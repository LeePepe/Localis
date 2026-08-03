---
layer: SessionStore
role: Persistence boundary for host-scoped sessions and backends behind the SessionRepository protocol
depends_on: [LocalisModels]
depended_by: [ChatService, LocalisUI, Localis]
red_lines:
  - No query may filter by `backendID` alone. The composite key is `(hostID, backendID)` — the same backend name (`claude`) exists on two machines, and a backend-only query cross-contaminates them (FR-029, Amendment A §1.1).
  - CloudKit stays off. `ModelConfiguration` is constructed with `cloudKitDatabase: .none` — session transcripts never leave the device (constitution I).
  - No message body, title, or backend payload is ever logged. Diagnostics carry ids and counts only (constitution I).
  - Migration never deletes. Unattributable legacy sessions become read-only, never dropped (FR-038, SC-008).
  - A session's host is fixed at creation. Neither `create` nor `save` may rebind it (FR-030).
  - Callers depend on the `SessionRepository` protocol, never on a concrete store. Swapping in-memory for disk-backed must not touch any other layer.
  - Storage failures map to `LocalisError` at this boundary — file/decoding errors must never escape.
  - No UI and no networking. This layer stores what it is given; it does not fetch or render.
  - All writes are actor-isolated and `async`. Nothing here runs on the main thread.
roles:
  Types: [SessionQuery, ResumeCursor, TurnReconciliation, HostAttributionPlan, UnattributedHost]
  Config: [SessionStoreContainer]
  Repo: [SessionRepository, SwiftDataSessionRepository, StoredModels, StoredMapping]
test: swift test --package-path Packages/SessionStore
owns: [SessionRepository, InMemorySessionRepository, SwiftDataSessionRepository, SessionQuery, ResumeCursor, TurnReconciliation, HostAttributionPlan]
---

# SessionStore Context

## Role

The repository boundary. Business logic depends on the `SessionRepository`
protocol, so the on-disk format can change — and tests can run entirely in
memory — without touching callers.

## The composite key

Every stored session carries the host it belongs to. `SessionQuery` makes the
red line structural rather than a convention: `hostID` is non-optional and no
initializer accepts a `backendID` without one, so a backend-only query is
*unrepresentable*, not merely discouraged. The `SessionRepository` protocol is
scoped the same way — `backends(ofHost:)`, `save(_:on:)`, `deleteBackend(id:on:)`
— because a host-blind method on the protocol would reintroduce the defect one
layer up, where the type system can no longer catch it.

`StoredSession.hostID` is a raw `UUID?` rather than a `HostID`. SwiftData
predicates compile against primitives, and a `#Predicate` over a wrapper struct
silently degrades to an in-memory filter — the composite index would stop being
used without any error. `StoredMapping` reapplies the newtype on the way out.

## Two ways a session can have no live host

These are different facts and are stored separately:

- **`hostID == nil`** — a legacy row written before Amendment A. No machine was
  ever recorded. Projects as `HostID.unattributed` (the reserved all-zero id,
  which pairing never generates) and is found via `SessionQuery.unattributed`.
- **`isOrphaned == true`** — the host was unpaired. The binding *survives*
  (FR-030): the session is still found through that host's query, the transcript
  is intact, and only sending is disabled. Re-pairing calls
  `reactivateSessions(ofHost:)` and the conversation is usable again.

Conflating them would let a re-pair re-attribute a conversation that never
moved.

## Restored state

A session read from disk comes back `.disconnected` or `.orphaned` — never
`.idle`. There is no live link to a host at read time, so `canSend` must be
false until one is opened (FR-053). Claiming `idle` would let the composer offer
to send over a connection that was never established.

## Background resume reconciliation

The host keeps producing while the app is away, so on return the layer must say
which of three things happened. `TurnReconciliation.reconcile(messageID:)`
answers with exactly one:

- `.settled` — the stream finished (or already failed and told the user).
- `.stillRunning(ResumeCursor)` — resumable from `(turnID, lastSeq)`.
- `.lost` — the turn died mid-stream and only this case sets `allowsRetry`.

`detached` (app backgrounded, host still running) and `interrupted` (the turn
actually died) are never collapsed into one state — Amendment C §1.5. A
`detached` message with no cursor is `.lost`, not silently resumable: without a
sequence there is no safe point to resume from.

## Migration

`HostAttributionPlan.resolve(pairedHosts:)` is a pure function so the backfill
rule can be exhausted in a table without a container:

- exactly one paired host → every legacy session is backfilled to it;
- zero, or two or more → attribution is a guess, so the sessions become
  read-only and wait for the user to adopt them via `adopt(sessionIDs:on:)`.

No branch deletes. `HostAttribution` has no delete case at all, so "lose the
user's data" is not a state the type can express. Migration is idempotent — a
second run attributes nothing.

## Ordering guarantees

Ordering lives here, not in the view, because it is a property of the data:

- `allSessions()` / `sessions(matching:)` — newest `updatedAt` first.
- `backends(ofHost:)` — alphabetical by name, so the picker doesn't reorder
  itself between launches.
- messages within a session — by `createdAt`, ascending.

## Deletes

`delete(id:)` and `deleteBackend(id:on:)` are idempotent — deleting an absent id
is a no-op, not an error. Messages cascade with their session; nothing else
does. Unpairing is not a delete (see above).

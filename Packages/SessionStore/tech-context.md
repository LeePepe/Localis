---
layer: SessionStore
role: Persistence boundary for sessions and backends behind the SessionRepository protocol
depends_on: [LocalisModels]
depended_by: [ChatService, LocalisUI, Localis]
red_lines:
  - Callers depend on the `SessionRepository` protocol, never on a concrete store. Swapping in-memory for disk-backed must not touch any other layer.
  - Storage failures map to `LocalisError` at this boundary — file/decoding errors must never escape.
  - No UI and no networking. This layer stores what it is given; it does not fetch or render.
  - Concurrent access is serialized by the actor. Do not add a non-isolated shared cache alongside it.
roles:
  Repo: [SessionRepository]
test: swift test --package-path Packages/SessionStore
owns: [SessionRepository, InMemorySessionRepository]
---

# SessionStore Context

## Role

The repository boundary. Business logic depends on the `SessionRepository`
protocol, so the on-disk format can change — and tests can run entirely in
memory — without touching callers.

## Current state

`InMemorySessionRepository` is the only conformer today. It is an `actor`, so
concurrent readers and writers are serialized without locks. The disk-backed
implementation will conform to the same protocol and swap in behind it; that is
the whole point of the seam.

## Ordering guarantees

Ordering lives here, not in the view, because it is a property of the data:

- `allSessions()` — newest `updatedAt` first (the session-list order).
- `allBackends()` — alphabetical by name, so the picker doesn't reorder itself
  between launches.

## Deletes

`delete(id:)` and `deleteBackend(id:)` are idempotent — deleting an absent id is
a no-op, not an error. A session whose backend was deleted still renders (see
`LocalisUI` → `SessionRowState`), so orphan rows are a supported state.

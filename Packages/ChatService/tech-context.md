---
layer: ChatService
role: Orchestrates one chat turn — validate, persist, stream the reply, persist each update
depends_on: [LocalisModels, TransportKit, SessionStore, SkillsKit]
depended_by: [LocalisUI, Localis]
red_lines:
  - Depends on `AgentTransport` and `SessionRepository` as PROTOCOLS, never on concrete types. Importing a concrete transport here would make this layer untestable without a live agent.
  - A mid-stream failure must preserve the partial text the user already saw and mark the message `.failed` — never discard it, never leave it stranded as `.streaming`.
  - No UI. This layer yields `Session` snapshots; it does not know how they are drawn.
  - Time and identity are injected (`now` / `makeID`) so turns are deterministic under test. Do not call `Date()` or `UUID()` inline.
  - Swift 6 strict concurrency; the actor's isolation must not be escaped with `@unchecked Sendable`.
roles:
  Service: [ChatService]
test: swift test --package-path Packages/ChatService
owns: [ChatService]
---

# ChatService Context

## Role

The only place that knows the *order* of a chat turn:

1. Validate the prompt (empty → `LocalisError.invalidInput(field: "message")`,
   thrown before anything is persisted).
2. Persist the user message.
3. Persist a `.streaming` assistant placeholder.
4. Stream transport events, updating and persisting after each one.
5. Settle on a terminal status.

## Why it yields snapshots

`send` returns `AsyncThrowingStream<Session, Error>`. Each element is a
*complete new session* with the assistant message updated. The view renders the
latest snapshot and never mutates — which is what keeps the streaming path free
of shared mutable state.

## Failure handling

A transport failure mid-stream does **not** throw out of the stream. The partial
assistant text is kept and marked `.failed`, then yielded, so the user keeps
what they already read and the UI can offer a retry. Throwing here would lose
the partial text.

A stream that ends without an explicit `.completed` event is still a finished
turn — the message is settled to `.complete` rather than stranded as
`.streaming`, which would leave a permanent spinner in the transcript.

## The reason a turn failed is carried, not dropped

`TransportEvent.failed` carries a `LocalisError`, and a bare `case .failed:`
compiles while silently discarding it. That leaves the user with "Error" and no
way to tell a revoked token from a dropped connection — one needs re-pairing,
the other needs nothing but a retry. The reason is bound and lands on
`Session.status` as `.error(_)`, which is where it survives a relaunch: *why* a
turn died cannot be recomputed from anything once the process exits.

Anything thrown that is not already a `LocalisError` is mapped here rather than
let through. Conformers are supposed to map at their own boundary, so a foreign
error means that rule was broken upstream — but a `URLError` reaching the UI
renders as text no user can read, and its description can carry a full endpoint
(constitution I).

## A finished turn clears the error

Settling a successful turn sets `.idle`. Without it, one bad turn marks the
conversation broken for good: `Session.canSend` is `status == .idle`, so a stale
`.error` leaves the composer refusing input on a session that works (FR-053).
Every failure path in this layer has a matching clear.

## Determinism

`now` and `makeID` are injected closures. Tests pass fixed values; production
uses `Date()` / `UUID()`.

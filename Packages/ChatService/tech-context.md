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

A `.turnEnd` frame carries an `outcome` and, on failure, an `error.code`; a bare
`case .turnEnd:` compiles while silently discarding both. That leaves the user
with "Error" and no way to tell a revoked token from a dropped connection — one
needs re-pairing, the other needs nothing but a retry. The code is mapped by
`LocalisError(wireCode:)` and lands on `Session.status` as `.error(_)`, which is
where it survives a relaunch: *why* a turn died cannot be recomputed from
anything once the process exits.

The bridge's own `error.message` is never read, here or anywhere — it can
contain absolute paths (constitution I / FR-025), and the wording the user sees
is derived locally from the case.

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

## A broken stream is not automatically a failure

Amendment C §1.5 splits one outcome into three, and this layer settles them from
two rules it does not itself own:

1. **Is the break survivable?** `LocalisError.isRetryable` answers. A revoked
   token and a dropped connection produce the same broken stream, but resuming
   the first only replays the refusal — so it settles `.failed`.
2. **Is a survivable break resumable?** `TurnReconciliation.resolve` answers,
   from the cursor: with one → `.detached`, without → `.interrupted`.

Neither question is answered here. An `if cursor != nil` in this file would
agree with the store *by coincidence*, and the first refactor on either side
would end the agreement without a test failing — which is exactly the failure
mode three layers of defence exist to prevent.

`.detached` reads the session as `.disconnected`, not `.error`. The turn is
running fine on the host; the link is what is gone, and an error banner would be
a lie about the work. `canSend` stays false either way, which is correct —
starting a second turn while the first generates is the harm the amendment names.

### `sessionStatus` is public on purpose

`.disconnected` carries a specific claim: **the link is gone, and the work may
well still be running.** The composer's wording depends on that reading — it
offers to keep reading the conversation rather than announcing the reply is
lost.

That agreement was reached twice independently, in this package and in LocalisUI,
and for a while the only thing holding it together was that both authors happened
to mean the same thing. Nothing failed if one of them changed their mind; the
user was simply told that a turn still generating on their Mac had died. A
`static func` that the UI can call is what turns that coincidence into something
a test can hold: the projection is asserted against, not restated.

The obligation runs both ways and is worth naming, because neither half is
enforced by the compiler: changing this mapping means telling LocalisUI first,
and changing what `.disconnected` says to the user means telling this layer.

## Where the cursor comes from

`AgentTransport.send` returns a `TurnStream`: a `turnID` read from the response
header, plus the frames. The cursor is seeded from that id **before the first
frame arrives**, which is what makes the worst case decidable — a connection
that dies before any event is still a turn the Mac is generating, and without
the id it would be indistinguishable from one that never started.

`turnID` is optional because a bridge older than the resume contract omits the
header. That is a real case, not one to assume away: no id means no cursor,
which means a break settles `.interrupted` rather than `.detached`. Correct —
there is nothing to resume.

Frames are deduped against the cursor before anything else. On resume the bridge
may replay frames around the boundary, and appending a replayed delta shows the
user duplicated words (SC-003). Two details that look like oversights and are
not:

- A frame with **no `seq` is always kept**. Absent means "this host cannot
  resume", not "sequence zero", and a healthy stream repeats words all the time.
- The check is `shouldAccept(seq:)`, not `accepts(turnID:seq:)`. A
  `SequencedEvent` carries no turn id, and one `TurnStream` is one turn's frames
  by construction. Passing the cursor's own id back in would look like the
  stronger check while comparing a value to itself.

## A failure the bridge under-reports is still a failure

`.turnEnd(outcome: .failed)` settles the message `.failed` whether or not
`failed_at_ms` and `tool_calls_completed` came with it. `TurnFailure` is built
only when **both** are present — filling a missing one with `0` would assert
"failed 0 minutes in, after 0 tool calls", and a half-invented record is the one
shape that reads as true and is not. The UI already drops the detail line when
it is absent.

This differs from `TurnReconciliation`, which degrades a detail-less failure to
`.settled` and loses both the failure and the retry. That path is not wrong for
what it can see — two persisted columns after a relaunch. This one observed the
frame itself, which is strictly more information, so there is nothing to infer.

An outcome this build cannot name (`.unknown`) does **not** settle the message.
The loop keeps reading: the frames that follow decide, and guessing `.complete`
would report an unfinished turn as answered.

## Determinism

`now` and `makeID` are injected closures. Tests pass fixed values; production
uses `Date()` / `UUID()`.

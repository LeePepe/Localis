---
layer: LocalisModels
role: Domain value types shared by every layer — hosts, agents, sessions, messages, and the one error vocabulary
depends_on: []
depended_by: [TransportKit, ChatService, SkillsKit, SessionStore, LocalisUI, Localis]
red_lines:
  - Pure value types only — no networking, no persistence, no SwiftUI. Adding a dependency here couples every layer to it.
  - Every type is immutable; changes return a new value (`withX` / `appending`). No `var` stored properties, no in-place mutation.
  - Swift 6 strict concurrency; all types `Sendable` without `@unchecked` or `nonisolated(unsafe)`.
  - `LocalisError.userMessage` must never contain endpoints, tokens, or raw payloads — it is rendered to the user verbatim.
  - No credential field on any entity. The pairing token lives in the Keychain, keyed by `HostID`, and is never modelled here.
  - `HostRuntimeState` is deliberately not `Codable` — reachability and latency are derived, never persisted.
  - The bridge's own `error.message` is never carried into `LocalisError` — it may contain absolute paths. UI text is derived locally from the code.
roles:
  Types: [LocalisHost, HostRuntimeState, HostRecognition, AgentBackend, Capability, BackendRef, Message, Session, StreamEvent, TurnCursor, TurnFailure, SkillDescriptor, LocalisError]
test: swift test --package-path Packages/LocalisModels
owns: [LocalisHost, HostID, HostEndpoint, SPKIHash, HostPairingState, HostKind, HostRuntimeState, HostReachability, HostUnreachableReason, HostRecognition, AgentBackend, BackendAvailability, Capability, BackendRef, Message, MessageRole, MessageStatus, Session, SessionStatus, StreamEvent, SequencedEvent, ToolCall, ApprovalRequest, TelemetryValue, TokenUsage, TurnEnd, TurnCursor, TurnFailure, SkillDescriptor, LocalisError]
---

# LocalisModels Context

## Role

The foundation layer. Every other package imports it; it imports nothing. That
asymmetry is deliberate — it is what keeps the dependency graph acyclic.

## What lives here

| Type | Purpose |
|---|---|
| `LocalisHost` | A machine running the bridge: identity, endpoint, pinned certificate, pairing state |
| `HostRecognition` | Decides whether a discovered bridge is a machine already on file (FR-031) |
| `HostRuntimeState` | Reachability / latency / last-seen — derived, never persisted |
| `AgentBackend` | A backend advertised by the bridge: id, label, capability set |
| `Capability` | A named-but-open capability a backend advertises (contract §2) |
| `BackendRef` | The composite key `(hostID, backendID)` that names a backend across hosts (FR-029) |
| `Message` | One turn: role, text, timestamp, delivery status |
| `Session` | A conversation bound to one host; holds the transcript |
| `StreamEvent` | The only stream vocabulary that leaves TransportKit — wire shapes stay internal |
| `TurnCursor` | Resume cursor `(turnID, lastSeq)` for an in-flight turn (Amendment C) |
| `TurnFailure` | How far a turn got before it died — `failedAtMs`, `toolCallsCompleted` |
| `SkillDescriptor` | A prompt template the input bar can insert (Amendment B) |
| `LocalisError` | The single error vocabulary all layers map into |

## Why `LocalisHost` and not `Host`

Foundation exports a `Host` class on Darwin. A domain type named `Host` compiles
inside this package but makes every downstream `[Host]` annotation ambiguous,
which would break each consumer in turn. Same reason the error vocabulary is
`LocalisError`. The prefix is paid once, here.

## Host identity

`HostID` is generated locally, assigned once, and stable for life (FR-026). The
endpoint, display name and pinned certificate are all *attributes*, because all
three change during normal use — DHCP hands out a new address, the user renames
the machine, a bridge reinstall regenerates the certificate. Using any of them as
identity would let one machine look like two and scatter its history.

`bridgeID` is optional and is never an identity authority (Amendment A §1.6). The
pinned SPKI is the authority; `bridgeID` only relocates a machine whose
certificate already matches. A whole-disk clone reports the same `bridgeID` from
a different machine, and the differing SPKI is what keeps the two apart.

## Backends are addressed by composite key

`BackendRef` is `(hostID, backendID)`, where `backendID` stays the raw wire
string from `/v1/models`. Amendment A §1.1 rejected synthesising a local UUID
per backend: it would turn backends into client state, create a garbage
collection problem, and fail to survive a bridge reinstall.

## Message status and background streaming

Streaming continues while the app is away, so the status set has to express what
the user finds on return (Amendment C §1.5–§1.6):

| Came back to find | Status | Offered |
|---|---|---|
| The stream finished | `complete` | nothing |
| The host is still generating | `detached` | wait — **never** retry |
| The stream died and content was lost | `interrupted` | retry |
| A resume returned truncated content | `interrupted` | retry |

`detached.isRetryable` is `false` on purpose: the work is still running on the
host, and a retry would start a second generation. `Message.appending` is a
no-op on a terminal message, so a late frame from a dead connection cannot
reopen a finished message.

## Immutability

Every mutation returns a new value:

- `Message.appending(_:)` — the streaming path; each chunk yields a new message.
- `Session.replacing(_:at:)` — swaps a message by id, returns a new session.
- `LocalisHost.paired(pinning:)` / `.unpaired()` / `.relocated(to:)`.
- `AgentBackend.withDisplayName(_:)` / `.withCapabilities(_:)`.

`Session.replacing` is a no-op for an unknown id rather than a crash or an
append — a stale message id must not corrupt a transcript.

`Session.hostID` is fixed at creation and immutable for life (FR-030). This is
enforced structurally: no initialiser overload or copy-with helper accepts a new
host, so there is no code path that moves a session between machines.

## Derived state vs historical fact

The test for whether something must be persisted:

> **Can it be recomputed after a relaunch? Then it is derived state. If it
> cannot, it is a historical fact and must be stored.**

`HostRuntimeState` is derived — reachability and latency are a fresh probe away,
so persisting them would only mean showing a stale answer until the real one
arrives. That is why the type is deliberately not `Codable`: the type system
refuses the mistake rather than a reviewer having to catch it.

`SessionStatus.error` and `TurnFailure` are historical facts. That the turn
failed, eight minutes in, after three tool calls, is not observable from
anywhere once the process dies. Dropping it means the user comes back to a
conversation that reads as idle — or to a bare "Error" — and cannot tell whether
anything happened at all, let alone whether to retry.

Note the two are not distinguished by how *transient* they feel. A live stream
and a failed turn are equally momentary; the difference is only that one can be
asked again and the other cannot. Apply the question, not the intuition.

## Capabilities are named but not closed

Contract §2 asks for two things in one sentence: capabilities have a documented
set of values, *and* "客户端必须忽略未知值，**不得因此丢弃整项**". A closed `enum`
delivers only the first — decoding a capability this build has never heard of
fails, and the failure takes the whole backend with it. The user loses an agent
from the picker because the host advertised one extra word.

`Capability` is therefore a `struct` over the wire string with named statics.
`supports(.streaming)` is still checked at compile time — a typo like
`.steaming` will not build, where `"steaming"` used to return `false` forever —
while an unrecognised value round-trips intact. `isKnown` exists for deciding
whether the UI can draw an icon, never for deciding whether to keep the value.

The wire spells one of them `requires_network`; the conversion lives inside the
type so no call site has to track which side of the boundary it is on.

## Error mapping

Each layer maps its own failures into `LocalisError` **at its boundary**, so the
UI has exactly one vocabulary to render. `URLError`, decoding errors, and file
errors must never escape their layer.

Every error code in contract §6 has a case here, because the contract forbids
showing the bridge's own `error.message` (it may contain absolute paths,
constitution I). A code with no case would have nowhere to get its wording from
but the wire. `LocalisError.isRetryable` encodes which failures a retry can
actually change: a certificate mismatch and a turn belonging to another device
are not among them.

`LocalisError` is `Codable` because `SessionStatus.error` is persisted with the
session: a conversation that ended in failure should still read as failed after
a relaunch, rather than silently coming back as idle.

### The wire-code mapping lives here, not per layer

`LocalisError(wireCode:)` is the one translation from contract §6's `error.code`
into this vocabulary. It sits next to the cases for the same reason the cases sit
together: three layers each writing their own switch is three implementations
that can each be wrong differently, and the one that drifts stays invisible until
a user hits exactly that code on exactly that path.

Two choices about codes this build does not recognise, both deliberate:

- **The initialiser is not failable.** Returning `nil` invites `?? nothing
  happened` at the call site, which reports a failed turn as fine. A code we
  cannot name is still a failure.
- **The fallback is `malformedResponse`, which is retryable.** "We don't know
  what went wrong" and "we know a retry cannot help" are different claims, and
  they are not equally costly to get wrong: defaulting to the second takes the
  retry away from a user whose next attempt might well have worked.

The code is never used as display text. An unrecognised value may be the bridge's
own `error.message` passed in by mistake, and that can carry absolute paths
(constitution I / FR-025); `userMessage` is derived from the case, so it cannot.

## Resume cursor

`TurnCursor` is `(turnID, lastSeq)`. `lastSeq` is `Int?` rather than defaulting
to `0` or `-1`: `seq` counts from 0 per turn, so the first would silently skip
event 0 and the second would be a sentinel pretending to be a sequence number.

`resumeFrom` is the *last accepted* seq, not the next wanted one — the bridge
replays from `seq + 1`, so the other choice would skip exactly one frame.
`advanced(to:)` never moves backwards, because after a resume the old connection
can still deliver a late frame.

A *gap* in `seq` is accepted rather than rejected: the bridge decides what to
replay, and a client demanding consecutive numbers would strand a turn forever
the moment one was skipped. Prefer `accepts(turnID:seq:)` over `shouldAccept` —
`seq` counts per turn, so another turn's frame carries numbers in the same range
and would otherwise mark this cursor's progress.

## Failure detail lives on the message

Contract §3.1(d) makes `failed_at_ms` and `tool_calls_completed` **required** on
a failed turn, so the user gets "failed 8 minutes in, after 3 tool calls" rather
than a bare "Error". `TurnFailure` is stored on `Message`, not just on a stream
event, because the message is what survives a relaunch — and force-quitting
before seeing the failure is the exact case background resume exists for.

`Message.failed(_:)` sets status and detail together. Separate setters would
permit a `.failed` message with nothing to show, which is the outcome the
contract forbids. Moving off `.failed` drops the detail, so a successful retry
cannot carry stale "failed 8 minutes in" wording on a finished answer.


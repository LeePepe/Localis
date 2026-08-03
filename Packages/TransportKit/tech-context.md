---
layer: TransportKit
role: Wire protocol to local agents — the AgentTransport seam, SSE stream parsing, and endpoint validation
depends_on: [LocalisModels]
depended_by: [ChatService, Localis]
red_lines:
  - Every wire failure maps to `LocalisError` before it escapes this layer — `URLError`, decoding errors, and socket errors must never reach ChatService or the UI.
  - No UI, no persistence. This layer speaks to the network and returns values; it does not decide what to store or show.
  - User-supplied endpoints are validated here (`EndpointValidator`) before any request. This is a trust boundary — never take a raw string on faith.
  - HTTPS only. Plaintext HTTP has no fallback path, LAN included (constitution principle V) — self-signed certs are handled by SPKI pinning at pairing time, never by downgrading the scheme.
  - Parsers are pure value types (`SSEParser`), testable with no socket. Do not hide parsing inside a URLSession delegate.
  - Swift 6 strict concurrency; `AgentTransport` conformers must be genuinely `Sendable`.
roles:
  Types: [AgentTransport, BridgeClient, SSEParser, EndpointValidator, StreamEventMapper, BackendCatalog, SkillCatalog, SPKIPinning, HostCredentialStore, BridgeDiscovery]
test: swift test --package-path Packages/TransportKit
owns: [AgentTransport, TurnStream, BridgeClient, TurnRequest, SSEParser, EndpointValidator, StreamEventMapper, BackendCatalog, HostCapabilities, SkillCatalog, SPKIPinning, HostCredentialStore, KeychainError, BridgeDiscovery, DiscoveredHost]
---

# TransportKit Context

## Role

The only layer that touches the network. Everything above it depends on the
`AgentTransport` protocol, never on a concrete transport — which is what lets
`ChatService` be tested against a scripted fake with no live agent.

## The seam

```swift
protocol AgentTransport: Sendable {
    func send(_ request: TurnRequest) async throws -> TurnStream
    func probe(_ backend: AgentBackend) async -> Bool
}
```

`TurnStream` is `turnID: String?` plus an `AsyncThrowingStream<SequencedEvent, Error>`.
`BridgeClient` is the conformer.

The seam carries `SequencedEvent`, not a reduced `.chunk`/`.completed`/`.failed`
triple. The narrow shape was here first and is the tempting simplification, but
it cannot *express* two things the contract requires, and both were parsed off
the wire already — the seam was the only thing discarding them:

- **A failure's progress.** Contract §3.1(d) makes `failed_at_ms` and
  `tool_calls_completed` a MUST, so the user sees "failed after 8 minutes and 3
  tool calls" instead of a bare "Error". `.failed(LocalisError)` has nowhere to
  put them, and a caller filling in zeroes would be asserting something false
  about work the Mac actually did.
- **The turn id, before the first event.** It arrives in the `x-localis-turn-id`
  header (§3.3), which is why it is a property of `TurnStream` rather than an
  event. A turn whose id can only be learned by reading the stream is
  unresumable in exactly the case resume exists for — the connection dying
  early — and `.detached` then has no way to be constructed at all.

`AgentTransportTests` pins this shape. A well-meaning narrowing back to three
cases fails a test rather than quietly deleting two features.

One conformer serves every backend. Backends are **data** (capability
descriptors from `/v1/models`), never code branches — constitution principle IV
forbids a `switch` on a backend name anywhere in this layer. Adding a sixth
agent is a Mac-side adapter, with zero iOS changes and zero releases.

`probe` asks `/v1/models` rather than pinging a backend directly: availability
is the host's to report (§2), and it is the only party that knows whether a
backend is signed in. Any failure reads as "not right now" — a probe exists to
grey a row out, and throwing would turn an unreachable host into an error the
user must dismiss before seeing the list.

## SSEParser

Incremental and pure: feed it raw chunks as they arrive, get back whole frames;
bytes that don't yet form a complete event are carried in `buffer` to the next
call. `parse` returns `(frames, next)` rather than mutating — so a test can
replay any chunk boundary, including a split mid-frame.

Comment lines (`:` in column 0) are SSE keep-alives and yield no frame.

## What leaves this package

`StreamEventMapper` turns an `SSEParser.Frame` into a `StreamEvent`, which
**LocalisModels owns** — not this package. The reason is `LocalisUI`, whose
`depends_on` has no TransportKit in it: the UI has to render tool durations and
"failed 8 minutes in, after 3 tool calls", so a stream type living here would be
unreachable from the layer that displays it.

What stays here is everything that knows the wire: the mapper itself, the
`x_localis` envelopes, `JSONValue`, `[DONE]`. Above this line the app sees domain
events and never a wire shape (plan §1.1).

A frame the mapper cannot read yields `nil` and the stream continues. That is
constitution IV in practice — the bridge may add events and fields without an iOS
release, so treating the unrecognised as fatal would break turns on exactly the
frames a newer bridge added.

## BridgeClient

One client, one machine. `send` starts a turn, `resume` picks it up after a
disconnect, `cancel` stops it, `models`/`skills` read the catalogues.

`send` returns a `TurnStream` — the turn id *and* the events — because the id
arrives in the `x-localis-turn-id` response header, before any body (contract
§3.3). A turn whose id can only be learned by reading the stream is unresumable
in exactly the case resume exists for: the connection dying early.

Three rules about how a stream ends, and all three fail silently if inverted:

- `[DONE]` closes it. Anything after is ignored (contract §7).
- **Ending without `[DONE]` throws `connectionLost`**, keeping what arrived.
  Finishing cleanly would present half an answer as a whole one.
- **`x_localis.truncated` throws `truncated`, never completion** — "宁可说丢了,
  不可假装完整" (§3.3).

Resume dedupes on `TurnCursor.accepts(turnID:seq:)`, not `shouldAccept(seq:)`.
`seq` counts per turn, so another turn's frames carry numbers in the same range
and comparing sequence alone lets one turn's replay advance another's cursor.

Errors map on the **pair** `(status, code)`, not on status alone: 401 splits into
`unauthorized` and `tokenRevoked`, which demand opposite actions — one clears the
Keychain entry, the other must not. The bridge's `error.message` is never read;
it may hold absolute paths (constitution I), and a value nothing reads cannot
leak.

## Endpoint validation

**HTTPS only.** `EndpointValidator.allowedSchemes` is `["https"]` and there is no
plaintext fallback, LAN included (constitution principle V) — conversations carry
source code and filesystem paths, and "it's only my home network" is not a threat
model. Self-signed certificates are what make this practical without a public CA:
`SPKIPinning` records the SubjectPublicKeyInfo hash at pairing and checks it on
every connection afterwards.

Everything else — no host, unknown scheme, out-of-range port — is
`LocalisError.invalidInput(field: "endpoint")`.

`ArchitectureTests` sweeps this package's own sources for `http://` so the rule
cannot be reintroduced quietly.

## Per-host, never multi-host

Everything here is built for **one** host: one token, one pinned SPKI, one
negotiated protocol version, one backend list, one skill catalog. Amendment A's
multi-host orchestration lives above this layer.

`BridgeDiscovery` is the single exception, and only just — it *emits* hosts one
at a time and keeps no collection, no registry and no "current host". Whether a
sighting is a machine already on file is decided by `HostRecognition` in
LocalisModels, not reimplemented here: the pinned certificate is the authority
and Bonjour's `hid=` only relocates a machine whose SPKI already matches.

`HostCredentialStore` keys every entry by `HostID`, so a host-blind lookup is not
something to remember not to write — there is no way to express it.

`ArchitectureTests` sweeps `BridgeClient`, `BridgePairing` and
`HostCredentialStore` for a *collection* of hosts (`[LocalisHost]`, `[HostID]`,
`[HostEndpoint]`). Those three carry a host's credentials, and a collection is
the shape that lets one machine's token or pin reach a request bound for another
(FR-028) while looking perfectly reasonable at the call site.

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
  Types: [AgentTransport, SSEParser, EndpointValidator, StreamEvent, StreamEventMapper, BackendCatalog, SkillCatalog, SPKIPinning, HostCredentialStore, BridgeDiscovery]
test: swift test --package-path Packages/TransportKit
owns: [AgentTransport, TransportRequest, TransportEvent, SSEParser, EndpointValidator, StreamEvent, SequencedEvent, StreamEventMapper, BackendCatalog, BackendListing, HostCapabilities, SkillCatalog, SPKIPinning, HostCredentialStore, KeychainError, BridgeDiscovery, DiscoveredHost]
---

# TransportKit Context

## Role

The only layer that touches the network. Everything above it depends on the
`AgentTransport` protocol, never on a concrete transport — which is what lets
`ChatService` be tested against a scripted fake with no live agent.

## The seam

```swift
protocol AgentTransport: Sendable {
    func send(_ request: TransportRequest) async throws -> AsyncThrowingStream<TransportEvent, Error>
    func probe(_ backend: AgentBackend) async -> Bool
}
```

`TransportEvent` is `.chunk(String)` / `.completed` / `.failed(LocalisError)`.
One conformer serves every backend. Backends are **data** (capability
descriptors from `/v1/models`), never code branches — constitution principle IV
forbids a `switch` on a backend name anywhere in this layer. Adding a sixth
agent is a Mac-side adapter, with zero iOS changes and zero releases.

## SSEParser

Incremental and pure: feed it raw chunks as they arrive, get back whole frames;
bytes that don't yet form a complete event are carried in `buffer` to the next
call. `parse` returns `(frames, next)` rather than mutating — so a test can
replay any chunk boundary, including a split mid-frame.

Comment lines (`:` in column 0) are SSE keep-alives and yield no frame.

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

---
layer: TransportKit
role: Wire protocol to local agents — the AgentTransport seam, SSE stream parsing, and endpoint validation
depends_on: [LocalisModels]
depended_by: [ChatService, Localis]
red_lines:
  - Every wire failure maps to `LocalisError` before it escapes this layer — `URLError`, decoding errors, and socket errors must never reach ChatService or the UI.
  - No UI, no persistence. This layer speaks to the network and returns values; it does not decide what to store or show.
  - User-supplied endpoints are validated here (`EndpointValidator`) before any request. This is a trust boundary — never take a raw string on faith.
  - Parsers are pure value types (`SSEParser`), testable with no socket. Do not hide parsing inside a URLSession delegate.
  - Swift 6 strict concurrency; `AgentTransport` conformers must be genuinely `Sendable`.
roles:
  Types: [AgentTransport, SSEParser, EndpointValidator]
test: swift test --package-path Packages/TransportKit
owns: [AgentTransport, TransportRequest, TransportEvent, SSEParser, EndpointValidator]
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
Each `AgentKind` will bring its own conformer — the protocol is what keeps
adding a new agent from touching any other layer.

## SSEParser

Incremental and pure: feed it raw chunks as they arrive, get back whole frames;
bytes that don't yet form a complete event are carried in `buffer` to the next
call. `parse` returns `(frames, next)` rather than mutating — so a test can
replay any chunk boundary, including a split mid-frame.

Comment lines (`:` in column 0) are SSE keep-alives and yield no frame.

## Endpoint validation

Local agents commonly run plain HTTP on the LAN, so `http` is allowed alongside
`https`. Everything else — no host, unknown scheme, out-of-range port — is
`LocalisError.invalidInput(field: "endpoint")`.

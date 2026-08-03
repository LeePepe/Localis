import Foundation
import LocalisModels
import Testing

@testable import TransportKit

/// The seam every layer above depends on.
///
/// These tests exist because the seam's *shape* is what decides whether two
/// features are expressible at all. A protocol that yields `.chunk`/`.completed`
/// /`.failed` cannot carry a turn id or a failure's progress, so `.detached` and
/// "failed 8 minutes in, after 3 tool calls" are not unimplemented branches —
/// they are values the seam cannot say. Pinning the shape here means a
/// well-meaning simplification back to three cases fails a test instead of
/// quietly deleting two features.
@Suite("AgentTransport seam")
struct AgentTransportTests {
    private static let host = HostID()
    private static let endpoint = HostEndpoint(host: "mac.local", port: 8443)

    private static func turn(_ text: String = "hello") -> TurnRequest {
        TurnRequest(
            backendID: "alpha",
            sessionID: UUID(),
            messages: [Message(id: UUID(), role: .user, text: text, createdAt: Date(timeIntervalSince1970: 0))]
        )
    }

    /// The real client, reached only through the protocol.
    ///
    /// Typed as `any AgentTransport` on purpose: a test that called
    /// `BridgeClient` directly would still pass if the conformance were removed,
    /// which is the one thing these tests are here to catch.
    private static func transport(_ http: StubStreamingHTTP) -> any AgentTransport {
        BridgeClient(host: host, endpoint: endpoint, token: "opaque-token", http: http)
    }

    // MARK: - Conformance

    @Test("the real client is reachable through the protocol")
    func bridgeClientConforms() async throws {
        let http = StubStreamingHTTP(responses: [
            .stream(status: 200, headers: [:], body: ["data: [DONE]\n\n"])
        ])

        let stream = try await Self.transport(http).send(Self.turn())

        #expect(await http.lastRequest?.url?.absoluteString == "https://mac.local:8443/v1/chat/completions")
        _ = stream
    }

    // MARK: - What the seam must be able to carry

    /// Gap 1: `.detached` needs a turn id, and the id arrives in the response
    /// header — before any body, and possibly the only thing that arrives.
    ///
    /// A seam returning a bare stream can only offer the id as an event, which
    /// is unavailable in exactly the case resume exists for: the connection
    /// dying immediately. Then a turn the Mac is still generating is
    /// indistinguishable from one that never started, and the only safe reading
    /// is to abandon it.
    @Test("a turn id is available before any event arrives")
    func turnIDPrecedesEvents() async throws {
        let http = StubStreamingHTTP(responses: [
            .stream(status: 200, headers: ["x-localis-turn-id": "t-9"], body: [])
        ])

        let stream = try await Self.transport(http).send(Self.turn())

        // Read before the stream is touched at all. The body here is empty —
        // the disconnect-before-first-token case — and the id is still known.
        #expect(stream.turnID == "t-9")
    }

    /// Gap 2: a failure carries how far the turn got.
    ///
    /// Contract §3.1(d) makes `failed_at_ms` and `tool_calls_completed` a MUST
    /// on failure, so the user gets "failed after 8 minutes and 3 tool calls"
    /// rather than a bare "Error". A seam that drops them leaves the caller
    /// choosing between showing nothing and fabricating zeroes — and the second
    /// is worse, because "failed 0 minutes in" is a false claim about work the
    /// Mac actually did.
    @Test("a failure carries its progress through the seam")
    func failureCarriesProgress() async throws {
        let frame = """
            event: x-localis-turn-end
            data: {"seq":4,"turn_id":"t-9","outcome":"failed",\
            "error":{"code":"backend_unavailable"},\
            "failed_at_ms":8000,"tool_calls_completed":3}

            data: [DONE]


            """
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [frame])])

        var end: TurnEnd?
        for try await event in try await Self.transport(http).send(Self.turn()).events {
            if case .turnEnd(let turnEnd) = event.event { end = turnEnd }
        }

        let recorded = try #require(end, "the seam dropped the turn's end")
        #expect(recorded.failedAtMs == 8000)
        #expect(recorded.toolCallsCompleted == 3)
        #expect(recorded.errorCode == "backend_unavailable")
        #expect(recorded.turnID == "t-9")
    }

    /// Contract §3.3: dedupe on resume needs `seq` on every event.
    ///
    /// A seam carrying only text has nowhere to put it, and the caller must
    /// then dedupe by comparing content — which drops a legitimately repeated
    /// word as if it were a replayed frame.
    @Test("every event carries its sequence number")
    func eventsCarrySeq() async throws {
        let frames = """
            data: {"seq":0,"turn_id":"t-9","choices":[{"delta":{"content":"a"}}]}

            data: {"seq":1,"turn_id":"t-9","choices":[{"delta":{"content":"b"}}]}

            data: [DONE]


            """
        let http = StubStreamingHTTP(responses: [.stream(status: 200, headers: [:], body: [frames])])

        var seqs: [Int] = []
        for try await event in try await Self.transport(http).send(Self.turn()).events {
            if let seq = event.seq { seqs.append(seq) }
        }

        #expect(seqs == [0, 1])
    }

    // MARK: - Substitutability

    /// The seam has to be implementable by something that is not the real
    /// client, or `ChatService` cannot be tested without a live bridge — the
    /// entire reason the protocol exists.
    @Test("a scripted double satisfies the seam")
    func scriptedDoubleConforms() async throws {
        let events = [
            SequencedEvent(seq: 0, event: .delta("scripted")),
            SequencedEvent(seq: 1, event: .done),
        ]
        let transport: any AgentTransport = ScriptedTransport(turnID: "t-1", events: events)

        let stream = try await transport.send(Self.turn())
        var received: [StreamEvent] = []
        for try await event in stream.events { received.append(event.event) }

        #expect(stream.turnID == "t-1")
        #expect(received.count == 2)
        #expect(await transport.probe(AgentBackend(id: "alpha", displayName: "Alpha")))
    }
}

/// A transport with no socket, standing in for the bridge.
///
/// Deliberately minimal: if conforming to `AgentTransport` needed more than a
/// canned turn id and a list of events, the seam would be too wide to fake, and
/// `ChatService`'s tests would drift towards testing the transport instead.
private struct ScriptedTransport: AgentTransport {
    let turnID: String?
    let events: [SequencedEvent]

    func send(_ request: TurnRequest) async throws -> TurnStream {
        TurnStream(
            turnID: turnID,
            events: AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        )
    }

    func probe(_ backend: AgentBackend) async -> Bool { true }
}

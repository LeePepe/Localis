import Foundation
import Testing

@testable import BridgeCore

/// Covers the turn stream's framing obligations (contract §3.3).
///
/// `TurnCoordinator` had no tests at all until the iOS side's contract audit
/// found that `turn_id` was reaching the client only in the *last* frame. That
/// is worth recording: the gap was not a subtle one, it was simply in the one
/// type nothing exercised. A stream is awkward to assert against, and awkward
/// is where holes accumulate.
@Suite("TurnCoordinator")
struct TurnCoordinatorTests {
    /// A runner that emits exactly what it was handed.
    private struct StubRunner: TurnRunning {
        let backendID = "stub"
        let outputs: [TurnOutput]

        func run(
            prompt: String,
            resuming: String?,
            workspace: String?
        ) -> AsyncThrowingStream<TurnOutput, any Error> {
            AsyncThrowingStream { continuation in
                for output in outputs {
                    continuation.yield(output)
                }
                continuation.finish()
            }
        }
    }

    /// Runs a turn and returns its frames as parsed JSON payloads, in order.
    ///
    /// `[DONE]` is dropped: it is a literal sentinel, not an object, and every
    /// assertion here is about fields.
    private static func payloads(
        from outputs: [TurnOutput]
    ) async throws -> [[String: Any]] {
        let coordinator = TurnCoordinator(sessions: SessionStore())
        let request = TurnRequest(
            backendID: "stub",
            messages: [.init(role: "user", content: "hello")]
        )
        let (_, events) = await coordinator.start(
            request, on: StubRunner(outputs: outputs), deviceID: "device-1"
        )

        var text = ""
        for try await bytes in events {
            text += String(decoding: bytes, as: UTF8.self)
        }

        return text
            .components(separatedBy: "\n\n")
            .compactMap { frame in
                guard let line = frame.split(separator: "\n").last(where: { $0.hasPrefix("data: ") }) else {
                    return nil
                }
                let json = line.dropFirst("data: ".count)
                guard json != "[DONE]" else { return nil }
                return try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            }
    }

    /// The contract states this twice, as two separate MUSTs — in the response
    /// head *and* in the first event. The redundancy is deliberate: a client
    /// that parses only the SSE body (a proxy, a log replay, a recorded
    /// stream) never sees the header, and without the id it cannot resume or
    /// cancel the turn it is watching.
    @Test("the first frame carries turn_id")
    func firstFrameCarriesTurnID() async throws {
        let payloads = try await Self.payloads(from: [.event(.delta("He"))])
        let first = try #require(payloads.first)

        #expect(
            first["turn_id"] as? String != nil,
            "the first frame has no turn_id — a body-only client cannot name the turn it is reading"
        )
    }

    /// Not only the first: the contract's resume story assumes any frame
    /// identifies its turn, and a client that joins mid-stream reads whatever
    /// frame arrives next.
    @Test("every frame carries turn_id")
    func everyFrameCarriesTurnID() async throws {
        let payloads = try await Self.payloads(from: [
            .event(.sessionStatus("thinking")),
            .event(.delta("He")),
            .event(.delta("llo")),
            .event(.finished(reason: "stop")),
        ])

        let missing = payloads.enumerated().filter { $0.element["turn_id"] as? String == nil }
        let indices = missing.map { $0.offset }
        #expect(missing.isEmpty, "frames without turn_id at indices \(indices)")
    }

    /// All frames of one turn must agree, including the `turn_end` that mints
    /// its id separately.
    @Test("turn_id is the same in every frame")
    func turnIDIsConsistent() async throws {
        let payloads = try await Self.payloads(from: [
            .event(.delta("He")),
            .event(.delta("llo")),
        ])

        let ids = Set(payloads.compactMap { $0["turn_id"] as? String })
        #expect(ids.count == 1, "a turn reported \(ids.count) different ids: \(ids.sorted())")
    }

    /// `seq` starts at 0 and increases by one across *everything* the turn
    /// emits, content deltas included (§3.3, as clarified by Amendment D §1).
    /// It is the only cursor resume has.
    @Test("seq is monotonic from zero across every frame")
    func seqIsMonotonic() async throws {
        let payloads = try await Self.payloads(from: [
            .event(.sessionStatus("thinking")),
            .event(.delta("He")),
            .event(.delta("llo")),
            .event(.finished(reason: "stop")),
        ])

        let sequence = payloads.compactMap { $0["seq"] as? Int }
        #expect(sequence.count == payloads.count, "some frames carry no seq")
        #expect(sequence == Array(0..<payloads.count), "seq was \(sequence)")
    }
}

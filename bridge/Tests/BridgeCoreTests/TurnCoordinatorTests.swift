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
///
/// **On `turn_id` specifically: the contract does not require it on these
/// frames.** Amendment D §5b (2026-08-04) deleted that MUST, and the contract
/// now says a client MUST work when the first event omits it — the response
/// header `x-localis-turn-id` is the sole authority. The two tests below that
/// assert it therefore pin *bridge behaviour we chose*, not compliance. Do not
/// go looking in the contract for their basis; see `SequencedEvent.turnID` for
/// why the field is emitted anyway. Deleting these two would break no promise
/// to any client. `seqIsMonotonic` and `turnIDIsConsistent` are a different
/// matter — `seq` is still a MUST, and self-consistency is not optional.
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

    /// **Pins bridge behaviour. Asserts no contract requirement.**
    ///
    /// This test was written against a MUST that Amendment D §5b has since
    /// deleted, and the contract now says the opposite: a client MUST work when
    /// the first event omits `turn_id`. It is kept because the bridge does emit
    /// the field and a silent change to that is worth noticing — not because
    /// anything is owed to a client.
    ///
    /// The justification that used to sit here — "a body-only consumer needs
    /// it" — was written *after* the field existed, to explain it. Treating it
    /// as design intent nearly got a correct deletion reversed. It is recorded
    /// in `SequencedEvent.turnID` as what it is, and it is not an argument.
    @Test("the first frame carries turn_id")
    func firstFrameCarriesTurnID() async throws {
        let payloads = try await Self.payloads(from: [.event(.delta("He"))])
        let first = try #require(payloads.first)

        #expect(
            first["turn_id"] as? String != nil,
            "the first frame lost its turn_id — bridge behaviour changed; no client is owed this (Amendment D §5b)"
        )
    }

    /// Also bridge behaviour, not compliance — same standing as the test above.
    ///
    /// The contract's resume cursor is `seq` and the turn's identity is the
    /// response header; neither needs this field. What it guards is that the
    /// bridge stays self-consistent about emitting it at all.
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

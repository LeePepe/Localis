import Foundation
import Testing

@testable import LocalisModels

/// Amendment C / contract §3.1(d).
///
/// The contract's hard requirement is that a failure be *actionable*: "failed 8
/// minutes in, after 3 tool calls" rather than a bare "Error". These tests hold
/// that requirement up across the one case it exists for — the user force-quit
/// the app before ever seeing the failure.
@Suite("TurnFailure")
struct TurnFailureTests {
    @Test("carries elapsed time and tool call count")
    func carriesProgress() {
        let failure = TurnFailure(failedAtMs: 480_000, toolCallsCompleted: 3)

        #expect(failure.failedAtMs == 480_000)
        #expect(failure.toolCallsCompleted == 3)
    }

    @Test("negative values are clamped rather than rejected")
    func negativesAreClamped() {
        // Neither field can be negative in a real turn, so a negative means a
        // malformed frame. Rejecting the whole record over it would trade a
        // slightly wrong number for no failure detail at all — the bare "Error"
        // this type exists to prevent.
        let failure = TurnFailure(failedAtMs: -1, toolCallsCompleted: -7)

        #expect(failure.failedAtMs == 0)
        #expect(failure.toolCallsCompleted == 0)
    }

    @Test("a failure with no tool calls is still a valid failure")
    func zeroToolCallsIsValid() {
        // Failing before any tool ran is ordinary, not missing data. Treating 0
        // as "unknown" would hide a real and useful fact from the user.
        let failure = TurnFailure(failedAtMs: 1_200, toolCallsCompleted: 0)

        #expect(failure.toolCallsCompleted == 0)
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        // It has to survive being written to disk — that is the whole point.
        let failure = TurnFailure(failedAtMs: 480_000, toolCallsCompleted: 3)

        let data = try JSONEncoder().encode(failure)
        let decoded = try JSONDecoder().decode(TurnFailure.self, from: data)

        #expect(decoded == failure)
    }
}

/// The failure detail has to live on the message, because the message is what
/// survives a relaunch. Contract §3.1(d) states the rule as "mark the message
/// `failed`, **and carry the progress information**" — one action, not two.
@Suite("Message failure detail")
struct MessageFailureTests {
    private static let created = Date(timeIntervalSince1970: 1_700_000_000)

    private static func streaming() -> Message {
        Message(
            id: UUID(), role: .assistant, text: "partial",
            createdAt: created, status: .streaming
        )
    }

    @Test("failed(_:) sets the status and the detail together")
    func failedSetsBoth() {
        // Exposing these as two independent setters would allow a `.failed`
        // message with no detail — exactly the bare "Error" the contract's hard
        // requirement forbids.
        let message = Self.streaming()

        let failed = message.failed(TurnFailure(failedAtMs: 480_000, toolCallsCompleted: 3))

        #expect(failed.status == .failed)
        #expect(failed.failure?.failedAtMs == 480_000)
        #expect(failed.failure?.toolCallsCompleted == 3)
        #expect(failed.text == "partial")
        #expect(Self.streaming().failure == nil)
    }

    @Test("a message that has not failed carries no failure detail")
    func nonFailedHasNoDetail() {
        let message = Self.streaming()

        #expect(message.failure == nil)
        #expect(message.withStatus(.complete).failure == nil)
    }

    @Test("moving off failed clears the detail")
    func leavingFailedClearsDetail() {
        // A retry that succeeds must not keep "failed 8 minutes in" attached.
        // Stale progress on a completed message reads as a fresh failure.
        let failed = Self.streaming().failed(
            TurnFailure(failedAtMs: 480_000, toolCallsCompleted: 3)
        )

        #expect(failed.withStatus(.complete).failure == nil)
        #expect(failed.withStatus(.streaming).failure == nil)
    }

    @Test("appending cannot resurrect a failed message")
    func appendingIsNoOpOnFailed() {
        // `.failed` is terminal, so a late frame from the dead connection must
        // not reopen it — and must not silently drop the failure detail either.
        let failed = Self.streaming().failed(
            TurnFailure(failedAtMs: 480_000, toolCallsCompleted: 3)
        )

        let after = failed.appending("more")

        #expect(after == failed)
        #expect(after.failure?.failedAtMs == 480_000)
    }

    @Test("failure detail survives Codable — the relaunch case")
    func failureSurvivesRoundTrip() throws {
        // This is the reason the field exists: force-quit, relaunch, and the
        // user still learns it ran 8 minutes and completed 3 tool calls.
        let failed = Self.streaming().failed(
            TurnFailure(failedAtMs: 480_000, toolCallsCompleted: 3)
        )

        let data = try JSONEncoder().encode(failed)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == failed)
        #expect(decoded.failure?.toolCallsCompleted == 3)
    }

    @Test("messages stored before the field existed still decode")
    func decodesLegacyPayload() throws {
        // SessionStore has rows written before `failure` existed. Failing on
        // them would lose the user's transcript on upgrade.
        let legacy = """
        {"id":"\(UUID().uuidString)","role":"assistant","text":"hi",
         "createdAt":0,"status":"complete"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Message.self, from: legacy)

        #expect(decoded.failure == nil)
        #expect(decoded.status == .complete)
    }

    @Test("a failed message is still retryable")
    func failedRemainsRetryable() {
        // The progress detail informs the decision; it does not remove it.
        let failed = Self.streaming().failed(
            TurnFailure(failedAtMs: 480_000, toolCallsCompleted: 3)
        )

        #expect(failed.isRetryable)
        #expect(failed.isTerminal)
    }
}

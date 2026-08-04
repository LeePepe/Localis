import Foundation
import Testing

@testable import BridgeAdapters

/// When a failed turn may be retried without `--resume`.
///
/// **Every test here that expects `false` is the point of the type.** The
/// retry exists to spare the user a dead conversation; the guard exists to
/// stop a message being executed twice on their machine. The second is the
/// larger harm, so the default answer is no.
@Suite("ResumeFailure — retry only on proof")
struct ResumeFailureTests {
    /// The real frame, from a live run against an id no conversation has.
    ///
    /// Recorded 2026-08-04. Kept verbatim rather than minimised: this is the
    /// only shape the retry is allowed to fire on, so the test that admits it
    /// should be the observed one, not a tidied version that might have dropped
    /// the field the CLI actually keys on.
    private static func observedFrame() -> [String: Any] {
        [
            "type": "result",
            "subtype": "error_during_execution",
            "is_error": true,
            "num_turns": 0,
            "session_id": "00000000-dead-4000-8000-000000000000",
            "errors": ["No conversation found with session ID: 00000000-dead-4000-8000-000000000000"],
        ]
    }

    @Test("the observed resume failure is retryable")
    func observedFailureRetries() {
        #expect(ResumeFailure.isRetryableWithoutResume(frame: Self.observedFrame()))
    }

    /// A successful turn is never retried, whatever else it says.
    @Test("a success is not retryable")
    func successIsNotRetryable() {
        var frame = Self.observedFrame()
        frame["is_error"] = false

        #expect(!ResumeFailure.isRetryableWithoutResume(frame: frame))
    }

    /// **The load-bearing test.** A failure that reached the machine must not
    /// be retried: the CLI can run commands, and a second run would run them
    /// again. `num_turns > 0` is the CLI saying it did work.
    @Test("a failure that already ran turns is not retryable", arguments: [1, 2, 17])
    func startedTurnsAreNotRetryable(turns: Int) {
        var frame = Self.observedFrame()
        frame["num_turns"] = turns

        #expect(
            !ResumeFailure.isRetryableWithoutResume(frame: frame),
            "a turn that ran \(turns) turn(s) would be executed a second time"
        )
    }

    /// Absent is not zero. A frame that never mentions `num_turns` has told us
    /// nothing about whether work happened, and nothing is not proof.
    @Test("a missing turn count is not retryable")
    func missingTurnCountIsNotRetryable() {
        var frame = Self.observedFrame()
        frame.removeValue(forKey: "num_turns")

        #expect(!ResumeFailure.isRetryableWithoutResume(frame: frame))
    }

    /// A different failure at zero turns — an outage, a killed process, a
    /// refused login — is not a missing conversation and gets no retry.
    @Test("another zero-turn failure is not retryable", arguments: [
        "Credit balance is too low",
        "Connection error",
        "Invalid API key",
        "",
    ])
    func otherFailuresAreNotRetryable(message: String) {
        var frame = Self.observedFrame()
        frame["errors"] = [message]

        #expect(
            !ResumeFailure.isRetryableWithoutResume(frame: frame),
            "'\(message)' was treated as a missing conversation"
        )
    }

    /// The message must be the CLI's, in the CLI's field. A conversation whose
    /// *content* quotes the sentence is not the CLI reporting it.
    @Test("the sentence somewhere other than the errors array is not retryable")
    func sentenceElsewhereIsNotRetryable() {
        var frame = Self.observedFrame()
        frame.removeValue(forKey: "errors")
        frame["result"] = "No conversation found with session ID: whatever"

        #expect(!ResumeFailure.isRetryableWithoutResume(frame: frame))
    }
}

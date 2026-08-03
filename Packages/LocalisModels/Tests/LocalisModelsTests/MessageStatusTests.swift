import Foundation
import Testing

@testable import LocalisModels

/// The message state machine has to answer one question honestly: when the user
/// comes back to the app, what happened to the answer that was in flight?
///
/// Three outcomes, and conflating any two of them is a real bug:
/// - the stream finished while away  → `complete`
/// - it is still running on the host → `detached` (Amendment C §1.5)
/// - it died and the text is gone    → `interrupted`
@Suite("MessageStatus")
struct MessageStatusTests {
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private static func streamingMessage(text: String = "partial") -> Message {
        Message(id: UUID(), role: .assistant, text: text, createdAt: Self.date, status: .streaming)
    }

    @Test("a stream that finished while the app was away lands on complete")
    func finishedWhileAwayIsComplete() {
        let detached = Self.streamingMessage().detached()

        let resumed = detached.appending(" and the rest").withStatus(.complete)

        #expect(resumed.status == .complete)
        #expect(resumed.text == "partial and the rest")
    }

    @Test("a stream still running on the host is detached, not interrupted")
    func stillRunningIsDetached() {
        // Amendment C §1.5: this is the dangerous conflation. If a live turn is
        // labelled `interrupted` the UI offers "retry" and the user starts a
        // *second* generation on the host.
        let detached = Self.streamingMessage().detached()

        #expect(detached.status == .detached)
        #expect(!detached.isRetryable)
        #expect(detached.isInFlight)
        #expect(detached.text == "partial")
    }

    @Test("a stream that died mid-way is interrupted and retryable")
    func diedMidwayIsInterrupted() {
        // FR-019: partial text is kept, never silently dropped, and the user is
        // offered a retry because nothing is still running.
        let interrupted = Self.streamingMessage().interrupted()

        #expect(interrupted.status == .interrupted)
        #expect(interrupted.isRetryable)
        #expect(!interrupted.isInFlight)
        #expect(interrupted.text == "partial")
    }

    @Test("a truncated resume is interrupted, not complete")
    func truncatedResumeIsInterrupted() {
        // Amendment C §1.6: when the bridge's buffer overflowed we say the text
        // is incomplete. Better to admit a gap than to present a truncated
        // answer as finished.
        let detached = Self.streamingMessage().detached()

        let truncated = detached.interrupted()

        #expect(truncated.status == .interrupted)
        #expect(truncated.isRetryable)
    }

    @Test("failure is terminal and retryable, and keeps the text already read")
    func failureKeepsPartialText() {
        let failed = Self.streamingMessage().withStatus(.failed)

        #expect(failed.status == .failed)
        #expect(failed.isTerminal)
        #expect(failed.isRetryable)
        #expect(failed.text == "partial")
    }

    @Test("only complete and failed are terminal")
    func terminalStates() {
        #expect(MessageStatus.complete.isTerminal)
        #expect(MessageStatus.failed.isTerminal)
        #expect(!MessageStatus.streaming.isTerminal)
        #expect(!MessageStatus.detached.isTerminal)
        #expect(!MessageStatus.pending.isTerminal)
        // `interrupted` is not terminal: the turn can be retried and the
        // message superseded.
        #expect(!MessageStatus.interrupted.isTerminal)
    }

    @Test("only interrupted and failed offer a retry")
    func retryableStates() {
        // The safety property: never offer retry for anything the host might
        // still be working on.
        #expect(MessageStatus.interrupted.isRetryable)
        #expect(MessageStatus.failed.isRetryable)
        #expect(!MessageStatus.detached.isRetryable)
        #expect(!MessageStatus.streaming.isRetryable)
        #expect(!MessageStatus.complete.isRetryable)
        #expect(!MessageStatus.pending.isRetryable)
    }

    @Test("appending to a detached message resumes streaming")
    func appendingResumesStreaming() {
        // Reconnecting and replaying from the cursor puts the message back into
        // `streaming` — content is arriving again.
        let resumed = Self.streamingMessage().detached().appending("more")

        #expect(resumed.status == .streaming)
        #expect(resumed.text == "partialmore")
    }

    @Test("appending never resurrects a terminal message")
    func appendingIsIgnoredAfterTerminalState() {
        // Guards the duplicate-stream hazard in Amendment C §5 (principle II):
        // after a resume, a late frame from the old connection must not reopen a
        // finished message.
        let complete = Self.streamingMessage(text: "done").withStatus(.complete)

        let late = complete.appending(" oops")

        #expect(late == complete)
    }

    @Test("every status round-trips through Codable")
    func codableRoundTrip() throws {
        for status: MessageStatus in [.pending, .streaming, .detached, .interrupted, .complete, .failed] {
            let decoded = try JSONDecoder().decode(
                MessageStatus.self,
                from: try JSONEncoder().encode(status)
            )
            #expect(decoded == status)
        }
    }

    @Test("wire values are stable — persisted rows must survive an app update")
    func wireValuesAreStable() {
        #expect(MessageStatus.detached.rawValue == "detached")
        #expect(MessageStatus.interrupted.rawValue == "interrupted")
        #expect(MessageStatus.complete.rawValue == "complete")
    }
}

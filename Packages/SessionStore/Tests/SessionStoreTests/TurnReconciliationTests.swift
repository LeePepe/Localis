import Foundation
import Testing

@testable import SessionStore

/// What the store knows about a turn when the app comes back (Amendment C §1.5).
///
/// The dangerous conflation this suite guards against: `detached` (the link
/// dropped but the host is still generating) and `interrupted` (the content is
/// genuinely gone). Offering "retry" on a `detached` turn runs a *second* job on
/// the user's machine — so the two must never collapse into one state.
@Suite("Turn reconciliation on return")
struct TurnReconciliationTests {
    private static func cursor(_ seq: Int) -> ResumeCursor {
        ResumeCursor(turnID: "turn-1", lastSeq: seq)
    }

    @Test("a completed turn needs nothing on return")
    func completeIsSettled() {
        #expect(TurnReconciliation.resolve(state: .complete, cursor: nil) == .settled)
        #expect(TurnReconciliation.resolve(state: .complete, cursor: Self.cursor(4)) == .settled)
    }

    @Test("a failed turn is settled — it already told the user it failed")
    func failedIsSettled() {
        #expect(TurnReconciliation.resolve(state: .failed, cursor: nil) == .settled)
    }

    @Test("a detached turn with a cursor resumes from that cursor")
    func detachedResumes() {
        let resumed = TurnReconciliation.resolve(state: .detached, cursor: Self.cursor(11))

        #expect(resumed == .stillRunning(Self.cursor(11)))
    }

    @Test("an interrupted turn is lost and may be retried")
    func interruptedIsLost() {
        #expect(TurnReconciliation.resolve(state: .interrupted, cursor: Self.cursor(3)) == .lost)
    }

    @Test("a turn left streaming by a killed process is not still streaming")
    func streamingDoesNotSurviveRestart() {
        // The stream lived in a process that no longer exists. With a cursor the
        // host may still be working; without one there is nothing to resume from.
        #expect(TurnReconciliation.resolve(state: .streaming, cursor: Self.cursor(2)) == .stillRunning(Self.cursor(2)))
        #expect(TurnReconciliation.resolve(state: .streaming, cursor: nil) == .lost)
    }

    @Test("a detached turn without a cursor is lost, not silently resumable")
    func detachedWithoutCursorIsLost() {
        #expect(TurnReconciliation.resolve(state: .detached, cursor: nil) == .lost)
    }

    @Test("only a lost turn may offer retry — running turns must not")
    func retryIsOfferedOnlyWhenContentIsGone() {
        #expect(TurnReconciliation.lost.allowsRetry)
        #expect(!TurnReconciliation.stillRunning(Self.cursor(1)).allowsRetry)
        #expect(!TurnReconciliation.settled.allowsRetry)
    }

    @Test("every delivery state resolves — no unhandled case")
    func allStatesResolve() {
        for state in StoredDeliveryState.allCases {
            _ = TurnReconciliation.resolve(state: state, cursor: Self.cursor(1))
        }
    }
}

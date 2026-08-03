import Foundation
import Testing

@testable import SessionStore

import LocalisModels

/// The store's answer to "what happened while the app was away" (Amendment C
/// §1.5). Several of the outcomes look similar and mean very different things,
/// so each one is pinned here.
@Suite("Turn reconciliation")
struct TurnReconciliationTests {
    private static let cursor = TurnCursor(turnID: "turn-1", lastSeq: 7)

    @Test("a completed turn needs nothing on return")
    func completeIsSettled() {
        #expect(TurnReconciliation.resolve(state: .complete, cursor: nil) == .settled)
    }

    @Test("a failed turn reports how far it got, not just that it failed")
    func failedCarriesDetail() {
        let failure = TurnFailure(failedAtMs: 480_000, toolCallsCompleted: 3)

        let outcome = TurnReconciliation.resolve(state: .failed, cursor: nil, failure: failure)

        // "failed 8 minutes in, after 3 tool calls" — the detail the user needs
        // to decide whether retrying is worth it.
        #expect(outcome == .failed(failure))
    }

    @Test("a failure with no recorded detail does not invent one")
    func failedWithoutDetailIsSettled() {
        // A zeroed TurnFailure would render as "failed 0 minutes in, after 0
        // tool calls" — a number nobody reported.
        #expect(TurnReconciliation.resolve(state: .failed, cursor: nil) == .settled)
    }

    @Test("a detached turn with a cursor resumes from that cursor")
    func detachedWithCursorResumes() {
        #expect(
            TurnReconciliation.resolve(state: .detached, cursor: Self.cursor)
                == .stillRunning(Self.cursor)
        )
    }

    @Test("a detached turn without a cursor is lost, not silently resumable")
    func detachedWithoutCursorIsLost() {
        #expect(TurnReconciliation.resolve(state: .detached, cursor: nil) == .lost)
    }

    @Test("a turn left streaming by a killed process is not still streaming")
    func streamingResolvesLikeDetached() {
        // Reaching reconciliation at all means the process that owned the stream
        // is gone, so `streaming` can only mean resumable or lost.
        #expect(
            TurnReconciliation.resolve(state: .streaming, cursor: Self.cursor)
                == .stillRunning(Self.cursor)
        )
        #expect(TurnReconciliation.resolve(state: .streaming, cursor: nil) == .lost)
    }

    @Test("an interrupted turn is lost and may be retried")
    func interruptedIsLost() {
        let outcome = TurnReconciliation.resolve(state: .interrupted, cursor: Self.cursor)

        // Even with a cursor: interrupted means the content is gone, so there is
        // nothing left on the host to resume from.
        #expect(outcome == .lost)
        #expect(outcome.allowsRetry)
    }

    @Test("a running turn must never offer retry")
    func onlyFinishedTurnsAllowRetry() {
        // Retrying a turn the host is still generating starts a second run on
        // the user's machine — a real side effect, not a display difference.
        #expect(TurnReconciliation.stillRunning(Self.cursor).allowsRetry == false)
        #expect(TurnReconciliation.settled.allowsRetry == false)
        #expect(TurnReconciliation.lost.allowsRetry)
        #expect(
            TurnReconciliation.failed(TurnFailure(failedAtMs: 1, toolCallsCompleted: 0)).allowsRetry
        )
    }

    @Test("every delivery state resolves — no unhandled case")
    func everyStateResolves() {
        for state in StoredDeliveryState.allCases {
            _ = TurnReconciliation.resolve(state: state, cursor: Self.cursor)
            _ = TurnReconciliation.resolve(state: state, cursor: nil)
        }
    }
}

/// `TurnFailure` is the difference between "Error" and "failed 8 minutes in,
/// after 3 tool calls" (contract §3.1(d)).
@Suite("Turn failure detail")
struct TurnFailureTests {
    @Test("failure detail survives a round trip")
    func roundTrips() throws {
        let failure = TurnFailure(failedAtMs: 480_000, toolCallsCompleted: 3)

        let data = try JSONEncoder().encode(failure)
        let decoded = try JSONDecoder().decode(TurnFailure.self, from: data)

        #expect(decoded == failure)
    }

    @Test("a malformed negative value is clamped rather than dropping the record")
    func negativesAreClamped() {
        // Losing the whole record over one bad number would leave the bare
        // "Error" this type exists to prevent.
        let failure = TurnFailure(failedAtMs: -1, toolCallsCompleted: -5)

        #expect(failure.failedAtMs == 0)
        #expect(failure.toolCallsCompleted == 0)
    }

    @Test("a turn that failed before any tool call is still a valid record")
    func zeroToolCallsIsValid() {
        let failure = TurnFailure(failedAtMs: 1_200, toolCallsCompleted: 0)

        #expect(failure.toolCallsCompleted == 0)
        #expect(failure.failedAtMs == 1_200)
    }
}

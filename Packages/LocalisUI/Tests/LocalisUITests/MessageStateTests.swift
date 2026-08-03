import Foundation
import Testing

@testable import LocalisUI

import LocalisModels

/// The third layer of the `detached` defence (Amendment C §1.5).
///
/// `core` guarantees `detached.isRetryable == false` and `store` only allows
/// retry on `.lost` / `.failed`. This layer's job is that the control is not
/// *rendered* — the design contract's rule 8 is explicit that restyling is not
/// enough, because a mis-tap on a disabled-looking button that still fires
/// starts a second generation on the user's Mac.
@Suite("Message state projection")
struct MessageStateTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private static func message(
        _ status: MessageStatus,
        text: String = "partial",
        failure: TurnFailure? = nil
    ) -> Message {
        Message(
            id: UUID(), role: .assistant, text: text,
            createdAt: t0, status: status, failure: failure
        )
    }

    @Test("a detached turn offers no retry action at all")
    func detachedHasNoRetryAction() {
        let state = MessageState.make(from: Self.message(.detached))

        // Not `.disabled`, not `.confirming` — absent. An action that exists in
        // the model is an action a view can be asked to draw.
        #expect(state.actions.contains(.retry) == false)
        // Cancel is the honest offer: the host is still working.
        #expect(state.actions.contains(.cancel))
    }

    @Test("an interrupted turn offers retry, because nothing is still running")
    func interruptedOffersRetry() {
        let state = MessageState.make(from: Self.message(.interrupted))

        #expect(state.actions.contains(.retry))
        #expect(state.actions.contains(.cancel) == false)
    }

    @Test("a failed turn offers retry and no cancel")
    func failedOffersRetry() {
        let state = MessageState.make(from: Self.message(.failed))

        #expect(state.actions.contains(.retry))
        #expect(state.actions.contains(.cancel) == false)
    }

    @Test("a streaming turn offers cancel but never retry")
    func streamingOffersCancelOnly() {
        let state = MessageState.make(from: Self.message(.streaming))

        #expect(state.actions.contains(.retry) == false)
        #expect(state.actions.contains(.cancel))
    }

    @Test("no in-flight status ever offers retry")
    func inFlightNeverRetryable() {
        // The safety property stated once over the whole enum, so a status added
        // later cannot quietly land on the wrong side of it.
        for status in MessageStatus.allCases where status.isInFlight {
            let state = MessageState.make(from: Self.message(status))
            #expect(state.actions.contains(.retry) == false, "\(status) offered retry")
        }
    }

    @Test("retry is offered exactly when the domain says it is retryable")
    func retryMatchesDomain() {
        // The view must not invent its own answer to a question core already
        // decides — three layers agreeing only helps if they agree by deriving
        // from the same rule rather than by coincidence.
        for status in MessageStatus.allCases {
            let state = MessageState.make(from: Self.message(status))
            #expect(state.actions.contains(.retry) == status.isRetryable, "\(status)")
        }
    }

    @Test("retry and cancel are never offered together")
    func retryAndCancelAreMutuallyExclusive() {
        // This guards the premise the two quantified tests above share.
        //
        // `actions(for:)` asks two questions independently — `isRetryable` for
        // retry, `isInFlight` for cancel — and the set is only ever a sensible
        // pair because those two predicates happen to be disjoint today. Nothing
        // states that. If a status is ever both, this layer would draw "Retry"
        // and "Stop" on the same turn, and `inFlightNeverRetryable` would fail
        // in a way that reads as a UI bug rather than as the domain having
        // changed shape underneath it.
        //
        // Asserted through the projection rather than on the predicates, because
        // it is the *pair of controls* that must not coexist — that is the harm,
        // and it survives a rename of either question.
        for status in MessageStatus.allCases {
            let actions = MessageState.make(from: Self.message(status)).actions
            #expect(
                !(actions.contains(.retry) && actions.contains(.cancel)),
                "\(status) offered both retry and cancel"
            )
        }
    }

    @Test("every status offers at least one action or none, never an unhandled one")
    func actionsAreOnlyEverDerivedFromTheTwoQuestions() {
        // The set is closed: it holds only what `isRetryable` and `isInFlight`
        // put there. A third control added to `MessageAction` without a rule to
        // grant it would sit unreachable — visible in the enum, never rendered —
        // which is a quieter failure than a compile error.
        for action in MessageAction.allCases {
            let granted = MessageStatus.allCases.contains { status in
                MessageState.make(from: Self.message(status)).actions.contains(action)
            }
            #expect(granted, "\(action) is never granted by any status")
        }
    }

    // MARK: - Failure detail

    @Test("a failure with detail says how far it got")
    func failureDetailIsRendered() {
        let state = MessageState.make(
            from: Self.message(.failed, failure: TurnFailure(failedAtMs: 480_000, toolCallsCompleted: 3))
        )

        #expect(state.failureDetail == FailureDetail(elapsed: 480, toolCalls: 3))
    }

    @Test("a failure with no recorded detail renders no detail at all")
    func failureWithoutDetailInventsNothing() {
        // Rule 7 of the design contract: a value the backend never reported
        // makes its row disappear. A zeroed detail would read as "failed
        // instantly, after 0 tool calls" — a claim nobody made.
        let state = MessageState.make(from: Self.message(.failed))

        #expect(state.failureDetail == nil)
    }

    @Test("a non-failed message never carries failure detail")
    func onlyFailedCarriesDetail() {
        for status in MessageStatus.allCases where status != .failed {
            let state = MessageState.make(from: Self.message(status))
            #expect(state.failureDetail == nil, "\(status)")
        }
    }

    // MARK: - Partial text

    @Test("an interrupted turn keeps the text that already arrived")
    func interruptedKeepsPartialText() {
        // FR-019: what the user already read does not vanish because the rest
        // was lost.
        let state = MessageState.make(from: Self.message(.interrupted, text: "half an answ"))

        #expect(state.text == "half an answ")
        #expect(state.isTruncated)
    }

    @Test("a completed turn is not marked truncated")
    func completeIsNotTruncated() {
        #expect(MessageState.make(from: Self.message(.complete)).isTruncated == false)
    }
}

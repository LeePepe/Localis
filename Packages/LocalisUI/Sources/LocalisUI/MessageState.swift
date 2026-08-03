import Foundation
import LocalisModels

/// Something the user can do to a turn.
///
/// Modelled as a set on `MessageState` rather than as booleans on the view,
/// because the `detached` rule is about *absence*: contract rule 8 says a
/// detached turn "must not render a retry control at all — restyling it would
/// still let a mis-tap start a second job on the user's machine". A `Set` can
/// express absence; an `isRetryEnabled: Bool` cannot — it still hands the view a
/// button to draw.
public enum MessageAction: String, Hashable, Sendable, CaseIterable {
    /// Ask for the turn again. Only ever offered when nothing is still running.
    case retry
    /// Stop a turn the host is still working on.
    case cancel

    /// SF Symbol from the design contract §11. Named here so no `body` picks one.
    public var systemImage: String {
        switch self {
        case .retry: return "arrow.clockwise"
        case .cancel: return "stop.fill"
        }
    }

    public var title: String {
        switch self {
        case .retry: return String(localized: "Retry")
        case .cancel: return String(localized: "Stop")
        }
    }
}

/// How far a failed turn got, ready to render (contract §3.1(d)).
///
/// Only ever constructed from a `TurnFailure` the host actually sent. There is
/// no "unknown" case and no zero default: rule 7 of the design contract is that
/// a value the backend never reported makes its row disappear, and a zeroed
/// detail would read as "failed instantly, after 0 tool calls" — a claim nobody
/// made.
public struct FailureDetail: Hashable, Sendable {
    /// Seconds from the start of the turn to the failure.
    public let elapsed: TimeInterval
    /// Tool calls that finished first. Zero is a real answer here, because the
    /// host reported it.
    public let toolCalls: Int

    public init(elapsed: TimeInterval, toolCalls: Int) {
        self.elapsed = elapsed
        self.toolCalls = toolCalls
    }

    /// "8 minutes" — coarse on purpose; the exact millisecond helps nobody.
    public var elapsedDescription: String {
        Duration.seconds(elapsed).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)
        )
    }

    /// The whole sentence: "failed 8 minutes in, after 3 tool calls".
    ///
    /// Assembled here rather than in a `body` so the wording is unit-testable —
    /// this string is the entire difference between an actionable failure and
    /// the bare "Error" the contract forbids.
    public var summary: String {
        let calls = toolCalls == 1
            ? String(localized: "1 tool call")
            : String(localized: "\(toolCalls) tool calls")
        return String(localized: "failed \(elapsedDescription) in, after \(calls)")
    }
}

/// View-ready projection of one `Message` in a transcript.
///
/// Pure value type, like `SessionRowState`: everything worth asserting about a
/// turn — which controls exist, whether the text is a fragment, what the failure
/// says — is decided here and unit-tested, so the view has nothing left to get
/// wrong.
public struct MessageState: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: MessageRole
    /// Whatever text arrived, including a partial answer (FR-019).
    public let text: String
    public let status: MessageStatus
    /// Exactly the controls this turn may show. See `MessageAction`.
    public let actions: Set<MessageAction>
    /// Present only when the host reported how far the turn got.
    public let failureDetail: FailureDetail?
    /// The text is a fragment — the rest was lost, not merely still coming.
    public let isTruncated: Bool

    public init(
        id: UUID,
        role: MessageRole,
        text: String,
        status: MessageStatus,
        actions: Set<MessageAction>,
        failureDetail: FailureDetail?,
        isTruncated: Bool
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.status = status
        self.actions = actions
        self.failureDetail = failureDetail
        self.isTruncated = isTruncated
    }

    public static func make(from message: Message) -> MessageState {
        MessageState(
            id: message.id,
            role: message.role,
            text: message.text,
            status: message.status,
            actions: actions(for: message.status),
            failureDetail: message.failure.map {
                FailureDetail(elapsed: $0.elapsed, toolCalls: $0.toolCallsCompleted)
            },
            // `detached` is not truncated: the host still has the rest of it.
            isTruncated: message.status == .interrupted
        )
    }

    /// The controls a status earns.
    ///
    /// Both answers are delegated to `MessageStatus`, deliberately. This is the
    /// third of three layers enforcing the `detached` rule — core refuses to call
    /// it retryable, the store refuses to reconcile it as retryable, and this
    /// refuses to draw the control. Three layers only help if they agree by
    /// deriving from one rule instead of by coincidence, so nothing here
    /// re-decides "is detached safe to retry"; it asks.
    private static func actions(for status: MessageStatus) -> Set<MessageAction> {
        var actions: Set<MessageAction> = []
        if status.isRetryable { actions.insert(.retry) }
        if status.isInFlight { actions.insert(.cancel) }
        return actions
    }
}

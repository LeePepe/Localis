import Foundation

/// One event as it goes out on a turn's stream (contract §3.1).
///
/// Modelled as a closed enum on this side even though the client treats the
/// wire format as open. The asymmetry is intentional: the client must survive
/// events it has never heard of, whereas the bridge is the party that decides
/// what exists. An open type here would only let a caller invent a frame that
/// no version of the contract describes.
public enum BridgeEvent: Sendable, Hashable {
    /// A piece of assistant text. The overwhelmingly common case.
    case delta(String)
    /// The turn's stop reason, in OpenAI's `finish_reason` vocabulary.
    case finished(reason: String)
    /// Token counts, sent before `[DONE]` when the backend reports them
    /// (contract §3.4a — SHOULD, because a CLI may not know).
    case usage(TokenUsage)
    /// A tool starting or finishing (§3.1a).
    case toolCall(ToolCallEvent)
    /// A tool call awaiting the user's decision (§3.1b).
    case approvalRequired(ApprovalEvent)
    /// A human-readable activity phrase. Open vocabulary (§3.4c).
    case sessionStatus(String)
    /// The open telemetry envelope (§3.4b).
    case telemetry([String: TelemetryValue])
    /// How the turn ended (§3.1d).
    case turnEnd(TurnEndEvent)
    /// The `[DONE]` sentinel that closes the stream.
    case done
}

/// An event with its position in the turn.
///
/// `seq` is per-turn and monotonic from 0 (contract §3.3). It is what lets a
/// client that dropped off the network say "I have through 42" and get exactly
/// what it missed — so it is not decoration on the payload, it is the payload's
/// address.
public struct SequencedEvent: Sendable, Hashable {
    public let seq: Int?
    public let event: BridgeEvent

    /// - Parameter seq: nil only for `[DONE]`, which is a sentinel rather than
    ///   a numbered event and therefore has nothing to resume from.
    public init(seq: Int?, event: BridgeEvent) {
        self.seq = seq
        self.event = event
    }
}

/// Token counts for one turn (contract §3.4a).
public struct TokenUsage: Sendable, Hashable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    /// Nothing worth sending. The client renders the block only when data
    /// exists, so an all-nil report would be an empty slot implying data is on
    /// its way (FR-059).
    public var isEmpty: Bool {
        promptTokens == nil && completionTokens == nil && totalTokens == nil
    }
}

/// A tool call crossing a lifecycle boundary (contract §3.1a).
public struct ToolCallEvent: Sendable, Hashable {
    /// Which lifecycle edge this frame reports.
    public enum Phase: String, Sendable, Hashable {
        case start
        case end
    }

    /// How a call finished.
    public enum Outcome: String, Sendable, Hashable {
        case ok
        case error
        case cancelled
        case denied
    }

    /// **The correlation key.** Concurrent tool calls interleave on the wire,
    /// so without it the client cannot match an `end` to its `start` — the
    /// single most load-bearing field in this event.
    public let callID: String
    public let phase: Phase
    /// Display only. The client is forbidden from branching on it
    /// (constitution IV), so it carries no meaning beyond the label.
    public let tool: String
    /// A one-line human summary. **Must not contain absolute paths, message
    /// bodies or tokens** — abbreviating is this side's job (constitution I).
    public let summary: String?
    public let outcome: Outcome?
    public let durationMs: Int?

    public init(
        callID: String,
        phase: Phase,
        tool: String,
        summary: String? = nil,
        outcome: Outcome? = nil,
        durationMs: Int? = nil
    ) {
        self.callID = callID
        self.phase = phase
        self.tool = tool
        self.summary = summary
        self.outcome = outcome
        self.durationMs = durationMs
    }
}

/// A tool call the user must approve (contract §3.1b).
public struct ApprovalEvent: Sendable, Hashable {
    public let approvalID: String
    public let tool: String
    public let summary: String?

    public init(approvalID: String, tool: String, summary: String? = nil) {
        self.approvalID = approvalID
        self.tool = tool
        self.summary = summary
    }
}

/// How a turn ended (contract §3.1d).
public struct TurnEndEvent: Sendable, Hashable {
    public enum Outcome: String, Sendable, Hashable {
        case completed
        case failed
        case cancelled
    }

    public let turnID: String
    public let outcome: Outcome
    /// Milliseconds from turn start to failure. **Required when `outcome` is
    /// `failed`** — it is half of what makes the failure actionable rather than
    /// a shrug (FR-058).
    public let failedAtMs: Int?
    /// Tool calls that completed before the failure. The other half.
    public let toolCallsCompleted: Int?
    /// A code from the contract's §6 vocabulary. Never a message: the client
    /// maps codes to its own wording, and a message could carry a path
    /// (constitution I).
    public let errorCode: String?

    public init(
        turnID: String,
        outcome: Outcome,
        failedAtMs: Int? = nil,
        toolCallsCompleted: Int? = nil,
        errorCode: String? = nil
    ) {
        self.turnID = turnID
        self.outcome = outcome
        self.failedAtMs = failedAtMs
        self.toolCallsCompleted = toolCallsCompleted
        self.errorCode = errorCode
    }
}

/// A value in the open telemetry envelope (contract §3.4b).
///
/// The envelope is free-form by design — the point is that a new key needs no
/// iOS release. This type bounds only the *shapes* JSON can hold, never the
/// keys.
public enum TelemetryValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

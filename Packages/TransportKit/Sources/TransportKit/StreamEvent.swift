import Foundation

/// One thing that happened during a turn, in the app's own vocabulary.
///
/// This is the **only** stream type that leaves `TransportKit`. Wire shapes —
/// `chat.completion.chunk`, `x_localis` envelopes, `[DONE]` — stay internal, so
/// changing how the bridge encodes an event does not ripple into the layers
/// above (plan §1.1).
///
/// Nothing here names a backend, and nothing above may branch on one:
/// constitution IV makes backends data, delivered by `/v1/models`.
public enum StreamEvent: Hashable, Sendable {
    /// A piece of assistant text. Append it; do not assume word or line breaks.
    case delta(String)
    /// A tool started or finished. Pair by `callID` — concurrent calls interleave.
    case toolCall(ToolCall)
    /// The host is asking whether a tool may run.
    case approvalRequired(ApprovalRequest)
    /// A human-readable activity phrase. **Open value set** (contract §3.4c):
    /// show it verbatim, never match against a closed list.
    case sessionStatus(String)
    /// Free key-values for readouts. Unknown keys are carried, not filtered —
    /// the UI decides what it can render (contract §3.4b).
    case telemetry([String: TelemetryValue])
    /// Token counts, when the host can supply them. Absent for backends that
    /// cannot; nothing is invented (contract §3.4a).
    case usage(TokenUsage)
    /// The model stopped. Open reason string — `stop`, `length`, or a value that
    /// did not exist when this shipped.
    case finished(reason: String)
    /// How the whole turn ended, with progress attached when it failed.
    case turnEnd(TurnEnd)
    /// The stream closed normally (`data: [DONE]`).
    case done
}

/// A `StreamEvent` with the resume cursor it arrived under.
///
/// `seq` rides alongside the event rather than inside each case: dedup on
/// resume is then one comparison in one place, instead of a `switch` that has to
/// be extended every time an event is added — the shape where a new case
/// silently gets no dedup (Amendment C §3.3).
///
/// Optional because a host without `resumable_turns` never sends it.
public struct SequencedEvent: Hashable, Sendable {
    public let seq: Int?
    public let event: StreamEvent

    public init(seq: Int?, event: StreamEvent) {
        self.seq = seq
        self.event = event
    }
}

/// One step in a tool's lifecycle (contract §3.1a).
public struct ToolCall: Hashable, Sendable {
    /// Pairs `start` with `end`. Required by the contract because concurrent
    /// calls interleave and nothing else can match the two frames.
    public let callID: String
    public let phase: Phase
    /// Display only. Branching on this would be a backend switch by another
    /// name (constitution IV).
    public let tool: String
    /// One human-readable line, abbreviated by the bridge. Never a full path.
    public let summary: String?
    /// Present on `end`.
    public let outcome: Outcome?
    /// Present on `end` when the bridge measured it; otherwise the client can
    /// subtract the two frames' arrival times.
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

    /// Deliberately closed: an unknown phase is dropped at the mapper rather
    /// than represented here. A future `progress` guessed as `start` or `end`
    /// would corrupt the pairing — a call shown as running forever, or one
    /// closed while it is still going.
    public enum Phase: String, Hashable, Sendable {
        case start
        case end
    }

    /// How a tool call ended.
    ///
    /// `unknown` keeps a value the client does not recognise instead of forcing
    /// it into `error`: reporting a success as a failure is worse than admitting
    /// the state has no name yet (contract §3.1a).
    public enum Outcome: Hashable, Sendable {
        case ok
        case error
        case cancelled
        case denied
        case unknown(String)

        init(wire: String) {
            switch wire {
            case "ok": self = .ok
            case "error": self = .error
            case "cancelled": self = .cancelled
            case "denied": self = .denied
            default: self = .unknown(wire)
            }
        }
    }
}

/// A pending permission request (contract §3.1b).
///
/// v1 must receive and display these without crashing; the full approval UI is
/// out of scope, so the seam exists and nothing more.
public struct ApprovalRequest: Hashable, Sendable {
    /// Needed to answer via `POST /v1/approvals/{approval_id}`.
    public let approvalID: String
    /// Display only.
    public let tool: String
    public let summary: String?

    public init(approvalID: String, tool: String, summary: String? = nil) {
        self.approvalID = approvalID
        self.tool = tool
        self.summary = summary
    }
}

/// A scalar from the open telemetry envelope (contract §3.4b).
///
/// Scalars only. A nested object has no readout to render it, and keeping the
/// raw JSON around would invite a caller to reach into it and re-introduce
/// exactly the field coupling the envelope exists to avoid.
public enum TelemetryValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
}

/// Token counts for a turn (contract §3.4a).
///
/// Every field is optional and a missing one stays `nil`: the contract forbids
/// showing `0` or any invented number, and forbids a placeholder slot — a slot
/// reading "unavailable" implies data is coming. No data, no block.
public struct TokenUsage: Hashable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?

    public init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    /// Whether anything at all is worth rendering.
    public var isEmpty: Bool {
        promptTokens == nil && completionTokens == nil && totalTokens == nil
    }
}

/// How a turn finished (Amendment C §3.1d).
///
/// This is what closes the loop on background resume: coming back, the three
/// possible fates — finished, still running, died while away — are all readable
/// from the stream instead of guessed.
public struct TurnEnd: Hashable, Sendable {
    /// Present when the bridge sent one; needed to resume or cancel.
    public let turnID: String?
    public let outcome: Outcome
    /// Milliseconds from turn start to failure. The contract makes this a MUST
    /// on failure so the user gets "failed after 8 minutes and 3 tool calls"
    /// rather than a bare "something went wrong".
    public let failedAtMs: Int?
    public let toolCallsCompleted: Int?
    /// The machine-readable `error.code`, mapped to UI text locally.
    ///
    /// The bridge's `error.message` is **not carried at all**. It may contain
    /// absolute paths (constitution I / FR-025), and a field that does not exist
    /// cannot be displayed by a future caller who did not read the contract.
    public let errorCode: String?

    public init(
        turnID: String?,
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

    /// Terminal states of a turn. `unknown` carries a value this build does not
    /// recognise rather than collapsing it into `failed`, which would report a
    /// turn that actually succeeded as broken.
    public enum Outcome: Hashable, Sendable {
        case completed
        case failed
        case cancelled
        case unknown(String)

        init(wire: String) {
            switch wire {
            case "completed": self = .completed
            case "failed": self = .failed
            case "cancelled": self = .cancelled
            default: self = .unknown(wire)
            }
        }
    }
}

import Foundation

/// Turns one SSE frame into a domain `StreamEvent`.
///
/// Everything the wire format knows stops here. Above this line the app sees
/// `StreamEvent` and nothing else (plan §1.1), so a change to how the bridge
/// encodes an event is a change to this file alone.
///
/// **A frame this mapper cannot make sense of returns `nil`, and the stream
/// keeps running.** That is not leniency for its own sake: constitution IV lets
/// the bridge add events, fields and values without an iOS release, so treating
/// anything unrecognised as fatal would take down turns that are otherwise fine
/// — and would do it on exactly the frames a newer bridge added.
///
/// Stateless, so a session can hold one and it stays `Sendable` for free.
public struct StreamEventMapper: Sendable {
    public init() {}

    /// The `data:` payload that ends a stream.
    private static let doneSentinel = "[DONE]"

    /// Maps `frame`, or returns nil if it carries nothing actionable.
    public func map(_ frame: SSEParser.Frame) -> SequencedEvent? {
        let payload = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)

        if frame.event == nil, payload == Self.doneSentinel {
            return SequencedEvent(seq: nil, event: .done)
        }

        guard let json = JSONValue(jsonText: payload) else {
            // A truncated or corrupt frame. Dropping one frame costs a few
            // characters; throwing would cost the whole turn.
            return nil
        }

        let seq = json["seq"]?.intValue

        guard let event = event(from: json, named: frame.event) else { return nil }
        return SequencedEvent(seq: seq, event: event)
    }

    // MARK: - Dispatch

    private func event(from json: JSONValue, named name: String?) -> StreamEvent? {
        // Named events are Localis extensions; unnamed frames are standard
        // OpenAI chunks. An unknown name is skipped (FR-010) — this is the rule
        // that lets a newer bridge talk to an older client.
        switch name {
        case nil: return chunk(from: json)
        case BridgeEventName.toolCall: return toolCall(from: json)
        case BridgeEventName.approvalRequired: return approval(from: json)
        case BridgeEventName.sessionStatus: return sessionStatus(from: json)
        case BridgeEventName.telemetry: return telemetry(from: json)
        case BridgeEventName.turnEnd: return turnEnd(from: json)
        default: return nil
        }
    }

    // MARK: - Standard OpenAI chunk

    /// Maps an unnamed frame: a content delta, a finish reason, or a usage
    /// report. The three are distinguished by which fields are present, since a
    /// chunk carrying only `usage` has an empty `choices` array.
    private func chunk(from json: JSONValue) -> StreamEvent? {
        if let usage = json["usage"], let mapped = tokenUsage(from: usage) {
            return .usage(mapped)
        }

        // Only the first choice is read: the client sends `n: 1` and a second
        // choice has nowhere to go in a single-turn transcript.
        guard let choice = json["choices"]?.arrayValue?.first else { return nil }

        if let content = choice["delta"]?["content"]?.stringValue, !content.isEmpty {
            return .delta(content)
        }
        if let reason = choice["finish_reason"]?.stringValue {
            return .finished(reason: reason)
        }

        // An empty delta: nothing to append, and appending "" would flip a
        // message into `streaming` for no reason.
        return nil
    }

    private func tokenUsage(from json: JSONValue) -> TokenUsage? {
        let usage = TokenUsage(
            promptTokens: json["prompt_tokens"]?.intValue,
            completionTokens: json["completion_tokens"]?.intValue,
            totalTokens: json["total_tokens"]?.intValue
        )
        // Nothing usable — better no event than an empty readout, which the
        // contract explicitly forbids rendering.
        return usage.isEmpty ? nil : usage
    }

    // MARK: - Localis extension events

    private func toolCall(from json: JSONValue) -> StreamEvent? {
        // Without `call_id` the frame cannot be paired with its partner, and
        // without `tool` there is nothing to show. Both are MUST in the
        // contract; a frame missing either is unusable rather than degraded.
        guard let callID = json["call_id"]?.stringValue, !callID.isEmpty,
              let tool = json["tool"]?.stringValue, !tool.isEmpty,
              let rawPhase = json["phase"]?.stringValue,
              // An unknown phase is dropped per contract §3.1a. Guessing it as
              // start or end would either strand a call as "running" forever or
              // close one that is still going.
              let phase = ToolCall.Phase(rawValue: rawPhase) else {
            return nil
        }

        return .toolCall(ToolCall(
            callID: callID,
            phase: phase,
            tool: tool,
            summary: json["summary"]?.stringValue,
            outcome: json["outcome"]?.stringValue.map(ToolCall.Outcome.init(wire:)),
            durationMs: json["duration_ms"]?.intValue
        ))
    }

    private func approval(from json: JSONValue) -> StreamEvent? {
        // Without the id there is no way to answer, so showing the prompt would
        // strand the user in front of a question with no working buttons.
        guard let approvalID = json["approval_id"]?.stringValue, !approvalID.isEmpty,
              let tool = json["tool"]?.stringValue, !tool.isEmpty else {
            return nil
        }

        return .approvalRequired(ApprovalRequest(
            approvalID: approvalID,
            tool: tool,
            summary: json["summary"]?.stringValue
        ))
    }

    private func sessionStatus(from json: JSONValue) -> StreamEvent? {
        // Open value set (contract §3.4c): whatever phrase the bridge sends is
        // the text to display. Validating it against a known list would reject
        // precisely the new phrases this event exists to carry.
        guard let status = json["status"]?.stringValue, !status.isEmpty else { return nil }
        return .sessionStatus(status)
    }

    private func telemetry(from json: JSONValue) -> StreamEvent? {
        guard let fields = json.objectValue else { return nil }

        var values: [String: TelemetryValue] = [:]
        for (key, value) in fields {
            // Framing, not a readout.
            guard !BridgeEventName.envelopeKeys.contains(key) else { continue }
            // Unknown *keys* are kept on purpose — that is the entire point of
            // the open envelope (contract §3.4b): the bridge adds `gpu_temp`
            // and iOS ships nothing. Only unrenderable *shapes* are skipped.
            guard let telemetryValue = value.telemetryValue else { continue }
            values[key] = telemetryValue
        }

        return values.isEmpty ? nil : .telemetry(values)
    }

    private func turnEnd(from json: JSONValue) -> StreamEvent? {
        // The outcome is the whole content of this event; without it there is
        // nothing to record.
        guard let rawOutcome = json["outcome"]?.stringValue, !rawOutcome.isEmpty else { return nil }

        return .turnEnd(TurnEnd(
            turnID: json["turn_id"]?.stringValue,
            outcome: TurnEnd.Outcome(wire: rawOutcome),
            failedAtMs: json["failed_at_ms"]?.intValue,
            toolCallsCompleted: json["tool_calls_completed"]?.intValue,
            // `error.code` only. `error.message` is read by nothing here: it may
            // contain absolute paths (constitution I / FR-025), and the surest
            // way to keep it off a screen is to never carry it inward.
            errorCode: json["error"]?["code"]?.stringValue
        ))
    }
}

/// Wire names for the Localis SSE extensions (contract §3.1).
///
/// String constants rather than an enum: an unknown name must fall through to
/// "skip and keep reading", and an enum invites an exhaustive `switch` that a
/// new bridge event would then have to break.
enum BridgeEventName {
    static let toolCall = "x-localis-tool-call"
    static let approvalRequired = "x-localis-approval-required"
    static let sessionStatus = "x-localis-session-status"
    static let telemetry = "x-localis-telemetry"
    static let turnEnd = "x-localis-turn-end"

    /// Keys that belong to the envelope rather than to any payload.
    static let envelopeKeys: Set<String> = ["seq", "session_id", "turn_id"]
}

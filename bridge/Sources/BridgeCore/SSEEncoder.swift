import Foundation

/// Encodes events into SSE frames (contract §3.1).
///
/// The one rule that shapes everything here: **content deltas are unnamed
/// frames, extensions are named ones.** A standard OpenAI client parses only
/// the unnamed `data:` frames, so keeping the Localis additions behind `event:`
/// names is what lets this bridge be OpenAI-compatible and Localis-aware at the
/// same time. Naming a delta frame would make it invisible to the very parser
/// meant to read it.
///
/// Hand-rolled JSON assembly rather than `Codable`, for two reasons: the
/// payload shape differs per case in ways a synthesised encoder expresses
/// awkwardly, and a frame must never contain a raw newline — which is a
/// property of the serialiser, not of the model.
public enum SSEEncoder {
    /// Serialises one event, terminator included.
    ///
    /// Returns a `String` rather than bytes because the caller writes it into a
    /// NIO buffer as UTF-8 anyway, and a string is what a test can read.
    public static func encode(_ event: SequencedEvent) -> String {
        if case .done = event.event {
            // A literal sentinel, not JSON. The client compares the payload
            // text directly; an object here would leave the stream looking
            // unterminated and be reported as a lost connection.
            return "data: [DONE]\n\n"
        }

        let name = eventName(for: event.event)
        var payload = body(for: event.event)

        // `seq` sits at the top level of every frame, standard chunk included.
        // The client reads it before knowing what kind of frame it holds, so
        // burying it inside a payload would make resume work for extension
        // events and silently not for content.
        if let seq = event.seq {
            payload["seq"] = seq
        }

        // Alongside `seq`, and for the same reason. The contract states this
        // twice — response header *and* first event — and the redundancy is
        // deliberate: a consumer reading only the body (a proxy, a recorded
        // stream) never sees the header, and without the id it cannot name the
        // turn it is watching. `turn_end` also carries it in its own body;
        // both values come from the coordinator that minted the id, so a frame
        // with two disagreeing ids is not expressible.
        if let turnID = event.turnID {
            payload["turn_id"] = turnID
        }

        let json = serialise(payload)

        // No `id:` field: SSE's own reconnection mechanism would have the
        // *browser* replay from a last-event-id, which is not the semantics
        // here — resume is an explicit endpoint with an explicit cursor (§3.3).
        return name.map { "event: \($0)\ndata: \(json)\n\n" } ?? "data: \(json)\n\n"
    }

    // MARK: - Naming

    /// The `event:` name, or nil for frames that must stay unnamed.
    ///
    /// Deltas, finish reasons and usage are standard OpenAI chunks and are
    /// deliberately anonymous.
    private static func eventName(for event: BridgeEvent) -> String? {
        switch event {
        case .delta, .finished, .usage, .done:
            return nil
        case .toolCall:
            return EventName.toolCall
        case .approvalRequired:
            return EventName.approvalRequired
        case .sessionStatus:
            return EventName.sessionStatus
        case .telemetry:
            return EventName.telemetry
        case .turnEnd:
            return EventName.turnEnd
        }
    }

    /// Wire names for the extensions (contract §3.1).
    ///
    /// These strings are the client's dispatch keys, and a client skips names
    /// it does not know **without complaint** (FR-010). A typo therefore does
    /// not fail loudly — the feature just never appears. Keeping them as named
    /// constants next to the encoder is the cheapest defence available.
    enum EventName {
        static let toolCall = "x-localis-tool-call"
        static let approvalRequired = "x-localis-approval-required"
        static let sessionStatus = "x-localis-session-status"
        static let telemetry = "x-localis-telemetry"
        static let turnEnd = "x-localis-turn-end"
    }

    // MARK: - Bodies

    private static func body(for event: BridgeEvent) -> [String: Any] {
        switch event {
        case .delta(let text):
            return chunk(delta: ["content": text])

        case .finished(let reason):
            // An empty `delta` alongside `finish_reason` is what OpenAI sends,
            // and the client reads the two from the same choice object.
            return chunk(delta: [:], extra: ["finish_reason": reason])

        case .usage(let usage):
            // `choices: []` is the standard shape for a usage-only chunk. The
            // client distinguishes chunk kinds by which fields are present, so
            // the empty array is meaningful rather than filler.
            var payload = chunk(choices: [])
            payload["usage"] = compact([
                "prompt_tokens": usage.promptTokens,
                "completion_tokens": usage.completionTokens,
                "total_tokens": usage.totalTokens,
            ])
            return payload

        case .toolCall(let call):
            return compact([
                "call_id": call.callID,
                "phase": call.phase.rawValue,
                "tool": call.tool,
                "summary": call.summary,
                "outcome": call.outcome?.rawValue,
                "duration_ms": call.durationMs,
            ])

        case .approvalRequired(let approval):
            return compact([
                "approval_id": approval.approvalID,
                "tool": approval.tool,
                "summary": approval.summary,
            ])

        case .sessionStatus(let status):
            return ["status": status]

        case .telemetry(let values):
            return values.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value.jsonValue
            }

        case .turnEnd(let end):
            var payload = compact([
                "turn_id": end.turnID,
                "outcome": end.outcome.rawValue,
                "failed_at_ms": end.failedAtMs,
                "tool_calls_completed": end.toolCallsCompleted,
            ])
            // Code only, never a message. `error.message` may hold an absolute
            // path (constitution I / contract §6); the client is forbidden from
            // showing it, and the surest way to honour that is to never send it.
            if let code = end.errorCode {
                payload["error"] = ["code": code]
            }
            return payload

        case .done:
            // Handled before dispatch; a body would never be read.
            return [:]
        }
    }

    /// The envelope shared by every standard OpenAI chunk.
    private static func chunk(
        delta: [String: Any]? = nil,
        extra: [String: Any] = [:],
        choices: [[String: Any]]? = nil
    ) -> [String: Any] {
        var choice: [String: Any] = ["index": 0]
        if let delta { choice["delta"] = delta }
        choice.merge(extra) { _, new in new }

        return [
            "object": "chat.completion.chunk",
            "choices": choices ?? [choice],
        ]
    }

    // MARK: - Serialisation

    /// Drops nil values, so an absent optional is an absent key.
    ///
    /// This matters beyond tidiness: the client renders by field *presence*
    /// (FR-059), so emitting `"duration_ms": null` would be a claim that a
    /// value exists when it does not.
    private static func compact(_ pairs: [String: Any?]) -> [String: Any] {
        pairs.reduce(into: [:]) { result, entry in
            guard let value = entry.value else { return }
            result[entry.key] = value
        }
    }

    /// JSON on exactly one line.
    ///
    /// A newline inside the serialised text would terminate the SSE frame early
    /// and split one event into two malformed ones. `JSONSerialization` without
    /// `.prettyPrinted` never emits one, and string contents are escaped — but
    /// the guarantee is important enough to name.
    private static func serialise(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            // Unreachable for the shapes built above, all of which are JSON
            // primitives. Emitting a syntactically valid frame the client will
            // skip beats emitting one that breaks its parser for the rest of
            // the turn.
            return "{}"
        }
        return text
    }
}

private extension TelemetryValue {
    var jsonValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        }
    }
}

import BridgeCore
import Foundation

/// What one line of claude's `stream-json` output turned into.
///
/// A line can produce more than one of these and can produce none, so the
/// decoder returns an array. Modelling "nothing happened" as an empty array
/// rather than an optional keeps the caller's loop uniform — it never has to
/// ask whether a frame was interesting.
public enum ClaudeStreamOutput: Sendable, Hashable {
    /// A contract event, ready for the encoder once the server stamps a `seq`.
    case event(BridgeEvent)
    /// claude's own session id, which the bridge stores so the next turn can
    /// pass `--resume`. Not the same thing as the contract's session id.
    case session(String)
    /// The turn's terminal state. Deliberately *not* a `BridgeEvent.turnEnd`:
    /// that event needs a `turn_id`, which is the server's to mint, and a
    /// decoder that invented one would be making up an identifier the rest of
    /// the system treats as authoritative.
    case ended(ClaudeTurnResult)
    /// A line this decoder could not read.
    case skipped(ClaudeStreamDecoder.SkipReason)
}

/// How a turn finished, as the CLI reported it.
public struct ClaudeTurnResult: Sendable, Hashable {
    public let outcome: TurnEndEvent.Outcome
    /// A code from the contract's §6 vocabulary, never the CLI's own text —
    /// which may name a file (constitution I).
    public let errorCode: String?

    public init(outcome: TurnEndEvent.Outcome, errorCode: String? = nil) {
        self.outcome = outcome
        self.errorCode = errorCode
    }
}

/// Decodes claude's `stream-json` dialect into contract events.
///
/// Line-at-a-time and stateless. The CLI emits newline-delimited JSON, so the
/// natural unit is one line — and holding no state means a malformed line
/// cannot corrupt the interpretation of the ones after it, which matters for a
/// program whose output format we do not control.
///
/// Everything claude-specific stops here. Nothing downstream knows this backend
/// exists, which is what makes constitution IV ("a sixth backend needs no iOS
/// release") true on the bridge side as well as the app side.
public enum ClaudeStreamDecoder {
    /// Why a line produced nothing.
    ///
    /// Reported rather than swallowed: the CLI ships on its own schedule, and a
    /// dialect change that silently produced empty replies would be diagnosed
    /// as a hang. These reasons are for operator logs — they name no content,
    /// so they are safe to record (constitution I).
    public enum SkipReason: String, Sendable, Hashable {
        /// Not JSON. Usually a diagnostic the CLI wrote to stdout.
        case notJSON = "not_json"
        /// Valid JSON in a shape this decoder has no rule for.
        case unknownType = "unknown_type"
    }

    /// Decodes one line.
    public static func decode(line: String) -> [ClaudeStreamOutput] {
        // Framing, not data. Reporting blank lines as skipped would bury a real
        // dialect mismatch under noise.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard
            let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
            let frame = object as? [String: Any]
        else {
            return [.skipped(.notJSON)]
        }

        switch frame["type"] as? String {
        case "system":
            return decodeSystem(frame)
        case "stream_event":
            return decodeStreamEvent(frame)
        case "result":
            return decodeResult(frame)
        case "assistant", "user":
            // The assembled message, sent once the deltas that composed it have
            // already gone out. Forwarding it would deliver the reply a second
            // time — the whole text, immediately after the streamed version.
            // Dropped knowingly rather than reported as unreadable.
            return []
        default:
            return [.skipped(.unknownType)]
        }
    }

    // MARK: - Frame kinds

    /// The handshake frame, read only for the session id.
    ///
    /// The rest of it describes the local machine — working directory, tool
    /// inventory, model settings. None of that is looked at, which is the point:
    /// a field never read is a field that cannot leak (constitution I).
    ///
    /// The other `system` subtypes are the CLI's own activity, observed on a
    /// real run: `hook_started` / `hook_response` (the user's local hooks
    /// firing), `notification`, and `status`. They describe this machine rather
    /// than the conversation, so they are dropped rather than reported as
    /// unreadable — a real dialect change would otherwise arrive buried in a
    /// steady stream of false alarms.
    private static func decodeSystem(_ frame: [String: Any]) -> [ClaudeStreamOutput] {
        switch frame["subtype"] as? String {
        case "init":
            guard let sessionID = frame["session_id"] as? String else {
                return [.skipped(.unknownType)]
            }
            return [.session(sessionID)]

        case "hook_started", "hook_response", "notification", "status":
            return []

        default:
            return [.skipped(.unknownType)]
        }
    }

    private static func decodeStreamEvent(_ frame: [String: Any]) -> [ClaudeStreamOutput] {
        guard let event = frame["event"] as? [String: Any] else {
            return [.skipped(.unknownType)]
        }

        switch event["type"] as? String {
        case "content_block_delta":
            return decodeContentDelta(event)

        case "message_delta":
            let delta = event["delta"] as? [String: Any]
            guard let stop = delta?["stop_reason"] as? String else { return [] }
            return [.event(.finished(reason: finishReason(for: stop)))]

        case "content_block_start", "content_block_stop", "message_start", "message_stop", "ping":
            // Structural. The deltas alone carry the text, so tracking block
            // boundaries would add state without adding information.
            return []

        default:
            return [.skipped(.unknownType)]
        }
    }

    /// **The one rule worth stating twice.**
    ///
    /// claude interleaves a `thinking` block with the `text` block in a single
    /// stream. Thinking is the model's scratchpad; text is its answer. Only
    /// `text_delta` becomes content — a `thinking_delta` that slipped through
    /// would put the reasoning into the user's transcript verbatim and save it
    /// to history.
    ///
    /// Matched by delta type rather than block index, because index assignment
    /// depends on whether a thinking block was produced at all.
    private static func decodeContentDelta(_ event: [String: Any]) -> [ClaudeStreamOutput] {
        guard let delta = event["delta"] as? [String: Any] else {
            return [.skipped(.unknownType)]
        }

        switch delta["type"] as? String {
        case "text_delta":
            guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.event(.delta(text))]

        case "thinking_delta", "signature_delta":
            // Deliberately dropped, not skipped: these are frames we understand
            // and have decided not to forward. Reporting them as unreadable
            // would make a working stream look broken.
            return []

        case "input_json_delta":
            // Tool arguments, streamed a fragment at a time. Surfacing them
            // needs call correlation and a summary that names no path
            // (contract §3.1a) — a later piece of work, and emitting the raw
            // fragments in the meantime would leak exactly what that summary
            // exists to abbreviate.
            return []

        default:
            return [.skipped(.unknownType)]
        }
    }

    /// The terminal frame: token counts and the turn's fate.
    private static func decodeResult(_ frame: [String: Any]) -> [ClaudeStreamOutput] {
        var outputs: [ClaudeStreamOutput] = []

        if let sessionID = frame["session_id"] as? String {
            outputs.append(.session(sessionID))
        }

        let usage = tokenUsage(from: frame["usage"] as? [String: Any])
        if !usage.isEmpty {
            outputs.append(.event(.usage(usage)))
        }

        // `is_error` is the CLI's own verdict. Reading `subtype` alone would let
        // a failed turn arrive as a successful empty reply.
        let failed = frame["is_error"] as? Bool ?? false
        outputs.append(.ended(ClaudeTurnResult(
            outcome: failed ? .failed : .completed,
            // A code from §6's vocabulary. The CLI's own message is not
            // forwarded: it can name a file, and the client maps codes to its
            // own wording anyway.
            errorCode: failed ? "backend_error" : nil
        )))

        return outputs
    }

    // MARK: - Translation

    /// claude reports halves; the client shows a total.
    ///
    /// Cache reads and writes are left out on purpose — they are billing
    /// detail, and folding them into `prompt_tokens` would report a number the
    /// user cannot reconcile with anything they can see.
    private static func tokenUsage(from usage: [String: Any]?) -> TokenUsage {
        guard let usage else { return TokenUsage() }

        let input = usage["input_tokens"] as? Int
        let output = usage["output_tokens"] as? Int
        // Only when both halves are known: a "total" equal to one half would be
        // read as fact rather than as a gap.
        let total = input.flatMap { inputTokens in output.map { inputTokens + $0 } }

        return TokenUsage(promptTokens: input, completionTokens: output, totalTokens: total)
    }

    /// claude's stop reason in OpenAI's vocabulary.
    ///
    /// The client parses `finish_reason` against OpenAI's set, so passing
    /// `end_turn` straight through would hand it a value none of its branches
    /// match.
    private static func finishReason(for stopReason: String) -> String {
        switch stopReason {
        case "end_turn", "stop_sequence": return "stop"
        case "max_tokens": return "length"
        case "tool_use": return "tool_calls"
        // An unmapped reason still ends the turn. Guessing a specific cause
        // would be worse than the generic one: the stream is over either way,
        // and `stop` is the only claim that stays true.
        default: return "stop"
        }
    }
}

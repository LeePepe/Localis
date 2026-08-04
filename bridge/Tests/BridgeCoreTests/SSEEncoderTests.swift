import Foundation
import Testing

@testable import BridgeCore

/// The wire format the iOS client parses (contract §3.1).
///
/// These tests assert bytes, not structs. That is deliberate: the client's
/// `SSEParser` and `StreamEventMapper` read the octets on the socket, so a test
/// that round-trips through this encoder's own types would agree with itself
/// while disagreeing with the only reader that matters.
@Suite("SSEEncoder — wire format")
struct SSEEncoderWireFormatTests {
    /// The client treats an unnamed frame as a standard OpenAI chunk and a
    /// named one as a Localis extension. Emitting a name here would make the
    /// client's `chunk(from:)` never run, and no content would ever render.
    @Test("content delta is an unnamed frame")
    func contentDeltaIsUnnamed() throws {
        let text = SSEEncoder.encode(SequencedEvent(seq: 0, event: .delta("He")))

        #expect(!text.contains("event:"))
        #expect(text.hasSuffix("\n\n"))

        let json = try payload(of: text)
        #expect(json["object"] as? String == "chat.completion.chunk")
        #expect(json["seq"] as? Int == 0)

        let choices = try #require(json["choices"] as? [[String: Any]])
        let delta = try #require(choices.first?["delta"] as? [String: Any])
        #expect(delta["content"] as? String == "He")
    }

    /// `seq` is what makes a turn resumable (contract §3.3). It must sit at the
    /// top level of *every* frame, including the standard chunks, because the
    /// client reads it before it knows which kind of frame it has.
    @Test("every event kind carries a top-level seq", arguments: [
        BridgeEvent.delta("x"),
        .finished(reason: "stop"),
        .usage(TokenUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3)),
        .sessionStatus("thinking"),
        .telemetry(["context_used": .number(0.42)]),
        .toolCall(ToolCallEvent(callID: "c-7", phase: .start, tool: "Bash", summary: "git status")),
        .turnEnd(TurnEndEvent(turnID: "t-1", outcome: .completed)),
    ])
    func everyEventCarriesSeq(event: BridgeEvent) throws {
        let json = try payload(of: SSEEncoder.encode(SequencedEvent(seq: 42, event: event)))

        #expect(json["seq"] as? Int == 42)
    }

    /// The names are the client's dispatch keys. A typo here is not a cosmetic
    /// bug: the client skips unknown event names silently (FR-010), so the
    /// feature would simply never appear, with nothing logged on either side.
    @Test("extension events use the contract's event names", arguments: [
        (BridgeEvent.toolCall(ToolCallEvent(callID: "c", phase: .start, tool: "Bash")), "x-localis-tool-call"),
        (.approvalRequired(ApprovalEvent(approvalID: "a", tool: "Write")), "x-localis-approval-required"),
        (.sessionStatus("thinking"), "x-localis-session-status"),
        (.telemetry(["k": .number(1)]), "x-localis-telemetry"),
        (.turnEnd(TurnEndEvent(turnID: "t", outcome: .completed)), "x-localis-turn-end"),
    ])
    func extensionEventNames(event: BridgeEvent, expected: String) {
        let text = SSEEncoder.encode(SequencedEvent(seq: 1, event: event))

        #expect(text.hasPrefix("event: \(expected)\n"))
    }

    /// `[DONE]` is a literal sentinel, not JSON. The client compares the
    /// payload string directly, so wrapping it in an object would leave the
    /// stream looking unterminated — which the client reports as a lost
    /// connection rather than a finished turn.
    @Test("done is the bare sentinel with no event name")
    func doneIsBareSentinel() {
        #expect(SSEEncoder.encode(SequencedEvent(seq: nil, event: .done)) == "data: [DONE]\n\n")
    }

    /// A delta spanning a newline must not be split across SSE `data:` lines by
    /// accident. JSON escaping handles this — but only if the payload really is
    /// JSON-encoded, so this pins that it is.
    @Test("newlines inside content are escaped, not framed")
    func newlinesInContentAreEscaped() throws {
        let text = SSEEncoder.encode(SequencedEvent(seq: 3, event: .delta("a\nb")))

        // One frame: a single `data:` line and one blank-line terminator.
        #expect(text.components(separatedBy: "data:").count == 2)

        let json = try payload(of: text)
        let choices = try #require(json["choices"] as? [[String: Any]])
        let delta = try #require(choices.first?["delta"] as? [String: Any])
        #expect(delta["content"] as? String == "a\nb")
    }

    /// Contract §3.1(a): `start` and `end` pair by `call_id`, and `end` must
    /// carry an `outcome`. Without these the client cannot close out a call and
    /// shows it as running forever (FR-057).
    @Test("tool call end carries call_id and outcome")
    func toolCallEndCarriesOutcome() throws {
        let event = BridgeEvent.toolCall(ToolCallEvent(
            callID: "c-7",
            phase: .end,
            tool: "Bash",
            outcome: .ok,
            durationMs: 840
        ))

        let json = try payload(of: SSEEncoder.encode(SequencedEvent(seq: 31, event: event)))

        #expect(json["call_id"] as? String == "c-7")
        #expect(json["phase"] as? String == "end")
        #expect(json["outcome"] as? String == "ok")
        #expect(json["duration_ms"] as? Int == 840)
    }

    /// Contract §3.1(d): a failed turn must be actionable. Dropping these two
    /// fields is what turns "ran 8 minutes, completed 3 tool calls, then
    /// failed" back into a bare "something went wrong".
    @Test("failed turn-end carries progress")
    func failedTurnEndCarriesProgress() throws {
        let event = BridgeEvent.turnEnd(TurnEndEvent(
            turnID: "t-9",
            outcome: .failed,
            failedAtMs: 480_000,
            toolCallsCompleted: 3,
            errorCode: "backend_crashed"
        ))

        let json = try payload(of: SSEEncoder.encode(SequencedEvent(seq: 99, event: event)))

        #expect(json["outcome"] as? String == "failed")
        #expect(json["failed_at_ms"] as? Int == 480_000)
        #expect(json["tool_calls_completed"] as? Int == 3)

        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "backend_crashed")
        // Constitution I: `message` may carry absolute paths. The client is
        // forbidden from displaying it, so the safest place to not leak it is
        // to never put it on the wire.
        #expect(error["message"] == nil)
    }

    // MARK: - Helpers

    /// Parses the JSON out of a single-frame SSE block.
    private func payload(of text: String) throws -> [String: Any] {
        let line = try #require(
            text.split(separator: "\n").first { $0.hasPrefix("data: ") },
            "no data line in frame"
        )
        let json = String(line.dropFirst("data: ".count))

        return try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
    }
}

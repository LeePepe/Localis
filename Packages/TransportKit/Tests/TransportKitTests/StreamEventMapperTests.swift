import Foundation
import LocalisModels
import Testing

@testable import TransportKit

/// Wire → domain mapping for the chat stream (contract §3.1, §3.4, Amendment C).
///
/// The rule these tests enforce over and over: **a frame the client does not
/// understand is skipped, and the stream keeps running.** A bridge is free to
/// add events and fields without an iOS release (constitution IV), so anything
/// that turns an unknown value into a decoding failure is a bug — it would take
/// down a turn that is otherwise fine.
@Suite("StreamEventMapper — wire to domain")
struct StreamEventMapperTests {
    private let mapper = StreamEventMapper()

    /// Maps one frame written as raw wire text.
    private func map(event: String? = nil, _ data: String) -> SequencedEvent? {
        mapper.map(SSEParser.Frame(event: event, data: data))
    }

    // MARK: - Standard OpenAI chunks

    @Test("a content delta becomes a delta event")
    func contentDelta() {
        let mapped = map(#"{"id":"c-1","object":"chat.completion.chunk","choices":[{"delta":{"content":"He"},"index":0}]}"#)

        #expect(mapped?.event == .delta("He"))
    }

    @Test("[DONE] ends the stream")
    func doneSentinel() {
        #expect(map("[DONE]")?.event == .done)
    }

    @Test("[DONE] is recognised with surrounding whitespace")
    func doneWithWhitespace() {
        #expect(map(" [DONE] ")?.event == .done)
    }

    @Test("a finish_reason becomes a finished event")
    func finishReason() {
        let mapped = map(#"{"object":"chat.completion.chunk","choices":[{"delta":{},"finish_reason":"stop","index":0}]}"#)

        #expect(mapped?.event == .finished(reason: "stop"))
    }

    @Test("an unknown finish_reason is passed through, not rejected")
    func unknownFinishReason() {
        // Open set: a new stop condition must not fail the turn.
        let mapped = map(#"{"choices":[{"delta":{},"finish_reason":"invented_later"}]}"#)

        #expect(mapped?.event == .finished(reason: "invented_later"))
    }

    @Test("an empty chunk yields nothing rather than an empty delta")
    func emptyChunkIsSkipped() {
        // An empty delta would append "" to the message and mark it streaming
        // for no reason.
        #expect(map(#"{"object":"chat.completion.chunk","choices":[{"delta":{},"index":0}]}"#) == nil)
    }

    @Test("multiple choices take the first — the client is single-turn")
    func firstChoiceWins() {
        let mapped = map(#"{"choices":[{"delta":{"content":"a"},"index":0},{"delta":{"content":"b"},"index":1}]}"#)

        #expect(mapped?.event == .delta("a"))
    }

    @Test("unknown fields in a chunk are ignored")
    func unknownChunkFields() {
        let mapped = map(#"{"choices":[{"delta":{"content":"hi","invented":1}}],"invented_later":{"deep":true}}"#)

        #expect(mapped?.event == .delta("hi"))
    }

    @Test("malformed JSON yields nothing instead of throwing")
    func malformedJSONIsSkipped() {
        // One corrupt frame must not end a turn. The stream keeps reading.
        #expect(map("{not json at all") == nil)
    }

    // MARK: - Sequence cursor (Amendment C)

    @Test("seq is lifted out of the payload for the resume cursor")
    func seqIsExtracted() {
        let mapped = map(#"{"seq":42,"choices":[{"delta":{"content":"x"}}]}"#)

        #expect(mapped?.seq == 42)
    }

    @Test("a frame without seq still maps, with no cursor")
    func missingSeqIsFine() {
        // Bridges that do not support resumable turns omit seq entirely.
        let mapped = map(#"{"choices":[{"delta":{"content":"x"}}]}"#)

        #expect(mapped != nil)
        #expect(mapped?.seq == nil)
    }

    @Test("seq is read from named events too")
    func seqOnNamedEvent() {
        let mapped = map(event: "x-localis-session-status", #"{"seq":5,"status":"thinking"}"#)

        #expect(mapped?.seq == 5)
    }

    // MARK: - Tool call lifecycle (contract §3.1a)

    @Test("a tool call start carries call_id, tool and summary")
    func toolCallStart() {
        let mapped = map(
            event: "x-localis-tool-call",
            #"{"seq":12,"call_id":"c-7","phase":"start","tool":"Bash","summary":"git status"}"#
        )

        guard case .toolCall(let call) = mapped?.event else {
            Issue.record("expected a tool call, got \(String(describing: mapped?.event))")
            return
        }
        #expect(call.callID == "c-7")
        #expect(call.phase == .start)
        #expect(call.tool == "Bash")
        #expect(call.summary == "git status")
    }

    @Test("a tool call end carries the outcome and duration")
    func toolCallEnd() {
        let mapped = map(
            event: "x-localis-tool-call",
            #"{"call_id":"c-7","phase":"end","tool":"Bash","outcome":"ok","duration_ms":840}"#
        )

        guard case .toolCall(let call) = mapped?.event else {
            Issue.record("expected a tool call")
            return
        }
        #expect(call.phase == .end)
        #expect(call.outcome == .ok)
        #expect(call.durationMs == 840)
    }

    @Test("known tool outcomes decode", arguments: [
        ("ok", ToolCall.Outcome.ok),
        ("error", .error),
        ("cancelled", .cancelled),
        ("denied", .denied),
    ])
    func toolOutcomes(_ testCase: (wire: String, expected: ToolCall.Outcome)) {
        let mapped = map(
            event: "x-localis-tool-call",
            #"{"call_id":"c","phase":"end","tool":"Bash","outcome":"\#(testCase.wire)"}"#
        )

        guard case .toolCall(let call) = mapped?.event else {
            Issue.record("expected a tool call for \(testCase.wire)")
            return
        }
        #expect(call.outcome == testCase.expected)
    }

    @Test("an unknown tool outcome is preserved as an unknown terminal state")
    func unknownToolOutcome() {
        // Contract §3.1a: an unknown outcome is a terminal state we cannot name.
        // Folding it into `.error` would report a success as a failure; dropping
        // the frame would leave the call spinning forever.
        let mapped = map(
            event: "x-localis-tool-call",
            #"{"call_id":"c","phase":"end","tool":"Bash","outcome":"invented_later"}"#
        )

        guard case .toolCall(let call) = mapped?.event else {
            Issue.record("expected a tool call")
            return
        }
        #expect(call.outcome == .unknown("invented_later"))
    }

    @Test("an unknown phase drops the frame")
    func unknownPhaseIsDropped() {
        // Contract §3.1a says MUST ignore — a future `progress` phase must not
        // be mistaken for a start or an end, which would corrupt the pairing.
        let mapped = map(
            event: "x-localis-tool-call",
            #"{"call_id":"c","phase":"progress","tool":"Bash"}"#
        )

        #expect(mapped == nil)
    }

    @Test("a tool call without call_id is dropped")
    func toolCallNeedsCallID() {
        // call_id is the only thing that pairs start with end when concurrent
        // calls interleave. Without it the frame cannot be filed anywhere.
        #expect(map(event: "x-localis-tool-call", #"{"phase":"start","tool":"Bash"}"#) == nil)
    }

    @Test("a tool call without a tool name is dropped")
    func toolCallNeedsTool() {
        #expect(map(event: "x-localis-tool-call", #"{"call_id":"c","phase":"start"}"#) == nil)
    }

    // MARK: - Approvals

    @Test("an approval request maps with its id and tool")
    func approvalRequired() {
        let mapped = map(
            event: "x-localis-approval-required",
            #"{"approval_id":"a-123","tool":"Write","summary":"write foo.swift"}"#
        )

        guard case .approvalRequired(let approval) = mapped?.event else {
            Issue.record("expected an approval request")
            return
        }
        #expect(approval.approvalID == "a-123")
        #expect(approval.tool == "Write")
        #expect(approval.summary == "write foo.swift")
    }

    @Test("an approval without an id is dropped")
    func approvalNeedsID() {
        // There would be no way to answer it.
        #expect(map(event: "x-localis-approval-required", #"{"tool":"Write"}"#) == nil)
    }

    // MARK: - Session status (contract §3.4c — open value set)

    @Test("a session status is carried through verbatim")
    func sessionStatus() {
        #expect(map(event: "x-localis-session-status", #"{"status":"thinking"}"#)?.event
            == .sessionStatus("thinking"))
    }

    @Test("an unknown status value is shown as-is, not an error")
    func unknownSessionStatus() {
        // §3.4c: the value set is open and the bridge sends human-readable
        // phrases. Validating against a closed enum here would reject exactly
        // the strings the feature exists to display.
        #expect(map(event: "x-localis-session-status", #"{"status":"compacting context"}"#)?.event
            == .sessionStatus("compacting context"))
    }

    @Test("a status frame with no status is dropped")
    func statusNeedsValue() {
        #expect(map(event: "x-localis-session-status", #"{"seq":3}"#) == nil)
    }

    // MARK: - Telemetry (contract §3.4b — free key-values)

    @Test("telemetry keeps every value the bridge sent")
    func telemetryEnvelope() {
        let mapped = map(
            event: "x-localis-telemetry",
            #"{"context_used":0.42,"queue_depth":2,"model":"claude-opus-4","paused":true}"#
        )

        guard case .telemetry(let values) = mapped?.event else {
            Issue.record("expected telemetry")
            return
        }
        #expect(values["context_used"] == .number(0.42))
        #expect(values["queue_depth"] == .number(2))
        #expect(values["model"] == .string("claude-opus-4"))
        #expect(values["paused"] == .boolean(true))
    }

    @Test("an unknown telemetry key is kept, not dropped")
    func unknownTelemetryKeyIsKept() {
        // The whole point of the open envelope: adding "gpu_temp" must need
        // zero iOS changes. Filtering to a known key list here would defeat it —
        // the UI decides what it can render, the transport does not pre-censor.
        let mapped = map(event: "x-localis-telemetry", #"{"gpu_temp":71}"#)

        guard case .telemetry(let values) = mapped?.event else {
            Issue.record("expected telemetry")
            return
        }
        #expect(values["gpu_temp"] == .number(71))
    }

    @Test("envelope metadata is not reported as a telemetry value")
    func telemetryExcludesEnvelopeKeys() {
        // seq and session_id are framing, not something to render in a readout.
        let mapped = map(event: "x-localis-telemetry", #"{"seq":42,"session_id":"s-1","queue_depth":2}"#)

        guard case .telemetry(let values) = mapped?.event else {
            Issue.record("expected telemetry")
            return
        }
        #expect(values["seq"] == nil)
        #expect(values["session_id"] == nil)
        #expect(values.count == 1)
    }

    @Test("a telemetry frame carrying only metadata is dropped")
    func emptyTelemetryIsDropped() {
        #expect(map(event: "x-localis-telemetry", #"{"seq":42}"#) == nil)
    }

    @Test("a nested telemetry value is skipped without losing the frame")
    func nestedTelemetryValueSkipped() {
        // Only scalars are renderable. An object-valued key is ignored; the
        // siblings still arrive.
        let mapped = map(event: "x-localis-telemetry", #"{"nested":{"a":1},"queue_depth":2}"#)

        guard case .telemetry(let values) = mapped?.event else {
            Issue.record("expected telemetry")
            return
        }
        #expect(values["nested"] == nil)
        #expect(values["queue_depth"] == .number(2))
    }

    // MARK: - Usage (contract §3.4a)

    @Test("a usage chunk maps to token counts")
    func usageChunk() {
        let mapped = map(#"{"object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":340,"total_tokens":1540}}"#)

        #expect(mapped?.event == .usage(TokenUsage(promptTokens: 1200, completionTokens: 340, totalTokens: 1540)))
    }

    @Test("a partial usage payload keeps the fields that were sent")
    func partialUsage() {
        // §3.4a forbids inventing numbers, so a missing count stays nil rather
        // than becoming 0 — the UI renders nothing for it.
        let mapped = map(#"{"usage":{"total_tokens":90}}"#)

        #expect(mapped?.event == .usage(TokenUsage(promptTokens: nil, completionTokens: nil, totalTokens: 90)))
    }

    // MARK: - Turn end (Amendment C §3.1d)

    @Test("a completed turn end maps its outcome")
    func turnEndCompleted() {
        let mapped = map(
            event: "x-localis-turn-end",
            #"{"turn_id":"t-9","outcome":"completed","tool_calls_completed":3}"#
        )

        guard case .turnEnd(let end) = mapped?.event else {
            Issue.record("expected a turn end")
            return
        }
        #expect(end.turnID == "t-9")
        #expect(end.outcome == .completed)
        #expect(end.toolCallsCompleted == 3)
    }

    @Test("a failed turn end carries actionable progress")
    func turnEndFailedCarriesProgress() {
        // The hard requirement in §3.1d: "failed after 8 minutes and 3 tool
        // calls" instead of a bare "something went wrong".
        let mapped = map(
            event: "x-localis-turn-end",
            #"{"turn_id":"t-9","outcome":"failed","failed_at_ms":480000,"tool_calls_completed":3,"error":{"code":"backend_crashed"}}"#
        )

        guard case .turnEnd(let end) = mapped?.event else {
            Issue.record("expected a turn end")
            return
        }
        #expect(end.outcome == .failed)
        #expect(end.failedAtMs == 480_000)
        #expect(end.toolCallsCompleted == 3)
        #expect(end.errorCode == "backend_crashed")
    }

    @Test("the bridge's diagnostic message never reaches the domain event")
    func turnEndDropsDiagnosticMessage() {
        // Constitution I / FR-025: `error.message` may contain absolute paths.
        // It is not merely "not displayed" — it is not carried, so no future
        // caller can display it by accident.
        let mapped = map(
            event: "x-localis-turn-end",
            #"{"outcome":"failed","error":{"code":"backend_unavailable","message":"/Users/tian/secret/path exploded"}}"#
        )

        let described = String(describing: mapped)
        #expect(described.contains("/Users/tian") == false, "a filesystem path leaked into the domain event")
        #expect(described.contains("secret") == false)
    }

    @Test("turn outcomes decode", arguments: [
        ("completed", TurnEnd.Outcome.completed),
        ("failed", .failed),
        ("cancelled", .cancelled),
    ])
    func turnOutcomes(_ testCase: (wire: String, expected: TurnEnd.Outcome)) {
        let mapped = map(event: "x-localis-turn-end", #"{"outcome":"\#(testCase.wire)"}"#)

        guard case .turnEnd(let end) = mapped?.event else {
            Issue.record("expected a turn end for \(testCase.wire)")
            return
        }
        #expect(end.outcome == testCase.expected)
    }

    @Test("an unknown turn outcome is preserved rather than guessed")
    func unknownTurnOutcome() {
        let mapped = map(event: "x-localis-turn-end", #"{"outcome":"invented_later"}"#)

        guard case .turnEnd(let end) = mapped?.event else {
            Issue.record("expected a turn end")
            return
        }
        #expect(end.outcome == .unknown("invented_later"))
    }

    @Test("a turn end with no outcome is dropped")
    func turnEndNeedsOutcome() {
        #expect(map(event: "x-localis-turn-end", #"{"turn_id":"t-9"}"#) == nil)
    }

    // MARK: - Forward compatibility

    @Test("an unknown event name is skipped and the stream continues")
    func unknownEventIsSkipped() {
        // FR-010. This is the single most important forward-compatibility rule:
        // a bridge adding an event must not break an older client.
        #expect(map(event: "x-localis-invented-later", #"{"anything":"at all"}"#) == nil)
    }

    @Test("a known event with an unparseable payload is skipped, not fatal")
    func knownEventBadPayload() {
        #expect(map(event: "x-localis-tool-call", "not json") == nil)
    }
}

/// End-to-end over recorded wire captures: parser and mapper together.
@Suite("StreamEventMapper — recorded streams")
struct RecordedStreamTests {
    /// Replays a fixture through the parser and mapper exactly as the transport
    /// does, splitting at `chunkSize` bytes to exercise framing at the same time.
    private func replay(_ fixture: String, chunkSize: Int = 7) throws -> [SequencedEvent] {
        let bytes = try Fixture.bytes(fixture)
        let mapper = StreamEventMapper()
        var parser = SSEParser()
        var events: [SequencedEvent] = []

        for start in stride(from: 0, to: bytes.count, by: chunkSize) {
            let piece = Array(bytes[start..<min(start + chunkSize, bytes.count)])
            let (frames, next) = parser.parse(bytes: piece)
            events += frames.compactMap(mapper.map)
            parser = next
        }
        events += parser.finish().compactMap(mapper.map)

        return events
    }

    @Test("a recorded successful turn maps to the expected event sequence")
    func recordedSuccessfulTurn() throws {
        let events = try replay("chat-stream")

        #expect(events.map(\.seq) == [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, nil])
        #expect(events.last?.event == .done)
    }

    @Test("the recorded content reassembles byte for byte")
    func recordedContentIsIntact() throws {
        let text = try replay("chat-stream").compactMap { event -> String? in
            guard case .delta(let chunk) = event.event else { return nil }
            return chunk
        }.joined()

        #expect(text == "Hello")
    }

    @Test("the unknown event in the capture is skipped without losing its neighbours")
    func recordedUnknownEventSkipped() throws {
        let events = try replay("chat-stream")

        // seq 6 is `x-localis-invented-later`; 5 and 7 are on either side.
        #expect(events.contains { $0.seq == 6 } == false)
        #expect(events.contains { $0.seq == 5 })
        #expect(events.contains { $0.seq == 7 })
    }

    @Test("the recorded tool call pairs start with end by call_id")
    func recordedToolCallPairs() throws {
        let calls = try replay("chat-stream").compactMap { event -> ToolCall? in
            guard case .toolCall(let call) = event.event else { return nil }
            return call
        }

        #expect(calls.count == 2)
        #expect(calls[0].callID == calls[1].callID)
        #expect(calls[0].phase == .start)
        #expect(calls[1].phase == .end)
    }

    @Test("a recorded failed turn keeps its partial content and its progress")
    func recordedFailedTurn() throws {
        let events = try replay("chat-stream-failed")

        let text = events.compactMap { event -> String? in
            guard case .delta(let chunk) = event.event else { return nil }
            return chunk
        }.joined()
        #expect(text == "partial", "content received before the failure must survive (FR-019)")

        guard case .turnEnd(let end) = events.last?.event else {
            Issue.record("expected the capture to end with a turn end")
            return
        }
        #expect(end.outcome == .failed)
        #expect(end.failedAtMs == 480_000)
        #expect(end.toolCallsCompleted == 3)
    }

    @Test("no recorded stream leaks a filesystem path into a domain event")
    func recordedStreamsLeakNoPaths() throws {
        for fixture in ["chat-stream", "chat-stream-failed"] {
            let described = String(describing: try replay(fixture))
            #expect(described.contains("/Users/") == false, "\(fixture) leaked a path")
        }
    }

    @Test("framing is identical at every chunk size", arguments: [1, 3, 16, 64, 4096])
    func chunkSizeIndependence(_ size: Int) throws {
        let baseline = try replay("chat-stream", chunkSize: 4096)

        #expect(try replay("chat-stream", chunkSize: size) == baseline)
    }
}

/// Loads recorded wire captures from the test bundle.
enum Fixture {
    static func bytes(_ name: String) throws -> [UInt8] {
        Array(try data(name, extension: "sse"))
    }

    static func data(_ name: String, extension ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw FixtureError.missing("\(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error {
        case missing(String)
    }
}

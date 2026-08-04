import Foundation
import Testing

@testable import BridgeAdapters
@testable import BridgeCore

/// The claude CLI's `--output-format stream-json` dialect, decoded into contract
/// events.
///
/// The fixture is a real capture, reduced to the frame shapes this decoder
/// reads: no absolute paths, no real session id, no thinking signature
/// (constitution I — a checked-in fixture is a file like any other). Reduced,
/// not invented: every frame type present here came off the real CLI, so a
/// change in its dialect still lands as a red test rather than a silent
/// mismatch.
@Suite("ClaudeStreamDecoder — stream-json dialect")
struct ClaudeStreamDecoderTests {
    /// **The load-bearing test.** claude interleaves a `thinking` block with the
    /// `text` block in the same stream. Thinking is the model's scratchpad, not
    /// its answer; emitting it as content would put the reasoning into the
    /// transcript verbatim — visible to the user, saved to history, and wrong.
    @Test("thinking deltas never become content")
    func thinkingIsNotContent() throws {
        let outputs = decodeFixture()

        let content = outputs.compactMap(\.deltaText).joined()

        #expect(content == "hello world")
        #expect(!content.contains("The user is asking"))
    }

    /// The counterpart: without this, "never emit thinking" is satisfiable by
    /// emitting nothing at all.
    @Test("text deltas become content in order")
    func textBecomesContent() {
        let lines = [
            deltaLine(type: "text_delta", key: "text", value: "hel"),
            deltaLine(type: "text_delta", key: "text", value: "lo"),
        ]

        let content = lines
            .flatMap { ClaudeStreamDecoder.decode(line: $0) }
            .compactMap(\.deltaText)
            .joined()

        #expect(content == "hello")
    }

    /// `stop_reason` is claude's vocabulary; `finish_reason` is OpenAI's, and
    /// OpenAI's is what the client parses. Passing `end_turn` through untouched
    /// would hand the client a value no branch of it recognises.
    @Test("stop reasons map to OpenAI finish reasons", arguments: [
        ("end_turn", "stop"),
        ("max_tokens", "length"),
        ("tool_use", "tool_calls"),
    ])
    func stopReasonMapping(claude: String, expected: String) throws {
        let line = """
        {"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"\(claude)"}}}
        """

        let outputs = ClaudeStreamDecoder.decode(line: line)
        let reason = try #require(outputs.compactMap(\.finishReason).first)

        #expect(reason == expected)
    }

    /// Token counts arrive only in the terminal `result` frame, and the client
    /// renders the usage block on presence (FR-059). Losing them here is not a
    /// crash — it is a permanently empty panel.
    @Test("the result frame yields usage")
    func resultYieldsUsage() throws {
        let outputs = decodeFixture()
        let usage = try #require(outputs.compactMap(\.usage).first)

        #expect(usage.promptTokens == 44_313)
        #expect(usage.completionTokens == 41)
        // Derived, not reported: claude sends the two halves, the client shows
        // a total.
        #expect(usage.totalTokens == 44_354)
    }

    /// The turn's outcome, which becomes `x-localis-turn-end` once the server
    /// pairs it with a turn id. The decoder cannot invent that id, so it reports
    /// the outcome and stops there.
    @Test("a successful result ends the turn as completed")
    func successfulResultCompletes() throws {
        let outputs = decodeFixture()
        let result = try #require(outputs.compactMap(\.turnResult).first)

        #expect(result.outcome == .completed)
        #expect(result.errorCode == nil)
    }

    /// `is_error` is the CLI's own failure signal. Reading only `subtype` would
    /// let a failed turn be reported to the user as a successful empty reply.
    @Test("an error result ends the turn as failed")
    func errorResultFails() throws {
        let line = """
        {"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s"}
        """

        let outputs = ClaudeStreamDecoder.decode(line: line)
        let result = try #require(outputs.compactMap(\.turnResult).first)

        #expect(result.outcome == .failed)
        #expect(result.errorCode == "backend_error")
    }

    /// **A failed turn must not report a session id worth keeping.**
    ///
    /// Observed 2026-08-04 against the real CLI: `--resume` with a UUID that
    /// names no conversation exits 1, prints `No conversation found with
    /// session ID: …` on stderr, and emits exactly one frame — a `result` with
    /// `is_error: true` whose `session_id` is **the very id that was rejected**,
    /// echoed straight back. The line below is that frame, trimmed.
    ///
    /// If the decoder reports it as a session, the coordinator files it, and a
    /// mapping that has already been proven dead is written back over itself.
    /// Once the mapping is durable that means a conversation which is
    /// permanently unusable: every turn resumes an id the CLI rejects, and no
    /// turn ever succeeds to replace it. Today the mapping dies with the
    /// process, which is the only reason this has not been seen.
    @Test("a failed turn does not report a session id")
    func failedResultReportsNoSession() throws {
        let line = """
        {"type":"result","subtype":"error_during_execution","is_error":true,\
        "num_turns":0,"session_id":"00000000-dead-4000-8000-000000000000",\
        "errors":["No conversation found with session ID: 00000000-dead-4000-8000-000000000000"]}
        """

        let outputs = ClaudeStreamDecoder.decode(line: line)

        let sessions = outputs.compactMap(\.sessionID)
        #expect(
            sessions.isEmpty,
            "the id the CLI just rejected was reported as this turn's session: \(sessions)"
        )
    }

    /// The other half, so the test above cannot be satisfied by never reporting
    /// a session id at all: a *successful* result still reports one.
    @Test("a successful result still reports its session id")
    func successfulResultReportsSession() throws {
        let line = """
        {"type":"result","subtype":"success","is_error":false,"session_id":"s-ok"}
        """

        let outputs = ClaudeStreamDecoder.decode(line: line)

        #expect(outputs.compactMap(\.sessionID) == ["s-ok"])
    }

    /// The bridge needs claude's own session id to pass `--resume` on the next
    /// turn; the contract's `x-localis-session-id` is the client's handle and
    /// means nothing to the CLI. Mapping between the two is what makes a
    /// conversation continue rather than restart.
    @Test("the init frame reports the CLI session id")
    func initReportsSessionID() throws {
        let outputs = decodeFixture()
        let sessionID = try #require(outputs.compactMap(\.sessionID).first)

        #expect(sessionID == "11111111-2222-3333-4444-555555555555")
    }

    /// A dialect this decoder does not know must not take the turn down with
    /// it. The CLI is a separate program on a release cycle we do not control,
    /// so an unrecognised frame is a routine event, not an error.
    @Test("unreadable lines are skipped with a reason, not dropped silently", arguments: [
        ("not json at all", ClaudeStreamDecoder.SkipReason.notJSON),
        ("{\"type\":\"something_new\"}", .unknownType),
    ])
    func unreadableLinesAreSkipped(line: String, expected: ClaudeStreamDecoder.SkipReason) throws {
        let outputs = ClaudeStreamDecoder.decode(line: line)
        let reason = try #require(outputs.compactMap(\.skipReason).first)

        #expect(reason == expected)
        #expect(outputs.compactMap(\.deltaText).isEmpty)
    }

    /// Blank lines are framing, not data. Reporting them as skipped would bury
    /// a real dialect mismatch under noise in whatever reads those reasons.
    @Test("blank lines produce nothing at all")
    func blankLinesAreIgnored() {
        #expect(ClaudeStreamDecoder.decode(line: "   ").isEmpty)
    }

    /// **Found by running the real CLI, not by reading its docs.** A live turn
    /// emits an `assistant` frame carrying the whole assembled message after
    /// the deltas that composed it have already been sent. Forwarding it would
    /// deliver the reply twice: streamed, then again in full.
    @Test("the assembled assistant message is not re-sent as content")
    func assembledMessageIsNotResent() {
        let line = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"hello world"}]},"session_id":"s"}
        """

        let outputs = ClaudeStreamDecoder.decode(line: line)

        #expect(outputs.isEmpty)
    }

    /// Also from a live run: the CLI narrates its own activity on this machine
    /// — local hooks firing, notifications, status. None of it is conversation.
    ///
    /// Asserted as *silence* rather than as skips: reporting six frames per
    /// turn as unreadable would bury a genuine dialect change under routine
    /// noise, which is how a real mismatch goes unnoticed.
    @Test("the CLI's own activity frames are dropped silently", arguments: [
        "hook_started", "hook_response", "notification", "status",
    ])
    func activityFramesAreSilent(subtype: String) {
        let line = #"{"type":"system","subtype":"\#(subtype)","session_id":"s"}"#

        #expect(ClaudeStreamDecoder.decode(line: line).isEmpty)
    }

    /// The counterpart to the two tests above: dropping known-uninteresting
    /// frames must not become dropping everything. An unrecognised `system`
    /// subtype is still reported, so a new one shows up as a skip rather than
    /// as silence.
    @Test("an unknown system subtype is still reported")
    func unknownSystemSubtypeIsReported() throws {
        let line = #"{"type":"system","subtype":"something_new","session_id":"s"}"#

        let outputs = ClaudeStreamDecoder.decode(line: line)
        let reason = try #require(outputs.compactMap(\.skipReason).first)

        #expect(reason == .unknownType)
    }

    // MARK: - Helpers

    private func decodeFixture() -> [ClaudeStreamOutput] {
        fixtureLines().flatMap { ClaudeStreamDecoder.decode(line: $0) }
    }

    private func fixtureLines() -> [String] {
        let url = Bundle.module.url(
            forResource: "claude-stream-json",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        )
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("fixture claude-stream-json.jsonl is missing from the test bundle")
            return []
        }
        return text.split(separator: "\n").map(String.init)
    }

    private func deltaLine(type: String, key: String, value: String) -> String {
        """
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,\
        "delta":{"type":"\(type)","\(key)":"\(value)"}}}
        """
    }
}

// MARK: - Readable projections

/// Narrow accessors so each test reads as the one claim it makes, rather than
/// as a pattern match repeated eight times.
private extension ClaudeStreamOutput {
    var deltaText: String? {
        guard case .event(.delta(let text)) = self else { return nil }
        return text
    }

    var finishReason: String? {
        guard case .event(.finished(let reason)) = self else { return nil }
        return reason
    }

    var usage: TokenUsage? {
        guard case .event(.usage(let usage)) = self else { return nil }
        return usage
    }

    var turnResult: ClaudeTurnResult? {
        guard case .ended(let result) = self else { return nil }
        return result
    }

    var sessionID: String? {
        guard case .session(let id) = self else { return nil }
        return id
    }

    var skipReason: ClaudeStreamDecoder.SkipReason? {
        guard case .skipped(let reason) = self else { return nil }
        return reason
    }
}

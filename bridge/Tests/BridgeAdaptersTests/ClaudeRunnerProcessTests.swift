import Foundation
import Testing

@testable import BridgeAdapters
@testable import BridgeCore

/// Running an actual subprocess and reading what comes back.
///
/// The rest of the adapter suite feeds strings to a decoder. That proves the
/// decoding and nothing about the part most likely to be wrong: pipes,
/// buffering, EOF, exit codes, and whether the stream ever finishes. A stub
/// `/bin/sh` script standing in for the CLI exercises all of it in
/// milliseconds and with no dependency on claude being installed.
@Suite("ClaudeRunner — real subprocess", .serialized)
struct ClaudeRunnerProcessTests {
    /// The whole point of the program, in miniature: a process writes
    /// stream-json, and events come out.
    @Test("a process writing stream-json yields events")
    func yieldsEvents() async throws {
        let script = try StubCLI(emitting: """
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}}
        {"type":"result","subtype":"success","is_error":false,"session_id":"s-1","usage":{"input_tokens":10,"output_tokens":2}}
        """)

        let outputs = try await collect(from: script)
        let content = outputs.compactMap(\.deltaText).joined()

        #expect(content == "hello")
        #expect(outputs.contains { $0.isCompletedResult })
    }

    /// **The case a string-fed test cannot reach.** The CLI's last line arrives
    /// at EOF without a trailing newline. If the runner does not flush at
    /// termination, that line is dropped — and for claude it is the `result`
    /// frame carrying usage and the turn's outcome, so the turn would appear to
    /// end with no ending.
    @Test("the final unterminated line is not lost")
    func finalLineSurvives() async throws {
        let script = try StubCLI(emitting: """
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}}
        {"type":"result","subtype":"success","is_error":false,"session_id":"s-2"}
        """, trailingNewline: false)

        let outputs = try await collect(from: script)

        #expect(outputs.contains { $0.isCompletedResult })
    }

    /// A line split across two writes must rejoin. The stub sleeps mid-line to
    /// force the split into separate reads rather than hoping for it.
    @Test("a line split across two writes rejoins")
    func splitWriteRejoins() async throws {
        let script = try StubCLI(rawScript: """
        printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"split'
        sleep 0.15
        printf 'me"}}}\\n'
        """)

        let outputs = try await collect(from: script)

        #expect(outputs.compactMap(\.deltaText).joined() == "splitme")
    }

    /// A non-zero exit is a failed turn even if the stream looked complete.
    /// Finishing normally would leave the client waiting for an end that is not
    /// coming.
    @Test("a non-zero exit throws")
    func nonZeroExitThrows() async throws {
        let script = try StubCLI(rawScript: "echo '{}' ; exit 3")

        await #expect(throws: ClaudeRunner.Failure.backendError) {
            _ = try await collect(from: script)
        }
    }

    /// A missing binary must be a clean typed failure, not a crash and not a
    /// stream that never finishes.
    @Test("a missing executable reports backend_unavailable")
    func missingExecutable() async throws {
        let runner = ClaudeRunner(executable: "/nonexistent/claude")

        await #expect(throws: ClaudeRunner.Failure.backendUnavailable) {
            for try await _ in runner.run(ClaudeInvocation(prompt: "x")) {}
        }
    }

    /// stderr must be drained. A CLI that writes more than a pipe buffer's
    /// worth of diagnostics would block forever on the write if nobody read it,
    /// and the turn would hang with no output and no error — the failure mode
    /// hardest to attribute.
    @Test("a chatty stderr does not deadlock the turn")
    func chattyStderrDoesNotDeadlock() async throws {
        let script = try StubCLI(rawScript: """
        for i in $(seq 1 2000); do
          echo "diagnostic line $i naming /some/path/that/is/long" >&2
        done
        printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"survived"}}}\\n'
        """)

        let outputs = try await collect(from: script)

        #expect(outputs.compactMap(\.deltaText).joined() == "survived")
    }

    /// Cancellation must stop the process, not just stop listening. Otherwise
    /// the CLI keeps running — and keeps spending tokens — after the user has
    /// stopped the turn (§4).
    ///
    /// The timings are the test. The stub sleeps `markerDelay` before writing;
    /// this waits longer than that, so a surviving process has had its chance
    /// and the absent marker means termination rather than impatience. An
    /// earlier version waited less than the sleep and passed even with
    /// termination removed — it was measuring nothing.
    @Test("cancelling the stream terminates the process")
    func cancellationTerminatesProcess() async throws {
        let markerDelay = Duration.milliseconds(700)
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("localis-cancel-\(UUID().uuidString)")
        let script = try StubCLI(rawScript: """
        printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"first"}}}\\n'
        sleep 0.7
        touch \(marker.path)
        """)

        let runner = ClaudeRunner(executable: script.path)
        let task = Task {
            for try await _ in runner.run(ClaudeInvocation(prompt: "x")) {
                // Stop at the first event, while the process is still sleeping.
                break
            }
        }
        try await task.value

        try await Task.sleep(for: markerDelay * 2)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// The negative control for the test above, kept in the suite rather than
    /// run by hand once: it proves the marker mechanism can observe a surviving
    /// process at these timings. Without it, "no marker" is equally consistent
    /// with "terminated correctly" and "waited too briefly to tell".
    @Test("the marker mechanism observes a process that is left alone")
    func markerAppearsWhenProcessSurvives() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("localis-control-\(UUID().uuidString)")
        let script = try StubCLI(rawScript: """
        sleep 0.7
        touch \(marker.path)
        """)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: script.path)
        process.standardOutput = Pipe()
        try process.run()

        try await Task.sleep(for: .milliseconds(1400))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - Helpers

    private func collect(from script: StubCLI) async throws -> [ClaudeStreamOutput] {
        let runner = ClaudeRunner(executable: script.path)
        var outputs: [ClaudeStreamOutput] = []

        for try await output in runner.run(ClaudeInvocation(prompt: "x")) {
            outputs.append(output)
        }
        return outputs
    }
}

/// An executable shell script standing in for the CLI.
///
/// A stub rather than the real `claude`: these tests are about pipes and
/// process lifecycle, and they must pass on a machine with no claude installed
/// and without spending tokens.
private struct StubCLI {
    let path: String

    init(rawScript: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localis-stub-\(UUID().uuidString).sh")

        try "#!/bin/sh\n\(rawScript)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        path = url.path
    }

    /// Emits the given lines verbatim.
    init(emitting lines: String, trailingNewline: Bool = true) throws {
        // `printf '%s'` rather than `echo`: it adds nothing of its own, so the
        // presence or absence of the final newline is exactly what the test
        // asked for.
        let escaped = lines.replacingOccurrences(of: "'", with: "'\\''")
        let terminator = trailingNewline ? "\\n" : ""
        try self.init(rawScript: "printf '%s\(terminator)' '\(escaped)'")
    }
}

private extension ClaudeStreamOutput {
    var deltaText: String? {
        guard case .event(.delta(let text)) = self else { return nil }
        return text
    }

    var isCompletedResult: Bool {
        guard case .ended(let result) = self else { return false }
        return result.outcome == .completed
    }
}

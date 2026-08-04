import Foundation
import Testing

@testable import BridgeAdapters
@testable import BridgeCore

/// What the backend does when the CLI refuses the conversation it was asked to
/// continue.
///
/// **Every test here counts invocations.** The retry's whole risk is that a
/// prompt runs twice on the user's machine, and these CLIs execute commands.
/// "Did it retry?" is not answerable from the events alone — a second run that
/// produced identical output is invisible there — so the stub records each
/// invocation to a file and the tests read that file.
@Suite("ClaudeBackend — retry after a rejected resume", .serialized)
struct ClaudeBackendResumeTests {
    /// The observed failure: `--resume` names a conversation the CLI does not
    /// have, so it refuses before running anything.
    ///
    /// Recorded 2026-08-04 against the real CLI. `num_turns: 0` and the
    /// `errors` sentence are both load-bearing — `ResumeFailure` requires both.
    private static func notFoundFrame() -> String {
        """
        {"type":"result","subtype":"error_during_execution","is_error":true,\
        "num_turns":0,"session_id":"00000000-dead-4000-8000-000000000000",\
        "errors":["No conversation found with session ID: 00000000-dead-4000-8000-000000000000"]}
        """
    }

    /// A turn that worked, with a session id the coordinator can file over the
    /// dead one.
    private static func successFrames() -> String {
        """
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,\
        "delta":{"type":"text_delta","text":"fresh reply"}}}
        {"type":"result","subtype":"success","is_error":false,"session_id":"s-new"}
        """
    }

    /// **The point of the feature.** A session whose backend conversation has
    /// been deleted must still be able to send. Before this, the turn failed and
    /// every later turn failed the same way — the session was permanently mute.
    @Test("a rejected resume is retried fresh and the turn succeeds")
    func rejectedResumeRetriesFresh() async throws {
        let stub = try ResumeStub(
            withResume: Self.notFoundFrame(), exitingWith: 1,
            withoutResume: Self.successFrames(), exitingWith: 0
        )

        let outputs = try await collect(from: stub, resuming: "00000000-dead-4000-8000-000000000000")

        #expect(outputs.compactMap(\.deltaText).joined() == "fresh reply")
        // The fresh id has to reach the coordinator, or the next turn resumes
        // the dead one again and this repeats forever.
        #expect(outputs.compactMap(\.backendSession) == ["s-new"])
        #expect(try stub.invocations().count == 2)
    }

    /// The retry must actually drop `--resume`. Retrying with the same argument
    /// would be a second refusal and a second process, for nothing.
    @Test("the retry carries no resume argument")
    func retryDropsResume() async throws {
        let stub = try ResumeStub(
            withResume: Self.notFoundFrame(), exitingWith: 1,
            withoutResume: Self.successFrames(), exitingWith: 0
        )

        _ = try await collect(from: stub, resuming: "00000000-dead-4000-8000-000000000000")

        let invocations = try stub.invocations()
        #expect(invocations.count == 2)
        #expect(invocations.first?.contains("--resume") == true)
        #expect(invocations.last?.contains("--resume") == false)
    }

    /// **The load-bearing test.** A failure that did work is not retried, even
    /// though it says the conversation is missing. `num_turns > 0` is the CLI
    /// telling us commands may already have run on this machine; running the
    /// prompt again would run them again.
    @Test("a failure that ran turns is not retried", arguments: [1, 4])
    func startedTurnsAreNotRetried(turns: Int) async throws {
        let frame = """
        {"type":"result","subtype":"error_during_execution","is_error":true,\
        "num_turns":\(turns),"session_id":"dead",\
        "errors":["No conversation found with session ID: dead"]}
        """
        let stub = try ResumeStub(
            withResume: frame, exitingWith: 1,
            withoutResume: Self.successFrames(), exitingWith: 0
        )

        await #expect(throws: ClaudeRunner.Failure.backendError) {
            _ = try await collect(from: stub, resuming: "dead")
        }

        #expect(
            try stub.invocations().count == 1,
            "a turn that already ran \(turns) turn(s) was executed a second time"
        )
    }

    /// Some other zero-turn failure — an outage, a refused login — is not a
    /// missing conversation. Retrying it would turn every transient backend
    /// fault into two runs of the user's prompt.
    @Test("an unrelated failure is not retried")
    func unrelatedFailureIsNotRetried() async throws {
        let frame = """
        {"type":"result","subtype":"error_during_execution","is_error":true,\
        "num_turns":0,"errors":["Credit balance is too low"]}
        """
        let stub = try ResumeStub(
            withResume: frame, exitingWith: 1,
            withoutResume: Self.successFrames(), exitingWith: 0
        )

        await #expect(throws: ClaudeRunner.Failure.backendError) {
            _ = try await collect(from: stub, resuming: "dead")
        }

        #expect(try stub.invocations().count == 1)
    }

    /// A first turn has no conversation to lose, so there is nothing to retry
    /// *to*. If the CLI somehow reports a missing conversation for an
    /// invocation that never named one, that is a dialect we do not understand
    /// — and re-running the prompt is not the safe response to not understanding.
    @Test("a first turn is never retried")
    func firstTurnIsNotRetried() async throws {
        let stub = try ResumeStub(
            withResume: Self.successFrames(), exitingWith: 0,
            withoutResume: Self.notFoundFrame(), exitingWith: 1
        )

        await #expect(throws: ClaudeRunner.Failure.backendError) {
            _ = try await collect(from: stub, resuming: nil)
        }

        #expect(try stub.invocations().count == 1)
    }

    /// **A guard the ruling did not ask for.** If the first attempt already sent
    /// text to the client, a retry would show the user half a reply followed by
    /// a whole one — and, worse, would re-run a prompt the CLI had visibly begun
    /// acting on. `ResumeFailure` makes this unreachable for the failure we have
    /// observed; this covers the dialect we have not.
    @Test("a rejected resume that already emitted content is not retried")
    func partialOutputBlocksRetry() async throws {
        let frame = """
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,\
        "delta":{"type":"text_delta","text":"half an answer"}}}
        \(Self.notFoundFrame())
        """
        let stub = try ResumeStub(
            withResume: frame, exitingWith: 1,
            withoutResume: Self.successFrames(), exitingWith: 0
        )

        await #expect(throws: ClaudeRunner.Failure.backendError) {
            _ = try await collect(from: stub, resuming: "dead")
        }

        #expect(
            try stub.invocations().count == 1,
            "the user saw a partial reply and the prompt was then run again"
        )
    }

    /// The retry happens once. A second refusal is reported, not retried again
    /// — a stub that refuses both ways stands in for a CLI whose store is
    /// broken rather than merely missing one conversation.
    @Test("a retry that also fails is not retried again")
    func retryDoesNotLoop() async throws {
        let stub = try ResumeStub(
            withResume: Self.notFoundFrame(), exitingWith: 1,
            withoutResume: Self.notFoundFrame(), exitingWith: 1
        )

        await #expect(throws: ClaudeRunner.Failure.backendError) {
            _ = try await collect(from: stub, resuming: "dead")
        }

        #expect(try stub.invocations().count == 2, "the retry looped")
    }

    /// The ordinary path, unchanged: a resume the CLI accepts runs once.
    @Test("an accepted resume runs once")
    func acceptedResumeRunsOnce() async throws {
        let stub = try ResumeStub(
            withResume: Self.successFrames(), exitingWith: 0,
            withoutResume: Self.notFoundFrame(), exitingWith: 1
        )

        let outputs = try await collect(from: stub, resuming: "s-live")

        #expect(outputs.compactMap(\.deltaText).joined() == "fresh reply")
        #expect(try stub.invocations().count == 1)
    }

    // MARK: - Helpers

    private func collect(from stub: ResumeStub, resuming: String?) async throws -> [TurnOutput] {
        let backend = ClaudeBackend(executable: stub.path)
        var outputs: [TurnOutput] = []

        for try await output in backend.run(prompt: "hello", resuming: resuming, workspace: nil) {
            outputs.append(output)
        }
        return outputs
    }
}

/// A stub CLI that answers differently with and without `--resume`, and records
/// every invocation.
///
/// The log is the instrument. Whether a retry happened is not visible in the
/// event stream — a second run producing the same text looks like one run — so
/// the count of lines in this file is what the tests actually assert on.
private struct ResumeStub {
    let path: String
    private let logPath: String

    init(
        withResume resumeOutput: String, exitingWith resumeStatus: Int,
        withoutResume freshOutput: String, exitingWith freshStatus: Int
    ) throws {
        let directory = FileManager.default.temporaryDirectory
        let identifier = UUID().uuidString
        logPath = directory.appendingPathComponent("localis-resume-log-\(identifier)").path

        // `"$@"` records the argument vector as the CLI received it, so the
        // "did the retry drop --resume?" assertion reads the real arguments
        // rather than re-deriving them from `ClaudeInvocation`.
        let script = """
        echo "$@" >> \(Self.quote(logPath))
        case " $@ " in
          *" --resume "*)
            printf '%s\\n' \(Self.quote(resumeOutput))
            exit \(resumeStatus)
            ;;
          *)
            printf '%s\\n' \(Self.quote(freshOutput))
            exit \(freshStatus)
            ;;
        esac
        """

        let url = directory.appendingPathComponent("localis-resume-stub-\(identifier).sh")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        path = url.path
    }

    /// One entry per process the backend started, in order, each the argument
    /// vector it was given.
    ///
    /// A missing log means zero invocations, which is a legitimate answer —
    /// and a distinguishable one, since every test here expects at least one.
    func invocations() throws -> [String] {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension TurnOutput {
    var deltaText: String? {
        guard case .event(.delta(let text)) = self else { return nil }
        return text
    }

    var backendSession: String? {
        guard case .backendSession(let id) = self else { return nil }
        return id
    }
}

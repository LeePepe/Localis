import BridgeCore
import Foundation

/// `ClaudeRunner` as a `TurnRunning` backend.
///
/// A separate type rather than a conformance on `ClaudeRunner` itself, so the
/// runner stays testable as "spawn this process and decode its output" without
/// dragging the contract's turn vocabulary into it.
public struct ClaudeBackend: TurnRunning {
    public let backendID = "claude"

    private let runner: ClaudeRunner

    public init(executable: String) {
        self.runner = ClaudeRunner(executable: executable)
    }

    /// The descriptor this backend advertises in `GET /v1/models`.
    ///
    /// `available` is decided by whether the binary is there — checked once at
    /// startup, because a phone showing "Claude Code" for a CLI that is not
    /// installed produces a turn that fails with no explanation the user can
    /// act on.
    public static func descriptor(executable: String?) -> BackendDescriptor {
        BackendDescriptor(
            id: "claude",
            displayName: "Claude Code",
            capabilities: ["streaming", "tools", "workspace"],
            available: executable != nil,
            unavailableReason: executable == nil ? "not_installed" : nil
        )
    }

    public func run(
        prompt: String,
        resuming: String?,
        workspace: String?
    ) -> AsyncThrowingStream<TurnOutput, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let first = try await attempt(
                        ClaudeInvocation(prompt: prompt, resuming: resuming, workspace: workspace),
                        resuming: resuming,
                        into: continuation
                    )

                    switch first {
                    case .finished:
                        continuation.finish()

                    case .failed(let error):
                        continuation.finish(throwing: error)

                    case .retryWithoutResume:
                        // The conversation the client asked to continue is gone
                        // from the CLI's store, and nothing ran. Starting fresh
                        // loses the history — but the alternative is a session
                        // that can never send another message, because every
                        // turn resumes the same id and the CLI refuses it.
                        //
                        // `resuming: nil` here is what makes this terminate:
                        // `attempt` only returns `.retryWithoutResume` when it
                        // was given a resume target, so a second retry is not
                        // reachable — no counter needed.
                        //
                        // The dead mapping is not deleted, it is overwritten: a
                        // successful attempt emits a fresh `session_id`, which
                        // the coordinator files under the same session. If this
                        // attempt also fails the stale id survives, and the next
                        // turn takes this same path again — worse than fixing it
                        // now, but not stranded.
                        let second = try await attempt(
                            ClaudeInvocation(prompt: prompt, resuming: nil, workspace: workspace),
                            resuming: nil,
                            into: continuation
                        )
                        switch second {
                        case .finished:
                            continuation.finish()
                        case .failed(let error):
                            continuation.finish(throwing: error)
                        case .retryWithoutResume:
                            // Unreachable: `attempt` requires a non-nil
                            // `resuming` to ask for this. Reported rather than
                            // silently retried, so a change that breaks the
                            // invariant surfaces as a failed turn instead of a
                            // loop that runs the user's prompt repeatedly.
                            continuation.finish(throwing: ClaudeRunner.Failure.backendError)
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// How one invocation ended, from the caller's point of view.
    private enum Attempt {
        case finished
        case failed(any Error)
        /// The CLI refused the `--resume` target and did no work. Only ever
        /// returned when this attempt actually had a resume target.
        case retryWithoutResume
    }

    /// Runs one invocation, forwarding its outputs, and reports how it ended.
    ///
    /// Never finishes the continuation — the caller decides that, because it is
    /// the caller that knows whether another attempt is coming.
    private func attempt(
        _ invocation: ClaudeInvocation,
        resuming: String?,
        into continuation: AsyncThrowingStream<TurnOutput, any Error>.Continuation
    ) async throws -> Attempt {
        // **Anything the client has already seen forbids a retry.** The rule
        // this enforces is not about correctness of the transcript alone: a
        // second attempt re-sends the whole prompt, and these CLIs run commands
        // on the user's machine. `ResumeFailure` already proves `num_turns` was
        // 0, so for the failure we have observed this stays false; it is here
        // for the dialect we have not observed, where "nothing ran" and "you
        // saw nothing" could come apart.
        var producedOutput = false

        for try await output in runner.run(invocation) {
            switch output {
            case .event(let event):
                producedOutput = true
                continuation.yield(.event(event))

            case .session(let id):
                producedOutput = true
                continuation.yield(.backendSession(id))

            case .ended(let result):
                // The turn's outcome, not an event: the coordinator mints
                // `turn_end` because only it knows the turn id. A failure has to
                // be raised as an error, or a failed turn would end as
                // `completed`.
                guard result.outcome == .failed else { continue }

                if result.resumeWasRejected, resuming != nil, !producedOutput {
                    return .retryWithoutResume
                }
                return .failed(ClaudeRunner.Failure.backendError)

            case .skipped:
                // A line this decoder had no rule for. Dropped: the CLI ships on
                // its own schedule and an unrecognised frame is not a reason to
                // fail a turn whose text is arriving fine.
                continue
            }
        }

        return .finished
    }
}

/// Reports the runner's failures as contract codes.
extension ClaudeRunner.Failure: BackendFailure {
    public var code: String { rawValue }
}

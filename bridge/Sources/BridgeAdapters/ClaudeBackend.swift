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
        let invocation = ClaudeInvocation(prompt: prompt, resuming: resuming, workspace: workspace)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await output in runner.run(invocation) {
                        switch output {
                        case .event(let event):
                            continuation.yield(.event(event))

                        case .session(let id):
                            continuation.yield(.backendSession(id))

                        case .ended(let result):
                            // The turn's outcome, not an event: the coordinator
                            // mints `turn_end` because only it knows the turn
                            // id. A failure has to be raised as an error, or a
                            // failed turn would end as `completed`.
                            if result.outcome == .failed {
                                continuation.finish(throwing: ClaudeRunner.Failure.backendError)
                                return
                            }

                        case .skipped:
                            // A line this decoder had no rule for. Dropped:
                            // the CLI ships on its own schedule and an
                            // unrecognised frame is not a reason to fail a turn
                            // whose text is arriving fine.
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Reports the runner's failures as contract codes.
extension ClaudeRunner.Failure: BackendFailure {
    public var code: String { rawValue }
}

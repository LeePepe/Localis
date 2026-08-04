import BridgeCore
import Foundation

/// Runs the claude CLI and turns its stdout into contract events.
///
/// The bridge exists because an iOS sandbox cannot do this: fork a local
/// process and read its output. Everything else in this program is transport
/// around this one capability.
///
/// Streams via `AsyncThrowingStream` rather than collecting and returning: the
/// user is watching the reply appear, so a function that waits for the process
/// to exit would deliver a correct answer far too late (SC-002 puts first
/// token at p95 ≤ 1.5s).
public struct ClaudeRunner: Sendable {
    /// What went wrong before or during a run.
    ///
    /// Codes rather than the CLI's own text: its messages name files and
    /// directories, which must not reach the client (constitution I).
    public enum Failure: String, Error, Sendable {
        /// The `claude` binary is not on this machine, or not where we looked.
        case backendUnavailable = "backend_unavailable"
        /// The process started and exited non-zero.
        case backendError = "backend_error"
    }

    /// Absolute path to the CLI.
    ///
    /// Resolved once at startup and injected, not looked up per turn. A `PATH`
    /// lookup inside the run would make each turn depend on the environment the
    /// bridge happened to inherit — and a shim earlier on `PATH` than the real
    /// binary is a thing that actually happens on this project's own machines.
    public let executable: String

    public init(executable: String) {
        self.executable = executable
    }

    /// Runs one turn.
    ///
    /// The stream yields decoder outputs — events, the CLI's session id, and
    /// the turn's result — in the order they arrive. It finishes when the
    /// process exits, and throws only when the turn cannot be delivered at all.
    public func run(_ invocation: ClaudeInvocation) -> AsyncThrowingStream<ClaudeStreamOutput, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = invocation.arguments
            if let directory = invocation.workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
            }

            let stdout = Pipe()
            process.standardOutput = stdout
            // stderr goes to its own pipe and is drained but not forwarded. The
            // CLI writes progress and diagnostics there, which routinely name
            // absolute paths — leaving it inherited would put those in the
            // bridge's own output (constitution I), and leaving it unread would
            // deadlock the child once the pipe buffer fills.
            let stderr = Pipe()
            process.standardError = stderr
            stderr.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }

            // One accumulator for the life of the process: a line split across
            // two reads only rejoins if the same buffer sees both halves.
            let state = RunState()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }

                for line in state.append(chunk) {
                    for output in ClaudeStreamDecoder.decode(line: line) {
                        continuation.yield(output)
                    }
                }
            }

            process.terminationHandler = { process in
                // Detach the handlers before the final flush so a late read
                // cannot yield after the stream has finished.
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                // Whatever the last read left unterminated. For claude this is
                // routinely the `result` frame — usage and the turn's outcome —
                // which arrives without a trailing newline at EOF.
                let trailing = stdout.fileHandleForReading.availableData
                let lines = trailing.isEmpty ? state.flush() : state.append(trailing) + state.flush()
                for line in lines {
                    for output in ClaudeStreamDecoder.decode(line: line) {
                        continuation.yield(output)
                    }
                }

                // A non-zero exit after a complete stream is still a failed
                // turn: the decoder's `result` frame may never have arrived, and
                // finishing normally would leave the client waiting for an end
                // that is not coming.
                if process.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: Failure.backendError)
                }
            }

            continuation.onTermination = { reason in
                // Cancellation must actually stop the work. Without this the
                // CLI keeps running — and keeps costing tokens — after the user
                // has stopped the turn (§4).
                guard case .cancelled = reason, process.isRunning else { return }
                process.terminate()
            }

            do {
                try process.run()
            } catch {
                // The binary is missing or not executable. Reported as a code
                // the client can map, never as the underlying message, which
                // contains the path we tried.
                continuation.finish(throwing: Failure.backendUnavailable)
            }
        }
    }
}

/// The accumulator, shared between the read handler and the termination
/// handler.
///
/// A `final class` with a lock rather than an `actor`: both callers are
/// synchronous callbacks on Foundation's own queues, and `await`ing from them
/// is not available. The lock is uncontended in practice — the handlers do not
/// run concurrently — but "in practice" is not a guarantee Foundation makes.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = LineAccumulator()

    func append(_ chunk: Data) -> [String] {
        lock.withLock { accumulator.append(chunk) }
    }

    func flush() -> [String] {
        lock.withLock { accumulator.flush() }
    }
}

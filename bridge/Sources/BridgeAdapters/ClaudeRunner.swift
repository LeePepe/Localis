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

            // One accumulator for the life of the process, and one lock that
            // covers **taking the bytes out of the pipe** as well as decoding
            // and yielding them. Foundation runs `readabilityHandler` and
            // `terminationHandler` on separate queues and does not wait for an
            // in-flight read before firing termination, so the two overlap.
            //
            // Locking less than this is not enough, and both narrower versions
            // were measured failing:
            //
            // - Locking only the line buffer leaves the yield outside, so
            //   termination can finish the stream between a read's `append` and
            //   its `yield`.
            // - Locking the decode but reading `availableData` outside it loses
            //   the same output a different way: the reader takes the bytes,
            //   termination wins the lock, drains a pipe that is *already
            //   empty*, and finishes — then the reader's yield lands on a
            //   finished continuation and is discarded.
            //
            // With the read inside, the two orders are both correct: the reader
            // holds the lock from `availableData` through `yield`, so
            // termination either waits and finds nothing left, or goes first and
            // drains everything itself.
            let state = RunState()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                state.read(from: handle) { continuation.yield($0) }
            }

            process.terminationHandler = { process in
                // Detach the handlers before the final flush so a late read
                // cannot yield after the stream has finished.
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                // Whatever the last read left unterminated. For claude this is
                // routinely the `result` frame — usage and the turn's outcome —
                // which arrives without a trailing newline at EOF.
                state.finishing {
                    state.readLocked(from: stdout.fileHandleForReading) { continuation.yield($0) }
                    state.flushLocked { continuation.yield($0) }

                    // A non-zero exit after a complete stream is still a failed
                    // turn: the decoder's `result` frame may never have arrived,
                    // and finishing normally would leave the client waiting for
                    // an end that is not coming.
                    if process.terminationStatus == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Failure.backendError)
                    }
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
/// synchronous callbacks on Foundation's own queues, and `await`ing from them is
/// not available.
///
/// **The lock covers the pipe read, not just the buffer.** Two narrower versions
/// were written and both lost output under load — see the comment at the call
/// site for how each one fails. `availableData` is destructive, so a read that
/// happens outside the critical section can hand its bytes to a caller who then
/// loses the race to yield them, and the pipe no longer has them for anyone
/// else. Reading inside makes "who takes the bytes" and "who publishes them" the
/// same decision.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = LineAccumulator()

    /// Drains the handle, decodes, and yields — all under the lock.
    func read(from handle: FileHandle, _ yield: (ClaudeStreamOutput) -> Void) {
        lock.withLock { readLocked(from: handle, yield) }
    }

    /// Runs `body` under the lock, so a caller that needs several steps to be
    /// one atomic unit — drain, flush, finish — gets exactly that.
    func finishing(_ body: () -> Void) {
        lock.withLock(body)
    }

    /// Only from inside `finishing`.
    func readLocked(from handle: FileHandle, _ yield: (ClaudeStreamOutput) -> Void) {
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }

        for line in accumulator.append(chunk) {
            for output in ClaudeStreamDecoder.decode(line: line) {
                yield(output)
            }
        }
    }

    /// Only from inside `finishing`.
    func flushLocked(_ yield: (ClaudeStreamOutput) -> Void) {
        for line in accumulator.flush() {
            for output in ClaudeStreamDecoder.decode(line: line) {
                yield(output)
            }
        }
    }
}

import Foundation

/// Runs turns and keeps the handles cancel needs.
///
/// The sequence numbers are minted here rather than by each backend: `seq` is
/// the client's resume cursor (§3.3), so it has to be monotonic from 0 across
/// everything a turn emits, whatever produced it. A backend that numbered its
/// own events would restart the count on every adapter.
public actor TurnCoordinator {
    private let sessions: SessionStore
    private var running: [String: Task<Void, Never>] = [:]
    /// Which device started each turn, so a second phone cannot cancel it.
    private var owners: [String: String] = [:]

    public init(sessions: SessionStore) {
        self.sessions = sessions
    }

    /// A fresh turn id.
    ///
    /// Random, not sequential. Turn ids appear in `/v1/turns/{id}/cancel` and
    /// `/resume`, so a predictable id lets one paired device guess another's
    /// turn — the ownership check below is the wall, but a guessable id is the
    /// ladder.
    public static func generateTurnID() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return "t-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Starts a turn and returns its id together with the SSE frames it will
    /// produce.
    ///
    /// The id comes back immediately, before the first event, because the
    /// server writes it into the response head — a client that learns the id
    /// only at the end cannot resume a turn that was interrupted, which is the
    /// only situation resume exists for.
    public func start(
        _ request: TurnRequest,
        on runner: any TurnRunning,
        deviceID: String
    ) -> (turnID: String, events: BridgeEventStream) {
        let turnID = Self.generateTurnID()
        owners[turnID] = deviceID

        let stream = BridgeEventStream { continuation in
            let task = Task {
                await self.pump(request, on: runner, turnID: turnID, into: continuation)
            }
            running[turnID] = task

            continuation.onTermination = { _ in
                // The client hung up. Without this the CLI keeps running, and
                // keeps costing tokens, for a reply nobody will read.
                task.cancel()
            }
        }

        return (turnID, stream)
    }

    /// Cancels a turn, if this device owns it.
    public func cancel(turnID: String, deviceID: String) -> CancelOutcome {
        guard let owner = owners[turnID] else { return .unknownTurn }
        guard owner == deviceID else { return .notYours }

        running[turnID]?.cancel()
        running[turnID] = nil
        return .cancelled
    }

    public enum CancelOutcome: Sendable, Equatable {
        case cancelled
        /// 404. No such turn, or it ended long enough ago to be forgotten.
        case unknownTurn
        /// 403. The turn exists and belongs to another device — answered
        /// distinctly from 404 because the client's remedies differ, and
        /// because the requester already knows the id.
        case notYours
    }

    // MARK: - Pumping

    /// Drives one turn from the runner's outputs to encoded SSE frames.
    private func pump(
        _ request: TurnRequest,
        on runner: any TurnRunning,
        turnID: String,
        into continuation: BridgeEventStream.Continuation
    ) async {
        guard let prompt = request.prompt else {
            finish(turnID: turnID, continuation: continuation, seq: 0, outcome: .failed, code: "invalid_request")
            return
        }

        let resuming = await resumeToken(for: request)
        var seq = 0
        var sawFailure: String?

        func emit(_ event: BridgeEvent) {
            continuation.yield([UInt8](SSEEncoder.encode(SequencedEvent(seq: seq, event: event)).utf8))
            seq += 1
        }

        do {
            for try await output in runner.run(prompt: prompt, resuming: resuming, workspace: request.workspace) {
                // Cancellation has to break the loop as well as stop the child
                // process: the stream may still have buffered output, and
                // forwarding it after the user pressed stop shows text that
                // arrives from a turn they already ended.
                if Task.isCancelled { break }

                switch output {
                case .event(let event):
                    // `[DONE]` and `turn_end` are minted below, once, with the
                    // turn id this coordinator owns. A backend that emitted its
                    // own would terminate the stream early.
                    if case .done = event { continue }
                    if case .turnEnd = event { continue }
                    emit(event)

                case .backendSession(let backendSession):
                    if let sessionID = request.sessionID {
                        await sessions.store(
                            backendSession: backendSession,
                            for: sessionID,
                            backendID: request.backendID
                        )
                    }
                }
            }
        } catch {
            // A code, never the underlying message: adapter errors quote the
            // CLI, whose text names absolute paths (constitution §I).
            sawFailure = (error as? BackendFailure)?.code ?? "backend_error"
        }

        let outcome: TurnEndEvent.Outcome
        if Task.isCancelled {
            outcome = .cancelled
        } else if sawFailure != nil {
            outcome = .failed
        } else {
            outcome = .completed
        }

        finish(turnID: turnID, continuation: continuation, seq: seq, outcome: outcome, code: sawFailure)
    }

    /// Writes `turn_end` and `[DONE]`, then closes.
    ///
    /// Both, always, on every path out of a turn — including failure and
    /// cancellation. A stream that ends without `[DONE]` is read by the client
    /// as a lost connection, which would report a network fault for a turn that
    /// failed for a reason the bridge knows.
    private func finish(
        turnID: String,
        continuation: BridgeEventStream.Continuation,
        seq: Int,
        outcome: TurnEndEvent.Outcome,
        code: String?
    ) {
        let end = TurnEndEvent(turnID: turnID, outcome: outcome, errorCode: code)
        continuation.yield([UInt8](SSEEncoder.encode(SequencedEvent(seq: seq, event: .turnEnd(end))).utf8))
        continuation.yield([UInt8](SSEEncoder.encode(SequencedEvent(seq: nil, event: .done)).utf8))
        continuation.finish()

        running[turnID] = nil
    }

    /// The backend's own session id for this conversation, if we have one.
    private func resumeToken(for request: TurnRequest) async -> String? {
        guard let sessionID = request.sessionID else { return nil }
        return await sessions.backendSession(for: sessionID, backendID: request.backendID)
    }
}

/// An error a backend can report as a contract code.
///
/// Adapters conform their own failures to this rather than having the
/// coordinator know their types — the alternative is a `switch` over every
/// backend's error enum in the one file that is supposed not to know backends
/// exist.
public protocol BackendFailure: Error, Sendable {
    /// A code from the contract's §6 vocabulary.
    var code: String { get }
}

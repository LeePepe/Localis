import Foundation
import LocalisModels
import SessionStore
import TransportKit

/// Orchestrates one chat turn: validate → persist the user message → stream the
/// reply → persist each update.
///
/// This is the only place that knows the *order* of those steps. It depends on
/// `AgentTransport` and `SessionRepository` as protocols, so it is fully
/// testable against fakes with no live agent and no disk.
public actor ChatService {
    private let transport: any AgentTransport
    private let repository: any SessionRepository
    /// Injected so tests get deterministic timestamps and ids.
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        transport: any AgentTransport,
        repository: any SessionRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.transport = transport
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    /// Sends `prompt` in `session` and streams the assistant reply.
    ///
    /// Each yielded `Session` is a complete new snapshot with the assistant
    /// message updated — the view renders the latest one and never mutates.
    ///
    /// - Throws: `LocalisError.invalidInput` for an empty prompt. Transport
    ///   failures surface as a `.failed` assistant message rather than a throw,
    ///   so the transcript keeps the partial text the user already saw.
    public func send(
        prompt: String,
        in session: Session,
        to backend: AgentBackend
    ) async throws -> AsyncThrowingStream<Session, Error> {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalisError.invalidInput(field: "message")
        }

        let userMessage = Message(id: makeID(), role: .user, text: trimmed, createdAt: now())
        let withUser = session.appending(userMessage, at: now())
        try await repository.save(withUser)

        let placeholder = Message(
            id: makeID(),
            role: .assistant,
            text: "",
            createdAt: now(),
            status: .streaming
        )
        let withPlaceholder = withUser.appending(placeholder, at: now())
        try await repository.save(withPlaceholder)

        let request = TransportRequest(
            backend: backend,
            prompt: trimmed,
            history: session.messages
        )
        let events = try await transport.send(request)

        return AsyncThrowingStream { continuation in
            Task { [repository, now] in
                var current = withPlaceholder
                var assistant = placeholder
                // The resume point, advanced as sequenced frames arrive.
                //
                // Always `nil` today: `TransportEvent` is `.chunk` / `.completed`
                // / `.failed`, and none of the three carries a turn id or a
                // `seq`, so there is nothing to build a cursor out of. That is
                // why `.detached` never appears yet — not an unimplemented
                // branch, but a value the current seam cannot express.
                //
                // It is threaded through anyway so that the day the transport
                // yields `SequencedEvent`, assigning here is the whole change:
                // the settlement rule below already reads it, and `.detached`
                // starts appearing without a second decision being made.
                let cursor: TurnCursor? = nil
                continuation.yield(current)

                do {
                    for try await event in events {
                        switch event {
                        case .chunk(let text):
                            assistant = assistant.appending(text)
                        case .completed:
                            assistant = assistant.withStatus(.complete)
                        case .failed(let reason):
                            // Bind the reason. A bare `case .failed:` compiles
                            // and silently discards it, leaving the user with
                            // "Error" and no way to tell a revoked token from
                            // a dropped connection.
                            assistant = assistant.withStatus(.failed)
                            current = current
                                .replacing(assistant, at: now())
                                .withStatus(.error(reason), at: now())
                            try? await repository.save(current)
                            continuation.yield(current)
                            continuation.finish()
                            return
                        }
                        current = current.replacing(assistant, at: now())
                        try await repository.save(current)
                        continuation.yield(current)
                    }
                    // A stream that ends without an explicit `.completed` is
                    // still a finished turn — don't strand it as `.streaming`.
                    if assistant.status == .streaming {
                        assistant = assistant.withStatus(.complete)
                        current = current.replacing(assistant, at: now())
                    }
                    // A turn that finished clears any error the previous one
                    // left behind. Without this, one bad turn marks the
                    // conversation broken for good: `canSend` stays false and
                    // the composer refuses input on a session that works
                    // (FR-053).
                    current = current.withStatus(.idle, at: now())
                    try await repository.save(current)
                    continuation.yield(current)
                } catch {
                    // Keep the partial text the user already read, and settle
                    // it by the one rule rather than assuming the worst: a
                    // stream that dies under us is not automatically `.failed`.
                    let reason = Self.localisError(from: error)
                    let settled = Self.settledStatus(for: reason, cursor: cursor)
                    assistant = assistant.withStatus(settled)
                    current = current
                        .replacing(assistant, at: now())
                        .withStatus(
                            Self.sessionStatus(for: settled, reason: reason),
                            at: now()
                        )
                    try? await repository.save(current)
                    continuation.yield(current)
                }
                continuation.finish()
            }
        }
    }

    /// Maps anything thrown out of the transport into the one error vocabulary.
    ///
    /// `AgentTransport` conformers are required to map their own failures
    /// before they escape, so a foreign error arriving here means that rule was
    /// broken somewhere upstream. It still must not get past this layer: a
    /// `URLError` reaching the UI renders as text no user can read, and its
    /// description can carry a full endpoint (constitution I).
    ///
    /// `connectionLost` is the honest fallback — the turn did stop mid-flight,
    /// and it is the reading that stays retryable, which is the safe answer
    /// when the real cause is unknown.
    private static func localisError(from error: any Error) -> LocalisError {
        error as? LocalisError ?? .connectionLost
    }

    /// How a turn that broke mid-flight settles.
    ///
    /// Two questions, each answered by the one place that owns it:
    ///
    /// 1. **Is the break survivable at all?** `LocalisError.isRetryable` says.
    ///    A revoked token and a dropped connection produce the same broken
    ///    stream, but resuming the first only replays the refusal — no cursor
    ///    rescues it, so it settles `.failed`.
    /// 2. **Is a survivable break resumable?** `TurnReconciliation.resolve`
    ///    says, from the cursor.
    ///
    /// Neither judgement is made here. Writing `if cursor != nil` in this file
    /// would agree with the store by coincidence, and the first refactor on
    /// either side would end the agreement silently — which is the failure mode
    /// three layers of defence exist to avoid.
    static func settledStatus(for reason: LocalisError, cursor: TurnCursor?) -> MessageStatus {
        guard reason.isRetryable else { return .failed }

        // `.streaming` is the honest input: the turn was mid-flight when the
        // link died. The store reads that as "the process that owned this
        // stream is gone", which is exactly what happened.
        switch TurnReconciliation.resolve(state: .streaming, cursor: cursor) {
        case .stillRunning:
            return .detached
        case .lost:
            return .interrupted
        case .settled, .failed:
            // Unreachable from `.streaming`, and deliberately not folded into
            // the cases above: a future `resolve` gaining a state should fail
            // here loudly rather than settle a live turn as finished.
            return .interrupted
        }
    }

    /// What the conversation reads as once its turn settled.
    ///
    /// `.detached` is the case worth spelling out: the turn is running fine on
    /// the host, so an `.error` banner would be a lie about the work. The link
    /// is what is gone, so the session reads `.disconnected` — and `canSend`
    /// stays false, which is correct, because starting a second turn while the
    /// first generates is the precise harm Amendment C §1.5 exists to prevent.
    static func sessionStatus(for settled: MessageStatus, reason: LocalisError) -> SessionStatus {
        settled.isInFlight ? .disconnected : .error(reason)
    }
}

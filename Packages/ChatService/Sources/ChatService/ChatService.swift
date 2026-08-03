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
                    // Keep the partial text the user already read; mark it
                    // failed so the UI can offer a retry.
                    assistant = assistant.withStatus(.failed)
                    current = current
                        .replacing(assistant, at: now())
                        .withStatus(.error(Self.localisError(from: error)), at: now())
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
}

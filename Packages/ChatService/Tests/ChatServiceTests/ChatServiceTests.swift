import Foundation
import Testing

@testable import ChatService

import LocalisModels
import SessionStore
import TransportKit

/// Transport fake that replays a fixed event script.
private struct ScriptedTransport: AgentTransport {
    let events: [TransportEvent]
    /// When set, the stream throws after replaying `events`.
    let failure: (any Error)?

    init(events: [TransportEvent], failure: (any Error)? = nil) {
        self.events = events
        self.failure = failure
    }

    func send(_ request: TransportRequest) async throws -> AsyncThrowingStream<TransportEvent, Error> {
        let events = events
        let failure = failure
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish(throwing: failure)
        }
    }

    func probe(_ backend: AgentBackend) async -> Bool { true }
}

@Suite("ChatService")
struct ChatServiceTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeBackend() throws -> AgentBackend {
        AgentBackend(
            id: UUID(),
            kind: .claude,
            name: "Test",
            endpoint: try #require(URL(string: "http://127.0.0.1:8080"))
        )
    }

    private static func makeSession(backendID: UUID) -> Session {
        Session(id: UUID(), backendID: backendID, title: "Test", createdAt: t0, updatedAt: t0)
    }

    private static func makeService(
        transport: ScriptedTransport,
        repository: InMemorySessionRepository
    ) -> ChatService {
        ChatService(transport: transport, repository: repository, now: { t0 })
    }

    @Test("an empty prompt is rejected before anything is persisted")
    func rejectsEmptyPrompt() async throws {
        let backend = try Self.makeBackend()
        let repository = InMemorySessionRepository()
        let service = Self.makeService(
            transport: ScriptedTransport(events: []),
            repository: repository
        )

        await #expect(throws: LocalisError.invalidInput(field: "message")) {
            _ = try await service.send(
                prompt: "   ",
                in: Self.makeSession(backendID: backend.id),
                to: backend
            )
        }
        #expect(try await repository.allSessions().isEmpty)
    }

    @Test("streamed chunks accumulate into one complete assistant message")
    func accumulatesChunks() async throws {
        let backend = try Self.makeBackend()
        let repository = InMemorySessionRepository()
        let service = Self.makeService(
            transport: ScriptedTransport(events: [.chunk("Hel"), .chunk("lo"), .completed]),
            repository: repository
        )

        let stream = try await service.send(
            prompt: "hi",
            in: Self.makeSession(backendID: backend.id),
            to: backend
        )

        var latest: Session?
        for try await snapshot in stream { latest = snapshot }

        let final = try #require(latest)
        #expect(final.messages.count == 2)
        #expect(final.messages[0].role == .user)
        #expect(final.messages[0].text == "hi")
        #expect(final.messages[1].role == .assistant)
        #expect(final.messages[1].text == "Hello")
        #expect(final.messages[1].status == .complete)
    }

    @Test("the final snapshot is persisted to the repository")
    func persistsFinalSnapshot() async throws {
        let backend = try Self.makeBackend()
        let repository = InMemorySessionRepository()
        let session = Self.makeSession(backendID: backend.id)
        let service = Self.makeService(
            transport: ScriptedTransport(events: [.chunk("saved"), .completed]),
            repository: repository
        )

        let stream = try await service.send(prompt: "hi", in: session, to: backend)
        for try await _ in stream {}

        let stored = try #require(try await repository.session(id: session.id))
        #expect(stored.messages.last?.text == "saved")
        #expect(stored.messages.last?.status == .complete)
    }

    @Test("a mid-stream failure keeps partial text and marks the message failed")
    func failureKeepsPartialText() async throws {
        let backend = try Self.makeBackend()
        let repository = InMemorySessionRepository()
        let service = Self.makeService(
            transport: ScriptedTransport(events: [.chunk("par")], failure: LocalisError.connectionLost),
            repository: repository
        )

        let stream = try await service.send(
            prompt: "hi",
            in: Self.makeSession(backendID: backend.id),
            to: backend
        )

        var latest: Session?
        for try await snapshot in stream { latest = snapshot }

        let final = try #require(latest)
        #expect(final.messages.last?.text == "par")
        #expect(final.messages.last?.status == .failed)
    }

    @Test("a stream ending without an explicit completed event still completes")
    func implicitCompletion() async throws {
        let backend = try Self.makeBackend()
        let repository = InMemorySessionRepository()
        let service = Self.makeService(
            transport: ScriptedTransport(events: [.chunk("done")]),
            repository: repository
        )

        let stream = try await service.send(
            prompt: "hi",
            in: Self.makeSession(backendID: backend.id),
            to: backend
        )

        var latest: Session?
        for try await snapshot in stream { latest = snapshot }

        #expect(try #require(latest).messages.last?.status == .complete)
    }
}

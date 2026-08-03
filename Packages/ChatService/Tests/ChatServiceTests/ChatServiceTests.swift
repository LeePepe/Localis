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
    private static let hostID = HostID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    )

    private static func makeBackend() -> AgentBackend {
        AgentBackend(id: "test-backend", displayName: "Test", capabilities: [.streaming])
    }

    private static func makeSession(backendID: String) -> Session {
        Session(
            id: UUID(),
            hostID: hostID,
            backendID: backendID,
            title: "Test",
            createdAt: t0,
            updatedAt: t0
        )
    }

    /// The repository only ever *updates* a session it already holds — `save`
    /// is a no-op for an unknown id, because FR-030 fixes the host binding and
    /// a save is not allowed to invent one. So a service test seeds it first,
    /// the same way the real app creates a session before the first turn.
    private static func makeRepository(seeding session: Session) -> InMemorySessionRepository {
        InMemorySessionRepository(sessions: [session])
    }

    private static func makeService(
        transport: ScriptedTransport,
        repository: InMemorySessionRepository
    ) -> ChatService {
        ChatService(transport: transport, repository: repository, now: { t0 })
    }

    @Test("an empty prompt is rejected before anything is persisted")
    func rejectsEmptyPrompt() async throws {
        let backend = Self.makeBackend()
        let session = Self.makeSession(backendID: backend.id)
        let repository = Self.makeRepository(seeding: session)
        let service = Self.makeService(
            transport: ScriptedTransport(events: []),
            repository: repository
        )

        await #expect(throws: LocalisError.invalidInput(field: "message")) {
            _ = try await service.send(prompt: "   ", in: session, to: backend)
        }

        // Rejected before the transcript was touched — the seeded session is
        // still empty rather than carrying a blank user turn.
        let stored = try #require(try await repository.session(id: session.id))
        #expect(stored.messages.isEmpty)
    }

    @Test("streamed chunks accumulate into one complete assistant message")
    func accumulatesChunks() async throws {
        let backend = Self.makeBackend()
        let session = Self.makeSession(backendID: backend.id)
        let repository = Self.makeRepository(seeding: session)
        let service = Self.makeService(
            transport: ScriptedTransport(events: [.chunk("Hel"), .chunk("lo"), .completed]),
            repository: repository
        )

        let stream = try await service.send(prompt: "hi", in: session, to: backend)

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
        let backend = Self.makeBackend()
        let session = Self.makeSession(backendID: backend.id)
        let repository = Self.makeRepository(seeding: session)
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
        let backend = Self.makeBackend()
        let session = Self.makeSession(backendID: backend.id)
        let repository = Self.makeRepository(seeding: session)
        let service = Self.makeService(
            transport: ScriptedTransport(
                events: [.chunk("par")], failure: LocalisError.connectionLost
            ),
            repository: repository
        )

        let stream = try await service.send(prompt: "hi", in: session, to: backend)

        var latest: Session?
        for try await snapshot in stream { latest = snapshot }

        let final = try #require(latest)
        #expect(final.messages.last?.text == "par")
        #expect(final.messages.last?.status == .failed)
    }

    @Test("a stream ending without an explicit completed event still completes")
    func implicitCompletion() async throws {
        let backend = Self.makeBackend()
        let session = Self.makeSession(backendID: backend.id)
        let repository = Self.makeRepository(seeding: session)
        let service = Self.makeService(
            transport: ScriptedTransport(events: [.chunk("done")]),
            repository: repository
        )

        let stream = try await service.send(prompt: "hi", in: session, to: backend)

        var latest: Session?
        for try await snapshot in stream { latest = snapshot }

        #expect(try #require(latest).messages.last?.status == .complete)
    }
}

/// The invariants that only appear once more than one machine is paired
/// (Amendment A). A single-host suite passes happily while every one of these
/// is broken.
@Suite("ChatService is host-scoped")
struct ChatServiceHostScopeTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hostA = HostID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    )
    private static let hostB = HostID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    )
    private static let backend = AgentBackend(
        id: "claude", displayName: "Claude", capabilities: [.streaming]
    )

    private static func session(on host: HostID) -> Session {
        Session(
            id: UUID(),
            hostID: host,
            backendID: "claude",
            title: "Test",
            createdAt: t0,
            updatedAt: t0
        )
    }

    @Test("a turn never moves its session to another machine")
    func hostBindingSurvivesATurn() async throws {
        // FR-030. `Session` makes this unconstructable, so this test is aimed
        // at a future `send` that rebuilds the session from parts rather than
        // deriving it — the one remaining way the guarantee could be lost.
        let original = Self.session(on: Self.hostB)
        let repository = InMemorySessionRepository(sessions: [original])
        let service = ChatService(
            transport: ScriptedTransport(events: [.chunk("hi"), .completed]),
            repository: repository,
            now: { Self.t0 }
        )

        var latest: Session?
        for try await s in try await service.send(
            prompt: "hi", in: original, to: Self.backend
        ) { latest = s }

        #expect(try #require(latest).hostID == Self.hostB)
        let stored = try #require(try await repository.session(id: original.id))
        #expect(stored.hostID == Self.hostB)
    }

    @Test("two machines' turns land in their own transcripts")
    func concurrentHostsDoNotCrossTalk() async throws {
        // Both sessions use the wire id "claude" — the exact collision
        // `BackendRef` exists for (FR-029). Anything keyed off the bare backend
        // id would put one machine's reply in the other machine's transcript.
        let onA = Self.session(on: Self.hostA)
        let onB = Self.session(on: Self.hostB)
        let repository = InMemorySessionRepository(sessions: [onA, onB])

        let serviceA = ChatService(
            transport: ScriptedTransport(events: [.chunk("from A"), .completed]),
            repository: repository,
            now: { Self.t0 }
        )
        let serviceB = ChatService(
            transport: ScriptedTransport(events: [.chunk("from B"), .completed]),
            repository: repository,
            now: { Self.t0 }
        )

        for try await _ in try await serviceA.send(prompt: "hi", in: onA, to: Self.backend) {}
        for try await _ in try await serviceB.send(prompt: "hi", in: onB, to: Self.backend) {}

        let storedA = try #require(try await repository.session(id: onA.id))
        let storedB = try #require(try await repository.session(id: onB.id))
        #expect(storedA.messages.last?.text == "from A")
        #expect(storedB.messages.last?.text == "from B")
        #expect(storedA.hostID == Self.hostA)
        #expect(storedB.hostID == Self.hostB)
    }
}

/// What the user finds when they come back (Amendment C).
///
/// The third line of defence. `MessageStatus.isRetryable` refuses a retry on a
/// still-running turn and the UI declines to draw the control — but both of
/// those read a status this layer decided. If the service settles a turn
/// dishonestly, the two guards above it are reading a wrong answer carefully.
@Suite("ChatService settles turns honestly")
struct ChatServiceSettlementTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hostID = HostID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    )
    private static let backend = AgentBackend(
        id: "claude", displayName: "Claude", capabilities: [.streaming]
    )

    private static func makeSession() -> Session {
        Session(
            id: UUID(),
            hostID: hostID,
            backendID: "claude",
            title: "Test",
            createdAt: t0,
            updatedAt: t0
        )
    }

    @Test("a failed turn is never left in flight")
    func failureIsTerminal() async throws {
        // The worst outcome is not "failed" — it is a message stuck at
        // `.streaming`, which renders as a spinner that never stops and gives
        // the user nothing to act on.
        let session = Self.makeSession()
        let repository = InMemorySessionRepository(sessions: [session])
        let service = ChatService(
            transport: ScriptedTransport(
                events: [.chunk("par")], failure: LocalisError.connectionLost
            ),
            repository: repository,
            now: { Self.t0 }
        )

        for try await _ in try await service.send(
            prompt: "hi", in: session, to: Self.backend
        ) {}

        let stored = try #require(try await repository.session(id: session.id))
        let assistant = try #require(stored.messages.last)
        #expect(!assistant.isInFlight)
        #expect(assistant.isTerminal)
    }

    @Test("a failure is retryable and a completed turn is not")
    func retryabilityMatchesOutcome() async throws {
        let session = Self.makeSession()
        let repository = InMemorySessionRepository(sessions: [session])
        let failing = ChatService(
            transport: ScriptedTransport(events: [], failure: LocalisError.connectionLost),
            repository: repository,
            now: { Self.t0 }
        )

        var failed: Session?
        for try await s in try await failing.send(
            prompt: "hi", in: session, to: Self.backend
        ) { failed = s }
        #expect(try #require(failed).messages.last?.isRetryable == true)

        let ok = Self.makeSession()
        let okRepository = InMemorySessionRepository(sessions: [ok])
        let succeeding = ChatService(
            transport: ScriptedTransport(events: [.chunk("hi"), .completed]),
            repository: okRepository,
            now: { Self.t0 }
        )

        var done: Session?
        for try await s in try await succeeding.send(
            prompt: "hi", in: ok, to: Self.backend
        ) { done = s }
        #expect(try #require(done).messages.last?.isRetryable == false)
    }

    @Test("the partial text the user already read is never discarded")
    func partialTextSurvivesFailure() async throws {
        // FR-019. Throwing out of the stream would take the text with it, and
        // the user would watch words appear and then vanish.
        let session = Self.makeSession()
        let repository = InMemorySessionRepository(sessions: [session])
        let service = ChatService(
            transport: ScriptedTransport(
                events: [.chunk("half an "), .chunk("answer")],
                failure: LocalisError.connectionLost
            ),
            repository: repository,
            now: { Self.t0 }
        )

        for try await _ in try await service.send(
            prompt: "hi", in: session, to: Self.backend
        ) {}

        let stored = try #require(try await repository.session(id: session.id))
        #expect(stored.messages.last?.text == "half an answer")
    }
}

/// A failure the user cannot act on is barely better than no failure at all.
///
/// Contract §3.1(d) makes the reason a MUST, and `SessionStatus.error` is a
/// historical fact — nothing can recompute after a relaunch *why* a turn died.
/// So the reason has to leave this layer attached to something that persists.
@Suite("ChatService keeps the reason a turn failed")
struct ChatServiceFailureReasonTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hostID = HostID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    )
    private static let backend = AgentBackend(
        id: "claude", displayName: "Claude", capabilities: [.streaming]
    )

    private static func makeSession() -> Session {
        Session(
            id: UUID(),
            hostID: hostID,
            backendID: "claude",
            title: "Test",
            createdAt: t0,
            updatedAt: t0
        )
    }

    @Test("a backend-reported failure carries its reason onto the session")
    func backendFailureKeepsItsReason() async throws {
        // `TransportEvent.failed` carries a `LocalisError`. Matching it as a
        // bare `case .failed:` compiles and silently drops the reason, leaving
        // the user with "Error" and no way to tell a revoked token from a
        // dropped Wi-Fi connection.
        let session = Self.makeSession()
        let repository = InMemorySessionRepository(sessions: [session])
        let service = ChatService(
            transport: ScriptedTransport(
                events: [.chunk("par"), .failed(.tokenRevoked)]
            ),
            repository: repository,
            now: { Self.t0 }
        )

        var latest: Session?
        for try await s in try await service.send(
            prompt: "hi", in: session, to: Self.backend
        ) { latest = s }

        #expect(try #require(latest).status == .error(.tokenRevoked))
        let stored = try #require(try await repository.session(id: session.id))
        #expect(stored.status == .error(.tokenRevoked))
        // The partial text still survives — a reason is added, nothing is lost.
        #expect(stored.messages.last?.text == "par")
        #expect(stored.messages.last?.status == .failed)
    }

    @Test("a transport that throws also leaves its reason on the session")
    func thrownFailureKeepsItsReason() async throws {
        // The other arm of the same rule: a stream that throws is as much a
        // failure as one that reports `.failed`, and the user needs the reason
        // just as much.
        let session = Self.makeSession()
        let repository = InMemorySessionRepository(sessions: [session])
        let service = ChatService(
            transport: ScriptedTransport(
                events: [.chunk("par")], failure: LocalisError.connectionLost
            ),
            repository: repository,
            now: { Self.t0 }
        )

        var latest: Session?
        for try await s in try await service.send(
            prompt: "hi", in: session, to: Self.backend
        ) { latest = s }

        #expect(try #require(latest).status == .error(.connectionLost))
    }

    @Test("a non-Localis error is mapped, never leaked raw")
    func foreignErrorIsMapped() async throws {
        // The layer boundary rule: `URLError` and decoding errors must not
        // escape. If one arrives anyway, it becomes a `LocalisError` here
        // rather than reaching the UI as text no user can read.
        struct Foreign: Error {}
        let session = Self.makeSession()
        let repository = InMemorySessionRepository(sessions: [session])
        let service = ChatService(
            transport: ScriptedTransport(events: [], failure: Foreign()),
            repository: repository,
            now: { Self.t0 }
        )

        var latest: Session?
        for try await s in try await service.send(
            prompt: "hi", in: session, to: Self.backend
        ) { latest = s }

        let status = try #require(latest).status
        guard case .error = status else {
            Issue.record("expected an error status, got \(status)")
            return
        }
    }

    @Test("a turn that succeeds leaves no stale error behind")
    func successClearsToIdle() async throws {
        // The counterpart nobody writes: if a failure sets `.error` and nothing
        // ever clears it, one bad turn marks the conversation broken forever
        // and `canSend` stays false — the composer refuses input on a session
        // that is working fine (FR-053).
        let session = Self.makeSession()
        let repository = InMemorySessionRepository(sessions: [session])
        let service = ChatService(
            transport: ScriptedTransport(events: [.chunk("hi"), .completed]),
            repository: repository,
            now: { Self.t0 }
        )

        var latest: Session?
        for try await s in try await service.send(
            prompt: "hi", in: session, to: Self.backend
        ) { latest = s }

        #expect(try #require(latest).status == .idle)
        #expect(try #require(latest).canSend)
    }
}

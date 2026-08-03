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

    @Test("a mid-stream failure keeps partial text and settles the message")
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
        // `.interrupted`, not `.failed`: a dropped connection lost the content
        // but reported no failure, and Amendment C §1.5 splits the two. See
        // `ChatServiceDetachmentTests` for the rule this follows.
        #expect(final.messages.last?.status == .interrupted)
    }

    @Test("a failure the backend reports is marked failed, not interrupted")
    func reportedFailureIsFailed() async throws {
        // The other side of the split. A revoked token is a real failure with
        // a reason to show; no amount of reconnecting changes it, so calling
        // it `.interrupted` would offer a retry that cannot work.
        let backend = Self.makeBackend()
        let session = Self.makeSession(backendID: backend.id)
        let repository = Self.makeRepository(seeding: session)
        let service = Self.makeService(
            transport: ScriptedTransport(
                events: [.chunk("par")], failure: LocalisError.tokenRevoked
            ),
            repository: repository
        )

        var latest: Session?
        for try await s in try await service.send(
            prompt: "hi", in: session, to: backend
        ) { latest = s }

        let final = try #require(latest)
        #expect(final.messages.last?.status == .failed)
        #expect(final.messages.last?.text == "par")
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

    @Test("a broken turn is never left in flight")
    func failureIsTerminal() async throws {
        // The worst outcome is not "failed" — it is a message stuck at
        // `.streaming`, which renders as a spinner that never stops and gives
        // the user nothing to act on.
        //
        // The assertion is `!isInFlight`, not `isTerminal`: `.interrupted` is
        // deliberately non-terminal (a retry supersedes the message), so
        // demanding terminality here would be testing the wrong property and
        // would forbid the correct settlement.
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
        #expect(assistant.status != .streaming)
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

/// A stream that dies under us is not the same event as a backend reporting
/// failure, and Amendment C §1.5 splits the outcome in two.
///
/// The rule this suite pins, in one sentence: **`LocalisError.isRetryable`
/// decides whether the break is survivable at all, and `TurnReconciliation`
/// decides whether a survivable break is resumable.** Neither judgement is made
/// twice. Writing `if cursor != nil` here would agree with the store by
/// coincidence, and one refactor on either side would end the agreement
/// silently.
@Suite("ChatService distinguishes detached from interrupted")
struct ChatServiceDetachmentTests {
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

    @Test("a dropped connection with no resume point is interrupted, not failed")
    func noCursorIsInterrupted() async throws {
        // `.failed` claims the turn is over *and* that we know why it ended
        // badly. A dropped Wi-Fi connection is neither — the content is simply
        // gone, which is what `.interrupted` says and what makes a retry the
        // right offer (Amendment C §1.5).
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

        let final = try #require(latest)
        let assistant = try #require(final.messages.last)
        #expect(assistant.status == .interrupted)
        #expect(assistant.text == "par")
        #expect(assistant.isRetryable)
        // The host is definitively not working on this any more.
        #expect(!assistant.isInFlight)
    }

    @Test("a failure a retry cannot change stays failed, cursor or not")
    func unretryableErrorIsNeverResumable() {
        // The reason `isRetryable` is the gate rather than a list of
        // "connection-ish" errors: a revoked token produces exactly the same
        // broken stream as a dropped connection, and resuming it would replay
        // the same refusal. No cursor rescues it.
        let cursor = TurnCursor(turnID: "t-9", lastSeq: 12)

        #expect(ChatService.settledStatus(for: .tokenRevoked, cursor: cursor) == .failed)
        #expect(ChatService.settledStatus(for: .tokenRevoked, cursor: nil) == .failed)
        #expect(ChatService.settledStatus(for: .certificatePinMismatch, cursor: cursor) == .failed)
    }

    @Test("a survivable break with a resume point is detached, never retryable")
    func cursorMakesItDetached() {
        // The safety property of the whole amendment: the host is still
        // generating, so offering a retry starts a second job on the user's
        // own machine while the first is still burning tokens.
        let cursor = TurnCursor(turnID: "t-9", lastSeq: 12)
        let status = ChatService.settledStatus(for: .connectionLost, cursor: cursor)

        #expect(status == .detached)
        #expect(!status.isRetryable)
        #expect(status.isInFlight)
    }

    @Test("a survivable break with no resume point is interrupted")
    func noCursorMakesItInterrupted() {
        let status = ChatService.settledStatus(for: .connectionLost, cursor: nil)

        #expect(status == .interrupted)
        #expect(status.isRetryable)
    }

    @Test("the settled status agrees with the store's retry verdict, by derivation")
    func retryabilityAgreesWithTheStore() {
        // The point store made and I am applying to my own layer: three layers
        // of defence only mean anything if they are all derived from one rule.
        // This asserts the agreement directly instead of trusting that two
        // hand-written switches happen to line up.
        let cases: [(LocalisError, TurnCursor?)] = [
            (.connectionLost, TurnCursor(turnID: "t-1", lastSeq: 0)),
            (.connectionLost, nil),
            (.unreachable, TurnCursor(turnID: "t-2", lastSeq: 7)),
            (.truncated, nil),
        ]

        for (error, cursor) in cases {
            let verdict = TurnReconciliation.resolve(state: .streaming, cursor: cursor)
            let status = ChatService.settledStatus(for: error, cursor: cursor)
            #expect(
                status.isRetryable == verdict.allowsRetry,
                "\(error) with cursor \(String(describing: cursor?.turnID)) disagrees"
            )
        }
    }

    @Test("a detached turn is not reported as an error")
    func detachedIsNotAnError() {
        // `.error` puts a red banner on a conversation whose turn is running
        // perfectly well on the host. The link is what is gone, so the session
        // reads `.disconnected` — and `canSend` stays false, which is correct:
        // starting a second turn while the first generates is the exact harm.
        let status = ChatService.sessionStatus(
            for: .detached, reason: .connectionLost
        )

        #expect(status == .disconnected)
    }

    @Test("an interrupted turn keeps the reason on the session")
    func interruptedKeepsItsReason() {
        // Nothing is running any more, so the user is owed the reason and the
        // retry — this is the case where `.error` is the honest reading.
        let status = ChatService.sessionStatus(
            for: .interrupted, reason: .connectionLost
        )

        #expect(status == .error(.connectionLost))
    }
}

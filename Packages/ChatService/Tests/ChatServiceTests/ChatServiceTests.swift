import Foundation
import Testing

@testable import ChatService

import LocalisModels
import SessionStore
import TransportKit

/// Transport fake that replays a fixed event script.
///
/// `turnID` defaults to nil — a bridge older than the resume contract sends no
/// header, and that is the case a fake must be able to express, because it is
/// what makes a broken turn `.interrupted` rather than `.detached`.
private struct ScriptedTransport: AgentTransport {
    let events: [SequencedEvent]
    /// When set, the stream throws after replaying `events`.
    let failure: (any Error)?
    let turnID: String?

    init(events: [SequencedEvent], failure: (any Error)? = nil, turnID: String? = nil) {
        self.events = events
        self.failure = failure
        self.turnID = turnID
    }

    /// Convenience for the many tests that only care about assistant text.
    init(text: [String], failure: (any Error)? = nil, turnID: String? = nil) {
        self.init(
            events: text.enumerated().map { SequencedEvent(seq: $0.offset, event: .delta($0.element)) },
            failure: failure,
            turnID: turnID
        )
    }

    func send(_ request: TurnRequest) async throws -> TurnStream {
        let events = events
        let failure = failure
        return TurnStream(
            turnID: turnID,
            events: AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish(throwing: failure)
            }
        )
    }

    func probe(_ backend: AgentBackend) async -> Bool { true }
}

/// Records the request it was handed, so tests can assert on what this layer
/// *sent* rather than only on what it did with the reply.
///
/// An actor because `AgentTransport` is `Sendable` and `send` is nonisolated —
/// a `var` captured in a struct would be the mutable-state escape hatch strict
/// concurrency exists to refuse.
private actor RecordingTransport: AgentTransport {
    private(set) var received: TurnRequest?

    func send(_ request: TurnRequest) async throws -> TurnStream {
        received = request
        return TurnStream(
            turnID: nil,
            events: AsyncThrowingStream { $0.finish() }
        )
    }

    func probe(_ backend: AgentBackend) async -> Bool { true }
}

/// Builds the `.turnEnd` frame a bridge sends when a turn dies (contract §3.1d).
private func failedTurnEnd(
    seq: Int = 99,
    turnID: String? = "t-1",
    failedAtMs: Int? = 480_000,
    toolCallsCompleted: Int? = 3
) -> SequencedEvent {
    SequencedEvent(
        seq: seq,
        event: .turnEnd(
            TurnEnd(
                turnID: turnID,
                outcome: .failed,
                failedAtMs: failedAtMs,
                toolCallsCompleted: toolCallsCompleted,
                errorCode: "backend_error"
            )
        )
    )
}

private func completedTurnEnd(seq: Int = 99, turnID: String? = "t-1") -> SequencedEvent {
    SequencedEvent(seq: seq, event: .turnEnd(TurnEnd(turnID: turnID, outcome: .completed)))
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
            transport: ScriptedTransport(text: ["Hel", "lo"]),
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
            transport: ScriptedTransport(text: ["saved"]),
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
                text: ["par"], failure: LocalisError.connectionLost
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
                text: ["par"], failure: LocalisError.tokenRevoked
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
            transport: ScriptedTransport(text: ["done"]),
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
            transport: ScriptedTransport(text: ["hi"]),
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
            transport: ScriptedTransport(text: ["from A"]),
            repository: repository,
            now: { Self.t0 }
        )
        let serviceB = ChatService(
            transport: ScriptedTransport(text: ["from B"]),
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
                text: ["par"], failure: LocalisError.connectionLost
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
            transport: ScriptedTransport(text: ["hi"]),
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
                text: ["half an ", "answer"],
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
        // The bridge reports a failure as `.turnEnd(outcome: .failed)` with an
        // `errorCode`. Ignoring the code leaves the user with "Error" and no
        // way to tell a revoked token from a dropped Wi-Fi connection — one
        // needs re-pairing, the other needs nothing but a retry.
        let session = Self.makeSession()
        let repository = InMemorySessionRepository(sessions: [session])
        let service = ChatService(
            transport: ScriptedTransport(
                events: [
                    SequencedEvent(seq: 0, event: .delta("par")),
                    SequencedEvent(
                        seq: 1,
                        event: .turnEnd(
                            TurnEnd(
                                turnID: "t-1",
                                outcome: .failed,
                                failedAtMs: 480_000,
                                toolCallsCompleted: 3,
                                errorCode: "token_revoked"
                            )
                        )
                    ),
                ]
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
                text: ["par"], failure: LocalisError.connectionLost
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
            transport: ScriptedTransport(text: ["hi"]),
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
                text: ["par"], failure: LocalisError.connectionLost
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

/// The two end-to-end gaps the nine-case seam exists to close.
///
/// Every layer had already done its part — the bridge sends the detail, the
/// mapper parses it, the store persists it, the UI renders it. The three-case
/// seam in between was the only thing discarding it, so the whole chain read as
/// finished while the user still saw a bare "Error".
@Suite("ChatService closes the failure-detail and detach gaps")
struct ChatServiceTurnEndTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hostID = HostID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    )
    private static let backend = AgentBackend(
        id: "claude", displayName: "Claude", capabilities: [.streaming]
    )

    private static func makeSession() -> Session {
        Session(
            id: UUID(), hostID: hostID, backendID: "claude",
            title: "Test", createdAt: t0, updatedAt: t0
        )
    }

    private static func run(
        _ transport: ScriptedTransport
    ) async throws -> (session: Session, stored: Session) {
        let session = makeSession()
        let repository = InMemorySessionRepository(sessions: [session])
        let service = ChatService(
            transport: transport, repository: repository, now: { t0 }
        )
        var latest: Session?
        for try await s in try await service.send(
            prompt: "hi", in: session, to: backend
        ) { latest = s }
        let stored = try #require(try await repository.session(id: session.id))
        return (try #require(latest), stored)
    }

    @Test("a failed turn carries how far it got onto the message")
    func failureDetailReachesTheMessage() async throws {
        // Gap 1. The user is owed "failed 8 minutes in, after 3 tool calls"
        // rather than "Error" — contract §3.1(d) makes both fields required
        // precisely so a failure is actionable.
        let (final, stored) = try await Self.run(
            ScriptedTransport(events: [
                SequencedEvent(seq: 0, event: .delta("par")),
                failedTurnEnd(seq: 1, failedAtMs: 480_000, toolCallsCompleted: 3),
            ])
        )

        let message = try #require(final.messages.last)
        #expect(message.status == .failed)
        let failure = try #require(message.failure)
        #expect(failure.failedAtMs == 480_000)
        #expect(failure.toolCallsCompleted == 3)
        // It has to survive the save, because force-quitting before seeing the
        // failure is the exact case background resume exists for.
        #expect(stored.messages.last?.failure == failure)
        // And the partial text is still there — detail is added, nothing lost.
        #expect(message.text == "par")
    }

    @Test("a failure the bridge under-reports is still a failure")
    func failureWithoutDetailIsStillFailed() async throws {
        // The store's `TurnReconciliation` degrades a detail-less failure to
        // `.settled`, which silently swallows it — its own author flagged this
        // as a design gap. This layer must not reproduce it: we saw the
        // `.turnEnd(outcome: .failed)` frame directly, so the failure is a
        // fact regardless of whether the numbers came with it.
        //
        // What is *not* done: inventing `TurnFailure(0, 0)`. "Failed 0 minutes
        // in, after 0 tool calls" is a fabricated claim. The message is
        // `.failed` with no detail, and the UI already drops the detail line
        // when it is absent rather than rendering zeros.
        let (final, _) = try await Self.run(
            ScriptedTransport(events: [
                SequencedEvent(seq: 0, event: .delta("par")),
                failedTurnEnd(seq: 1, failedAtMs: nil, toolCallsCompleted: nil),
            ])
        )

        let message = try #require(final.messages.last)
        #expect(message.status == .failed)
        #expect(message.failure == nil)
        #expect(message.isRetryable)
    }

    @Test("a partially-reported failure is not half-invented")
    func partialDetailIsNotFabricated() async throws {
        // One field present, one missing. Filling the gap with `0` would state
        // something the bridge never said, so the detail is dropped whole.
        let (final, _) = try await Self.run(
            ScriptedTransport(events: [
                failedTurnEnd(seq: 0, failedAtMs: 480_000, toolCallsCompleted: nil),
            ])
        )

        let message = try #require(final.messages.last)
        #expect(message.status == .failed)
        #expect(message.failure == nil)
    }

    @Test("a dropped connection on a resumable turn is detached, never retryable")
    func detachedNeedsACursor() async throws {
        // Gap 2. The host is still generating, so offering a retry starts a
        // second job on the user's own machine while the first burns tokens.
        // The cursor is what proves the turn can be picked up again.
        let (final, stored) = try await Self.run(
            ScriptedTransport(
                events: [SequencedEvent(seq: 7, event: .delta("half"))],
                failure: LocalisError.connectionLost,
                turnID: "t-1"
            )
        )

        let message = try #require(final.messages.last)
        #expect(message.status == .detached)
        #expect(!message.isRetryable)
        #expect(message.text == "half")
        // Not an error: the turn is fine, the link is what broke.
        #expect(final.status == .disconnected)
        #expect(stored.messages.last?.status == .detached)
    }

    @Test("a dropped connection with no turn id is interrupted and retryable")
    func noTurnIDMeansInterrupted() async throws {
        // A bridge older than the resume contract sends no id, so there is
        // nothing to resume from — the content is genuinely gone and a retry
        // is the right offer.
        let (final, _) = try await Self.run(
            ScriptedTransport(
                events: [SequencedEvent(seq: 0, event: .delta("half"))],
                failure: LocalisError.connectionLost,
                turnID: nil
            )
        )

        let message = try #require(final.messages.last)
        #expect(message.status == .interrupted)
        #expect(message.isRetryable)
        #expect(message.text == "half")
    }

    @Test("a turn id in the header alone is enough to detach")
    func detachBeforeAnyFrameArrives() async throws {
        // The case the header placement exists for: the connection dies before
        // a single frame lands. Were the id carried in the first event, this
        // turn would be indistinguishable from one that never started — and
        // the Mac would keep generating with nothing on screen able to say so.
        let (final, _) = try await Self.run(
            ScriptedTransport(
                events: [], failure: LocalisError.connectionLost, turnID: "t-1"
            )
        )

        #expect(try #require(final.messages.last).status == .detached)
    }

    @Test("an unretryable error is failed even with a cursor")
    func unretryableBeatsTheCursor() async throws {
        // A revoked token produces the same broken stream as a dropped
        // connection, but resuming replays the same refusal. `isRetryable`
        // is the gate, and no cursor overrides it.
        let (final, _) = try await Self.run(
            ScriptedTransport(
                events: [], failure: LocalisError.tokenRevoked, turnID: "t-1"
            )
        )

        #expect(try #require(final.messages.last).status == .failed)
    }

    @Test("a replayed frame does not append its text twice")
    func replayedFramesAreDeduped() async throws {
        // Amendment C §3.3 / SC-003: "no missing text, no duplicated text".
        // The bridge may resend frames around the replay boundary, and `seq`
        // is what makes the duplicate recognisable.
        let (final, _) = try await Self.run(
            ScriptedTransport(
                events: [
                    SequencedEvent(seq: 0, event: .delta("Hel")),
                    SequencedEvent(seq: 1, event: .delta("lo")),
                    // The bridge replays seq 1 — already accepted.
                    SequencedEvent(seq: 1, event: .delta("lo")),
                    completedTurnEnd(seq: 2),
                ],
                turnID: "t-1"
            )
        )

        #expect(try #require(final.messages.last).text == "Hello")
    }

    @Test("events with no seq are all kept — a host without resume is not deduped")
    func unsequencedEventsAreNotDeduped() async throws {
        // `seq` is optional, and absent means "this host cannot resume", not
        // "sequence zero". Treating nil as a number would drop repeated text
        // from a perfectly healthy stream — the same word twice is ordinary.
        let (final, _) = try await Self.run(
            ScriptedTransport(events: [
                SequencedEvent(seq: nil, event: .delta("go ")),
                SequencedEvent(seq: nil, event: .delta("go ")),
                SequencedEvent(seq: nil, event: .delta("go")),
            ])
        )

        #expect(try #require(final.messages.last).text == "go go go")
    }

    @Test("a completed turnEnd settles the message and clears the session error")
    func completedTurnEndSettles() async throws {
        let (final, _) = try await Self.run(
            ScriptedTransport(events: [
                SequencedEvent(seq: 0, event: .delta("hi")),
                completedTurnEnd(seq: 1),
            ])
        )

        #expect(try #require(final.messages.last).status == .complete)
        #expect(final.status == .idle)
        #expect(final.canSend)
    }

    @Test("the five unconsumed event kinds are ignored, not fatal")
    func unconsumedEventsDoNotBreakTheTurn() async throws {
        // Tool calls, approvals, activity phrases, telemetry and usage all have
        // real uses, and wiring them up is its own piece of work. What must not
        // happen meanwhile is a turn breaking because one arrived — the same
        // rule the mapper follows for frames it cannot parse.
        let (final, _) = try await Self.run(
            ScriptedTransport(events: [
                SequencedEvent(seq: 0, event: .sessionStatus("Compacting context…")),
                SequencedEvent(
                    seq: 1,
                    event: .toolCall(ToolCall(callID: "c-1", phase: .start, tool: "read"))
                ),
                SequencedEvent(seq: 2, event: .telemetry(["tps": .number(42)])),
                SequencedEvent(
                    seq: 3,
                    event: .usage(TokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15))
                ),
                SequencedEvent(seq: 4, event: .delta("hi")),
                SequencedEvent(seq: 5, event: .finished(reason: "stop")),
                completedTurnEnd(seq: 6),
                SequencedEvent(seq: 7, event: .done),
            ])
        )

        let message = try #require(final.messages.last)
        #expect(message.text == "hi")
        #expect(message.status == .complete)
    }
}

/// What this layer *sends*, as opposed to what it does with the reply.
///
/// These assertions exist because getting them wrong is silent. A malformed
/// request does not throw; it produces an agent that answers oddly, which is
/// the hardest class of bug to trace back to its cause.
@Suite("ChatService sends a well-formed turn")
struct ChatServiceRequestTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hostID = HostID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    )

    private static func makeSession(messages: [Message]) -> Session {
        Session(
            id: UUID(),
            hostID: hostID,
            backendID: "test-backend",
            title: "Test",
            messages: messages,
            createdAt: t0,
            updatedAt: t0
        )
    }

    private static func makeService(
        _ transport: RecordingTransport,
        _ session: Session
    ) -> ChatService {
        ChatService(
            transport: transport,
            repository: InMemorySessionRepository(sessions: [session]),
            now: { t0 }
        )
    }

    @Test("the whole transcript is sent, not just the new message")
    func sendsFullHistory() async throws {
        // The contract is ambiguous here: its body example shows a single
        // message, while the same section describes `x-localis-session-id` as
        // continuing a bridge-side session. Until that is settled we send
        // everything, because the two readings fail very differently — a
        // stateful bridge merely re-reads context it already had, while a
        // stateless one handed only the new line forgets the conversation
        // every turn and just answers strangely.
        let earlier = [
            Message(id: UUID(), role: .user, text: "first", createdAt: Self.t0),
            Message(id: UUID(), role: .assistant, text: "reply", createdAt: Self.t0),
        ]
        let session = Self.makeSession(messages: earlier)
        let transport = RecordingTransport()
        let service = Self.makeService(transport, session)
        let backend = AgentBackend(
            id: "test-backend", displayName: "Test", capabilities: [.streaming]
        )

        let stream = try await service.send(prompt: "second", in: session, to: backend)
        for try await _ in stream {}

        let request = try #require(await transport.received)
        #expect(request.messages.count == 3)
        #expect(request.messages.map(\.text) == ["first", "reply", "second"])
    }

    @Test("the new user message is last, and it is the prompt")
    func promptIsTheFinalMessage() async throws {
        // The bridge answers the final message. Sending the prompt alongside a
        // history that does not end with it — or ending on the assistant's
        // last reply — asks the agent to answer the wrong turn.
        let session = Self.makeSession(messages: [
            Message(id: UUID(), role: .assistant, text: "earlier", createdAt: Self.t0)
        ])
        let transport = RecordingTransport()
        let service = Self.makeService(transport, session)
        let backend = AgentBackend(
            id: "test-backend", displayName: "Test", capabilities: [.streaming]
        )

        let stream = try await service.send(prompt: "  ask me  ", in: session, to: backend)
        for try await _ in stream {}

        let request = try #require(await transport.received)
        let last = try #require(request.messages.last)
        #expect(last.role == .user)
        // Trimmed, matching what was persisted — the bridge must not be sent
        // one string while the transcript shows another.
        #expect(last.text == "ask me")
    }

    @Test("the session id is carried so the bridge can continue the right turn")
    func carriesSessionID() async throws {
        // Contract §3 requires `x-localis-session-id`. Without it the bridge
        // cannot tie this turn to the previous one.
        let session = Self.makeSession(messages: [])
        let transport = RecordingTransport()
        let service = Self.makeService(transport, session)
        let backend = AgentBackend(
            id: "test-backend", displayName: "Test", capabilities: [.streaming]
        )

        let stream = try await service.send(prompt: "hi", in: session, to: backend)
        for try await _ in stream {}

        let request = try #require(await transport.received)
        #expect(request.sessionID == session.id)
        #expect(request.backendID == backend.id)
    }

    @Test("no workspace is sent, because this layer has none to send")
    func workspaceIsAbsentNotInvented() async throws {
        // FR-013 puts the working directory behind the backend's `workspace`
        // capability — but `Session` has no field to hold one, so the picker
        // and the stored path are unbuilt work, not something to synthesise
        // here. `nil` omits the header entirely, which is the honest state;
        // sending an empty one would assert "the workspace is the empty path".
        //
        // This test is a tripwire: when the field lands, it fails and whoever
        // adds it has to decide deliberately what gets sent.
        let session = Self.makeSession(messages: [])
        let transport = RecordingTransport()
        let service = Self.makeService(transport, session)
        let backend = AgentBackend(
            id: "test-backend",
            displayName: "Test",
            capabilities: [.streaming, .workspace]
        )

        let stream = try await service.send(prompt: "hi", in: session, to: backend)
        for try await _ in stream {}

        let request = try #require(await transport.received)
        #expect(request.workspace == nil)
    }
}

/// The projection LocalisUI now asserts against rather than restates.
///
/// These are quantified over `MessageStatus.allCases` rather than written as a
/// list of the statuses that exist today. A seventh status is exactly the change
/// that would slip through a hand-written list: it compiles, every existing test
/// stays green, and the new state silently picks up whichever branch the
/// `isInFlight` ternary happens to send it down.
@Suite("ChatService projects settled status for the UI")
struct ChatServiceProjectionTests {
    @Test("every in-flight status reads as disconnected, not as an error")
    func inFlightIsDisconnected() {
        // The claim `.disconnected` makes is "the link is gone, the work may
        // still be running" — which is why the composer offers to keep reading
        // instead of announcing the reply is lost. Any status where the turn
        // might still be alive has to land here, not just `.detached`.
        for status in MessageStatus.allCases where status.isInFlight {
            #expect(
                ChatService.sessionStatus(for: status, reason: .connectionLost) == .disconnected,
                "\(status) is in flight, so it must not surface as an error"
            )
        }
    }

    @Test("every settled status carries the reason it settled")
    func settledCarriesReason() {
        // The other half. A settled turn has a cause the user can act on, and
        // dropping it leaves them with a bare "Error" — a revoked token and a
        // dropped connection need different things from them.
        for status in MessageStatus.allCases where !status.isInFlight {
            #expect(
                ChatService.sessionStatus(for: status, reason: .tokenRevoked)
                    == .error(.tokenRevoked),
                "\(status) is settled, so its reason must survive"
            )
        }
    }

    @Test("no status is both in-flight and settled")
    func theSplitIsTotal() {
        // Guards the assumption the two tests above share: that `isInFlight`
        // partitions the statuses. If a future status answered neither, both
        // loops would skip it and both would still pass — the failure mode
        // quantified tests are supposed to remove, reintroduced by accident.
        let inFlight = MessageStatus.allCases.filter(\.isInFlight)
        let settled = MessageStatus.allCases.filter { !$0.isInFlight }

        #expect(inFlight.count + settled.count == MessageStatus.allCases.count)
        #expect(!inFlight.isEmpty)
        #expect(!settled.isEmpty)
    }
}

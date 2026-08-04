import Foundation
import Testing

@testable import ChatService

import LocalisModels
import SessionStore
import TransportKit

/// A transport whose liveness answer the test chooses (#25).
///
/// `ScriptedTransport` hardcodes `probe` to true, which is right for the suites
/// about streaming and useless here: the whole subject of these tests is what
/// happens on each of the two answers. It also counts the calls, because "did
/// not reconnect" and "reconnected to a host that happened to answer" are
/// distinguishable only by whether anything was asked.
private actor ProbeTransport: AgentTransport {
    private let answer: HostReachability
    private(set) var probeCount = 0

    /// `true`/`false` kept as the convenience spelling: every test in this suite
    /// asks whether a reconnect happened, and none of them is about *why* a host
    /// refused. Spelling a reachability out at each call site would put a detail
    /// in front of the thing being read.
    init(answer: Bool) {
        self.answer = answer ? .reachable : .unreachable(reason: .offline)
    }

    init(answer: HostReachability) {
        self.answer = answer
    }

    func send(_ request: TurnRequest) async throws -> TurnStream {
        // Reaching here means a turn was started, which no test in this suite
        // does. Recorded as an issue rather than left to return an empty stream:
        // a silent no-op would make a reconnect that wrongly starts a turn look
        // like a reconnect that did nothing.
        Issue.record("reconnect must not start a turn")
        return TurnStream(turnID: nil, events: AsyncThrowingStream { $0.finish() })
    }

    func probe(_ backend: AgentBackend) async -> HostReachability {
        probeCount += 1
        return answer
    }
}

/// The edge back into `.idle` (#25).
///
/// **The deadlock.** `Session.canSend` is `status == .idle`, and every read path
/// normalizes a stored session to `.disconnected` — correctly, because the
/// process holds no connection after a relaunch and `.idle` means *connected and
/// not busy*. But before this, the only writes that produced `.idle` were at the
/// end of a completed turn, and starting a turn requires `canSend`. The state was
/// entered on every cold start and left by nothing, so every conversation from
/// yesterday had a permanently grey composer.
///
/// **There were two dead ends, not one**, and the second is easy to miss:
/// `.error` is also outside `canSend`, and `ChatService` clears it only when a
/// later turn finishes — a turn that same rule forbids starting. One failed turn
/// therefore closed the conversation for good, with no relaunch needed.
///
/// **Why the edge is a probe rather than an assumption.** Writing `.idle`
/// because the user opened the screen would restore the composer by asserting a
/// connection nobody checked — FR-053 inverted, and exactly what the
/// normalization exists to prevent. The host is asked, and its answer is what
/// gets written.
@Suite("Reconnecting a session that holds no live link")
struct ChatServiceReconnectTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// One fixed host for every session here.
    ///
    /// A literal UUID with `!` would be a force unwrap the linter rejects, and
    /// the constant string buys nothing: no test asserts on this value, and
    /// nothing is looked up by it. What matters is only that all the sessions
    /// in one test agree, which a single `HostID()` gives.
    private static let hostID = HostID()

    private static func makeBackend() -> AgentBackend {
        AgentBackend(id: "test-backend", displayName: "Test", capabilities: [.streaming])
    }

    private static func makeSession(status: SessionStatus) -> Session {
        Session(
            id: UUID(),
            hostID: hostID,
            backendID: "test-backend",
            title: "Yesterday's conversation",
            createdAt: t0,
            updatedAt: t0,
            status: status
        )
    }

    /// A time strictly after `t0`, for asserting that a write did *not* happen.
    ///
    /// The default `now` is pinned to `t0`, which makes a stray save invisible:
    /// re-saving the fixture at its own `updatedAt` leaves the stored value
    /// identical to the unsaved one, so the assertion holds either way. Any test
    /// about whether the row was touched has to move the clock first.
    private static let t1 = Date(timeIntervalSince1970: 1_700_009_999)

    private static func makeService(
        transport: ProbeTransport,
        repository: InMemorySessionRepository,
        now: @escaping @Sendable () -> Date = { t0 }
    ) -> ChatService {
        ChatService(transport: transport, repository: repository, now: now)
    }

    // MARK: - The edge itself

    @Test("a disconnected session whose Mac answers becomes sendable")
    func disconnectedBecomesIdleWhenHostAnswers() async throws {
        let session = Self.makeSession(status: .disconnected)
        let repository = InMemorySessionRepository(sessions: [session])
        let service = Self.makeService(
            transport: ProbeTransport(answer: true), repository: repository
        )

        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .idle)
        #expect(reconnected.canSend)
    }

    @Test("being connected is process state — the store will not hold it, by design")
    func idleCannotBeReadBack() async throws {
        // **Read this before writing a test that asserts `.idle` on a re-read.**
        // `restoredStatus` maps `.idle` to `.disconnected` on *every* read, not
        // only after a relaunch — the store has no way to know whether a
        // connection exists, so it refuses to claim one. Being connected is
        // therefore process state and lives in the model that holds it.
        //
        // Pinned as its own test because the obvious assertion — "reconnect
        // persists, so re-reading gives `.idle`" — is unwritable, and finding
        // that out from a red test with no explanation invites the fix that
        // relaxes the normalization. That would hand every stored session a
        // composer on a connection nobody opened, which is the deadlock traded
        // for something worse.
        let session = Self.makeSession(status: .disconnected)
        let repository = InMemorySessionRepository(sessions: [session])
        let service = Self.makeService(
            transport: ProbeTransport(answer: true), repository: repository
        )

        let reconnected = await service.reconnect(session, to: Self.makeBackend())
        #expect(reconnected.status == .idle)

        let stored = try #require(try await repository.session(id: session.id))
        #expect(stored.status == .disconnected)
    }

    @Test("opening an old conversation does not move it up the list")
    func reconnectingDisconnectedDoesNotTouchTheRow() async throws {
        // The cost of writing a status the store cannot read back.
        //
        // From `.disconnected` the save was not merely wasted: `withStatus`
        // bumps `updatedAt` (Session.swift:96) and both repositories order the
        // list by it, descending (SwiftDataSessionRepository.swift:46,
        // SessionRepository.swift:136). So a conversation the user merely
        // *opened* would jump to the top — on screen, identical to it having
        // received a reply. Nothing errors, nothing looks broken; the list is
        // just quietly sorted by "recently viewed" while claiming to be sorted
        // by activity.
        //
        // The clock is moved off `t0` on purpose. With the default `now`, a
        // save would rewrite `updatedAt` to the value it already held and this
        // assertion would pass against both implementations — a test that could
        // not fail, which is the shape this suite exists to avoid.
        let session = Self.makeSession(status: .disconnected)
        let repository = InMemorySessionRepository(sessions: [session])
        let service = Self.makeService(
            transport: ProbeTransport(answer: true),
            repository: repository,
            now: { Self.t1 }
        )

        let reconnected = await service.reconnect(session, to: Self.makeBackend())
        // The in-memory answer still carries the new time — that half is the
        // reconnect working. Only the stored row must be untouched.
        #expect(reconnected.status == SessionStatus.idle)

        let stored = try #require(try await repository.session(id: session.id))
        #expect(stored.updatedAt == Self.t0)
    }

    @Test("recovering a failed conversation does not move it up the list either")
    func recoveringDoesNotTouchTheRowsPosition() async throws {
        // The half `reconnectingDisconnectedDoesNotTouchTheRow` does not cover.
        //
        // That test protects the sessions whose save was *skipped*. This one is
        // about the one case that still writes — and it is the same bug, not a
        // different one: the user opens a conversation that failed yesterday,
        // the probe succeeds, `.error` is replaced, and the row jumps to the
        // top of the list. Nothing arrived. On screen that is indistinguishable
        // from a reply having come in.
        //
        // The write itself is not the defect and must stay: without it a failed
        // session reads back failed forever (`recoveringClearsTheStoredError`).
        // What was wrong is that "persist the recovered status" and "declare
        // new activity" were one operation, because `withStatus` took a
        // timestamp at all. Splitting them is the fix; this asserts the split.
        //
        // Clock moved off `t0` for the reason `t1` exists: at the default the
        // row would be rewritten to the value it already held and this would
        // pass against the unfixed code too.
        let session = Self.makeSession(status: .error(.connectionLost))
        let repository = InMemorySessionRepository(sessions: [session])
        let service = Self.makeService(
            transport: ProbeTransport(answer: true),
            repository: repository,
            now: { Self.t1 }
        )

        _ = await service.reconnect(session, to: Self.makeBackend())

        let stored = try #require(try await repository.session(id: session.id))
        // Both halves, in one test on purpose. Asserting only the timestamp
        // would go green on an implementation that stopped saving altogether —
        // which trades this bug for the permanent-failure deadlock #25 closed.
        // The status must be the recovered one *and* the row must not have
        // moved; either alone is satisfiable by a regression.
        #expect(stored.status == .disconnected)
        #expect(stored.updatedAt == Self.t0)
    }

    @Test("a recovered session no longer reads back as failed")
    func recoveringClearsTheStoredError() async throws {
        // What persisting *does* buy, and the reason `reconnect` writes at all.
        //
        // `.error` survives a read where `.idle` does not, so a session left
        // failed comes back failed on every launch forever. Saving the
        // recovered status replaces it: the next read returns `.disconnected` —
        // not `.idle`, per the test above — which is the honest answer and one
        // this same call can lift again.
        let session = Self.makeSession(status: .error(.connectionLost))
        let repository = InMemorySessionRepository(sessions: [session])
        let service = Self.makeService(
            transport: ProbeTransport(answer: true), repository: repository
        )

        _ = await service.reconnect(session, to: Self.makeBackend())

        let stored = try #require(try await repository.session(id: session.id))
        #expect(stored.status == .disconnected)
    }

    @Test("a failed turn's session recovers once the Mac answers again")
    func errorRecoversWhenHostAnswers() async throws {
        // The second dead end. `.error` is outside `canSend`, and the only code
        // that cleared it ran at the end of a turn — which could not be started.
        // Without this branch a single dropped connection ends the conversation
        // permanently, and no relaunch is needed to reach that state.
        let session = Self.makeSession(status: .error(.connectionLost))
        let repository = InMemorySessionRepository(sessions: [session])
        let service = Self.makeService(
            transport: ProbeTransport(answer: true), repository: repository
        )

        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .idle)
    }

    // MARK: - The reverse controls
    //
    // Every test above passes under "always write .idle". These are what make
    // the suite mean something: each one is a session that must stay closed,
    // and the cheapest fix to the tests above opens all of them.

    @Test("a Mac that does not answer leaves the session unsendable")
    func silentHostLeavesSessionDisconnected() async throws {
        let session = Self.makeSession(status: .disconnected)
        let repository = InMemorySessionRepository(sessions: [session])
        let service = Self.makeService(
            transport: ProbeTransport(answer: false), repository: repository
        )

        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .disconnected)
        #expect(reconnected.canSend == false)
    }

    /// A state that did not exist while `probe` returned `Bool` (#40), and the
    /// one a reachability-shaped guard is most likely to get wrong: `.unknown`
    /// is not a refusal, so `!= .unreachable` reads as a reasonable test and
    /// opens the session on a host nothing has been established about.
    ///
    /// It has to stay closed for the same reason `backend.isAvailable` is
    /// checked before the probe runs — a session that reports as sendable and
    /// then fails at the far end is the accept-then-fail shape FR-053 rules out.
    @Test("a host nothing is known about does not count as answering")
    func unknownReachabilityLeavesSessionDisconnected() async throws {
        let session = Self.makeSession(status: .disconnected)
        let repository = InMemorySessionRepository(sessions: [session])
        let service = Self.makeService(
            transport: ProbeTransport(answer: .unknown), repository: repository
        )

        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .disconnected)
        #expect(reconnected.canSend == false)
    }

    /// The reason a host refused changes what the *host list* says (#40) and
    /// must not change what `reconnect` does. A guard that started treating
    /// some reasons as recoverable would reopen sessions on a Mac whose
    /// certificate no longer matches — the one failure constitution V says is
    /// not retryable at all.
    @Test("no unreachable reason reopens the session")
    func noReasonReconnects() async throws {
        for reason in HostUnreachableReason.allCases {
            let session = Self.makeSession(status: .disconnected)
            let repository = InMemorySessionRepository(sessions: [session])
            let service = Self.makeService(
                transport: ProbeTransport(answer: .unreachable(reason: reason)),
                repository: repository
            )

            let reconnected = await service.reconnect(session, to: Self.makeBackend())

            #expect(reconnected.canSend == false, "\(reason) must not reopen the session")
        }
    }

    @Test("a Mac that does not answer does not erase why the last turn failed")
    func silentHostKeepsTheStoredError() async throws {
        // `.error(_)` is a historical fact — the turn did fail, and nothing on a
        // later launch can re-derive it. Overwriting it with `.disconnected`
        // because a probe came back false replaces "your message was never
        // answered" with "this Mac is asleep", which is a different sentence and
        // sends the user to fix a different thing.
        let session = Self.makeSession(status: .error(.tokenRevoked))
        let repository = InMemorySessionRepository(sessions: [session])
        let service = Self.makeService(
            transport: ProbeTransport(answer: false), repository: repository
        )

        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .error(.tokenRevoked))
    }

    @Test("an unpaired Mac's session stays read-only however the probe answers")
    func orphanedIsNeverReconnected() async throws {
        // `.orphaned` is a fact about *pairing*, not about a connection, and it
        // outranks any liveness answer. A bridge that is up and reachable is
        // still one the user revoked, and FR-027 keeps the transcript readable
        // and unsendable rather than deleting it. The probe answers true here
        // deliberately: this must not be a test that passes because nothing
        // could have gone right.
        let session = Self.makeSession(status: .orphaned)
        let repository = InMemorySessionRepository(sessions: [session])
        let transport = ProbeTransport(answer: true)
        let service = Self.makeService(transport: transport, repository: repository)

        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .orphaned)
        // And the host was never asked. Asking would put a request on the wire
        // for a machine whose pairing the user revoked — the answer is already
        // known without one.
        #expect(await transport.probeCount == 0)
    }

    @Test("a turn in flight is not interrupted by a reconnect")
    func streamingIsLeftAlone() async throws {
        // `.streaming` cannot come off disk — the read path normalizes it — but
        // it is reachable in process, and writing `.idle` over it would hand the
        // composer back mid-turn and let a second send start on top of the
        // first.
        let session = Self.makeSession(status: .streaming)
        let repository = InMemorySessionRepository(sessions: [session])
        let transport = ProbeTransport(answer: true)
        let service = Self.makeService(transport: transport, repository: repository)

        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .streaming)
        #expect(await transport.probeCount == 0)
    }

    @Test("a session that is already sendable is left exactly as it is")
    func idleIsNotProbed() async throws {
        // Not merely an optimisation. `load()` runs on every open, and probing
        // a session that is already connected would put a request on the wire
        // each time the user taps into a conversation.
        let session = Self.makeSession(status: .idle)
        let repository = InMemorySessionRepository(sessions: [session])
        let transport = ProbeTransport(answer: true)
        let service = Self.makeService(transport: transport, repository: repository)

        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .idle)
        #expect(await transport.probeCount == 0)
    }

    @Test("an unavailable backend is not reconnected around")
    func unavailableBackendIsNotProbed() async throws {
        // A backend the Mac lists but is not signed into. The host would answer
        // the probe — it is up — so a reconnect that asked only "is the Mac
        // there" would report this session sendable and the send would fail at
        // the far end, which is the accept-then-fail shape FR-053 rules out.
        let session = Self.makeSession(status: .disconnected)
        let repository = InMemorySessionRepository(sessions: [session])
        let transport = ProbeTransport(answer: true)
        let service = Self.makeService(transport: transport, repository: repository)

        let reconnected = await service.reconnect(
            session,
            to: AgentBackend(
                id: "test-backend",
                displayName: "Test",
                capabilities: [.streaming],
                availability: .unavailable(reason: nil)
            )
        )

        #expect(reconnected.status == .disconnected)
    }
}

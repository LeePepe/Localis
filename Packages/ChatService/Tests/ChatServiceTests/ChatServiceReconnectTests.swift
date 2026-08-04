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
    /// What the host says about the backend, independent of what the caller
    /// passed in. Defaults to a listed, available agent — the answer that leaves
    /// `probe` as the only guard, which is what every test written before #41
    /// assumes.
    private let description: BackendDescription
    private(set) var probeCount = 0
    private(set) var refreshCount = 0

    /// The id the default description reports.
    ///
    /// Matches `makeBackend()`'s id so the default answer describes the same
    /// agent the tests hand in. Nothing reads the id today — `reconnect` asks
    /// the transport about one backend and gets one answer back — but a
    /// description naming a different agent would be a fixture that quietly
    /// stopped being about the session under test.
    private static let listed = BackendDescription.listed(
        AgentBackend(id: "test-backend", displayName: "Test", capabilities: [.streaming])
    )

    /// `true`/`false` kept as the convenience spelling: every test in this suite
    /// asks whether a reconnect happened, and none of them is about *why* a host
    /// refused. Spelling a reachability out at each call site would put a detail
    /// in front of the thing being read.
    init(answer: Bool) {
        self.answer = answer ? .reachable : .unreachable(reason: .offline)
        self.description = Self.listed
    }

    init(answer: HostReachability) {
        self.answer = answer
        self.description = Self.listed
    }

    /// A host that is up, describing a backend however the test says (#41).
    ///
    /// Reachable on purpose: a stub that refused both questions could not tell
    /// a build that lost the availability guard from one that kept it.
    init(describing description: BackendDescription) {
        self.answer = .reachable
        self.description = description
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

    /// Lists the backend as the caller described it, available.
    ///
    /// **This fake answers the two questions independently on purpose.** Since
    /// #41, `reconnect` requires both a reachable host *and* a listed, available
    /// backend. Deriving this from `answer` would make one stub drive both
    /// guards, and a regression that dropped the probe check entirely would stay
    /// green — the availability answer alone would still block the reconnect,
    /// and the suite would report the right outcome for the wrong reason.
    ///
    /// What the host says about the backend.
    ///
    /// **Deliberately ignores the `backend` argument.** Echoing it back would
    /// make the fake answer "whatever you passed in", and in production that
    /// argument always comes from storage, where both repositories flatten
    /// `availability` to `.available` on read. A test that got its answer from
    /// the argument would therefore be exercising a value the app can never
    /// actually have, and would stay green against an implementation that read
    /// the stored value instead of the host's — the exact bug #41 fixes.
    func refresh(_ backend: AgentBackend) async -> BackendDescription {
        refreshCount += 1
        return description
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
        // A backend the Mac lists but is not signed into. The host answers the
        // probe — it is up — so a reconnect that asked only "is the Mac there"
        // would report this session sendable and the send would fail at the far
        // end, which is the accept-then-fail shape FR-053 rules out.
        //
        // **The unavailability is the host's answer, not the argument's.**
        // Before #41 this test passed `.unavailable` in as the `backend` and the
        // guard read it off there — which could never happen in production,
        // where that argument comes from storage and both repositories flatten
        // `availability` to `.available` on read. The test was green against a
        // guard reading a value the app could not produce.
        let session = Self.makeSession(status: .disconnected)
        let repository = InMemorySessionRepository(sessions: [session])
        let transport = ProbeTransport(
            describing: .listed(
                AgentBackend(
                    id: "test-backend",
                    displayName: "Test",
                    capabilities: [.streaming],
                    availability: .unavailable(reason: "not_logged_in")
                )
            )
        )
        let service = Self.makeService(transport: transport, repository: repository)

        // Handed in exactly as storage would hand it over: available, because
        // that is the only thing storage can say.
        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .disconnected)
    }

    /// A backend the Mac no longer has is not reconnected around either.
    ///
    /// Distinct from signed-out: re-signing in fixes that one and cannot fix
    /// this one. Both block the reconnect, and asserting only the signed-out
    /// case would leave a build that treated "not listed" as a green light
    /// looking correct — it would hand the composer to a conversation whose
    /// agent was deleted on the Mac.
    @Test("a backend the Mac no longer lists is not reconnected around")
    func absentBackendIsNotReconnected() async throws {
        let session = Self.makeSession(status: .disconnected)
        let repository = InMemorySessionRepository(sessions: [session])
        let transport = ProbeTransport(describing: .absent)
        let service = Self.makeService(transport: transport, repository: repository)

        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .disconnected)
    }

    /// A host that could not be asked is not a green light.
    ///
    /// `.unknown` means the refresh established nothing. Treating it as
    /// available would be the accept-then-fail shape arriving through the
    /// silence rather than through a wrong answer — and silence is the common
    /// case, since an unreachable Mac produces it every time.
    @Test("a host that could not be asked does not reconnect the session")
    func unknownDescriptionDoesNotReconnect() async throws {
        let session = Self.makeSession(status: .disconnected)
        let repository = InMemorySessionRepository(sessions: [session])
        let transport = ProbeTransport(describing: .unknown)
        let service = Self.makeService(transport: transport, repository: repository)

        let reconnected = await service.reconnect(session, to: Self.makeBackend())

        #expect(reconnected.status == .disconnected)
    }

    /// The host's answer reaches the caller, not just the guard (#41).
    ///
    /// This is the edge the task is about: `reconnect` alone could satisfy every
    /// test above by blocking correctly and telling nobody why, which is the
    /// state the app was already in. The screen needs the reason, and it can
    /// only come out through the return value.
    @Test("the host's description is handed back, not only acted on")
    func reopenReturnsTheHostsDescription() async throws {
        let session = Self.makeSession(status: .disconnected)
        let repository = InMemorySessionRepository(sessions: [session])
        let signedOut = AgentBackend(
            id: "test-backend",
            displayName: "Test",
            capabilities: [.streaming],
            availability: .unavailable(reason: "not_logged_in")
        )
        let service = Self.makeService(
            transport: ProbeTransport(describing: .listed(signedOut)),
            repository: repository
        )

        let (_, description) = await service.reopen(session, to: Self.makeBackend())

        // The reason itself, not merely "unavailable": `not_logged_in` and a
        // backend that is simply busy are different sentences, and a caller
        // handed only a bool cannot tell them apart.
        #expect(description.backend?.unavailableReason == "not_logged_in")
    }

    /// The backend's state is reported even for a session no probe may change.
    ///
    /// `.streaming` is not reconnectable, and an early return before the refresh
    /// would report `.unknown` — "we could not ask" — about a Mac that answers
    /// fine. That is the wrong-half naming this whole edge exists to stop, and
    /// it would only show up on a screen open during a turn.
    @Test("a session no probe may change still learns what the host said")
    func nonReconnectableSessionStillGetsADescription() async throws {
        let session = Self.makeSession(status: .streaming)
        let repository = InMemorySessionRepository(sessions: [session])
        let transport = ProbeTransport(describing: .absent)
        let service = Self.makeService(transport: transport, repository: repository)

        let (unchanged, description) = await service.reopen(session, to: Self.makeBackend())

        #expect(unchanged.status == .streaming)
        #expect(description == .absent)
        // The probe is what must not fire: asking a host to reconsider a turn in
        // flight is the request `isReconnectable` exists to prevent.
        #expect(await transport.probeCount == 0)
    }
}

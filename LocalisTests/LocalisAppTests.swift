import Foundation
import Testing

@testable import Localis

import ChatService
import LocalisModels
import LocalisUI
import SessionStore

/// App-target assembly checks.
///
/// **What this suite is for.** Package test suites answer "is this part
/// correct". Not one of them can answer "is this part in the machine" — and for
/// ten commits the answer was no, while every package stayed green. This suite
/// is the only place that question gets asked.
///
/// It replaces an `Issue.record` placeholder that stood in while the composition
/// root did not exist. It now exists (`SessionListModel`, `SessionDetailModel`,
/// `RootView`), so the placeholder is gone and these are real assertions.
///
/// **What is deliberately not asserted here.** Nothing checks that a *view*
/// renders. The projections these tests exercise are exactly the values the
/// views are handed, and a test that reached into SwiftUI's body would be
/// asserting SwiftUI rather than this app. Where a screen has to be seen rather
/// than computed, the evidence is a screenshot from a simulator run, not a
/// green test — see #18.
@Suite("App target assembly")
struct LocalisAppTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A repository seeded through the same protocol production writes through.
    private static func seeded(
        _ entries: (host: HostID, backend: AgentBackend, session: Session)...
    ) async throws -> InMemorySessionRepository {
        let repository = InMemorySessionRepository()
        for entry in entries {
            try await repository.save(entry.backend, on: entry.host)
            try await repository.create(entry.session)
        }
        return repository
    }

    private static func session(
        id: UUID = UUID(),
        host: HostID,
        backendID: String,
        title: String = "Session",
        messages: [Message] = [],
        status: SessionStatus = .idle
    ) -> Session {
        Session(
            id: id,
            hostID: host,
            backendID: backendID,
            title: title,
            messages: messages,
            createdAt: t0,
            updatedAt: t0,
            status: status
        )
    }

    /// A detail model wired the way `SessionDetailView` wires one.
    ///
    /// The transport is the app's own `EchoTransport` rather than a test double.
    /// Substituting a tidier fake here would test a `ChatService` this app never
    /// builds — and the point of this suite is the assembly as it ships.
    private static func detailModel(
        repository: any SessionRepository,
        sessionID: UUID
    ) async -> SessionDetailModel {
        await SessionDetailModel(
            repository: repository,
            sessionID: sessionID,
            service: ChatService(transport: EchoTransport(), repository: repository)
        )
    }

    /// `RootView()` initialises.
    ///
    /// **This proves less than its name suggests, and the limit is the point.**
    /// `RootView.init` catches a failed `SessionStoreContainer.onDisk()` and
    /// falls back to an in-memory repository, so it cannot throw — which means
    /// this test cannot fail for the reason someone skimming it would assume
    /// ("the store opens"). It fails only if constructing the view traps.
    ///
    /// Kept as a smoke test with its claim written down accurately rather than
    /// deleted: the suite it came from called this "the wiring check", and that
    /// name is how ten commits' worth of missing assembly stayed invisible.
    @Test("the root view initialises (smoke test only — it cannot fail for lack of a store)")
    func rootViewConstructs() {
        _ = RootView()
    }

    /// The list model reads through the repository rather than holding fixtures.
    @Test("the session list is read from the repository")
    func listReadsThroughRepository() async throws {
        let host = HostID()
        let repository = try await Self.seeded(
            (
                host,
                AgentBackend(id: "claude", displayName: "Studio Claude"),
                Self.session(host: host, backendID: "claude", title: "Refactor TransportKit")
            )
        )

        let model = await SessionListModel(repository: repository)
        await model.load()

        let rows = await model.rows
        #expect(rows.map(\.title) == ["Refactor TransportKit"])
        #expect(await model.loadError == nil)
    }

    /// FR-029 through the assembly, not just through the projection.
    ///
    /// `SessionRowState` has its own test for this. This one is different: it
    /// runs the *whole* path — repository → per-host `backends(ofHost:)` →
    /// projection — because the bug this pins down lived in none of those three
    /// parts. Each was correct; the model asked per host correctly and then
    /// flattened the answers into a list with no host in it, and the row wore
    /// the other machine's name. A unit test of any single part stays green
    /// through that.
    @Test("two machines both advertising 'claude' keep their own names")
    func backendNamesResolvePerHost() async throws {
        let studio = HostID()
        let laptop = HostID()
        let repository = try await Self.seeded(
            (
                studio,
                AgentBackend(id: "claude", displayName: "Studio Claude"),
                Self.session(host: studio, backendID: "claude", title: "On the studio")
            ),
            (
                laptop,
                AgentBackend(id: "claude", displayName: "Laptop Claude"),
                Self.session(host: laptop, backendID: "claude", title: "On the laptop")
            )
        )

        let model = await SessionListModel(repository: repository)
        await model.load()

        let names = Dictionary(
            uniqueKeysWithValues: await model.rows.map { ($0.title, $0.backendName) }
        )
        #expect(names["On the studio"] == "Studio Claude")
        #expect(names["On the laptop"] == "Laptop Claude")
    }

    /// Opening a session projects both surfaces the milestone asks to see.
    ///
    /// Asserted together rather than as two tests because the failure that
    /// matters is a screen with one of them missing — a transcript with no
    /// composer under it is not "half working", it is a session you cannot
    /// reply to.
    @Test("opening a session projects a transcript and a composer")
    func openingSessionProjectsTranscriptAndComposer() async throws {
        let host = HostID()
        let id = UUID()
        let repository = try await Self.seeded(
            (
                host,
                AgentBackend(id: "claude", displayName: "Studio Claude"),
                Self.session(
                    id: id,
                    host: host,
                    backendID: "claude",
                    messages: [
                        Message(id: UUID(), role: .user, text: "first", createdAt: Self.t0),
                        Message(id: UUID(), role: .assistant, text: "second", createdAt: Self.t0)
                    ]
                )
            )
        )

        let model = await Self.detailModel(repository: repository, sessionID: id)
        await model.load()

        #expect(await model.messages.map(\.text) == ["first", "second"])
        #expect(await model.composer != nil)
        #expect(await model.loadError == nil)
    }

    /// A session deleted between the list rendering and the tap says so.
    ///
    /// The wrong behaviour here is not a crash — it is an empty transcript with
    /// a composer under it, which tells the user their conversation is now
    /// blank. Absence and emptiness are different sentences and the UI has to
    /// pick the true one.
    @Test("a session deleted before it opened says so rather than showing an empty transcript")
    func deletedSessionIsNamedNotBlank() async throws {
        let repository = InMemorySessionRepository()

        let model = await Self.detailModel(repository: repository, sessionID: UUID())
        await model.load()

        #expect(await model.loadError != nil)
        #expect(await model.messages.isEmpty)
        // The composer must not be offered for a session that is not there:
        // rendering one would invite a reply into nothing.
        #expect(await model.composer == nil)
    }

    /// FR-029 on the *send* path, which is a separate lookup from the list's.
    ///
    /// `SessionListModel` and `SessionDetailModel` resolve backends
    /// independently, so fixing one leaves the other free to be host-blind. The
    /// list getting the name right and the detail screen routing to the wrong
    /// machine is not a contradiction the app would notice — the reply would
    /// arrive looking entirely normal, from a different computer.
    @Test("the session routes to the backend on its own host, not a same-named one elsewhere")
    func detailResolvesBackendOnItsOwnHost() async throws {
        let studio = HostID()
        let laptop = HostID()
        let id = UUID()
        let repository = try await Self.seeded(
            (
                studio,
                AgentBackend(id: "claude", displayName: "Studio Claude"),
                Self.session(host: studio, backendID: "claude", title: "On the studio")
            ),
            (
                laptop,
                AgentBackend(id: "claude", displayName: "Laptop Claude"),
                Self.session(id: id, host: laptop, backendID: "claude", title: "On the laptop")
            )
        )

        let model = await Self.detailModel(repository: repository, sessionID: id)
        await model.load()

        #expect(await model.backend?.displayName == "Laptop Claude")
        #expect(await model.sendBlockedReason == nil)
    }

    /// A session whose host is no longer paired is readable but not sendable.
    ///
    /// Both halves are asserted because either alone is a different, wrong
    /// product: a blocked composer with the transcript hidden loses history the
    /// user still owns (FR-036), and a readable transcript with an unblocked
    /// composer accepts a message that has nowhere to go.
    @Test("a session whose agent is gone keeps its transcript and says why it can't send")
    func missingBackendBlocksSendingButKeepsTranscript() async throws {
        let host = HostID()
        let id = UUID()
        let repository = InMemorySessionRepository()
        // Deliberately no `save(backend:on:)`: the host answers with no backends,
        // which is what an unpaired machine looks like from here.
        try await repository.create(
            Self.session(
                id: id,
                host: host,
                backendID: "claude",
                messages: [
                    Message(id: UUID(), role: .user, text: "still here", createdAt: Self.t0)
                ]
            )
        )

        let model = await Self.detailModel(repository: repository, sessionID: id)
        await model.load()

        #expect(await model.messages.map(\.text) == ["still here"])
        #expect(await model.backend == nil)
        #expect(await model.sendBlockedReason != nil)
    }

    /// Submitting with no backend surfaces a reason instead of doing nothing.
    ///
    /// Silence is the failure mode that matters: a send button that swallows the
    /// message is indistinguishable from a slow reply, so the user waits, then
    /// retypes.
    ///
    /// **Submitted without `load()` first, and that is what makes this a test of
    /// `submit`.** An earlier version loaded first and asserted the same thing —
    /// and stayed green when `submit` was mutated to `guard let backend else
    /// { return }`, because `load` had already set the reason. It was named for
    /// `submit` and was measuring `load`. Skipping `load` leaves
    /// `sendBlockedReason` genuinely nil going in, so only `submit` can set it.
    ///
    /// This also pins the one path on which `submit`'s own fallback string is
    /// reachable at all — see the note to `core`: after a completed `load`, that
    /// `??` branch is dead.
    @Test("submitting with no backend says why rather than silently dropping the message")
    func submitWithoutBackendSurfacesReason() async throws {
        let host = HostID()
        let id = UUID()
        let repository = InMemorySessionRepository()
        try await repository.create(Self.session(id: id, host: host, backendID: "claude"))

        let model = await Self.detailModel(repository: repository, sessionID: id)
        #expect(await model.sendBlockedReason == nil, "precondition: nothing has explained anything yet")

        await model.submit("does this go anywhere")

        #expect(await model.sendBlockedReason != nil)
        // The dropped message must not appear in the transcript: showing it
        // would claim it was sent.
        #expect(await model.messages.isEmpty)
    }

    /// After `load`, a session with no backend explains itself.
    ///
    /// Split out from the test above because the two failures are different
    /// mechanisms — this one is `resolveBackend` doing its job, that one is
    /// `submit` doing its own. Asserting both through one call is how the
    /// earlier version came to be named for the mechanism it was not testing.
    @Test("a loaded session with no backend has already said why it can't send")
    func loadedSessionWithoutBackendExplainsItself() async throws {
        let host = HostID()
        let id = UUID()
        let repository = InMemorySessionRepository()
        try await repository.create(Self.session(id: id, host: host, backendID: "claude"))

        let model = await Self.detailModel(repository: repository, sessionID: id)
        await model.load()

        #expect(await model.sendBlockedReason != nil)
    }
}

import Foundation
import Testing

@testable import Localis

import LocalisModels
import LocalisUI
import SessionStore
import TransportKit

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
    ///
    /// **The host row is written `.paired`, and that is load-bearing as of
    /// milestone B.** `SessionDetailModel` now builds its transport per host and
    /// refuses to build one for a machine that is not `canConnect` — so a
    /// fixture that seeded only a backend and a session would leave every test
    /// here blocked for a *pairing* reason, which is not what any of them is
    /// about. The pin comes from `AnyPin` below rather than from this record,
    /// because `save(_ host:)` strips it: the store has no pin column, by
    /// design (`HostAssembly`).
    private static func seeded(
        _ entries: (host: HostID, backend: AgentBackend, session: Session)...
    ) async throws -> InMemorySessionRepository {
        let repository = InMemorySessionRepository()
        for entry in entries {
            try await repository.save(
                LocalisHost(
                    id: entry.host,
                    displayName: "A paired Mac",
                    endpoint: HostEndpoint(host: "mac.local", port: 8443),
                    pairingState: .paired
                )
            )
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

    /// A Keychain stand-in that has a pin for every machine.
    ///
    /// Needed because the store strips pins on save, so a host read back is
    /// always `canConnect == false` until `HostAssembly` reattaches one. Answers
    /// for any host rather than for a seeded set: no test in this suite is about
    /// *which* machine has a pin — `HostAssemblyTests` owns that question — and
    /// a keyed fixture here would be one more thing to keep in step with
    /// `seeded`.
    private struct AnyPin: PinReading {
        func pin(for host: HostID) throws -> SPKIHash? { SPKIHash(base64: "AAA=") }
    }

    /// A detail model wired the way `SessionDetailView` wires one, with the two
    /// things that must not touch a real device substituted.
    ///
    /// **`EchoTransport` is a test fixture now, not the app's transport.** Until
    /// milestone B this helper deliberately used the app's own fake, on the
    /// argument that substituting a tidier one would test a `ChatService` the
    /// app never builds. That argument expired with the change it was waiting
    /// for: production builds a `BridgeClient` per host
    /// (`ChatTransport.swift`), the fake moved into this target, and no
    /// assembly test can use the real transport without a Mac on the network.
    /// What this helper still asserts about the assembly is the part that is
    /// checkable here — the model resolves its own host through `HostAssembly`
    /// and asks the factory for a transport — and `transportSeesTheSessionsOwnHost`
    /// is the test that pins that down.
    private static func detailModel(
        repository: any SessionRepository,
        sessionID: UUID
    ) async -> SessionDetailModel {
        await SessionDetailModel(
            repository: repository,
            sessionID: sessionID,
            credentials: AnyPin(),
            makeTransport: { _ in EchoTransport() }
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
                        // Distinct timestamps, deliberately. `StoredMapping`
                        // orders by `createdAt`, so two messages sharing one
                        // leave the order down to whatever the fetch happens to
                        // return — and this test asserts a strict sequence.
                        // It passed locally either way; that was luck, not a
                        // property. store hit the identical shape in its
                        // migration test: green three runs in a row, red on the
                        // first pre-commit hook.
                        Message(id: UUID(), role: .user, text: "first", createdAt: Self.t0),
                        Message(id: UUID(), role: .assistant, text: "second", createdAt: Self.t0.addingTimeInterval(1))
                    ]
                )
            )
        )

        let model = await Self.detailModel(repository: repository, sessionID: id)
        await model.load()

        #expect(await model.messages.map(\.text) == ["first", "second"])
        #expect(await model.loadError == nil)

        // `composer != nil` was the whole assertion here, and it is the shape
        // this suite exists to avoid: a composer that exists and a composer the
        // user can type into are different claims, and only the first was
        // checked.
        //
        // The existence check is *kept*, not replaced — `#require` fails the
        // test on nil exactly as the old `#expect(... != nil)` did, and core's
        // mutation round confirmed it earns its place: setting
        // `composer = nil` in `apply` reddens this test by name. What follows
        // adds the second claim on top.
        let composer = try #require(await model.composer)
        // Flipped by #25 along with the test below. Before the connect path
        // existed these read `canSend == false` / `blockedReason != nil`, which
        // was the deadlock showing up in a test that is not about it: this test
        // is about the transcript and the composer being projected at all, and
        // it happened to also pin the composer shut. Recorded red on
        // `origin/main @ 24cfceb` at :212 and :213 before the fix landed.
        #expect(composer.canSend == true)
        #expect(composer.blockedReason == nil)
    }

    /// A restored session *can* be replied to, once the Mac answers (#25).
    ///
    /// **This test was the pinned dead end, inverted.** It used to assert
    /// `canSend == false` and carried a note saying that was a symptom, not the
    /// design: `Session.canSend` is `status == .idle`, every read normalises a
    /// stored session to `.disconnected`, and the only writes producing `.idle`
    /// came at the end of a turn that `canSend` gates. The note asked whoever
    /// closed the gap to run the positive case red first and record the text,
    /// because a test that turns green when a `.disabled` comes off cannot be
    /// told apart from one that was never strong enough to be red.
    ///
    /// Recorded red on `origin/main @ 24cfceb`, before the connect path existed,
    /// verbatim:
    ///
    /// ```
    /// --- opening a session projects a transcript and a composer
    ///     LocalisAppTests.swift:212: Expectation failed:
    ///         (composer.canSend → false) == true
    ///     LocalisAppTests.swift:213: Expectation failed:
    ///         (composer.blockedReason → "This Mac isn't reachable. You can
    ///         still read the conversation.") == nil
    /// ```
    ///
    /// **What makes it green now.** `SessionDetailModel.load` ends with a
    /// reconnect: it asks the transport whether the backend is live, and writes
    /// the answer back.
    ///
    /// **The transport here is a fixture, and that sentence used to say
    /// otherwise.** Until milestone B this note read "the app's transport is
    /// still `EchoTransport`, whose `probe` returns true unconditionally
    /// (`Fakes/EchoTransport.swift:106`) … the fake announces itself on screen,
    /// so no screenshot can pass this off as a live Mac." All three clauses are
    /// now false: production builds a `BridgeClient` per host, that file is in
    /// `LocalisTests/` and invisible to the app, and the pill that announced it
    /// is deleted. `probe` still returns `.reachable` unconditionally — that is
    /// the one part that survived, and it is why this test asserts the *wiring*
    /// (a reachable host ends with a sendable composer) and not that any
    /// particular Mac answered.
    ///
    /// `orphanedSessionStaysBlocked` in `SessionReconnectTests` is the guard on
    /// the shortcut this must not be made green by: relaxing the normalisation
    /// so `.idle` reads back would hand every stored session a composer on a
    /// connection nobody opened. That test was green before this change and is
    /// green after it.
    @Test("a restored session can be replied to once its Mac answers")
    func restoredSessionBecomesSendable() async throws {
        let host = HostID()
        let id = UUID()
        let repository = try await Self.seeded(
            (
                host,
                AgentBackend(id: "claude", displayName: "Studio Claude"),
                Self.session(id: id, host: host, backendID: "claude", status: .idle)
            )
        )

        let model = await Self.detailModel(repository: repository, sessionID: id)
        await model.load()

        let composer = try #require(await model.composer)
        #expect(composer.canSend == true)
        #expect(composer.blockedReason == nil)
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
    ///
    /// **Why there is no sibling test for the *unavailable* backend**, which is
    /// `resolveBackend`'s other reason to block sending. It cannot be written
    /// yet, and not because of a gap in the fixtures. Two layers, and the
    /// second is the one that matters for whoever picks up #29:
    ///
    /// - **Nothing produces it.** `grep -rn "\.models(" Localis/Sources` is
    ///   empty, so `SessionDetailView.swift:116`'s `match.isAvailable` cannot
    ///   be false at all today. The "isn't signed in" sentence has no writer.
    /// - **And the read path would erase it anyway.** Both repositories drop
    ///   `availability` on the way out, deliberately: the SwiftData one by
    ///   having no column for it (`StoredMapping.swift:117`), the in-memory one
    ///   by an explicit `withAvailability(.available)`
    ///   (`SessionRepository.swift:129`). It answers "can the host route to
    ///   this *right now*", which nothing on disk knows, and a stored
    ///   `not_logged_in` would grey out a backend the user has since signed
    ///   into.
    ///
    /// So wiring the live refresh is **not** sufficient on its own: as long as
    /// the backend reaching the view came out of a repository, it arrives
    /// `.available` regardless of what the host just said. Either the refresh
    /// hands runtime availability to the model without a round trip through
    /// storage, or that erase-on-read rule changes — and it is a rule the two
    /// implementations were deliberately aligned on, so it is not a one-liner.
    ///
    /// Tracked as #29, both layers, rather than papered over with a test that
    /// asserts a path nothing can reach.
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

import Foundation
import Testing

@testable import SessionStore

import LocalisModels

/// Properties that must hold for **every** `SessionRepository`, run against all
/// of them.
///
/// This suite exists because of a mutant that survived. `StoredHostTests` proved
/// the disk-backed store never hands back a pinned certificate — but making
/// `InMemorySessionRepository` keep the pin changed nothing, because every test
/// in that suite drove the SwiftData one. The gap was not "a missing assertion";
/// it was "an implementation nobody was asserting anything about".
///
/// That gap is worse than it sounds, and the reason is which implementation goes
/// untested. `InMemorySessionRepository` is what previews and other packages'
/// tests inject — so the untested implementation is the one most test evidence
/// is *produced on*, and the tested one is the only one that ships. A behaviour
/// that differs between them makes a green UI test a statement about software
/// the user never runs.
///
/// So: a property belongs here, parameterised, whenever it is a promise of the
/// *protocol* rather than of one implementation. Anything written against a
/// single concrete type can only ever be evidence about that type.
@Suite("SessionRepository conformance")
struct SessionRepositoryConformanceTests {
    // MARK: - Fixtures

    /// Which implementation a test is driving.
    enum Implementation: CustomStringConvertible, CaseIterable {
        case swiftData
        case inMemory

        func make() throws -> any SessionRepository {
            switch self {
            case .swiftData:
                return SwiftDataSessionRepository(container: try SessionStoreContainer.inMemory())
            case .inMemory:
                return InMemorySessionRepository()
            }
        }

        var description: String {
            switch self {
            case .swiftData: return "SwiftDataSessionRepository"
            case .inMemory: return "InMemorySessionRepository"
            }
        }
    }

    /// Every implementation, as test arguments.
    ///
    /// Spelled as `allCases` rather than a hand-written array so that adding a
    /// third implementation cannot quietly skip these properties: the new case
    /// is enrolled by existing, not by somebody remembering to enrol it.
    static let implementations = Implementation.allCases

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// Built from byte tuples rather than parsed from strings: a
    /// `UUID(uuidString:)!` asserts at runtime a constant the compiler could
    /// have checked, and the force unwrap is what SwiftLint rejects.
    ///
    /// Both are deliberately non-zero, because `HostID.unattributed` is the
    /// all-zero id — a fixture that happened to equal it would make the
    /// host-scoping tests pass while describing one machine rather than two.
    private static let hostA = HostID(
        rawValue: UUID(uuid: (0xA1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    )
    private static let hostB = HostID(
        rawValue: UUID(uuid: (0xB2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
    )

    /// The two host fixtures are distinct machines, and neither is "no machine".
    ///
    /// Everything below that claims host scoping — `backendsAreHostScoped`,
    /// `queriesAreHostScoped`, `backendDeletionIsHostScoped` — is only saying
    /// something if `hostA != hostB`, and the orphaning properties are only
    /// saying something if neither equals `.unattributed`. All of that rests on
    /// two literals, and a literal that drifted into the all-zero id would turn
    /// those tests green by making them describe one machine instead of two.
    ///
    /// So the premise is asserted rather than assumed: this is the one test
    /// whose failure explains why the others cannot be believed.
    @Test("the host fixtures name two real, different machines")
    func fixturesAreDistinctAttributedHosts() {
        #expect(Self.hostA != Self.hostB)
        #expect(Self.hostA.isUnattributed == false)
        #expect(Self.hostB.isUnattributed == false)
    }

    /// A paired machine, optionally carrying a pin.
    ///
    /// The pin is a parameter rather than always-nil so a test can hand the
    /// store a fully-composed host — pin included — and assert the pin does not
    /// come back. A fixture that could not carry one would make "the pin is
    /// dropped" unfalsifiable.
    ///
    /// The value is an obvious non-secret: this repository is public, and a
    /// string that looked like a real base64 SPKI hash would be a thing future
    /// readers have to check rather than recognise.
    private static func pairedHost(id: HostID, pin: SPKIHash?) -> LocalisHost {
        LocalisHost(
            id: id,
            displayName: "A Mac",
            endpoint: HostEndpoint(host: "example.invalid", port: 8443),
            bridgeID: "bridge",
            pinnedSPKI: pin,
            pairingState: .paired,
            protocolVersion: 1,
            kind: .other
        )
    }

    private static func session(
        id: UUID = UUID(),
        hostID: HostID = hostA,
        backendID: String = "claude",
        title: String = "Session",
        messages: [Message] = [],
        updatedAt: Date = t0,
        status: SessionStatus = .idle
    ) -> Session {
        Session(
            id: id, hostID: hostID, backendID: backendID, title: title,
            messages: messages, createdAt: t0, updatedAt: updatedAt, status: status
        )
    }

    // MARK: - Restored connection state

    /// **A restored session may not present as sendable.**
    ///
    /// `canSend` is true for `.idle` alone, and `.idle` means *connected and not
    /// busy*. After a relaunch the first half is false for every stored session:
    /// the process that owned the connection is gone. So a store that hands back
    /// `.idle` is not merely returning a stale value, it is returning a false
    /// one — and the falsehood is precisely the one FR-053 exists to prevent,
    /// where the composer accepts text and the send fails afterwards.
    ///
    /// Parameterised because this is the divergence that cost the most: the
    /// in-memory store returned `.idle` unchanged, so a UI test asserting "the
    /// composer is disabled after a relaunch" passed on the store the test
    /// injected and described the opposite of the store that ships.
    @Test(
        "a session read back from storage is never sendable",
        arguments: implementations
    )
    func restoredSessionIsNeverSendable(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let session = Self.session(status: .idle)

        try await repository.create(session)
        let restored = try #require(try await repository.session(id: session.id))

        #expect(
            restored.canSend == false,
            "\(implementation) restored a session the composer would offer to send on"
        )
        #expect(
            restored.status == .disconnected,
            "\(implementation) restored \(restored.status) rather than .disconnected"
        )
    }

    /// The transient connection states all collapse to `.disconnected`.
    ///
    /// Not just `.idle`: `.connecting` and `.streaming` describe a live link too,
    /// and a session restored as `.streaming` would render a spinner for a turn
    /// no process is running.
    @Test(
        "transient connection states do not survive a restore",
        arguments: implementations,
        [SessionStatus.idle, .connecting, .streaming, .disconnected]
    )
    func transientStatesCollapse(
        _ implementation: Implementation,
        status: SessionStatus
    ) async throws {
        let repository = try implementation.make()
        let session = Self.session(status: status)

        try await repository.create(session)
        let restored = try #require(try await repository.session(id: session.id))

        #expect(
            restored.status == .disconnected,
            "\(implementation) restored \(status) as \(restored.status)"
        )
    }

    /// `.error` **does** survive, and this is the counterweight to the test
    /// above.
    ///
    /// Without it, "collapse everything to `.disconnected`" would pass, and the
    /// user would relaunch to find yesterday's failed turn sitting at
    /// `.disconnected` with no indication their message was never answered. A
    /// failure is a historical fact; nothing on next launch can re-derive it.
    @Test(
        "a failed turn is still failed after a restore",
        arguments: implementations
    )
    func errorStatusSurvives(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let session = Self.session(status: .error(.unreachable))

        try await repository.create(session)
        let restored = try #require(try await repository.session(id: session.id))

        #expect(
            restored.status == .error(.unreachable),
            "\(implementation) lost the failure, restoring \(restored.status)"
        )
    }

    /// A session with no machine is orphaned, whichever store it came from.
    ///
    /// `UnattributedHost` states this as an invariant — "a session carrying this
    /// id is always `.orphaned`" — and an unattributed session that came back
    /// `.idle` would be sendable, with no machine to send to.
    @Test(
        "a session with no machine is orphaned and unsendable",
        arguments: implementations
    )
    func unattributedSessionIsOrphaned(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let session = Self.session(hostID: .unattributed, status: .idle)

        try await repository.create(session)
        let restored = try #require(try await repository.session(id: session.id))

        #expect(
            restored.status == .orphaned,
            "\(implementation) restored an unattributed session as \(restored.status)"
        )
        #expect(
            restored.canSend == false,
            "\(implementation) would let the composer send with no machine to send to"
        )
    }

    /// Which read path a test pulls a session back through.
    ///
    /// Exists because a mutant survived: making `allSessions()` skip the
    /// normalisation changed nothing, since every status test above reads
    /// through `session(id:)`. Three paths return a `Session`, and a promise
    /// about "a session read back from storage" is a promise about all three —
    /// the list is in fact the *more* dangerous one to get wrong, because the
    /// session list is what renders on launch before any detail view is opened.
    enum ReadPath: CustomStringConvertible, CaseIterable {
        case byID
        case all
        case query

        func read(_ id: UUID, from repository: any SessionRepository) async throws -> Session? {
            switch self {
            case .byID:
                return try await repository.session(id: id)
            case .all:
                return try await repository.allSessions().first { $0.id == id }
            case .query:
                let all = try await repository.allSessions()
                guard let session = all.first(where: { $0.id == id }) else { return nil }
                let query = session.hostID.isUnattributed
                    ? SessionQuery.unattributed
                    : SessionQuery(hostID: session.hostID)
                return try await repository.sessions(matching: query).first { $0.id == id }
            }
        }

        var description: String {
            switch self {
            case .byID: return "session(id:)"
            case .all: return "allSessions()"
            case .query: return "sessions(matching:)"
            }
        }
    }

    /// **Every read path applies the same normalisation.**
    ///
    /// The cross product is the point: two implementations × three read paths is
    /// six ways to hand back a sendable session, and testing one of the six is
    /// what let both earlier gaps through. Written as one parameterised test so
    /// that a new implementation or a new read path is enrolled by existing.
    @Test(
        "a session is never sendable, whichever way it is read",
        arguments: implementations,
        ReadPath.allCases
    )
    func noReadPathReturnsASendableSession(
        _ implementation: Implementation,
        path: ReadPath
    ) async throws {
        let repository = try implementation.make()
        let session = Self.session(status: .idle)
        try await repository.create(session)

        let restored = try #require(try await path.read(session.id, from: repository))

        #expect(
            restored.canSend == false,
            "\(implementation) via \(path) returned a session the composer would send on"
        )
        #expect(
            restored.status == .disconnected,
            "\(implementation) via \(path) returned \(restored.status)"
        )
    }

    /// An unattributed session is orphaned through every read path too.
    @Test(
        "a machine-less session is orphaned, whichever way it is read",
        arguments: implementations,
        ReadPath.allCases
    )
    func noReadPathUnorphansAnUnattributedSession(
        _ implementation: Implementation,
        path: ReadPath
    ) async throws {
        let repository = try implementation.make()
        let session = Self.session(hostID: .unattributed, status: .idle)
        try await repository.create(session)

        let restored = try #require(try await path.read(session.id, from: repository))

        #expect(
            restored.status == .orphaned,
            "\(implementation) via \(path) returned \(restored.status)"
        )
    }

    /// A failure survives every read path — the counterweight, applied to all
    /// three.
    @Test(
        "a failed turn stays failed, whichever way it is read",
        arguments: implementations,
        ReadPath.allCases
    )
    func noReadPathLosesTheFailure(
        _ implementation: Implementation,
        path: ReadPath
    ) async throws {
        let repository = try implementation.make()
        let session = Self.session(status: .error(.unreachable))
        try await repository.create(session)

        let restored = try #require(try await path.read(session.id, from: repository))

        #expect(
            restored.status == .error(.unreachable),
            "\(implementation) via \(path) returned \(restored.status)"
        )
    }

    // MARK: - Backend availability


    /// **Availability is never restored from storage.**
    ///
    /// It answers "can the host route to this *right now*", which nothing on
    /// disk can know. A stored `not_logged_in` from last week would grey out a
    /// backend the user has since signed into, and it would stay greyed until
    /// the next `/v1/models` refresh — the user's only recourse being to guess
    /// that reconnecting fixes it.
    ///
    /// The optimistic default is deliberate: it can only ever cause a failed
    /// send with a real error from the host, whereas the pessimistic one hides a
    /// working backend behind a stale fact.
    ///
    /// **The `/v1/models` refresh this defers to has no production path (#29),
    /// so what this test pins is currently the only answer anything can get.**
    /// Measured 2026-08-04 over `Packages/*/Sources` and `Localis/Sources`:
    /// `withAvailability` has one production caller, `SessionRepository.restored`,
    /// and it passes `.available`. `BackendCatalog` decodes
    /// `.unavailable(reason:)` off the wire correctly, but its only consumer is
    /// `BridgeClient.probe`, which reads `isAvailable` into a `Bool` and drops
    /// the backend. Nothing carries a decoded availability to storage or to a
    /// view, so `SessionDetailView`'s "isn't signed in" branch cannot be reached
    /// — this suite's green is about a value with one possible source, not about
    /// a store choosing correctly between two.
    ///
    /// That does **not** make this test redundant, and it is worth saying which
    /// half it guards: it fails if a store starts persisting availability, which
    /// is the mistake that stays wrong after #29 is fixed. It is silent about
    /// the missing refresh, which is why the note is here rather than left for
    /// someone to infer from a passing run.
    ///
    /// **The two arguments are not guarded equally.** Removing the
    /// `withAvailability(.available)` from `InMemorySessionRepository.restored`
    /// turns this red on that argument only (verified 2026-08-04); the SwiftData
    /// one has no line to remove, because `StoredBackend` has no column and the
    /// drop is a consequence of the schema. So for the disk-backed store this is
    /// a property with no corresponding code to break — parameterising over both
    /// makes the coverage *look* symmetric when only one side has something that
    /// could regress. The asymmetry is the point of keeping both: the schema is
    /// what would have to change there, and it would change this test's answer.
    @Test(
        "a stored backend comes back available, whatever was saved",
        arguments: implementations
    )
    func availabilityIsNotRestored(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let backend = AgentBackend(
            id: "claude",
            displayName: "Claude",
            capabilities: [.streaming],
            availability: .unavailable(reason: "not_logged_in")
        )

        try await repository.save(backend, on: Self.hostA)
        let restored = try #require(try await repository.backends(ofHost: Self.hostA).first)

        #expect(
            restored.isAvailable,
            "\(implementation) restored a stale \(restored.availability)"
        )
        #expect(
            restored.capabilities == [.streaming],
            "\(implementation) lost the capability set while dropping availability"
        )
    }

    /// An unrecognised capability round-trips intact (contract §2,
    /// constitution IV).
    ///
    /// The whole point of a capability *set* rather than an enum is that the
    /// bridge can add one without an iOS release. A store that dropped unknown
    /// values would reintroduce the release coupling silently — the backend
    /// would keep working and merely appear less capable.
    @Test(
        "a capability this build has no name for survives storage",
        arguments: implementations
    )
    func unknownCapabilitySurvives(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let exotic = Capability(rawValue: "time_travel")

        try await repository.save(
            AgentBackend(id: "claude", displayName: "Claude", capabilities: [.streaming, exotic]),
            on: Self.hostA
        )
        let restored = try #require(try await repository.backends(ofHost: Self.hostA).first)

        #expect(
            restored.capabilities == [.streaming, exotic],
            "\(implementation) restored \(restored.capabilities)"
        )
    }

    // MARK: - Host scoping (FR-029)

    /// The same backend name on two machines is two backends.
    ///
    /// A bare `backendID` is unique only within one host, so a store keyed on it
    /// alone would let pairing a second Mac overwrite the first Mac's backend
    /// list. Both implementations must key on the pair.
    @Test(
        "same-named backends on two machines do not collide",
        arguments: implementations
    )
    func backendsAreHostScoped(_ implementation: Implementation) async throws {
        let repository = try implementation.make()

        try await repository.save(
            AgentBackend(id: "claude", displayName: "Studio Claude"), on: Self.hostA
        )
        try await repository.save(
            AgentBackend(id: "claude", displayName: "Air Claude"), on: Self.hostB
        )

        let onA = try await repository.backends(ofHost: Self.hostA)
        let onB = try await repository.backends(ofHost: Self.hostB)

        #expect(onA.map(\.displayName) == ["Studio Claude"], "\(implementation) leaked across hosts")
        #expect(onB.map(\.displayName) == ["Air Claude"], "\(implementation) leaked across hosts")
    }

    /// Deleting one machine's backend leaves the same-named one elsewhere alone.
    @Test(
        "deleting a backend on one machine spares its namesake",
        arguments: implementations
    )
    func backendDeletionIsHostScoped(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        try await repository.save(AgentBackend(id: "claude", displayName: "A"), on: Self.hostA)
        try await repository.save(AgentBackend(id: "claude", displayName: "B"), on: Self.hostB)

        try await repository.deleteBackend(id: "claude", on: Self.hostA)

        #expect(try await repository.backends(ofHost: Self.hostA).isEmpty)
        #expect(
            try await repository.backends(ofHost: Self.hostB).map(\.displayName) == ["B"],
            "\(implementation) deleted the other machine's backend too"
        )
    }

    /// Saving a backend twice updates it rather than duplicating it.
    @Test("saving a backend twice updates one row", arguments: implementations)
    func backendSaveIsUpsert(_ implementation: Implementation) async throws {
        let repository = try implementation.make()

        try await repository.save(
            AgentBackend(id: "claude", displayName: "Old", capabilities: [.streaming]),
            on: Self.hostA
        )
        try await repository.save(
            AgentBackend(id: "claude", displayName: "New", capabilities: [.skills]),
            on: Self.hostA
        )

        let all = try await repository.backends(ofHost: Self.hostA)
        #expect(all.count == 1, "\(implementation) stored \(all.count) rows for one backend")
        #expect(all.first?.displayName == "New")
        #expect(all.first?.capabilities == [.skills])
    }

    /// Backends come back alphabetical, so the picker doesn't reorder between
    /// launches — rows that move are rows the user mis-taps.
    @Test("backends are alphabetical", arguments: implementations)
    func backendsAreSorted(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        for name in ["Zed", "Alpha", "Middle"] {
            try await repository.save(
                AgentBackend(id: name.lowercased(), displayName: name), on: Self.hostA
            )
        }

        let names = try await repository.backends(ofHost: Self.hostA).map(\.displayName)
        #expect(names == ["Alpha", "Middle", "Zed"], "\(implementation) returned \(names)")
    }

    // MARK: - Session lifecycle

    /// Sessions come back newest-activity first — the order the list renders in.
    ///
    /// The three timestamps are distinct on purpose. Equal ones make the sort
    /// order a tie the two implementations are free to break differently, and a
    /// test that passes on one and flakes on the other teaches nothing.
    @Test("sessions are newest-updated first", arguments: implementations)
    func sessionsSortedByRecency(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        try await repository.create(Self.session(title: "Older", updatedAt: Self.t0))
        try await repository.create(
            Self.session(title: "Newest", updatedAt: Self.t0.addingTimeInterval(120))
        )
        try await repository.create(
            Self.session(title: "Middle", updatedAt: Self.t0.addingTimeInterval(60))
        )

        let titles = try await repository.allSessions().map(\.title)
        #expect(titles == ["Newest", "Middle", "Older"], "\(implementation) returned \(titles)")
    }

    /// Re-creating an existing id is a no-op, not an overwrite.
    ///
    /// The host binding is fixed for life (FR-030), so `create` must not be a
    /// path by which a conversation changes machine — which is what an
    /// overwrite would be.
    @Test("creating an existing session changes nothing", arguments: implementations)
    func createIsIdempotent(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let id = UUID()
        try await repository.create(Self.session(id: id, title: "First"))
        try await repository.create(Self.session(id: id, hostID: Self.hostB, title: "Second"))

        let stored = try #require(try await repository.session(id: id))
        #expect(stored.title == "First", "\(implementation) overwrote an existing session")
        #expect(stored.hostID == Self.hostA, "\(implementation) moved a session between machines")
        #expect(try await repository.allSessions().count == 1)
    }

    /// Saving a session that was never created stores nothing.
    ///
    /// `save` is an update, not an upsert: a caller holding a stale session must
    /// not be able to resurrect a conversation the user deleted.
    @Test("saving an unknown session stores nothing", arguments: implementations)
    func saveDoesNotInsert(_ implementation: Implementation) async throws {
        let repository = try implementation.make()

        try await repository.save(Self.session(title: "Ghost"))

        #expect(
            try await repository.allSessions().isEmpty,
            "\(implementation) resurrected a session through save"
        )
    }

    /// A save carrying a different machine keeps the stored one (FR-030).
    @Test("save cannot move a session between machines", arguments: implementations)
    func saveKeepsHostBinding(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let id = UUID()
        try await repository.create(Self.session(id: id, hostID: Self.hostA))

        try await repository.save(Self.session(id: id, hostID: Self.hostB, title: "Moved"))

        let stored = try #require(try await repository.session(id: id))
        #expect(stored.hostID == Self.hostA, "\(implementation) moved the conversation")
        #expect(stored.title == "Moved", "\(implementation) dropped the legitimate edit")
    }

    /// `createdAt` is identity, not content — a save cannot rewrite it.
    @Test("save preserves the creation time", arguments: implementations)
    func saveKeepsCreatedAt(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let id = UUID()
        try await repository.create(Self.session(id: id))

        try await repository.save(
            Session(
                id: id, hostID: Self.hostA, backendID: "claude", title: "Edited",
                messages: [], createdAt: Self.t0.addingTimeInterval(9_999),
                updatedAt: Self.t0.addingTimeInterval(60), status: .idle
            )
        )

        let stored = try #require(try await repository.session(id: id))
        #expect(stored.createdAt == Self.t0, "\(implementation) rewrote the creation time")
    }

    /// Deleting things that are not there is not an error.
    ///
    /// All three delete paths, because a store that threw on one of them would
    /// turn a double-tap into an error the user has to read.
    @Test("deleting absent things is a no-op", arguments: implementations)
    func deletesAreIdempotent(_ implementation: Implementation) async throws {
        let repository = try implementation.make()

        try await repository.delete(id: UUID())
        try await repository.deleteBackend(id: "absent", on: Self.hostA)
        try await repository.deleteHost(id: HostID(rawValue: UUID()))

        #expect(try await repository.allSessions().isEmpty)
    }

    /// The "no machine" marker is refused as a host row.
    ///
    /// A row for it would appear in `hosts()` as a machine the user could tap,
    /// and tapping it would try to connect to nothing.
    @Test("the unattributed marker is not storable as a machine", arguments: implementations)
    func unattributedHostIsRefused(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let marker = LocalisHost(
            id: .unattributed,
            displayName: "Nowhere",
            endpoint: HostEndpoint(host: "localhost", port: 8443),
            bridgeID: nil,
            pinnedSPKI: nil,
            pairingState: .discovered,
            protocolVersion: 1,
            kind: .other
        )

        await #expect(throws: LocalisError.self) {
            try await repository.save(marker)
        }
        #expect(
            try await repository.hosts().isEmpty,
            "\(implementation) stored the no-machine marker as a machine"
        )
    }

    /// A host-scoped query never returns another machine's sessions (FR-029).
    @Test("a query is confined to its machine", arguments: implementations)
    func queriesAreHostScoped(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        try await repository.create(Self.session(hostID: Self.hostA, title: "On A"))
        try await repository.create(Self.session(hostID: Self.hostB, title: "On B"))

        let onA = try await repository.sessions(matching: SessionQuery(hostID: Self.hostA))

        #expect(onA.map(\.title) == ["On A"], "\(implementation) returned \(onA.map(\.title))")
    }

    /// The unattributed query returns legacy rows and nothing else.
    @Test("the unattributed query finds only machine-less sessions", arguments: implementations)
    func unattributedQueryIsExact(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        try await repository.create(Self.session(hostID: .unattributed, title: "Legacy"))
        try await repository.create(Self.session(hostID: Self.hostA, title: "Attributed"))

        let legacy = try await repository.sessions(matching: .unattributed)

        #expect(legacy.map(\.title) == ["Legacy"], "\(implementation) returned \(legacy.map(\.title))")
    }

    /// A transcript edit rewrites the stored messages rather than accumulating
    /// them.
    ///
    /// The streaming path saves the same message id repeatedly, so a store that
    /// appended would grow one duplicate per chunk.
    @Test("saving a transcript replaces it rather than appending", arguments: implementations)
    func transcriptIsReplaced(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let id = UUID()
        let messageID = UUID()
        let first = Message(
            id: messageID, role: .assistant, text: "partial",
            createdAt: Self.t0, status: .streaming
        )
        try await repository.create(Self.session(id: id, messages: [first]))

        let finished = Message(
            id: messageID, role: .assistant, text: "the whole answer",
            createdAt: Self.t0, status: .complete
        )
        try await repository.save(Self.session(id: id, messages: [finished]))

        let stored = try #require(try await repository.session(id: id))
        #expect(stored.messages.map(\.text) == ["the whole answer"], "\(implementation)")
    }

    /// Messages removed upstream are removed from storage too.
    @Test("a message dropped upstream does not linger", arguments: implementations)
    func removedMessagesAreDropped(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let id = UUID()
        let message = Message(
            id: UUID(), role: .user, text: "typo", createdAt: Self.t0, status: .complete
        )
        try await repository.create(Self.session(id: id, messages: [message]))

        try await repository.save(Self.session(id: id, messages: []))

        let stored = try #require(try await repository.session(id: id))
        #expect(stored.messages.isEmpty, "\(implementation) kept a deleted message")
    }

    // MARK: - Single-host lookup

    /// **`host(id:)` never hands back a pin, on either implementation.**
    ///
    /// `hosts()` was already guarded, `host(id:)` was not, and the gap matters
    /// because of which one the app calls: the list renders the picker, but the
    /// single lookup is what a connection attempt goes through. A pin leaking
    /// from the lookup would make `canConnect` true on a host the Keychain never
    /// vouched for — the exact fact M4's surviving mutant proved nothing was
    /// asserting about.
    ///
    /// Probed on both before being written: neither diverges today. That makes
    /// this a regression guard rather than a bug fix, and it is worth having for
    /// the same reason the `ReadPath` cross-product was — one promise reachable
    /// by two paths, with only one of them under test, is a promise about the
    /// path nobody exercised.
    @Test(
        "a single-host lookup never carries a pin",
        arguments: implementations
    )
    func hostLookupCarriesNoPin(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        let paired = Self.pairedHost(id: Self.hostA, pin: SPKIHash(base64: "not-a-real-pin"))

        try await repository.save(paired)
        let found = try #require(try await repository.host(id: Self.hostA))

        #expect(
            found.pinnedSPKI == nil,
            "\(implementation) returned a pin from the table; the Keychain is the only anchor"
        )
        #expect(
            found.canConnect == false,
            "\(implementation) made a stored host connectable without the composition point"
        )
        #expect(
            found.pairingState == .paired,
            "\(implementation) lost the pairing state, which the table *is* meant to hold"
        )
    }

    /// A machine that was never saved is absent, not a placeholder.
    ///
    /// Paired with the test above so "never carries a pin" cannot be satisfied
    /// by a lookup that returns nothing at all: one asserts the hit, this one
    /// asserts the miss.
    @Test(
        "looking up an unknown machine finds nothing",
        arguments: implementations
    )
    func unknownHostLookupIsNil(_ implementation: Implementation) async throws {
        let repository = try implementation.make()
        try await repository.save(Self.pairedHost(id: Self.hostA, pin: nil))

        let found = try await repository.host(id: Self.hostB)

        #expect(found == nil, "\(implementation) invented a machine it was never given")
    }

    /// The "no machine" marker is never a machine.
    ///
    /// `save` refuses it, so a lookup must not find one either — otherwise a
    /// legacy session's `.unattributed` id would resolve to something tappable
    /// in the UI, which is exactly what `UnattributedHost` exists to prevent.
    @Test(
        "the no-machine marker resolves to no machine",
        arguments: implementations
    )
    func unattributedHostLookupIsNil(_ implementation: Implementation) async throws {
        let repository = try implementation.make()

        let found = try await repository.host(id: .unattributed)

        #expect(found == nil, "\(implementation) resolved .unattributed to a host")
    }
}

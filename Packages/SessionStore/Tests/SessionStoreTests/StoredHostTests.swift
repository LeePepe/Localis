import Foundation
import Testing

@testable import SessionStore

import LocalisModels
import SwiftData

/// Which `SessionRepository` a test is driving.
///
/// Exists so a property that must hold for *both* implementations is written
/// once and parameterised, rather than written against whichever one was handy.
/// The two sit behind a single protocol, so a behavioural difference between
/// them is invisible to any test that only exercises one — and the in-memory
/// one is what previews and UI tests run on.
enum RepositoryKind: CustomStringConvertible {
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

/// Persistence for the machines themselves.
///
/// Until this table existed, `StoredSession.hostID` and `StoredBackend.hostID`
/// were foreign keys into nothing: every query was host-scoped, and no row
/// anywhere recorded what a host *was*. A paired Mac survived exactly as long as
/// the process did.
///
/// Two of the suites below are not about round-tripping fields. `Shape` asserts
/// what the table is allowed to contain, and `On disk` asserts that adding it
/// did not cost anyone their existing conversations. Both are here because
/// neither can be re-derived by reading the model later.
@Suite("Stored hosts")
struct StoredHostTests {
    /// Fixed ids so a failure names the same machine every run.
    ///
    /// Built from bytes rather than parsed from a string: `UUID(uuidString:)`
    /// returns an optional, and the `!` that follows is a force-unwrap the lint
    /// rules reject — reasonably, since a typo in the literal would crash the
    /// suite rather than fail a test.
    private static let idA = HostID(rawValue: UUID(uuid: (0xA1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
    private static let idB = HostID(rawValue: UUID(uuid: (0xB2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)))

    private static func host(
        id: HostID,
        name: String,
        endpoint: HostEndpoint = HostEndpoint(host: "bridge.local", port: 8443),
        bridgeID: String? = nil,
        pinnedSPKI: SPKIHash? = nil,
        pairingState: HostPairingState = .discovered,
        protocolVersion: Int = 1,
        kind: HostKind = .mac
    ) -> LocalisHost {
        LocalisHost(
            id: id,
            displayName: name,
            endpoint: endpoint,
            bridgeID: bridgeID,
            pinnedSPKI: pinnedSPKI,
            pairingState: pairingState,
            protocolVersion: protocolVersion,
            kind: kind
        )
    }

    private static func repository() throws -> SwiftDataSessionRepository {
        SwiftDataSessionRepository(container: try SessionStoreContainer.inMemory())
    }

    // MARK: - Round trip

    /// Every field this package owns survives a round trip.
    ///
    /// The expected value is built with `pinnedSPKI: nil` rather than compared
    /// against the host that was saved: the pin is not this package's to keep
    /// (see `storageHoldsNoSecondTrustAnchor`), so equality with the original
    /// would be asserting the opposite of the design. Everything *else* must
    /// match exactly, which is what makes this a round trip rather than a spot
    /// check.
    @Test("a saved host comes back with every field this layer owns")
    func savedHostRoundTrips() async throws {
        let repository = try Self.repository()
        let fields: (endpoint: HostEndpoint, bridgeID: String?, protocolVersion: Int, kind: HostKind) = (
            HostEndpoint(host: "192.168.1.20", port: 9443), "bridge-7", 3, .nas
        )
        let saved = Self.host(
            id: Self.idA,
            name: "Studio",
            endpoint: fields.endpoint,
            bridgeID: fields.bridgeID,
            pinnedSPKI: SPKIHash(base64: "c3BraQ=="),
            pairingState: .paired,
            protocolVersion: fields.protocolVersion,
            kind: fields.kind
        )

        try await repository.save(saved)

        let loaded = try #require(try await repository.host(id: Self.idA))
        #expect(
            loaded == Self.host(
                id: Self.idA,
                name: "Studio",
                endpoint: fields.endpoint,
                bridgeID: fields.bridgeID,
                pinnedSPKI: nil,
                pairingState: .paired,
                protocolVersion: fields.protocolVersion,
                kind: fields.kind
            )
        )
    }

    /// Pairing state survives; connectability is deliberately **not** restored.
    ///
    /// A host read straight from this package is always `pinnedSPKI == nil`, so
    /// `canConnect` is false even for a machine the user really did pair. That
    /// is the honest answer for a layer that does not hold the pin: the
    /// Keychain does, and only the app's composition point can put the two
    /// halves together.
    ///
    /// **This asymmetry is the dangerous part of the design, so it is asserted
    /// rather than described.** `pairingState == .paired` with `canConnect ==
    /// false` is a state the rest of the app must tolerate — core found the
    /// same gap from the other side, where a view model computed
    /// connectability from the state alone and no test could tell the
    /// difference, because no fixture had ever produced this combination. This
    /// is the fixture that produces it.
    @Test("a restored host keeps its pairing state but is not connectable on its own")
    func restoredHostKeepsPairingStateWithoutThePin() async throws {
        let repository = try Self.repository()
        try await repository.save(
            Self.host(id: Self.idA, name: "Studio")
                .paired(pinning: SPKIHash(base64: "c3BraQ=="))
        )

        let loaded = try #require(try await repository.host(id: Self.idA))
        #expect(loaded.pairingState == .paired)
        #expect(loaded.pinnedSPKI == nil)
        #expect(loaded.canConnect == false)
    }

    /// Unpairing must leave a `revoked` state behind, not a connectable one.
    ///
    /// The pin is gone from every restored host regardless (this layer does not
    /// store one), so the load-bearing assertion here is `pairingState`: a
    /// revoked machine that came back `.paired` would be offered to the user as
    /// something to connect to once the composition point supplied a pin —
    /// except the Keychain's pin is gone too (`removeCredentials(for:)`), and
    /// the two halves disagreeing is exactly the drift we removed the column to
    /// prevent.
    @Test("an unpaired host comes back revoked, not merely pinless")
    func unpairedHostComesBackRevoked() async throws {
        let repository = try Self.repository()
        try await repository.save(
            Self.host(id: Self.idA, name: "Studio")
                .paired(pinning: SPKIHash(base64: "c3BraQ=="))
                .unpaired()
        )

        let loaded = try #require(try await repository.host(id: Self.idA))
        #expect(loaded.pairingState == .revoked)
        #expect(loaded.pinnedSPKI == nil)
        #expect(loaded.canConnect == false)
    }

    /// A machine seen on the network but never paired is stored like any other.
    ///
    /// `LocalisHost(adopting:)` produces exactly this — `.discovered`, no pin,
    /// `canConnect == false` — so it is the *ordinary* input to `save`, not an
    /// edge case. The user who spots their Mac in the list and quits before
    /// pairing should still see it next launch.
    ///
    /// Asserted rather than left to the absence of a guard: "we happen not to
    /// reject it today" and "we promise not to" read identically in the
    /// implementation, and only one of them survives someone adding a
    /// plausible-looking `guard host.pairingState == .paired`.
    @Test("a discovered but unpaired machine is stored, not refused")
    func discoveredHostIsStorable() async throws {
        let repository = try Self.repository()
        let discovered = Self.host(id: Self.idA, name: "Studio", pairingState: .discovered)
        #expect(discovered.pinnedSPKI == nil)
        #expect(discovered.canConnect == false)

        try await repository.save(discovered)

        let loaded = try #require(try await repository.host(id: Self.idA))
        #expect(loaded.pairingState == .discovered)
        #expect(loaded.canConnect == false)
        #expect(try await repository.hosts().map(\.id) == [Self.idA])
    }

    @Test("a host that was never saved is absent rather than invented")
    func unknownHostIsNil() async throws {
        let repository = try Self.repository()
        #expect(try await repository.host(id: Self.idA) == nil)
        #expect(try await repository.hosts().isEmpty)
    }

    // MARK: - Upsert

    /// Saving twice updates the machine rather than making a second one.
    ///
    /// The id is stable for life (FR-026), so a rename or a DHCP move arrives
    /// here as a save on an id that already exists. Inserting instead would put
    /// the same Mac in the list twice, and half its sessions would point at the
    /// copy the user did not pick.
    ///
    /// **This test cannot tell which mechanism upserts, and that is not a hole
    /// in it.** Mutating `save` to a bare `insert` leaves it green, because
    /// `#Unique<StoredHost>([\.id])` collapses the duplicate by itself —
    /// verified, along with the converse: removing the constraint while keeping
    /// the branch also keeps this property. Two guards on one property, either
    /// sufficient. The mutant is equivalent, not survived-because-unmeasured.
    ///
    /// Both stay. The constraint is what the *store* guarantees regardless of
    /// which code path writes; the branch is what makes the intent readable at
    /// the call site and what would still hold if the schema were ever rebuilt
    /// without the macro. Deleting either is safe today and silently removes the
    /// margin.
    @Test("saving a renamed, relocated host updates it instead of adding a second")
    func saveIsUpsert() async throws {
        let repository = try Self.repository()
        let original = Self.host(id: Self.idA, name: "Studio")
        try await repository.save(original)

        try await repository.save(
            original
                .renamed(to: "Studio (office)")
                .relocated(to: HostEndpoint(host: "10.0.0.4", port: 8443))
        )

        let all = try await repository.hosts()
        #expect(all.count == 1)
        #expect(all.first?.displayName == "Studio (office)")
        #expect(all.first?.endpoint.host == "10.0.0.4")
        #expect(all.first?.id == Self.idA)
    }

    /// An update must overwrite every field, including the ones that go to nil.
    ///
    /// Separate from `saveIsUpsert`, which counts rows. This one reads the row
    /// that survived: an upsert that merged instead of overwriting would keep
    /// the old `bridgeID` and the old pin, and the machine would come back
    /// carrying credentials-adjacent state the second save had cleared. The
    /// nil-ward direction is the one that breaks quietly — `apply` assigns
    /// rather than coalesces for exactly this reason (FR-027).
    @Test("an update overwrites fields that were cleared, not just fields that changed")
    func updateClearsFieldsThatWentAway() async throws {
        let repository = try Self.repository()
        try await repository.save(
            Self.host(id: Self.idA, name: "Studio", bridgeID: "bridge-7", protocolVersion: 3)
                .paired(pinning: SPKIHash(base64: "c3BraQ=="))
        )

        try await repository.save(
            Self.host(id: Self.idA, name: "Studio", bridgeID: nil, protocolVersion: 1)
        )

        let loaded = try #require(try await repository.host(id: Self.idA))
        #expect(loaded.bridgeID == nil)
        #expect(loaded.pinnedSPKI == nil)
        #expect(loaded.protocolVersion == 1)
        #expect(loaded.pairingState == .discovered)
    }

    /// Two machines are two rows even when they are named the same.
    ///
    /// The same shape as FR-029 one level up: identity is the id, never the
    /// display name, so two Macs both called "MacBook Pro" must not collapse.
    @Test("two machines with identical names stay two machines")
    func identicalNamesAreDistinctHosts() async throws {
        let repository = try Self.repository()
        try await repository.save(Self.host(id: Self.idA, name: "MacBook Pro"))
        try await repository.save(Self.host(id: Self.idB, name: "MacBook Pro"))

        #expect(try await repository.hosts().count == 2)
        #expect(try await repository.host(id: Self.idA)?.id == Self.idA)
        #expect(try await repository.host(id: Self.idB)?.id == Self.idB)
    }

    /// Alphabetical, for the same reason `backends(ofHost:)` is: this list is a
    /// picker, and a picker whose rows move between launches is one the user
    /// mis-taps.
    @Test("hosts come back in a stable alphabetical order")
    func hostsAreAlphabetical() async throws {
        let repository = try Self.repository()
        try await repository.save(Self.host(id: HostID(), name: "Zeta"))
        try await repository.save(Self.host(id: HostID(), name: "alpha"))
        try await repository.save(Self.host(id: HostID(), name: "Mid"))

        #expect(try await repository.hosts().map(\.displayName) == ["alpha", "Mid", "Zeta"])
    }

    // MARK: - Deleting

    @Test("deleting a host removes it, and deleting it twice is not an error")
    func deleteIsIdempotent() async throws {
        let repository = try Self.repository()
        try await repository.save(Self.host(id: Self.idA, name: "Studio"))

        try await repository.deleteHost(id: Self.idA)
        try await repository.deleteHost(id: Self.idA)

        #expect(try await repository.host(id: Self.idA) == nil)
    }

    /// Deleting a machine must not delete the conversations held on it.
    ///
    /// This is the same rule as unpairing (FR-027, FR-036) arriving through a
    /// different door. A `@Relationship(deleteRule: .cascade)` from host to
    /// session — the "obvious" schema — would silently make removing a machine
    /// from the list destroy its history.
    @Test("deleting a host leaves that machine's conversations readable")
    func deletingHostKeepsItsSessions() async throws {
        let repository = try Self.repository()
        try await repository.save(Self.host(id: Self.idA, name: "Studio"))
        try await repository.create(
            Session(
                id: UUID(),
                hostID: Self.idA,
                backendID: "claude",
                title: "Kept",
                messages: [Message(id: UUID(), role: .user, text: "hi", createdAt: Date(timeIntervalSince1970: 0))],
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        )

        try await repository.deleteHost(id: Self.idA)

        let sessions = try await repository.sessions(matching: SessionQuery(hostID: Self.idA))
        #expect(sessions.map(\.title) == ["Kept"])
        #expect(sessions.first?.messages.count == 1)
    }

    // MARK: - The unattributed sentinel

    /// `HostID.unattributed` is a marker for "no machine", not a machine.
    ///
    /// It is why the foreign keys in this schema are bare `UUID`s and not
    /// relationships: a real relationship would need a row for the sentinel, and
    /// that row is one `hosts()` would hand to the UI as a pairable Mac.
    /// Rejecting the write is what keeps the sentinel un-instantiable.
    @Test("the unattributed sentinel cannot be saved as if it were a machine")
    func unattributedHostIsRejected() async throws {
        let repository = try Self.repository()

        await #expect(throws: (any Error).self) {
            try await repository.save(Self.host(id: .unattributed, name: "Nowhere"))
        }
        #expect(try await repository.hosts().isEmpty)
        #expect(try await repository.host(id: .unattributed) == nil)
    }

    // MARK: - Both implementations

    /// **Neither implementation stores a pin**, and this runs against both.
    ///
    /// Added because a mutant survived: making `InMemorySessionRepository` keep
    /// the pin changed nothing, since every other test in this suite drives the
    /// SwiftData one. The two sit behind a single protocol, so a divergence is
    /// invisible exactly where it does the most damage — a UI test or preview
    /// built on the in-memory store would demonstrate `canConnect` surviving a
    /// reload, which is false in the shipping app.
    ///
    /// Parameterised over both rather than duplicated, so a third implementation
    /// cannot be added without deciding what it does here.
    @Test(
        "no implementation returns a pinned certificate",
        arguments: [RepositoryKind.swiftData, .inMemory]
    )
    func noImplementationStoresThePin(kind: RepositoryKind) async throws {
        let repository = try kind.make()
        try await repository.save(
            Self.host(id: Self.idA, name: "Studio")
                .paired(pinning: SPKIHash(base64: "c3BraQ=="))
        )

        let loaded = try #require(try await repository.host(id: Self.idA))
        #expect(loaded.pinnedSPKI == nil, "\(kind) handed back a pin")
        #expect(loaded.pairingState == .paired, "\(kind) lost the pairing state")
        #expect(loaded.canConnect == false, "\(kind) reported a connectable host")

        let listed = try #require(try await repository.hosts().first)
        #expect(listed.pinnedSPKI == nil, "\(kind) handed back a pin from hosts()")
    }

    /// A host seeded through the initializer is stripped like a saved one.
    ///
    /// The seed path is the one previews and UI tests actually use, so a pin
    /// that survived construction would be a pin the app can never have.
    @Test("a host seeded into the in-memory store arrives without its pin")
    func seededHostLosesItsPin() async throws {
        let repository = InMemorySessionRepository(
            hosts: [
                Self.host(id: Self.idA, name: "Studio")
                    .paired(pinning: SPKIHash(base64: "c3BraQ==")),
            ]
        )

        let loaded = try #require(try await repository.host(id: Self.idA))
        #expect(loaded.pinnedSPKI == nil)
        #expect(loaded.canConnect == false)
    }

    // MARK: - Shape

    /// **No credential may become a stored column** (constitution I).
    ///
    /// `LocalisHost` says so in a doc comment, and a doc comment is a sentence
    /// somebody can decline to read while adding `var pairingToken: String`. This
    /// asserts it against the schema SwiftData actually builds, so the person who
    /// adds the field sees red.
    ///
    /// The set is asserted exactly rather than by a deny-list of forbidden words.
    /// A deny-list only catches a field that is *named* like a secret, and the
    /// token would not be — it would arrive as `blob`, or `t`, or riding inside
    /// an existing string. Exact equality means every addition to this one table
    /// is a deliberate act with a test to update.
    @Test("the host table stores these columns and no others")
    func hostTableShapeIsPinned() throws {
        let entity = try #require(
            SessionStoreContainer.schema.entities.first { $0.name == "StoredHost" },
            "StoredHost is not in the container schema, so nothing persists it"
        )

        let stored = Set(entity.properties.map(\.name))
        #expect(
            stored == [
                "id",
                "displayName",
                "endpointHost",
                "endpointPort",
                "bridgeID",
                "pairingStateRaw",
                "protocolVersion",
                "kindRaw",
            ],
            """
            The host table's columns changed. If you are adding a pairing token, \
            an auth header, or anything else that would authenticate to a \
            machine: it belongs in the Keychain keyed by host id, never here \
            (constitution I). If you are adding something else, update this list \
            deliberately.
            """
        )
    }

    /// **There is no second trust anchor.**
    ///
    /// The pinned SPKI has exactly one owner — `HostCredentialStore`, in the
    /// Keychain, keyed by host id — and this table is not it. Two copies of a
    /// trust anchor drift, and the drifting one is what decides whether a
    /// connection is allowed to open.
    ///
    /// Named for the proposition rather than for the implementation, on purpose.
    /// "The pin is not in the table" describes today's code and reads as stale
    /// the moment somebody adds it back "for convenience" — at which point the
    /// tidy move is to delete the test. "There is no second trust anchor" is a
    /// claim about the system, and adding the column makes it false.
    ///
    /// So this asserts two things that must stay true together: the column is
    /// absent from the built schema, and a host saved *carrying* a pin does not
    /// smuggle one into storage.
    @Test("there is no second trust anchor: storage never holds a pinned certificate")
    func storageHoldsNoSecondTrustAnchor() async throws {
        let entity = try #require(
            SessionStoreContainer.schema.entities.first { $0.name == "StoredHost" }
        )
        let pinLike = entity.properties.map(\.name).filter {
            $0.localizedCaseInsensitiveContains("spki")
                || $0.localizedCaseInsensitiveContains("pin")
                || $0.localizedCaseInsensitiveContains("cert")
        }
        #expect(
            pinLike.isEmpty,
            """
            \(pinLike) looks like a pinned certificate stored in the host table. \
            The pin's owner is HostCredentialStore (Keychain, keyed by host id). \
            A copy here becomes a second trust anchor, and the two will drift.
            """
        )

        // The domain type still carries a pin — this package simply does not
        // write it. Saving one must therefore drop it, not persist it quietly
        // under some other column.
        let repository = try Self.repository()
        try await repository.save(
            Self.host(id: Self.idA, name: "Studio")
                .paired(pinning: SPKIHash(base64: "cGlubmVkLXNwa2k="))
        )

        let loaded = try #require(try await repository.host(id: Self.idA))
        #expect(loaded.pinnedSPKI == nil)
        #expect(loaded.pairingState == .paired)
    }

    // MARK: - On disk

    /// A machine paired before the app was killed is still there afterwards.
    ///
    /// The in-memory container cannot answer this: it is the same object for the
    /// whole test, so a `save` that never reached a file would still read back.
    /// This one opens a second container over the same file.
    @Test("a paired machine is still paired after the store is closed and reopened")
    func pairedHostSurvivesAColdStart() async throws {
        let url = try Self.makeStoreURL()
        defer { Self.removeStore(at: url) }

        try await {
            let repository = SwiftDataSessionRepository(container: try SessionStoreContainer.onDisk(at: url))
            try await repository.save(
                Self.host(id: Self.idA, name: "Studio", bridgeID: "bridge-7")
                    .paired(pinning: SPKIHash(base64: "c3BraQ=="))
            )
        }()

        let reopened = SwiftDataSessionRepository(container: try SessionStoreContainer.onDisk(at: url))
        let loaded = try #require(try await reopened.host(id: Self.idA))
        #expect(loaded.displayName == "Studio")
        #expect(loaded.bridgeID == "bridge-7")
        // Paired across a cold start — but not connectable from this layer
        // alone, because the pin it needs is in the Keychain. See
        // `restoredHostKeepsPairingStateWithoutThePin`.
        #expect(loaded.pairingState == .paired)
        #expect(loaded.canConnect == false)
    }

    /// Adding the host table must not cost an existing user their history.
    ///
    /// Written against the *old* schema first — the three entities that shipped
    /// before `StoredHost` existed — then reopened with the new one. A test that
    /// only checked "the new container builds" would pass even if every
    /// conversation on disk had been discarded, because a fresh store builds
    /// fine.
    ///
    /// This is what forces every stored property on `StoredHost` to carry a
    /// default: without them the migration is not lightweight, and this test is
    /// where that stops being a style preference.
    @Test("opening an old store with the new schema keeps every session, message and backend")
    func addingTheHostTableLosesNothing() async throws {
        let url = try Self.makeStoreURL()
        defer { Self.removeStore(at: url) }

        let sessionID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        try await {
            let old = Schema([StoredSession.self, StoredMessage.self, StoredBackend.self])
            let container = try ModelContainer(
                for: old,
                configurations: [ModelConfiguration(schema: old, url: url, cloudKitDatabase: .none)]
            )
            let repository = SwiftDataSessionRepository(container: container)
            try await repository.create(
                Session(
                    id: sessionID,
                    hostID: Self.idA,
                    backendID: "claude",
                    title: "Written before hosts existed",
                    messages: [
                        // Distinct timestamps on purpose. `StoredMapping.session`
                        // orders a transcript by `createdAt`, so two messages
                        // sharing one leaves the order down to whatever the fetch
                        // happened to return — this test failed intermittently
                        // with both stamped `t0`, and the flake was mine, not the
                        // store's.
                        Message(id: UUID(), role: .user, text: "first", createdAt: t0),
                        Message(id: UUID(), role: .assistant, text: "second", createdAt: t0.addingTimeInterval(1)),
                    ],
                    createdAt: t0,
                    updatedAt: t0
                )
            )
            try await repository.save(
                AgentBackend(id: "claude", displayName: "Studio Claude"),
                on: Self.idA
            )
        }()

        let migrated = SwiftDataSessionRepository(container: try SessionStoreContainer.onDisk(at: url))

        let session = try #require(try await migrated.session(id: sessionID))
        #expect(session.title == "Written before hosts existed")
        #expect(session.messages.map(\.text) == ["first", "second"])
        #expect(try await migrated.storedMessageCount() == 2)
        #expect(try await migrated.backends(ofHost: Self.idA).map(\.displayName) == ["Studio Claude"])
        // The new table is empty rather than absent: an old store has no hosts,
        // and asking for them is a legitimate question with the answer "none".
        #expect(try await migrated.hosts().isEmpty)
    }

    // MARK: - Store files

    private static func makeStoreURL() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "localis-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "store.sqlite")
    }

    private static func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

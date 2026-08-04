import Foundation
import Testing

@testable import Localis

import LocalisModels
import SessionStore
import TransportKit

/// Cold start: the machines the user already added come back.
///
/// **Why this suite is in the app target and not in SessionStore.** `StoredHost`
/// has its own tests, and they prove the table round-trips. Not one of them can
/// fail if the app never calls `hosts()` — which is exactly the state B-1 found
/// the project in: `Session.hostID` was a foreign key pointing at a table that
/// did not exist, and after the table existed, nothing wrote to it or read from
/// it. A store that persists correctly and an app that never asks are
/// indistinguishable from the user's side: both show an empty list forever.
///
/// So these tests assert the *app's* behaviour across a simulated relaunch: a
/// second model, built fresh over the same container, the way a cold start
/// builds one.
@Suite("Host recovery across a cold start")
struct HostRecoveryTests {
    /// Two repositories over one container — the closest thing to a relaunch
    /// that a test can do without a simulator.
    ///
    /// Deliberately *not* one repository reused: an in-process cache would make
    /// the second read succeed without touching disk, and this suite would then
    /// be green on an app that persists nothing. The container is the only thing
    /// shared, which is the only thing a relaunch shares.
    private static func relaunching(
        _ write: (SwiftDataSessionRepository) async throws -> Void
    ) async throws -> SwiftDataSessionRepository {
        let container = try SessionStoreContainer.inMemory()
        try await write(SwiftDataSessionRepository(container: container))
        return SwiftDataSessionRepository(container: container)
    }

    private static func mac(
        named name: String = "Tian's MacBook Pro",
        at host: String = "mac.local"
    ) -> LocalisHost {
        LocalisHost(
            id: HostID(),
            displayName: name,
            endpoint: HostEndpoint(host: host, port: 8443),
            bridgeID: "bridge-abc"
        )
    }

    /// A Keychain with nothing in it.
    ///
    /// Passed explicitly at every construction site in this suite rather than
    /// relying on the default. The default is the **real** Keychain, and a test
    /// that quietly reaches it fails differently in CI than on a developer's
    /// machine — the exact failure mode that makes people stop trusting red.
    ///
    /// Empty is also the right fixture here: this suite is about what survives
    /// the trip to disk, and the answer is "the record, never the pin". The
    /// join itself is `HostAssemblyTests`.
    private struct NoPins: PinReading {
        func pin(for host: HostID) throws -> SPKIHash? { nil }
    }

    private static func model(_ repository: any SessionRepository) async -> HostListModel {
        await HostListModel(repository: repository, credentials: NoPins())
    }

    @Test("a host added before the app quit is on screen after it relaunches")
    func hostSurvivesRelaunch() async throws {
        let saved = Self.mac()
        let repository = try await Self.relaunching { try await $0.save(saved) }

        let model = await Self.model(repository)
        await model.load()

        // The assertion the whole milestone is about. Anything weaker — "the
        // store has a row" — is already covered in SessionStore and stays green
        // while this screen is empty.
        #expect(await model.rows.map(\.title) == ["Tian's MacBook Pro"])
        #expect(await model.loadError == nil)
    }

    @Test("a machine the user typed in is adopted, stored, and comes back")
    func manualEntryIsAdoptedAndPersisted() async throws {
        // The full B-1 path in one test: typed address → `DiscoveredHost` →
        // `LocalisHost(adopting:)` → store → relaunch → screen. Each of those
        // four joins had a green test on either side of it and nothing running
        // through.
        let container = try SessionStoreContainer.inMemory()
        let first = await Self.model(SwiftDataSessionRepository(container: container))

        try await first.addHost(typedAddress: "https://studio.local:9000")

        let second = await Self.model(SwiftDataSessionRepository(container: container))
        await second.load()

        #expect(await second.rows.map(\.title) == ["studio.local:9000"])
    }

    @Test("an unpaired machine comes back unpaired, not quietly promoted")
    func recoveredHostKeepsItsPairingState() async throws {
        let repository = try await Self.relaunching { try await $0.save(Self.mac()) }

        let model = await Self.model(repository)
        await model.load()

        // If persistence lost `pairingState` and the default filled in
        // `.paired`, the app would offer to connect to a machine it never
        // authenticated to — and the list would look completely normal.
        let row = try #require(await model.rows.first)
        #expect(row.isConnectable == false)
        #expect(row.status == "Not paired")
    }

    @Test("a paired machine comes back paired, and still not connectable on the store alone")
    func pairedHostSurvivesAsPairedButNotConnectable() async throws {
        // **This test used to assert the opposite**, and the store changing
        // under it is the point rather than an accident. `SessionStore` no
        // longer has a pin column at all: the Keychain is the only owner of a
        // trust anchor, so every host read back from disk has `pinnedSPKI ==
        // nil` and `canConnect == false` by construction.
        //
        // So the pair of facts worth pinning down is this one — the *state*
        // survives the trip to disk, and connectability does **not** come with
        // it. The old assertion (`isConnectable == true`) can no longer be true
        // for any stored host, and a test that demands it would be demanding
        // the second trust anchor back.
        //
        // What still needs saying: dropping `pairingState` on the way to disk
        // would leave a machine the user paired looking unpaired forever, and
        // no other test in this suite would notice.
        let paired = Self.mac().beginningPairing().paired(pinning: SPKIHash(base64: "AAA="))
        let repository = try await Self.relaunching { try await $0.save(paired) }

        let model = await Self.model(repository)
        await model.load()

        let row = try #require(await model.rows.first)
        #expect(row.status == "Paired")
        // Not an oversight and not a TODO. This suite injects an **empty**
        // Keychain (`NoPins`), so it is measuring the store's half alone, and
        // the store's half can never make a machine connectable. That the join
        // does make it connectable is `HostAssemblyTests`; keeping the two
        // apart is what lets this one fail for exactly one reason.
        #expect(row.isConnectable == false)
    }

    @Test("a paired machine that came back without its pin is not offered as connectable")
    func pairedWithoutPinIsNotConnectable() async throws {
        // **This test exists because a mutation survived**, and it has since
        // been overtaken by events in a way worth recording. Replacing
        // `host.canConnect` with `host.pairingState == .paired` changed no test
        // — every fixture was either paired *and* pinned or neither, so the two
        // expressions agreed everywhere they were exercised.
        //
        // When it was written, the paired-but-unpinned state was a prediction:
        // "exactly what a store that persists `pairingState` but not the pin
        // hands back on every cold start". `SessionStore` has since dropped its
        // pin column, so this is no longer the edge case — it is the **only**
        // case. Every host the app reads from disk arrives in this shape.
        //
        // The fixture is built by hand rather than through `paired(pinning:)`
        // on purpose: it must keep describing a host with no pin even if the
        // store's behaviour changes again.
        //
        // A row that offered to connect here would be offering an unpinned
        // connection to a machine we cannot authenticate — pinning switched off
        // silently, with the list looking entirely normal (FR-028,
        // constitution V).
        let pairedButUnpinned = LocalisHost(
            id: HostID(),
            displayName: "Studio",
            endpoint: HostEndpoint(host: "studio.local", port: 8443),
            bridgeID: "bridge-abc",
            pinnedSPKI: nil,
            pairingState: .paired
        )
        let repository = try await Self.relaunching { try await $0.save(pairedButUnpinned) }

        let model = await Self.model(repository)
        await model.load()

        let row = try #require(await model.rows.first)
        #expect(row.isConnectable == false)
    }

    @Test("a store that cannot be read says so rather than showing no machines")
    func readFailureIsNamedNotEmpty() async throws {
        // "Nothing went wrong, you have no Macs" and "we could not read your
        // Macs" are different sentences, and an empty list tells the user the
        // first one. This is the sixth member of the defect family this project
        // keeps finding: nothing happening, dressed as everything being fine.
        let model = await Self.model(FailingRepository())
        await model.load()

        #expect(await model.loadError != nil)
        #expect(await model.rows.isEmpty)
    }

    @Test("a typed address that is not usable is refused before anything is stored")
    func invalidAddressStoresNothing() async throws {
        let container = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: container)
        let model = await Self.model(repository)

        // Plaintext, deliberately. `EndpointValidator` is HTTPS-only, and a
        // manual field is where a plaintext fallback would reappear.
        await #expect(throws: LocalisError.invalidInput(field: "endpoint")) {
            try await model.addHost(typedAddress: "http://studio.local:9000")
        }

        #expect(try await repository.hosts().isEmpty)
        #expect(await model.rows.isEmpty)
    }

    @Test("hosts are listed in a stable order rather than whatever the fetch returned")
    func recoveredHostsAreOrdered() async throws {
        // Two machines saved in one order and expected in another. Without this
        // the list can reshuffle between launches, which reads as machines
        // appearing and disappearing.
        let repository = try await Self.relaunching {
            try await $0.save(Self.mac(named: "Studio", at: "studio.local"))
            try await $0.save(Self.mac(named: "Air", at: "air.local"))
        }

        let model = await Self.model(repository)
        await model.load()

        #expect(await model.rows.map(\.title) == ["Air", "Studio"])
    }
}

/// A repository whose reads fail.
///
/// Only `hosts()` is scripted; everything else traps, so a future test that
/// wandered onto another method would fail loudly rather than quietly asserting
/// against a fabricated empty answer.
private struct FailingRepository: SessionRepository {
    /// Deliberately **not** a `LocalisError`.
    ///
    /// SwiftData throws its own errors, and the model's job is to say something
    /// usable about one it has never seen. A fake that threw a `LocalisError`
    /// would exercise the branch that already has a `userMessage` to read and
    /// leave the fallback — the branch a real disk failure actually takes —
    /// untested.
    private struct Unreadable: Error {}

    func hosts() async throws -> [LocalisHost] { throw Unreadable() }

    func allSessions() async throws -> [Session] { throw Unreadable() }
    func sessions(matching query: SessionQuery) async throws -> [Session] { throw Unreadable() }
    func session(id: UUID) async throws -> Session? { throw Unreadable() }
    func create(_ session: Session) async throws { throw Unreadable() }
    func save(_ session: Session) async throws { throw Unreadable() }
    func delete(id: UUID) async throws { throw Unreadable() }
    func backends(ofHost hostID: HostID) async throws -> [AgentBackend] { throw Unreadable() }
    func save(_ backend: AgentBackend, on hostID: HostID) async throws { throw Unreadable() }
    func deleteBackend(id: String, on hostID: HostID) async throws { throw Unreadable() }
    func host(id: HostID) async throws -> LocalisHost? { throw Unreadable() }
    func save(_ host: LocalisHost) async throws { throw Unreadable() }
    func deleteHost(id: HostID) async throws { throw Unreadable() }
}

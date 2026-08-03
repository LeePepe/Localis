import Foundation
import Testing

@testable import Localis

import LocalisModels
import SessionStore
import TransportKit

/// The join between a stored machine and its Keychain pin.
///
/// **Why this suite had to exist the moment `SessionStore` dropped its pin
/// column.** Before that, one test asserted "a paired machine comes back
/// connectable" — and it was wrong, because it believed the store alone could
/// produce a connectable host. Removing it was right, but it left a real
/// proposition with nothing claiming it:
///
///   *once the two halves are joined, a genuinely paired machine **is**
///   connectable.*
///
/// That proposition cannot be tested in `SessionStore` (it can only assert the
/// pin is always nil) and it cannot be tested in `TransportKit` (which knows
/// nothing about stored records). It belongs here, with the join, and a broken
/// join is the kind of defect that shows up as "the machine I paired won't
/// connect" rather than as a crash — silent, and easy to blame on the network.
@Suite("Joining a stored machine to its pin")
struct HostAssemblyTests {
    /// A Keychain stand-in.
    ///
    /// Deliberately a fake rather than the real `HostCredentialStore`: a real
    /// Keychain fails differently in CI than on a developer's machine, and a
    /// suite that goes red for reasons unrelated to its subject teaches people
    /// to ignore it.
    private struct FakeCredentials: PinReading {
        var pins: [HostID: SPKIHash] = [:]
        var failure: (any Error)?

        func pin(for host: HostID) throws -> SPKIHash? {
            if let failure { throw failure }
            return pins[host]
        }
    }

    private struct Locked: Error {}

    private static func paired(_ name: String = "Studio") -> LocalisHost {
        LocalisHost(
            id: HostID(),
            displayName: name,
            endpoint: HostEndpoint(host: "studio.local", port: 8443),
            bridgeID: "bridge-studio",
            pinnedSPKI: nil,
            pairingState: .paired
        )
    }

    @Test("a paired machine with its pin is connectable once the halves are joined")
    func pairedHostWithPinIsConnectable() async throws {
        // **The proposition this whole type exists for.** Every other test in
        // the project asserts one half: the store round-trips the record, the
        // Keychain round-trips the pin. Neither can fail if the join is missing
        // — and with the join missing, no machine in the app can ever connect.
        let host = Self.paired()
        let repository = InMemorySessionRepository()
        try await repository.save(host)

        let assembly = HostAssembly(
            repository: repository,
            credentials: FakeCredentials(pins: [host.id: SPKIHash(base64: "AAA=")])
        )

        let joined = try #require(try await assembly.host(id: host.id))
        #expect(joined.canConnect)
        #expect(joined.pinnedSPKI == SPKIHash(base64: "AAA="))
    }

    @Test("the store alone still cannot produce a connectable machine")
    func storeWithoutTheJoinIsNotConnectable() async throws {
        // The control for the test above. If this one ever goes red, the pin
        // has come back into the store — a second trust anchor — and the join
        // has stopped being the only way to get one.
        let host = Self.paired()
        let repository = InMemorySessionRepository()
        try await repository.save(host)

        let readBack = try #require(try await repository.host(id: host.id))
        #expect(readBack.pinnedSPKI == nil)
        #expect(readBack.canConnect == false)
    }

    @Test("a paired machine whose pin is missing stays unconnectable rather than failing")
    func pairedHostWithoutPinIsNotConnectable() async throws {
        // A restored device backup carries the store but not the Keychain.
        // That user must see their machine and be told to pair it again — an
        // error here would hide the machine entirely, and a `canConnect == true`
        // would offer an unpinned connection.
        let host = Self.paired()
        let repository = InMemorySessionRepository()
        try await repository.save(host)

        let assembly = HostAssembly(repository: repository, credentials: FakeCredentials())

        let joined = try #require(try await assembly.host(id: host.id))
        #expect(joined.canConnect == false)
        #expect(joined.pairingState == .paired)
    }

    @Test("a Keychain failure is reported, not turned into an unpaired machine")
    func keychainFailurePropagates() async throws {
        // Swallowing this would turn "the Keychain is locked" into "this
        // machine is not paired", which sends the user to re-pair — and
        // re-pairing overwrites the very pin we failed to read.
        let host = Self.paired()
        let repository = InMemorySessionRepository()
        try await repository.save(host)

        let assembly = HostAssembly(
            repository: repository,
            credentials: FakeCredentials(failure: Locked())
        )

        await #expect(throws: Locked.self) {
            _ = try await assembly.host(id: host.id)
        }
    }

    @Test("an unpaired machine is never given a pin, even if one is lying around")
    func unpairedHostIsNeverPinned() async throws {
        // Residue from an unpairing that did not finish. Attaching it would
        // resurrect a trust anchor the user explicitly revoked (FR-027), and
        // the list would look entirely normal.
        let revoked = LocalisHost(
            id: HostID(),
            displayName: "Old Mac",
            endpoint: HostEndpoint(host: "old.local", port: 8443),
            bridgeID: "bridge-old",
            pinnedSPKI: nil,
            pairingState: .revoked
        )
        let repository = InMemorySessionRepository()
        try await repository.save(revoked)

        let assembly = HostAssembly(
            repository: repository,
            credentials: FakeCredentials(pins: [revoked.id: SPKIHash(base64: "AAA=")])
        )

        let joined = try #require(try await assembly.host(id: revoked.id))
        #expect(joined.pinnedSPKI == nil)
        #expect(joined.canConnect == false)
    }

    @Test("every machine in the list is joined, not just the first")
    func allHostsAreJoined() async throws {
        // A join applied to `host(id:)` but not to `hosts()` would leave the
        // list showing nothing connectable while the detail screen worked —
        // which reads as a UI bug and gets investigated in the wrong place.
        let first = Self.paired("Studio")
        let second = Self.paired("Air")
        let repository = InMemorySessionRepository()
        try await repository.save(first)
        try await repository.save(second)

        let assembly = HostAssembly(
            repository: repository,
            credentials: FakeCredentials(pins: [
                first.id: SPKIHash(base64: "AAA="),
                second.id: SPKIHash(base64: "BBB=")
            ])
        )

        let joined = try await assembly.hosts()

        // Computed outside the macro deliberately. `allSatisfy` is `rethrows`,
        // and `#expect` expands its argument into a context where the compiler
        // then demands a `try` — the error lands in generated code and points
        // at a line that reads fine.
        //
        // Named rather than counted, too: `allSatisfy` over an empty array is
        // vacuously true, so a `hosts()` that returned nothing would satisfy it.
        // The count assertion below covers that today, but a pair of assertions
        // that must be read together to be sound is one edit away from unsound.
        let connectable = Set(joined.filter(\.canConnect).map(\.displayName))
        #expect(connectable == ["Studio", "Air"])
    }

    @Test("a machine that is not on file is nil, not an invented one")
    func unknownHostIsNil() async throws {
        let assembly = HostAssembly(
            repository: InMemorySessionRepository(),
            credentials: FakeCredentials()
        )

        #expect(try await assembly.host(id: HostID()) == nil)
    }
}

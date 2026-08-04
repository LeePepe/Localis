import Foundation
import Testing

@testable import BridgeCore

/// Revocation, and the difference between "revoked" and "never heard of it".
///
/// **The distinction is not cosmetic and the client cannot verify it.** Contract
/// §6 gives the two cases different codes because the phone acts on them
/// differently: `token_revoked` makes it erase this host's Keychain entry and
/// tell the user to pair again; `invalid_token` makes it abandon the request and
/// nothing more. Both arrive as a 401 with a JSON body, so on the wire they are
/// indistinguishable — the phone can only believe what the bridge says. Every
/// assertion in this suite is therefore load-bearing in a place no client-side
/// test can reach.
@Suite("TokenStore — revocation")
struct TokenStoreRevocationTests {
    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localis-revoke-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static let grant = TokenStore.Grant(deviceName: "Test Phone", deviceID: "dev-1")

    /// **The red-green pair, in one test.**
    ///
    /// The first assertion is the half that is easy to leave out: before the
    /// revoke, this exact token must *work*. Without it, the second assertion
    /// proves nothing — a token can be rejected for a dozen reasons that have
    /// nothing to do with revocation, and a store that rejected everything would
    /// pass a test that only checked the "after".
    @Test("a token works, is revoked, and is then reported as revoked")
    func revocationChangesTheAnswer() async throws {
        let store = TokenStore()
        await store.issue(token: "tok-abc", to: Self.grant)

        #expect(
            await store.lookup(token: "tok-abc") == .granted(Self.grant),
            "the token did not work even before revocation — the test below would prove nothing"
        )

        await store.revoke(deviceID: Self.grant.deviceID)

        #expect(await store.lookup(token: "tok-abc") == .revoked)
    }

    /// **`token_revoked` must not widen to "anything I do not recognise".**
    ///
    /// This is the assertion that stops the phone from erasing a working pairing
    /// because a header was corrupted in transit. A store that returned
    /// `.revoked` for every unknown token would pass the test above.
    @Test("a token that was never issued is unknown, not revoked", arguments: [
        "tok-never-issued",
        "",
        "tok-ab",
        "tok-abcd",
    ])
    func unknownTokenIsNotRevoked(token: String) async throws {
        let store = TokenStore()
        await store.issue(token: "tok-abc", to: Self.grant)
        await store.revoke(deviceID: Self.grant.deviceID)

        #expect(await store.lookup(token: token) == .unknown)
    }

    /// Revoking one device must not touch another's credential — the multi-host
    /// case from Amendment A, where the user has several phones on one Mac.
    @Test("revoking one device leaves another device working")
    func revocationIsScopedToOneDevice() async throws {
        let other = TokenStore.Grant(deviceName: "Other Phone", deviceID: "dev-2")

        let store = TokenStore()
        await store.issue(token: "tok-1", to: Self.grant)
        await store.issue(token: "tok-2", to: other)

        await store.revoke(deviceID: Self.grant.deviceID)

        #expect(await store.lookup(token: "tok-1") == .revoked)
        #expect(await store.lookup(token: "tok-2") == .granted(other), "revoking one device unpaired another")
    }

    /// The verdict has to survive a restart, or the phone would be told
    /// `invalid_token` after a reboot and would keep the dead credential.
    @Test("a revoked token is still reported as revoked after a restart")
    func revocationVerdictSurvivesRestart() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try TokenStore(directory: directory)
        await before.issue(token: "tok-abc", to: Self.grant)
        await before.revoke(deviceID: Self.grant.deviceID)

        let after = try TokenStore(directory: directory)
        #expect(await after.lookup(token: "tok-abc") == .revoked)
    }

    /// **The revoked token must not be recoverable from the file.**
    ///
    /// The tombstone outlives the credential, so storing the plaintext would
    /// leave the one token the user asked to make useless sitting on disk for as
    /// long as the bridge exists (constitution §I).
    @Test("the revoked token does not appear in the grant file")
    func revokedTokenIsNotStoredInClear() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try TokenStore(directory: directory)
        await store.issue(token: "tok-abc", to: Self.grant)
        await store.revoke(deviceID: Self.grant.deviceID)

        let contents = try String(
            contentsOf: directory.appendingPathComponent(TokenStore.fileName),
            encoding: .utf8
        )
        #expect(!contents.contains("tok-abc"), "the revoked token is still on disk in the clear")
    }

    /// Re-pairing after a revoke has to produce a *working* device again. A
    /// tombstone that outranked a live grant would make the device permanently
    /// unpairable, and the only symptom would be a phone that pairs
    /// successfully and then gets 401 on its first real request.
    @Test("a device that re-pairs after being revoked works again")
    func rePairingAfterRevocationWorks() async throws {
        let store = TokenStore()
        await store.issue(token: "tok-old", to: Self.grant)
        await store.revoke(deviceID: Self.grant.deviceID)
        await store.issue(token: "tok-new", to: Self.grant)

        #expect(await store.lookup(token: "tok-new") == .granted(Self.grant))
        #expect(await store.lookup(token: "tok-old") == .revoked, "the old token stopped being reported as revoked")
    }

    /// Revoking an id nothing matches returns nothing, so the caller can report
    /// it rather than claiming a device was removed.
    @Test("revoking an unknown device id revokes nothing")
    func revokingUnknownDeviceReportsNothing() async throws {
        let store = TokenStore()
        await store.issue(token: "tok-abc", to: Self.grant)

        #expect(await store.revoke(deviceID: "dev-not-here").isEmpty)
        #expect(await store.lookup(token: "tok-abc") == .granted(Self.grant), "an unmatched revoke removed a grant")
    }

    /// `revoke` returns the devices whose pairing ended, so the command can name
    /// them. Printing "done" instead would leave an operator unable to tell they
    /// revoked the wrong device.
    @Test("revoke reports which device it ended")
    func revokeReportsTheDevice() async throws {
        let store = TokenStore()
        await store.issue(token: "tok-abc", to: Self.grant)

        #expect(await store.revoke(deviceID: Self.grant.deviceID) == [Self.grant])
    }

    /// The listing exists so an operator can find an id; it must never carry the
    /// token, which would put a live credential on a terminal.
    @Test("the device listing carries no token")
    func listingCarriesNoToken() async throws {
        let store = TokenStore()
        await store.issue(token: "tok-abc", to: Self.grant)

        let devices = await store.pairedDevices
        #expect(devices == [Self.grant])
    }

    /// **The migration test, and it guards a failure that stops the bridge from
    /// starting at all.**
    ///
    /// The pre-tombstone file was a bare JSON array. `init(directory:)` throws
    /// on anything it cannot decode and never resets silently — so a version
    /// that only understood the new shape would not degrade gracefully on an
    /// existing Mac, it would refuse to boot, and the operator's only clue would
    /// be "the pairing record is damaged". Every machine that had ever paired
    /// would hit this on upgrade.
    @Test("a pre-tombstone grant file still loads, and its tokens still work")
    func legacyGrantFileStillLoads() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The old format, written by hand rather than by the current encoder —
        // a fixture produced by today's code could not catch today's code
        // changing shape.
        let legacy = """
        [{"token":"tok-legacy","grant":{"deviceName":"Old Phone","deviceID":"dev-old"}}]
        """
        try legacy.write(
            to: directory.appendingPathComponent(TokenStore.fileName),
            atomically: true,
            encoding: .utf8
        )

        let store = try TokenStore(directory: directory)
        #expect(
            await store.lookup(token: "tok-legacy")
                == .granted(TokenStore.Grant(deviceName: "Old Phone", deviceID: "dev-old")),
            "upgrading unpaired every device that was already paired"
        )
    }

    /// And a legacy file must still be revocable — the migration is not complete
    /// if the upgraded bridge can read the old grants but cannot end them.
    @Test("a device from a pre-tombstone file can be revoked")
    func legacyGrantCanBeRevoked() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacy = """
        [{"token":"tok-legacy","grant":{"deviceName":"Old Phone","deviceID":"dev-old"}}]
        """
        try legacy.write(
            to: directory.appendingPathComponent(TokenStore.fileName),
            atomically: true,
            encoding: .utf8
        )

        let store = try TokenStore(directory: directory)
        #expect(await !store.revoke(deviceID: "dev-old").isEmpty)

        let after = try TokenStore(directory: directory)
        #expect(await after.lookup(token: "tok-legacy") == .revoked)
    }

    /// Garbage is still an error. The legacy path must not have turned the
    /// corrupt-file check into "try the old shape, and shrug if that fails too"
    /// — `init` throwing on an unreadable file is what stops a damaged file from
    /// silently unpairing the machine.
    @Test("an unreadable file is still an error after the format change", arguments: [
        "this is not json",
        "{\"unexpected\": \"shape\"}",
        "[{\"token\": \"tok\"}]",
        "{\"grants\": \"not an array\", \"revoked\": [], \"salt\": \"s\"}",
    ])
    func corruptFileIsStillAnError(contents: String) async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try contents.write(
            to: directory.appendingPathComponent(TokenStore.fileName),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: TokenStore.Failure.self) {
            _ = try TokenStore(directory: directory)
        }
    }

    /// The salt must be stable across restarts. Regenerating it would make every
    /// existing tombstone unmatchable, and each already-revoked token would
    /// quietly fall back to `invalid_token` — the phone would then keep a
    /// credential it should have erased, with no error anywhere.
    ///
    /// Asserted through behaviour rather than by reading the salt: the value is
    /// private, and the property that matters is that the verdict survives.
    @Test("the revocation verdict survives two restarts, not just one")
    func saltIsStableAcrossRestarts() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try TokenStore(directory: directory)
        await first.issue(token: "tok-abc", to: Self.grant)
        await first.revoke(deviceID: Self.grant.deviceID)

        // The second restart is the one that catches a salt regenerated on
        // load: the first reload would still hold the salt that was just
        // written, and only a further write-then-read exposes the drift.
        let second = try TokenStore(directory: directory)
        await second.issue(token: "tok-other", to: TokenStore.Grant(deviceName: "P2", deviceID: "dev-2"))

        let third = try TokenStore(directory: directory)
        #expect(await third.lookup(token: "tok-abc") == .revoked, "the revocation record stopped matching")
    }
}

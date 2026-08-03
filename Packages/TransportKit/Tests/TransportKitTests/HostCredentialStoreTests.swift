import Foundation
import LocalisModels
import Testing

@testable import TransportKit

/// Per-host credential storage (constitution I and V, FR-027, FR-028).
///
/// Two properties are under test, and both fail silently if broken:
/// **isolation** — no key, no query and no fallback reaches across hosts — and
/// **zero residue** — unpairing leaves nothing behind that a later bug could
/// resurrect.
///
/// These run against the real Keychain in a per-run service namespace, deleted
/// afterwards. A fake would test the fake: the accessibility class and the
/// query shape are the substance here, and only the real API has them.
@Suite("HostCredentialStore — per-host isolation", .serialized)
final class HostCredentialStoreTests {
    private let store: HostCredentialStore
    private let hostA = HostID()
    private let hostB = HostID()

    init() {
        // A unique service per run keeps concurrent runs and a developer's own
        // Keychain out of each other's way.
        store = HostCredentialStore(service: "dev.localis.tests.\(UUID().uuidString)")
    }

    deinit {
        store.removeAll()
    }

    // MARK: - Tokens

    @Test("a stored token comes back")
    func roundTripsToken() throws {
        try store.saveToken("token-a", for: hostA)

        #expect(try store.token(for: hostA) == "token-a")
    }

    @Test("an unknown host has no token")
    func unknownHostHasNoToken() throws {
        #expect(try store.token(for: HostID()) == nil)
    }

    @Test("saving twice replaces rather than duplicating")
    func saveReplaces() throws {
        try store.saveToken("first", for: hostA)
        try store.saveToken("second", for: hostA)

        // A duplicate entry is worse than a wrong one: the query returns
        // whichever the Keychain picks, so the app would authenticate with a
        // revoked token intermittently.
        #expect(try store.token(for: hostA) == "second")
    }

    /// The property Amendment A calls out: hosts share nothing.
    @Test("one host's token is never returned for another")
    func tokensAreIsolated() throws {
        try store.saveToken("token-a", for: hostA)
        try store.saveToken("token-b", for: hostB)

        #expect(try store.token(for: hostA) == "token-a")
        #expect(try store.token(for: hostB) == "token-b")
    }

    @Test("there is no host-less token to fall back on")
    func noSharedToken() throws {
        // The API takes a HostID everywhere, so a shared credential is not
        // merely absent — it is unrepresentable. This test states the intent
        // that keeps a convenience overload from being added later.
        try store.saveToken("token-a", for: hostA)

        #expect(try store.token(for: HostID()) == nil)
    }

    // MARK: - Pinned certificates

    @Test("a pinned SPKI round-trips")
    func roundTripsPin() throws {
        let pin = SPKIHash(base64: "LpkFZjT82OYMgRsm4c1ztqAmunU6kM7ZfmhokT3JqvI=")
        try store.savePin(pin, for: hostA)

        #expect(try store.pin(for: hostA) == pin)
    }

    @Test("pins are isolated per host")
    func pinsAreIsolated() throws {
        let pinA = SPKIHash(base64: "LpkFZjT82OYMgRsm4c1ztqAmunU6kM7ZfmhokT3JqvI=")
        let pinB = SPKIHash(base64: "jyomIJG/AM1mpiJm+xS39E9L/SNfb8bgcvP7ciaupXc=")
        try store.savePin(pinA, for: hostA)
        try store.savePin(pinB, for: hostB)

        #expect(try store.pin(for: hostA) == pinA)
        #expect(try store.pin(for: hostB) == pinB)
    }

    @Test("a token and a pin for the same host do not collide")
    func tokenAndPinCoexist() throws {
        let pin = SPKIHash(base64: "LpkFZjT82OYMgRsm4c1ztqAmunU6kM7ZfmhokT3JqvI=")
        try store.saveToken("token-a", for: hostA)
        try store.savePin(pin, for: hostA)

        #expect(try store.token(for: hostA) == "token-a")
        #expect(try store.pin(for: hostA) == pin)
    }

    // MARK: - Unpairing (FR-027)

    @Test("unpairing removes both the token and the pin")
    func unpairRemovesEverything() throws {
        try store.saveToken("token-a", for: hostA)
        try store.savePin(SPKIHash(base64: "LpkFZjT82OYMgRsm4c1ztqAmunU6kM7ZfmhokT3JqvI="), for: hostA)

        try store.removeCredentials(for: hostA)

        #expect(try store.token(for: hostA) == nil)
        #expect(try store.pin(for: hostA) == nil, "a surviving pin is a trust anchor for a host we unpaired")
    }

    @Test("unpairing one host leaves the others untouched")
    func unpairIsScopedToOneHost() throws {
        try store.saveToken("token-a", for: hostA)
        try store.saveToken("token-b", for: hostB)
        try store.savePin(SPKIHash(base64: "jyomIJG/AM1mpiJm+xS39E9L/SNfb8bgcvP7ciaupXc="), for: hostB)

        try store.removeCredentials(for: hostA)

        // Contract §1: revoking one host must not disturb another's credentials
        // or connection.
        #expect(try store.token(for: hostB) == "token-b")
        #expect(try store.pin(for: hostB) != nil)
    }

    @Test("unpairing a host with nothing stored is not an error")
    func unpairIsIdempotent() throws {
        // Called on a host that failed halfway through pairing, and called
        // twice by a retry. Neither should surface a failure.
        try store.removeCredentials(for: hostA)
        try store.removeCredentials(for: hostA)
    }

    @Test("re-pairing after unpairing stores a fresh token")
    func rePairAfterUnpair() throws {
        try store.saveToken("old", for: hostA)
        try store.removeCredentials(for: hostA)
        try store.saveToken("new", for: hostA)

        #expect(try store.token(for: hostA) == "new")
    }

    // MARK: - Storage policy (constitution I)

    @Test("credentials are stored for this device only, when unlocked")
    func accessibilityIsDeviceOnly() throws {
        // `WhenUnlockedThisDeviceOnly`: not readable while locked, and never
        // synced or carried into a backup. A token that rides an iCloud restore
        // onto a second device is access to the user's Mac they never granted
        // there — and it would work, silently.
        //
        // Asserted against the constant the store writes, because the readback
        // is unavailable on the test host: macOS's file-based Keychain omits
        // `kSecAttrAccessible` from query results, and the data-protection
        // Keychain that returns it rejects an unentitled SwiftPM test binary.
        // So this pins the intent, and the write path is one line away from it.
        #expect(HostCredentialStore.accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)

        // Not `.afterFirstUnlock` and not the syncing variants — each would
        // undo one half of the property above.
        #expect(HostCredentialStore.accessibility != kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(HostCredentialStore.accessibility != kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(HostCredentialStore.accessibility != kSecAttrAccessibleWhenUnlocked as String)

        // If a future OS starts reporting it back, hold the write path to the
        // same value rather than letting the check quietly lapse.
        try store.saveToken("token-a", for: hostA)
        if let reported = try store.storedAccessibility(for: hostA) {
            #expect(reported == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        }
    }

    @Test("the token is not recoverable from the store's description")
    func tokenNotInDescription() throws {
        try store.saveToken("super-secret-token", for: hostA)

        #expect(String(describing: store).contains("super-secret-token") == false)
    }
}

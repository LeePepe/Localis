import Foundation
import Testing

@testable import BridgeCore

/// Pairing grants, and the fact that they outlive the process.
///
/// `TokenStore` had no tests at all until a restart was observed to reject a
/// token the same bridge had issued minutes earlier. The failure was invisible
/// from inside the process — every unit of it worked — and only showed up when
/// something killed the bridge and came back.
///
/// **Why persistence is required, not a nicety.** spec.md:46 describes pairing
/// as a one-time act; spec.md:220 says a host change does not require
/// re-pairing; FR-027 makes *unpairing* an explicit user action with defined
/// consequences. A process exit is none of those things. If a restart revoked
/// every grant, FR-027 would describe an action no user would ever need to
/// take — rebooting the Mac would do it for them.
@Suite("TokenStore — persistence")
struct TokenStorePersistenceTests {
    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localis-token-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static let grant = TokenStore.Grant(deviceName: "Test Phone", deviceID: "dev-1")

    /// **The regression test.** This is the observed bug, in one assertion.
    ///
    /// A second store over the same directory stands in for a restart: the
    /// first process is gone, the state on disk is all that survives.
    @Test("a token issued before a restart still works after it")
    func grantSurvivesRestart() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try TokenStore(directory: directory)
        await before.issue(token: "tok-abc", to: Self.grant)

        let after = try TokenStore(directory: directory)
        let recovered = await after.grant(for: "tok-abc")

        #expect(recovered == Self.grant, "the bridge forgot a device it had paired — a restart silently unpairs everyone")
    }

    /// Persistence must not become a way to authenticate anything.
    ///
    /// Without this, a store that reloaded by returning the first grant it
    /// found would pass the test above while accepting every token on earth.
    @Test("a token that was never issued is still rejected after a restart")
    func unknownTokenStillRejected() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try TokenStore(directory: directory)
        await before.issue(token: "tok-abc", to: Self.grant)

        let after = try TokenStore(directory: directory)
        #expect(await after.grant(for: "tok-not-issued") == nil)
    }

    /// Revocation has to be as durable as issuance.
    ///
    /// A revoke that lived only in memory would come back on the next restart,
    /// which is the worst direction for this bug to point: the user explicitly
    /// removed a device (FR-027) and it silently returns.
    ///
    /// **⚠️ This test guards that `revoke` is implemented correctly. It does not
    /// guard that anything calls it — and nothing does.** `TokenStore.revoke`
    /// has no production caller: there is no unpair route on the bridge, no
    /// unpair request on iOS, and no unpair control in the UI. This test is the
    /// method's only caller anywhere.
    ///
    /// The warning is here, next to the test, rather than only on the method,
    /// because **the test is the misleading part**. A reader who finds a
    /// well-argued, genuinely-failing test naturally infers that the thing it
    /// covers is in use — the test's existence becomes the false signal. A
    /// green test in front of unreachable code is better camouflage than no
    /// test at all.
    ///
    /// Do not read this suite passing as "unpair works". It means "if unpair is
    /// ever wired up, this half of it will not lose the user's decision on
    /// restart".
    @Test("a revoked device does not come back after a restart")
    func revocationSurvivesRestart() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try TokenStore(directory: directory)
        await before.issue(token: "tok-abc", to: Self.grant)
        await before.revoke(deviceID: Self.grant.deviceID)

        let after = try TokenStore(directory: directory)
        #expect(await after.grant(for: "tok-abc") == nil, "a revoked pairing returned on restart")
    }

    /// Re-pairing replaces rather than accumulates, on disk too.
    @Test("re-pairing a device leaves exactly one live token across a restart")
    func rePairingReplacesOnDisk() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = try TokenStore(directory: directory)
        await before.issue(token: "tok-old", to: Self.grant)
        await before.issue(token: "tok-new", to: Self.grant)

        let after = try TokenStore(directory: directory)
        #expect(await after.grant(for: "tok-new") == Self.grant)
        #expect(await after.grant(for: "tok-old") == nil, "the superseded token still authenticates")
        #expect(await after.count == 1)
    }

    /// Tokens are credentials, so the file is owner-only — the same treatment
    /// `key.pem` gets, for the same reason (constitution §I).
    @Test("the grant file is not readable by anyone but the owner")
    func fileIsOwnerOnly() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try TokenStore(directory: directory)
        await store.issue(token: "tok-abc", to: Self.grant)

        let path = directory.appendingPathComponent(TokenStore.fileName).path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue

        #expect(permissions & 0o077 == 0, "grant file is mode \(String(permissions, radix: 8)) — a credential readable by other users")
    }

    /// A first run has no file, and that is not an error.
    @Test("an empty directory yields an empty store")
    func absentFileIsNotAnError() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await TokenStore(directory: directory).isEmpty)
    }

    /// **Corruption fails loudly — deliberately the opposite of `instance-id`.**
    ///
    /// A blank `instance-id` is regenerated, and that is right: it is advisory,
    /// and regenerating it only falls back to SPKI matching. A grant file is
    /// not advisory. Silently replacing it with an empty one revokes every
    /// pairing on the machine, and the user sees only that their phone stopped
    /// working — with no event to point at and nothing they did to cause it.
    ///
    /// So an unreadable file is a startup error the operator can read, not a
    /// clean slate.
    @Test("an unreadable grant file is an error, not a silent reset", arguments: [
        "this is not json",
        "{\"unexpected\": \"shape\"}",
        "[{\"token\": \"tok\"}]",
    ])
    func corruptFileIsAnError(contents: String) async throws {
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

    /// The in-memory store stays available for tests and for a bridge told not
    /// to persist — but it must not quietly write to the current directory.
    @Test("an ephemeral store writes nothing")
    func ephemeralStoreWritesNothing() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TokenStore()
        await store.issue(token: "tok-abc", to: Self.grant)

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
        #expect(await store.grant(for: "tok-abc") == Self.grant)
    }
}

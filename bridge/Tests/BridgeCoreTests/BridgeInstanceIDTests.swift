import Foundation
import Testing

@testable import BridgeCore

/// The bridge's stable instance id — Bonjour TXT `hid=`, and `bridge_id` in the
/// pairing response (contract §0 [A]).
@Suite("BridgeInstanceID")
struct BridgeInstanceIDTests {
    /// The whole point of the field: it outlives the process.
    ///
    /// An id regenerated per launch would make a paired Mac look like a new
    /// machine after every restart, which is the exact situation `hid` was added
    /// to prevent.
    @Test("the same directory yields the same id across loads")
    func stableAcrossLoads() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try BridgeInstanceID.loadOrCreate(in: directory)
        let second = try BridgeInstanceID.loadOrCreate(in: directory)

        #expect(first == second)
    }

    /// Two installs are two machines.
    ///
    /// If this collided, the client's rule 1 would merge them — one Mac would
    /// inherit the other's endpoint and sessions.
    @Test("separate installs get separate ids")
    func distinctPerInstall() throws {
        let a = try Self.temporaryDirectory()
        let b = try Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        #expect(try BridgeInstanceID.loadOrCreate(in: a) != BridgeInstanceID.loadOrCreate(in: b))
    }

    /// **The regression test.**
    ///
    /// This bridge shipped with `bridge_id` set to the SPKI pin. That reads as
    /// harmless — both identify the machine — but it makes the contract's clone
    /// rule unreachable: §0 [A] says `hid` equal with **SPKI different** MUST be
    /// treated as a different host, and if `hid` *is* the SPKI, the two can
    /// never disagree. A safety rule that cannot fire is not a safety rule.
    ///
    /// It also empties the amendment of content: rule 1 ("hid matches and SPKI
    /// matches") degenerates into rule 2 ("SPKI matches"), the fallback for
    /// bridges that send no `hid` at all.
    ///
    /// So the assertion is not cosmetic. The id has to be *independent state* —
    /// derived from nothing the certificate knows.
    @Test("the id is not derived from the TLS key")
    func independentOfTheCertificate() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let identity = try BridgeIdentity.loadOrCreate(in: directory)
        let instanceID = try BridgeInstanceID.loadOrCreate(in: directory)

        #expect(instanceID != identity.spkiPin, "bridge_id is the SPKI pin — the clone rule can never fire")
    }

    /// Regenerating a new key must not disturb the instance id.
    ///
    /// The two are stored side by side, and the failure this rules out is a
    /// loader that rebuilds one while touching the other.
    @Test("the id survives a new TLS identity in the same directory")
    func survivesKeyRotation() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try BridgeIdentity.loadOrCreate(in: directory)
        let before = try BridgeInstanceID.loadOrCreate(in: directory)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("cert.pem"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("key.pem"))
        let rotated = try BridgeIdentity.loadOrCreate(in: directory)
        let after = try BridgeInstanceID.loadOrCreate(in: directory)

        #expect(after == before)
        #expect(after != rotated.spkiPin)
    }

    /// An unusable stored id is replaced rather than served.
    ///
    /// Unlike the private key — where a corrupt file is a hard error, because
    /// overwriting it revokes every pairing — `hid` is optional and carries no
    /// authority, so the client simply falls back to SPKI matching (rule 2).
    /// Refusing to start over an advisory field would be the worse failure.
    @Test("a blank stored id is regenerated", arguments: ["", "   ", "\n"])
    func blankIsRegenerated(stored: String) throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try stored.write(to: directory.appendingPathComponent("instance-id"), atomically: true, encoding: .utf8)

        let identifier = try BridgeInstanceID.loadOrCreate(in: directory)
        #expect(!identifier.isEmpty)
    }

    /// It goes into a Bonjour TXT value and is compared as text on the client.
    ///
    /// A stray newline or space would be advertised verbatim; iOS trims before
    /// comparing, so it would survive there — but it would still be wrong on the
    /// wire, and the next reader is not obliged to trim.
    @Test("the id is a single clean token")
    func isCleanForTXT() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let identifier = try BridgeInstanceID.loadOrCreate(in: directory)

        let isHex = identifier.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
        #expect(isHex, "not a clean lowercase hex token: \(identifier)")
        #expect(identifier.count >= 32, "too short to be collision-free: \(identifier.count) chars")
    }

    private static func temporaryDirectory() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localis-instance-\(UUID().uuidString)", isDirectory: true)
    }
}

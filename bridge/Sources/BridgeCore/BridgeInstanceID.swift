import Foundation

/// The bridge's stable instance id — Bonjour TXT `hid=`, and the optional
/// `bridge_id` in the pairing response (contract §0 [A]).
///
/// **Deliberately independent of the TLS key.** It is tempting to reuse the SPKI
/// pin here: both identify this Mac, and one fewer file on disk looks like a
/// simplification. It is not. §0 [A] requires the client to treat "same `hid`,
/// different SPKI" as a *different* machine — the rule that stops a copied
/// configuration directory from impersonating the Mac it was copied from. If
/// `hid` were the SPKI, those two values could never disagree, so that rule
/// could never fire, and the amendment would collapse into the SPKI-only
/// fallback it was written to improve on.
///
/// **It is not an identity authority.** It relocates a machine whose
/// certificate already matches. Nothing here is secret and nothing here is
/// verified — the pin is the trust anchor, this is a hint that survives a DHCP
/// renewal.
///
/// Not derived from the hostname either: the contract says so explicitly, and
/// the reason is that users rename their Macs.
public enum BridgeInstanceID {
    /// Loads the id stored in `directory`, generating and persisting one if
    /// there is none.
    ///
    /// **A stored value that is unusable is replaced, not fatal.** This is the
    /// opposite of ``BridgeIdentity``'s handling of a corrupt key, and the
    /// asymmetry is intended: overwriting a private key silently revokes every
    /// pairing, whereas `hid` is optional and carries no authority — a client
    /// that receives a new one simply falls back to SPKI matching (rule 2) and
    /// re-learns it. Refusing to start over an advisory field would be the more
    /// damaging failure.
    public static func loadOrCreate(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(fileName)

        if let stored = try? String(contentsOf: url, encoding: .utf8),
           case let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }

        let identifier = generate()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try identifier.write(to: url, atomically: true, encoding: .utf8)

        return identifier
    }

    /// A fresh id: 16 random bytes as lowercase hex.
    ///
    /// Random rather than something meaningful. Anything derived from the
    /// machine — hostname, hardware serial, the certificate — either changes
    /// when it should not or is reproducible by whoever copied the disk.
    ///
    /// Lowercase hex with no separators because it travels in a Bonjour TXT
    /// value and is compared as text on the other side; a value needing
    /// normalisation before comparison is one that will eventually be compared
    /// without it.
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Stored beside `cert.pem` and `key.pem`, in the same owner-only
    /// directory. Not inside either of them: the id has to survive a key
    /// rotation, which is the one moment its value matters most.
    private static let fileName = "instance-id"
}

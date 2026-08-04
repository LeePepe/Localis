import Crypto
import Foundation

/// The bearer tokens this bridge has issued.
///
/// An actor because it is read on every authenticated request and written when
/// a phone pairs — concurrently, from different connections.
///
/// **Lookup is constant-time**, for the same reason the pairing code comparison
/// is: a token is a secret compared against attacker-supplied input, and a
/// dictionary lookup's timing varies with how far the key matched. The set is
/// small (one entry per paired device), so a linear scan costs nothing worth
/// measuring.
///
/// **Grants outlive the process.** Pairing is a one-time act (spec.md:46) that
/// ends only when the user unpairs (FR-027) or the certificate changes
/// (constitution §V). A bridge restart is neither — it is a process exiting —
/// so a store that forgot on exit would silently unpair every device on the
/// machine, and would make FR-027 describe an action no user would ever need
/// to perform.
public actor TokenStore {
    /// A paired device.
    public struct Grant: Sendable, Hashable, Codable {
        public let deviceName: String
        public let deviceID: String

        public init(deviceName: String, deviceID: String) {
            self.deviceName = deviceName
            self.deviceID = deviceID
        }
    }

    /// One issued credential, as stored.
    private struct Entry: Sendable, Hashable, Codable {
        let token: String
        let grant: Grant
    }

    /// A token that was revoked, remembered by hash so the next request that
    /// carries it can be told *why* it failed.
    ///
    /// **Why a tombstone exists at all.** Revocation used to be a plain delete,
    /// which makes a revoked token and a token this bridge never issued the same
    /// object: both are absent. The contract (§6) gives them different codes on
    /// purpose — `token_revoked` means "a known thing happened to you", and the
    /// phone responds by clearing its Keychain and asking the user to pair
    /// again; `invalid_token` means "cause unknown", and the phone only abandons
    /// the request. Without a record of the revocation the bridge cannot tell
    /// the two apart, so it would have to send the weaker code and the user's
    /// phone would keep a credential that will never work again.
    ///
    /// **Stored as a salted hash, never the token.** The tombstone outlives the
    /// credential, so keeping the plaintext would mean a revoked token — the one
    /// thing the user asked to make useless — sits in a file on disk for as long
    /// as the bridge exists. The salt is per-bridge and lives in the same
    /// owner-only file: it stops a stolen `grants.json` from being tested
    /// offline against a guessed token, which an unsalted hash of a
    /// high-entropy-but-known-format token would allow.
    private struct Tombstone: Sendable, Hashable, Codable {
        let tokenHash: String
        let deviceID: String
    }

    /// The file's shape.
    ///
    /// **Versioned, and this is the one migration that had to work.** The old
    /// format was a bare JSON array; `init(directory:)` treats an undecodable
    /// file as a fatal error and refuses to start (never a silent reset — see
    /// ``Failure``). Adding a field without reading the old shape would
    /// therefore not degrade, it would stop the bridge from booting on every Mac
    /// that had ever paired, and the operator's only clue would be "the pairing
    /// record is damaged". The legacy array is decoded explicitly below.
    private struct Stored: Sendable, Codable {
        var grants: [Entry]
        var revoked: [Tombstone]
        var salt: String
    }

    /// Beside `cert.pem`, `key.pem` and `instance-id`, in the same owner-only
    /// directory (constitution §I).
    public static let fileName = "grants.json"

    private var grants: [Entry] = []

    /// Tokens the user has revoked, so the next request carrying one can be
    /// told `token_revoked` rather than `invalid_token`.
    ///
    /// **This grows and nothing prunes it.** One entry per revocation, roughly
    /// 100 bytes, and a human revokes devices by hand — a Mac that reached a
    /// megabyte here would have unpaired ten thousand times. Expiry was left out
    /// deliberately rather than forgotten: any cutoff turns a phone that was off
    /// for longer than the cutoff back into `invalid_token`, silently, and the
    /// only symptom is a device that keeps a dead credential.
    private var revoked: [Tombstone] = []

    /// Per-bridge salt for the tombstone hashes. Generated once, then stable —
    /// regenerating it would make every existing tombstone unmatchable, and
    /// every already-revoked token would quietly go back to `invalid_token`.
    private var salt: String = TokenStore.generateSalt()

    /// Where grants are written, or nil for a store that keeps nothing.
    ///
    /// nil is for tests and for a bridge explicitly told not to persist. It is
    /// not a fallback: a store that could not find its directory writes
    /// nowhere rather than guessing at one.
    private let fileURL: URL?

    /// An in-memory store that writes nothing.
    public init() {
        self.fileURL = nil
    }

    /// Loads the grants stored in `directory`, if any.
    ///
    /// - Throws: ``Failure/unreadableGrants(path:)`` when a file is present but
    ///   cannot be decoded. **Deliberately not a silent reset** — see the type
    ///   documentation on ``Failure``.
    public init(directory: URL) throws {
        let url = directory.appendingPathComponent(Self.fileName)
        self.fileURL = url

        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.unreadableGrants(path: url.path)
        }

        let decoder = JSONDecoder()

        if let stored = try? decoder.decode(Stored.self, from: data) {
            grants = stored.grants
            revoked = stored.revoked
            salt = stored.salt
            return
        }

        // The pre-tombstone format: a bare array of entries. Read rather than
        // rejected, because rejecting it is not a degradation — `init` throws on
        // an undecodable file, so every Mac that had already paired would fail
        // to start the bridge after this change, reporting only "the pairing
        // record is damaged".
        //
        // Migration is not written back here. `init` does not persist, and a
        // read that silently rewrites the user's credential file is a surprise;
        // the next `issue` or `revoke` writes the new shape.
        do {
            grants = try decoder.decode([Entry].self, from: data)
        } catch {
            throw Failure.unreadableGrants(path: url.path)
        }
    }

    public func issue(token: String, to grant: Grant) {
        // Re-pairing the same device replaces its token rather than adding a
        // second one. Otherwise every re-pair leaves a live credential behind
        // that nothing will ever revoke.
        grants = grants.filter { $0.grant.deviceID != grant.deviceID }
            + [Entry(token: token, grant: grant)]
        persist()
    }

    /// The device this token belongs to, or nil.
    public func grant(for token: String) -> Grant? {
        var matched: Grant?
        // No early exit: the loop visits every entry whether or not it has
        // already found the answer.
        for entry in grants where PairingSession.constantTimeEquals(entry.token, token) {
            matched = entry.grant
        }
        return matched
    }

    /// What a token is: live, revoked, or neither.
    ///
    /// Three outcomes rather than an optional, because the caller has to answer
    /// with two different error codes and `nil` cannot carry the difference.
    public enum Lookup: Sendable, Equatable {
        /// A live token. The device it belongs to.
        case granted(Grant)
        /// This exact token was revoked by the user (contract §6).
        case revoked
        /// Not a token this bridge knows anything about.
        case unknown
    }

    /// Classifies a bearer token.
    ///
    /// **`revoked` is only ever returned for a token that actually went through
    /// ``revoke(deviceID:)`` on this bridge.** Anything else unrecognised stays
    /// ``Lookup/unknown``, and the distinction is load-bearing in a way the
    /// client cannot check: the two codes look identical on the wire, so the
    /// phone can only believe what it is told. `token_revoked` makes it erase a
    /// credential. Sending it for a token that was merely garbled would delete a
    /// working pairing over a corrupted header.
    public func lookup(token: String) -> Lookup {
        if let grant = grant(for: token) { return .granted(grant) }

        let hash = Self.hash(token: token, salt: salt)
        var wasRevoked = false
        // No early exit, for the same reason `grant(for:)` has none.
        for tombstone in revoked where PairingSession.constantTimeEquals(tombstone.tokenHash, hash) {
            wasRevoked = true
        }
        return wasRevoked ? .revoked : .unknown
    }

    /// Ends a device's pairing.
    ///
    /// Called by the `unpair` subcommand (`LocalisBridgeCLI`). **Revocation is
    /// executed from the Mac side only** — contract §1, "吊销由 Mac 侧单向执行".
    /// There is deliberately no HTTP route for it: an authenticated endpoint
    /// would let any paired phone revoke a *different* phone, which turns a
    /// stolen token from "read this Mac's models" into "lock the owner out of
    /// their own Mac".
    ///
    /// Each revoked token leaves a ``Tombstone`` so the next request carrying it
    /// gets `token_revoked` rather than `invalid_token`. Deleting alone — what
    /// this did before — makes a revoked token indistinguishable from one this
    /// bridge never issued, and the phone then keeps a credential it should have
    /// erased.
    ///
    /// Persisted immediately, and this direction matters more than issuance: a
    /// revoke that lived only in memory would come back on the next restart,
    /// undoing something the user explicitly asked for (FR-027).
    ///
    /// - Returns: the devices whose pairings ended. Empty when the id matched
    ///   nothing — the caller reports that rather than claiming a success, so
    ///   that a mistyped id cannot read as "device removed".
    @discardableResult
    public func revoke(deviceID: String) -> [Grant] {
        let ending = grants.filter { $0.grant.deviceID == deviceID }
        guard !ending.isEmpty else { return [] }

        revoked += ending.map {
            Tombstone(tokenHash: Self.hash(token: $0.token, salt: salt), deviceID: $0.grant.deviceID)
        }
        grants = grants.filter { $0.grant.deviceID != deviceID }
        persist()

        return ending.map(\.grant)
    }

    /// Every device currently paired, for the operator to choose from.
    ///
    /// Carries no token — the caller prints this, and a listing that put a live
    /// credential on a terminal would defeat the file's 0600 mode
    /// (constitution §I).
    public var pairedDevices: [Grant] { grants.map(\.grant) }

    public var count: Int { grants.count }

    /// Whether this bridge has no paired devices.
    public var isEmpty: Bool { grants.isEmpty }

    /// Writes the current grants, owner-only.
    ///
    /// A write failure is reported to the log rather than thrown: the pairing
    /// it belongs to has already succeeded on the wire, and turning that into
    /// an error would tell the phone it failed while the bridge holds a live
    /// token for it. The cost of the failure is a pairing that does not survive
    /// the next restart — the behaviour this file exists to fix, degraded back
    /// to where it was, and said out loud rather than silently.
    private func persist() {
        guard let fileURL else { return }

        let data: Data
        do {
            data = try JSONEncoder().encode(Stored(grants: grants, revoked: revoked, salt: salt))
        } catch {
            Self.warn("could not encode pairing grants; they will not survive a restart")
            return
        }

        // Written through `FileManager` with the mode set in the same call,
        // never written first and chmod'd after — the same treatment `key.pem`
        // gets, because a credential that is world-readable for a moment is a
        // credential that was world-readable.
        //
        // `createFile` replaces an existing file's contents but leaves its
        // permissions alone, so the mode is re-asserted below for a file that
        // was already there.
        guard FileManager.default.createFile(
            atPath: fileURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            Self.warn("could not write pairing grants; they will not survive a restart")
            return
        }

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Self.warn("could not restrict permissions on the pairing grant file")
        }
    }

    /// Reports a persistence problem on stderr.
    ///
    /// Never includes the token, the device name, or the file's contents —
    /// constitution §I. The path is the bridge's own config directory, which
    /// the operator already knows, and without it the message names no
    /// actionable place.
    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("localis-bridge: \(message)\n".utf8))
    }

    /// A revoked token's fingerprint.
    ///
    /// Salted so that a leaked `grants.json` cannot be attacked offline: tokens
    /// have a known format and come from a known generator, so a bare
    /// `SHA256(token)` is a value an attacker can compute candidates for. The
    /// salt is a secret held in the same owner-only file, which makes the
    /// tombstones useless to anyone who does not already have the file — and
    /// anyone who has the file has the live tokens anyway.
    static func hash(token: String, salt: String) -> String {
        Data(SHA256.hash(data: Data("\(salt):\(token)".utf8))).base64EncodedString()
    }

    /// 256 bits, from the system generator — the same choice the token itself
    /// makes, for the same reason.
    private static func generateSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes).base64EncodedString()
    }

    public enum Failure: Error, Equatable {
        /// A grant file exists but cannot be read or decoded.
        ///
        /// **Reported, never repaired.** The contrast with `instance-id` is
        /// deliberate: that one is advisory, so regenerating a corrupt one only
        /// falls back to SPKI matching. A grant file is authority. Replacing it
        /// with an empty one revokes every pairing on the machine, and the user
        /// sees only that their phone stopped connecting — no event to point
        /// at, nothing they did. An error the operator can read is the smaller
        /// harm, and it is the only version of this the user can act on.
        case unreadableGrants(path: String)
    }
}

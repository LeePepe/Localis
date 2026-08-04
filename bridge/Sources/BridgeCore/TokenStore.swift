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

    /// Beside `cert.pem`, `key.pem` and `instance-id`, in the same owner-only
    /// directory (constitution §I).
    public static let fileName = "grants.json"

    private var grants: [Entry] = []

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

        do {
            grants = try JSONDecoder().decode([Entry].self, from: data)
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

    /// Ends a device's pairing.
    ///
    /// **No production caller. Nothing on a phone can reach this today.**
    /// Verified 2026-08-04 across all three segments of the path:
    ///
    /// | layer | state |
    /// |---|---|
    /// | iOS UI | no "unpair" control exists |
    /// | iOS logic | `unpaired()` has zero callers |
    /// | bridge | `Router` has no unpair route; this method's only caller is a test |
    ///
    /// Kept rather than deleted, on a deliberate ruling. The argument below for
    /// *why* it must persist is the part worth keeping: it was reached once, and
    /// whoever builds unpair would otherwise have to reach it again — possibly
    /// without success, since the failure it prevents is invisible until a
    /// restart.
    ///
    /// Building it now was considered and rejected: a route that calls this,
    /// writes to disk, and answers `token_revoked` would be an end-to-end path
    /// no client ever requests. That looks *more* finished than the present
    /// state while being exactly as unreachable, which is harder to notice, not
    /// easier. The order has to be UI entry point → iOS request → bridge route.
    ///
    /// Persisted immediately, and this direction matters more than issuance: a
    /// revoke that lived only in memory would come back on the next restart,
    /// undoing something the user explicitly asked for (FR-027).
    public func revoke(deviceID: String) {
        grants = grants.filter { $0.grant.deviceID != deviceID }
        persist()
    }

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
            data = try JSONEncoder().encode(grants)
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

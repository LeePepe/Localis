import Foundation
import LocalisModels
import Security

/// Keychain storage for one host's credentials (constitution I and V).
///
/// Two things live here per host: the pairing token and the pinned SPKI. Both
/// are keyed by `HostID` and **nothing is shared between hosts** — no common
/// trust store, no host-less fallback key, no "default" credential. That is
/// FR-028 stated as an API: a shared entry would let host A's certificate
/// authenticate host B, and the failure would be silent, because everything
/// would keep working.
///
/// Every method takes a `HostID`, so a host-blind lookup is not something to
/// remember not to write — there is no way to express it.
///
/// **Nothing here is ever logged.** No token, no pin, no host id: the type has
/// no description worth printing, and errors carry an OSStatus rather than the
/// value that failed.
public struct HostCredentialStore: Sendable {
    /// Keychain service, overridable so tests do not touch the app's entries.
    private let service: String

    public init(service: String = "dev.localis.bridge") {
        self.service = service
    }

    /// What kind of secret an entry holds.
    ///
    /// Part of the account key, so a token and a pin for the same host are
    /// different entries and cannot overwrite one another.
    private enum Kind: String {
        case token
        case pin
    }

    /// The Keychain account for one host's secret of one kind.
    ///
    /// Both halves are in the key, which is what makes cross-host reads
    /// impossible rather than merely unlikely.
    private func account(_ kind: Kind, _ host: HostID) -> String {
        "\(kind.rawValue).\(host.rawValue.uuidString)"
    }

    // MARK: - Tokens

    /// Stores the pairing token for `host`, replacing any existing one.
    public func saveToken(_ token: String, for host: HostID) throws {
        try save(Data(token.utf8), account: account(.token, host))
    }

    /// The pairing token for `host`, or nil if it is not paired.
    public func token(for host: HostID) throws -> String? {
        guard let data = try read(account: account(.token, host)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Pinned certificates

    /// Pins `hash` for `host`, replacing any existing pin.
    public func savePin(_ hash: SPKIHash, for host: HostID) throws {
        try save(Data(hash.base64.utf8), account: account(.pin, host))
    }

    /// The SPKI pinned for `host` at pairing, or nil if there is none.
    ///
    /// Nil means "cannot connect", never "connect without checking": an absent
    /// pin fails closed at the call site (`SPKIPinning`).
    public func pin(for host: HostID) throws -> SPKIHash? {
        guard let data = try read(account: account(.pin, host)),
              let base64 = String(data: data, encoding: .utf8) else {
            return nil
        }
        return SPKIHash(base64: base64)
    }

    // MARK: - Unpairing

    /// Removes everything stored for `host` (FR-027, zero residue).
    ///
    /// Both secrets go, and the pin especially: leaving it behind would keep a
    /// trust anchor on disk for a host the user explicitly stopped trusting.
    ///
    /// Idempotent — a host that was never paired, or one being removed twice by
    /// a retry, is not an error.
    ///
    /// Sessions are **not** touched. Unpairing removes credentials; the
    /// conversation history stays and becomes read-only (FR-027), which is why
    /// this type knows nothing about storage above it.
    public func removeCredentials(for host: HostID) throws {
        try delete(account: account(.token, host))
        try delete(account: account(.pin, host))
    }

    /// Removes every entry in this store's service. Test support: the app
    /// unpairs one host at a time and never has a reason to wipe the service.
    func removeAll() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ] as CFDictionary)
    }

    /// How stored credentials are protected.
    ///
    /// **Not readable while the device is locked, and never leaves this
    /// device**: no iCloud sync, no restore onto a second phone. A pairing
    /// token that rides a backup onto another device is access to the user's
    /// Mac that they never granted there — and it would work silently.
    ///
    /// Named rather than inlined so the policy is one value that a test pins
    /// and a reviewer can find, instead of a literal buried in a query.
    ///
    /// Held as `String`, not `CFString`: a `CFString` static is not `Sendable`
    /// under strict concurrency, and the escape hatch that would silence that
    /// is exactly what constitution II forbids.
    static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    /// The accessibility class an entry was actually stored under, when the
    /// platform reports it.
    ///
    /// Returns nil on macOS: the file-based Keychain omits `kSecAttrAccessible`
    /// from `SecItemCopyMatching` results, and the data-protection Keychain
    /// that does return it needs an entitlement a SwiftPM test binary cannot
    /// carry (`errSecMissingEntitlement`). So on the test host this is a check
    /// that cannot run — the policy is pinned via `accessibility` instead, and
    /// verified end-to-end only on device.
    func storedAccessibility(for host: HostID) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(.token, host),
            kSecReturnAttributes: true,
        ] as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    // MARK: - Keychain

    private func save(_ data: Data, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        // Delete first rather than trying an update and falling back: a partial
        // update can leave two entries for one account, and the Keychain then
        // returns whichever it likes — an app that authenticates with a revoked
        // token on some launches and not others.
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = Self.accessibility

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status: status)
        }
    }

    private func read(account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            // Not paired. An ordinary state, not a failure.
            return nil
        default:
            throw KeychainError.readFailed(status: status)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }
}

/// A Keychain operation that failed.
///
/// Carries the OSStatus and nothing else — no account, no host, no value. The
/// status is what a developer needs; anything more would put a credential's
/// identity into an error that may be logged upstream.
public enum KeychainError: Error, Hashable, Sendable {
    case storeFailed(status: OSStatus)
    case readFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
}

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
public actor TokenStore {
    /// A paired device.
    public struct Grant: Sendable, Hashable {
        public let deviceName: String
        public let deviceID: String

        public init(deviceName: String, deviceID: String) {
            self.deviceName = deviceName
            self.deviceID = deviceID
        }
    }

    private var grants: [(token: String, grant: Grant)] = []

    public init() {}

    public func issue(token: String, to grant: Grant) {
        // Re-pairing the same device replaces its token rather than adding a
        // second one. Otherwise every re-pair leaves a live credential behind
        // that nothing will ever revoke.
        grants.removeAll { $0.grant.deviceID == grant.deviceID }
        grants.append((token, grant))
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

    public func revoke(deviceID: String) {
        grants.removeAll { $0.grant.deviceID == deviceID }
    }

    public var count: Int { grants.count }
}

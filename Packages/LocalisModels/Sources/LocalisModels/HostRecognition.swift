import Foundation

/// Decides whether a bridge that just appeared on the network is a machine we
/// already know (FR-031).
///
/// Getting this wrong fails silently in both directions: merge two machines and
/// one inherits the other's history; fail to recognise one and the user is asked
/// to re-pair a machine that never changed. So the rule is written once, here,
/// as a pure function over data — not spread across the discovery code.
///
/// **The pinned certificate is the authority.** `bridge_id` only relocates a
/// machine whose SPKI already matches (Amendment A §1.6). A whole-disk clone
/// reports the same `bridge_id` from a different machine; its SPKI differs, and
/// that is what keeps the two apart.
public enum HostRecognition {
    /// What a freshly discovered bridge turned out to be.
    public enum Outcome: Hashable, Sendable {
        /// A known, paired host — possibly at a new address. No re-pairing.
        case trusted(HostID)
        /// A known host whose pairing was revoked. Its orphaned sessions can be
        /// reactivated, but the user must pair again first.
        case needsPairing(HostID)
        /// A known host presenting a certificate that does not match its pin.
        /// Connection is refused with no override (constitution V).
        case untrusted(HostID)
        /// Not a machine we have seen. Treat as new.
        case unknown
    }

    /// Matches a discovered bridge against the hosts we know.
    ///
    /// - Parameters:
    ///   - bridgeID: the bridge's self-reported instance id, if it sent one.
    ///   - spki: SPKI hash of the certificate it just presented.
    ///   - hosts: every host on file, paired or revoked.
    public static func recognise(
        bridgeID: String?,
        spki: SPKIHash,
        among hosts: [LocalisHost]
    ) -> Outcome {
        // A revoked host has no pin left (FR-027), so it can only be matched by
        // bridge id — and matching it grants continuity, never trust.
        if let revoked = hosts.first(where: {
            $0.pairingState == .revoked && $0.bridgeID != nil && $0.bridgeID == bridgeID
        }) {
            return .needsPairing(revoked.id)
        }

        guard let known = hosts.first(where: { $0.pinnedSPKI != nil && $0.bridgeID == bridgeID })
            ?? hosts.first(where: { $0.pinnedSPKI == spki }) else {
            return .unknown
        }

        guard known.pinnedSPKI == spki else {
            // Same bridge id, different certificate: either a clone or a
            // reinstall. Both demand a human decision, never an auto-merge.
            return .untrusted(known.id)
        }

        // The certificate matches. A contradicting bridge id means the two
        // signals disagree, and `bridge_id` does not get to win — decline.
        if let claimed = bridgeID, let recorded = known.bridgeID, claimed != recorded {
            return .unknown
        }

        return known.pairingState == .paired ? .trusted(known.id) : .needsPairing(known.id)
    }
}

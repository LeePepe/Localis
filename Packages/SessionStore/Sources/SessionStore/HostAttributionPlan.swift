import Foundation
import LocalisModels

/// How a session stored before `hostID` existed gets attributed to a machine.
///
/// Amendment A §1.7 fixes the rule: one paired host means the attribution is
/// certain, anything else means it is a guess. Guessing wrong silently files a
/// conversation under the wrong machine, so ambiguity resolves to read-only
/// rather than to a coin flip.
///
/// A pure function on purpose — the rule that decides whether a user keeps
/// their conversations is exhaustively testable without a container.
public enum HostAttributionPlan: Hashable, Sendable {
    /// Exactly one paired host: attribute every legacy session to it.
    case backfill(HostID)
    /// Zero or several paired hosts: mark read-only and let the user decide.
    case orphan

    /// Picks the plan from the hosts paired at migration time.
    public static func resolve(pairedHosts: [HostID]) -> HostAttributionPlan {
        let distinct = Set(pairedHosts)
        guard distinct.count == 1, let only = distinct.first else { return .orphan }
        return .backfill(only)
    }

    /// The attribution for one legacy session.
    ///
    /// A session that already carries a host is returned untouched: a migration
    /// re-run must not reassign conversations that were already placed. The
    /// unattributed marker is not a host, so it does not count as placed.
    public func attribution(forLegacySessionWith existingHostID: HostID?) -> HostAttribution {
        if let existingHostID, !existingHostID.isUnattributed {
            return .attributed(existingHostID)
        }
        switch self {
        case .backfill(let hostID):
            return .attributed(hostID)
        case .orphan:
            return .orphaned
        }
    }
}

/// The outcome of attributing one session. Note the absence of a `delete` case:
/// migration has no vocabulary for discarding a conversation (FR-038), and
/// deletion is only ever an explicit user action (FR-027).
public enum HostAttribution: Hashable, Sendable {
    /// Belongs to this machine.
    case attributed(HostID)
    /// Ownership unknown — readable, not sendable, awaiting the user.
    case orphaned

    /// Always `true`. It exists so the guarantee is asserted by tests rather
    /// than merely stated in a comment.
    public var keepsSession: Bool { true }
}

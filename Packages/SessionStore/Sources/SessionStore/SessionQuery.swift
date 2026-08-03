import Foundation
import LocalisModels

/// A query against stored sessions, keyed the only way a backend can be
/// identified globally: **(hostID, backendID)**.
///
/// Amendment A §1.1 chose a composite key over a synthesized local UUID, which
/// leaves one silent failure mode: a query that filters by `backendID` alone.
/// Two machines can both expose a backend called `claude`, so such a query
/// returns another machine's conversations with no error anywhere.
///
/// This type closes that hole structurally rather than by convention —
/// `hostID` comes first and `backendID` cannot be supplied without it, so a
/// backend-only query is not something a caller can express.
public struct SessionQuery: Hashable, Sendable {
    /// The machine whose sessions are being asked for.
    ///
    /// `HostID.unattributed` for `.orphaned`, whose defining property is having
    /// no known machine.
    public let hostID: HostID
    /// Optional narrowing *within* that host. Meaningless without `hostID`,
    /// which is why it can only be set alongside one.
    public let backendID: String?

    /// Every session on one machine.
    public init(hostID: HostID) {
        self.hostID = hostID
        self.backendID = nil
    }

    /// Sessions on one machine that used one of its backends.
    public init(hostID: HostID, backendID: String) {
        self.hostID = hostID
        self.backendID = backendID
    }

    /// Sessions with no known machine — legacy rows migration could not
    /// attribute, readable and awaiting the user's decision (FR-038).
    ///
    /// Deliberately *not* named `orphaned`: a session whose host was unpaired
    /// keeps its binding for life (FR-030) and is found through that host's
    /// query with `status == .orphaned`. Conflating the two would make
    /// "unpaired" look like "hostless" and invite a re-pair to re-attribute a
    /// conversation that never moved.
    public static let unattributed = SessionQuery(hostID: .unattributed)

    /// Whether this query asks for sessions with no known machine.
    public var isUnattributedQuery: Bool { hostID.isUnattributed }

    /// Whether a stored session's attribution satisfies this query.
    ///
    /// Host equality is checked first and unconditionally; `backendID` only ever
    /// narrows further. There is no path through this function where a backend
    /// name alone can produce a match.
    public func matches(hostID sessionHostID: HostID?, backendID sessionBackendID: String?) -> Bool {
        guard (sessionHostID ?? .unattributed) == hostID else { return false }
        guard let backendID else { return true }
        return sessionBackendID == backendID
    }
}

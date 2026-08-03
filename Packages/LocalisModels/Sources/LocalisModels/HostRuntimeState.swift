import Foundation

/// Runtime state about a host, computed and **never persisted**.
///
/// Amendment C §4.2: reachability, latency and last-seen are observations, not
/// facts about the machine. Keeping them out of `Host` is what stops a stale
/// "unreachable" from being written to disk and read back as truth after the
/// network recovered. Aggregates like "2 of 3 reachable" are derived the same
/// way and equally unstored.
///
/// Deliberately **not** `Codable` — the type system enforces the rule.
public struct HostRuntimeState: Hashable, Sendable {
    public let reachability: HostReachability
    /// Round-trip time of the last successful probe, when one has succeeded.
    public let latencyMs: Int?
    /// When the host last answered. "6 minutes ago" and "3 days ago" are
    /// different situations for the user (Amendment C §4.2).
    public let lastSeenAt: Date?

    public init(
        reachability: HostReachability = .unknown,
        latencyMs: Int? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.reachability = reachability
        self.latencyMs = latencyMs
        self.lastSeenAt = lastSeenAt
    }

    public func withReachability(_ newReachability: HostReachability) -> HostRuntimeState {
        HostRuntimeState(reachability: newReachability, latencyMs: latencyMs, lastSeenAt: lastSeenAt)
    }

    /// Records a successful probe.
    public func seen(at timestamp: Date, latencyMs newLatency: Int?) -> HostRuntimeState {
        HostRuntimeState(reachability: .reachable, latencyMs: newLatency, lastSeenAt: timestamp)
    }
}

/// Whether a host is answering right now.
///
/// `unknown` is the honest starting value — before the first probe we have not
/// established that a host is down, and showing it as unreachable would be a
/// lie the user has to disprove.
public enum HostReachability: Hashable, Sendable {
    case reachable
    case unreachable(reason: HostUnreachableReason)
    case unknown
}

/// Why a host cannot be reached. Carried so the UI can say something specific
/// and actionable rather than a generic failure.
public enum HostUnreachableReason: String, CaseIterable, Sendable {
    /// No route: the machine is asleep, off, or we left its network.
    case offline
    /// Reached, but the certificate did not match the pin (constitution V).
    case certificateRejected
    /// Reached, but the token was rejected — re-pairing is required.
    case unauthorized
    /// The host speaks a protocol version this app does not support (FR-032).
    case unsupportedProtocol
}

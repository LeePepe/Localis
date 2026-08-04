import Foundation

/// What a host says about one of its backends, right now.
///
/// Three cases and not an `AgentBackend?`, because the optional spelling folds
/// two different situations into `nil`: a Mac that did not answer, and a Mac
/// that answered and no longer lists the backend. They call for opposite user
/// actions — the first is fixed by waiting, the second never is — and a screen
/// given only `nil` can say nothing better than "unavailable", which is the
/// collapse this type exists to prevent.
///
/// Runtime state, never persisted (Amendment C §4.2): it answers "right now",
/// which nothing on disk can know. Deliberately not `Codable`, so the type
/// system enforces that rather than a convention.
public enum BackendDescription: Hashable, Sendable {
    /// The host answered and listed this backend. The value is the host's own
    /// description, so `availability` here is fresh — unlike a stored one, which
    /// both repositories deliberately flatten to `.available`.
    case listed(AgentBackend)
    /// The host answered and did not list this backend: it was removed on the
    /// Mac. Waiting does not fix this, and the conversation cannot be continued
    /// until the agent is put back or the session is pointed elsewhere.
    case absent
    /// The host could not be asked — asleep, off the network, or refusing.
    ///
    /// **Says nothing about the backend.** Reporting this as "signed out" would
    /// send the user to sign in on a machine that is not even on, which is the
    /// same wrong-half naming that made a rejected certificate read as an
    /// offline Mac.
    case unknown
}

extension BackendDescription {
    /// The host's description when it gave one, otherwise nil.
    ///
    /// A convenience for callers that genuinely do not distinguish `absent` from
    /// `unknown` — not a shortcut past the distinction. Anything that puts words
    /// on a screen should switch over the case instead.
    public var backend: AgentBackend? {
        guard case .listed(let backend) = self else { return nil }
        return backend
    }
}

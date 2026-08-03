import Foundation

/// The globally unique key for a backend: `(hostID, backendID)` (FR-029).
///
/// `backendID` stays the wire string from `/v1/models` and is unique only
/// *within one host*. Two machines both exposing `claude` expose two different
/// backends, and anything that compares backend ids alone will silently return
/// the wrong machine's — the failure mode Amendment A §1.1 calls out.
///
/// Rejected alternatives, and why (Amendment A §1.1):
/// - **A synthesised local UUID** would make iOS keep a registry translating ids
///   back to wire names. That turns a backend into client state, which
///   constitution IV forbids, and the registry cannot survive a bridge
///   reinstall or a move to another machine.
/// - **A namespaced string** (`"host-uuid/claude"`) is this composite key with
///   the halves glued together, so it can be concatenated and mis-parsed, and
///   the type system stops telling the two apart.
public struct BackendRef: Hashable, Codable, Sendable {
    public let hostID: HostID
    /// The `/v1/models` model id, verbatim. Unique per host, not globally.
    public let backendID: String

    public init(hostID: HostID, backendID: String) {
        self.hostID = hostID
        self.backendID = backendID
    }

    /// Whether `backend` — as advertised by `host` — is the one this refers to.
    ///
    /// The host argument is required on purpose: it makes the host-blind
    /// comparison inexpressible rather than merely discouraged.
    public func matches(_ backend: AgentBackend, on host: HostID) -> Bool {
        hostID == host && backendID == backend.id
    }
}

extension AgentBackend {
    /// Qualifies this backend with the host that advertised it.
    ///
    /// `BridgeClient` is instantiated per host, so the backends it returns all
    /// belong to that host; the label is attached here at the boundary. This is
    /// why `TransportKit` never needs to know that multiple hosts exist.
    public func ref(on hostID: HostID) -> BackendRef {
        BackendRef(hostID: hostID, backendID: id)
    }
}

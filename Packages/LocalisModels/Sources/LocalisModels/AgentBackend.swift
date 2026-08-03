import Foundation

/// A local AI agent backend Localis can talk to.
///
/// Localis is a *client* — every backend runs on the user's own machine or
/// network. The kind drives which wire protocol `TransportKit` speaks; the
/// endpoint is supplied by the user, never hardcoded.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case openClaw
    case hermes
    case kimi
    case codex

    /// Human-facing label. UI must localize; this is the stable fallback.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openClaw: return "OpenClaw"
        case .hermes: return "Hermes"
        case .kimi: return "Kimi"
        case .codex: return "Codex"
        }
    }
}

/// A configured connection to one local agent.
///
/// Value type — updates produce a new instance (`withEndpoint`), never mutate.
public struct AgentBackend: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: AgentKind
    /// User-supplied display name, e.g. "MacBook Claude".
    public let name: String
    /// Base URL of the local agent, e.g. `http://192.168.1.20:8080`.
    public let endpoint: URL

    public init(id: UUID, kind: AgentKind, name: String, endpoint: URL) {
        self.id = id
        self.kind = kind
        self.name = name
        self.endpoint = endpoint
    }

    /// Returns a copy pointing at a different endpoint.
    public func withEndpoint(_ newEndpoint: URL) -> AgentBackend {
        AgentBackend(id: id, kind: kind, name: name, endpoint: newEndpoint)
    }

    /// Returns a copy with a different display name.
    public func withName(_ newName: String) -> AgentBackend {
        AgentBackend(id: id, kind: kind, name: newName, endpoint: endpoint)
    }
}

import Foundation

/// A backend advertised by the bridge, as **data**.
///
/// Constitution principle IV (non-negotiable): iOS speaks one protocol, and all
/// backend differences are absorbed by adapters on the Mac side. So a backend is
/// a capability descriptor pulled from `/v1/models` — never a closed enum, and
/// never a `switch` in transport code.
///
/// This is what makes "add a sixth backend" a Mac-side adapter plus one more
/// entry in `/v1/models`, with zero iOS changes and zero App Store releases. A
/// `case kimi` here would silently reintroduce that release coupling: every new
/// agent would need a new build.
///
/// Value type — updates produce a new instance, never mutate.
public struct AgentBackend: Identifiable, Codable, Hashable, Sendable {
    /// Stable identifier from the bridge — the `/v1/models` model id.
    public let id: String
    /// Human-facing label supplied by the bridge. UI must localize any text it
    /// adds around this; the label itself is the bridge's to name.
    public let displayName: String
    /// Capabilities this backend advertises, e.g. `"tools"`, `"streaming"`,
    /// `"resume"`. Open set on purpose — an unknown capability is ignored, not
    /// a decoding failure, so the bridge can add one without an iOS release.
    public let capabilities: Set<String>

    public init(id: String, displayName: String, capabilities: Set<String> = []) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
    }

    /// Whether the backend advertises a named capability.
    ///
    /// This is the only sanctioned way to branch on a backend. Feature checks
    /// ask what it *can do*, never what it *is*.
    public func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    /// Returns a copy with a different display name.
    public func withDisplayName(_ newName: String) -> AgentBackend {
        AgentBackend(id: id, displayName: newName, capabilities: capabilities)
    }

    /// Returns a copy advertising a different capability set.
    public func withCapabilities(_ newCapabilities: Set<String>) -> AgentBackend {
        AgentBackend(id: id, displayName: displayName, capabilities: newCapabilities)
    }
}

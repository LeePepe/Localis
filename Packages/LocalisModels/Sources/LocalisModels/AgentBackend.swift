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
    /// Whether the host can currently route to this backend (contract §2).
    ///
    /// A separate axis from `capabilities`: a signed-out backend still
    /// advertises what it *can do*. Folding availability into the capability set
    /// would make it look incapable, and its capabilities would then appear to
    /// change under the user on re-login.
    public let availability: BackendAvailability

    public init(
        id: String,
        displayName: String,
        capabilities: Set<String> = [],
        availability: BackendAvailability = .available
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.availability = availability
    }

    /// Decodes payloads written before `availability` existed.
    ///
    /// A stored backend list from an earlier build has no such field, and
    /// failing on it would lose the user's backends on upgrade. A missing value
    /// means available — the safe default, since an older bridge that never
    /// sends it must not have everything greyed out.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        capabilities = try container.decodeIfPresent(Set<String>.self, forKey: .capabilities) ?? []
        availability = try container.decodeIfPresent(
            BackendAvailability.self, forKey: .availability
        ) ?? .available
    }

    /// Whether the host can route to this backend right now.
    public var isAvailable: Bool { availability == .available }

    /// The host's short reason code when unavailable, e.g. `not_logged_in`.
    ///
    /// A machine code from an open set, not display text — the UI maps it
    /// locally and falls back to generic wording for codes it doesn't know.
    public var unavailableReason: String? {
        switch availability {
        case .available: return nil
        case .unavailable(let reason): return reason
        }
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
        AgentBackend(
            id: id, displayName: newName,
            capabilities: capabilities, availability: availability
        )
    }

    /// Returns a copy advertising a different capability set.
    public func withCapabilities(_ newCapabilities: Set<String>) -> AgentBackend {
        AgentBackend(
            id: id, displayName: displayName,
            capabilities: newCapabilities, availability: availability
        )
    }

    /// Returns a copy with a different availability — the `/v1/models` refresh
    /// path, where a backend comes back after the user signs in.
    public func withAvailability(_ newAvailability: BackendAvailability) -> AgentBackend {
        AgentBackend(
            id: id, displayName: displayName,
            capabilities: capabilities, availability: newAvailability
        )
    }
}

/// Whether a host can currently route to a backend (contract §2 `x_localis`).
///
/// The reason is carried rather than reduced to a bool so the picker can say
/// "codex isn't signed in" instead of just greying a row out — the difference
/// between the user knowing what to do and not.
public enum BackendAvailability: Codable, Hashable, Sendable {
    case available
    /// Unavailable, with the host's short reason code when it sent one.
    ///
    /// Open value set (constitution IV): an unrecognised code is kept intact so
    /// a bridge can add one without an iOS release.
    case unavailable(reason: String?)
}


import Foundation
import LocalisModels

/// A skill (slash command) exposed by an agent backend.
///
/// Skills are *discovered* from the backend, not hardcoded — different agents
/// advertise different sets, and the set can change between sessions.
public struct Skill: Identifiable, Codable, Hashable, Sendable {
    /// Invocation name without the leading slash, e.g. `review`.
    public let id: String
    /// One-line description shown in the picker.
    public let summary: String
    /// Which backend advertised it.
    public let backendID: String

    public init(id: String, summary: String, backendID: String) {
        self.id = id
        self.summary = summary
        self.backendID = backendID
    }

    /// How the skill is typed into the composer.
    public var invocation: String { "/\(id)" }
}

/// Source of the skills available for a backend.
public protocol SkillProvider: Sendable {
    /// Skills advertised by `backend`, or an empty array if it exposes none.
    func skills(for backend: AgentBackend) async throws -> [Skill]
}

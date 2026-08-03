import Foundation
import LocalisModels

/// Parses a composer draft into a skill invocation, if it is one.
///
/// Pure and synchronous — the composer calls this on every keystroke to decide
/// whether to show the skill picker, so it must not touch the network.
public enum SkillParser {
    /// A recognized `/skill arguments…` draft.
    public struct Invocation: Equatable, Sendable {
        public let skillID: String
        /// Everything after the skill name, trimmed. Empty when absent.
        public let arguments: String

        public init(skillID: String, arguments: String) {
            self.skillID = skillID
            self.arguments = arguments
        }
    }

    /// Extracts an invocation from `text`.
    ///
    /// - Returns: nil when the draft is ordinary prose (no leading slash, or a
    ///   bare `/` with nothing after it).
    public static func parse(_ text: String) -> Invocation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let body = String(trimmed.dropFirst())
        guard let firstSpace = body.firstIndex(of: " ") else {
            return body.isEmpty ? nil : Invocation(skillID: body, arguments: "")
        }

        let skillID = String(body[body.startIndex..<firstSpace])
        guard !skillID.isEmpty else { return nil }
        let arguments = String(body[body.index(after: firstSpace)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Invocation(skillID: skillID, arguments: arguments)
    }

    /// Skills whose id has `prefix` as a case-insensitive prefix.
    ///
    /// Drives the autocomplete list; an empty prefix matches everything.
    public static func matches(prefix: String, in skills: [Skill]) -> [Skill] {
        guard !prefix.isEmpty else { return skills }
        return skills.filter { $0.id.lowercased().hasPrefix(prefix.lowercased()) }
    }
}

import Foundation
import LocalisModels

/// Parses `GET /v1/skills` (contract §5, Amendment B).
///
/// Per host, always: skills are files on that machine, so two hosts have two
/// unrelated catalogues and the picker shows only the current session's
/// (FR-045). Nothing here caches — the caller holds the result in memory and
/// never persists it (FR-047).
///
/// The client deliberately reads **less** than the bridge sends: `parameters`
/// and `backends` still arrive and are ignored (Amendment B §2). That is why
/// dropping the parameter form needed no protocol change, and why adding one
/// back later would not either.
public enum SkillCatalog {
    /// Decodes a `/v1/skills` body.
    ///
    /// - Throws: `LocalisError.malformedResponse` when the body is not JSON or
    ///   has no `data` array.
    ///
    /// A single invalid entry is skipped and the rest stay usable (FR-023). The
    /// alternative — failing the whole catalogue — would let one malformed
    /// template on the Mac remove every skill the user has.
    public static func decode(data: Data) throws -> [SkillDescriptor] {
        guard let json = JSONValue(jsonData: data), let entries = json["data"]?.arrayValue else {
            throw LocalisError.malformedResponse
        }

        return entries.compactMap(skill(from:))
    }

    /// Builds one skill, or nil if a required field is missing or blank.
    ///
    /// Blank counts as missing: a skill with an empty template inserts nothing,
    /// and in the picker it is indistinguishable from one that is broken.
    private static func skill(from json: JSONValue) -> SkillDescriptor? {
        guard let id = json["id"]?.stringValue, !id.trimmed.isEmpty,
              let name = json["name"]?.stringValue, !name.trimmed.isEmpty,
              let template = json["template"]?.stringValue, !template.trimmed.isEmpty else {
            return nil
        }

        return SkillDescriptor(
            id: id,
            name: name,
            summary: json["summary"]?.stringValue,
            // Verbatim, `{{…}}` included. The composer is the parameter
            // mechanism: the user types over the placeholder (Amendment B §2).
            template: template
        )
    }
}

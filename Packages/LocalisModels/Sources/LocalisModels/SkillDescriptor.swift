import Foundation

/// An editable text template the user can drop into the composer.
///
/// Amendment B: a skill is an **input accelerator**, not a subsystem. The whole
/// feature is: type `/`, filter, insert the text, edit it, send. Everything else
/// the original spec described — a parameter schema, required-field validation,
/// variable substitution, invocation provenance, "resend with the same skill" —
/// was **deleted**, not deferred (SC-014).
///
/// The composer *is* the parameter mechanism: `{{topic}}` goes in verbatim and
/// the user types over it. That is why there is no expansion API here to call.
///
/// The wire format is unchanged: `/v1/skills` may still return `parameters` and
/// `backends`, and a v1 client ignores both (Amendment B §2). Bridges need no
/// changes, and a future parameter form would need no protocol change either.
public struct SkillDescriptor: Identifiable, Codable, Hashable, Sendable {
    /// Stable id from the host's catalogue, e.g. `to-spec`.
    public let id: String
    /// Label shown in the picker.
    public let name: String
    /// One line under the name. Absent for skills that do not supply one.
    public let summary: String?
    /// The text inserted into the composer, **verbatim**, placeholders included.
    public let template: String

    public init(id: String, name: String, summary: String? = nil, template: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.template = template
    }

    /// Only the four fields above are decoded. Unknown keys — including the
    /// `parameters` and `backends` a bridge may still send — are ignored rather
    /// than treated as a failure (FR-023, forward compatibility).
    private enum CodingKeys: String, CodingKey {
        case id, name, summary, template
    }

    /// Range of the first `{{…}}` placeholder, if the template has one.
    ///
    /// US4 scenario 2 puts the cursor here so the user can type straight over
    /// it. A scan rather than metadata — that is the whole reason `SkillParameter`
    /// could be deleted (Amendment B §2).
    ///
    /// An unterminated `{{` is not a placeholder.
    public var firstPlaceholderRange: Range<String.Index>? {
        guard let open = template.range(of: "{{"),
              let close = template.range(of: "}}", range: open.upperBound..<template.endIndex) else {
            return nil
        }
        return open.lowerBound..<close.upperBound
    }

    /// Whether this skill survives the picker's filter for `query` (FR-022).
    ///
    /// Subsequence matching over id and name, case-insensitive, so `ts` finds
    /// `to-spec`. An empty query matches everything.
    public func matches(_ query: String) -> Bool {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return true }
        return Self.isSubsequence(needle, of: id.lowercased())
            || Self.isSubsequence(needle, of: name.lowercased())
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(haystack)
        for character in needle {
            guard let hit = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: hit)...]
        }
        return true
    }
}

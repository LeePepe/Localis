import Foundation
import Testing

@testable import LocalisModels

/// Amendment B: a skill is an editable text template, nothing more. There is no
/// parameter schema, no validator, no expander, and no invocation record — those
/// were deleted, not deferred (SC-014).
@Suite("SkillDescriptor")
struct SkillDescriptorTests {
    @Test("a skill is id, name, optional summary, and template — nothing else")
    func shapeIsMinimal() throws {
        let skill = SkillDescriptor(id: "to-spec", name: "To Spec", summary: nil, template: "Write a spec for {{topic}}")

        let json = String(decoding: try JSONEncoder().encode(skill), as: UTF8.self)

        #expect(!json.contains("parameters"))
        #expect(!json.contains("backends"))
        #expect(!json.contains("invocation"))
    }

    @Test("the template is inserted verbatim, placeholders included")
    func templateIsNotExpanded() {
        // Amendment B §1: the composer *is* the parameter mechanism. There is
        // deliberately no substitution API to call.
        let skill = SkillDescriptor(id: "tdd", name: "TDD", summary: "Red green refactor", template: "Test {{feature}} first")

        #expect(skill.template == "Test {{feature}} first")
    }

    @Test("the first placeholder is found by scanning the template")
    func firstPlaceholderRangeIsScanned() {
        // US4 scenario 2: the cursor lands on the first placeholder so the user
        // can type over it. A scan, not metadata (Amendment B §2).
        let skill = SkillDescriptor(id: "s", name: "S", summary: nil, template: "Review {{file}} for {{issue}}")

        let range = try? #require(skill.firstPlaceholderRange)

        #expect(range.map { String(skill.template[$0]) } == "{{file}}")
    }

    @Test("a template without placeholders has no placeholder range")
    func noPlaceholderIsNil() {
        let skill = SkillDescriptor(id: "s", name: "S", summary: nil, template: "Just prose")

        #expect(skill.firstPlaceholderRange == nil)
    }

    @Test("an unterminated placeholder is not a placeholder")
    func unterminatedPlaceholderIsIgnored() {
        let skill = SkillDescriptor(id: "s", name: "S", summary: nil, template: "Broken {{oops")

        #expect(skill.firstPlaceholderRange == nil)
    }

    @Test("fuzzy matching narrows the picker as the user types")
    func fuzzyMatchesSubsequences() {
        // US4 scenario 1: typing after `/` filters. Subsequence matching so
        // "ts" finds "to-spec".
        let skill = SkillDescriptor(id: "to-spec", name: "To Spec", summary: nil, template: "x")

        #expect(skill.matches(""))
        #expect(skill.matches("ts"))
        #expect(skill.matches("spec"))
        #expect(skill.matches("TOSPEC"))
        #expect(!skill.matches("zzz"))
    }

    @Test("matching searches the name as well as the id")
    func fuzzyMatchesTheName() {
        let skill = SkillDescriptor(id: "abc", name: "Write a changelog", summary: nil, template: "x")

        #expect(skill.matches("changelog"))
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        let skill = SkillDescriptor(id: "x", name: "X", summary: "sum", template: "t")

        let decoded = try JSONDecoder().decode(
            SkillDescriptor.self,
            from: try JSONEncoder().encode(skill)
        )

        #expect(decoded == skill)
    }

    @Test("unknown wire fields are ignored, not a decoding failure")
    func decodingIgnoresUnknownFields() throws {
        // FR-023 + Amendment B §2: the bridge may keep sending `parameters` and
        // `backends`. A v1 client ignores them, and one unknown field must never
        // take out the whole catalogue.
        let wire = """
        {"id":"x","name":"X","template":"t","parameters":[{"name":"topic"}],"backends":["claude"]}
        """

        let decoded = try JSONDecoder().decode(SkillDescriptor.self, from: Data(wire.utf8))

        #expect(decoded.id == "x")
        #expect(decoded.template == "t")
        #expect(decoded.summary == nil)
    }

    @Test("a skill missing a required field fails to decode on its own")
    func missingRequiredFieldFails() {
        // FR-023: per-entry tolerance lives in SkillsKit, which needs this to
        // throw for the single bad entry so it can skip just that one.
        let wire = #"{"id":"x","name":"X"}"#

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SkillDescriptor.self, from: Data(wire.utf8))
        }
    }
}

import Foundation
import Testing

@testable import SkillsKit

import LocalisModels

@Suite("SkillParser")
struct SkillParserTests {
    @Test("parses a bare skill with no arguments")
    func parsesBareSkill() {
        let invocation = SkillParser.parse("/review")

        #expect(invocation == SkillParser.Invocation(skillID: "review", arguments: ""))
    }

    @Test("parses a skill with arguments")
    func parsesSkillWithArguments() {
        let invocation = SkillParser.parse("/review  the auth module ")

        #expect(invocation?.skillID == "review")
        #expect(invocation?.arguments == "the auth module")
    }

    @Test("returns nil for prose and bare slashes", arguments: ["hello", "", "   ", "/", "/ "])
    func rejectsNonInvocations(_ input: String) {
        #expect(SkillParser.parse(input) == nil)
    }

    @Test("matching is case-insensitive on the prefix")
    func matchesCaseInsensitively() {
        let backendID = "claude-sonnet"
        let skills = [
            Skill(id: "review", summary: "Review code", backendID: backendID),
            Skill(id: "refactor", summary: "Refactor code", backendID: backendID),
            Skill(id: "test", summary: "Write tests", backendID: backendID)
        ]

        #expect(SkillParser.matches(prefix: "RE", in: skills).map(\.id) == ["review", "refactor"])
        #expect(SkillParser.matches(prefix: "", in: skills).count == 3)
        #expect(SkillParser.matches(prefix: "zzz", in: skills).isEmpty)
    }
}

@Suite("Skill")
struct SkillTests {
    @Test("invocation prefixes the id with a slash")
    func invocationFormat() {
        let skill = Skill(id: "review", summary: "Review code", backendID: "claude-sonnet")

        #expect(skill.invocation == "/review")
    }
}

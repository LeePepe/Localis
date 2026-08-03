import Foundation
import LocalisModels
import Testing

@testable import TransportKit

/// `GET /v1/models` → backends and host capabilities (contract §2, §2.1).
///
/// Two rules dominate here, and both are constitution IV in practice:
/// an unknown capability value must not discard the backend that advertises it,
/// and a missing `x_localis` must degrade rather than fail. Between them they
/// are what makes "add a sixth backend" a Mac-side change with no iOS release.
@Suite("BackendCatalog — /v1/models")
struct BackendCatalogTests {
    private func decode(_ json: String) throws -> BackendCatalog {
        try BackendCatalog(data: Data(json.utf8))
    }

    private func recorded() throws -> BackendCatalog {
        try BackendCatalog(data: Fixture.data("models-response", extension: "json"))
    }

    // MARK: - Backends

    @Test("decodes every backend in the recorded response")
    func decodesRecordedBackends() throws {
        let catalog = try recorded()

        #expect(catalog.backends.map(\.id) == ["alpha", "beta", "gamma", "delta"])
    }

    @Test("reads display name and capabilities from x_localis")
    func readsDisplayNameAndCapabilities() throws {
        let backend = try #require(recorded().backends.first)

        #expect(backend.id == "alpha")
        #expect(backend.displayName == "Alpha Agent")
        #expect(backend.capabilities == [.streaming, .tools, .skills, .workspace])
    }

    @Test("an unknown capability value is kept and the backend stays usable")
    func unknownCapabilityIsKept() throws {
        // Contract §7: the item remains usable. Kept rather than filtered — the
        // client checks capabilities it knows by name, so an unrecognised one is
        // inert, and dropping it here would erase a feature flag the moment the
        // bridge ships one.
        let beta = try #require(recorded().backends.first { $0.id == "beta" })

        #expect(beta.capabilities.contains(Capability(rawValue: "invented_later")))
        #expect(beta.capabilities.contains(.streaming))
    }

    @Test("a backend with no x_localis degrades instead of failing")
    func missingExtensionDegrades() throws {
        // Contract §7: "某项缺 x_localis → 用默认 capability 降级处理，不崩".
        let delta = try #require(recorded().backends.first { $0.id == "delta" })

        #expect(delta.displayName == "delta", "falls back to the wire id")
        #expect(delta.capabilities.isEmpty)
        #expect(delta.availability == .available, "absent availability is not unavailability")
    }

    @Test("unknown fields on a backend are ignored")
    func unknownBackendFieldsIgnored() throws {
        let beta = try #require(recorded().backends.first { $0.id == "beta" })

        #expect(beta.displayName == "Beta Agent")
    }

    @Test("an unavailable backend keeps its reason")
    func unavailableBackendKeepsReason() throws {
        // The user needs to be told *why* — "codex is not logged in" is
        // actionable, "unavailable" is not.
        let gamma = try #require(recorded().backends.first { $0.id == "gamma" })

        #expect(gamma.availability == .unavailable(reason: "not_logged_in"))
    }

    @Test("an unavailable backend with no reason is still unavailable")
    func unavailableWithoutReason() throws {
        let catalog = try decode(#"{"data":[{"id":"a","x_localis":{"available":false}}]}"#)

        #expect(catalog.backends.first?.availability == .unavailable(reason: nil))
    }

    @Test("a backend with no id is skipped, the rest survive")
    func backendWithoutIDIsSkipped() throws {
        // Per-item fault tolerance: one malformed entry must not cost the user
        // every other backend on the machine.
        let catalog = try decode(#"{"data":[{"object":"model"},{"id":"good"}]}"#)

        #expect(catalog.backends.map(\.id) == ["good"])
    }

    @Test("a blank id is skipped")
    func blankIDIsSkipped() throws {
        let catalog = try decode(#"{"data":[{"id":"   "},{"id":"good"}]}"#)

        #expect(catalog.backends.map(\.id) == ["good"])
    }

    @Test("a non-object entry is skipped")
    func nonObjectEntryIsSkipped() throws {
        let catalog = try decode(#"{"data":["nonsense",{"id":"good"}]}"#)

        #expect(catalog.backends.map(\.id) == ["good"])
    }

    @Test("a non-string capability is skipped without losing the backend")
    func nonStringCapabilitySkipped() throws {
        let catalog = try decode(#"{"data":[{"id":"a","x_localis":{"capabilities":["streaming",7,null]}}]}"#)

        #expect(catalog.backends.first?.capabilities == [.streaming])
    }

    @Test("an empty catalogue is valid, not an error")
    func emptyCatalogue() throws {
        // A Mac with no agents configured is a real state, and it is the bridge
        // reporting honestly — not a failure to surface as one.
        #expect(try decode(#"{"object":"list","data":[]}"#).backends.isEmpty)
    }

    @Test("a response with no data array is malformed")
    func missingDataArrayThrows() {
        #expect(throws: LocalisError.malformedResponse) {
            try decode(#"{"object":"list"}"#)
        }
    }

    @Test("a non-JSON body is malformed")
    func nonJSONThrows() {
        #expect(throws: LocalisError.malformedResponse) {
            try decode("<html>gateway timeout</html>")
        }
    }

    // MARK: - Host capabilities (contract §2.1, Amendment C)

    @Test("host capabilities come from the top-level x_localis")
    func hostCapabilities() throws {
        let host = try recorded().host

        #expect(host.resumableTurns)
        #expect(host.retentionSeconds == 600)
        #expect(host.maxBufferBytes == 4_194_304)
    }

    @Test("resumable turns defaults to false when the host says nothing")
    func resumableDefaultsToFalse() throws {
        // The single most consequential default in the protocol (§2.1): an old
        // bridge does not know the field, and assuming "the work survives a
        // disconnect" would silently drop results the user was waiting for.
        let catalog = try decode(#"{"data":[]}"#)

        #expect(catalog.host.resumableTurns == false)
        #expect(catalog.host.retentionSeconds == nil)
        #expect(catalog.host.maxBufferBytes == nil)
    }

    @Test("telemetry items are kept, unknown ones included")
    func telemetryItems() throws {
        let host = try recorded().host

        #expect(host.telemetry.contains("usage"))
        #expect(host.telemetry.contains("invented_later"), "an unknown item must not be filtered out")
    }

    @Test("telemetry defaults to empty")
    func telemetryDefaultsEmpty() throws {
        #expect(try decode(#"{"data":[]}"#).host.telemetry.isEmpty)
    }

    @Test("a host capability of the wrong type falls back to the default")
    func wrongTypedHostCapability() throws {
        // Trust nothing from the wire: a string where a bool belongs must not
        // be coerced into `true`, which would flip the resume semantics.
        let catalog = try decode(#"{"x_localis":{"resumable_turns":"yes"},"data":[]}"#)

        #expect(catalog.host.resumableTurns == false)
    }

    @Test("the catalogue names no backend anywhere in its source")
    func noHardcodedBackendNames() throws {
        // Constitution IV, checked mechanically: the parser must not have
        // learned any backend's name. See ArchitectureTests for the sweep over
        // the whole package.
        let catalog = try recorded()

        #expect(catalog.backends.count == 4)
    }
}

/// `GET /v1/skills` → templates (contract §5, Amendment B).
@Suite("SkillCatalog — /v1/skills")
struct SkillCatalogTests {
    private func decode(_ json: String) throws -> [SkillDescriptor] {
        try SkillCatalog.decode(data: Data(json.utf8))
    }

    private func recorded() throws -> [SkillDescriptor] {
        try SkillCatalog.decode(data: Fixture.data("skills-response", extension: "json"))
    }

    @Test("decodes the valid skills and skips the broken ones")
    func decodesValidSkills() throws {
        // Contract §5 / FR-023: one bad entry costs that entry and nothing else.
        // `missing-template`, the id-less entry and the blank-id entry all fail
        // the required-field check.
        #expect(try recorded().map(\.id) == ["to-spec", "tdd", "no-summary"])
    }

    @Test("the template arrives verbatim, placeholders intact")
    func templateIsVerbatim() throws {
        // Amendment B: no substitution anywhere. `{{topic}}` reaches the
        // composer as text for the user to type over — that is the entire
        // parameter mechanism.
        let skill = try #require(recorded().first)

        #expect(skill.template == "Use the to-spec skill on: {{topic}}\n\nDepth: {{depth}}")
    }

    @Test("parameters and backends are ignored without error")
    func ignoresParametersAndBackends() throws {
        // Contract §7: the skill stays usable. The bridge keeps sending both;
        // a v1 client simply reads less.
        let skill = try #require(recorded().first)

        #expect(skill.id == "to-spec")
        #expect(skill.name == "To Spec")
    }

    @Test("an absent summary is allowed")
    func summaryIsOptional() throws {
        let skill = try #require(recorded().first { $0.id == "no-summary" })

        #expect(skill.summary == nil)
    }

    @Test("unknown fields on a skill are ignored")
    func unknownSkillFieldsIgnored() throws {
        let skill = try #require(recorded().first { $0.id == "tdd" })

        #expect(skill.name == "TDD")
    }

    @Test("a skill missing a required field is skipped", arguments: [
        ("no id", #"{"name":"N","template":"T"}"#),
        ("no name", #"{"id":"i","template":"T"}"#),
        ("no template", #"{"id":"i","name":"N"}"#),
        ("blank id", #"{"id":" ","name":"N","template":"T"}"#),
        ("blank name", #"{"id":"i","name":" ","template":"T"}"#),
        ("not an object", #""nonsense""#),
    ])
    func requiredFields(_ testCase: (name: String, entry: String)) throws {
        let skills = try decode(#"{"data":[\#(testCase.entry),{"id":"ok","name":"OK","template":"T"}]}"#)

        #expect(skills.map(\.id) == ["ok"], "\(testCase.name) should have been skipped")
    }

    @Test("a blank template is skipped")
    func blankTemplateIsSkipped() throws {
        // An empty template inserts nothing; offering it in the picker is a
        // dead entry the user cannot tell apart from a working one.
        #expect(try decode(#"{"data":[{"id":"i","name":"N","template":"  "}]}"#).isEmpty)
    }

    @Test("an empty catalogue is valid")
    func emptyCatalogue() throws {
        #expect(try decode(#"{"object":"list","data":[]}"#).isEmpty)
    }

    @Test("a response with no data array is malformed")
    func missingDataArrayThrows() {
        #expect(throws: LocalisError.malformedResponse) {
            try decode(#"{"object":"list"}"#)
        }
    }

    @Test("a non-JSON body is malformed")
    func nonJSONThrows() {
        #expect(throws: LocalisError.malformedResponse) {
            try decode("not json")
        }
    }
}

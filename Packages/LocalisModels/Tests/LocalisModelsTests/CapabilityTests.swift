import Foundation
import Testing

@testable import LocalisModels

/// Contract §2: the capability list is a **named** set that the client must not
/// treat as closed — "客户端必须忽略未知值，不得因此丢弃整项". Both halves of that
/// sentence are load-bearing, and these tests hold each of them separately.
@Suite("Capability")
struct CapabilityTests {
    @Test("the named capabilities carry their wire spelling")
    func namedCapabilitiesMatchWire() {
        // The wire uses snake_case; Swift uses camelCase. Doing the conversion
        // inside the type means no caller has to remember which side it is on.
        #expect(Capability.streaming.rawValue == "streaming")
        #expect(Capability.tools.rawValue == "tools")
        #expect(Capability.skills.rawValue == "skills")
        #expect(Capability.workspace.rawValue == "workspace")
        #expect(Capability.requiresNetwork.rawValue == "requires_network")
    }

    @Test("an unrecognised capability is preserved, not discarded")
    func unknownCapabilityIsPreserved() {
        // Constitution IV: a new backend capability must not need an iOS
        // release. A closed enum would fail to decode here and take the whole
        // backend down with it — which the contract explicitly forbids.
        let unknown = Capability(rawValue: "vision")

        #expect(unknown.rawValue == "vision")
        #expect(unknown != Capability.streaming)
    }

    @Test("known and unknown capabilities compare by wire value")
    func equalityIsByRawValue() {
        #expect(Capability(rawValue: "streaming") == Capability.streaming)
        #expect(Capability(rawValue: "vision") == Capability(rawValue: "vision"))
    }

    @Test("round-trips through Codable as a bare string")
    func codesAsBareString() throws {
        // It has to encode as the wire spelling, not as {"rawValue": "..."},
        // or a stored backend list stops matching what /v1/models sends.
        let data = try JSONEncoder().encode(Capability.tools)

        #expect(String(data: data, encoding: .utf8) == "\"tools\"")
        #expect(try JSONDecoder().decode(Capability.self, from: data) == .tools)
    }

    @Test("isKnown distinguishes the documented set without rejecting the rest")
    func isKnownFlagsUndocumented() {
        // Useful for deciding whether the UI can render an icon for it — but
        // never for deciding whether to keep it.
        #expect(Capability.streaming.isKnown)
        #expect(!Capability(rawValue: "vision").isKnown)
    }
}

/// `AgentBackend` moving from `Set<String>` to `Set<Capability>`.
@Suite("AgentBackend capabilities are typed")
struct AgentBackendCapabilityTests {
    @Test("supports takes a named capability")
    func supportsIsTyped() {
        // The point of the change: a typo like `.steaming` is a compile error,
        // where `"steaming"` silently returned false forever.
        let backend = AgentBackend(
            id: "claude", displayName: "Claude",
            capabilities: [.streaming, .tools]
        )

        #expect(backend.supports(.streaming))
        #expect(backend.supports(.tools))
        #expect(!backend.supports(.workspace))
    }

    @Test("an unknown capability from the wire survives on the backend")
    func unknownCapabilitySurvivesOnBackend() {
        // A bridge advertising a capability this build has never heard of must
        // still produce a usable backend — not a decode failure, and not a
        // backend silently missing from the picker.
        let backend = AgentBackend(
            id: "claude", displayName: "Claude",
            capabilities: [.streaming, Capability(rawValue: "vision")]
        )

        #expect(backend.supports(Capability(rawValue: "vision")))
        #expect(backend.supports(.streaming))
    }

    @Test("a backend decodes even when the wire lists capabilities we don't know")
    func decodingKeepsUnknownCapabilities() throws {
        // This is the contract's "不得因此丢弃整项" as an executable test.
        let wire = """
        {"id":"claude","displayName":"Claude",
         "capabilities":["streaming","vision","requires_network"]}
        """.data(using: .utf8)!

        let backend = try JSONDecoder().decode(AgentBackend.self, from: wire)

        #expect(backend.supports(.streaming))
        #expect(backend.supports(.requiresNetwork))
        #expect(backend.supports(Capability(rawValue: "vision")))
        #expect(backend.capabilities.count == 3)
    }

    @Test("a backend with no capabilities supports nothing")
    func emptyCapabilitiesSupportNothing() {
        let bare = AgentBackend(id: "bare", displayName: "Bare")

        #expect(bare.capabilities.isEmpty)
        #expect(!bare.supports(.streaming))
    }
}

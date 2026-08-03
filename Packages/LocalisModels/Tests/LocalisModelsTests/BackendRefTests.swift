import Foundation
import Testing

@testable import LocalisModels

/// FR-029: the globally unique key for a backend is the composite
/// `(hostID, backendID)`. Amendment A §1.1 rejected the synthesised-UUID and
/// namespaced-string alternatives; the reasoning is reproduced in the tests
/// that would break if someone reintroduced them.
@Suite("BackendRef")
struct BackendRefTests {
    private static let hostA = HostID()
    private static let hostB = HostID()

    @Test("the same backend name on two hosts is two different backends")
    func sameNameOnDifferentHostsIsDistinct() {
        // SC-010: cross-host bleed must be zero. Both machines advertise a
        // backend literally called "claude"; nothing may treat them as one.
        let onA = BackendRef(hostID: Self.hostA, backendID: "claude")
        let onB = BackendRef(hostID: Self.hostB, backendID: "claude")

        #expect(onA != onB)
        #expect(Set([onA, onB]).count == 2)
    }

    @Test("equality needs both halves to match")
    func equalityRequiresBothComponents() {
        let ref = BackendRef(hostID: Self.hostA, backendID: "claude")

        #expect(ref == BackendRef(hostID: Self.hostA, backendID: "claude"))
        #expect(ref != BackendRef(hostID: Self.hostA, backendID: "codex"))
        #expect(ref != BackendRef(hostID: Self.hostB, backendID: "claude"))
    }

    @Test("the backend id stays the wire string from /v1/models")
    func backendIDIsTheWireString() {
        // Constitution IV: a backend is data read off the wire, not client
        // state. Synthesising a local UUID here would make iOS maintain a
        // registry to translate ids back — and that registry cannot survive a
        // bridge reinstall (Amendment A §1.1).
        let ref = BackendRef(hostID: Self.hostA, backendID: "claude")

        #expect(ref.backendID == "claude")
    }

    @Test("a ref is built by qualifying a backend with its host")
    func qualifyingABackendProducesARef() {
        let backend = AgentBackend(id: "codex", displayName: "Codex", capabilities: [.streaming])

        let ref = backend.ref(on: Self.hostA)

        #expect(ref == BackendRef(hostID: Self.hostA, backendID: "codex"))
    }

    @Test("a ref matches a backend only on the host it came from")
    func matchesIsHostQualified() {
        // The silent failure mode Amendment A §1.1 warns about: a lookup that
        // compares backend ids alone will happily return the other machine's
        // backend. `matches` exists so callers cannot express that mistake.
        let backend = AgentBackend(id: "claude", displayName: "Claude")
        let ref = BackendRef(hostID: Self.hostA, backendID: "claude")

        #expect(ref.matches(backend, on: Self.hostA))
        #expect(!ref.matches(backend, on: Self.hostB))
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        let ref = BackendRef(hostID: Self.hostA, backendID: "claude")

        let decoded = try JSONDecoder().decode(
            BackendRef.self,
            from: try JSONEncoder().encode(ref)
        )

        #expect(decoded == ref)
    }

    @Test("AgentBackend stays a capability descriptor, not an enum")
    func backendRemainsCapabilityData() {
        // Guards the e17c2f1 refactor: a closed enum here would mean every new
        // agent needs an App Store release (constitution IV).
        let sixth = AgentBackend(id: "brand-new-agent", displayName: "New", capabilities: [.streaming])

        #expect(sixth.supports(.streaming))
        #expect(!sixth.supports(.workspace))
    }
}

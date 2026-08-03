import Foundation
import Testing

@testable import LocalisModels

/// Contract §2 `x_localis`: `available` / `unavailable_reason`.
///
/// Without these the picker can only show a backend as present or absent, and
/// the user gets no way to tell "codex is not logged in" from "codex is gone".
@Suite("AgentBackend availability")
struct AgentBackendAvailabilityTests {
    @Test("a backend is available unless the bridge says otherwise")
    func defaultsToAvailable() {
        // The field is optional in the contract, and the safe default for a
        // missing one is available — an older bridge that never sends it must
        // not have all its backends greyed out.
        let backend = AgentBackend(id: "claude", displayName: "Claude")

        #expect(backend.isAvailable)
        #expect(backend.unavailableReason == nil)
    }

    @Test("an unavailable backend carries the reason code")
    func unavailableCarriesReason() {
        let backend = AgentBackend(
            id: "codex",
            displayName: "Codex",
            availability: .unavailable(reason: "not_logged_in")
        )

        #expect(!backend.isAvailable)
        #expect(backend.unavailableReason == "not_logged_in")
    }

    @Test("an unknown reason code is carried, not dropped")
    func unknownReasonIsCarried() {
        // Constitution IV: the reason set is open. A code this build has never
        // seen still round-trips, so a bridge can add one without an iOS release.
        let backend = AgentBackend(
            id: "hermes",
            displayName: "Hermes",
            availability: .unavailable(reason: "region_locked")
        )

        #expect(backend.unavailableReason == "region_locked")
    }

    @Test("availability is a separate axis from capabilities")
    func availabilityDoesNotAffectCapabilities() {
        // A logged-out backend still advertises what it *can* do. Conflating the
        // two would make an unavailable backend look incapable, and the
        // capability set would then change under the user on re-login.
        let backend = AgentBackend(
            id: "codex",
            displayName: "Codex",
            capabilities: [.streaming, .tools],
            availability: .unavailable(reason: "not_logged_in")
        )

        #expect(backend.supports(.streaming))
        #expect(backend.supports(.tools))
        #expect(!backend.isAvailable)
    }

    @Test("changing availability keeps identity and capabilities")
    func withAvailabilityIsImmutable() {
        let original = AgentBackend(
            id: "codex",
            displayName: "Codex",
            capabilities: [.streaming],
            availability: .unavailable(reason: "not_logged_in")
        )

        let recovered = original.withAvailability(.available)

        #expect(recovered.isAvailable)
        #expect(recovered.id == original.id)
        #expect(recovered.capabilities == original.capabilities)
        #expect(!original.isAvailable)
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        let backend = AgentBackend(
            id: "codex",
            displayName: "Codex",
            capabilities: [.streaming],
            availability: .unavailable(reason: "not_logged_in")
        )

        let data = try JSONEncoder().encode(backend)
        let decoded = try JSONDecoder().decode(AgentBackend.self, from: data)

        #expect(decoded == backend)
    }

    @Test("a backend stored before availability existed still decodes")
    func decodesPayloadWithoutAvailability() throws {
        // SessionStore has rows written before this field existed. Failing to
        // decode them would lose the user's backend list on upgrade.
        let json = #"{"id":"claude","displayName":"Claude","capabilities":["streaming"]}"#

        let decoded = try JSONDecoder().decode(AgentBackend.self, from: Data(json.utf8))

        #expect(decoded.isAvailable)
        #expect(decoded.id == "claude")
    }
}

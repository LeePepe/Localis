import Foundation
import Testing

@testable import LocalisModels

/// The step that turns a machine seen on the network into a machine we have a
/// record of.
///
/// It had no home before B-1. `DiscoveredHost` was public, `LocalisHost.init`
/// was public, and nothing anywhere converted one into the other — so the whole
/// pairing story was reachable symbol by symbol and impossible to walk end to
/// end. A package can have every public symbol referenced somewhere and still
/// not be able to do the one thing it exists for; "is it imported" and "is the
/// symbol used" both answer yes in exactly that situation.
///
/// These tests are about what the newly-created host is *allowed to claim*. The
/// advertisement is unauthenticated — anything on the LAN can broadcast any
/// name, any bridge id, any protocol number — so the interesting assertions are
/// all about what does **not** carry across.
@Suite("Adopting a discovered host")
struct HostAdoptionTests {
    /// A stand-in advertisement.
    ///
    /// This suite tests the *rule*, which lives here; that `DiscoveredHost`
    /// actually conforms is asserted in TransportKit, where that type lives. A
    /// conformance proven only by a stub is the wiring defect again — the rule
    /// would be right and unreachable.
    private struct StubAdvertisement: HostAdvertisement {
        var displayName: String
        var endpoint: HostEndpoint
        var bridgeID: String?
        var advertisedProtocol: Int?
    }

    private static func discovered(
        name: String = "Tian's MacBook Pro",
        endpoint: HostEndpoint = HostEndpoint(host: "mac.local", port: 8443),
        bridgeID: String? = "bridge-abc",
        advertisedProtocol: Int? = 1
    ) -> StubAdvertisement {
        StubAdvertisement(
            displayName: name,
            endpoint: endpoint,
            bridgeID: bridgeID,
            advertisedProtocol: advertisedProtocol
        )
    }

    @Test("adoption produces a host that is not yet paired")
    func adoptedHostStartsDiscovered() {
        let host = LocalisHost(adopting: Self.discovered())

        // The single most important assertion in this file. An advertisement is
        // a claim by an unauthenticated stranger; if adoption could yield
        // `.paired`, anything on the network could install itself as a trusted
        // machine by broadcasting.
        #expect(host.pairingState == .discovered)
    }

    @Test("adoption never carries a pin")
    func adoptedHostHasNoPin() {
        let host = LocalisHost(adopting: Self.discovered())

        // A pin may only come from a certificate presented on a real connection
        // (FR-028). There is no such connection yet at adoption time, so there
        // is nothing a pin here could have been derived from.
        #expect(host.pinnedSPKI == nil)
        // …and therefore the host must be unable to open a connection.
        #expect(host.canConnect == false)
    }

    @Test("each adoption mints a fresh local identity")
    func adoptionMintsNewIdentity() {
        // Identity is locally generated and never derived from anything on the
        // wire (FR-026). Deriving it from `bridgeID` would let a machine choose
        // its own id — and choosing someone else's is then equally available.
        let first = LocalisHost(adopting: Self.discovered())
        let second = LocalisHost(adopting: Self.discovered())

        #expect(first.id != second.id)
    }

    @Test("the advertised name, endpoint and bridge id do carry across")
    func advertisedAttributesCarry() {
        let host = LocalisHost(adopting: Self.discovered(
            name: "Studio",
            endpoint: HostEndpoint(host: "studio.local", port: 9000),
            bridgeID: "bridge-xyz"
        ))

        // These are attributes, not identity, which is exactly why they are
        // safe to take from an unauthenticated source: being wrong about them
        // is a wrong label or a failed connection, not a false trust decision.
        #expect(host.displayName == "Studio")
        #expect(host.endpoint == HostEndpoint(host: "studio.local", port: 9000))
        #expect(host.bridgeID == "bridge-xyz")
    }

    @Test("a bridge that advertises no protocol version is assumed to be v1")
    func missingProtocolDefaultsToOne() {
        // Amendment A §1.6: the field is additive and optional. Refusing to
        // adopt a bridge that predates it would make the app unable to see a
        // machine it can in fact talk to.
        let host = LocalisHost(adopting: Self.discovered(advertisedProtocol: nil))

        #expect(host.protocolVersion == 1)
    }

    @Test("an advertised protocol version is recorded, not negotiated")
    func advertisedProtocolIsRecorded() {
        // Recorded so the mismatch can be *reported* (FR-032). Adoption is not
        // where a version is refused: a host we refuse to record is a host the
        // user cannot see and therefore cannot be told about.
        let host = LocalisHost(adopting: Self.discovered(advertisedProtocol: 7))

        #expect(host.protocolVersion == 7)
    }

    @Test("adoption is pure — the same facts twice differ only by identity")
    func adoptionIsPureApartFromIdentity() {
        let facts = Self.discovered()
        let first = LocalisHost(adopting: facts)
        let second = LocalisHost(adopting: facts)

        // Guards against a future `adopting` that reaches for the clock, the
        // network or stored state. Everything except the minted id must be a
        // function of the facts alone.
        #expect(first.displayName == second.displayName)
        #expect(first.endpoint == second.endpoint)
        #expect(first.bridgeID == second.bridgeID)
        #expect(first.pairingState == second.pairingState)
        #expect(first.protocolVersion == second.protocolVersion)
        #expect(first.pinnedSPKI == second.pinnedSPKI)
    }

    @Test("an adopted host can be carried through pairing to a connectable one")
    func adoptionReachesAConnectableHost() {
        // The end-to-end shape B-1 exists to make possible: discovered →
        // pairing → paired-and-pinned. Asserted here because every individual
        // transition already had a passing test while the *sequence* could not
        // be started at all.
        let adopted = LocalisHost(adopting: Self.discovered())
        let paired = adopted.beginningPairing().paired(pinning: SPKIHash(base64: "AAA="))

        #expect(paired.canConnect)
        // Identity survives the whole walk — that is what makes history stick
        // to one machine (FR-026).
        #expect(paired.id == adopted.id)
    }
}

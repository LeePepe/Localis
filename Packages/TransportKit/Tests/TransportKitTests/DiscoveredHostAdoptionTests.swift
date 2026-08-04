import Foundation
import LocalisModels
import Testing

@testable import TransportKit

/// The join between "a Mac appeared on the network" and "we have a record of
/// it".
///
/// `HostAdoptionTests` in LocalisModels proves the rule, but every case there
/// runs against a stub advertisement. A stub-only proof is the wiring defect in
/// miniature: the rule would be correct and nothing real could reach it. These
/// tests exist to be the ones that go red if `DiscoveredHost` stops conforming,
/// and they walk the full path — Bonjour TXT record in, persistable host out.
@Suite("Adopting a real discovered host")
struct DiscoveredHostAdoptionTests {
    @Test("a host parsed from a Bonjour advertisement can be adopted")
    func bonjourAdvertisementAdopts() throws {
        // Built through the real parser rather than the memberwise init: the
        // path under test starts at the wire, and a hand-built value would skip
        // the part most likely to drift.
        let discovered = try #require(DiscoveredHost(service: BonjourService(
            name: "Tian's MacBook Pro",
            host: "mac.local",
            port: 8443,
            txt: ["v": "1", "name": "Tian's MacBook Pro", "hid": "bridge-abc"]
        )))

        let host = LocalisHost(adopting: discovered)

        #expect(host.displayName == discovered.displayName)
        #expect(host.endpoint == discovered.endpoint)
        #expect(host.bridgeID == discovered.bridgeID)
        // The claims that must not survive the crossing. An advertisement is
        // unauthenticated, so adoption yielding anything connectable would let
        // a broadcast install a trusted machine.
        #expect(host.pairingState == .discovered)
        #expect(host.pinnedSPKI == nil)
        #expect(host.canConnect == false)
    }

    @Test("a manually entered address can be adopted the same way")
    func manualEntryAdopts() throws {
        // Manual entry is not a privileged path. If it produced a host that
        // skipped pairing, typing an address would be a way around pinning.
        // The scheme is required — `EndpointValidator` is HTTPS-only, and a
        // manual field is the obvious place a plaintext fallback would reappear.
        let discovered = try DiscoveredHost(manualEndpoint: "https://studio.local:9000")

        let host = LocalisHost(adopting: discovered)

        #expect(host.endpoint == discovered.endpoint)
        #expect(host.pairingState == .discovered)
        #expect(host.canConnect == false)
    }

    @Test("a bridge advertising no version is adopted as v1")
    func missingVersionAdoptsAsOne() throws {
        // `DiscoveredHost` deliberately keeps this nil rather than defaulting —
        // a fabricated version would later be compared against as though the
        // bridge had stated it. The default belongs at adoption, and this test
        // is what holds the two halves of that decision together.
        let discovered = try #require(DiscoveredHost(service: BonjourService(
            name: "Old Bridge",
            host: "old.local",
            port: 8443,
            txt: ["name": "Old Bridge"]
        )))
        #expect(discovered.advertisedProtocol == nil)

        #expect(LocalisHost(adopting: discovered).protocolVersion == 1)
    }

    @Test("adoption feeds recognition, which is what makes a second sighting a relocation")
    func adoptedHostIsRecognisedOnASecondSighting() throws {
        // The reason adoption has to mint a *stable* local id. Sighting the
        // same machine at a new address must resolve to the host we already
        // have, not to a second record — that is what keeps history attached to
        // one machine (FR-026).
        let first = try #require(DiscoveredHost(service: BonjourService(
            name: "Tian's MacBook Pro",
            host: "mac.local",
            port: 8443,
            txt: ["v": "1", "name": "Tian's MacBook Pro", "hid": "bridge-abc"]
        )))
        let pin = SPKIHash(base64: "AAA=")
        let known = LocalisHost(adopting: first).beginningPairing().paired(pinning: pin)

        // Same machine, new address after a DHCP renewal.
        let again = try #require(DiscoveredHost(service: BonjourService(
            name: "Tian's MacBook Pro",
            host: "192.168.1.42",
            port: 8443,
            txt: ["v": "1", "name": "Tian's MacBook Pro", "hid": "bridge-abc"]
        )))

        #expect(again.recognised(presenting: pin, among: [known]) == .trusted(known.id))
    }
}

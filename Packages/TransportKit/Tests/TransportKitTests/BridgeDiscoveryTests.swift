import Foundation
import LocalisModels
import Testing

@testable import TransportKit

/// Bonjour discovery and the manual-address channel (FR-001, FR-031, T024/T095).
///
/// Discovery is the one place in this package that sees more than one machine,
/// and it is deliberately the *only* one: it emits hosts one at a time and keeps
/// no collection, no registry and no notion of a "current" host. Everything
/// above assembles the list; a client is still built for one host.
///
/// The failures under test are the quiet ones. A bridge that changed address
/// and is not recognised makes the user re-pair a machine that never changed —
/// annoying but visible. A bridge that is recognised when it should not be
/// merges two machines into one, and *nothing looks wrong*.
@Suite("BridgeDiscovery")
struct BridgeDiscoveryTests {
    // MARK: - TXT parsing

    @Test("a full TXT record yields name, protocol and bridge id")
    func parsesFullRecord() throws {
        let service = BonjourService(
            name: "fallback-name",
            host: "mac.local",
            port: 8443,
            txt: ["v": "1", "name": "Tian's MacBook Pro", "hid": "bridge-abc"]
        )

        let host = try #require(DiscoveredHost(service: service))

        #expect(host.displayName == "Tian's MacBook Pro")
        #expect(host.advertisedProtocol == 1)
        #expect(host.bridgeID == "bridge-abc")
        #expect(host.endpoint == HostEndpoint(host: "mac.local", port: 8443))
        #expect(host.source == .bonjour)
    }

    @Test("an older bridge without hid still discovers")
    func hidIsOptional() throws {
        // Amendment A §1.6: `hid` is an additive optional. A bridge that omits
        // it must remain fully usable — the client falls back to SPKI matching.
        let service = BonjourService(
            name: "fallback-name",
            host: "mac.local",
            port: 8443,
            txt: ["v": "1", "name": "Old Bridge"]
        )

        let host = try #require(DiscoveredHost(service: service))

        #expect(host.bridgeID == nil)
        #expect(host.displayName == "Old Bridge")
    }

    @Test("a missing name falls back to the service name")
    func nameFallsBackToServiceName() throws {
        let service = BonjourService(name: "service-name", host: "mac.local", port: 8443, txt: ["v": "1"])

        #expect(DiscoveredHost(service: service)?.displayName == "service-name")
    }

    @Test("a blank name falls back rather than showing an empty row")
    func blankNameFallsBack() throws {
        let service = BonjourService(name: "service-name", host: "mac.local", port: 8443, txt: ["name": "   "])

        #expect(DiscoveredHost(service: service)?.displayName == "service-name")
    }

    @Test("unknown TXT keys are ignored, not rejected")
    func unknownKeysIgnored() throws {
        // Forward compatibility: a future bridge adding a key must not make
        // itself invisible to an older client.
        let service = BonjourService(
            name: "n",
            host: "mac.local",
            port: 8443,
            txt: ["v": "1", "name": "Mac", "hid": "x", "future": "whatever"]
        )

        #expect(DiscoveredHost(service: service)?.displayName == "Mac")
    }

    @Test("an unparseable protocol version is absent, not zero")
    func badProtocolIsAbsent() throws {
        // Zero would read as "protocol 0" and could satisfy a minimum-version
        // comparison written as `>= 0`. Absent forces the caller to ask.
        let service = BonjourService(name: "n", host: "mac.local", port: 8443, txt: ["v": "not-a-number"])

        #expect(DiscoveredHost(service: service)?.advertisedProtocol == nil)
    }

    @Test("a blank hid is treated as absent")
    func blankHidIsAbsent() throws {
        // An empty string would compare equal to another empty string and merge
        // two unrelated machines through `HostRecognition`.
        let service = BonjourService(name: "n", host: "mac.local", port: 8443, txt: ["hid": ""])

        #expect(DiscoveredHost(service: service)?.bridgeID == nil)
    }

    @Test("a service with no host is dropped", arguments: ["", "   "])
    func hostlessServiceDropped(_ host: String) {
        #expect(DiscoveredHost(service: BonjourService(name: "n", host: host, port: 8443, txt: [:])) == nil)
    }

    @Test("a service with an impossible port is dropped", arguments: [0, -1, 65_536])
    func badPortDropped(_ port: Int) {
        #expect(DiscoveredHost(service: BonjourService(name: "n", host: "mac.local", port: port, txt: [:])) == nil)
    }

    // MARK: - Manual entry (FR-001)

    @Test("a manually typed https address becomes a discovered host")
    func manualEndpointAccepted() throws {
        // The Tailscale / custom-port case: the machine is reachable but not on
        // a network where multicast works.
        let host = try DiscoveredHost(manualEndpoint: "https://mac.tailnet.ts.net:8443")

        #expect(host.endpoint == HostEndpoint(host: "mac.tailnet.ts.net", port: 8443))
        #expect(host.source == .manual)
        #expect(host.bridgeID == nil, "a typed address carries no bridge identity")
    }

    @Test("a manual address without a port uses the https default")
    func manualEndpointDefaultsPort() throws {
        #expect(try DiscoveredHost(manualEndpoint: "https://mac.local").endpoint.port == 443)
    }

    @Test("a plaintext address is refused", arguments: [
        "http://mac.local:8443",
        "http://192.168.1.10",
        "HTTP://mac.local",
    ])
    func manualPlaintextRefused(_ text: String) {
        // Constitution V: no plaintext path, and the manual field is the obvious
        // way one would be reintroduced.
        #expect(throws: LocalisError.invalidInput(field: "endpoint")) {
            try DiscoveredHost(manualEndpoint: text)
        }
    }

    @Test("a nonsense address is refused", arguments: ["", "   ", "not a url", "ftp://mac.local"])
    func manualGarbageRefused(_ text: String) {
        #expect(throws: LocalisError.invalidInput(field: "endpoint")) {
            try DiscoveredHost(manualEndpoint: text)
        }
    }

    @Test("the display name of a manual host is its address")
    func manualDisplayName() throws {
        // There is no advertised name to use, and inventing one ("New host")
        // makes two manually added machines indistinguishable in the list.
        #expect(try DiscoveredHost(manualEndpoint: "https://mac.local:8443").displayName == "mac.local:8443")
    }

    // MARK: - Streaming

    @Test("every discovered service reaches the stream")
    func streamsDiscoveredServices() async throws {
        let browser = StubBrowser(services: [
            BonjourService(name: "a", host: "a.local", port: 8443, txt: ["name": "Mac A", "hid": "a"]),
            BonjourService(name: "b", host: "b.local", port: 8443, txt: ["name": "Mac B", "hid": "b"]),
        ])
        let discovery = BridgeDiscovery(browser: browser)

        var found: [String] = []
        for await host in discovery.hosts() {
            found.append(host.displayName)
        }

        // Amendment A: discovery sees several machines. It reports each one
        // separately and merges nothing — that decision belongs to the caller.
        #expect(found == ["Mac A", "Mac B"])
    }

    @Test("an unusable service does not end the stream")
    func malformedServiceSkipped() async throws {
        // One bridge advertising badly must not hide the others (boundary
        // validation: one bad item, not a bad batch).
        let browser = StubBrowser(services: [
            BonjourService(name: "bad", host: "", port: 8443, txt: [:]),
            BonjourService(name: "good", host: "b.local", port: 8443, txt: ["name": "Mac B"]),
        ])
        let discovery = BridgeDiscovery(browser: browser)

        var found: [String] = []
        for await host in discovery.hosts() {
            found.append(host.displayName)
        }

        #expect(found == ["Mac B"])
    }

    @Test("the same machine re-advertising at a new address is reported again")
    func readvertisementIsReported() async throws {
        // Not deduplicated: the second sighting *is* the address change, and
        // swallowing it would strand the host at its old endpoint.
        let browser = StubBrowser(services: [
            BonjourService(name: "a", host: "192.168.1.10", port: 8443, txt: ["hid": "a", "name": "Mac"]),
            BonjourService(name: "a", host: "192.168.1.44", port: 8443, txt: ["hid": "a", "name": "Mac"]),
        ])
        let discovery = BridgeDiscovery(browser: browser)

        var endpoints: [String] = []
        for await host in discovery.hosts() {
            endpoints.append(host.endpoint.host)
        }

        #expect(endpoints == ["192.168.1.10", "192.168.1.44"])
    }

    @Test("stopping the browser finishes the stream")
    func stopFinishesStream() async throws {
        let browser = StubBrowser(services: [])
        let discovery = BridgeDiscovery(browser: browser)

        var count = 0
        for await _ in discovery.hosts() { count += 1 }

        #expect(count == 0)
        #expect(await browser.wasStopped, "a browser left running keeps the radio awake")
    }

    // MARK: - Re-identification (FR-031, T095)

    /// The `hid` path: same machine, new address, no re-pairing.
    @Test("a paired host that changed address is recognised")
    func recognisesRelocatedHost() throws {
        let pin = SPKIHash(base64: "AAA=")
        let known = LocalisHost(
            id: HostID(),
            displayName: "Mac",
            endpoint: HostEndpoint(host: "192.168.1.10", port: 8443),
            bridgeID: "bridge-abc",
            pinnedSPKI: pin,
            pairingState: .paired
        )
        let discovered = try #require(DiscoveredHost(service: BonjourService(
            name: "n", host: "192.168.1.44", port: 8443, txt: ["hid": "bridge-abc", "name": "Mac"]
        )))

        #expect(discovered.recognised(presenting: pin, among: [known]) == .trusted(known.id))
    }

    /// The fallback path: an older bridge with no `hid` is still matched.
    @Test("a bridge without hid is matched by its pinned certificate")
    func recognisesByPinWhenHidMissing() throws {
        let pin = SPKIHash(base64: "AAA=")
        let known = LocalisHost(
            id: HostID(),
            displayName: "Mac",
            endpoint: HostEndpoint(host: "192.168.1.10", port: 8443),
            pinnedSPKI: pin,
            pairingState: .paired
        )
        let discovered = try #require(DiscoveredHost(service: BonjourService(
            name: "n", host: "192.168.1.44", port: 8443, txt: ["name": "Mac"]
        )))

        #expect(discovered.recognised(presenting: pin, among: [known]) == .trusted(known.id))
    }

    /// The security case Amendment A calls out explicitly.
    @Test("a clone presenting the same hid from a different key is not merged")
    func clonedBridgeIsNotMerged() throws {
        // A bridge's whole config directory copied to another machine reports
        // the same `hid`. If `hid` won, that machine would inherit the original's
        // trust and history on the strength of a copyable string. Its SPKI
        // differs, and SPKI is the anchor.
        let realPin = SPKIHash(base64: "AAA=")
        let clonePin = SPKIHash(base64: "BBB=")
        let known = LocalisHost(
            id: HostID(),
            displayName: "Mac",
            endpoint: HostEndpoint(host: "192.168.1.10", port: 8443),
            bridgeID: "bridge-abc",
            pinnedSPKI: realPin,
            pairingState: .paired
        )
        let clone = try #require(DiscoveredHost(service: BonjourService(
            name: "n", host: "192.168.1.99", port: 8443, txt: ["hid": "bridge-abc", "name": "Mac"]
        )))

        let outcome = clone.recognised(presenting: clonePin, among: [known])

        #expect(outcome != .trusted(known.id), "a copyable string must not confer another machine's trust")
        #expect(outcome == .untrusted(known.id))
    }

    @Test("a machine we have never seen is unknown")
    func unknownHostIsUnknown() throws {
        let discovered = try #require(DiscoveredHost(service: BonjourService(
            name: "n", host: "new.local", port: 8443, txt: ["hid": "brand-new"]
        )))

        #expect(discovered.recognised(presenting: SPKIHash(base64: "CCC="), among: []) == .unknown)
    }

    @Test("recognition offers no way to accept a mismatched certificate")
    func recognitionHasNoOverride() throws {
        // Constitution V, stated where the discovery flow would be tempted to
        // add one: the outcome is a fact, not a suggestion the caller can waive.
        let known = LocalisHost(
            id: HostID(),
            displayName: "Mac",
            endpoint: HostEndpoint(host: "192.168.1.10", port: 8443),
            bridgeID: "bridge-abc",
            pinnedSPKI: SPKIHash(base64: "AAA="),
            pairingState: .paired
        )
        let discovered = try #require(DiscoveredHost(service: BonjourService(
            name: "n", host: "192.168.1.10", port: 8443, txt: ["hid": "bridge-abc"]
        )))

        let outcome = discovered.recognised(presenting: SPKIHash(base64: "ZZZ="), among: [known])

        #expect(outcome == .untrusted(known.id))
        // A discovered host carries no trust of its own: it has no `canConnect`,
        // no "accept" and no pin of its own to compare against. The only way to
        // reach a connectable state is to pair again, which re-pins.
        #expect(outcome != .trusted(known.id))
    }
}

/// A browser that replays a fixed list and then finishes.
///
/// The real one wraps `NWBrowser`, which needs a live multicast network and a
/// bridge on it — untestable in CI, and the parts worth testing (TXT parsing,
/// skipping, recognition) are all on this side of the seam.
private actor StubBrowser: BridgeBrowser {
    private let queue: [BonjourService]
    private(set) var wasStopped = false

    init(services: [BonjourService]) {
        self.queue = services
    }

    func services() async -> AsyncStream<BonjourService> {
        AsyncStream { continuation in
            for service in queue {
                continuation.yield(service)
            }
            continuation.finish()
        }
    }

    func stop() async {
        wasStopped = true
    }
}

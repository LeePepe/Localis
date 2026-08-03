import Foundation
import Testing

@testable import LocalisModels

@Suite("Host")
struct HostTests {
    private static func makeDiscovered() -> LocalisHost {
        LocalisHost(
            id: HostID(),
            displayName: "Studio",
            endpoint: HostEndpoint(host: "studio.local", port: 8443),
            bridgeID: "bridge-abc",
            pinnedSPKI: nil,
            pairingState: .discovered,
            protocolVersion: 1,
            kind: .mac
        )
    }

    private static func makePaired() -> LocalisHost {
        makeDiscovered().paired(pinning: SPKIHash(base64: "AAAA"))
    }

    @Test("identity survives every attribute change")
    func identityIsStableAcrossAttributeChanges() {
        // FR-026: endpoint / displayName / SPKI all change during normal use.
        // If any of them were identity, a DHCP renewal would scatter history.
        let original = Self.makePaired()

        let moved = original
            .renamed(to: "Studio (den)")
            .relocated(to: HostEndpoint(host: "100.64.0.2", port: 8443))
            .certificateChanged()

        #expect(moved.id == original.id)
        #expect(original.displayName == "Studio")
        #expect(original.endpoint.host == "studio.local")
    }

    @Test("pairing walks discovered → pairing → paired and pins the SPKI")
    func pairingTransitionPinsCertificate() {
        let discovered = Self.makeDiscovered()

        let pairing = discovered.beginningPairing()
        let paired = pairing.paired(pinning: SPKIHash(base64: "SPKI-1"))

        #expect(discovered.pairingState == .discovered)
        #expect(pairing.pairingState == .pairing)
        #expect(paired.pairingState == .paired)
        #expect(paired.pinnedSPKI == SPKIHash(base64: "SPKI-1"))
        #expect(discovered.pinnedSPKI == nil)
    }

    @Test("unpairing clears the pinned SPKI — zero residue")
    func unpairingLeavesNoPinnedCertificate() {
        // FR-027 / SC-012: unpair must leave no orphaned credential behind. The
        // Keychain token is the transport's job; the pinned SPKI is ours, and
        // dropping it here is what makes "zero residue" checkable in a test.
        let paired = Self.makePaired()

        let revoked = paired.unpaired()

        #expect(revoked.pairingState == .revoked)
        #expect(revoked.pinnedSPKI == nil)
        #expect(revoked.id == paired.id)
        // The bridge id survives so a later re-pair can recognise the machine
        // and reactivate its orphaned sessions.
        #expect(revoked.bridgeID == paired.bridgeID)
    }

    @Test("a certificate change keeps the pinned SPKI and blocks connection")
    func certificateChangeBlocksConnection() {
        // Constitution V: no "trust anyway" path. The previously pinned value is
        // retained so the UI can say *this* host changed, not "some host did".
        let changed = Self.makePaired().certificateChanged()

        #expect(changed.pairingState == .certificateChanged)
        #expect(changed.pinnedSPKI != nil)
        #expect(!changed.canConnect)
    }

    @Test("only a paired host with a pinned certificate may connect")
    func canConnectRequiresPairedAndPinned() {
        #expect(Self.makePaired().canConnect)
        #expect(!Self.makeDiscovered().canConnect)
        #expect(!Self.makeDiscovered().beginningPairing().canConnect)
        #expect(!Self.makePaired().unpaired().canConnect)
    }

    @Test("protocol version is negotiated per host")
    func protocolVersionIsPerHost() {
        // FR-032: one host being on an unsupported version must not affect any
        // other host, so the version is a field on Host, never a global.
        let a = Self.makePaired().withProtocolVersion(1)
        let b = Self.makePaired().withProtocolVersion(2)

        #expect(a.protocolVersion == 1)
        #expect(b.protocolVersion == 2)
    }

    @Test("kind carries no behaviour, only presentation")
    func kindIsPresentationOnly() {
        let nas = Self.makePaired().withKind(.nas)

        #expect(nas.kind == .nas)
        #expect(nas.canConnect == Self.makePaired().canConnect)
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        let host = Self.makePaired()

        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(LocalisHost.self, from: data)

        #expect(decoded == host)
    }

    @Test("no stored property can hold a token")
    func hostHasNoCredentialField() throws {
        // Constitution I: the pairing token lives in the Keychain and nowhere
        // else. Encoding the whole entity and grepping the payload is a cheap
        // standing guard against someone adding a `token` field later.
        let data = try JSONEncoder().encode(Self.makePaired())
        let json = String(decoding: data, as: UTF8.self).lowercased()

        #expect(!json.contains("token"))
        #expect(!json.contains("secret"))
        #expect(!json.contains("bearer"))
    }
}

@Suite("HostEndpoint")
struct HostEndpointTests {
    @Test("display text joins host and port")
    func displayTextJoinsHostAndPort() {
        let endpoint = HostEndpoint(host: "studio.local", port: 8443)

        #expect(endpoint.displayText == "studio.local:8443")
    }

    @Test("endpoints differing only by port are different endpoints")
    func portParticipatesInEquality() {
        #expect(HostEndpoint(host: "a.local", port: 1) != HostEndpoint(host: "a.local", port: 2))
    }
}

@Suite("HostRuntimeState")
struct HostRuntimeStateTests {
    @Test("reachability defaults to unknown before any probe")
    func defaultsToUnknown() {
        let state = HostRuntimeState()

        #expect(state.reachability == .unknown)
        #expect(state.latencyMs == nil)
        #expect(state.lastSeenAt == nil)
    }

    @Test("derived state is not part of the persisted Host")
    func derivedStateIsSeparateFromHost() throws {
        // Amendment C §4.2: reachability / latency / lastSeenAt are runtime
        // values. Keeping them in a separate type is what stops them from being
        // persisted by accident.
        let json = String(decoding: try JSONEncoder().encode(HostTests.makePairedForRuntimeCheck()), as: UTF8.self)

        #expect(!json.contains("reachability"))
        #expect(!json.contains("latency"))
        #expect(!json.contains("lastSeen"))
    }

    @Test("an unreachable state carries a reason")
    func unreachableCarriesReason() {
        let state = HostRuntimeState(reachability: .unreachable(reason: .offline))

        #expect(state.reachability == .unreachable(reason: .offline))
        #expect(state.reachability != .unreachable(reason: .certificateRejected))
    }
}

extension HostTests {
    /// Exposed for `HostRuntimeStateTests`, which asserts on Host's encoding.
    static func makePairedForRuntimeCheck() -> LocalisHost { makePaired() }
}

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

/// The wording each reason projects (#35).
///
/// **Why these assert on properties rather than on the strings.** A test that
/// pins `.offline` to its exact sentence passes by restating the implementation
/// and fails on every copy edit, which teaches the next person to update the
/// expected value without reading it. What has to hold is that the four reasons
/// stay four *distinct, actionable* messages — that is the whole reason the enum
/// carries a case instead of a bool. So that is what is asserted.
@Suite("HostUnreachableReason wording")
struct HostUnreachableReasonWordingTests {
    @Test("every reason has words")
    func everyReasonIsGivenWords() {
        // `CaseIterable` is what makes this fail for a case added later. An
        // exhaustive `switch` in the implementation forces *a* branch to be
        // written, but nothing stops that branch from returning "" — this is
        // the half the compiler cannot check.
        for reason in HostUnreachableReason.allCases {
            #expect(!reason.userMessage.isEmpty, "\(reason) has no message")
        }
    }

    @Test("no two reasons say the same thing")
    func reasonsAreNotInterchangeable() {
        // The failure this exists for is a fifth case added by copying the line
        // above it: it compiles, it passes `everyReasonIsGivenWords`, and it
        // tells the user to fix the wrong thing. Distinctness catches it.
        let messages = Set(HostUnreachableReason.allCases.map(\.userMessage))

        #expect(messages.count == HostUnreachableReason.allCases.count)
    }

    @Test("a changed certificate is not offered as something to retry")
    func certificateRejectionNamesNoRetry() {
        // Constitution V: no "trust anyway", and no wording that reads as one.
        // "Try again" on this branch means "reconnect and pin whatever is being
        // presented now", which is the attack the pin exists to stop.
        let message = HostUnreachableReason.certificateRejected.userMessage.lowercased()

        #expect(!message.contains("try again"))
        #expect(!message.contains("retry"))
        // The two above pass for any string lacking those words, including an
        // empty one or a sentence about something else. These pin that it is
        // about identity and names the one action that resolves it.
        #expect(message.contains("identity"))
        #expect(message.contains("pair again"))
    }

    @Test("being offline does not send the user to re-pair")
    func offlineDoesNotSuggestRepairing() {
        // The inverse mistake, and the likelier one: an asleep Mac is the most
        // common failure here, and telling that user to pair again sends them
        // to redo credentials that work. `offline` is the one case where
        // waiting is the answer.
        let message = HostUnreachableReason.offline.userMessage.lowercased()

        #expect(!message.contains("pair again"))
        #expect(message.contains("network") || message.contains("awake"))
    }

    @Test("the two 'pair again' reasons still name different causes")
    func credentialAndIdentityFailuresAreDistinguished() {
        // `certificateRejected` and `unauthorized` share an action, which is
        // exactly why they are easy to collapse. They must not be: one says the
        // machine may not be the machine, the other says this device's
        // credential stopped working. Sent to the wrong one the user inspects
        // the wrong thing — and in the certificate case, shrugs at a real
        // warning.
        let identity = HostUnreachableReason.certificateRejected.userMessage
        let credential = HostUnreachableReason.unauthorized.userMessage

        #expect(identity != credential)
        #expect(identity.lowercased().contains("identity"))
        #expect(!credential.lowercased().contains("identity"))
    }

    @Test("wording carries nothing that came off the wire")
    func wordingIsDerivedLocally() {
        // Constitution I. The text is derived from the case, so a host's own
        // `error.message` — which may contain absolute paths — has no route
        // into it. Asserted rather than assumed because the cheap fix to a
        // vague message is to append the underlying reason, and that reason
        // comes from the far end.
        for reason in HostUnreachableReason.allCases {
            let message = reason.userMessage
            #expect(!message.contains("/"), "\(reason) carries a path separator")
            #expect(!message.contains("http"), "\(reason) carries an endpoint")
            // The raw case name leaking in would mean the string was built from
            // the value rather than written for the user.
            #expect(!message.contains(reason.rawValue), "\(reason) renders its own case name")
        }
    }
}

extension HostTests {
    /// Exposed for `HostRuntimeStateTests`, which asserts on Host's encoding.
    static func makePairedForRuntimeCheck() -> LocalisHost { makePaired() }
}

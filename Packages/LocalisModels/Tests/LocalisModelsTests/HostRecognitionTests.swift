import Foundation
import Testing

@testable import LocalisModels

/// FR-031 and the multi-host edge cases in spec §Edge Cases.
///
/// Recognising a re-appearing host is the one place where getting it wrong is
/// silent: merge two machines and history is corrupted; fail to recognise one
/// and the user is asked to pair a machine they already paired.
@Suite("HostRecognition")
struct HostRecognitionTests {
    private static let spkiA = SPKIHash(base64: "SPKI-A")
    private static let spkiB = SPKIHash(base64: "SPKI-B")

    private static func paired(
        bridgeID: String?,
        spki: SPKIHash,
        name: String = "Studio"
    ) -> LocalisHost {
        LocalisHost(
            id: HostID(),
            displayName: name,
            endpoint: HostEndpoint(host: "studio.local", port: 8443),
            bridgeID: bridgeID,
            pinnedSPKI: spki,
            pairingState: .paired,
            protocolVersion: 1,
            kind: .mac
        )
    }

    @Test("a matching bridge id and SPKI is the same host at a new address")
    func matchingBridgeIDAndSPKIIsTrusted() {
        // FR-031 / SC-011: DHCP renewal or a switch to a Tailscale address must
        // not cost the user a re-pairing.
        let known = Self.paired(bridgeID: "bridge-1", spki: Self.spkiA)

        let result = HostRecognition.recognise(
            bridgeID: "bridge-1",
            spki: Self.spkiA,
            among: [known]
        )

        #expect(result == .trusted(known.id))
    }

    @Test("a matching SPKI alone is enough when the bridge id is absent")
    func spkiAloneIsTrustedWhenBridgeIDMissing() {
        // Amendment A §1.6: `bridge_id` is optional. Older bridges do not send
        // it, and the pinned SPKI is the documented fallback.
        let known = Self.paired(bridgeID: nil, spki: Self.spkiA)

        let result = HostRecognition.recognise(bridgeID: nil, spki: Self.spkiA, among: [known])

        #expect(result == .trusted(known.id))
    }

    @Test("a different SPKI is never the same host, whatever the bridge id says")
    func differingSPKIIsNeverTrusted() {
        // The cloned-bridge edge case: a whole-disk clone reports the same
        // `bridge_id` from a different machine. Merging them would let one
        // machine inherit the other's session history.
        let known = Self.paired(bridgeID: "bridge-1", spki: Self.spkiA)

        let result = HostRecognition.recognise(
            bridgeID: "bridge-1",
            spki: Self.spkiB,
            among: [known]
        )

        #expect(result == .untrusted(known.id))
    }

    @Test("a contradicting bridge id under a pinned SPKI is not auto-trusted")
    func contradictingBridgeIDIsNotTrusted() {
        // `bridge_id` is never an identity authority (Amendment A §1.6). When it
        // disagrees with the pinned certificate we decline to guess.
        let known = Self.paired(bridgeID: "bridge-1", spki: Self.spkiA)

        let result = HostRecognition.recognise(
            bridgeID: "bridge-2",
            spki: Self.spkiA,
            among: [known]
        )

        #expect(result == .unknown)
    }

    @Test("an unpaired host is recognised by bridge id but still needs pairing")
    func revokedHostIsRecognisedWithoutTrust() {
        // spec §Edge Cases: re-pairing a previously unpaired machine may
        // reactivate its orphaned sessions. Recognition here grants *continuity*,
        // never trust — the SPKI was cleared on unpair (FR-027).
        let revoked = Self.paired(bridgeID: "bridge-1", spki: Self.spkiA).unpaired()

        let result = HostRecognition.recognise(
            bridgeID: "bridge-1",
            spki: Self.spkiA,
            among: [revoked]
        )

        #expect(result == .needsPairing(revoked.id))
    }

    @Test("an unseen machine is unknown")
    func unseenMachineIsUnknown() {
        let known = Self.paired(bridgeID: "bridge-1", spki: Self.spkiA)

        let result = HostRecognition.recognise(
            bridgeID: "bridge-9",
            spki: SPKIHash(base64: "SPKI-Z"),
            among: [known]
        )

        #expect(result == .unknown)
    }

    @Test("recognition scans every known host, not just the first")
    func scansAllKnownHosts() {
        let first = Self.paired(bridgeID: "bridge-1", spki: Self.spkiA, name: "MacBook")
        let second = Self.paired(bridgeID: "bridge-2", spki: Self.spkiB, name: "Studio")

        let result = HostRecognition.recognise(
            bridgeID: "bridge-2",
            spki: Self.spkiB,
            among: [first, second]
        )

        #expect(result == .trusted(second.id))
    }

    @Test("an empty known set is unknown, not a crash")
    func emptyKnownSetIsUnknown() {
        #expect(HostRecognition.recognise(bridgeID: "x", spki: Self.spkiA, among: []) == .unknown)
    }
}

import Foundation
import Testing

@testable import Localis

import LocalisModels

/// `DemoHostProbe` reads a launch argument and must not guess (task #52).
///
/// **Why a demo device gets a test suite at all.** This one is the instrument
/// the #41/#48 acceptance is read through: someone passes
/// `-LocalisDemoUnreachable certificateRejected` and looks at a card. An
/// instrument that quietly answers a different question than the one asked
/// makes every reading through it wrong, and — unlike a broken feature —
/// nothing downstream complains, because the app behaves perfectly for
/// whatever reason it *did* pick.
///
/// Before this file, the whole guarantee was that someone ran it by hand once.
/// `DemoHostProbe` appeared in exactly two places in the repo, `HostProbing.swift`
/// and `RootView.swift`, and in no test at all.
@Suite("The demo probe answers the reason that was asked for, or none")
struct DemoProbeReasonTests {
    /// The rule with teeth: an unrecognised value produces `nil`, **not**
    /// `.offline`.
    ///
    /// A fallback would answer a request for `certificateRejected` with the one
    /// sentence #48's acceptance says must not appear — so the reader sees
    /// "This Mac isn't answering" where they asked for a certificate problem,
    /// which reads as *the display chain being broken*. That is the failure
    /// this project has already paid for once (#45), and here it would send the
    /// reader to debug wiring that is fine.
    ///
    /// `nil` instead means the demo probe is never installed, the card shows
    /// nothing, and the mismatch is visible as "my argument did nothing" —
    /// which points at the argument, where the fault actually is.
    @Test("an unrecognised reason produces nothing, rather than falling back to offline")
    func unrecognisedReasonDoesNotFallBack() {
        // Not an empty string or a near-miss only: a value that is clearly
        // nobody's typo, so the assertion is about the default branch rather
        // than about string trimming.
        #expect(DemoHostProbe.reason(named: "totally-not-a-reason") == nil)
        #expect(DemoHostProbe.reason(named: "totally-not-a-reason") != .offline)

        // The realistic way to hit it: a case-mismatched or renamed value. A
        // reader who typed this wants to know it did nothing.
        #expect(DemoHostProbe.reason(named: "CertificateRejected") == nil)
        #expect(DemoHostProbe.reason(named: "certificate_rejected") == nil)

        // No argument at all is the shipped-build path, and it must also not
        // install a demo probe.
        #expect(DemoHostProbe.reason(named: nil) == nil)
    }

    /// **The positive control, and the suite is worthless without it.**
    ///
    /// `reason(named:)` returning `nil` for everything would keep every
    /// assertion above green forever, while the demo device silently stopped
    /// working — the launch argument would do nothing and the acceptance it
    /// exists to serve could never be performed again. Asserting that legal
    /// values map to their own reason is what makes the verdict able to move.
    ///
    /// Every case is covered by iterating `allCases` rather than by listing
    /// four literals: a fifth reason added later arrives here with no matching
    /// string and turns this red, which is the moment to decide its argument
    /// name — rather than it silently having none.
    @Test("every legal reason maps to itself")
    func legalReasonsMapToThemselves() {
        for reason in HostUnreachableReason.allCases {
            #expect(
                DemoHostProbe.reason(named: reason.rawValue) == reason,
                "\(reason.rawValue) must select \(reason), or the demo device cannot show it"
            )
        }

        // And they are not all the same value arrived at four ways: a mapping
        // that returned `.offline` for every legal name would satisfy the loop
        // above only if `rawValue` matched, but a mapping keyed on something
        // looser might not. Counting distinct results states the intent.
        let produced = HostUnreachableReason.allCases.compactMap {
            DemoHostProbe.reason(named: $0.rawValue)
        }
        #expect(Set(produced).count == HostUnreachableReason.allCases.count)
    }

    /// The join: `requestedReason` really reads `defaultsKey`.
    ///
    /// **Why this exists beside the pure-function tests.** Those state the
    /// mapping; none of them would notice if `requestedReason` stopped calling
    /// it, or read a key nobody passes. That is the same shape as the defect in
    /// #48 — two correct ends, no join, and every suite green. One test crosses
    /// it, so a renamed key cannot stay quiet.
    ///
    /// **Writes `standard` and removes the key afterwards**, which is the only
    /// way to cross the real read: `requestedReason` reads
    /// `UserDefaults.standard` by definition, and that is the fact under test.
    /// A volatile domain was tried first and does not work — domains registered
    /// with `setVolatileDomain` are not in `standard`'s lookup chain, so the
    /// setup did nothing at all and the test failed as though the mapping were
    /// broken. The control below is what told those two apart.
    ///
    /// The `defer` runs even when an `#expect` fails, so a red test cannot
    /// leave the key behind for the next test — or, since `standard` is
    /// persisted, for the next *run*.
    @Test("requestedReason reads the documented launch-argument key")
    func requestedReasonReadsTheDefaultsKey() {
        UserDefaults.standard.set(
            HostUnreachableReason.certificateRejected.rawValue,
            forKey: DemoHostProbe.defaultsKey
        )
        defer { UserDefaults.standard.removeObject(forKey: DemoHostProbe.defaultsKey) }

        // Positive control on the fixture itself. Without it, a setup that
        // silently failed to take would be indistinguishable from a mapping
        // that stopped working — which is exactly what happened on the first
        // run of this test, and is why the assertion is here rather than
        // trusting the write.
        #expect(
            UserDefaults.standard.string(forKey: DemoHostProbe.defaultsKey)
                == HostUnreachableReason.certificateRejected.rawValue
        )

        #expect(DemoHostProbe.requestedReason == .certificateRejected)
    }

    /// The probe built from a reason carries it to the row, and only for a
    /// machine that could have been connected to.
    ///
    /// The guard is the same one `BridgeHostProbe` applies, and it is the point
    /// of the demo: an unpaired machine staying blank *beside* a paired one
    /// carrying the sentence is what makes the reading evidence rather than a
    /// screenshot of one card.
    @Test("the reason reaches a connectable machine, and not an unpaired one")
    func reasonTravelsOnlyForConnectableHosts() async {
        let probe = DemoHostProbe(reason: .certificateRejected)

        let paired = Self.host(pinned: true)
        // Positive control: the fixture must be connectable on its own, or the
        // assertion below could pass while measuring the pairing.
        #expect(paired.canConnect)
        #expect(await probe.reachability(of: paired) == .unreachable(reason: .certificateRejected))

        let unpaired = Self.host(pinned: false, state: .discovered)
        #expect(await probe.reachability(of: unpaired) == .unknown)
    }

    private static func host(
        pinned: Bool,
        state: HostPairingState = .paired
    ) -> LocalisHost {
        LocalisHost(
            id: HostID(),
            displayName: "Studio",
            endpoint: HostEndpoint(host: "studio.local", port: 8443),
            bridgeID: "bridge-1",
            pinnedSPKI: pinned ? SPKIHash(base64: "AAA=") : nil,
            pairingState: state,
            protocolVersion: 1,
            kind: .mac
        )
    }
}

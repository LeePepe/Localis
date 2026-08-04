import Foundation
import Testing

@testable import Localis

import LocalisModels

/// The host list has to say *why* a machine is unusable (FR-060).
///
/// **Why this is a separate suite from the pairing-state wording.** The row now
/// carries two independent dimensions — what the pairing relationship is, and
/// whether the machine answered the last time we asked — and they fail in
/// different ways. Folding them into one suite would let a change that collapses
/// the two dimensions into one string stay green as long as *some* words came
/// out.
///
/// FR-060's second half is the part with teeth: a certificate problem must not
/// share wording with "the Mac is asleep". Constitution V forbids a "trust
/// anyway" override, and the closest thing to an override that can still be
/// built is a sentence that makes the user think waiting or retrying will clear
/// it.
@Suite("Host row: unreachable reason is visible and specific")
struct HostRowReachabilityTests {
    private func host(
        _ name: String = "Studio",
        state: HostPairingState = .paired
    ) -> LocalisHost {
        LocalisHost(
            id: HostID(),
            displayName: name,
            endpoint: .init(host: "studio.local", port: 8443),
            bridgeID: "bridge-1",
            pinnedSPKI: nil,
            pairingState: state,
            protocolVersion: 1,
            kind: .mac
        )
    }

    /// FR-060, first half: the reason reaches the row at all.
    ///
    /// Asserted as "the row's detail is not empty and is not the same string it
    /// shows when nothing is wrong", rather than against a literal. The wording
    /// belongs to `HostUnreachableReason.userMessage`, which has its own tests;
    /// duplicating the sentence here would mean every copy-edit breaks two
    /// suites and tempts whoever fixes it to paste rather than think.
    @Test("an unreachable host says why, and a reachable one does not")
    func unreachableHostCarriesItsReason() {
        let offline = HostRowState(
            host: host(),
            runtime: HostRuntimeState(reachability: .unreachable(reason: .offline))
        )
        let fine = HostRowState(
            host: host(),
            runtime: HostRuntimeState(reachability: .reachable)
        )

        #expect(offline.unreachableDetail != nil)
        #expect(offline.unreachableDetail?.isEmpty == false)
        #expect(fine.unreachableDetail == nil)
    }

    /// `unknown` is not a failure, and must not be rendered as one.
    ///
    /// Before the first probe we have not established anything. A row that said
    /// "not answering" on launch would be a claim the user has to disprove, and
    /// the honest rendering of "we have not asked yet" is silence.
    @Test("a host we have not probed yet reports nothing")
    func unknownReachabilityIsNotAFailure() {
        let row = HostRowState(
            host: host(),
            runtime: HostRuntimeState(reachability: .unknown)
        )

        #expect(row.unreachableDetail == nil)
        #expect(row.isUnreachable == false)
    }

    /// FR-060, second half: a certificate problem must not read like an outage.
    ///
    /// The two are different situations with different user actions — one is
    /// resolved by waiting, the other must never be. Sharing a sentence would
    /// downgrade the thing constitution V exists to prevent into a network
    /// hiccup.
    @Test("certificate rejection does not share wording with being offline")
    func certificateReasonIsDistinctFromOffline() {
        let certificate = HostRowState(
            host: host(),
            runtime: HostRuntimeState(reachability: .unreachable(reason: .certificateRejected))
        )
        let offline = HostRowState(
            host: host(),
            runtime: HostRuntimeState(reachability: .unreachable(reason: .offline))
        )

        #expect(certificate.unreachableDetail != offline.unreachableDetail)
    }

    /// Every reason produces its own sentence, checked by counting.
    ///
    /// **Counting rather than comparing pairs is deliberate.** A pairwise test
    /// grows quadratically and, more importantly, a new case added later is not
    /// covered by it — the test still passes while saying nothing about the new
    /// reason. Deduplicating all of them and comparing to `allCases.count` fails
    /// the moment a fifth reason is given a sentence that already exists.
    @Test("all four reasons produce four distinct sentences")
    func reasonsAreNotInterchangeable() {
        let details = HostUnreachableReason.allCases.map { reason in
            HostRowState(
                host: host(),
                runtime: HostRuntimeState(reachability: .unreachable(reason: reason))
            ).unreachableDetail
        }

        #expect(details.allSatisfy { $0 != nil })
        #expect(Set(details.compactMap { $0 }).count == HostUnreachableReason.allCases.count)
    }

    /// FR-061: the row shows `certificateChanged`, the *pairing* state.
    ///
    /// The two names are close enough that merging them is the next reader's
    /// reasonable move, so the rule is pinned by a test rather than by a comment
    /// — a prose-only rule is the kind that gets tidied away by someone who
    /// never saw it.
    ///
    /// They are cause and effect, not synonyms: `certificateRejected` is the
    /// result of one connection attempt and is never persisted, while
    /// `certificateChanged` is the state of the pairing relationship and needs a
    /// person to leave it. Showing the transient one in the status would let the
    /// next probe — the Mac merely being switched off — replace it with
    /// "offline", and the fact that this machine's identity changed would vanish
    /// while the pairing stayed compromised.
    @Test("status reflects the persistent pairing state, not the transient probe result")
    func statusShowsPairingStateNotProbeResult() {
        let changed = HostRowState(
            host: host(state: .certificateChanged),
            runtime: HostRuntimeState(reachability: .unreachable(reason: .certificateRejected))
        )

        // The durable fact is what the status line reports.
        #expect(changed.status == HostRowState.statusText(for: .certificateChanged))

        // And a host whose pairing is intact does not borrow that status just
        // because one probe was refused — otherwise a transient result would be
        // writing the durable line after all.
        let paired = HostRowState(
            host: host(state: .paired),
            runtime: HostRuntimeState(reachability: .unreachable(reason: .certificateRejected))
        )
        #expect(paired.status == HostRowState.statusText(for: .paired))
        #expect(paired.status != changed.status)
    }

    /// A row that cannot connect must not offer to.
    ///
    /// `isConnectable` already required paired-and-pinned. Reachability is a
    /// second, independent reason to refuse: a machine that just refused our
    /// certificate is not one to open a connection to, whatever the stored
    /// pairing says.
    @Test("an unreachable host is not offered as connectable")
    func unreachableHostIsNotConnectable() {
        let row = HostRowState(
            host: host(state: .paired),
            runtime: HostRuntimeState(reachability: .unreachable(reason: .certificateRejected))
        )

        #expect(row.isConnectable == false)
    }

    /// The other side of that condition: `unknown` must stay connectable.
    ///
    /// **This is the test that distinguishes the right predicate from a value
    /// that happens to work.** `isConnectable` must be false for
    /// `unreachable` specifically, not for "anything that is not `reachable`".
    /// Written the second way, every host is unconnectable until #41 supplies a
    /// live probe — because until then every row is `.unknown` — and the symptom
    /// is a dead host list that looks like broken UI rather than like a wrong
    /// condition here.
    ///
    /// The reason is the one already written on `HostReachability`: treating
    /// "not yet asked" as "down" makes the user disprove something nobody
    /// measured. It applies to connectability exactly as it does to wording.
    ///
    /// Deliberately paired with a host that really is connectable, which is what
    /// makes this able to fail — an unpaired fixture would report `false` for a
    /// reason that has nothing to do with reachability, and the test would pass
    /// against both predicates.
    @Test("a host we have not probed yet is still connectable if its pairing is good")
    func unknownReachabilityDoesNotBlockConnecting() {
        let connectable = host(state: .paired).paired(pinning: SPKIHash(base64: "AAA="))
        // Positive control: the fixture must be connectable on its own, or the
        // assertion below could pass while measuring the pairing, not the probe.
        #expect(connectable.canConnect)

        let unknown = HostRowState(
            host: connectable,
            runtime: HostRuntimeState(reachability: .unknown)
        )
        let reachable = HostRowState(
            host: connectable,
            runtime: HostRuntimeState(reachability: .reachable)
        )

        #expect(unknown.isConnectable)
        #expect(reachable.isConnectable)
    }

    /// The default keeps every existing construction site honest.
    ///
    /// `HostListModel` has no transport yet (#41 supplies the live probe), so
    /// rows are built without a runtime value. That default must be `unknown`
    /// — "we have not asked" — and not `reachable`, which would be a claim no
    /// probe backs up and would show every stored machine as online at launch.
    @Test("a row built without runtime state claims nothing about reachability")
    func defaultRuntimeIsUnknownNotReachable() {
        let row = HostRowState(host: host())

        #expect(row.isUnreachable == false)
        #expect(row.unreachableDetail == nil)
        // The distinction that matters: not-yet-asked must not be recorded as a
        // successful probe.
        #expect(row.runtime.reachability == .unknown)
        #expect(row.runtime.reachability != .reachable)
    }
}

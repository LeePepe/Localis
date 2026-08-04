import Foundation
import Testing

@testable import Localis

import LocalisModels
import SessionStore
import TransportKit

/// The probe's answer reaches the row (#48).
///
/// **Why this suite exists separately from `HostRowReachabilityTests`.** That
/// one asserts the projection: given a `HostRuntimeState`, what does the row
/// say. Every one of its cases constructs the runtime value by hand, so all of
/// them stay green while *nothing in the app ever builds one* — which is
/// precisely the state #48 found the project in. `HostUnreachableReason` had
/// four cases, four sentences and a passing suite, and no user could see any of
/// them.
///
/// So this suite asserts the join instead: that a probe result travels from the
/// transport into `HostRowState.runtime`. It is the same shape as
/// `HostRecoveryTests` — that one exists because a store that persists and an
/// app that never asks are indistinguishable from the user's side, and this one
/// exists because a transport that reports and an app that never probes are too.
@Suite("Probe results reach the host rows")
struct HostProbeTests {
    /// A machine that has been paired — which is the only kind that gets probed.
    ///
    /// **The `.paired` is load-bearing, not incidental fixture detail.**
    /// `LocalisHost`'s default is `.discovered`, and a `.discovered` machine is
    /// deliberately never asked: it has no token, so the request would be
    /// refused as `.unauthorized` and the row would read "This Mac no longer
    /// accepts this device" about a machine that never accepted it.
    /// `notPairedMachinesAreNotProbed` is where that rule is asserted; this
    /// helper only has to stay on the side of it that the other tests are about.
    private static func mac(
        named name: String = "Studio",
        at host: String = "studio.local",
        pairingState: HostPairingState = .paired
    ) -> LocalisHost {
        LocalisHost(
            id: HostID(),
            displayName: name,
            endpoint: HostEndpoint(host: host, port: 8443),
            bridgeID: "bridge-abc",
            pairingState: pairingState
        )
    }

    /// An empty Keychain, passed explicitly at every construction site.
    ///
    /// Same reason `HostRecoveryTests` does it: the default is the **real**
    /// Keychain, and a suite that quietly reaches it fails differently in CI
    /// than on a developer's machine.
    private struct NoPins: PinReading {
        func pin(for host: HostID) throws -> SPKIHash? { nil }
    }

    /// A prober that answers from a script, and records what it was asked.
    ///
    /// Recording the hosts is not decoration: it is what distinguishes "the
    /// model probed this machine and wrote the answer down" from "the model
    /// reached the same value some other way". A test that only checked the row
    /// would pass against an implementation that hardcoded the verdict.
    private actor ScriptedProber: HostProbing {
        private let answers: [HostID: HostReachability]
        private let fallback: HostReachability
        private(set) var asked: [HostID] = []

        init(_ answers: [HostID: HostReachability], fallback: HostReachability = .reachable) {
            self.answers = answers
            self.fallback = fallback
        }

        func reachability(of host: LocalisHost) async -> HostReachability {
            asked.append(host.id)
            return answers[host.id] ?? fallback
        }
    }

    private static func model(
        _ repository: any SessionRepository,
        probing: any HostProbing
    ) async -> HostListModel {
        await HostListModel(repository: repository, credentials: NoPins(), probing: probing)
    }

    private static func stored(_ hosts: LocalisHost...) async throws -> SwiftDataSessionRepository {
        let repository = SwiftDataSessionRepository(container: try SessionStoreContainer.inMemory())
        for host in hosts { try await repository.save(host) }
        return repository
    }

    /// The assertion the whole task is about.
    ///
    /// A rejected certificate must reach the screen as the sentence about
    /// identity, and must **not** reach it as the sentence about being asleep.
    /// Both are observable, which is what makes this able to move.
    @Test("a refused certificate reaches the row as an identity problem, not an outage")
    func certificateRejectionReachesTheRow() async throws {
        let mac = Self.mac()
        let repository = try await Self.stored(mac)
        let prober = ScriptedProber([mac.id: .unreachable(reason: .certificateRejected)])

        let model = await Self.model(repository, probing: prober)
        await model.load()
        // `load()` deliberately returns before any probe answers — that is the
        // requirement `rowsAppearBeforeProbesComplete` is about. So a test that
        // wants the probe's answer has to say so, or it is asserting against the
        // pre-probe list and reading "no sentence yet" as "the wrong sentence".
        await model.probesFinished()

        let row = try #require(await model.rows.first)
        #expect(row.unreachableDetail == HostUnreachableReason.certificateRejected.userMessage)
        // The other half of FR-060, stated as its own expectation rather than
        // inferred from the one above: the two sentences are the pair most
        // likely to be merged, and "not equal to the offline sentence" is the
        // fact that keeps them apart.
        #expect(row.unreachableDetail != HostUnreachableReason.offline.userMessage)
    }

    /// The prober must actually be consulted, per host.
    ///
    /// Without this, an implementation that never calls the transport and leaves
    /// every row at `.unknown` passes every *other* test in this suite that
    /// asserts silence.
    @Test("every stored machine is probed")
    func everyHostIsProbed() async throws {
        let studio = Self.mac(named: "Studio", at: "studio.local")
        let air = Self.mac(named: "Air", at: "air.local")
        let repository = try await Self.stored(studio, air)
        let prober = ScriptedProber([:])

        let model = await Self.model(repository, probing: prober)
        await model.load()
        await model.probesFinished()

        #expect(await Set(prober.asked) == Set([studio.id, air.id]))
    }

    /// FR-034: one unreachable machine must not take the others down with it.
    ///
    /// The failure this guards against is not a crash — it is a list that shows
    /// nothing, or shows only the machines that answered, because one probe
    /// decided the outcome for all of them.
    @Test("an unreachable machine does not hide the reachable ones")
    func oneFailureDoesNotBlockTheRest() async throws {
        let broken = Self.mac(named: "Air", at: "air.local")
        let fine = Self.mac(named: "Studio", at: "studio.local")
        let repository = try await Self.stored(broken, fine)
        let prober = ScriptedProber(
            [broken.id: .unreachable(reason: .offline), fine.id: .reachable]
        )

        let model = await Self.model(repository, probing: prober)
        await model.load()
        await model.probesFinished()

        #expect(await model.rows.count == 2)
        let rows = await model.rows
        let brokenRow = try #require(rows.first { $0.id == broken.id })
        let fineRow = try #require(rows.first { $0.id == fine.id })
        #expect(brokenRow.unreachableDetail != nil)
        // The reachable one says nothing, which is the honest rendering of "no
        // problem to report" — not a second sentence saying it is fine.
        #expect(fineRow.unreachableDetail == nil)
    }

    /// Rows must be on screen before the probes finish.
    ///
    /// **This is a requirement about ordering, not about speed.** A `load()`
    /// that awaited every probe before publishing would leave the list empty
    /// for as long as the slowest unreachable Mac takes to time out — and an
    /// empty list is the sentence "you have no machines". The stored rows are
    /// known immediately and must be shown immediately; the probe results
    /// arrive as an update.
    @Test("the machines appear before the probes answer")
    func rowsAppearBeforeProbesComplete() async throws {
        let mac = Self.mac()
        let repository = try await Self.stored(mac)
        let gate = ProbeGate()

        let model = await Self.model(repository, probing: gate)
        // `load()` must return with rows on screen while the probe is still
        // blocked. If it awaits the probe, this test hangs rather than failing
        // — deliberately: a hang here is a real deadlock in the app, and
        // reporting it as a normal red would understate it.
        await model.load()

        #expect(await model.rows.count == 1)
        // Nothing is claimed about reachability yet, because nothing has come
        // back. `.unknown` is what "we have asked but do not know" looks like,
        // and it is the same value as "we have not asked" on purpose — neither
        // is a claim.
        let row = try #require(await model.rows.first)
        #expect(row.runtime.reachability == .unknown)
        #expect(row.unreachableDetail == nil)

        await gate.answer(.unreachable(reason: .certificateRejected))
        await model.probesFinished()

        let updated = try #require(await model.rows.first)
        #expect(updated.unreachableDetail == HostUnreachableReason.certificateRejected.userMessage)
    }

    /// A probe result must not overwrite the pairing state's line.
    ///
    /// FR-061 again, at the join rather than at the projection: the row's
    /// `status` belongs to the durable pairing relationship, and a transient
    /// probe result must not be written into it. Pinned here because this is
    /// the layer where the two values first meet.
    @Test("a probe result does not rewrite the pairing status")
    func probeDoesNotOverwriteStatus() async throws {
        let mac = Self.mac()
        let repository = try await Self.stored(mac)
        let prober = ScriptedProber([mac.id: .unreachable(reason: .certificateRejected)])

        let model = await Self.model(repository, probing: prober)
        await model.load()
        await model.probesFinished()

        let row = try #require(await model.rows.first)
        #expect(row.status == HostRowState.statusText(for: .paired))
        // The detail line carries the probe result instead — both are present,
        // neither has replaced the other.
        #expect(row.unreachableDetail != nil)
    }

    /// A machine that was never paired is not asked, and says nothing.
    ///
    /// **What this prevents is a confident false sentence, not a wasted
    /// request.** Measured on 2026-08-04, following one nil token through:
    /// `HostCredentialStore.token(for:)` returns nil rather than throwing, so
    /// `BridgeClient.request` refuses with `.unauthorized`,
    /// `HostReachability(failure:)` maps that to `.unauthorized`, and its
    /// sentence is "This Mac **no longer** accepts this device." Said about a
    /// `.discovered` machine, every word of that is false — and it sends the
    /// user to re-pair, which is the right action reached through a wrong
    /// reason, so a working outcome would hide it.
    ///
    /// Both halves are asserted because they can fail apart: the row could stay
    /// quiet while the request still went out (a pointless connection to an
    /// unpaired machine), or the machine could go unprobed while something else
    /// wrote a sentence onto the row.
    @Test("a machine that was never paired is not probed, and says nothing")
    func notPairedMachinesAreNotProbed() async throws {
        let unpaired = Self.mac(pairingState: .discovered)
        let repository = try await Self.stored(unpaired)
        // Answers `.unauthorized` if asked — the same answer the real
        // credential-less path produces, so a probe that should not have
        // happened shows up as the sentence it would have caused.
        let prober = ScriptedProber(
            [unpaired.id: .unreachable(reason: .unauthorized)]
        )

        let model = await Self.model(repository, probing: prober)
        await model.load()
        await model.probesFinished()

        #expect(await prober.asked.isEmpty)
        let row = try #require(await model.rows.first)
        #expect(row.unreachableDetail == nil)
        // The row is not silent overall — its pairing state is still on screen,
        // and it is both true and the action to take. Nothing is being hidden by
        // not adding a second line.
        #expect(row.status == HostRowState.statusText(for: .discovered))
    }

    /// A machine that answers gets no sentence at all.
    ///
    /// The negative case matters as much as the positive ones here: an
    /// implementation that wrote `.unreachable` unconditionally would satisfy
    /// every test above.
    @Test("a machine that answers reports nothing")
    func reachableHostSaysNothing() async throws {
        let mac = Self.mac()
        let repository = try await Self.stored(mac)
        let prober = ScriptedProber([mac.id: .reachable])

        let model = await Self.model(repository, probing: prober)
        await model.load()
        await model.probesFinished()

        let row = try #require(await model.rows.first)
        #expect(row.unreachableDetail == nil)
        #expect(row.isUnreachable == false)
        #expect(row.runtime.reachability == .reachable)
    }
}

/// A prober that holds its answer until released.
///
/// Lets a test observe the state of the list *between* "rows loaded" and
/// "probes answered", which is the window the ordering requirement is about and
/// the only place it can be measured.
private actor ProbeGate: HostProbing {
    private var continuations: [CheckedContinuation<HostReachability, Never>] = []
    private var pending: HostReachability?

    func reachability(of host: LocalisHost) async -> HostReachability {
        if let pending { return pending }
        return await withCheckedContinuation { continuations.append($0) }
    }

    func answer(_ reachability: HostReachability) {
        pending = reachability
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume(returning: reachability) }
    }
}

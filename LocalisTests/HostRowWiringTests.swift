import Foundation
import Testing

@testable import Localis

import LocalisModels
import SessionStore

/// The first tests that cross `probe → HostRowState` (#41).
///
/// **Why that phrasing matters.** `HostRowReachabilityTests` proves the display
/// side: given a runtime state, the row says the right thing. `LocalisErrorTests`
/// and `HostReachabilityTests` prove the classifying side: given a failure, the
/// right reason comes out. Both were complete, both were green, and the host row
/// still showed nothing — because no code joined them. Neither suite could see
/// that, since neither crosses the join.
///
/// Concretely: every `HostRowState` in this app was built with the `.unknown`
/// default, `HostRuntimeState` is deliberately never persisted (Amendment C
/// §4.2) so it cannot arrive through the repository, and `DemoSeed` writes
/// records — which this is not. There was no path, not even a debug one.
///
/// These tests assert on `rows`, the value the list actually renders, rather
/// than on the probe being called. A build that probed every machine and threw
/// the answers away would satisfy a call-count assertion and leave the user with
/// the screen they had before.
@Suite("A probe's answer reaches the host row")
struct HostRowWiringTests {
    /// Answers with whatever the test says, per host, and records what it was
    /// asked.
    ///
    /// **Does not derive the answer from the host.** A probe that returned
    /// `.unreachable` for, say, any host whose pairing state is
    /// `.certificateChanged` would be reading a stored fact and calling it a
    /// measurement — and a test built on it would pass against an
    /// implementation that never opened a connection.
    ///
    /// `asked` is not decoration. "The row stayed quiet" and "the machine was
    /// never asked" can fail apart, and `notPairedMachinesAreNotProbed` is the
    /// one test here that needs to tell them apart — see its note.
    private actor StubProbe: HostProbing {
        let answers: [HostID: HostReachability]
        /// The answer for a host the test did not name. `.unknown` rather than
        /// `.reachable`, so a row that appears only because of a default cannot
        /// look like one that was measured.
        let fallback: HostReachability
        private(set) var asked: [HostID] = []

        init(_ answers: [HostID: HostReachability], fallback: HostReachability = .unknown) {
            self.answers = answers
            self.fallback = fallback
        }

        func reachability(of host: LocalisHost) async -> HostReachability {
            asked.append(host.id)
            return answers[host.id] ?? fallback
        }
    }

    private static func makeHost(
        _ name: String,
        state: HostPairingState = .paired,
        pinned: Bool = true
    ) -> LocalisHost {
        LocalisHost(
            id: HostID(),
            displayName: name,
            endpoint: HostEndpoint(host: "studio.local", port: 8443),
            bridgeID: "bridge-\(name)",
            pinnedSPKI: pinned ? SPKIHash(base64: "AAA=") : nil,
            pairingState: state,
            protocolVersion: 1,
            kind: .mac
        )
    }

    /// Pins are read through the assembly, not the store, so a test that wants
    /// a connectable host has to supply one.
    private struct StubPins: PinReading {
        let pin: SPKIHash?

        func pin(for host: HostID) throws -> SPKIHash? { pin }
    }

    private static func makeModel(
        hosts: [LocalisHost],
        probe: StubProbe
    ) async throws -> HostListModel {
        let container = try SessionStoreContainer.inMemory()
        let repository = SwiftDataSessionRepository(container: container)
        for host in hosts { try await repository.save(host) }
        return await HostListModel(
            repository: repository,
            credentials: StubPins(pin: SPKIHash(base64: "AAA=")),
            probe: probe
        )
    }

    /// The acceptance criterion for #41, stated as the two sentences.
    ///
    /// A machine that refused our certificate must say so, and must **not** say
    /// the thing that reads as "wait and try again" — constitution V allows no
    /// override, and a sentence implying a retry will clear it is the closest
    /// thing to one that can still be built. Both strings are observable, so
    /// this verdict can move in either direction.
    @Test("a rejected certificate reaches the row, and does not read as offline")
    func certificateRejectionIsNamedOnTheRow() async throws {
        let host = Self.makeHost("Studio")
        let model = try await Self.makeModel(
            hosts: [host],
            probe: StubProbe([host.id: .unreachable(reason: .certificateRejected)])
        )

        await model.load()

        let row = try #require(await model.rows.first)
        let detail = try #require(row.unreachableDetail)
        #expect(detail == HostUnreachableReason.certificateRejected.userMessage)
        #expect(detail != HostUnreachableReason.offline.userMessage)
        // And the machine cannot be connected to. Saying the certificate changed
        // while still offering the row as tappable would be the accept-then-fail
        // shape on the host list.
        #expect(row.isConnectable == false)
    }

    /// The other direction, and it is not redundant.
    ///
    /// The cheapest way to pass every other test here is to mark every row
    /// unreachable. That build shows "isn't answering" under a Mac that is
    /// answering fine and makes the whole list untappable — and only an
    /// assertion on the reachable case can see it.
    @Test("a machine that answers stays connectable and says nothing is wrong")
    func reachableHostSaysNothing() async throws {
        let host = Self.makeHost("Studio")
        let model = try await Self.makeModel(
            hosts: [host],
            probe: StubProbe([host.id: .reachable])
        )

        await model.load()

        let row = try #require(await model.rows.first)
        #expect(row.unreachableDetail == nil)
        #expect(row.isConnectable)
    }

    /// One machine's answer does not become another's.
    ///
    /// The probes are concurrent and their results are matched back by id. A
    /// build that zipped answers onto rows by position would pass every
    /// single-host test here and mislabel every list with more than one Mac —
    /// telling the user that the machine that is fine is the one with the
    /// changed certificate.
    @Test("each machine gets its own answer, not its neighbour's")
    func answersAreMatchedToTheirOwnHost() async throws {
        let good = Self.makeHost("Studio")
        let bad = Self.makeHost("Laptop")
        let model = try await Self.makeModel(
            hosts: [good, bad],
            probe: StubProbe([
                good.id: .reachable,
                bad.id: .unreachable(reason: .certificateRejected),
            ])
        )

        await model.load()

        let rows = await model.rows
        let goodRow = try #require(rows.first { $0.id == good.id })
        let badRow = try #require(rows.first { $0.id == bad.id })
        #expect(goodRow.unreachableDetail == nil)
        #expect(badRow.unreachableDetail == HostUnreachableReason.certificateRejected.userMessage)
    }

    /// A machine that was never paired is not asked, and says nothing.
    ///
    /// **Adapted from `store`'s `notPairedMachinesAreNotProbed`** (its #48
    /// branch, which is not the one being merged). Brought over on team-lead's
    /// ruling, and the ruling's argument is the reason it belongs: the guard it
    /// covers is one line, and deleting that line turned nothing red here.
    ///
    /// **What it prevents is a confident false sentence, not a wasted request.**
    /// `store` traced it through a nil token on 2026-08-04:
    /// `HostCredentialStore.token(for:)` returns nil rather than throwing, so
    /// `BridgeClient.request` refuses with `.unauthorized`,
    /// `HostReachability(failure:)` maps that to `.unauthorized`, and its
    /// sentence is "This Mac **no longer** accepts this device." About a
    /// `.discovered` machine every word of that is false — and it sends the user
    /// to pair, which is the right action reached through a wrong reason, so the
    /// working outcome would hide the defect.
    ///
    /// **Both halves are asserted because they fail apart.** The row could stay
    /// quiet while the request still went out — a pointless connection to a
    /// machine we hold no credential for — or the machine could go unasked while
    /// something else wrote a sentence onto its row. `asked` sees the first;
    /// `unreachableDetail` sees the second.
    @Test("a machine that was never paired is not probed, and says nothing")
    func notPairedMachinesAreNotProbed() async throws {
        let unpaired = Self.makeHost("Studio", state: .discovered, pinned: false)
        // Answers `.unauthorized` if asked — the same answer the real
        // credential-less path produces, so a probe that should not have
        // happened arrives as the sentence it would have caused rather than as
        // a silent extra connection.
        let probe = StubProbe([unpaired.id: .unreachable(reason: .unauthorized)])
        let model = try await Self.makeModel(hosts: [unpaired], probe: probe)

        await model.load()

        #expect(await probe.asked.isEmpty)
        let row = try #require(await model.rows.first)
        #expect(row.unreachableDetail == nil)
        // The row is not silent overall: its pairing state is on screen, and
        // that is both true and the action to take. Nothing is hidden by
        // declining to add a second line.
        #expect(row.status == HostRowState.statusText(for: .discovered))
    }

    /// A machine with a good pairing *is* asked — the control for the test above.
    ///
    /// Without this, the cheapest way to keep `notPairedMachinesAreNotProbed`
    /// green forever is to stop probing altogether: `asked.isEmpty` holds
    /// trivially for a build that never asks anyone, and every other test here
    /// reads `rows` rather than `asked`, so none of them would notice which of
    /// the two filters produced the silence.
    @Test("a paired machine is asked")
    func pairedMachinesAreProbed() async throws {
        let host = Self.makeHost("Studio")
        let probe = StubProbe([host.id: .reachable])
        let model = try await Self.makeModel(hosts: [host], probe: probe)

        await model.load()

        #expect(await probe.asked == [host.id])
    }

    /// A machine with no answer is not accused of being down.
    ///
    /// `.unknown` renders as no sentence, which is the honest projection: the
    /// probe established nothing. Rendering it as a problem would put "isn't
    /// answering" under every machine at launch, a claim the user would have to
    /// disprove.
    @Test("a machine with no answer is not reported as a problem")
    func unknownIsNotRenderedAsAFailure() async throws {
        let host = Self.makeHost("Studio")
        let model = try await Self.makeModel(hosts: [host], probe: StubProbe([:]))

        await model.load()

        let row = try #require(await model.rows.first)
        #expect(row.unreachableDetail == nil)
        // Still connectable: the pairing is good and nothing has contradicted
        // it. Withholding the row on an absent measurement would make a launch
        // with no network look like an unpaired Mac.
        #expect(row.isConnectable)
    }
}

import Foundation
import Testing

@testable import Localis

import LocalisModels
import SessionStore
import TransportKit

/// Opening a stored session must be able to end with a usable composer.
///
/// **The deadlock this suite exists for (#25).** A session read back from disk
/// is normalized to `.disconnected` — correctly, because no connection objects
/// exist after a relaunch and `.idle` means *connected and not busy*. But
/// `canSend` is true for `.idle` alone, and the only two writes that produce
/// `.idle` live at the end of a completed turn, whose precondition is `canSend`.
/// So the state is entered on every cold start and left by nothing: every
/// pre-existing conversation's composer is permanently grey.
///
/// **Why the assertion is on `load()` rather than on any transport.** The
/// missing piece is not a bridge call — `BridgeClient` exists and works. It is
/// that no code path anywhere asks it to connect and writes the answer back. A
/// test that reached for a transport double would pass the day someone added a
/// double and still leave the app dead, because the app builds neither. What
/// has to become true is narrower and checkable: after `load()` returns for a
/// session on a reachable host, the session is sendable.
@Suite("Reconnecting a session read back from disk")
struct SessionReconnectTests {
    /// Two repositories over one container, the way a relaunch sees it.
    ///
    /// Not one repository reused: an in-process cache would let the second read
    /// succeed without a round trip, and this suite would go green against an
    /// app that never re-reads at all.
    private static func relaunching(
        _ write: (SwiftDataSessionRepository) async throws -> Void
    ) async throws -> SwiftDataSessionRepository {
        let container = try SessionStoreContainer.inMemory()
        try await write(SwiftDataSessionRepository(container: container))
        return SwiftDataSessionRepository(container: container)
    }

    /// A Keychain stand-in with a pin for every machine.
    ///
    /// The store has no pin column, so a host read back from it is
    /// `canConnect == false` and `SessionDetailModel` refuses to build a
    /// transport for it. That refusal is correct and is not this suite's
    /// subject: #25 is about a *paired, reachable* machine whose composer stays
    /// grey. Without this, every test here would be blocked one step earlier,
    /// for a pairing reason, and would look like the deadlock returning.
    private struct AnyPin: PinReading {
        func pin(for host: HostID) throws -> SPKIHash? { SPKIHash(base64: "AAA=") }
    }

    /// A detail model wired the way `SessionDetailView` wires one, with the
    /// Keychain and the transport substituted.
    ///
    /// `EchoTransport` is a `LocalisTests` fixture as of milestone B — the app
    /// builds a `BridgeClient` per host now, and no test can use that without a
    /// Mac on the network. Its `probe` answers `.reachable` unconditionally,
    /// which is exactly the premise this suite needs: the host answers, and the
    /// question is whether the composer opens.
    private static func detailModel(
        repository: any SessionRepository,
        sessionID: UUID
    ) async -> SessionDetailModel {
        await SessionDetailModel(
            repository: repository,
            sessionID: sessionID,
            credentials: AnyPin(),
            makeTransport: { _ in EchoTransport() }
        )
    }

    /// A paired machine with one signed-in agent and one stored conversation.
    ///
    /// Stored `.idle` deliberately. The point is that storing the *best*
    /// possible status still comes back unsendable, so the failure cannot be
    /// blamed on the fixture having saved something pessimistic.
    ///
    /// `pairingState: .paired` for the same reason, one layer down: a
    /// `.discovered` record is one `SessionDetailModel` correctly refuses to
    /// build a transport for, and this suite would then be measuring that
    /// refusal rather than #25.
    private static func seed(
        into repository: SwiftDataSessionRepository
    ) async throws -> (host: HostID, session: UUID) {
        let host = LocalisHost(
            id: HostID(),
            displayName: "Tian's MacBook Pro",
            endpoint: HostEndpoint(host: "mac.local", port: 8443),
            bridgeID: "bridge-abc",
            pairingState: .paired
        )
        try await repository.save(host)

        let backend = AgentBackend(
            id: "claude",
            displayName: "Claude Code",
            availability: .available
        )
        try await repository.save(backend, on: host.id)

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let session = Session(
            id: UUID(),
            hostID: host.id,
            backendID: backend.id,
            title: "Yesterday's conversation",
            messages: [],
            createdAt: t0,
            updatedAt: t0,
            status: .idle
        )
        try await repository.create(session)

        return (host.id, session.id)
    }

    /// The deadlock itself, stated as the behaviour the user sees.
    ///
    /// **Recorded red before the fix, and the trait is now gone.** Verbatim from
    /// the run that produced it, kept so that this test's green is evidence
    /// *this* failure went away rather than that the assertion was never live:
    ///
    /// ```
    /// ✘ Test "a conversation from yesterday can be replied to today" recorded
    ///   an issue at SessionReconnectTests.swift:134:15:
    ///   Expectation failed: model.composer?.canSend ?? false
    /// ✘ ... failed after 0.013 seconds with 1 issue.
    /// ```
    ///
    /// **One issue, and it was the last assertion.** The three before it passed,
    /// which was the substance of the finding: `loadError` nil, `composer`
    /// non-nil, `sendBlockedReason` nil. The transcript loaded, the backend
    /// resolved, nothing reported a problem — and the composer still could not
    /// send. Nothing was broken except that no path existed to say the link was
    /// up.
    ///
    /// It must not be made green by relaxing `restoredStatus` to bring `.idle`
    /// back — that would hand the composer over by declaring a connection that
    /// does not exist, which is FR-053 inverted and the reason the
    /// normalization is there. `orphanedSessionStaysBlocked` below is the
    /// tripwire on exactly that shortcut, and it was green before this fix and
    /// stays green after it.
    @Test("a conversation from yesterday can be replied to today")
    func restoredSessionBecomesSendable() async throws {
        var ids: (host: HostID, session: UUID)?
        let repository = try await Self.relaunching { seeded in
            ids = try await Self.seed(into: seeded)
        }
        let sessionID = try #require(ids?.session)

        let model = await Self.detailModel(repository: repository, sessionID: sessionID)
        await model.load()

        // Reading is never gated (FR-036), and that half already works.
        await #expect(model.loadError == nil)
        await #expect(model.composer != nil)
        await #expect(model.sendBlockedReason == nil)

        // The half that does not.
        await #expect(model.composer?.canSend ?? false)
    }

    /// The guard rail on the fix, and the reason it is a separate test.
    ///
    /// The cheapest way to make the test above pass is to stop normalizing, or
    /// to write `.idle` on load unconditionally. Either would also make *this*
    /// session sendable — one whose host is not paired at all — and that is the
    /// state `.orphaned` exists to represent. So this asserts the opposite
    /// direction, and it is live today because the current behaviour is already
    /// correct: it must stay green through the fix, not become green because of
    /// it.
    @Test("a conversation on an unpaired machine stays unsendable")
    func orphanedSessionStaysBlocked() async throws {
        var sessionID: UUID?
        let repository = try await Self.relaunching { seeded in
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let session = Session(
                id: UUID(),
                // No host row is written, so this points at a machine the user
                // never paired — the foreign key dangles by construction.
                hostID: HostID(),
                backendID: "claude",
                title: "On a Mac that isn't paired",
                messages: [],
                createdAt: t0,
                updatedAt: t0,
                status: .idle
            )
            try await seeded.create(session)
            sessionID = session.id
        }
        let id = try #require(sessionID)

        let model = await Self.detailModel(repository: repository, sessionID: id)
        await model.load()

        await #expect(model.composer?.canSend == false)
    }
}

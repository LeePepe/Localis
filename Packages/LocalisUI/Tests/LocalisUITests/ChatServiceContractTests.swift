import Foundation
import Testing

@testable import LocalisUI

import ChatService
import LocalisModels

/// The seam between `ChatService`'s session mapping and this layer's wording.
///
/// These two were written independently and agreed by coincidence. Nothing
/// failed if one side changed its mind — the user was simply told a turn that
/// was still running had died. `core` made `sessionStatus` public so the
/// agreement could be asserted instead of restated; this suite is that
/// assertion, and it lives here because this is the side that would be wrong.
@Suite("ChatService session mapping meets the composer's wording")
struct ChatServiceContractTests {
    private static func composerState(for status: SessionStatus) -> ComposerState {
        ComposerState.make(
            from: Session(
                id: UUID(), hostID: HostID(rawValue: UUID()), backendID: "claude",
                title: "Session", createdAt: .init(timeIntervalSince1970: 0),
                updatedAt: .init(timeIntervalSince1970: 0), status: status
            )
        )
    }

    @Test("a detached turn reads as disconnected, not as an error")
    func detachedMapsToDisconnected() {
        // The turn is running fine on the host; an `.error` banner would be a
        // lie about the work. Asserted against the real mapping rather than a
        // copy of it.
        let status = ChatService.sessionStatus(for: .detached, reason: .connectionLost)

        #expect(status == .disconnected)
    }

    @Test("every in-flight status reads as disconnected")
    func everyInFlightStatusMapsToDisconnected() {
        // `sessionStatus` branches on `isInFlight`, not on `.detached` alone, so
        // pinning the one case would leave the other two free to drift. The
        // composer's offline wording is read for all of them.
        for settled in MessageStatus.allCases where settled.isInFlight {
            let status = ChatService.sessionStatus(for: settled, reason: .connectionLost)
            #expect(status == .disconnected, "\(settled)")
        }
    }

    @Test("the wording a detached turn lands on offers reading, not a verdict")
    func detachedWordingDoesNotDeclareTheTurnDead() {
        // The whole chain in one assertion: `.detached` → `.disconnected` →
        // this sentence. It offers to keep reading and says nothing about the
        // reply having ended, because at this moment it may not have.
        let status = ChatService.sessionStatus(for: .detached, reason: .connectionLost)
        let state = Self.composerState(for: status)

        #expect(state.canSend == false)
        #expect(state.blockedReason == "This Mac isn't reachable. You can still read the conversation.")
    }

    @Test("a settled failure reads as an error, and says so in the domain's words")
    func settledFailureSurfacesTheError() {
        // The other half of the branch. `interrupted` is not in flight, so the
        // link is not what's wrong — something failed, and the composer should
        // say what, rather than offering to keep reading.
        let status = ChatService.sessionStatus(for: .interrupted, reason: .connectionLost)
        let state = Self.composerState(for: status)

        #expect(status == .error(.connectionLost))
        #expect(state.blockedReason == LocalisError.connectionLost.userMessage)
    }

    @Test("the two branches never produce the same wording")
    func inFlightAndSettledAreDistinguishable() {
        // If these ever collapsed, a still-running turn and a dead one would be
        // indistinguishable to the user — which is the exact confusion
        // Amendment C §1.5 split the states to prevent.
        let running = Self.composerState(
            for: ChatService.sessionStatus(for: .detached, reason: .connectionLost)
        )
        let dead = Self.composerState(
            for: ChatService.sessionStatus(for: .interrupted, reason: .connectionLost)
        )

        #expect(running.blockedReason != dead.blockedReason)
    }
}

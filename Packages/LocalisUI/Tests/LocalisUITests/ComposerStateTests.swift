import Foundation
import Testing

@testable import LocalisUI

import ChatService
import LocalisModels

/// FR-053: a session that cannot deliver must refuse input *visibly*, rather
/// than accept text and fail after the user hits send.
///
/// "Visibly" is why this projection carries a reason and not just a `Bool`. A
/// greyed-out composer with no explanation is the same dead end as one that
/// fails on send — the user still cannot tell whether to wait, re-pair, or give
/// up.
@Suite("Composer state projection")
struct ComposerStateTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hostA = HostID(rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)

    private static func session(_ status: SessionStatus, messages: [Message] = []) -> Session {
        Session(
            id: UUID(), hostID: hostA, backendID: "claude", title: "Session",
            messages: messages, createdAt: t0, updatedAt: t0, status: status
        )
    }

    @Test("an idle session can send")
    func idleCanSend() {
        let state = ComposerState.make(from: Self.session(.idle))

        #expect(state.canSend)
        #expect(state.blockedReason == nil)
    }

    @Test("sendability follows the domain, never a second opinion")
    func sendabilityMatchesDomain() {
        // `Session.canSend` is the single authority (Session.swift:66). If this
        // projection ever disagrees, one of the two is showing the user a lie.
        for status in Self.allStatuses {
            let session = Self.session(status)
            #expect(ComposerState.make(from: session).canSend == session.canSend, "\(status)")
        }
    }

    @Test("a session restored from disk cannot send")
    func restoredSessionCannotSend() {
        // The store normalizes every live-connection status to `.disconnected`
        // on read, so this is the state the composer meets after a relaunch.
        // It must not offer to send over a connection nobody opened.
        let state = ComposerState.make(from: Self.session(.disconnected))

        #expect(state.canSend == false)
        #expect(state.blockedReason != nil)
    }

    @Test("every blocked state says why, in words")
    func blockedStatesExplainThemselves() throws {
        let blocked: [SessionStatus] = [
            .disconnected, .connecting, .streaming, .orphaned, .error(.unreachable)
        ]
        for status in blocked {
            let reason = try #require(
                ComposerState.make(from: Self.session(status)).blockedReason,
                "\(status) blocked with no explanation"
            )
            #expect(reason.isEmpty == false, "\(status)")
        }
    }

    /// Every status the composer can meet. Written out because `SessionStatus`
    /// carries an associated value and so cannot be `CaseIterable`; a seventh
    /// case added upstream will not appear here on its own, which is why the
    /// tests below assert an *invariant* over the list rather than a table of
    /// expected strings.
    private static let allStatuses: [SessionStatus] = [
        .idle, .disconnected, .connecting, .streaming, .orphaned, .error(.unreachable)
    ]

    @Test("a reason is present exactly when the composer is closed")
    func reasonPresenceMatchesSendability() {
        // The two fields are one fact stated twice, and `ComposerView` trusts
        // that: it draws the notice bar on `blockedReason != nil` alone. A
        // sendable session carrying a reason would explain a block that isn't
        // happening; a blocked one carrying `nil` would refuse input silently,
        // which is the exact failure FR-053 names.
        for status in Self.allStatuses {
            let state = ComposerState.make(from: Self.session(status))
            #expect(state.canSend == (state.blockedReason == nil), "\(status)")
        }
    }

    @Test("no reason is blank")
    func noReasonIsBlank() {
        // `blockedReason(for:)` has an unreachable `.idle` branch returning "",
        // chosen over a crash so a future status change cannot take the composer
        // down. The cost is that an empty string is representable — and the view
        // would render it as an icon beside nothing at all. Emptiness must stay
        // spelled `nil`, never "".
        for status in Self.allStatuses {
            guard let reason = ComposerState.make(from: Self.session(status)).blockedReason else {
                continue
            }
            #expect(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "\(status)")
        }
    }

    @Test("the offline copy does not claim the turn is over")
    func disconnectedCopyPreservesItsAssumption() {
        // This assertion exists to be *in the way*.
        //
        // `ChatService` maps a `detached` turn — link gone, host still
        // generating — onto `.disconnected`. So this copy is read at a moment
        // when work may well still be running on the user's Mac, and it is
        // written accordingly: it offers reading, and says nothing about the
        // reply having ended.
        //
        // `ChatServiceContractTests` now holds the mapping itself, so a change
        // on that side lands there. This one is narrower and still worth
        // keeping: rewording *this string* to "This reply was lost." breaks no
        // mapping and would otherwise pass everything.
        let reason = ComposerState.make(from: Self.session(.disconnected)).blockedReason

        #expect(reason == "This Mac isn't reachable. You can still read the conversation.")
    }

    @Test("an unpaired host explains that it is unpaired, not merely offline")
    func orphanedIsDistinctFromOffline() {
        // Two different user actions: re-pair vs. wait. Collapsing them into
        // one "unavailable" leaves the user with no idea which applies.
        let orphaned = ComposerState.make(from: Self.session(.orphaned)).blockedReason
        let offline = ComposerState.make(from: Self.session(.disconnected)).blockedReason

        #expect(orphaned != offline)
    }

    @Test("an error surfaces the domain's own wording")
    func errorUsesDomainMessage() {
        // Not a UI-invented string: `LocalisError.userMessage` is derived from
        // the code locally, precisely because the bridge's own text may contain
        // absolute paths (constitution I).
        let state = ComposerState.make(from: Self.session(.error(.unauthorized)))

        #expect(state.blockedReason == LocalisError.unauthorized.userMessage)
    }

    @Test("a streaming session offers stop instead of send")
    func streamingOffersStop() {
        #expect(ComposerState.make(from: Self.session(.streaming)).isStreaming)
        #expect(ComposerState.make(from: Self.session(.idle)).isStreaming == false)
    }

    // MARK: - Draft validation

    @Test("an empty draft is not sendable even when the session is ready")
    func emptyDraftIsNotSendable() {
        let state = ComposerState.make(from: Self.session(.idle))

        #expect(state.canSubmit(draft: "") == false)
        #expect(state.canSubmit(draft: "   \n  ") == false)
        #expect(state.canSubmit(draft: "hello"))
    }

    @Test("a non-empty draft is still not sendable on a blocked session")
    func draftCannotOverrideBlock() {
        let state = ComposerState.make(from: Self.session(.orphaned))

        #expect(state.canSubmit(draft: "hello") == false)
    }
}

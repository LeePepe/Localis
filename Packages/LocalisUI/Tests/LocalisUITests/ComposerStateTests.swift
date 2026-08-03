import Foundation
import Testing

@testable import LocalisUI

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
        let statuses: [SessionStatus] = [
            .idle, .disconnected, .connecting, .streaming, .orphaned, .error(.unreachable)
        ]
        for status in statuses {
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
    func blockedStatesExplainThemselves() {
        let blocked: [SessionStatus] = [
            .disconnected, .connecting, .streaming, .orphaned, .error(.unreachable)
        ]
        for status in blocked {
            let reason = ComposerState.make(from: Self.session(status)).blockedReason
            let text = try? #require(reason)
            #expect(text?.isEmpty == false, "\(status) blocked with no explanation")
        }
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

import Foundation
import LocalisModels

/// View-ready projection of a session's composer.
///
/// FR-053 says a session that cannot deliver must refuse input *visibly*. That
/// is why this type carries a `blockedReason` and not just a `Bool`: a greyed
/// field with no explanation is the same dead end as one that accepts text and
/// fails on send — the user still cannot tell whether to wait, re-pair, or give
/// up.
public struct ComposerState: Equatable, Sendable {
    /// Whether the session itself can accept a message right now.
    public let canSend: Bool
    /// Why not, in words the user can act on. `nil` exactly when `canSend`.
    public let blockedReason: String?
    /// A turn is in flight, so the control is stop rather than send.
    public let isStreaming: Bool

    public init(canSend: Bool, blockedReason: String?, isStreaming: Bool) {
        self.canSend = canSend
        self.blockedReason = blockedReason
        self.isStreaming = isStreaming
    }

    public static func make(from session: Session) -> ComposerState {
        // `Session.canSend` is the single authority on sendability. Re-deriving
        // it from the status here would be a second opinion, and the two would
        // drift — one of them then showing the user a lie.
        ComposerState(
            canSend: session.canSend,
            blockedReason: session.canSend ? nil : blockedReason(for: session.status),
            isStreaming: session.status == .streaming
        )
    }

    /// Whether this draft may be submitted.
    ///
    /// Two independent gates, and the session's comes first: a non-empty draft
    /// can never unblock an unpaired host.
    public func canSubmit(draft: String) -> Bool {
        canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Why the composer is closed.
    ///
    /// Every branch names a *different user action* — wait, re-pair, retry —
    /// because collapsing them into one "unavailable" leaves the user with no
    /// idea which applies.
    ///
    /// `.error` defers to `LocalisError.userMessage` rather than inventing
    /// wording: that text is derived locally from the code precisely so the
    /// bridge's own message, which may contain absolute paths, never reaches a
    /// screen (constitution I).
    private static func blockedReason(for status: SessionStatus) -> String {
        switch status {
        case .disconnected:
            return String(localized: "This Mac isn't reachable. You can still read the conversation.")
        case .connecting:
            return String(localized: "Connecting…")
        case .streaming:
            return String(localized: "Waiting for the current reply to finish.")
        case .orphaned:
            return String(localized: "This Mac is unpaired. Pair it again to continue the conversation.")
        case .error(let error):
            return error.userMessage
        case .idle:
            // Unreachable: `canSend` is true here, so the caller never asks.
            // Returning empty rather than crashing keeps a future status change
            // from taking the composer down with it.
            return ""
        }
    }
}

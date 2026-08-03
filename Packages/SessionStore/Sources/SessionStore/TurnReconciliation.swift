import Foundation

/// The delivery state the store persists for an assistant turn.
///
/// Amendment C §1.5 splits what used to be one "interrupted" state into two,
/// and the distinction is the whole point of the type:
///
/// - `detached` — the connection dropped, **the host is still generating**.
/// - `interrupted` — the content is actually gone (the host doesn't support
///   resume, or the retention window expired).
///
/// Collapsing them is the most dangerous simplification available here: a
/// `detached` turn shown as "interrupted, retry?" makes the user start a second
/// job on their own machine while the first is still running.
///
/// This mirrors the domain's message state but is the store's own vocabulary —
/// persistence keeps a stable spelling even if the domain enum is renamed.
public enum StoredDeliveryState: String, CaseIterable, Codable, Sendable {
    /// Receiving now, in this process.
    case streaming
    /// Link gone, host still working. Resumable — never retryable.
    case detached
    /// Content lost. Retryable, because there is nothing left to resume.
    case interrupted
    /// Fully received.
    case complete
    /// Ended in an error the user was told about.
    case failed
}

/// What the app should do about a stored turn when it comes back.
public enum TurnReconciliation: Hashable, Sendable {
    /// Nothing to do — the turn reached a terminal state before we left.
    case settled
    /// The host may still be generating; pick the stream up from this cursor.
    case stillRunning(ResumeCursor)
    /// The content is gone. This is the only outcome that may offer a retry.
    case lost

    /// Whether the UI may offer "retry".
    ///
    /// Deliberately a property of the reconciliation rather than of the state:
    /// it is the answer to "is there still a job running on the user's machine",
    /// and only `lost` can answer no.
    public var allowsRetry: Bool {
        self == .lost
    }

    /// Resolves a stored turn into one of the three situations the app can face
    /// on return: it finished, it's still going, or it's gone.
    ///
    /// A cursor is what makes resuming possible at all, so every non-terminal
    /// state without one degrades to `.lost` — claiming a turn is resumable with
    /// no resume point would strand it as permanently "still running".
    public static func resolve(state: StoredDeliveryState, cursor: ResumeCursor?) -> TurnReconciliation {
        switch state {
        case .complete, .failed:
            return .settled
        case .interrupted:
            return .lost
        case .detached, .streaming:
            // `.streaming` reaching this point means the process that owned the
            // stream is gone (a kill, a crash), so it is never still streaming —
            // it is either resumable or lost, exactly like `.detached`.
            guard let cursor else { return .lost }
            return .stillRunning(cursor)
        }
    }
}

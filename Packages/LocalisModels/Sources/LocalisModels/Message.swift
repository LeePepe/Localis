import Foundation

/// Who produced a message.
public enum MessageRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case system
    /// Output of a tool invocation surfaced back into the transcript.
    case tool
}

/// Delivery state of a message.
///
/// The states exist to answer one question honestly when the user returns to the
/// app: **what happened to the answer that was in flight?** There are three
/// genuinely different outcomes, and the states keep them apart:
///
/// | Came back to find | State | What the user is offered |
/// |---|---|---|
/// | the stream finished while away | `complete` | nothing to do |
/// | it is still running on the host | `detached` | "still running on <host>" + cancel |
/// | it died and the text is gone | `interrupted` | "interrupted" + retry |
///
/// Amendment C §1.5: `detached` and `interrupted` must never be conflated.
/// Labelling a live turn "interrupted" invites a retry, which starts a *second*
/// generation on the host while the first is still going.
public enum MessageStatus: String, Codable, CaseIterable, Sendable {
    /// Queued locally; nothing sent yet.
    case pending
    /// Content is arriving.
    case streaming
    /// The connection dropped but the host kept generating and is buffering the
    /// output for us to resume from (Amendment C §1.3). Not an error.
    case detached
    /// Content was genuinely lost — the host does not support resumable turns,
    /// or the retention window expired, or the buffer overflowed. The partial
    /// text is kept (FR-019); a retry is safe because nothing is still running.
    case interrupted
    case complete
    case failed

    /// Whether the turn is finished for good and cannot gain more content.
    ///
    /// `interrupted` is not terminal: the turn can be retried and this message
    /// superseded.
    public var isTerminal: Bool {
        switch self {
        case .complete, .failed: return true
        case .pending, .streaming, .detached, .interrupted: return false
        }
    }

    /// Whether the UI may offer a retry.
    ///
    /// The safety property: **never** while the host might still be working. A
    /// retry on a `detached` turn duplicates work already underway.
    public var isRetryable: Bool {
        switch self {
        case .interrupted, .failed: return true
        case .pending, .streaming, .detached, .complete: return false
        }
    }

    /// Whether the host may still be producing content for this message.
    public var isInFlight: Bool {
        switch self {
        case .streaming, .detached, .pending: return true
        case .interrupted, .complete, .failed: return false
        }
    }
}

/// One turn in a chat transcript.
///
/// Immutable: streaming appends produce a new value via `appending(_:)`.
public struct Message: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let text: String
    public let createdAt: Date
    public let status: MessageStatus
    /// How far the turn got before it died — present only when `status` is
    /// `.failed` (contract §3.1(d)).
    ///
    /// Stored on the message rather than held in a stream event because the
    /// message is what survives a relaunch, and force-quitting before seeing the
    /// failure is precisely the case background resume exists for.
    ///
    /// The tie to `.failed` is maintained by the initialiser, not by convention:
    /// there is no code path that produces a `.complete` message still carrying
    /// "failed 8 minutes in".
    public let failure: TurnFailure?

    public init(
        id: UUID,
        role: MessageRole,
        text: String,
        createdAt: Date,
        status: MessageStatus = .complete,
        failure: TurnFailure? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.status = status
        // Detail without a failure is a contradiction the rest of the app would
        // have to keep re-checking. Drop it once, here.
        self.failure = status == .failed ? failure : nil
    }

    /// Decodes messages stored before `failure` existed.
    ///
    /// SessionStore holds rows written by earlier builds; failing on them would
    /// lose the user's transcript on upgrade.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            role: try container.decode(MessageRole.self, forKey: .role),
            text: try container.decode(String.self, forKey: .text),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            status: try container.decode(MessageStatus.self, forKey: .status),
            failure: try container.decodeIfPresent(TurnFailure.self, forKey: .failure)
        )
    }

    /// Returns a copy with `chunk` appended — the streaming path.
    ///
    /// Appending to a `detached` message puts it back into `streaming`: content
    /// is flowing again after a resume. Appending to a message that already
    /// finished is a **no-op**, which is what stops a late frame from the old
    /// connection reopening a completed message when a resumed stream and the
    /// original briefly overlap (Amendment C §5).
    public func appending(_ chunk: String) -> Message {
        guard !status.isTerminal else { return self }
        return Message(
            id: id,
            role: role,
            text: text + chunk,
            createdAt: createdAt,
            status: .streaming
        )
    }

    /// Returns a copy marked with a different status.
    ///
    /// Moving off `.failed` drops the failure detail: a retry that succeeds must
    /// not keep "failed 8 minutes in" attached, where it would read as a fresh
    /// failure on a finished answer.
    public func withStatus(_ newStatus: MessageStatus) -> Message {
        Message(
            id: id, role: role, text: text, createdAt: createdAt,
            status: newStatus, failure: failure
        )
    }

    /// Marks the turn failed **with** the progress the host reported.
    ///
    /// One call, not a status setter plus a detail setter, because the contract
    /// states it as one rule: mark it failed *and* carry the progress. Separate
    /// setters would permit a `.failed` message with nothing to show — the bare
    /// "Error" that §3.1(d) exists to forbid.
    public func failed(_ failure: TurnFailure) -> Message {
        Message(
            id: id, role: role, text: text, createdAt: createdAt,
            status: .failed, failure: failure
        )
    }

    /// See `MessageStatus.isTerminal`.
    public var isTerminal: Bool { status.isTerminal }

    /// See `MessageStatus.isRetryable` — false while the host may still be working.
    public var isRetryable: Bool { status.isRetryable }

    /// See `MessageStatus.isInFlight`.
    public var isInFlight: Bool { status.isInFlight }

    /// The connection dropped, but the host is still generating (Amendment C).
    ///
    /// Distinct from `interrupted()` precisely so the UI cannot offer a retry.
    public func detached() -> Message {
        withStatus(.detached)
    }

    /// Content was lost: keep what arrived, allow a retry (FR-019).
    ///
    /// Also the correct outcome for a resume that came back truncated — better
    /// to admit the gap than to present a partial answer as finished
    /// (Amendment C §1.6).
    public func interrupted() -> Message {
        withStatus(.interrupted)
    }
}

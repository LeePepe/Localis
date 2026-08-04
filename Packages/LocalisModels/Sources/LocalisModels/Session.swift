import Foundation

/// A conversation, bound to exactly one host.
///
/// **`hostID` is fixed at creation and never changes** (FR-030). Resume
/// semantics live in *that* bridge's process, `workspace` is a path on *that*
/// machine, and the backend list and skill catalogue are that machine's too — so
/// "move this chat to the other Mac" is not an operation that can be given a
/// meaning. There is deliberately no API for it here, and the UI must not offer
/// one. Changing machines means starting a new conversation.
///
/// `backendID` *is* changeable, and takes effect from the next message; earlier
/// messages keep whatever produced them (Amendment A §3).
///
/// The `messages` array is the transcript in chronological order. Every mutating
/// operation returns a new `Session`.
public struct Session: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// The machine this conversation belongs to. Immutable for life (FR-030).
    public let hostID: HostID
    /// The backend used for the *next* message. Wire string, unique within the
    /// host — use `backendRef` for anything that needs a global key.
    public let backendID: String
    public let title: String
    public let messages: [Message]
    public let createdAt: Date
    public let updatedAt: Date
    public let status: SessionStatus

    public init(
        id: UUID,
        hostID: HostID,
        backendID: String,
        title: String,
        messages: [Message] = [],
        createdAt: Date,
        updatedAt: Date,
        status: SessionStatus = .idle
    ) {
        self.id = id
        self.hostID = hostID
        self.backendID = backendID
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
    }

    /// Most recent message, if any — drives the session-list preview row.
    public var lastMessage: Message? { messages.last }

    /// This session's backend as a globally unique key (FR-040).
    ///
    /// Every lookup by backend goes through this. A bare `backendID` comparison
    /// would match the same-named backend on a different machine.
    public var backendRef: BackendRef {
        BackendRef(hostID: hostID, backendID: backendID)
    }

    /// Whether the composer may send.
    ///
    /// FR-053: a session that cannot deliver must refuse input visibly, rather
    /// than accept text and fail after the user hits send. Reading is never
    /// gated — an unreachable host's history stays fully browsable (FR-036).
    public var canSend: Bool { status == .idle }

    /// Returns a copy with `message` appended and `updatedAt` advanced.
    public func appending(_ message: Message, at timestamp: Date) -> Session {
        with(messages: messages + [message], updatedAt: timestamp)
    }

    /// Returns a copy where the message with `message.id` is replaced.
    ///
    /// Used by the streaming path: each chunk yields a new `Message` that
    /// supersedes the previous one. No-op if the id is absent — a stale id must
    /// not corrupt a transcript by appending a duplicate.
    public func replacing(_ message: Message, at timestamp: Date) -> Session {
        guard messages.contains(where: { $0.id == message.id }) else { return self }
        return with(
            messages: messages.map { $0.id == message.id ? message : $0 },
            updatedAt: timestamp
        )
    }

    public func withTitle(_ newTitle: String, at timestamp: Date) -> Session {
        with(title: newTitle, updatedAt: timestamp)
    }

    /// Switches the backend for subsequent messages. History is untouched.
    public func withBackendID(_ newBackendID: String, at timestamp: Date) -> Session {
        with(backendID: newBackendID, updatedAt: timestamp)
    }

    /// Returns a copy in a new status, **leaving `updatedAt` where it was**.
    ///
    /// **Why this takes no timestamp when its four neighbours above do.** Both
    /// repositories order the session list by `updatedAt` descending
    /// (`SwiftDataSessionRepository.swift:46` and `:55`,
    /// `SessionRepository.swift:136`), and nothing anywhere renders the value —
    /// `SessionRowState` has no time field at all. So the field is a sort key
    /// and only a sort key, and writing it means exactly one thing to the user:
    /// *this conversation just had activity, put it at the top.*
    ///
    /// A status change is not that. `.idle`, `.disconnected`, `.connecting`,
    /// `.error` and `.orphaned` are facts about the link and about pairing —
    /// they are entered by opening a screen, by a probe answering, by a Mac
    /// being unpaired. None of those is the user receiving anything. When this
    /// took a timestamp, opening a conversation that failed yesterday moved it
    /// above conversations that had genuinely replied, which on screen is
    /// indistinguishable from a new message. Nothing errors and nothing looks
    /// broken; the list is quietly sorted by "recently viewed" while claiming
    /// to be sorted by activity (#28).
    ///
    /// **The parameter is removed rather than left to callers to pass `nil`.**
    /// Every real activity path already advances `updatedAt` on the line before
    /// this one — `appending` when the turn is sent, `replacing` on each
    /// streamed chunk — so the timestamp here was load-bearing at exactly one
    /// of its four call sites, the one that was wrong. Keeping it would leave
    /// the mistake writable and rely on each future caller re-deriving this
    /// argument; deleting it makes "declare new activity" and "record a status"
    /// two operations that cannot be performed by accident as one.
    ///
    /// A path that genuinely needs both says so in two lines:
    /// `session.appending(message, at: now).withStatus(.streaming)`.
    ///
    /// This now matches `Message.withStatus(_:)`, which never took a timestamp.
    public func withStatus(_ newStatus: SessionStatus) -> Session {
        with(status: newStatus)
    }

    /// Marks the session read-only because its host was unpaired.
    ///
    /// FR-027: unpairing never deletes a message. The transcript stays intact
    /// and only sending is disabled; deletion happens only when the user asks.
    ///
    /// No timestamp, per `withStatus`: unpairing a Mac would otherwise reorder
    /// every conversation on it to the top of the list at the moment they all
    /// became unsendable — the loudest possible presentation of the one event
    /// that added no content.
    public func orphaned() -> Session {
        withStatus(.orphaned)
    }

    /// Brings a session back after its host was paired again.
    public func reactivated() -> Session {
        withStatus(.idle)
    }

    private func with(
        backendID: String? = nil,
        title: String? = nil,
        messages: [Message]? = nil,
        updatedAt: Date? = nil,
        status: SessionStatus? = nil
    ) -> Session {
        Session(
            id: id,
            hostID: hostID,
            backendID: backendID ?? self.backendID,
            title: title ?? self.title,
            messages: messages ?? self.messages,
            createdAt: createdAt,
            updatedAt: updatedAt ?? self.updatedAt,
            status: status ?? self.status
        )
    }
}

/// A session's connection state, shown in the chat header (FR-024).
///
/// An explicit enum rather than a set of booleans, so impossible combinations
/// cannot be represented (constitution VI).
public enum SessionStatus: Codable, Hashable, Sendable {
    /// The host is not currently reachable. History remains readable (FR-036).
    case disconnected
    case connecting
    /// Ready to send.
    case idle
    case streaming
    /// The host was unpaired: read-only, and never auto-deleted (FR-027).
    case orphaned
    /// Something failed, with the message to show the user.
    case error(LocalisError)
}

import Foundation

/// A conversation with one agent backend.
///
/// The `messages` array is the transcript in chronological order. All mutating
/// operations return a new `Session`.
public struct Session: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let backendID: UUID
    public let title: String
    public let messages: [Message]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        backendID: UUID,
        title: String,
        messages: [Message] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.backendID = backendID
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Most recent message, if any — drives the session-list preview row.
    public var lastMessage: Message? { messages.last }

    /// Returns a copy with `message` appended and `updatedAt` advanced.
    public func appending(_ message: Message, at timestamp: Date) -> Session {
        Session(
            id: id,
            backendID: backendID,
            title: title,
            messages: messages + [message],
            createdAt: createdAt,
            updatedAt: timestamp
        )
    }

    /// Returns a copy where the message with `message.id` is replaced.
    ///
    /// Used by the streaming path: each chunk yields a new `Message` that
    /// supersedes the previous one. No-op if the id is absent.
    public func replacing(_ message: Message, at timestamp: Date) -> Session {
        guard messages.contains(where: { $0.id == message.id }) else { return self }
        return Session(
            id: id,
            backendID: backendID,
            title: title,
            messages: messages.map { $0.id == message.id ? message : $0 },
            createdAt: createdAt,
            updatedAt: timestamp
        )
    }

    /// Returns a copy with a new title.
    public func withTitle(_ newTitle: String, at timestamp: Date) -> Session {
        Session(
            id: id,
            backendID: backendID,
            title: newTitle,
            messages: messages,
            createdAt: createdAt,
            updatedAt: timestamp
        )
    }
}

import Foundation

/// Who produced a message.
public enum MessageRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case system
    /// Output of a tool/skill invocation surfaced back into the transcript.
    case tool
}

/// Delivery state of a message in the UI.
public enum MessageStatus: String, Codable, Sendable {
    case pending
    case streaming
    case complete
    case failed
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

    public init(
        id: UUID,
        role: MessageRole,
        text: String,
        createdAt: Date,
        status: MessageStatus = .complete
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.status = status
    }

    /// Returns a copy with `chunk` appended — the streaming path.
    public func appending(_ chunk: String) -> Message {
        Message(
            id: id,
            role: role,
            text: text + chunk,
            createdAt: createdAt,
            status: .streaming
        )
    }

    /// Returns a copy marked with a terminal status.
    public func withStatus(_ newStatus: MessageStatus) -> Message {
        Message(id: id, role: role, text: text, createdAt: createdAt, status: newStatus)
    }
}

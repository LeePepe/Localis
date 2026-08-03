import Foundation
import LocalisModels

/// View-ready projection of a `Session` for one row of the session list.
///
/// A plain value type computed from the model, so the row view stays dumb and
/// the projection itself is unit-testable without SwiftUI.
public struct SessionRowState: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    /// Single-line preview of the last message, already truncated.
    public let preview: String
    /// Name of the backend this session talks to, or a fallback when unknown.
    public let backendName: String
    public let isStreaming: Bool

    public init(
        id: UUID,
        title: String,
        preview: String,
        backendName: String,
        isStreaming: Bool
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.backendName = backendName
        self.isStreaming = isStreaming
    }

    /// Longest preview we render before eliding.
    public static let previewLimit = 80

    /// Builds a row from a session and the backends currently configured.
    ///
    /// An unknown `backendID` (backend deleted while sessions remain) renders
    /// as "Unknown agent" rather than crashing or hiding the row.
    public static func make(from session: Session, backends: [AgentBackend]) -> SessionRowState {
        let backend = backends.first { $0.id == session.backendID }
        return SessionRowState(
            id: session.id,
            title: session.title,
            preview: preview(for: session.lastMessage),
            backendName: backend?.name ?? "Unknown agent",
            isStreaming: session.lastMessage?.status == .streaming
        )
    }

    /// Collapses newlines and elides at `previewLimit` so rows stay one line.
    private static func preview(for message: Message?) -> String {
        guard let message else { return "No messages yet" }
        let flattened = message.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "No messages yet" }
        guard flattened.count > previewLimit else { return flattened }
        return String(flattened.prefix(previewLimit)) + "…"
    }
}

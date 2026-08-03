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

    /// Builds a row from a session and the backends its hosts advertise.
    ///
    /// `backends` is keyed by `BackendRef` — `(hostID, backendID)` — not by
    /// backend id, because a backend id is unique only within one machine
    /// (FR-029). Two paired machines both exposing `claude` are two different
    /// backends, and a lookup by id alone returns whichever was found first.
    ///
    /// Not hypothetical: this took `[AgentBackend]` and matched on
    /// `$0.id == session.backendID`, and the first screenshot of the assembled
    /// app showed a laptop session wearing the studio machine's backend name.
    /// The fix is the parameter type rather than the comparison — with a
    /// `BackendRef` key, the host-blind lookup is not something this function
    /// can express any more.
    ///
    /// An absent ref (backend deleted, or the host unpaired while its sessions
    /// remain) renders as "Unknown agent" rather than crashing or hiding the row.
    public static func make(
        from session: Session,
        backends: [BackendRef: AgentBackend]
    ) -> SessionRowState {
        let backend = backends[session.backendRef]
        return SessionRowState(
            id: session.id,
            title: session.title,
            preview: preview(for: session.lastMessage),
            backendName: backend?.displayName ?? "Unknown agent",
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

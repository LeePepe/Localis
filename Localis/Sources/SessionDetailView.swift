import ChatService
import DesignKit
import LocalisModels
import LocalisUI
import SessionStore
import SwiftUI

/// One session: its transcript, and the composer under it.
///
/// Sending goes through `ChatService`, never through the repository directly —
/// the service is the only thing that knows the *order* of persist-then-stream,
/// and a view that saved its own message would write half a turn.
@MainActor
@Observable
final class SessionDetailModel {
    private(set) var messages: [MessageState] = []
    private(set) var composer: ComposerState?
    private(set) var loadError: String?

    private let repository: any SessionRepository
    private let sessionID: UUID
    private var session: Session?
    private var streamTask: Task<Void, Never>?

    init(repository: any SessionRepository, sessionID: UUID) {
        self.repository = repository
        self.sessionID = sessionID
    }

    func load() async {
        do {
            guard let session = try await repository.session(id: sessionID) else {
                // Deleted between the list rendering and the tap. Not an error
                // code — nothing failed — so it gets its own sentence rather
                // than borrowing one that would name a cause that didn't happen.
                loadError = "This session is no longer on this device."
                return
            }
            apply(session)
            loadError = nil
        } catch {
            loadError = (error as? LocalisError)?.userMessage ?? "Please try again."
        }
    }

    /// Projects a session snapshot into what the two views render.
    ///
    /// Every field the views need is a value type by the time it leaves here —
    /// `LocalisUI` never sees a `Session`, a repository, or a service.
    private func apply(_ session: Session) {
        self.session = session
        messages = session.messages.map(MessageState.make(from:))
        composer = ComposerState.make(from: session)
    }

    /// Sends `text` and applies each streamed snapshot as it arrives.
    ///
    /// The stream yields complete `Session` values, so this re-projects rather
    /// than mutating anything in place.
    func send(_ text: String, using service: ChatService, to backend: AgentBackend) {
        guard let session else { return }
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            do {
                let stream = try await service.send(prompt: text, in: session, to: backend)
                for try await snapshot in stream {
                    self?.apply(snapshot)
                }
            } catch {
                // The transcript keeps whatever already arrived; only the
                // reason for stopping is new information.
                self?.loadError = (error as? LocalisError)?.userMessage
                    ?? "The reply stopped early."
            }
        }
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
    }
}

struct SessionDetailView: View {
    @Environment(\.theme) private var theme

    private let repository: any SessionRepository
    private let sessionID: UUID

    @State private var model: SessionDetailModel?
    @State private var draft: String = ""

    init(repository: any SessionRepository, sessionID: UUID) {
        self.repository = repository
        self.sessionID = sessionID
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .task {
            let model = model ?? SessionDetailModel(
                repository: repository, sessionID: sessionID
            )
            self.model = model
            await model.load()
        }
    }

    @ViewBuilder
    private func content(_ model: SessionDetailModel) -> some View {
        if let loadError = model.loadError {
            ContentUnavailableView(
                "Couldn't open this session",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else {
            VStack(spacing: 0) {
                TranscriptView(messages: model.messages)
                if let composer = model.composer {
                    ComposerView(
                        state: composer,
                        draft: $draft,
                        // Sending needs a transport for this session's host,
                        // which pairing does not yet provide. Left unwired
                        // rather than faked: a send button that silently does
                        // nothing is worse than one the composer has already
                        // explained is closed.
                        onSend: { _ in },
                        onStop: { model.cancelStream() }
                    )
                }
            }
            .background(theme.neutrals.bg)
        }
    }
}

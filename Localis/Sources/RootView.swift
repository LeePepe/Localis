import LocalisModels
import LocalisUI
import SessionStore
import SwiftUI

/// Root of the app: loads sessions from the repository and hands the projected
/// rows to `LocalisUI`.
///
/// The repository is the in-memory implementation for now — the disk-backed one
/// conforms to the same `SessionRepository` protocol and swaps in here without
/// touching the view.
struct RootView: View {
    private let repository: any SessionRepository = InMemorySessionRepository()

    @State private var rows: [SessionRowState] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn't load sessions",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else {
                    SessionListView(rows: rows)
                }
            }
        }
        .task { await load() }
    }

    /// Loads sessions + backends and projects them into row state.
    ///
    /// Failures surface in the UI rather than being swallowed — an unreadable
    /// store is a real condition the user needs to see.
    private func load() async {
        do {
            let sessions = try await repository.allSessions()
            let backends = try await repository.allBackends()
            rows = sessions.map { SessionRowState.make(from: $0, backends: backends) }
            loadError = nil
        } catch {
            let localisError = error as? LocalisError
            loadError = localisError?.userMessage ?? "Please try again."
        }
    }
}

#Preview {
    RootView()
}

import DesignKit
import LocalisModels
import LocalisUI
import SessionStore
import SwiftUI

/// Root of the app: the session list, and a transcript for the session tapped.
///
/// The repository is constructed once here and handed down. It is the real,
/// disk-backed one — `SessionStoreContainer.onDisk()` — because a session list
/// that forgets everything on relaunch is not the product.
struct RootView: View {
    private let repository: any SessionRepository
    /// Non-nil when the store could not be opened at all. Kept separate from
    /// `SessionListModel.loadError`: a store that will not open is a different
    /// condition from one that opened and then failed a read, and the first
    /// leaves us with no repository to ask.
    private let storeError: String?

    @State private var model: SessionListModel?
    /// Explicit path so a screenshot run can push the same value a tap pushes.
    @State private var path = NavigationPath()

    init() {
        do {
            let repository = SwiftDataSessionRepository(
                container: try SessionStoreContainer.onDisk()
            )
            self.repository = repository
            self.storeError = nil
        } catch {
            // Falling back rather than crashing: the user can still read and
            // write this launch, and an in-memory store is honest about what it
            // is as long as we say so.
            self.repository = InMemorySessionRepository()
            self.storeError = (error as? LocalisError)?.userMessage
                ?? "Your history couldn't be opened, so this session won't be saved."
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    listContent(model)
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(for: SessionRowState.ID.self) { id in
                SessionDetailView(repository: repository, sessionID: id)
            }
        }
        .task {
            // Screenshot fixtures, written through the real repository and only
            // when the process was launched with `-LocalisDemoSeed`. See
            // `DemoSeed` for why it goes through the store rather than into the
            // views, and why a shipped build cannot reach it.
            if DemoSeed.isRequested {
                await DemoSeed.populateIfEmpty(repository)
            }
            let model = model ?? SessionListModel(repository: repository)
            self.model = model
            await model.load()
            // Same value a tapped row pushes, so this arrives at the transcript
            // through `navigationDestination` rather than beside it.
            if DemoSeed.opensFirstSession, let first = model.rows.first {
                path.append(first.id)
            }
        }
    }

    @ViewBuilder
    private func listContent(_ model: SessionListModel) -> some View {
        if let loadError = model.loadError {
            ContentUnavailableView(
                "Couldn't load sessions",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else {
            VStack(spacing: 0) {
                if let storeError {
                    // `StatusPill` in the danger tone rather than a bespoke
                    // banner: DESIGNKIT.md owns this layer's vocabulary, and a
                    // one-off notice here would be a value I invented.
                    StatusPill(storeError, tone: .danger)
                        .padding(.horizontal, Space.cardPadding)
                        .padding(.bottom, 8)
                }
                SessionListView(rows: model.rows)
            }
        }
    }
}

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
    /// The machines on file, loaded at launch.
    ///
    /// Held here rather than inside the list screen because it is launch state:
    /// "which Macs do I have" is answered once from disk and is what makes a
    /// relaunch show the same machines. A model built inside a screen would
    /// answer it only when that screen happened to be visited.
    @State private var hosts: HostListModel?
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
            // The machines recovered from disk (FR-026). Loaded at launch and
            // shown above the sessions, because an empty session list with a
            // paired Mac on screen is a different, true statement from an empty
            // screen — and until this ran, the app forgot every Mac on quit.
            let hosts = hosts ?? HostListModel(repository: repository)
            self.hosts = hosts
            await hosts.load()
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
                if let hosts {
                    hostStrip(hosts)
                }
                SessionListView(rows: model.rows)
            }
        }
    }

    /// The machines on file, above the sessions.
    ///
    /// **This strip is the visible half of B-1.** A `hosts()` call whose answer
    /// never reaches a pixel is indistinguishable from no call at all — the
    /// store round-trips, every test is green, and the user sees nothing. So
    /// the acceptance test for host persistence is this view showing a Mac
    /// after a cold start, not a passing suite.
    ///
    /// Deliberately not a whole screen yet: pairing has no UI (B-2), so a row
    /// here can be looked at and not tapped. A row that navigated somewhere
    /// unbuilt would be a worse lie than a row that admits it is not paired.
    @ViewBuilder
    private func hostStrip(_ hosts: HostListModel) -> some View {
        if let loadError = hosts.loadError {
            // Read failure is stated, never rendered as "no machines" — see
            // `HostListModel.load`.
            StatusPill(loadError, tone: .danger)
                .padding(.horizontal, Space.cardPadding)
                .padding(.bottom, 8)
        } else if !hosts.rows.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.gap) {
                    ForEach(hosts.rows) { row in
                        CardInner {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title)
                                    .font(TypeScale.title)
                                    .lineLimit(1)
                                Text(row.subtitle)
                                    .font(TypeScale.body)
                                    .lineLimit(1)
                                StatusPill(
                                    row.status,
                                    tone: row.isConnectable ? .primary : .neutral
                                )
                                // FR-060: why this machine is unusable, on the
                                // host list itself.
                                //
                                // **A second line, not a replacement for the
                                // pill.** The pill carries the pairing
                                // relationship and this carries the last probe
                                // result; they are different lifetimes
                                // (FR-061), and overwriting one with the other
                                // is how "this Mac's identity changed" gets
                                // replaced by "isn't answering" the moment the
                                // machine is switched off.
                                //
                                // Absent — not blank — when nothing is known to
                                // be wrong, so an unprobed host makes no claim.
                                if let detail = row.unreachableDetail {
                                    // Rendered through `StatusPill(.danger)`
                                    // rather than a `Text` with a theme colour:
                                    // this view holds no `@Environment(\.theme)`
                                    // and adding one to reach a single colour
                                    // would put a second place where "what a
                                    // problem looks like" is decided.
                                    StatusPill(detail, tone: .danger)
                                        // The sentences name an action; a
                                        // truncated one names half of it.
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.cardPadding)
            }
            .padding(.bottom, 8)
        }
    }
}

import DesignKit
import LocalisModels
import SwiftUI

/// One row of the session list.
///
/// Renders a `SessionRowState` — all projection logic lives in that value type,
/// so this view is pure layout and every token comes from `DesignKit`.
public struct SessionRow: View {
    @Environment(\.theme) private var theme
    private let state: SessionRowState

    public init(state: SessionRowState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: Space.gap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(TypeScale.title)
                    .foregroundStyle(theme.neutrals.text1)
                    .lineLimit(1)
                Text(state.preview)
                    .font(TypeScale.body)
                    .foregroundStyle(theme.neutrals.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.gap)
            StatusPill(state.backendName, tone: state.isStreaming ? .primary : .neutral)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// The root view: every session, newest first.
///
/// Takes already-projected rows so it can be previewed and screenshotted with
/// no store, no transport, and no live agent.
public struct SessionListView: View {
    @Environment(\.theme) private var theme
    private let rows: [SessionRowState]

    public init(rows: [SessionRowState]) {
        self.rows = rows
    }

    public var body: some View {
        Group {
            if rows.isEmpty {
                EmptyStateView(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No sessions yet",
                    message: "Add a local agent to start a conversation."
                )
            } else {
                List(rows) { row in
                    SessionRow(state: row)
                        .listRowBackground(theme.neutrals.card)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Localis")
    }
}

#Preview("Sessions") {
    NavigationStack {
        SessionListView(rows: [
            SessionRowState(
                id: UUID(),
                title: "Refactor TransportKit",
                preview: "Here's the SSE parser split into a pure value type…",
                backendName: "MacBook Claude",
                isStreaming: true
            ),
            SessionRowState(
                id: UUID(),
                title: "Weekend notes",
                preview: "No messages yet",
                backendName: "Studio Kimi",
                isStreaming: false
            )
        ])
    }
    .designTheme()
}

#Preview("Empty") {
    NavigationStack {
        SessionListView(rows: [])
    }
    .designTheme()
}

import DesignKit
import LocalisModels
import SwiftUI

/// One turn in the transcript: the bubble, plus whatever the turn's state earns
/// it — a failure line, a truncation note, the controls it may show.
///
/// The view chooses nothing. `MessageState` has already decided which actions
/// exist, so the `detached` rule (contract rule 8: no retry control at all, not
/// a disabled one) is enforced by there being nothing to iterate over.
public struct MessageRow: View {
    @Environment(\.theme) private var theme

    private let state: MessageState
    private let onAction: (MessageAction) -> Void

    public init(state: MessageState, onAction: @escaping (MessageAction) -> Void = { _ in }) {
        self.state = state
        self.onAction = onAction
    }

    private var side: BubbleSide {
        state.role == .user ? .outgoing : .incoming
    }

    public var body: some View {
        VStack(alignment: side == .outgoing ? .trailing : .leading, spacing: 6) {
            if state.text.isEmpty, state.status == .pending || state.status == .streaming {
                // Nothing has arrived yet: show the stream, not an empty bubble.
                HStack { TypingIndicator(); Spacer(minLength: 40) }
            } else {
                MessageBubble(text: state.text, side: side, isCode: state.role == .tool)
            }

            if let detail = state.failureDetail {
                failureLine(detail)
            }
            if state.isTruncated {
                truncationLine
            }
            if !state.actions.isEmpty {
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: side == .outgoing ? .trailing : .leading)
    }

    /// "failed 8 minutes in, after 3 tool calls" — never a bare "Error"
    /// (contract §3.1(d)). Absent entirely when the host reported nothing,
    /// rather than rendered with zeroes.
    private func failureLine(_ detail: FailureDetail) -> some View {
        Text(detail.summary)
            .font(TypeScale.meta.monospacedDigit())
            .foregroundStyle(theme.danger)
    }

    /// Says the answer is a fragment. FR-019 keeps the partial text; this keeps
    /// the user from reading it as the whole reply.
    private var truncationLine: some View {
        Text("Interrupted — this reply is incomplete.")
            .font(TypeScale.meta)
            .foregroundStyle(theme.neutrals.text2)
    }

    /// Exactly the controls `MessageState` granted.
    ///
    /// Sorted by raw value so the order is stable across renders — a `Set` has
    /// none of its own, and controls that swap places between frames are a way
    /// to make a mis-tap likely.
    private var actionRow: some View {
        HStack(spacing: Space.gap) {
            ForEach(state.actions.sorted { $0.rawValue < $1.rawValue }, id: \.self) { action in
                Button {
                    onAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .font(TypeScale.meta)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.primary.primaryText)
            }
        }
    }
}

/// The transcript: every turn, oldest first, scrolled to the newest.
public struct TranscriptView: View {
    @Environment(\.theme) private var theme

    private let messages: [MessageState]
    private let onAction: (MessageState.ID, MessageAction) -> Void

    public init(
        messages: [MessageState],
        onAction: @escaping (MessageState.ID, MessageAction) -> Void = { _, _ in }
    ) {
        self.messages = messages
        self.onAction = onAction
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.gap) {
                    ForEach(messages) { message in
                        MessageRow(state: message) { onAction(message.id, $0) }
                            .id(message.id)
                    }
                }
                .padding(Space.cardPadding)
                // Reading measure: extra canvas buys context, never longer
                // lines (layout constants, iPad ~700pt).
                .frame(maxWidth: Layout.readingMeasure)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

#Preview("Transcript") {
    let failed = MessageState(
        id: UUID(), role: .assistant, text: "I started on that and then",
        status: .failed,
        actions: [.retry],
        failureDetail: FailureDetail(elapsed: 480, toolCalls: 3),
        isTruncated: false
    )
    let detached = MessageState(
        id: UUID(), role: .assistant, text: "Still working on this one",
        status: .detached,
        // No `.retry`, and that is the point — see contract rule 8.
        actions: [.cancel],
        failureDetail: nil,
        isTruncated: false
    )
    return TranscriptView(messages: [
        MessageState(
            id: UUID(), role: .user, text: "Refactor the parser",
            status: .complete, actions: [], failureDetail: nil, isTruncated: false
        ),
        failed,
        detached
    ])
    .designTheme()
}

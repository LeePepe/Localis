import DesignKit
import LocalisModels
import SwiftUI

/// The composer.
///
/// FR-053: a session that cannot deliver refuses input *visibly*. So a blocked
/// composer does not merely grey out — it replaces itself with the reason,
/// because a dead field with no explanation leaves the user unable to tell
/// whether to wait, re-pair, or give up.
///
/// The draft is owned by the caller. This view renders a snapshot and sends
/// intent up; it never mutates a model in place.
public struct ComposerView: View {
    @Environment(\.theme) private var theme

    private let state: ComposerState
    @Binding private var draft: String
    private let onSend: (String) -> Void
    private let onStop: () -> Void

    public init(
        state: ComposerState,
        draft: Binding<String>,
        onSend: @escaping (String) -> Void = { _ in },
        onStop: @escaping () -> Void = {}
    ) {
        self.state = state
        self._draft = draft
        self.onSend = onSend
        self.onStop = onStop
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = state.blockedReason {
                blockedNotice(reason)
            }
            if state.canSend || state.isStreaming {
                field
            }
        }
        .padding(.horizontal, Layout.chromeInset)
        .padding(.bottom, Layout.chromeInset)
    }

    /// Why the composer is closed, in the words the domain chose.
    private func blockedNotice(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(theme.neutrals.text3)
            Text(reason)
                .font(TypeScale.meta)
                .foregroundStyle(theme.neutrals.text2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.neutrals.inner)
        .clipShape(RoundedRectangle(cornerRadius: Radius.inner))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inner)
                .stroke(theme.neutrals.border, lineWidth: 1)
        )
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "Message"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(TypeScale.body)
                .foregroundStyle(theme.neutrals.text1)
                .lineLimit(1...6)
                .disabled(!state.canSend)
            trailingControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Running text you read or edit gets the solid grade: contract §6 says
        // where legibility and material consistency conflict, legibility wins.
        .background(theme.neutrals.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.bubble))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.bubble)
                .stroke(theme.neutrals.border, lineWidth: 1)
        )
    }

    /// Stop while a turn is in flight, send otherwise.
    ///
    /// Never both, and never a send button that is live during a stream — that
    /// is the shape that queues a second turn on the host.
    @ViewBuilder
    private var trailingControl: some View {
        if state.isStreaming {
            Button(action: onStop) {
                Image(systemName: MessageAction.cancel.systemImage)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.danger)
            .accessibilityLabel(MessageAction.cancel.title)
        } else {
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard state.canSubmit(draft: draft) else { return }
                draft = ""
                onSend(text)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(!state.canSubmit(draft: draft))
            .foregroundStyle(
                state.canSubmit(draft: draft) ? theme.primary.primary : theme.neutrals.text3
            )
            .accessibilityLabel(String(localized: "Send"))
        }
    }
}

#Preview("Composer — ready") {
    @Previewable @State var draft = "Refactor the parser"
    return ComposerView(
        state: ComposerState.make(
            from: Session(
                id: UUID(), hostID: HostID(rawValue: UUID()), backendID: "claude",
                title: "S", createdAt: .now, updatedAt: .now, status: .idle
            )
        ),
        draft: $draft
    )
    .designTheme()
}

#Preview("Composer — unpaired host") {
    @Previewable @State var draft = ""
    return ComposerView(
        state: ComposerState.make(
            from: Session(
                id: UUID(), hostID: HostID(rawValue: UUID()), backendID: "claude",
                title: "S", createdAt: .now, updatedAt: .now, status: .orphaned
            )
        ),
        draft: $draft
    )
    .designTheme()
}

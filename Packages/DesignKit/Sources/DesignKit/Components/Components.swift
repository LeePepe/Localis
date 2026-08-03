import SwiftUI

// ============================================================================
//  Component vocabulary — same rules as the my-designer web/macOS components:
//  elevation = luminance tiers (bg < card < inner) + 1px border, no shadows.
//
//  Localis is a chat client, so the vocabulary is chat-shaped: Card / CardInner
//  carry over unchanged, and MessageBubble / StatusPill / TypingIndicator
//  replace the dashboard-only Metric / Sparkline / RingGauge set.
// ============================================================================

// MARK: - Card (L1) + CardInner (L2)

public struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.gap) { content() }
            .padding(Space.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.neutrals.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(theme.neutrals.border, lineWidth: 1)
            )
    }
}

public struct CardInner<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        HStack { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.neutrals.inner)
            .clipShape(RoundedRectangle(cornerRadius: Radius.inner))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inner)
                    .stroke(theme.neutrals.border, lineWidth: 1)
            )
    }
}

// MARK: - StatusPill — connection / delivery state

public enum PillTone: Sendable {
    case neutral, success, warning, danger, primary
}

public struct StatusPill: View {
    @Environment(\.theme) private var theme
    private let text: String
    private let tone: PillTone

    public init(_ text: String, tone: PillTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return theme.neutrals.text2
        case .success: return theme.success
        case .warning: return theme.warning
        case .danger: return theme.danger
        case .primary: return theme.primary.primaryText
        }
    }

    private var background: Color {
        tone == .primary ? theme.primary.primarySubtle : theme.neutrals.inner
    }

    public var body: some View {
        Text(text)
            .font(TypeScale.meta)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(theme.neutrals.border, lineWidth: 1))
    }
}

// MARK: - MessageBubble — one turn in the transcript

/// Which side of the transcript a bubble sits on.
public enum BubbleSide: Sendable {
    case outgoing, incoming
}

public struct MessageBubble: View {
    @Environment(\.theme) private var theme
    private let text: String
    private let side: BubbleSide
    /// Renders in a monospaced face — agent output is often code.
    private let isCode: Bool

    public init(text: String, side: BubbleSide, isCode: Bool = false) {
        self.text = text
        self.side = side
        self.isCode = isCode
    }

    private var background: Color {
        side == .outgoing ? theme.primary.primary : theme.neutrals.card
    }

    private var foreground: Color {
        side == .outgoing ? theme.primary.onPrimary : theme.neutrals.text1
    }

    public var body: some View {
        HStack {
            if side == .outgoing { Spacer(minLength: 40) }
            Text(text)
                .font(isCode ? TypeScale.code : TypeScale.body)
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: Radius.bubble))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.bubble)
                        .stroke(side == .outgoing ? .clear : theme.neutrals.border, lineWidth: 1)
                )
            if side == .incoming { Spacer(minLength: 40) }
        }
    }
}

// MARK: - TypingIndicator — the agent is streaming

public struct TypingIndicator: View {
    @Environment(\.theme) private var theme
    @State private var phase = 0.0

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(theme.neutrals.text3)
                    .frame(width: 6, height: 6)
                    .opacity(phase == Double(i) ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.neutrals.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.bubble))
        .accessibilityLabel("Agent is typing")
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 2
            }
        }
    }
}

// MARK: - EmptyStateView — no sessions / no backends yet

public struct EmptyStateView: View {
    @Environment(\.theme) private var theme
    private let systemImage: String
    private let title: String
    private let message: String

    public init(systemImage: String, title: String, message: String) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: Space.gap) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(theme.neutrals.text3)
            Text(title)
                .font(TypeScale.title)
                .foregroundStyle(theme.neutrals.text1)
            Text(message)
                .font(TypeScale.body)
                .foregroundStyle(theme.neutrals.text2)
                .multilineTextAlignment(.center)
        }
        .padding(Space.cardPadding)
        .frame(maxWidth: .infinity)
    }
}

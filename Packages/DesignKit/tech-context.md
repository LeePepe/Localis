---
layer: DesignKit
role: Localis's single design language — one seed color derives the whole primary token set, plus the chat component vocabulary
depends_on: []
depended_by: [LocalisUI, Localis]
red_lines:
  - One design language, one seed-based palette. Changing the theme means changing the seed — never fork the language or start a second palette.
  - Neutral and semantic palettes are FIXED and never seed-derived (green=good must not shift with the brand color). Same seed math as the web design-system port.
  - No domain types. DesignKit imports nothing from Localis — a component that needs a `Message` belongs in LocalisUI.
  - UI strings must go through `String(localized:)` / `NSLocalizedString`. No hardcoded user-facing text in components.
  - Swift 6 strict concurrency; tokens and palettes are `Sendable`, views are `MainActor`.
roles:
  Types: [Color]
  UI: [Components]
test: swift test --package-path Packages/DesignKit
owns: [Seed, PrimaryPalette, Neutrals, Semantic, Theme, Radius, Space, TypeScale, Card, CardInner, StatusPill, MessageBubble, TypingIndicator, EmptyStateView]
---

# DesignKit Context

## Role

Localis's **only** design language. Seeded from the my-designer swiftui
scaffold and ported to iOS: the seed math is byte-identical to the macOS
template and the web port, so Localis stays visually consistent across
platforms. The only platform-specific code is color decomposition, which
bridges through `UIColor` on iOS and `NSColor` on macOS.

## The seed system

One seed color derives the entire primary token set — `primary`, `…Hover`,
`…Active`, `…Subtle`, `…Muted`, `…Border`, `…Text`, `onPrimary`, `ring` — via
`makePrimaryPalette(seed:isDark:)`. `onPrimary` is a real WCAG contrast choice
(black or white by relative luminance), not a guess.

Fixed, never seed-derived:

- **Neutrals** — Radix slate or Tailwind neutral (`Neutral.slate` / `.neutral`).
- **Semantics** — success / warning / danger (Apple system colors).

Localis's default seed is `.appleBlue`.

## Component vocabulary

`Card` / `CardInner` carry over from the scaffold unchanged. The dashboard-only
components (Metric, Sparkline, RingGauge) were dropped for a chat-shaped set:

| Component | Purpose |
|---|---|
| `MessageBubble` | One turn; `.outgoing` / `.incoming`, optional monospace for code |
| `StatusPill` | Connection / delivery state, five tones |
| `TypingIndicator` | The agent is streaming |
| `EmptyStateView` | No sessions / no backends yet |

Elevation is luminance tiers (`bg` < `card` < `inner`) plus a 1px border — no
shadows.

## Usage

```swift
ContentView().designTheme()          // resolves seed + colorScheme
@Environment(\.theme) var theme      // read tokens
```

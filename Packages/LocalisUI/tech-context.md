---
layer: LocalisUI
role: Localis's screens — session list, transcript, composer — plus the pure view projections they render
depends_on: [LocalisModels, DesignKit, ChatService, SessionStore, SkillsKit]
depended_by: [Localis]
red_lines:
  - Every color, radius, and spacing comes from `@Environment(\.theme)`. A literal `Color.blue` or `.padding(17)` in this layer is a design-system leak.
  - Views own no business rules. Anything worth a unit test — truncation, ordering, "which backend is this?" — belongs in a pure projection like `SessionRowState`, not in a `body`.
  - Views never mutate a model in place. They render snapshots and send intent up; state changes come back as new values.
  - Errors are shown, never swallowed. A failed load renders a real message, not an empty list that looks like "no sessions".
  - UI strings go through `String(localized:)`. No hardcoded user-facing text.
roles:
  Types: [SessionRowState]
  UI: [SessionListView]
test: swift test --package-path Packages/LocalisUI
owns: [SessionRowState, SessionRow, SessionListView]
---

# LocalisUI Context

## Role

The SwiftUI surface. It composes DesignKit components with domain types from
LocalisModels and drives them from `ChatService` / `SessionRepository`.

## Projections are where the tests live

A SwiftUI `body` is awkward to test, so anything with a rule in it is pulled out
into a pure value type first. `SessionRowState.make(from:backends:)` is the
pattern:

- preview text collapses newlines and elides past `previewLimit` (80) with `…`
- a session whose backend was deleted renders as `"Unknown agent"` rather than
  vanishing — orphan rows are a supported state, not a crash
- `isStreaming` is derived from the last message's status, so the row can show a
  `TypingIndicator` without asking the service anything

The view then does nothing but lay these fields out — which is why this package
has real unit tests despite being all UI.

## Empty vs. failed

Two different states, drawn differently on purpose:

- no sessions → `EmptyStateView` (an invitation)
- load threw → an error surface carrying `LocalisError.userMessage`

Collapsing them would tell a user "no sessions yet" when the truth is "we
couldn't read your sessions".

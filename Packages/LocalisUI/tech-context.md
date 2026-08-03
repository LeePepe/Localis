---
layer: LocalisUI
role: Localis's screens — session list, transcript, composer — plus the pure view projections they render
depends_on: [LocalisModels, DesignKit, ChatService]
depended_by: [Localis]
red_lines:
  - Never reach `TransportKit` or `SessionStore` directly — everything goes through `ChatService`. The dependency is not declared, so a stray import fails the build rather than the review.
  - Every color, radius, and spacing comes from `@Environment(\.theme)`. A literal `Color.blue` or `.padding(17)` in this layer is a design-system leak.
  - Views own no business rules. Anything worth a unit test — truncation, ordering, "which backend is this?" — belongs in a pure projection like `SessionRowState`, not in a `body`.
  - Views never mutate a model in place. They render snapshots and send intent up; state changes come back as new values.
  - Errors are shown, never swallowed. A failed load renders a real message, not an empty list that looks like "no sessions".
  - UI strings go through `String(localized:)`. No hardcoded user-facing text.
  - A `detached` turn renders no retry control — not disabled, not behind a confirmation. Absent. See "The third detached layer".
roles:
  Types: [SessionRowState, MessageState, ComposerState, Layout]
  UI: [SessionListView, TranscriptView, ComposerView]
test: swift test --package-path Packages/LocalisUI
owns: [SessionRowState, SessionRow, SessionListView, MessageState, MessageAction, FailureDetail, ComposerState, MessageRow, TranscriptView, ComposerView, Layout]
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

## The third detached layer

`MessageState.actions` is a `Set<MessageAction>`, not a pair of
`isRetryEnabled` booleans, and the type choice is the point.

Amendment C §1.5 and design contract rule 8 both say a `detached` turn — one the
connection dropped on while the host kept generating — must not render a retry
control *at all*. Greying it out is not enough: a mis-tap on a control that still
fires starts a second generation on the user's Mac while the first is running. A
boolean hands the view a button and asks it to be careful; a set that simply does
not contain `.retry` gives it nothing to draw.

This is the third of three layers enforcing the same rule, and none of them
re-decides it:

| layer | mechanism |
|---|---|
| LocalisModels | `MessageStatus.isRetryable` is false for `.detached` |
| SessionStore | `TurnReconciliation.allowsRetry` is true only for `.lost` / `.failed` |
| LocalisUI | `MessageState.actions` omits `.retry`, by asking `isRetryable` |

Three layers only help if they agree by deriving from one rule rather than by
coincidence — so `actions(for:)` delegates rather than pattern-matching the enum
a fourth time.

## Failure detail is never fabricated

`FailureDetail` exists only when the host reported both `failed_at_ms` and
`tool_calls_completed`. There is no "unknown" case and no zero default: rule 7 of
the design contract says a value the backend never sent makes its row disappear,
and a zeroed detail would render "failed instantly, after 0 tool calls" — a
number nobody reported. Zero *is* meaningful when it arrives from the host; it is
never manufactured locally.

## A blocked composer says why

FR-053 asks a session that cannot deliver to refuse input *visibly*. So
`ComposerState` carries a `blockedReason: String?`, not a `Bool` — and every
branch names a different user action:

| status | what the user should do |
|---|---|
| `disconnected` | wait, or bring the Mac back on the network |
| `connecting` | wait |
| `streaming` | wait for the current reply |
| `orphaned` | pair the Mac again |
| `error` | whatever `LocalisError.userMessage` says |

Collapsing these into one "unavailable" is the failure this design is avoiding:
a greyed field with no explanation is the same dead end as one that accepts text
and fails on send.

Sendability itself is *not* re-derived here — `ComposerState.make` reads
`Session.canSend`. A second opinion would drift from the first, and then one of
them is lying to the user.

## Layout constants live in `Layout`, temporarily

`Layout` holds the three §7 numbers DesignKit does not yet own — reading measure
700pt, chrome inset 21pt, bottom fade 132pt — each with its contract line quoted.
They belong in DesignKit beside `Space` and `Radius`; they sit here so that no
`body` grows a numeric literal in the meantime, and so the eventual migration is
a move rather than a re-derivation. `LayoutTests` pins the values, because
numbers like these look arbitrary in a diff and invite tidying.

Note `Space.contentMaxWidth` (1200) is *not* the reading measure. It is a
dashboard width; a transcript is prose, and prose gets harder to read as the
measure grows.

## Empty vs. failed

Two different states, drawn differently on purpose:

- no sessions → `EmptyStateView` (an invitation)
- load threw → an error surface carrying `LocalisError.userMessage`

Collapsing them would tell a user "no sessions yet" when the truth is "we
couldn't read your sessions".

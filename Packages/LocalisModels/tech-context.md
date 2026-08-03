---
layer: LocalisModels
role: Domain value types shared by every layer — agents, sessions, messages, and the one error vocabulary
depends_on: []
depended_by: [TransportKit, ChatService, SkillsKit, SessionStore, LocalisUI, Localis]
red_lines:
  - Pure value types only — no networking, no persistence, no SwiftUI. Adding a dependency here couples every layer to it.
  - Every type is immutable; changes return a new value (`withX` / `appending`). No `var` stored properties, no in-place mutation.
  - Swift 6 strict concurrency; all types `Sendable` without `@unchecked` or `nonisolated(unsafe)`.
  - `LocalisError.userMessage` must never contain endpoints, tokens, or raw payloads — it is rendered to the user verbatim.
roles:
  Types: [AgentBackend, Message, Session, LocalisError]
test: swift test --package-path Packages/LocalisModels
owns: [AgentKind, AgentBackend, Message, MessageRole, MessageStatus, Session, LocalisError]
---

# LocalisModels Context

## Role

The foundation layer. Every other package imports it; it imports nothing. That
asymmetry is deliberate — it is what keeps the dependency graph acyclic.

## What lives here

| Type | Purpose |
|---|---|
| `AgentKind` | Which local agent (Claude / OpenClaw / Hermes / Kimi / Codex) |
| `AgentBackend` | A configured connection: kind + user-supplied name + endpoint |
| `Message` | One turn: role, text, timestamp, delivery status |
| `Session` | A conversation with one backend; holds the transcript |
| `LocalisError` | The single error vocabulary all layers map into |

## Immutability

Every mutation returns a new value:

- `Message.appending(_:)` — the streaming path; each chunk yields a new message.
- `Session.replacing(_:at:)` — swaps a message by id, returns a new session.
- `AgentBackend.withEndpoint(_:)` / `.withName(_:)`.

`Session.replacing` is a no-op for an unknown id rather than a crash or an
append — a stale message id must not corrupt a transcript.

## Error mapping

Each layer maps its own failures into `LocalisError` **at its boundary**, so the
UI has exactly one vocabulary to render. `URLError`, decoding errors, and file
errors must never escape their layer.

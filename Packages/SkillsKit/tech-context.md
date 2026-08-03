---
layer: SkillsKit
role: Agent-advertised skills (slash commands) — the discovery seam and the composer-side parser
depends_on: [LocalisModels]
depended_by: [ChatService, LocalisUI, Localis]
red_lines:
  - Skills are DISCOVERED from a backend, never hardcoded. Different agents advertise different sets, and a set can change between sessions.
  - `SkillParser` is pure and synchronous — the composer calls it on every keystroke, so it must never touch the network or disk.
  - No UI. This layer decides what a draft means; it does not draw the picker.
  - Swift 6 strict concurrency; `SkillProvider` conformers must be genuinely `Sendable`.
roles:
  Types: [Skill, SkillParser]
test: swift test --package-path Packages/SkillsKit
owns: [Skill, SkillProvider, SkillParser]
---

# SkillsKit Context

## Role

Everything about `/skill` invocations: what a backend offers, and what the text
in the composer currently means.

## Discovery seam

```swift
protocol SkillProvider: Sendable {
    func skills(for backend: AgentBackend) async throws -> [Skill]
}
```

A backend that advertises nothing returns an empty array — that is a normal
state, not an error. The set is per-backend (`Skill.backendID`) because two
agents can expose different commands under the same name.

## Parsing

`SkillParser.parse` turns a draft into `Invocation(skillID:arguments:)`, or nil
when the draft is ordinary prose. It runs on every keystroke, so it is pure
synchronous string work — no I/O.

Deliberate nils: a bare `/`, a `/` followed only by whitespace, and any text
without a leading slash. These are drafts in progress, not errors.

`matches(prefix:in:)` drives autocomplete and is case-insensitive; an empty
prefix matches everything (the just-typed-`/` state).

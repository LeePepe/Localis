---
canonical_roles: [Types, Config, Repo, Service, Runtime, UI]
# Intra-layer stereotype order (class-role dependency axis), NOT package deps.
# Package deps live in each Packages/<X>/tech-context.md `depends_on`.
# A lower-role type must never import a higher-role type WITHIN the same package.
#   Types   — models, enums, protocols, DTOs, pure value types, parsers
#   Config  — container / configuration assembly
#   Repo    — persistence and external data access
#   Service — orchestration, business logic, streaming turn management
#   Runtime — process/UI-adjacent helpers
#   UI      — SwiftUI views / modifiers
---

# Localis Context

## Product Identity

Localis is an **iOS client for coding agents you run yourself**. It talks to
Claude Code, OpenClaw, Hermes, Kimi, Codex — running on your own Mac, your own
LAN, your own server — over a transport you configure. It is not a wrapper
around a hosted chat product; there is no Localis backend.

The value is: your agents, your machine, in your pocket.

## Glossary

- **Backend** (`AgentBackend`) — one configured agent endpoint: a kind
  (`AgentKind`), a display name, and a URL. A user typically has several.
- **Session** — one conversation with one backend. Owns its ordered `[Message]`.
- **Skill** — a slash command a backend *advertises*. Skills are discovered per
  backend, never hardcoded — two agents can expose different `/review`s.
- **Turn** — one user message plus the streamed assistant reply.
- **Transport** — the wire protocol to a backend. Behind `AgentTransport`, so
  everything above it is testable with no live agent.

## Architecture

Local SPM packages under `Packages/`, one layer each, built bottom-up:

```
LocalisModels          ← foundation, no dependencies
├── TransportKit       ← network seam, SSE, endpoint validation
├── SessionStore       ← repository boundary
└── SkillsKit          ← skill discovery + slash parsing
        └── ChatService    ← turn orchestration
DesignKit              ← design language, no dependencies
        └── LocalisUI      ← screens
                └── Localis (app target)
```

Two roots — `LocalisModels` (domain) and `DesignKit` (visual) — that never know
about each other. They meet for the first time in `LocalisUI`.

## Load-bearing decisions

### Everything above TransportKit depends on a protocol

`ChatService` imports `AgentTransport`, never a concrete transport. That single
seam is why the whole turn pipeline — validation, persistence, streaming,
partial-failure recovery — is unit-tested against a scripted fake with no agent
running anywhere. Adding a new `AgentKind` means one new conformer and no edits
above.

`SessionStore` does the same for storage: `InMemorySessionRepository` today, a
disk-backed conformer later, no caller changes.

### Immutability end to end

No type in `LocalisModels` mutates. `Message.appending(_:)`,
`Session.replacing(_:at:)`, `AgentBackend.withEndpoint(_:)` all return new
values. `ChatService.send` yields a stream of whole `Session` snapshots rather
than mutating a shared object — which is what makes concurrent streaming safe
without locks, and why the SwiftUI layer can render each frame as pure data.

### Partial output is never discarded

If a transport fails mid-stream, the assistant message keeps the text the user
already read and is marked `.failed`. Throwing would be simpler and would erase
what they were reading. Same principle in the UI: "couldn't load" and "nothing
here yet" are drawn differently, because collapsing them lies to the user.

### One design language

`DesignKit` derives its entire primary token set from a single seed color, using
math byte-identical to the my-designer scaffold and the web port. Neutrals and
semantics are fixed — green means good regardless of the brand color. No view in
`LocalisUI` hardcodes a color or a spacing value.

## Build

SPM-first. Each package builds and tests standalone:

```bash
swift build --package-path Packages/<Name>
swift test  --package-path Packages/<Name>
```

The Xcode project is **generated**, never committed:

```bash
xcodegen generate      # project.yml → Localis.xcodeproj
```

Version and build number are single-sourced in `project.yml`
(`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`); fastlane overrides the build
number per upload from the App Store Connect high-water mark.

## Ownership

`AGENTS.md` carries the read contract and the layer routing table — read that
before touching code.

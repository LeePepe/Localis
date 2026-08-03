# Localis

An iOS client for the coding agents you run yourself — Claude Code, OpenClaw,
Hermes, Kimi, Codex — on your own Mac, your own LAN, your own server.

There is no Localis backend. Your agents, your machine, in your pocket.

Bundle `com.leepepe.localis` · Team `4Z8GG667QD` · its own TestFlight record.

## Architecture

Seven local SPM packages under `Packages/`, two independent roots that meet for
the first time in the UI layer:

```
LocalisModels          ← domain values; no dependencies
├── TransportKit       ← the AgentTransport seam, SSE, endpoint validation
├── SessionStore       ← SessionRepository boundary
└── SkillsKit          ← skill discovery + slash parsing
        └── ChatService    ← turn orchestration
DesignKit              ← seed-based design language; no dependencies
        └── LocalisUI      ← screens + pure view projections
                └── Localis (app target — wiring only, not a layer)
```

Everything above `TransportKit` depends on a *protocol*, never a concrete
transport — which is why the whole turn pipeline is unit-tested against a
scripted fake with no agent running anywhere.

See [`tech-context.md`](./tech-context.md) for the decisions behind this, and
[`AGENTS.md`](./AGENTS.md) for the layer map and read contract.

## Build

Packages build and test standalone — no Xcode project, no simulator:

```bash
swift build --package-path Packages/LocalisModels
swift test  --package-path Packages/LocalisModels
```

The Xcode project is generated and never committed:

```bash
xcodegen generate
xcodebuild build -project Localis.xcodeproj -scheme Localis \
  -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation
```

Enable the repo hooks once:

```bash
git config core.hooksPath scripts/hooks
```

## Release

`.github/workflows/testflight.yml` builds and uploads to TestFlight from a
self-hosted mac runner when `main` has new commits since the last release.
Required one-time setup (GitHub secrets, the runner label, the App Store Connect
app record) is listed in [`AGENTS.md`](./AGENTS.md#setup-the-user-must-do-once).

## Requirements

iOS 18 · Swift 6 (strict concurrency) · Xcode 26.5 · XcodeGen · fastlane

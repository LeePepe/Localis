# Localis — Agent Instructions

## Read Contract

Before touching anything, read the doc for the thing you're touching. Acting
without reading is a violation. This table is a **thin index** — the content
lives in the documents it points at. Drill down on demand; do not pre-read
everything.

| What you're doing | Read first | What you get |
|---|---|---|
| Any task | `.specify/memory/constitution.md` (if present) | The non-negotiable red lines |
| Understanding the product / scope | `specs/` | Feature intent, acceptance criteria |
| Changing global architecture / crossing layers | `tech-context.md` (top level, holds `canonical_roles`) | Architecture decisions, data flow, layer map, class-role order |
| Changing `Packages/<X>/**` | `Packages/<X>/tech-context.md` | That layer's role / deps / red_lines / test command |
| Changing visual design | `Packages/DesignKit/tech-context.md` + `design/` | The seed token system; the prototype |
| build / test / git | this file | Command reference, release pipeline |

## Layer Map

Business logic lives in `Packages/` (7 local SPM packages). The app target
(`Localis/`) is a platform entry point + wiring only — it is **not a layer**.

| Layer | Responsibility | Doc | depends_on |
|---|---|---|---|
| LocalisModels | Domain values: backends, messages, sessions, errors | `Packages/LocalisModels/tech-context.md` | — |
| TransportKit | Wire protocol to agents: `AgentTransport`, SSE, endpoint validation | `Packages/TransportKit/tech-context.md` | LocalisModels |
| SessionStore | Persistence boundary (`SessionRepository`) | `Packages/SessionStore/tech-context.md` | LocalisModels |
| SkillsKit | Skill discovery + slash-command parsing | `Packages/SkillsKit/tech-context.md` | LocalisModels |
| ChatService | Turn orchestration: validate → persist → stream | `Packages/ChatService/tech-context.md` | LocalisModels, TransportKit, SessionStore, SkillsKit |
| DesignKit | Design language: seed color tokens + components | `Packages/DesignKit/tech-context.md` | — |
| LocalisUI | Screens + pure view projections | `Packages/LocalisUI/tech-context.md` | LocalisModels, DesignKit, ChatService, SessionStore, SkillsKit |

**Progressive disclosure**: locate the layer in this table → read only that
layer's `tech-context.md` → take its constraints and start. Don't pre-read every
layer.

**Scope work by layer**:

- Change lands in 1 layer (or only the app target) → one task, do it directly.
- Spans 2+ layers → too big. Split into N subtasks that each `swift build/test`
  independently (one layer, one commit).
- Still large within a single layer → split by technical seam: pure logic →
  input/validation → orchestration → output transform → fixtures → docs.
- **Leftovers become new tasks. Never grow the current task on the way out.**

**Two dependency axes** (same rule both times — dependencies point down only):

- **Between layers (packages)**: each layer's `depends_on` frontmatter.
  Reversing it is a violation (`LocalisModels` must never import `ChatService`).
- **Within a layer (class roles)**: each layer's `roles:` plus `canonical_roles`
  in the top-level `tech-context.md`. A lower-role type must not import a
  higher-role type inside the same package (a `Types` file must not reach into
  `Service`).

## Layered Repair

When a lint/test failure names a layer:

- Fix inside the failing layer only. Root cause elsewhere → file a new task,
  don't reach across layers.
- Fix while honoring that layer's `red_lines` — don't cross one to make a test
  pass (e.g. don't hardcode a skill list to avoid a discovery round-trip).
- Re-run that layer's `test` command (it's in the frontmatter) before handing
  off.

## Build & Test

### SPM packages (use these by default)

The 7 packages build and test with no Xcode project and no simulator — seconds
each.

**If your change only touches `Packages/`, you must verify with `swift
build`/`swift test`. Do not reach for `xcodebuild`.**

```bash
swift build --package-path Packages/LocalisModels
swift test  --package-path Packages/LocalisModels
```

All packages:

```bash
for p in Packages/*/; do swift test --package-path "$p" || break; done
```

### App target (only when needed)

`Localis/` has no top-level `Package.swift`, so it needs `xcodebuild`:

1. **Generate the project first** — `Localis.xcodeproj` is a build artifact and
   is not committed:
   ```bash
   xcodegen generate
   ```
2. **Generic destination** to avoid device-connection timeouts:
   ```bash
   xcodebuild build -project Localis.xcodeproj -scheme Localis \
     -destination 'generic/platform=iOS Simulator' \
     -skipPackagePluginValidation
   ```
3. **Run it in the background with a long timeout** — first SPM resolve can take
   several minutes.
4. **Tests**:
   ```bash
   xcodebuild test -project Localis.xcodeproj -scheme Localis \
     -destination 'platform=iOS Simulator,name=iPhone 17' \
     -skipPackagePluginValidation
   ```

### XcodeGen

Targets are defined in `project.yml`. Re-run `xcodegen generate` after changing
target config. `Localis/Sources/` and `LocalisTests/` are directory source
references — new files are picked up automatically.

## Hooks

```bash
git config core.hooksPath scripts/hooks
```

`scripts/hooks/pre-commit` runs SwiftLint on staged Swift files, then does an
**incremental** `swift build && swift test` for each touched `Packages/<X>` (and
runs `scripts/check-frontmatter.sh` when any `tech-context.md` changed). Layers
you didn't touch are not built.

## TestFlight

`.github/workflows/testflight.yml` checks `main` on a schedule; if there are new
commits since the last successful release, it builds and uploads to TestFlight
(internal testing) on a self-hosted runner. Manual fallback: Actions →
testflight → Run workflow with `force=true`.

- **Release marker**: moving tag `testflight/last-released` (cumulative — no
  commit is lost when a build fails or the runner is offline).
- **Signing**: manual, with an explicit App Store distribution profile.
  Automatic signing on a multi-account runner keychain triggers
  `errSecInternalComponent`.
- **Build number**: App Store Connect's global high-water mark + 1, injected at
  archive time via `xcargs` — never written back into `project.yml`.
- **fastlane**: the `ios beta` lane in `fastlane/Fastfile`.

### Setup the user must do once

| Item | Where | Source |
|---|---|---|
| `ASC_KEY_ID` | GitHub secret | ASC → Users and Access → Integrations → API Key → Key ID |
| `ASC_ISSUER_ID` | GitHub secret | same page, Issuer ID |
| `ASC_KEY_P8_BASE64` | GitHub secret | `base64 -i AuthKey_XXX.p8` (the `.p8` downloads once — never commit it) |
| `KEYCHAIN_PASSWORD` | GitHub secret | login-keychain password on the runner |
| Self-hosted runner labelled `localis-mac` | GitHub → Settings → Actions → Runners | see the ⚠️ block at the top of `testflight.yml` |
| App record for `com.leepepe.localis` | App Store Connect | must exist before the first upload |

## Conventions

- **Swift 6 strict concurrency** everywhere (`.swiftLanguageMode(.v6)`).
- **Immutability**: never mutate — return a new value. This is a project red
  line, not a style preference; see `tech-context.md`.
- **No hardcoded UI strings**: `String(localized:)` / `NSLocalizedString`.
- **No hardcoded design values** in `LocalisUI`: read `@Environment(\.theme)`.
- **Errors are never swallowed.** Every wire failure maps to `LocalisError` at
  the TransportKit boundary and carries a `userMessage`.
- **Conventional commits** (`feat:`, `fix:`, `refactor:`, `chore:` …), no AI
  attribution.

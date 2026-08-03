# CLAUDE.md

This file is the Claude Code entry point. **The full instructions live in
[`AGENTS.md`](./AGENTS.md)** — read it before doing anything.

## Start here

1. [`AGENTS.md`](./AGENTS.md) — read contract, layer map, build/test commands,
   release pipeline.
2. [`tech-context.md`](./tech-context.md) — architecture, product identity,
   `canonical_roles`.
3. `Packages/<X>/tech-context.md` — the layer you're about to touch.

## The short version

```bash
# Packages — this is the default. Seconds, no Xcode, no simulator.
swift build --package-path Packages/<Name>
swift test  --package-path Packages/<Name>

# App target — regenerate first; the .xcodeproj is never committed.
xcodegen generate
xcodebuild build -project Localis.xcodeproj -scheme Localis \
  -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation
```

**If your change only touches `Packages/`, do not run `xcodebuild`.** It is
minutes slower and tells you nothing `swift test` didn't.

Run `xcodebuild` in the background with a long timeout — the first SPM resolve
can take several minutes.

## Non-negotiables

- Dependencies point down only, on both axes (packages via `depends_on`, class
  roles via `roles` / `canonical_roles`).
- Never mutate a value — return a new one.
- Never swallow an error.
- Never hardcode a color, spacing, or user-facing string.
- Never commit `Localis.xcodeproj` (generated) or an `AuthKey_*.p8` (signing
  secret).

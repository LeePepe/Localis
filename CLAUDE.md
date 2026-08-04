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

# App-target TESTS need a concrete simulator, addressed by UDID. See below.
xcrun simctl list devices available | grep iPhone      # pick one, copy its UDID
xcodebuild test -project Localis.xcodeproj -scheme Localis \
  -destination "id=<UDID>" -skipPackagePluginValidation
```

**If your change only touches `Packages/`, do not run `xcodebuild`.** It is
minutes slower and tells you nothing `swift test` didn't.

Run `xcodebuild` in the background with a long timeout — the first SPM resolve
can take several minutes.

### Addressing a simulator: use the UDID, never the name

Both of these fail for reasons that have nothing to do with your code, and both
failures are easy to misread as "my change broke something":

- **`generic/platform=iOS Simulator` cannot run tests.** It builds fine, but
  `xcodebuild test` exits 70 with `Tests must be run on a concrete device`.
- **`name:iPhone 17` / `OS:latest` may resolve to nothing on your machine.** The
  name in CI is not a name you necessarily have. When a destination matches no
  device, `xcodebuild` prints a list of available destinations and **exits 0
  without compiling a line** — and a stale `.app` may still be sitting in
  DerivedData, so an install-and-screenshot step will happily produce a real
  screenshot of a build from hours ago.

So: resolve a UDID first and pass `-destination "id=<UDID>"`. When a run is
meant to produce evidence (a screenshot, a green test), also use a fresh
`-derivedDataPath` and check the built bundle's timestamp against the clock —
"this run built nothing" and "this run built successfully" are otherwise
indistinguishable on disk.

### Reading CI logs while a run is still going

```bash
gh api repos/LeePepe/Localis/actions/jobs/<job-id>/logs   # works mid-run
gh run view --log --job <job-id>                          # needs the whole run to finish
```

The second one answers `run ... is still in progress; logs will be available
when it is complete`. That is a statement about the tool, not about the logs —
they exist, and the first command returns them. Do not read it as "the failure
left no trace" and start guessing from the job's duration instead.

It has a worse failure than refusing, too: after a rerun, `gh run view --log`
returns the **latest attempt's** log rather than the one you asked for. The
first attempt's crash then looks like it vanished, and "the rerun overwrote the
evidence" is a conclusion you can reach with nothing actually wrong. The `gh
api` form is addressed by job id and answers about that job. Refusing to answer
is visible; answering about the wrong thing is not.

Duration is a bad proxy in general here: a failing job that took 40s sounds like
it died before reaching the tests, but the SessionStore suite runs 132 tests in
**0.459s** — those 40 seconds were almost entirely compilation. Read the log.

### `git reset --hard` and untracked files

`--hard` leaves untracked files alone but discards local edits to **tracked**
ones. Half of that rule ("untracked survives") is the memorable half, and it is
the half that gets you: an edit to something like `scripts/hooks/pre-commit`
disappears silently, and a hook that lost a gate does not error — it just stops
stopping things. After a reset, grep for the change you expect to still be
there.

## Non-negotiables

- Dependencies point down only, on both axes (packages via `depends_on`, class
  roles via `roles` / `canonical_roles`).
- Never mutate a value — return a new one.
- Never swallow an error.
- Never hardcode a color, spacing, or user-facing string.
- Never commit `Localis.xcodeproj` (generated) or an `AuthKey_*.p8` (signing
  secret).

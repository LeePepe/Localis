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

`Localis.xcodeproj` is a **generated artifact and is never committed** — it is
gitignored on purpose. Both the CI app job and `fastlane ios beta` run
`xcodegen generate` before building, so git never needs it. Do not "helpfully"
add it back: a tracked `.pbxproj` drifts from `project.yml` and turns every PR
into a merge-conflict review. If it is missing locally, regenerate it.

## The silent pass

Almost every real defect this project has shipped and then caught had the same
shape: **"nothing happened" was indistinguishable from "everything is fine."**
Not a wrong answer — an absent one, wearing the costume of a right one.

Instances we actually hit, so you can recognise the family:

| What we saw | What it meant |
|---|---|
| A green wiring check | Its filter matched nothing (`comm -23` against an empty file) |
| `exit 0` from `xcodebuild` | Destination matched no device; nothing compiled, and a stale `.app` was still on disk |
| `swiftlint` reporting no violations | `swiftlint` was not on `PATH`; the hook skipped its only gate in silence |
| `Test run with 0 tests` | `--filter` matched nothing, and the runner exits 0 for that |
| A green test named for a rule | It asserted the rule's *neighbour*; mutating the rule left it green |
| `142 started / 1 passed` | The "1 passed" was an empty XCTest shell; the real suite crashed before finishing |
| A test suite covering a function | Its only call site passed a constant, so the check was tautological |
| A security rule in the contract | `bridge_id` was the SPKI pin, so "same id, different pin" could never occur |
| An empty session list | The demo seed needs a launch argument; an empty store looks like a broken list |
| A `MERGED` pull request | Status field said merged; nobody had checked the content landed |
| Two teammates' reads of the tree | Both true, for different refs, minutes apart |
| `** TEST FAILED **` *and* exit 0, no test names | A stale `.xcodeproj` left a file out of the target; compilation failed and nothing ran |
| 538 green tests over a pinned transport | Every one used a fake HTTP client; real TLS had never run, and the pinning delegate was never called on the streaming path |
| A timely `429 pairing_session_expired` | It was the *consequence* of the previous probe consuming the one-shot code, not the cause of the failure being investigated |

Those last two are worth separating, because they fail in opposite directions.

The first is the most expensive shape this project has produced: **both sides
green, the seam between them never executed.** Every unit test on the transport
used a fake HTTP client, so the certificate-pinning delegate had never seen a
real handshake — and `stream()` turned out never to invoke it at all, which
means everything except pairing could not have worked. No test could have gone
red, because no test was on that path. This is ADR-0001's sentence made
concrete: *a contract is a document, and documents do not turn red by
themselves.* When two components are written against a shared contract, the
count of passing tests on either side says nothing about whether they have ever
spoken.

The second is subtler and cost a full round: an error that **arrives at the
right moment, names something real, and is still not the cause.** The `429` was
produced by an earlier probe of my own; investigating it led away from the
defect. Before accepting an error as an explanation, ask what you did just
before it — especially where a one-shot resource is involved.

That last row of the original table is the mirror of every other one: they warn
that a green may be nothing having run — it warns that **a red may be something
else having failed**. It is the more dangerous direction, because a red arrives
while you are holding an unverified change, and **any failure then looks like
the one you just caused**. We nearly went back and "fixed" two correct
assertions over it.

One more, which is the inverse of "an unwritten invariant looks like an absent
one": **a written-down defect looks like the only defect.** #25 was recorded,
explained at length, and assigned — and that is plausibly why its second half
(a session also latches unsendable on `.error`, which needs no relaunch at all)
was found by the person implementing the fix rather than by anyone reviewing the
report. Documenting "this area has a problem" quietly becomes "this area has
*that* problem," and nobody re-asks the general question. When you write a
defect down, say what you did *not* check.

The rules that come out of this, in order of how often they save us:

1. **Before trusting a "no problem," prove the check can say "problem."** Break
   the thing on purpose and watch it go red. A verdict that cannot move is not
   a verdict. This is the single highest-yield habit here.
2. **A positive control is not optional for anything that gates.** Scripts that
   gate commits ship with a self-test that must fail. `scripts/check-wiring.sh
   --self-test` is the pattern.
3. **"More carefully" is not a fix.** It does nothing for a stale read, a wrong
   ref, or a misused tool — three things that have each bitten us. Change the
   procedure, not the diligence.
4. **Stamp analyses with what they were computed against.** A mutation table, a
   contract comparison, a CI status — all are properties of *(object, moment)*
   and all read like properties of *(object)*. Cite refs, not line numbers.
5. **Say what you verified and what you did not.** "No issues found" and "not
   checked" look identical downstream, and the first one ends the investigation.
6. **Carry the premise with the conclusion.** "X shouldn't be deleted" and "X
   shouldn't be deleted, and I have not looked at whether anyone is deleting it"
   lead to different actions. Second-hand advice arrives stripped of its
   caveats unless you restate them.
7. **When a contract requirement looks unmet, ask who is waiting for the value**
   before implementing it. Two of Amendment D's five gaps (D4, D5b) were
   requirements nothing consumed — one of them we nearly staffed as a fix.
8. **A tidy post-mortem is suspect.** Blame that lands cleanly on one cause has
   usually been shaped by the story, not the evidence — we had a complete,
   satisfying account of one incident that turned out to be causally wrong in
   every link.
9. **A fact you just cited is a fact you have not yet applied to yourself.**
   Twice now someone quoted a rule to argue about another person's code and
   missed that the same rule decided their own open change. The information was
   in hand; only its role was wrong. After you use something as evidence, ask
   what it says about what you are holding.
10. **Before proposing "point that test at the other branch," check whether the
    other branch already has one.** The suggestion sounds like added coverage
    and can deliver a duplicate — coverage rises, nothing new is guarded.
11. **When a suggestion of yours turns out to be wrong, say which of your
    premises failed**, not just that you were wrong. Every reversal in this
    project came with the specific missing check, and that is what made the
    next person able to skip it.
12. **A check that did not fire is not a check that held.** Three people hit
    this on the same day, from different directions: a SHA that never drifted
    because nobody rebased that branch, a gated suite whose green aggregate
    would look the same whether it skipped or ran, and a negative control whose
    error code was taken as proof the delegate had refused when nothing recorded
    that it ran at all. In each case the mechanism was untested, not proven.
    Ask what would have had to happen for this check to speak, and whether it
    did — then record the answer rather than inferring it.
13. **Revert against the pre-fix commit, not against your memory of the fix.**
    A fix with two parts, reverted in one part, stays green — and that green
    then argues the test is worthless. Someone was told on the strength of it
    to delete a test that was, in fact, the only thing guarding the defect.

    The correction has a second layer that is the actual lesson. The first
    account of this was "I reverted the wrong half" — an execution slip. A
    three-arm control run afterwards showed something else: **the load was not
    on the half anyone thought.** Removing the delegate argument changed
    nothing at runtime; the `URLSessionTaskDelegate` conformance was doing all
    the work; and removing the conformance alone does not compile. So the
    half-revert's green was the *correct answer to the question it asked*, and
    the apology that followed it was itself misattributed. A wrong diagnosis
    can survive being apologised for — the apology closes the file.

    That third arm also reclassified the argument: it is not part of the fix
    but a **compile-time guard**, so that deleting the conformance breaks the
    build instead of silently unpinning every streamed request. Which is
    exactly the failure mode that kept #32 invisible.

    So: when a control comes back green, diff your reverted tree against the
    commit before the fix, and if the conclusion matters, vary each part
    independently. One command, and it answers what no amount of care does.
14. **A red can point at the wrong half of the system.** The companion to every
    "green means nothing ran": here the test failed, failed for the right
    reason, and still sent the reader somewhere useless. `try` threw the
    underlying `-1202` straight out, so the assertion never ran, and all the
    failure said was *the certificate for this server is invalid* — which reads
    as a certificate problem and costs a round of investigating the bridge's
    cert chain. The one datum that identified it as our own wiring, an empty
    delegate log, appeared nowhere in the output. Investigating the wrong half
    is what actually happened, twice, before the message was changed to carry
    `Delegate recorded []`.

    When you write a failure message, the question is not "does this say
    something true" but "**does a reader who trusts this end up in the right
    file**". A true message that indicts the wrong component is worse than a
    vague one, because it is actionable.

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

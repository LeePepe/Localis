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
| `swiftlint --strict` clean on a test file | `.swiftlint.yml` excludes every test directory — a planted force-unwrap gave the same `rc=0` and the same empty output |
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
| Nine references to an error case | All nine were on the receiving side; nothing in production ever throws it, so the handling has never once run |
| A `#expect` stating the fact you needed | Behind `.enabled(if:)`, and CI feeds none of those variables — last verified by hand, before the fix that changed what it measures |
| A secret scanner blocking every PR in the repo | The one line it matched was the deliberately fake token in a negative assertion; a real one assigned to a variable first would have passed |
| A comment explaining a mechanism | It was wrong, had been copied into another layer, and the copy did not move when the original was fixed |

Those last two are the "half a wire" family, and this project has now found
four instances in two days: `TokenStore.revoke` with no caller,
`certificatePinMismatch` with no throw site, `HostRuntimeState` with no
production consumer, and `token_revoked` with no emitter. Every one was written
carefully, tested thoroughly, and connected to nothing. The reason they survive
is that **each half is individually defensible** — a reviewer looking at the
receiving code sees correct, well-tested handling, because it is.

So the judgement is never "does this look implemented" but two separate
questions: **does production code ever produce this value, and does anything
read it and act.** A reference count answers neither. Nine hits on
`certificatePinMismatch` read exactly like a case in active use; all nine were
consumers.

The phrase that covers all of them: these tests check **whether the referee
judges correctly, not whether the referee was ever called onto the field.**
`SPKIPinning` has twelve ungated assertions that CI runs every day — hash
stability, cross-checks against `openssl`, a changed certificate refused, host
A's certificate rejected for host B. All twelve passed throughout #32, during
which the streamed path never invoked `SPKIPinning` at all. The verdict logic
was flawless and unreached.

That one is the worst variant, because unlike a skipped suite or an unreferenced
enum it is **green, genuinely executed, and named for the thing you want**
("SPKIPinning — per-host trust" reads like it guards the whole chain). The only
way to catch it is to grep for what a test *does not* contain — `URLSession`,
`NWListener`, `SecIdentity`: zero hits, all in memory — and searching for an
absence is not a move anyone makes unprompted.

Those two before them fail in opposite directions.

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

A related trap has cost us a whole design round: **a symbol's name is not its
semantics.** `NSURLErrorServerCertificateUntrusted` sounds like the code for a
pin that did not match, and `NSURLErrorCancelled` sounds like a user pressing
stop. Measured, they are close to swapped — `-1202` is what the *system's*
default policy produces when the delegate is never consulted (the shape of
#32), while a delegate that is consulted and refuses produces `-999`, the same
code as the stop button. A whole error-mapping table was reasoned out from the
names before anyone measured, and both of us had accepted it.

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

   The complement matters as much: **a check that goes red for uninteresting
   reasons is worse than no check.** A test asserting exact user-facing wording
   passes by restating the implementation and fails on every copy edit, so the
   habit it teaches is *update the expected value without reading it* — and
   that habit is spent on the next red, which will be a real one. Assert the
   property instead: four reasons distinct from each other, each naming an
   action the user can take. That survives rewording and still fails when a
   fifth case is added by copying the fourth — which compiles, satisfies "every
   case has words," and tells the user to fix the wrong thing.
2. **A positive control is not optional for anything that gates.** Scripts that
   gate commits ship with a self-test that must fail. `scripts/check-wiring.sh
   --self-test` is the pattern.

   Mutating one site at a time is the usual way to check a test is load-bearing,
   and it has a blind spot: **when several places maintain the same invariant,
   every single-site mutation stays green and the test looks worthless.** Three
   call sites kept `updatedAt` moving; killing any one or two changed nothing,
   and only removing all three went red. The rescue was a probe pointed the
   other way — assert the *unmutated* code produces the wrong value, watch it
   fail, and read the actual number out of the failure. That separates "the
   test cannot see this value" from "the test sees it, but something else is
   holding it up."

   Adjacent, and the reason that investigation started at all: the site doing
   the work was **outside** the loop it appeared to sit in, in a
   `if status == .streaming` block indented to look like the loop body. Which
   lines belong to which scope is a thing to check, not to read.

   The general form is about the *verdict* rather than the code: **an aggregate
   signal fed by several sources is evidence for none of them individually.** A
   gate script's self-test judged success by exit code alone, and three probes
   fed that one code, so it could never have shown whether any single probe
   still worked. Reading three signals that cannot substitute for each other
   fixes it, as does slicing output *by section* rather than grepping globally
   for a failure marker — a global grep is satisfied by exactly the sources you
   are trying to rule out.

   How that conclusion was reached is worth as much as the conclusion. The
   first supposed demonstration — blind one probe, watch the self-test stay
   green — was reported, believed, and written down here. Two things were wrong
   with it. The self-test copied the script **from the repository** before
   running it, so every mutant overwrote itself with the pristine original and
   the mutation never executed at all. And once that was fixed, the mutant
   still failed to kill, because a blinded probe **cannot** turn the self-test
   green: its only two exits are "compiled" and "did not compile", both of
   which mark a failure. It was a dud target — an input structurally incapable
   of landing on the other side.

   So: a harness that stages a copy is a harness that can quietly test the
   wrong bytes; check that your mutant is what actually ran. And **before
   concluding a check is weak because a mutation survived, work out whether
   that mutation could have killed it** — otherwise "prove the verdict can
   move" has been applied to everything except the proof itself.

   The same trap catches stashed work. A `git stash` restored onto a different
   base is not "my earlier change" — it is that change plus every assumption
   its original base made, and here it referenced a type belonging to another
   branch's work. Restoring it left the baseline red for a completely new
   reason, which reads exactly like the old one. Rebuild the increment on the
   current tree rather than replaying a stash across a base change.

   Three times this week the *control* was the thing that silently did nothing:
   a mutant overwritten by its own harness, a mutation structurally unable to
   kill, and a `--filter` naming a suite's display string instead of its
   identifier, which prints `0 tests passed` — the same words as success. The
   habit protects the code under test and then gets skipped on the apparatus,
   because the apparatus is the thing you are currently trusting. **When a
   control comes back the way you hoped, confirm it ran**: a red should name
   the assertion that failed, a green should name the tests that passed.

   One habit found all of this, and it is cheap: **make the probe print what it
   saw, not what it concluded.** A dud mutation, a self-test that had never
   observed a real breach, three call sites propping up one invariant, an
   assertion that was never reading the value — each surfaced when someone
   printed the compiler's actual sentence, the recorded delegate outcomes, the
   real number. `❌` and `rc=1` are summaries, and every summary is a place two
   different causes can meet and become indistinguishable.

   `rc=0` is the most dangerous of them, because every shell tool speaks it and
   nobody doubts it. macOS ships **LibreSSL**, not OpenSSL, and LibreSSL answers
   an unrecognised flag by printing usage and exiting **0 without producing the
   output file** — so `openssl pkcs12 -export -legacy` "succeeds" and leaves
   nothing behind. A script gated on the exit code sails past and fails much
   later somewhere unrelated. Gate on the artifact instead: does the file exist,
   does it parse, does it contain what you asked for. (`BridgeIdentity.swift`
   already checks both files exist rather than the status, which is why the
   bridge side never hit this.)

   And keep the output whole while you still do not know what you are looking
   for. `| grep -v pass` on a test run hid a compilation failure and produced
   an empty result that read as "it ran and printed nothing"; `| tail -22` on a
   crashing probe cut off the exception reason. **A filter written before the
   answer is known is a filter written against the wrong thing.** Tee the run
   to a file, then narrow.
3. **"More carefully" is not a fix.** It does nothing for a stale read, a wrong
   ref, or a misused tool — three things that have each bitten us. Change the
   procedure, not the diligence.
4. **Stamp analyses with what they were computed against.** A mutation table, a
   contract comparison, a CI status — all are properties of *(object, moment)*
   and all read like properties of *(object)*. Cite refs, not line numbers.
5. **Say what you verified and what you did not.** "No issues found" and "not
   checked" look identical downstream, and the first one ends the investigation.

   And when a result you already reported turns out to be empty, **retract it
   quickly rather than carefully**. Someone reported a lint run clean, later
   found the tool had been excluded from that directory, and withdrew it at
   once — noting that the cost of retracting is one person's credibility, while
   the cost of leaving it is a merge decision made on a reading of nothing. The
   asymmetry is what decides, not the awkwardness.

   Praising the courage of an admission gets this backwards. Withdrawing a bad
   reading is an engineering act with a measurable downstream effect.
6. **Carry the premise with the conclusion.** "X shouldn't be deleted" and "X
   shouldn't be deleted, and I have not looked at whether anyone is deleting it"
   lead to different actions. Second-hand advice arrives stripped of its
   caveats unless you restate them.
7. **When a contract requirement looks unmet, ask who is waiting for the value**
   before implementing it. Two of Amendment D's five gaps (D4, D5b) were
   requirements nothing consumed — one of them we nearly staffed as a fix.

   The mirror of this bites when you are the one ruling rather than
   implementing: **ask whether the rule you just handed down can be carried
   out at all.** A ruling that only revoked tokens may answer `token_revoked`
   sounded like a constraint on behaviour; the implementation deleted the
   grant, so a revoked token and one this bridge never issued were the same
   object — both absent — and the distinction the rule required did not exist
   to be reported. It took a tombstone to make the rule implementable, and the
   person implementing it found that out, not the person who wrote it. Before
   a ruling leaves your hands, name the state it depends on and check that
   state exists.
8. **A tidy post-mortem is suspect.** Blame that lands cleanly on one cause has
   usually been shaped by the story, not the evidence — we had a complete,
   satisfying account of one incident that turned out to be causally wrong in
   every link.
9. **A fact you just cited is a fact you have not yet applied to yourself.**
   Twice now someone quoted a rule to argue about another person's code and
   missed that the same rule decided their own open change. The information was
   in hand; only its role was wrong. After you use something as evidence, ask
   what it says about what you are holding.

   Its everyday form is cheaper to catch: **before building an apparatus to
   measure a behaviour, grep the assertions for it.** A live TLS probe was
   stood up to establish that a refused pin surfaces as `-999` rather than a
   certificate error. That exact claim was already a `#expect` in the negative
   control, with a comment saying so — and it had been read aloud in the
   conversation a few messages earlier without anyone noticing it settled the
   open question.

   **Then check the assertion actually runs**, and do not skip this half. That
   `#expect` sits behind `.enabled(if: LiveBridge.isConfigured)`, and CI sets
   none of those variables — `grep -rn LOCALIS_BRIDGE .github/workflows/`
   returns nothing. It had been verified only on the handful of local runs
   where someone exported a pin by hand, before a fix that changed the very
   delegate path it measures. "It has been green a dozen times today" was
   asserted, in this file's own defence of evidence, without being checked.

   So: a gated test is a document that looks verified. A comment at least
   looks like a comment; a `#expect` looks like something CI re-checks every
   day, and the two are indistinguishable in `git show`, which shows source
   and not execution. Read one that cannot run at the confidence level of a
   comment, not of a test. Which is also why the pinning suite being invisible
   to CI is its own task (#37) rather than a footnote here.
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

    Where the false belief came from is worth its own sentence, because it is
    not carelessness and it recurs. The claim "the argument is load-bearing"
    was written into a source comment, confidently, and never revisited:
    **writing something down produces the feeling of having verified it.** The
    same effect shows up in the reasoning that led to deleting the test — two
    alternatives were enumerated, and having a list produced the feeling of
    having covered the space. Enumerating and writing both impersonate
    checking. Neither is one.

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

    Sharper still: **the red can belong to a different component than the one
    you are reading it about.** A mutation run came back red and was taken as
    "the mutation was caught" — but the failure was in the harness's own
    positive control, which had broken for an unrelated reason. A probe that is
    itself broken emits reds that say nothing about the thing under test, and
    they are indistinguishable from the reds you were hoping for. So when a
    control fails, read *which* assertion failed before concluding anything;
    "it went red" is not a result, it is a prompt to find out where.

    Two failures needing different responses must not share a marker. A façade
    checker printed `❌ the pinning seam is reachable from outside TransportKit`
    for a run where the seal was intact and the check had merely stopped
    recognising the compiler's wording — its own header distinguished the two,
    its closing line had one phrasing for both, and the hook repeated that
    phrasing. So a stale string sent whoever hit it hunting a breach that did
    not exist.

    Worse, the collision ran the other way too. The self-test's "breach" step
    made the protocol public but left the attacking type without a conformance,
    so the attack still failed to compile — and the check was reading `❌`,
    which a genuine breach does *not* produce. It had never once observed the
    thing it exists to detect. **`COMPILED` means the façade is gone; `❌` means
    something was rejected, and those are opposite events wearing one glyph.**
    Both directions came from the same habit: printing a verdict rather than
    what was seen, so distinct causes converged on one symbol before anyone
    could compare them.
15. **A wrong comment gets quoted, and the quote does not follow the fix.** Of
    everything here, a comment is the only artifact that can be *disproved and
    still sit there unchanged* — code that is wrong goes red, a test that is
    wrong goes red, a comment that is wrong does nothing at all. Worse, it
    propagates: the false causal claim about `bytes(for:)` was copied out of
    `HTTPStreaming.swift` into another layer's file, and fixing the original
    left the copy behind, now indistinguishable from an independent
    observation. Two people had already reasoned from it.

    So when you correct an explanation, grep for its distinctive phrasing
    across the repo before closing the task — and prefer comments that state
    what was measured ("arm B: removing the argument alone changed nothing")
    over comments that state a mechanism, because a measurement carries its own
    provenance and a mechanism does not.

    Propagation is the second-order problem; some comments are simply **wrong
    when written**. One here gave three reasons for a type's placement: that
    `LocalisUI` cannot depend on `LocalisModels` (`Package.swift:18` lists it),
    that six files would have to change (all six already import it), and that a
    named sibling is handed values rather than a model (its signature takes the
    model). All three refutable by opening one file, and the analogy behaved
    the *opposite* of how it was cited — so a reader who followed it found an
    example supporting the other conclusion and assumed they had misunderstood.

    Hence: **a factual claim in a comment — one a single command could falsify
    — carries its check or its measurement.** `// LocalisUI cannot depend on
    LocalisModels` needs the file and line; `// throwing here would replace the
    list with an alert the user must dismiss` is design intent, unfalsifiable
    by command, and needs nothing. Requiring provenance for every sentence
    would collapse under its own weight; the falsifiable ones are exactly the
    ones that rot, because the code moves and the prose does not.

    And note when it happens: writing a comment is explaining, and explaining
    *feels* like knowing. Same effect as the `#expect` written from an error
    code's name. Cost of checking, in that case: one file, one line.

    Refuted reasons are not a refuted conclusion. The placement may still be
    right; it now has nothing holding it up. Mark it open rather than moving
    the code — swapping one unverified reason for another is not progress.
16. **A grep is only as true as its path argument, and the path is not in the
    output.** A search over `Packages/*/Sources` came back showing no place
    that cancels an in-flight request, and that absence became the premise of
    a ruling — that `-999` was unambiguous and could be mapped straight to a
    pin mismatch. The app target was never searched. `Localis/Sources` has a
    user-facing cancel, and a five-line program confirmed the obvious
    consequence: cancelling the enclosing `Task` makes `URLSession` throw
    `-999`. The ambiguity was real and already in production.

    A positive control does not save you here — the control ran, the command
    worked, and the command was answering about the wrong subtree. **"Nothing
    matched" and "nothing matched in the half you searched" are the same
    string.** So when an absence is about to become a premise, state the
    search scope out loud next to the conclusion, and ask whether the thing
    you are claiming does not exist could live outside it. Absence of evidence
    is the one result whose reliability is invisible in its own output.

    A sharper version of the same failure: the command that got reported was
    not the command that ran. The real one ended `| grep -v onTermination |
    head -12`; what went into the message was a tidied version and the claim
    "only two hits." A teammate re-ran the quoted command, got six, and said
    so. The conclusion survived — the extra hits were all in `onTermination`
    too — but for a moment we had a shared baseline that was wrong and looked
    sourced. **Quote the command you actually ran, pipes included; if you are
    summarising, say "summarising."** A cleaned-up command reads as evidence
    and is memory.

    Two more limits on the same tool, both of which produced wrong counts that
    a ruling then rested on. **A hand-written pattern covers the forms its
    author thought of**: four alternations for "a bare `.unreachable`" missed
    the one inside an array literal, so the count came out 11 against the
    compiler's 16. And **grep counts strings, not usages** — `.unreachable`
    names cases in two different enums here, so no amount of pattern-polishing
    separates them.

    When the number is going to decide something, **let the compiler count**:
    make the change and read the errors. It knows the difference between two
    identically spelled cases and a pattern never will. (Related: the audit
    that found this also found two sites where the "mechanical" fix was not —
    `#expect(throws: LocalisError.unreachable)` becoming `.unreachable()`
    silently asserts the *absence* of a diagnostic, so the test would fail for
    a reason unrelated to its name.)
17. **An acceptance run that is allowed to do what the user cannot is not an
    acceptance run.** The unpair suite passed end to end — revoke, restart the
    bridge, watch the token get `401 token_revoked`. Restarting is not part of
    revoking. In the field the daemon stays up, the revoked phone keeps
    working, and the CLI has already printed success. Every assertion was
    true; the scenario was not the one that ships.

    This is the second time the same gap has cost us a round. The other was a
    live suite that could pair, fail, and simply ask for a fresh code, while
    the code the product hands a user is single-use and expires in 120
    seconds — a constraint the harness never had to live under.

    So before trusting a green acceptance: list the affordances the harness
    used that the product's user does not have — restarting a service,
    reissuing a one-shot secret, reaching into a file, knowing an id nobody
    displays. Each one is a place where the test is answering an easier
    question than the one asked.
18. **A gate that matches a pattern is not enforcing the rule you think it is.**
    `gitleaks` blocked every pull request in the repo over one line, and that
    line was `Bearer tok-never-issued-by-anyone` — the deliberately invalid
    token in an assertion checking that an unknown token gets `invalid_token`.
    The three real tokens in the same script go through `$TOKEN` and were not
    flagged, which is correct. But it means the protection runs backwards: **a
    genuine credential assigned to a variable one line earlier passes, and the
    one string in the file that could never authenticate anything is what
    stops the build.**

    That does not make the gate useless, and the fix is not an allowlist —
    silencing the pattern here also silences the day it catches a real one.
    The fix is to stop tripping it, and separately to ask what enforces the
    rule the gate only approximates. Constitution I forbids credentials on the
    device and in logs; nothing said anything about acceptance scripts, which
    hold live tokens by construction (#39).

    Generally: when a gate fires, separate **what it matched** from **what it
    is for**. They agree often enough that the gap only shows up in the cases
    that matter. And note the asymmetry that makes this worth a rule: an
    accidental gap gets closed by whoever trips over it, while a gap implied by
    the rule's own definition never does. Matching `Bearer <literal>` cannot
    ever see a credential held in a variable — not this time, not next time.
19. **Ask where a gate sits, not just whether it exists.** A pre-commit hook
    section landed above section 3 on purpose: section 3 opens by exiting 0 for
    any commit that touched no package, so a check placed below it would be
    skipped by commits that change only the checker — precisely when it most
    needs to run. The same shape, one layer up, is why CI never ran a single
    pinning assertion (#37): the suite exists, is correct, and lives behind a
    gate CI does not open.

    A check installed where its own failure case cannot reach it is
    indistinguishable, from the outside, from a check that passes.

    Whether a gate blocks or advises is a separate call, and it turns on
    whether the thing is green today. A check that is green blocks, because a
    red then means something that held has stopped holding. A check that is
    already red can only advise, or people learn to bypass the hook wholesale —
    and bypassing takes every other check in it down as well.

    **Order is the other half of location: a failing gate hides every gate
    behind it.** One `gitleaks` hit — on a deliberately fake token, in a branch
    nobody had merged — failed step 4 of the `Lint & policy` job, and steps 5
    through 9 came back `skipped`: SwiftLint, the frontmatter anti-rot check,
    the wiring self-test, the app-target import check. Five PRs sat red for an
    hour reading "lint failed," and during that hour **nothing was linted at
    all**. Not one of those five checks could have reported a problem, and the
    red looked like it was doing its job.

    So when a job fails, read the *step* conclusions, not the job's: `gh api
    repos/OWNER/REPO/actions/jobs/<id> --jq '[.steps[] | {name, conclusion}]'`.
    A wall of `skipped` after one `failure` means the answer you have is about
    one check and the silence is about all the others. And when ordering steps
    within a job, put the cheap, rarely-tripped ones last — they are the ones
    you can afford to lose, and everything after a fragile step is something
    you have chosen to stop running whenever that step is unhappy.
20. **A test can pass because of your `PATH`.** Every other false green here
    has its cause in the code or the test — a gate, a fake client, a pure
    function, an aggregate signal. This one lives in the process environment,
    which appears in no diff, no test file and no workflow config, and which
    nobody thinks to compare. A TLS harness shelled out to `openssl rsa
    -outform DER`: LibreSSL at `/usr/bin` emits PKCS#1, OpenSSL 3 at
    `/opt/homebrew/bin` emits PKCS#8, and `SecKeyCreateWithData` accepts only
    the first. Green locally, `-50` in CI, and **the harness was correct or
    incorrect depending on which binary came first in the path.**

    The direction makes it worse: local green plus CI red sends you to suspect
    the CI environment, not the green you already have.

    Two habits come out of it. **Remove the negotiation instead of picking a
    combination that happens to work** — generating and exporting the key
    entirely within one framework deletes the variable rather than betting on
    it. And **run the fix under both environments before pushing**: verified
    against only the one that was failing, a fix can simply relocate the
    failure. That happened in the same session — the repair passed under
    OpenSSL 3 and broke under LibreSSL, which would have shipped a green PR
    and left the red on the next person's machine, where nobody holds the
    clue of having just changed something.
21. **Count zero on the right side.** Polling a PR with "done when no checks
    are pending" reported done on its first tick: a commit pushed seconds
    earlier had no checks attached yet, so `pending == 0` — the same integer
    as every check having finished, meaning the opposite thing. This is the
    purest form of the empty-result trap on this list. A skipped suite at
    least prints `skipped` and an unmatched grep leaves a command you can
    re-run; here **both states are one number, with nothing to distinguish
    them.** The repair is structural rather than attentive: require
    `total > 0` before reading `pending`.

    Its companion, from the same hour: after a repo-wide fix lands on `main`,
    **branches that have not rebased keep failing exactly as before** — and
    "exactly" is literal. The step conclusions match too: `gitleaks detect`
    failure, five `skipped` behind it, identical to the run before the fix
    existed. What separates the two cases is whether `.gitleaksignore` is
    present in *that tree*, a fact the CI output never mentions. So a red
    outliving its fix does not merely invite the reading that the fix failed —
    **every piece of evidence in hand supports it**, and refuting it requires
    a quantity the logs do not contain. Run `git log origin/main..HEAD` on the
    branch before re-examining the fix.

    Also on reading CI state through `gh`: **the aggregate counts go stale, and
    stay stale.** `headRefOid` can trail `git ls-remote` by a minute;
    `statusCheckRollup` was observed returning `pending=1` for nine minutes
    across eighteen polls while the individual checks had all completed
    successfully some time earlier. Treat a run as finished only when the head
    matches `git ls-remote`, `total > 0`, and every *individual* check reports
    completed. The rollup's pending count is not evidence.
22. **`gitleaks detect` reads every reachable object, not your branch's
    history.** A blob on a branch that has never been merged still fails the
    scan on `main`. Measured, because the inference ran the other way: the
    offending commit is not an ancestor of `main`
    (`git merge-base --is-ancestor` says no), which suggested the exemption
    covering it must be inert — but removing `.gitleaksignore` from a `main`
    worktree turns the scan red, so the exemption is doing real work against
    an object `main` cannot reach.

    Two consequences. Any unmerged branch can fail everyone's builds, which is
    what "one finding blocked five unrelated PRs" actually meant. And when
    merging a long-lived branch, the *new* blob it introduces is a separate
    finding from the old one: an exemption pinned to the original commit does
    not cover the squashed copy. Check what the merge would introduce before
    merging, not after.
23. **CI runs on `main` and on pull requests targeting it. Nothing else.**
    Read the `on:` block once rather than assuming: a long-lived branch here
    accumulated thirty commits, a hundred and sixty tests and a full acceptance
    script **without a single CI run**, and a pull request between two
    non-`main` branches reports "no checks reported" — which looks like the
    checks are queued.

    So "it's green on that branch" means one person's local machine said so,
    which is the same standing as an unrun test. Worth stating plainly because
    branch protection, required checks and a healthy-looking Actions tab all
    describe `main`, and none of them says anything about where the work
    actually is.
24. **One sample cannot tell a mapping from a constant.** A test injecting one
    error and asserting one diagnostic passes equally against an implementation
    that hardcodes that diagnostic. Two distinct inputs with distinct expected
    outputs is the smallest thing that distinguishes them — the same reason
    `probe` returning a `Bool` and `isAvailable` reading always-true went
    unnoticed for so long.

    Two related shapes from the same review, both about tests that pass without
    discriminating:

    **Fixing a catch-all can create a narrower catch-all.** Mapping only
    `URLError` and defaulting everything else preserves exactly the collapse
    being repaired — and hides better, because its blind spot is precisely the
    domains nobody thinks to test.

    **Assert that nothing forbidden appears, not that the expected fields are
    right.** Whitelisting fields passes a future field that happens to carry a
    path; asserting the rendered output contains no `/Users`, no hostname, no
    port survives additions nobody has written yet.

    And pick test data that only one side can produce. An assertion that port
    `8443` never appears in a diagnostic is worthless if the client under test
    also uses `8443` — the value would then have two possible sources, and the
    assertion reads whichever arrived. Same failure as three probes sharing one
    exit code, relocated into the fixtures.
25. **A round-trip test is blind to the damage that matters.** Encode then
    decode in the same build and everything agrees with itself — including a
    build that has started writing `{"diagnostic":null}` where older ones write
    nothing. Compatibility asks whether *another* build can read what this one
    writes, and a round-trip is silent on that while looking exactly like a
    serialisation test.

    Assert the bytes. Adding an optional associated value to a persisted enum
    turned out to change nothing (Swift omits it rather than emitting `null`),
    but that was measured against a recorded encoding and pinned with a
    mutation that produced the predicted `{"diagnostic":null}` — not assumed
    from the round-trip passing.
26. **A stale build cache fails in the shape of a crash.** `signal code 11`
    from a test run reads as a runtime crash — the one failure that seems
    least likely to be a compile problem, so it is the least likely to prompt
    "did this even build?" Twice in one session it was `.build` holding
    artefacts from a stashed tree: once the real error was a missing type, once
    a manifest still listing a file that had been stashed away.

    Compile error, cache mismatch, and genuine crash are one exit code, and the
    person seeing them is usually holding an unverified change — so every red
    looks like theirs. Before attributing a failure to your diff, `rm -rf
    .build` and re-run. And note that the earlier "silent output" from a
    package sweep was this too: not a run that printed nothing, but a package
    that never compiled. Declining to count it as a pass was right; not
    investigating it let the same cause run loose for hours.
27. **A test can go vacuous because the world moved, and it keeps its name.**
    A privacy test seeded an error with a fake path and hostname, then asserted
    the rendered output contained neither. A later change routed that error
    code to a case carrying **no payload at all** — so all five "must not
    appear" assertions held for the reason that nothing was there to appear in.
    Still green, still called *nothing but domain and code rides out*, and now
    guarding nothing.

    The tell was mundane: a change that should have affected it, and it stayed
    green. **"I changed the world under this test and it did not notice" is the
    strongest signal available that it was never watching.** Follow it before
    concluding the change was safe.

    Repairing the input only fixes today. Add the precondition that would have
    caught it — `try #require(error.diagnostic != nil)` in front of the
    assertions — so the next time the routing moves, the test **fails** rather
    than quietly passing on an empty subject. Negative assertions need this
    most: an assertion that something is absent is satisfied by an absent
    universe.
28. **A fixture can move a test onto a different question.** A check meant to
    prove that unknown reachability does not block connecting would, built on an
    unpaired fixture, pass under either version of the rule — it would be
    measuring pairing, not reachability, and saying nothing about the thing in
    its own name. Mutation testing does not catch this: the wrong-fixture test
    fails under the mutant too, for its own unrelated reason.

    What catches it is a positive control **inside the test**: assert the
    fixture really is connectable before asserting reachability does not block
    it. One line, and it converts "this passed" into "this passed for the
    reason claimed."

    The same audit turned up the more common form of the problem: **every
    existing assertion on that property was negative.** Seven tests asserted it
    was false, none that it was true through the type under test, so replacing
    the rule with a wrong one left all seven green. When adding a rule, count
    the assertions on each side — a property with no positive case is a
    property that can be broken in one direction silently.
29. **Two branches that are each green have never met.** Two halves of one
    feature, developed in parallel, both passed CI — and the second branch was
    three commits behind the merge that added the first, so **the two halves
    had never been compiled in the same tree.** Rebasing first is not a
    formality: if they conflict, that conflict belongs on the branch, where it
    is one person's problem, rather than on `main`, where it looks like the
    merge broke something.

    This is #32's shape moved earlier in time — two sides individually correct,
    the seam between them never exercised — and it is cheaper here, because the
    compiler will say so within a minute.

    The same day this rule was written, checking a teammate's claim from a
    working tree **sixteen commits behind `main`** produced zero hits for a
    symbol that had three, and the reply "I can't see those call sites" was one
    step away. `git log HEAD..origin/main --oneline | wc -l` costs nothing.
    Everyone here has now been asked to run it; the person writing this had not
    run it on themselves.

## Hooks

```bash
git config core.hooksPath scripts/hooks
```

`scripts/hooks/pre-commit` runs SwiftLint on staged Swift files, then does an
**incremental** `swift build && swift test` for each touched `Packages/<X>` (and
runs `scripts/check-frontmatter.sh` when any `tech-context.md` changed). Layers
you didn't touch are not built.

**SwiftLint never sees test code.** `.swiftlint.yml` excludes `LocalisTests` and
`Packages/*/Tests`, so linting a test file is green by construction — and the
hook reports that as `lint skipped`, which is accurate but easy to read as
"nothing to complain about." Someone relied on the sentence above this one,
ran `swiftlint --strict` against a new test file, got `rc=0` with no output,
and reported it clean; a deliberate force-unwrap planted in the same file
produced the identical result. **For a change that lives in tests, the lint
step is silent by design and the guarantees have to come from the tests.**

The table above already has a row for `swiftlint` missing from `PATH`. This is
the same output with a different cause, and unlike the `PATH` case it is not
intermittent: it applies every time anyone touches a test.

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
- **Stage by naming files, not `git add -A`.** Probes, mutants and misplaced
  copies live in the working tree during any serious investigation, and `-A`
  sweeps them into the commit. One stray file this week was a duplicate of a
  real source file left by a mis-targeted `cp` — reviewed casually, it reads as
  deliberate. Naming each path costs a few seconds and makes "what is in this
  commit" a decision rather than a side effect.
- **Never write a task number as `(#NN)` in a commit subject — write `task
  #NN`.** Task numbers come from the local task list; GitHub has never heard of
  them, and issues and pull requests share one numbering space there. A subject
  ending `(#28)` for task 28 becomes a live link to *pull request* 28, and
  merging it closed an unrelated PR one second later. Nothing about that reads
  as wrong: the link resolves, the number matches, and the close is attributed
  to a human. PR numbers trail task numbers here, so every merge is another
  chance to collide. GitHub does not linkify `task #28`.

  The same collision is why **`closed by`, `merged by` and every other actor
  field carries almost no information in this repo** — the whole team drives
  `gh` under one account, so the field cannot separate one person from another,
  or a person from automation. To tell a deliberate action from an accidental
  one, use timing (one second apart is not a human decision), `commit_id` on
  the timeline event, and whether the two changes have any files in common.

- **When a comment cites a task number, say what that task promises.** Task
  numbers are local, so nothing validates a reference to one — not the
  compiler, not CI, not the task tool. A comment reading "#30 tracks giving
  `HostUnreachableReason` the missing case" pointed at a task about clearing
  credentials on a revoked token; the promised work had never been tracked by
  anything. Following the reference lands on a real, correctly-numbered,
  *completed* task, so the honest conclusion is "that got done" — **"already
  handled" and "never existed" read identically, and the error runs toward the
  reassuring one, which ends the search.**

  `#40 tracks giving probe a return type that can carry a reason` costs four
  more words and can be falsified on sight by whoever reads it. Same root as
  the numbering collision above: a local number in prose is an assertion
  nothing will ever check for you.

  The same goes for a **symbol** you name from memory. Drafting the ruling
  above, I cited a test called `HostUnreachableReasonTests` as the thing that
  would enforce it. No such type exists; the suite is
  `HostUnreachableReasonWordingTests`. Written into a comment, it fails worse
  than the bad task number: a wrong task number lands you on a real task, but a
  name that matches nothing returns an empty grep, and **an empty grep reads as
  your own mistake** — wrong flags, wrong path, wrong spelling, each of which
  has genuinely bitten someone here. The absence of the evidence gets charged
  to whoever went looking for it.

  So paste identifiers from the file, never from memory — and if a claim in
  your own draft names something, grep it before someone builds on it. The
  reviewer caught this one, in a ruling whose entire subject was references
  that nothing validates.

  There is a further turn, and it is the one to watch for: **the act of
  verifying can itself land on the wrong object.** A comment cited "#34, in
  progress"; the person who had just merged pull request 34 read it as stale
  and moved to correct it. Those are different 34s — one a task, one a PR, in
  numbering spaces that overlap by coincidence. Checking whether the sentence
  was still true (the catch-all it describes is still at
  `BridgeClient.swift:376`) is what stopped a correct comment from being
  "updated" into a wrong one. Note the direction of damage: a freshly revised
  wrong reference is **harder** to doubt than a stale correct one, because
  recent edits read as maintained. Before correcting a reference, confirm
  which namespace it belongs to and whether the claim still holds.

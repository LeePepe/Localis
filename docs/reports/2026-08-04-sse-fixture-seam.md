# The cross-end SSE fixture: who guards it, and in which direction

Task #55. Investigation only — no file under `Packages/TransportKit/Tests/`
or `bridge/` is modified by this report.

**Conclusion: do not build anything, and do not wait on the merge either.**
The premise this task was opened on does not hold: an iOS-side edit to
`chat-stream.sse` is *not* silent. It turns the iOS suite red today, on `main`,
with no bridge branch involved. What the bridge-side guard adds is a different
check in the opposite direction, and that one genuinely has no substitute — but
it is not the one that was thought to be missing.

## What was believed, and what is measurable

The task description states the guard's value is "**iOS 改了那个文件，这个 job
就红**", with the implication that nothing else would notice. That is true of
the bridge job and false of the repository as a whole.

I measured it by mutation, because "the tests look like they read the fixture"
and "the tests fail when the fixture changes" are different claims and only the
second one matters. `Packages/` was copied outside the worktree, mutated there,
and the original verified byte-identical afterwards (`b01d22539a15`, unchanged).

| Fixture mutation | iOS suite on `main` |
|---|---|
| none (control) | 258 tests / 19 suites **passed** |
| `"call_id"` → `"callId"` | **failed** — 2 issues, then `Fatal error: Index out of range` |
| `x-localis-turn-end` → `x-localis-turn-finished` | **failed** — `events.map(\.seq)` lost `11` |

The first mutation is exactly the divergence `SharedFixtureTests` was written
against: its own doc comment names "iOS reads `call_id` and this encoder emits
`callId`" as the case where "both sides stay green forever". **On the iOS side
that case is not green.** `StreamEventMapperTests.swift:435-517` pins the
sequence, the reassembled text, and the tool-call pairing to the fixture's
bytes, so a key rename cannot pass through unnoticed.

**Worth recording separately:** that mutation does not merely fail, it
*crashes* — `calls[0]` on an empty array at `:490`. A test that indexes into a
collection it did not first require to be non-empty reports a divergence as a
crash rather than as an expectation failure. It is still red, so nothing is
missed; but the failure names the wrong thing. That is a small, real, and
separately-fixable defect in the iOS test, not in the contract.

## So what does the bridge-side guard actually add

`bridge/Tests/BridgeCoreTests/SharedFixtureTests.swift` reads the iOS fixture
through a `#filePath`-relative URL — it is a read, not a copy, and the file
says why a copy would be worse than no test at all. Its comparisons are:

    missing = expected.subtracting(emitted)    // event names
    missing = theirs.subtracting(mine)         // key names, per event kind

**Both are one-directional, and the direction is the informative one:** every
name iOS expects must be a name the bridge can produce. The reverse is
deliberately not checked — a bridge that emits extra fields is not a break,
because the client ignores what it does not read (FR-010, which the fixture's
`x-localis-invented-later` frame exists to prove).

This gives the two sides genuinely different questions:

- **iOS asks:** does my parser still handle the sample I recorded?
  Answered by replaying the file. Sensitive to any edit of the file.
- **bridge asks:** is that sample something I could actually have emitted?
  Answered by encoding real events and comparing vocabularies. Sensitive to
  edits of the *encoder*.

An iOS edit to the fixture is caught by the first. **A bridge edit to the
encoder is caught only by the second** — and that is the asymmetry worth
naming, because it runs opposite to the one in the task description.

## Which side should hold the seam

Applying #53's rule — an invariant spanning two sides can only be held by a
layer that reaches both — the answer here is unusual: **the invariant is
already held, by a test that reaches both.** `SharedFixtureTests` lives in
`bridge/` but reads across the repository boundary. There is no missing owner.

What is missing is not ownership but *reachability*: the job that runs it is
defined only on `feat/bridge-skeleton`, and that branch has never been opened
as a pull request (task #54's finding, unchanged). The guard is written, is
correct, and has never been armed.

**That is a property of the branch, not of the seam.** Nothing in `main` can
arm it, because the code it runs does not exist in `main`.

## Options, and why each is not worth doing

**A — add a `main`-side check that the fixture has not changed.**
Redundant. The three mutations above show `main` already fails on fixture
edits, with better messages than a hash comparison would produce. A checksum
guard would also fire on *legitimate* edits made together with a matching
parser change, which is a false positive on the exact workflow it should
permit.

**B — copy `SharedFixtureTests` into an iOS-side package.**
It would have to be rewritten against `SSEEncoder`, which lives in `bridge/`
and is not reachable from `Packages/`. What survives the port is only the
fixture-replay half — which already exists. This produces a second copy of a
test that is passing today, and touches `bridge/`, which is out of scope
(#23).

**C — wait for the bridge branch to merge.**
This is what already happens, and it costs nothing. The seam is unguarded in
CI only for edits to the *bridge encoder*, and that encoder does not exist in
`main` — so there is currently nothing on `main` for the unarmed guard to
protect.

## Recommendation

**Do nothing, and specifically do not add a `main`-side fixture guard.** The
gap that motivated this task is closed by tests that already run on every pull
request. The remaining gap is real but empty: it protects code that has not
landed yet, and it closes by itself when `feat/bridge-skeleton` merges — the
same event task #54 already recommends handling by opening that branch as a
draft pull request.

One small thing is worth fixing independently of any of this, and it is inside
my own layer: **`StreamEventMapperTests.swift:490` indexes `calls[0]` without
requiring the array to be non-empty**, so a key-name divergence surfaces as
`Index out of range` instead of as the assertion that was written to catch it.
Not filed as part of this task; noted here so it is not lost.

## Correcting the record

Task #54's report said this contract was verified by neither side. That was
wrong, and the direction of the error matters: it made a guard sound absent
when it was present and passing, which is the kind of claim that gets acted on
by building a replacement for something that already works. The iOS side has
been verifying its half since the fixture was written.

# CI trigger surface: what it costs to widen it, and whether to

Task #54. Investigation only — `ci.yml` is unchanged by this report.

**Conclusion: do not widen `on:`.** The gap it was meant to close is real,
but it is not caused by the trigger filter, and widening the filter does not
close it. A draft pull request closes it completely, at no configuration cost.

## The measurements this rests on

Everything below is from the repository as of `e6ca40f`, and every number is
reproducible with the command beside it.

| Claim | Command | Result |
|---|---|---|
| `ci.yml` runs on GitHub-hosted runners | `gh api .../actions/runs/<id>/jobs --jq '.jobs[].runner_group_name'` | `GitHub Actions` ×9 |
| Only TestFlight is self-hosted | `grep -n 'runs-on:' .github/workflows/*.yml` | `ci.yml` ×3 `macos-26`; `testflight.yml` `[self-hosted, localis-mac]` |
| The repository is public | `gh repo view --json visibility` | `PUBLIC` |
| Nine jobs run concurrently, not queued | job start times within 70 s of each other | 9 distinct runner ids |
| A whole run is ~5 minutes wall clock | slowest job in the latest run | `App target` 5 min; the other eight 0–1 min |
| `feat/bridge-skeleton` has never had a pull request | `gh pr list --state all --head feat/bridge-skeleton` | `[]` |
| …and that empty result is real | same command, `--head docs/waiting-has-a-second-source` | `[{54, MERGED}]` |
| The branch is 30 ahead, 48 behind | `git rev-list --count origin/main..origin/feat/bridge-skeleton` and the reverse | 30 / 48 |

**Two premises in the task description do not hold, and both make the cost
question much cheaper than it looked.** The runner for `ci.yml` is
GitHub-hosted, not a single self-hosted instance — so jobs do not queue behind
each other, and on a *public* repository macOS minutes are not billed at all.
The self-hosted single instance is real, but it belongs to `testflight.yml`,
which this change would not touch.

## What the trigger filter actually filters

    on:
      pull_request:
        branches: [main]

**`branches:` under `pull_request` matches the pull request's _base_, not its
head.** A pull request from any branch into `main` matches this filter.

The evidence is in this repository's own history: pull requests #52, #53 and
#54 were all opened from feature branches, and all three ran the full nine
checks. If the filter restricted CI to work sitting on `main`, none of them
could have run.

So **"no branch other than `main` has independent witness" is not what the
configuration says.** Any branch with an open pull request is witnessed.

## The real gap

`feat/bridge-skeleton` carries 30 commits and 22 test files, and **has never
been opened as a pull request.** That, not the trigger filter, is why its
tests have never run.

What makes it worth writing down: **that branch already defines its own CI
job.** `ci.yml` on `feat/bridge-skeleton` has a `bridge:` job
(`working-directory: bridge`) including a step that checks the bridge's SSE
vocabulary against the iOS side's fixture — a cross-end contract check that
neither side currently verifies.

The witness was written. It has never been triggered, because a workflow job
defined only on a branch runs only when something references that branch, and
the one entry point that would (opening a pull request) was never used.

**This is the shape where a mechanism exists, is correct, and is unreachable**
— the same family as a guard whose only caller was deleted. Reading either
side alone shows nothing wrong: the job definition is right there, and `on:`
is a perfectly ordinary filter.

## Option A — open the branch as a draft pull request (recommended)

- CI runs immediately, **including that branch's own `bridge:` job**: GitHub
  resolves workflow definitions from the pull request's head for
  `pull_request` events.
- **`on:` is not modified**, so nothing changes for anyone else.
- Draft status prevents an accidental merge while still running every check.
- The cross-end SSE fixture check starts running, which is the part with no
  substitute elsewhere.
- Cost: one run per push to that branch, ~5 minutes wall clock, free on a
  public repository. `concurrency: cancel-in-progress: true` is already
  configured against `github.ref`, so consecutive pushes cancel the previous
  run rather than queueing.

**The one thing to check first:** the branch is 48 commits behind `main`.
Whether it opens cleanly is a question for whoever owns it (task #23), not a
CI question.

## Option B — `pull_request: branches: ['**']`

**No effect on this gap.** It widens which *base* branches a pull request may
target, and every pull request here targets `main`. It would matter only if we
started stacking pull requests between feature branches.

## Option C — `push:` on all branches

Works, and costs more than it returns:

- Every push by anyone runs a full nine-job round, including work-in-progress
  commits nobody is asking to have reviewed. Four documentation pushes in one
  afternoon would have been four rounds.
- **It produces no merge gate.** A red run on a pushed branch blocks nothing;
  the pull-request path is what makes a red run consequential.
- On a public repository the minutes are free, so the cost is not money — it
  is that every branch's noise becomes indistinguishable from a signal anyone
  is expected to act on.

## Recommendation

**Do not change `ci.yml`.** Open `feat/bridge-skeleton` as a draft pull
request. It closes the entire gap, changes no shared configuration, and the
job that has been waiting to run is already written on that branch.

**Ownership:** the branch belongs to task #23, and this report deliberately
stops at the recommendation — evaluating is not taking over.

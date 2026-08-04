#!/usr/bin/env bash
# stress-sessionstore: prove the container-construction race stays fixed.
#
# SessionStore's tests used to kill their own process. CoreData assembles each
# entity's derived-attribute trigger SQL into an unsynchronized NSMutableDictionary
# inside `createTriggersForEntities:`; two `ModelContainer` builds reaching it at
# once corrupt the dictionary and the process takes SIGSEGV. Fixed in #11 by a
# serial gate in `SessionStoreContainer.makeContainer`.
#
# ---- why this script exists at all -------------------------------------------
#
# The bug spent two weeks classified as CI flake because somebody ran the suite
# once, saw green, and concluded it was environmental. That inference is not
# careless — it is the only inference a single run supports. At the measured
# rate (2 crashes in 30 runs before the fix) a single clean run happens ~93% of
# the time *with the bug present*.
#
# So "I ran it and it passed" is not evidence here, and the fix's acceptance
# criterion was written as a count: >= 50 consecutive clean runs. That number
# lived in a task description, where it would survive exactly as long as anyone
# remembered to look it up. It lives here instead so that "is it fixed?" has an
# exit code rather than an anecdote.
#
# ---- what a pass does and does not mean --------------------------------------
#
# A clean run of this script says: at this iteration count, the failure did not
# occur. It does not say the race is impossible. The deterministic guard is
# `ContainerConcurrencyTests`, which asserts the gate itself (peak concurrency
# inside the critical section == 1) and fails immediately if the lock is removed.
# This script covers what that test cannot: the real suite, its real container
# count, its real scheduling.
#
# Both are needed. The unit test cannot observe a crash (it kills the process);
# this script cannot tell you *why* a crash happened.
#
# Usage:
#   scripts/stress-sessionstore.sh              # 50 runs, the acceptance criterion
#   scripts/stress-sessionstore.sh 200          # more runs
#   scripts/stress-sessionstore.sh --self-test  # prove this script can still fail
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/Packages/SessionStore"

# The historical rate was ~1 crash per 15 runs. 50 is not a round number chosen
# for looking thorough: below ~45 a clean result is more likely than not even
# with the bug fully present, which would make a pass meaningless.
DEFAULT_RUNS=50

run_stress() {
  local runs="$1"
  local crashes=0
  local other_failures=0
  local clean=0

  local i output
  for ((i = 1; i <= runs; i++)); do
    output="$(cd "$PACKAGE_DIR" && swift test 2>&1)"

    # Two distinct verdicts, deliberately not merged. A signal means the race
    # (or another memory fault); an ordinary test failure means somebody broke
    # something unrelated, and reporting that as "the race is back" would send
    # the next person down the wrong path entirely.
    #
    # Progress goes to stderr, not stdout. stdout carries exactly one line —
    # the counts — because the caller reads it with `read`. An earlier version
    # printed progress to stdout too; `read` then took the first progress line
    # as the counts, and the script reported a clean pass on a run where the
    # crash had actually reproduced. It was caught by running the negative
    # control (lock removed) against the real suite rather than trusting the
    # self-test, which only ever fed it synthetic strings.
    if grep -qi "unexpected signal" <<<"$output"; then
      crashes=$((crashes + 1))
      printf '  run %d/%d — CRASH: %s\n' "$i" "$runs" \
        "$(grep -im1 "unexpected signal" <<<"$output")" >&2
    elif grep -q "Test run with .* passed" <<<"$output"; then
      clean=$((clean + 1))
    else
      other_failures=$((other_failures + 1))
      printf '  run %d/%d — test failure (not a crash)\n' "$i" "$runs" >&2
    fi
  done

  printf '%d %d %d\n' "$crashes" "$other_failures" "$clean"
}

# ---- --self-test: prove this script can still report a crash -----------------
#
# The failure mode this guards against is the one the bug itself had: a check
# that reports success because it is no longer looking. If `swift test` changed
# its wording, or the package path moved, every run would fall through to a
# quiet pass and this script would certify a fix it never observed.
#
# So: feed it a run whose output contains the crash signature and require that
# it says so.
if [ "${1:-}" = "--self-test" ]; then
  echo "self-test: does the crash detector still fire?"

  fake_crash="error: Process ... exited with unexpected signal code 11"
  if grep -qi "unexpected signal" <<<"$fake_crash"; then
    echo "  ✅ crash signature is detected"
  else
    echo "  ❌ crash signature NOT detected — this script would pass through a real crash"
    exit 1
  fi

  fake_clean="Test run with 134 tests in 10 suites passed after 0.4 seconds."
  if grep -q "Test run with .* passed" <<<"$fake_clean"; then
    echo "  ✅ clean-run signature is detected"
  else
    echo "  ❌ clean-run signature NOT detected — every real pass would be miscounted"
    exit 1
  fi

  # A clean run must NOT match the crash pattern and vice versa. Overlapping
  # patterns would make the counts meaningless without either one being absent.
  if grep -qi "unexpected signal" <<<"$fake_clean"; then
    echo "  ❌ clean output matches the crash pattern — counts would be wrong"
    exit 1
  fi
  echo "  ✅ the two signatures do not overlap"

  if [ ! -d "$PACKAGE_DIR" ]; then
    echo "  ❌ package not found at $PACKAGE_DIR — every run would fail to build"
    exit 1
  fi
  echo "  ✅ package directory exists"

  # The signature checks above are necessary and were not sufficient: they all
  # passed while the script was reporting clean runs on a suite that was
  # crashing. The counts travel from run_stress to the caller through stdout,
  # and progress lines were going to the same place, so `read` consumed a
  # progress line as the counts. Every pattern matched correctly; the number
  # never arrived.
  #
  # So check the channel, not just the patterns: run_stress's stdout must be
  # exactly one line of three integers, whatever else it prints.
  probe_stdout="$(PACKAGE_DIR=/nonexistent run_stress 1 2>/dev/null)"
  if [[ "$probe_stdout" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
    echo "  ✅ counts reach the caller uncontaminated by progress output"
  else
    echo "  ❌ run_stress stdout is not a bare count line: '$probe_stdout'"
    echo "     The caller reads this with \`read\`; anything else silently"
    echo "     miscounts and can report a clean pass over real crashes."
    exit 1
  fi

  echo "self-test passed."
  exit 0
fi

RUNS="${1:-$DEFAULT_RUNS}"
if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [ "$RUNS" -lt 1 ]; then
  echo "usage: $0 [run-count | --self-test]" >&2
  exit 2
fi

if [ "$RUNS" -lt "$DEFAULT_RUNS" ]; then
  echo "⚠️  $RUNS runs is below the $DEFAULT_RUNS-run acceptance criterion."
  echo "   A clean result at this count does not distinguish a fixed race from"
  echo "   a present one. Reporting it as evidence would repeat the original"
  echo "   misdiagnosis."
  echo
fi

echo "stress: $RUNS consecutive runs of SessionStore's suite"
echo "        (looking for signal 11 in container construction)"
echo

read -r CRASHES OTHER CLEAN <<<"$(run_stress "$RUNS")"

echo
if [ "$CRASHES" -gt 0 ]; then
  echo "❌ the container-construction race reproduced: $CRASHES crash(es) in $RUNS runs"
  echo
  echo "   Stack to expect (from ~/Library/Logs/DiagnosticReports/):"
  echo "     -[__NSDictionaryM setObject:forKey:]"
  echo "     -[NSSQLEntity_DerivedAttributesExtension _generateTriggerSQL]"
  echo "     -[NSSQLiteConnection createTriggersForEntities:]"
  echo
  echo "   Check that SessionStoreContainer.makeContainer still takes"
  echo "   constructionLock, and that no new factory bypasses it."
  exit 1
fi

if [ "$OTHER" -gt 0 ]; then
  echo "⚠️  no crashes, but $OTHER run(s) had ordinary test failures."
  echo "   The race is not implicated. Something else is broken — fix that first,"
  echo "   because a suite that cannot pass cannot demonstrate the absence of a"
  echo "   crash either."
  exit 1
fi

echo "✅ $CLEAN/$RUNS runs clean, no signal 11."
echo
echo "   This is evidence at this iteration count, not a proof of impossibility."
echo "   The deterministic guard is ContainerConcurrencyTests, which fails"
echo "   immediately if the construction lock is removed."

#!/usr/bin/env bash
#
# Runs the shared-fixture test and proves it actually ran.
#
# The test compares this bridge's SSE vocabulary against the iOS side's
# `chat-stream.sse`. Its whole value is that an iOS edit to that file turns this
# suite red — but the person editing it is on the iOS side, so the red has to
# appear in CI, not only on the bridge author's laptop.
#
# **Why this is a script and not one `swift test --filter` line.** `--filter`
# matches type and function names, not `@Test("display names")`. A filter that
# matches nothing prints `Test run with 0 tests` and **exits 0** — a green run
# that verified nothing at all. Renaming the suite would silently disarm the
# check and every CI run would keep passing.
#
# So the count is parsed and required to be non-zero. Run with --self-test to
# prove this script can still fail.
set -euo pipefail

BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="SharedFixtureTests"

run_suite() {
    swift test --package-path "$BRIDGE_DIR" --filter "$1" 2>&1
}

# Extracts the N from "Test run with N tests". Empty if the line is absent.
test_count() {
    grep -oE 'Test run with [0-9]+ test' <<<"$1" | grep -oE '[0-9]+' | head -1
}

check() {
    local output count
    # The run's exit status is captured rather than allowed to kill the script,
    # so a genuine test failure is reported as one instead of as a crash.
    if ! output="$(run_suite "$SUITE")"; then
        echo "FAIL: $SUITE reported failures" >&2
        grep -E "recorded an issue|error:" <<<"$output" | head -20 >&2
        return 1
    fi

    count="$(test_count "$output")"

    if [[ -z "$count" ]]; then
        echo "FAIL: could not read a test count from swift test output" >&2
        echo "      (the output format changed — this check cannot vouch for anything)" >&2
        return 1
    fi

    if [[ "$count" -eq 0 ]]; then
        echo "FAIL: the filter '$SUITE' matched no tests." >&2
        echo "      swift test exits 0 in this case, so this would have been a green" >&2
        echo "      run that verified nothing. Was the suite renamed or deleted?" >&2
        return 1
    fi

    echo "OK: $SUITE ran $count tests against the iOS fixture"
}

# --- Self-test -------------------------------------------------------------
#
# Proves the zero-match guard fires, using a suite name that cannot exist. If
# this ever passes, the guard above has stopped guarding and every CI run since
# has been meaningless.
self_test() {
    local output count
    output="$(run_suite "NoSuchSuiteNameShouldMatchNothing" || true)"
    count="$(test_count "$output")"

    if [[ "$count" != "0" ]]; then
        echo "SELF-TEST FAIL: expected a 0-test run from a bogus filter, got '${count:-<none>}'" >&2
        return 1
    fi

    echo "SELF-TEST OK: a filter matching nothing reports 0 tests (and would be caught)"
}

if [[ "${1:-}" == "--self-test" ]]; then
    self_test
else
    check
fi

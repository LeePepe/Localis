#!/usr/bin/env bash
#
# Mutation round against the host/pin composition point.
#
# WHAT THIS ANSWERS. `HostAssemblyTests` is green. Green means the assertions
# hold against the code as written; it does not mean the assertions would
# notice if the code were wrong. This script breaks `HostAssembly` on purpose,
# four ways, and reports whether the suite goes red for each. A mutant that
# survives is a hole in the tests, not a bug in the app.
#
# THE THREE WAYS THIS SCRIPT COULD LIE, AND WHAT STOPS EACH:
#
#   1. The mutation never lands (pattern typo, file moved). The edit would be a
#      no-op, the suite would pass, and the output would say SURVIVES —
#      indistinguishable from a real hole. Guarded by comparing the file before
#      and after: an unchanged file is reported as DUD, never as SURVIVES.
#
#   2. The mutant does not compile. A build failure is not the suite catching
#      anything, but xcodebuild exits non-zero either way and a naive script
#      would score it KILLED. Guarded by looking for TEST FAILED / TEST
#      SUCCEEDED explicitly; anything else is DUD.
#
#   3. The suite was already red. Then every mutant "dies" and the round proves
#      nothing. Guarded by the baseline run below, which must be green before
#      any mutation is applied.
#
# RESTORING. The file is restored on every exit path, including Ctrl-C and
# timeout — a mutant left in the working tree is a defect disguised as working
# code. The restore is conditional: other agents share this checkout, and
# writing the original back unconditionally would silently discard an edit
# someone else made while this ran. It only writes back if the file on disk is
# still the mutant this script put there.

set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$REPO" || exit 1

TARGET="Localis/Sources/HostAssembly.swift"
SUITE="Joining a stored machine to its pin"
# The floor the run must clear to be believed at all. Not the exact count —
# that would go stale on every added test and train people to bump it without
# reading. It is a smoke alarm for "the selector matched almost nothing".
MIN_TESTS=20
DEVICE="${LOCALIS_SIM_UDID:-}"
WORK="$(mktemp -d)"
ORIGINAL="$WORK/original.swift"
MUTANT="$WORK/mutant.swift"

cleanup() {
    # Only restore if the file is still our mutant. If it differs, someone
    # else edited it while we ran and their work outranks our rollback.
    if [[ -f "$ORIGINAL" && -f "$MUTANT" ]] && cmp -s "$TARGET" "$MUTANT"; then
        cp "$ORIGINAL" "$TARGET"
        echo "restored $TARGET"
    elif [[ -f "$ORIGINAL" ]] && ! cmp -s "$TARGET" "$ORIGINAL"; then
        echo "WARNING: $TARGET is neither the original nor our mutant." >&2
        echo "         Left untouched. Original saved at $ORIGINAL" >&2
        exit 1
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

if [[ -z "$DEVICE" ]]; then
    echo "Set LOCALIS_SIM_UDID to a booted simulator UDID (xcrun simctl list devices)." >&2
    echo "Addressed by UDID, not by name: a name that matches no eligible device" >&2
    echo "makes xcodebuild print a list and exit 0 without building anything." >&2
    exit 1
fi

cp "$TARGET" "$ORIGINAL"

# Runs the suite. Echoes exactly one word: SUCCEEDED, FAILED, or BROKEN.
#
# The verdict comes from xcodebuild's own summary line, not from its exit code:
# a build that fails to compile and a suite whose assertions fail both exit
# non-zero, and only one of them means the tests did their job.
run_suite() {
    local log="$WORK/run.log"
    xcodebuild test \
        -project Localis.xcodeproj \
        -scheme Localis \
        -destination "id=$DEVICE" \
        -only-testing:LocalisTests \
        -skipPackagePluginValidation > "$log" 2>&1

    if grep -q '\*\* TEST SUCCEEDED \*\*' "$log"; then
        # A green run that executed nothing is not a survivor — it is a broken
        # selector. `-only-testing:LocalisTests` names a target, and a target
        # that has been renamed or emptied still exits SUCCEEDED with zero
        # tests. That prints identically to "the mutation was invisible to the
        # suite", which is the single most misleading confusion this script can
        # produce: it turns a tooling fault into a finding.
        #
        # The count is read from the run's own summary rather than assumed.
        # Anything below the floor means the selector, not the code, is what
        # changed.
        local count
        count="$(grep -oE 'Test run with [0-9]+ test' "$log" | grep -oE '[0-9]+' | tail -1)"
        if [[ -z "$count" || "$count" -lt "$MIN_TESTS" ]]; then
            echo "    --- ran ${count:-0} tests, expected at least $MIN_TESTS ---" >&2
            echo "    --- the selector is wrong; no conclusion is possible ---" >&2
            echo "NOTRUN"
            return
        fi
        echo "SUCCEEDED"
    elif grep -q '\*\* TEST FAILED \*\*' "$log"; then
        # Distinguish "assertions failed" from "did not compile". Both print
        # TEST FAILED; only the first is a kill.
        if grep -qE '^[^ ]+\.swift:[0-9]+:[0-9]+: error:' "$log"; then
            report_broken "$log"
            echo "BROKEN"
        else
            echo "FAILED"
        fi
    else
        report_broken "$log"
        echo "BROKEN"
    fi
}

# BROKEN without evidence is unactionable, and the temp directory is deleted on
# exit — so the compiler's own words are copied out before that happens. A
# verdict the reader cannot act on is barely better than no verdict.
report_broken() {
    local log="$1"
    local kept="$REPO/.mutation-broken.log"
    cp "$log" "$kept"
    {
        echo "    --- build did not produce a test result. First errors: ---"
        grep -E 'error:' "$log" | grep -v swiftmacro | head -5 | sed 's/^/    /'
        echo "    --- full log: $kept ---"
    } >&2
}

echo "=== baseline: the suite must be green before anything is mutated ==="
BASELINE="$(run_suite)"
if [[ "$BASELINE" != "SUCCEEDED" ]]; then
    echo "Baseline is $BASELINE, not SUCCEEDED. A mutation round against a red" >&2
    echo "suite proves nothing — every mutant would 'die' for the wrong reason." >&2
    exit 1
fi
echo "baseline green"
echo

# Each mutant is a sed expression that breaks one guarantee, paired with the
# test that is supposed to notice. The expected-catcher is documentation, not
# an assertion: it says what this script is really testing.
#
# Format: label :: sed-expression :: which test should catch it
MUTANTS=(
"pin is never attached::s|return stored.paired(pinning: pin)|return stored|::a paired machine with its pin is connectable"
"revoked hosts get pinned too::s|guard stored.pairingState == .paired else { return stored }||::an unpaired machine is never given a pin"
"keychain errors are swallowed::s|guard let pin = try credentials.pin|guard let pin = try? credentials.pin|::a Keychain failure is reported"
"list skips the join::s|try await repository.hosts().map(joined)|try await repository.hosts()|::every machine in the list is joined"
)

# THE POSITIVE CONTROL, and the reason it is first.
#
# Four mutants dying is the result this script is *supposed* to produce, which
# makes it the result least able to prove itself. "0 survived" and "the SURVIVED
# branch is unreachable" print identically. So the round opens with a mutation
# that changes the file — it is not a dud — but provably cannot change
# behaviour: it edits a comment. That must be reported SURVIVED. If it is not,
# this script cannot report a survivor at all and every clean sweep it has ever
# printed was meaningless.
#
# This is the same rule the project keeps rediscovering: before believing X
# tells you about Y, confirm X actually varies with Y.
if [[ "${1:-}" != "--no-self-check" ]]; then
    echo "=== self-check: a comment edit must be reported SURVIVED ==="
    cp "$ORIGINAL" "$TARGET"
    printf '\n// mutation self-check: behaviourally inert by construction\n' >> "$TARGET"
    cp "$TARGET" "$MUTANT"

    if cmp -s "$TARGET" "$ORIGINAL"; then
        echo "Self-check could not modify $TARGET at all." >&2
        exit 1
    fi

    control="$(run_suite)"
    if [[ "$control" != "SUCCEEDED" ]]; then
        echo "Self-check mutant was scored $control, expected SUCCEEDED (a survivor)." >&2
        echo "A comment cannot change behaviour, so the suite must stay green." >&2
        echo "This script cannot currently distinguish a survivor from a kill." >&2
        exit 1
    fi
    echo "self-check passed: the SURVIVED path is reachable"
    echo
fi

SURVIVORS=0
DUDS=0
KILLED=0

for entry in "${MUTANTS[@]}"; do
    label="${entry%%::*}"
    rest="${entry#*::}"
    expr="${rest%%::*}"
    rest="${rest#*::}"
    catcher="${rest%%::*}"

    printf '=== mutant: %s\n' "$label"

    cp "$ORIGINAL" "$TARGET"
    sed -i '' "$expr" "$TARGET"
    cp "$TARGET" "$MUTANT"

    # The dud check. An unchanged file means the pattern did not match, and a
    # suite that passes against unmutated code says nothing at all.
    if cmp -s "$TARGET" "$ORIGINAL"; then
        echo "    DUD — the mutation did not apply (pattern did not match)."
        echo "    Not a survivor: nothing was tested."
        DUDS=$((DUDS + 1))
        echo
        continue
    fi

    verdict="$(run_suite)"
    case "$verdict" in
        FAILED)
            echo "    KILLED — suite went red, as it should."
            echo "    expected catcher: $catcher"
            KILLED=$((KILLED + 1))
            ;;
        SUCCEEDED)
            echo "    *** SURVIVED *** — this break is invisible to the tests."
            echo "    expected catcher (did not fire): $catcher"
            SURVIVORS=$((SURVIVORS + 1))
            ;;
        NOTRUN)
            echo "    ABORTED — the run executed too few tests to mean anything."
            echo "    Not a survivor: the selector is broken, not the suite."
            exit 1
            ;;
        BROKEN)
            echo "    DUD — the mutant did not compile, so no test ran."
            echo "    A compile failure is not the suite catching anything."
            DUDS=$((DUDS + 1))
            ;;
    esac
    echo
done

cp "$ORIGINAL" "$TARGET"
cp "$TARGET" "$MUTANT"

echo "=== $KILLED killed, $SURVIVORS survived, $DUDS duds ==="
if [[ $DUDS -gt 0 ]]; then
    echo "Duds are not passes. Each one is a mutation that never ran, and the"
    echo "guarantee it was meant to probe is still unmeasured."
fi
[[ $SURVIVORS -eq 0 && $DUDS -eq 0 ]]

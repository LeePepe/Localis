#!/usr/bin/env bash
#
# Mutation round against the app-target assembly.
#
# WHAT THIS ANSWERS. Every `@Test` in `LocalisAppTests` has a display name that
# states a guarantee, and every one of them is green. Reading the bodies says
# the assertions look related to the names. Reading cannot say whether the
# assertion would go red if the guarantee were broken — that is the whole
# defect this suite exists to catch, and it is not visible by inspection. So
# each named guarantee gets broken on purpose here, and the run reports whether
# the test that claims to guard it actually goes red.
#
# A survivor is a green light guarding nothing. It is not a bug in the app.
#
# WHY THE MUTANTS ARE ALL COMPILABLE. A mutation that fails to build proves
# only that the compile edge is live; it says nothing about whether any test
# executed the changed code. Each break below is a plausible regression — the
# shape a real mistake would take — not a syntax error.
#
# THE THREE WAYS THIS SCRIPT COULD LIE, AND WHAT STOPS EACH:
#
#   1. The mutation never lands (pattern typo, file moved, text reworded). The
#      edit is a no-op, the suite passes, and the output reads SURVIVED —
#      indistinguishable from a real hole. Guarded by comparing each file before
#      and after: unchanged is reported DUD, never SURVIVED.
#
#   2. The mutant does not compile. xcodebuild exits non-zero either way, so a
#      naive script scores it KILLED. Guarded by reading the TEST SUCCEEDED /
#      TEST FAILED summary and separating compiler errors from failed
#      assertions.
#
#   3. The suite ran almost nothing. A target selector that matches an emptied
#      or renamed target still exits SUCCEEDED with zero tests, which prints
#      exactly like "the mutation was invisible to the suite" — turning a
#      tooling fault into a finding. Guarded by the MIN_TESTS floor.
#
# And the fourth, which the other three cannot catch: a clean sweep cannot
# prove it was capable of reporting a survivor. Hence the positive control.
#
# RESTORING. Two files are mutated across the round, and the restore is
# per-file and conditional: this checkout is shared, so writing an original back
# over an edit another agent made while this ran would destroy their work
# silently — worse than leaving a mutant behind, because it looks like nothing
# happened.

set -uo pipefail

# The repo root, from this script's own location rather than from git.
#
# `git rev-parse --show-toplevel` is the obvious spelling and it is wrong here:
# git exports GIT_DIR when it runs a hook, and with GIT_DIR set,
# `git -C scripts rev-parse --show-toplevel` answers about the *cwd* it was
# handed and returns `<repo>/scripts`. Checked in this tree rather than assumed
# — the same command prints the repo root bare and `<repo>/scripts` with GIT_DIR
# exported.
#
# Every path below would then miss by one directory: `cd` fails, and with
# `set -uo pipefail` (no `-e`) the script carries on in whatever directory it
# started in, where `$DETAIL` and `$LIST` do not exist. `snapshot` exits 1 — so
# the visible symptom is a round that dies before its baseline, from a hook,
# while passing standalone. That is the pair of results least likely to be read
# as one bug.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

DETAIL="Localis/Sources/SessionDetailView.swift"
LIST="Localis/Sources/SessionListModel.swift"
# The floor the run must clear to be believed at all. A floor, not the exact
# count: an exact count goes stale on every added test and trains the reader to
# bump it without looking.
MIN_TESTS=20
DEVICE="${LOCALIS_SIM_UDID:-}"
WORK="$(mktemp -d)"

# Snapshot both files up front. `$WORK/orig.<n>` is the original, `$WORK/mut.<n>`
# is whatever this script last wrote there.
FILES=("$DETAIL" "$LIST")

snapshot() {
    local i=0
    for f in "${FILES[@]}"; do
        cp "$f" "$WORK/orig.$i" || exit 1
        i=$((i + 1))
    done
}

# Restores one file only if it still holds the mutant this script put there.
restore_all() {
    local i=0 f
    for f in "${FILES[@]}"; do
        if [[ -f "$WORK/mut.$i" ]] && cmp -s "$f" "$WORK/mut.$i"; then
            cp "$WORK/orig.$i" "$f"
        elif [[ -f "$WORK/orig.$i" ]] && ! cmp -s "$f" "$WORK/orig.$i"; then
            echo "WARNING: $f is neither the original nor our mutant." >&2
            echo "         Left untouched. Original saved at $WORK/orig.$i" >&2
            KEEP_WORK=1
        fi
        i=$((i + 1))
    done
}

KEEP_WORK=0
cleanup() {
    restore_all
    if [[ "$KEEP_WORK" == "1" ]]; then
        echo "Work directory kept: $WORK" >&2
        exit 1
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

if [[ -z "$DEVICE" ]]; then
    echo "Set LOCALIS_SIM_UDID to a booted simulator UDID (xcrun simctl list devices booted)." >&2
    echo "Addressed by UDID, not by name: a name matching no eligible device makes" >&2
    echo "xcodebuild print a list and exit 0 without building anything." >&2
    exit 1
fi

snapshot

# Runs the suite. Echoes exactly one word: SUCCEEDED, FAILED, BROKEN, NOTRUN.
#
# The verdict comes from xcodebuild's own summary line, never its exit code: a
# build that did not compile and a suite whose assertions failed both exit
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

# Which tests failed, so a kill can be checked against the test that was
# *supposed* to catch it. A mutant killed by an unrelated test is a different
# fact from the one this round is asking about.
failing_tests() {
    grep -oE "Test \"[^\"]+\" failed" "$WORK/run.log" | sed 's/^Test "/    red: /; s/" failed$//' | sort -u
}

report_broken() {
    local log="$1"
    local kept="$REPO/.mutation-app-broken.log"
    cp "$log" "$kept"
    {
        echo "    --- build did not produce a test result. First errors: ---"
        grep -E 'error:' "$log" | grep -v swiftmacro | head -5 | sed 's/^/    /'
        echo "    --- full log: $kept ---"
    } >&2
}

# Which code this round is a statement about.
#
# A mutation table reads like a property of the source under test. It is not —
# it is a property of the *pair* (source, test suite), and either half moving
# invalidates it. That is not hypothetical: mutant 4 below had one named catcher
# when this was first run, and two after a colleague's PR merged a second test
# that seeds the same field down a different path. Nothing of mine changed.
#
# So the round stamps its own base. A table without one reads like a permanent
# conclusion, which is exactly how a stale one gets quoted months later.
echo "=== base: $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD) ==="
if [[ -n "$(git status --porcelain -- "$DETAIL" "$LIST" LocalisTests/ 2>/dev/null)" ]]; then
    echo "    (working tree is dirty — this table describes the tree, not the commit)"
fi
echo

echo "=== baseline: the suite must be green before anything is mutated ==="
BASELINE="$(run_suite)"
if [[ "$BASELINE" != "SUCCEEDED" ]]; then
    echo "Baseline is $BASELINE, not SUCCEEDED. A mutation round against a red" >&2
    echo "suite proves nothing — every mutant would 'die' for the wrong reason." >&2
    exit 1
fi
echo "baseline green"
echo

# Format: file :: label :: sed-expression :: the test whose NAME claims to guard this
#
# The expected catcher is the whole point of the round. "Something went red" is
# not the question — the question is whether the test that advertises this
# guarantee is the one that noticed.
MUTANTS=(
"$DETAIL::a missing agent is not explained::s|sendBlockedReason = String($|sendBlockedReason = nil; _ = String(|::a session whose agent is gone keeps its transcript and says why it can't send"
"$DETAIL::submit drops the message silently::s|?? String(localized: \"This conversation has no agent to send to.\")|?? Optional<String>.none|::submitting with no backend says why rather than silently dropping the message"
"$DETAIL::a deleted session reads as empty::s|loadError = \"This session is no longer on this device.\"|loadError = nil|::a session deleted before it opened says so rather than showing an empty transcript"
"$DETAIL::no composer is projected::s|composer = ComposerState.make(from: session)|composer = nil|::opening a session projects a transcript and a composer"
"$LIST::backends are keyed to one host for all::s|collected\[backend.ref(on: hostID)\]|collected[backend.ref(on: sessions[0].hostID)]|::two machines both advertising 'claude' keep their own names"
"$LIST::the list ignores the repository::s|rows = sessions.map { SessionRowState.make(from: \$0, backends: backends) }|rows = []|::the session list is read from the repository"
)

# THE POSITIVE CONTROL, and the reason it runs first.
#
# Six mutants dying is the result this script is supposed to produce, which
# makes it the result least able to prove itself: "0 survived" and "the SURVIVED
# branch is unreachable" print identically. So the round opens with an edit that
# changes the file — provably not a dud — but cannot change behaviour, because
# it is a comment. It must be reported SURVIVED. If it is not, this script
# cannot report a survivor at all, and every clean sweep it prints is empty.
if [[ "${1:-}" != "--no-self-check" ]]; then
    echo "=== self-check: a comment edit must be reported SURVIVED ==="
    printf '\n// mutation self-check: behaviourally inert by construction\n' >> "$DETAIL"
    cp "$DETAIL" "$WORK/mut.0"

    if cmp -s "$DETAIL" "$WORK/orig.0"; then
        echo "Self-check could not modify $DETAIL at all." >&2
        exit 1
    fi

    control="$(run_suite)"
    if [[ "$control" != "SUCCEEDED" ]]; then
        echo "Self-check mutant scored $control, expected SUCCEEDED (a survivor)." >&2
        echo "A comment cannot change behaviour, so the suite must stay green." >&2
        echo "This script cannot currently tell a survivor from a kill." >&2
        exit 1
    fi
    cp "$WORK/orig.0" "$DETAIL"
    rm -f "$WORK/mut.0"
    echo "self-check passed: the SURVIVED path is reachable"
    echo
fi

SURVIVORS=0
DUDS=0
KILLED=0
WRONG_CATCHER=0

for entry in "${MUTANTS[@]}"; do
    file="${entry%%::*}"; rest="${entry#*::}"
    label="${rest%%::*}"; rest="${rest#*::}"
    expr="${rest%%::*}"
    catcher="${rest##*::}"

    # Which snapshot index this file is.
    idx=0
    for f in "${FILES[@]}"; do
        [[ "$f" == "$file" ]] && break
        idx=$((idx + 1))
    done

    echo "=== mutant: $label ==="
    echo "    expected catcher: $catcher"

    cp "$WORK/orig.$idx" "$file"
    sed -i '' "$expr" "$file"

    if cmp -s "$file" "$WORK/orig.$idx"; then
        # The pattern matched nothing. Reporting this as SURVIVED would invent
        # a hole in the tests out of a typo in this script.
        echo "    DUD — the edit did not change the file. No conclusion."
        DUDS=$((DUDS + 1))
        echo
        continue
    fi
    cp "$file" "$WORK/mut.$idx"

    case "$(run_suite)" in
        FAILED)
            reds="$(failing_tests)"
            if grep -qF "$catcher" <<< "$reds"; then
                echo "    KILLED by the test that claims to guard it."
                KILLED=$((KILLED + 1))
            else
                # Something noticed, but not the test whose name advertises
                # this rule. That test is still a green light guarding nothing;
                # it is merely standing next to one that works.
                echo "    KILLED — but NOT by its expected catcher."
                echo "    The named guarantee is guarded elsewhere, not here."
                WRONG_CATCHER=$((WRONG_CATCHER + 1))
            fi
            echo "$reds"
            ;;
        SUCCEEDED)
            echo "    SURVIVED — the suite is green with this guarantee broken."
            echo "    '$catcher' does not check what it says."
            SURVIVORS=$((SURVIVORS + 1))
            ;;
        NOTRUN)
            echo "    ABORTED — the run executed too few tests to mean anything."
            echo "    Not a survivor: the selector is broken, not the suite."
            exit 1 ;;
        BROKEN)
            echo "    DUD — the mutant did not compile. Not a kill."
            DUDS=$((DUDS + 1))
            ;;
    esac

    cp "$WORK/orig.$idx" "$file"
    rm -f "$WORK/mut.$idx"
    echo
done

echo "=== $KILLED killed by name, $WRONG_CATCHER killed by another test, $SURVIVORS survived, $DUDS duds ==="
[[ "$SURVIVORS" == "0" && "$DUDS" == "0" && "$WRONG_CATCHER" == "0" ]] || exit 1

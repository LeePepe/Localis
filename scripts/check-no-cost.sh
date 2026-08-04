#!/usr/bin/env bash
# check-no-cost: FR-059's cost clause, enforced instead of remembered.
#
# spec.md FR-059:
#
#   **cost（金额）才是 seam**：v1 不做，界面上 MUST NOT 存在任何与之相关的元素；
#   日后由 bridge 算好显示值经开放信封下发，MUST NOT 需要 iOS 发版。
#
# Nothing violates this today. That is exactly why the check is being added now.
#
# ---- why now, with nothing to fix --------------------------------------------
#
# A guard written before the first violation costs one file. The same guard
# written after costs a conversation: somebody has shipped a cost label, and
# removing it means telling a person who already did the work that their work
# has to come out. The technical diff is identical; the social cost is not,
# and that difference is what decides whether the rule survives.
#
# The constraint is also the kind that erodes silently. "Show what this cost"
# is a reasonable-sounding product request, and the reason it is excluded —
# device-side pricing goes stale the moment a provider changes rates, and the
# spec routes the value through bridge so that fixing it never needs an iOS
# release — lives in a spec paragraph nobody rereads before adding a label.
#
# ---- what this checks, and what it cannot ------------------------------------
#
# It greps UI sources for money vocabulary and currency-shaped literals. That
# catches the realistic path (someone adds `Text("Cost: \(cost)")`) and misses
# an obfuscated one (a `Double` named `spend` rendered through a formatter).
# The check is stated at its real strength rather than described as proof.
#
# Deliberately NOT flagged: `token`, `usage`, `elapsed`. FR-059 keeps token
# usage as Certain data that MUST be rendered when present — a check that
# tripped on those would push someone to delete a required feature to get green,
# which is worse than the violation it prevents.
#
# Usage:
#   scripts/check-no-cost.sh              # scan UI sources
#   scripts/check-no-cost.sh --self-test  # prove the check can still fail
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# UI surfaces only. The constraint is about what the interface shows, so
# scanning the whole repo would flag this script, the spec that states the rule,
# and any bridge-side plumbing that legitimately carries a cost value later —
# and a check that cries wolf on its own rulebook gets muted.
SCAN_DIRS=(
  "$REPO_ROOT/Packages/LocalisUI/Sources"
  "$REPO_ROOT/Localis/Sources"
)

# Two halves, each tuned by its own false-positive risk.
#
# Vocabulary: matched case-insensitively as a substring, not word-anchored.
# `\b` fails on the names that actually get written — `pricePerToken` and
# `billingNote` both slipped through an anchored version during self-test,
# because in camelCase the word boundary is not where the word is. `costly`
# matching is an accepted cost of that.
#
# Currency literals: `$` must be followed by a digit AND not be Swift's `$0`
# closure shorthand, which appears in nearly every SwiftUI file. An earlier
# `\$[0-9]` flagged `ForEach { $0.id }` in four places — a check that fires on
# ubiquitous idiom gets switched off within a day, so this excludes `$0`-`$9`
# followed by `.` or a word character.
COST_VOCABULARY='cost|pricing|price|billing|dollar|usd|cents?\b'
COST_LITERAL='\$[0-9]+([.,][0-9]|[0-9])|[¥€£][0-9]'
COST_PATTERN="$COST_VOCABULARY|$COST_LITERAL"

scan() {
  local dir hits=""
  for dir in "${SCAN_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    # Comments are stripped before matching: a doc comment explaining *why*
    # cost is excluded is the most likely place for the word to appear
    # legitimately, and flagging it would make the rule's own rationale
    # unwritable.
    while IFS= read -r file; do
      local stripped match
      stripped="$(sed -E 's://.*$::' "$file")"
      match="$(grep -niE "$COST_PATTERN" <<<"$stripped" || true)"
      # Prefix every matched line with its file. Joining file and matches with
      # a bare colon put multi-line grep output on lines that carried no file
      # name, and the loop that renders the report dropped them — the check
      # exited 1 with an empty list, naming nothing to fix. Caught by injecting
      # a real violation into a real source file; the self-test, which only
      # feeds strings to the pattern, could not have seen it.
      if [ -n "$match" ]; then
        while IFS= read -r line; do
          [ -n "$line" ] && hits+="${file}:${line}"$'\n'
        done <<<"$match"
      fi
    done < <(find "$dir" -name '*.swift' -type f)
  done
  printf '%s' "$hits"
}

# ---- --self-test: prove the check can still fail -----------------------------
#
# The failure mode being guarded against is a check that goes quiet — a reworded
# pattern, a moved directory, a `find` that matches nothing. A silent pass and a
# genuinely clean tree look identical from the outside, so the pattern is fed an
# input that must match.
if [ "${1:-}" = "--self-test" ]; then
  echo "self-test: can this check still detect a violation?"

  failed=0
  for sample in 'Text("Cost: \(total)")' 'let pricePerToken = 0.003' \
                'Label("$4.20", systemImage: "dollarsign")' 'var billingNote: String' \
                'Text(spend.formatted(.currency(code: "USD")))'; do
    if grep -qiE "$COST_PATTERN" <<<"$sample"; then
      echo "  ✅ flags: $sample"
    else
      echo "  ❌ MISSED: $sample"
      failed=1
    fi
  done

  # Negative samples matter as much: a pattern that flags everything would also
  # "pass" the checks above while making the script useless in practice.
  for sample in 'ForEach(items) { $0.id }' 'let tokenCount = usage.tokens' \
                'FailureDetail(elapsed: $0.elapsed)' 'MessageRow { onAction($0) }' \
                'sorted { $0.rawValue < $1.rawValue }'; do
    if grep -qiE "$COST_PATTERN" <<<"$sample"; then
      echo "  ❌ FALSE POSITIVE: $sample"
      failed=1
    else
      echo "  ✅ ignores: $sample"
    fi
  done

  for dir in "${SCAN_DIRS[@]}"; do
    if [ -d "$dir" ]; then
      count=$(find "$dir" -name '*.swift' -type f | wc -l | tr -d ' ')
      if [ "$count" -eq 0 ]; then
        echo "  ❌ $dir has no .swift files — the scan would silently cover nothing"
        failed=1
      else
        echo "  ✅ $dir: $count files in scope"
      fi
    else
      echo "  ❌ scan directory missing: $dir"
      failed=1
    fi
  done

  [ "$failed" -eq 0 ] || { echo "self-test FAILED."; exit 1; }

  # End-to-end: the pattern checks above all passed while the report itself
  # came out empty — exit 1 with nothing named. Feeding strings to a regex
  # proves the regex; it does not prove the path from a matched file to a
  # printed line. So write a real violation into a real file and require that
  # the scan both finds it and can say where.
  probe_dir="${SCAN_DIRS[0]}"
  probe_file="$probe_dir/.cost-guard-selftest.swift"
  printf 'struct SelfTestProbe { let pricePerToken = 0.003 }\n' >"$probe_file"
  probe_hits="$(scan)"
  rm -f "$probe_file"

  if [ -z "$probe_hits" ]; then
    echo "  ❌ a real violation in a real file was not detected"
    exit 1
  fi
  if ! grep -q "cost-guard-selftest.swift:1:" <<<"$probe_hits"; then
    echo "  ❌ violation detected but not reportable — got: '$probe_hits'"
    echo "     The check would exit 1 while naming nothing to fix."
    exit 1
  fi
  echo "  ✅ a real violation is both detected and reported with file:line"

  echo "self-test passed."
  exit 0
fi

HITS="$(scan)"

if [ -z "$HITS" ]; then
  echo "✅ no cost elements in the UI (FR-059)."
  exit 0
fi

echo "❌ FR-059: cost-related elements found in UI sources."
echo
# Rendered with a plain read loop and parameter expansion rather than piping
# through sed. The piped version printed nothing at all: the pipeline ran the
# loop in a subshell whose output never reached the terminal, so the check
# exited 1 with an empty findings list. Twice now the pattern was right and the
# reporting path was broken — the exit code and the report are separate things
# to verify.
while IFS= read -r line; do
  [ -n "$line" ] && echo "   ${line#"$REPO_ROOT"/}"
done <<<"$HITS"
echo
echo "   spec.md FR-059: cost is a seam — v1 does not do it, and the interface"
echo "   MUST NOT contain any element related to it."
echo
echo "   The reason is not squeamishness about money: a price computed on the"
echo "   device goes stale the moment a provider changes rates, and there is no"
echo "   way to correct it without shipping a new build. The spec routes the"
echo "   display value through bridge precisely so that fixing it never needs an"
echo "   iOS release."
echo
echo "   Token usage is different and is required — render it when present."
exit 1

#!/usr/bin/env bash
# check-wiring: verify the app target actually *uses* the packages it declares.
#
# `project.yml` listing a package under the app target's `dependencies` links it
# into the binary. It does not import it. The two can disagree, and when they do
# the build configuration is the half everyone reads — nobody counts imports —
# so a package can sit declared-but-unused indefinitely while every signal in
# the repo reads as wired.
#
# That is not hypothetical: it is how ChatService, TransportKit and SkillsKit
# came to have hundreds of passing tests and zero production call sites.
#
# ---- why the criterion is what it is -----------------------------------------
#
# The first version of this script asked only "is the package imported?". It
# went green for TransportKit the moment a file gained the line
# `import TransportKit` and used nothing from it — not one symbol. The real
# state was unchanged: zero `BridgeClient` values are constructed anywhere in
# the app. The check was satisfied; the thing it existed to prove was not.
#
# So the criterion is now: **a declared package must be imported AND at least
# one symbol it exclusively owns must actually be referenced**. That is still
# not proof of reachability from `LocalisApp` — the stronger property — but it
# cannot be satisfied by a line that does nothing, and cheapness of satisfaction
# is what made the last criterion worthless.
#
# References are counted with comments and string literals stripped, because a
# package name inside a doc comment is exactly as cheap as an empty import and
# would reintroduce the same hole one layer down.
#
# Ownership is computed from the packages themselves rather than hardcoded: a
# type declared `public` in exactly one package is evidence for that package.
# Types declared in two (today: `Outcome`) are ambiguous and are dropped from
# the evidence set — counting them could credit the wrong package. Every
# package currently has unambiguously-owned types; if one ever has none, that
# is reported rather than silently passed.
#
# Requires python3 (already required by check-frontmatter.sh).
#
# Usage:
#   scripts/check-wiring.sh                # check the repo
#   scripts/check-wiring.sh --self-test    # prove the check can still fail
set -uo pipefail
REPO="$(git rev-parse --show-toplevel)"; cd "$REPO"
command -v python3 >/dev/null || { echo "⚠️  no python3, skipping wiring check"; exit 0; }

PROJECT_YML="project.yml"
APP_SOURCES="Localis/Sources"
PACKAGES_DIR="Packages"

# ---- the check itself, as a function so --self-test can run it twice --------
#
# $1: project.yml   $2: app sources dir   $3: packages dir
#
# Prints one line per problem, each as `<verdict>\t<package>`:
#   NOT-IMPORTED   declared, never imported
#   IMPORT-ONLY    imported, but no symbol of that package is referenced
#   NO-EVIDENCE    the package exposes no unambiguously-owned public symbol,
#                  so "is it used" cannot be answered — reported, not assumed
# Silent when clean. `PARSE-ERROR: ...` when the parse itself came up empty.
wiring_problems() {
  python3 - "$1" "$2" "$3" <<'PY'
import os, re, sys
from collections import defaultdict

project_yml, sources_dir, packages_dir = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(project_yml, encoding='utf-8').read()

# The app target's dependency list. Parsed structurally rather than with a line
# range: `project.yml` contains *two* blocks that begin `  Localis:` — the
# scheme at the top and the target further down — and a naive range grabs the
# scheme, whose dependency list is empty. An empty declared-set makes every
# comparison below vacuously pass, which is the exact way this check would rot
# into a permanent green. So: find every `  Localis:` block and keep the one
# that actually declares `dependencies:`.
declared = set()
for match in re.finditer(r'^  Localis:\n((?:    .*\n|\n)*)', text, re.M):
    block = match.group(1)
    if 'dependencies:' not in block:
        continue
    declared |= set(re.findall(r'^      - package:\s*(\S+)\s*$', block, re.M))

if not declared:
    # Never "no problems found" — a parse that finds nothing is a broken parse,
    # not a clean repo. Louder than a silent pass, on purpose.
    print("PARSE-ERROR: no app-target dependencies found in " + project_yml)
    sys.exit(0)


def swift_files(root):
    for base, _, names in os.walk(root):
        for name in names:
            if name.endswith('.swift'):
                yield os.path.join(base, name)


def strip_noise(src):
    """Remove comments and string literals.

    A symbol named in a doc comment is as cheap to write as an empty import, so
    counting it as evidence of use would rebuild the hole this check exists to
    close.
    """
    src = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)
    src = re.sub(r'//[^\n]*', ' ', src)
    src = re.sub(r'"""(?:.|\n)*?"""', ' ', src)
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', ' ', src)
    return src


# Which package publicly declares which type. Types owned by more than one
# package are ambiguous evidence and get dropped below.
#
# Nominal types only — not `func`, `var` or `let`. Member names are far too
# common to be evidence of anything: counting them credited TransportKit for
# the words `cancel`, `map` and `sessionID`, none of which came from
# TransportKit, in a file that used nothing of it. That is the same false green
# this rewrite exists to remove, arriving from the other direction. A
# capitalised nominal type is the narrowest thing that can only plausibly have
# come from the package that declares it.
DECL = re.compile(
    r'^\s*public\s+(?:final\s+|indirect\s+)*'
    r'(?:struct|class|enum|actor|protocol|typealias)\s+([A-Z]\w*)',
    re.M,
)
owners = defaultdict(set)
for package in sorted(os.listdir(packages_dir)):
    package_sources = os.path.join(packages_dir, package, 'Sources')
    if not os.path.isdir(package_sources):
        continue
    for path in swift_files(package_sources):
        with open(path, encoding='utf-8') as handle:
            for symbol in DECL.findall(strip_noise(handle.read())):
                owners[symbol].add(package)

exclusive = defaultdict(set)          # package -> symbols only it declares
for symbol, packages in owners.items():
    if len(packages) == 1:
        exclusive[next(iter(packages))].add(symbol)

# What the app imports, and every identifier it mentions outside comments.
imported, identifiers = set(), set()
for path in swift_files(sources_dir):
    with open(path, encoding='utf-8') as handle:
        source = strip_noise(handle.read())
    imported |= set(re.findall(r'^\s*import\s+(\w+)', source, re.M))
    body = re.sub(r'^\s*import\s+\w+\s*$', ' ', source, flags=re.M)
    identifiers |= set(re.findall(r'\b[A-Za-z_]\w*\b', body))

for package in sorted(declared):
    if package not in imported:
        print("NOT-IMPORTED\t" + package)
        continue
    symbols = exclusive.get(package, set())
    if not symbols:
        # Cannot be answered rather than answered "fine". A package with no
        # exclusively-owned public symbol gives this check nothing to look for,
        # and silently passing it is how a blind spot becomes a green tick.
        print("NO-EVIDENCE\t" + package)
        continue
    if not (symbols & identifiers):
        print("IMPORT-ONLY\t" + package)
PY
}

# ---- --self-test: prove the check is still capable of failing ---------------
#
# A wiring check that has silently degraded to always-green is worse than no
# check at all: it tells the next person the assembly is sound.
#
# Three cases, one per way this check has been or could be fed a false green:
#   1. declared and never imported     — the original defect
#   2. imported, no symbol used        — the empty `import TransportKit`
#   3. symbol named only in a comment  — the same trick one layer down
# Case 3 is not hypothetical-only: it is what stripping comments buys, and
# without a case pinning it, a future simplification would drop the stripping
# and nothing would go red.
if [ "${1:-}" = "--self-test" ]; then
  FIXTURE="$(mktemp -d)"
  trap 'rm -rf "$FIXTURE"' EXIT
  mkdir -p "$FIXTURE/Sources" "$FIXTURE/Packages/Ghost/Sources"
  cat > "$FIXTURE/project.yml" <<'YML'
  Localis:
    build:
      targets:
        Localis: all
  Localis:
    type: application
    dependencies:
      - package: Ghost
YML
  cat > "$FIXTURE/Packages/Ghost/Sources/Ghost.swift" <<'SWIFT'
public struct GhostOnlySymbol {}
public func cancel() {}
SWIFT

  fail=0
  expect() { # $1 label  $2 expected line  $3 swift source
    printf '%s' "$3" > "$FIXTURE/Sources/Only.swift"
    got="$(wiring_problems "$FIXTURE/project.yml" "$FIXTURE/Sources" "$FIXTURE/Packages")"
    if [ "$got" != "$(printf '%b' "$2")" ]; then
      echo "❌ self-test FAILED [$1]: expected '$2', got: ${got:-<nothing>}"
      fail=1
    fi
  }

  expect "never imported" 'NOT-IMPORTED\tGhost' 'import SwiftUI
'
  expect "imported but unused" 'IMPORT-ONLY\tGhost' 'import Ghost
'
  expect "symbol only in a comment" 'IMPORT-ONLY\tGhost' 'import Ghost
// GhostOnlySymbol is mentioned here and nowhere real.
'
  # A member name is not evidence. Before this case existed, the real run
  # credited TransportKit for the words `cancel`, `map` and `sessionID` in a
  # file that used nothing of it — a false green arriving from the opposite
  # direction to the empty import, and just as wrong.
  expect "member name is not evidence" 'IMPORT-ONLY\tGhost' 'import Ghost
func somethingElse() { cancel() }
'
  # The negative case matters as much as the positive ones: a check that
  # reports a problem unconditionally also "always fails" and is equally
  # useless. This is the one input that must come back clean.
  expect "genuinely used" '' 'import Ghost
let value = GhostOnlySymbol()
'

  if [ "$fail" -eq 0 ]; then
    echo "✅ self-test: the wiring check still detects unimported, import-only"
    echo "   and comment-only packages, and still passes a real use."
    exit 0
  fi
  echo "   The check can no longer be trusted, so its green result means nothing."
  exit 1
fi

# ---- the real run -----------------------------------------------------------
[ -f "$PROJECT_YML" ] || { echo "❌ missing $PROJECT_YML"; exit 1; }
[ -d "$APP_SOURCES" ] || { echo "❌ missing $APP_SOURCES"; exit 1; }
[ -d "$PACKAGES_DIR" ] || { echo "❌ missing $PACKAGES_DIR"; exit 1; }

PROBLEMS="$(wiring_problems "$PROJECT_YML" "$APP_SOURCES" "$PACKAGES_DIR")"

if [ -z "$PROBLEMS" ]; then
  echo "✅ wiring: every package the app target declares is imported and used."
  exit 0
fi

if echo "$PROBLEMS" | grep -q '^PARSE-ERROR:'; then
  echo "❌ $PROBLEMS"
  echo "   A parse that finds no dependencies would make this check pass forever."
  exit 1
fi

# ---- --porcelain: the raw verdicts, for callers that decide per problem ------
#
# Prints `VERDICT<TAB>PACKAGE` records instead of prose. It exists because the
# pre-commit hook has to let one known-open gap through while still blocking
# every other one, and the only alternative — matching the English sentences
# below — is a filter that silently stops matching when someone rewords a
# message. A stale allowlist pattern and a genuinely clean run produce the same
# thing here: no output. The verdict vocabulary is fixed; the prose is not.
#
# Still exits non-zero: this is a different rendering of a failure, not a
# softer one. A caller that wants to forgive something has to say so itself.
if [ "${1:-}" = "--porcelain" ]; then
  echo "$PROBLEMS"
  exit 1
fi

echo "❌ wiring: $PROJECT_YML declares packages the app does not really use:"
echo "$PROBLEMS" | while IFS=$'\t' read -r verdict package; do
  case "$verdict" in
    NOT-IMPORTED) echo "     - $package — declared, never imported" ;;
    IMPORT-ONLY)  echo "     - $package — imported, but not one of its symbols is used" ;;
    NO-EVIDENCE)  echo "     - $package — exposes no exclusively-owned public symbol; use cannot be verified" ;;
  esac
done
echo
echo "   Linked into the binary, not used by it. The build configuration says"
echo "   these layers are wired and the source says they are not — and the"
echo "   configuration is the half people read."
echo
echo "   An \`import\` alone does not count: an import that uses nothing is the"
echo "   cheapest possible way to turn this check green without changing what"
echo "   the app actually does."
echo
echo "   Either really use it under $APP_SOURCES/ or drop it from $PROJECT_YML."
exit 1

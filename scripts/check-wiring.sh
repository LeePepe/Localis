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
# What this checks is narrow on purpose: **every package the app target declares
# must be imported at least once under Localis/Sources/**. It does not check
# that anything is reachable from `LocalisApp` — that is the stronger property,
# and it only becomes meaningful once the assembly layer exists.
#
# Requires python3 (already required by check-frontmatter.sh).
#
# Usage:
#   scripts/check-wiring.sh          # check the repo
#   scripts/check-wiring.sh --self-test   # prove the check can still fail
set -uo pipefail
REPO="$(git rev-parse --show-toplevel)"; cd "$REPO"
command -v python3 >/dev/null || { echo "⚠️  no python3, skipping wiring check"; exit 0; }

PROJECT_YML="project.yml"
APP_SOURCES="Localis/Sources"

# ---- the check itself, as a function so --self-test can run it twice --------
#
# $1: project.yml to read     $2: sources directory to scan
# Prints the undeclared-but-unused packages, one per line. Silent when clean.
unused_packages() {
  python3 - "$1" "$2" <<'PY'
import os, re, sys

project_yml, sources_dir = sys.argv[1], sys.argv[2]
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

imported = set()
for root, _, files in os.walk(sources_dir):
    for name in files:
        if not name.endswith('.swift'):
            continue
        with open(os.path.join(root, name), encoding='utf-8') as handle:
            imported |= set(re.findall(r'^\s*import\s+(\w+)', handle.read(), re.M))

for package in sorted(declared - imported):
    print(package)
PY
}

# ---- --self-test: prove the check is still capable of failing ---------------
#
# A wiring check that has silently degraded to always-green is worse than no
# check at all: it tells the next person the assembly is sound. The parse above
# already refuses to pass on an empty declared-set, and this proves that refusal
# still works by running the check against a fixture that must fail.
if [ "${1:-}" = "--self-test" ]; then
  FIXTURE="$(mktemp -d)"
  trap 'rm -rf "$FIXTURE"' EXIT
  mkdir -p "$FIXTURE/Sources"
  cat > "$FIXTURE/project.yml" <<'YML'
  Localis:
    build:
      targets:
        Localis: all
  Localis:
    type: application
    dependencies:
      - package: DefinitelyNotImported
YML
  cat > "$FIXTURE/Sources/Only.swift" <<'SWIFT'
import SwiftUI
SWIFT
  result="$(unused_packages "$FIXTURE/project.yml" "$FIXTURE/Sources")"
  if [ "$result" = "DefinitelyNotImported" ]; then
    echo "✅ self-test: the wiring check still detects an unused declared package."
    exit 0
  fi
  echo "❌ self-test FAILED: expected 'DefinitelyNotImported', got: ${result:-<nothing>}"
  echo "   The check can no longer fail, so its green result means nothing."
  exit 1
fi

# ---- the real run -----------------------------------------------------------
[ -f "$PROJECT_YML" ] || { echo "❌ missing $PROJECT_YML"; exit 1; }
[ -d "$APP_SOURCES" ] || { echo "❌ missing $APP_SOURCES"; exit 1; }

UNUSED="$(unused_packages "$PROJECT_YML" "$APP_SOURCES")"

if [ -z "$UNUSED" ]; then
  echo "✅ wiring: every package the app target declares is imported."
  exit 0
fi

if echo "$UNUSED" | grep -q '^PARSE-ERROR:'; then
  echo "❌ $UNUSED"
  echo "   A parse that finds no dependencies would make this check pass forever."
  exit 1
fi

echo "❌ wiring: $PROJECT_YML declares packages the app never imports:"
echo "$UNUSED" | sed 's/^/     - /'
echo
echo "   Linked into the binary, never used by it. The build configuration says"
echo "   these layers are wired and the source says they are not — and the"
echo "   configuration is the half people read."
echo
echo "   Either import it under $APP_SOURCES/ or drop it from $PROJECT_YML."
exit 1

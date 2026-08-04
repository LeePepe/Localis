#!/usr/bin/env bash
# check-frontmatter: verify each checked layer's tech-context.md frontmatter
# still matches the code. Rot is an error (exit 1). Requires python3.
#
# Five checks:
#   ⓪ the checked-layer list ⇄ the filesystem — bidirectional (see below)
#   ① layer name == directory name
#   ② depends_on ⇄ Package.swift's .package(path: "../X") — bidirectional
#      (nothing missing, nothing extra, no ghost layers)
#   ③ the --package-path in the `test:` command exists
#   ④ roles: keys are all in the top-level tech-context.md `canonical_roles`,
#      and each entry really exists under Sources/<Pkg> (as a directory or
#      <entry>.swift)
#
# **Why the layer list is written out instead of globbed.** This used to loop
# over `Packages/*/tech-context.md`, which cannot distinguish a layer whose
# frontmatter is clean from a layer that has no tech-context.md at all: the
# second one simply never enters the loop, and the run ends green. Adding a
# package and forgetting its tech-context.md therefore bought silence, which is
# the one outcome that reads as approval. Naming the layers makes the absent
# file an error rather than an empty iteration.
#
# An explicit list has the opposite failure — it goes stale — so check ⓪ closes
# that direction too: a directory under Packages/ that nobody added to the list
# is itself reported. Neither half is optional; either one alone restores the
# hole the other closes.
#
# Shared by pre-commit and the CI policy job. The only language-specific part is
# the Package.swift dependency extraction.
#
# Usage:
#   scripts/check-frontmatter.sh              # check the repo
#   scripts/check-frontmatter.sh --self-test  # prove the check can still fail
set -uo pipefail
REPO="$(git rev-parse --show-toplevel)"; cd "$REPO"
command -v python3 >/dev/null || { echo "⚠️  no python3, skipping frontmatter check"; exit 0; }

# ---- the layers this script checks ------------------------------------------
#
# One line per layer, as a repo-relative directory holding a tech-context.md.
# A new package goes here in the same commit that creates it — check ⓪ fails
# until it does.
CHECKED_LAYERS=(
  Packages/ChatService
  Packages/DesignKit
  Packages/LocalisModels
  Packages/LocalisUI
  Packages/SessionStore
  Packages/SkillsKit
  Packages/TransportKit
)

# Where check ⓪ looks for layers that were never listed.
PACKAGES_DIR="Packages"

# ---- ⓪ the list ⇄ the filesystem, both directions ---------------------------
#
# $1: the directory to scan for unlisted layers   $2..: the listed layers
#
# Prints one line per problem, each as `<verdict>\t<layer>`:
#   MISSING-DIR      listed, but the directory does not exist
#   MISSING-CONTEXT  listed, directory exists, no tech-context.md in it
#   UNLISTED         a directory under $1 that the list does not name
# Silent when the two agree.
coverage_problems() {
  local scan_dir="$1"; shift
  local listed=("$@")
  local layer dir base found

  for layer in "${listed[@]}"; do
    if [ ! -d "$layer" ]; then
      printf 'MISSING-DIR\t%s\n' "$layer"
    elif [ ! -f "$layer/tech-context.md" ]; then
      printf 'MISSING-CONTEXT\t%s\n' "$layer"
    fi
  done

  for dir in "$scan_dir"/*/; do
    [ -d "$dir" ] || continue
    base="${dir%/}"
    found=0
    for layer in "${listed[@]}"; do
      [ "$layer" = "$base" ] && { found=1; break; }
    done
    [ "$found" -eq 1 ] || printf 'UNLISTED\t%s\n' "$base"
  done
}

# ---- --self-test: prove check ⓪ is still capable of failing -----------------
#
# The list exists to turn a missing tech-context.md into an error. A coverage
# check that has degraded to always-green would restore exactly the silence it
# was written to remove, and would do it invisibly — the run still prints ✅.
#
# Four cases: one per verdict, plus the negative control. The last one matters
# as much as the first three: a check that reports a problem unconditionally is
# equally useless, and only a clean input can tell the two apart.
if [ "${1:-}" = "--self-test" ]; then
  FIXTURE="$(mktemp -d)"
  trap 'rm -rf "$FIXTURE"' EXIT
  mkdir -p "$FIXTURE/Packages/Listed" "$FIXTURE/Packages/Bare" "$FIXTURE/Packages/Forgotten"
  : > "$FIXTURE/Packages/Listed/tech-context.md"
  # Bare/ deliberately has no tech-context.md; Forgotten/ is deliberately absent
  # from every list below.

  fail=0
  expect() { # $1 label  $2 expected output  $3.. the listed layers
    local label="$1" want="$2"; shift 2
    local got
    got="$(coverage_problems "$FIXTURE/Packages" "$@")"
    if [ "$got" != "$(printf '%b' "$want")" ]; then
      echo "❌ self-test FAILED [$label]: expected '$want', got: ${got:-<nothing>}"
      fail=1
    fi
  }

  expect "listed layer has no tech-context.md" \
    "MISSING-CONTEXT\t$FIXTURE/Packages/Bare\nUNLISTED\t$FIXTURE/Packages/Forgotten" \
    "$FIXTURE/Packages/Listed" "$FIXTURE/Packages/Bare"

  expect "listed layer does not exist" \
    "MISSING-DIR\t$FIXTURE/Packages/Ghost\nUNLISTED\t$FIXTURE/Packages/Bare\nUNLISTED\t$FIXTURE/Packages/Forgotten" \
    "$FIXTURE/Packages/Listed" "$FIXTURE/Packages/Ghost"

  expect "layer on disk that nobody listed" \
    "UNLISTED\t$FIXTURE/Packages/Bare\nUNLISTED\t$FIXTURE/Packages/Forgotten" \
    "$FIXTURE/Packages/Listed"

  # The negative control. Bare/ is named *and* given a tech-context.md here, so
  # a run that still reports it would be reporting unconditionally.
  : > "$FIXTURE/Packages/Bare/tech-context.md"
  : > "$FIXTURE/Packages/Forgotten/tech-context.md"
  expect "list and filesystem agree" '' \
    "$FIXTURE/Packages/Listed" "$FIXTURE/Packages/Bare" "$FIXTURE/Packages/Forgotten"

  if [ "$fail" -eq 0 ]; then
    echo "✅ self-test: the coverage check still detects an unwritten"
    echo "   tech-context.md, a listed layer that is gone, and an unlisted"
    echo "   layer on disk — and still passes a list that matches the tree."
    exit 0
  fi
  echo "   The check can no longer be trusted, so its green result means nothing."
  exit 1
fi

TOP_CONTEXT="tech-context.md"
[ -f "$TOP_CONTEXT" ] || { echo "❌ missing top-level $TOP_CONTEXT"; exit 1; }

# ---- parse canonical_roles (top level) --------------------------------------
CANON="$(python3 - "$TOP_CONTEXT" <<'PY'
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
m = re.match(r'^---\n(.*?)\n---\n', t, re.S)
fm = m.group(1) if m else ""
mm = re.search(r'^canonical_roles:\s*\[(.*?)\]\s*$', fm, re.M)
roles = [r.strip() for r in (mm.group(1) if mm else "").split(',') if r.strip()]
print(",".join(roles))
PY
)"
[ -n "$CANON" ] || { echo "❌ $TOP_CONTEXT: missing canonical_roles"; exit 1; }

# frontmatter parser (written to a temp file — avoids heredoc-inside-$() paren traps)
PARSER="$(mktemp)"; trap 'rm -f "$PARSER"' EXIT
cat > "$PARSER" <<'PY'
import sys, re
text = open(sys.argv[1], encoding='utf-8').read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.S)
if not m: print("NO_FRONTMATTER"); sys.exit(0)
fm = m.group(1)
def scalar(k):
    mm = re.search(r'^%s:\s*(.+)$' % re.escape(k), fm, re.M)
    return mm.group(1).strip() if mm else ""
def listfield(k):
    mm = re.search(r'^%s:\s*\[(.*?)\]\s*$' % re.escape(k), fm, re.M)
    return [x.strip() for x in (mm.group(1) if mm else "").split(',') if x.strip()]
print("LAYER="+scalar("layer"))
print("TEST="+scalar("test"))
print("DEPS="+",".join(listfield("depends_on")))
PY

fail=0

# ---- ⓪ the real coverage run ------------------------------------------------
#
# Runs before the per-layer loop: if a layer is missing its tech-context.md,
# every check below it has nothing to read, and "no findings" would be the
# result of not looking.
COVERAGE="$(coverage_problems "$PACKAGES_DIR" "${CHECKED_LAYERS[@]}")"
if [ -n "$COVERAGE" ]; then
  while IFS=$'\t' read -r verdict layer; do
    [ -z "$verdict" ] && continue
    case "$verdict" in
      MISSING-DIR)
        echo "❌ $layer: listed in CHECKED_LAYERS but the directory does not exist"
        echo "   (removed? drop it from the list in $0)" ;;
      MISSING-CONTEXT)
        echo "❌ $layer: listed in CHECKED_LAYERS but has no tech-context.md"
        echo "   Every layer documents its own dependencies; an absent file is"
        echo "   the one state that used to pass silently." ;;
      UNLISTED)
        echo "❌ $layer: exists on disk but is not in CHECKED_LAYERS"
        echo "   Nothing checks its frontmatter, and the run would still be green."
        echo "   Add it to the list in $0 and give it a tech-context.md." ;;
    esac
    fail=1
  done <<< "$COVERAGE"
fi

for dir in "${CHECKED_LAYERS[@]}"; do
  tc="$dir/tech-context.md"
  # Already reported by check ⓪ above — skipping here avoids a second, less
  # specific complaint about the same missing file.
  [ -f "$tc" ] || continue
  pkg="$(basename "$dir")"
  parsed="$(python3 "$PARSER" "$tc")"
  [ "$parsed" = "NO_FRONTMATTER" ] && { echo "❌ $tc: missing frontmatter"; fail=1; continue; }
  layer="$(echo "$parsed"   | sed -n 's/^LAYER=//p')"
  deps="$(echo "$parsed"    | sed -n 's/^DEPS=//p')"
  testcmd="$(echo "$parsed" | sed -n 's/^TEST=//p')"

  # ① layer name == directory name
  [ "$layer" = "$pkg" ] || { echo "❌ $tc: layer='$layer' ≠ directory '$pkg'"; fail=1; }

  # ② depends_on ⇄ Package.swift, both directions
  declared="$(grep -oE '\.package\(path:[[:space:]]*"\.\./[^"]+"' "$dir/Package.swift" 2>/dev/null \
                | sed -E 's|.*/([^"]+)".*|\1|' | sort -u || true)"
  IFS=',' read -ra darr <<< "$deps"
  for d in "${darr[@]:-}"; do [ -z "$d" ] && continue
    [ -d "Packages/$d" ] || { echo "❌ $tc: depends_on '$d' is a ghost layer (Packages/$d does not exist)"; fail=1; }
    echo "$declared" | grep -qx "$d" || { echo "❌ $tc: depends_on lists '$d' but Package.swift does not declare it"; fail=1; }
  done
  while IFS= read -r pd; do [ -z "$pd" ] && continue
    echo ",$deps," | grep -q ",$pd," || { echo "❌ $tc: Package.swift depends on '$pd' but depends_on omits it"; fail=1; }
  done <<< "$declared"

  # ③ the test command's --package-path exists
  tp="$(echo "$testcmd" | grep -oE -- '--package-path[[:space:]]+[^[:space:]]+' | awk '{print $2}')"
  [ -z "$tp" ] || [ -d "$tp" ] || { echo "❌ $tc: test path '$tp' does not exist"; fail=1; }

  # ④ roles: keys ∈ canonical_roles; every entry exists under Sources/<Pkg>
  #    (done in python — bash arrays + IFS are fragile under set -u)
  roles_err="$(python3 - "$tc" "$dir" "$pkg" "$CANON" <<'PY'
import sys, re, os, glob
tc, dir_, pkg, canon = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split(',')
fm = re.match(r'^---\n(.*?)\n---\n', open(tc, encoding='utf-8').read(), re.S)
fm = fm.group(1) if fm else ""
roles, in_roles = {}, False
for line in fm.splitlines():
    if re.match(r'^roles:\s*$', line): in_roles = True; continue
    if in_roles:
        mm = re.match(r'^\s+([A-Za-z]+):\s*\[(.*?)\]\s*$', line)
        if mm: roles[mm.group(1)] = [x.strip() for x in mm.group(2).split(',') if x.strip()]
        elif re.match(r'^\S', line): in_roles = False
srcroot = os.path.join(dir_, "Sources", pkg)
errs = []
for key, entries in roles.items():
    if key not in canon:
        errs.append(f"roles key '{key}' is not in canonical_roles {canon}")
    for e in entries:
        if os.path.isdir(os.path.join(srcroot, e)): continue
        if os.path.isfile(os.path.join(srcroot, e + ".swift")): continue
        if glob.glob(os.path.join(srcroot, "**", e + ".swift"), recursive=True): continue
        errs.append(f"roles entry '{e}' (key {key}) is neither a directory nor <entry>.swift under {srcroot}")
for x in errs: print(x)
PY
)"
  if [ -n "$roles_err" ]; then
    while IFS= read -r line; do [ -z "$line" ] && continue; echo "❌ $tc: $line"; fail=1; done <<< "$roles_err"
  fi
done

[ "$fail" -eq 0 ] && echo "✅ frontmatter matches the code" \
  || { echo "Architecture changed? Update the corresponding tech-context.md frontmatter and retry."; exit 1; }

#!/usr/bin/env bash
# check-frontmatter: verify each Packages/<X>/tech-context.md frontmatter still
# matches the code. Rot is an error (exit 1). Requires python3.
#
# Four checks:
#   ① layer name == directory name
#   ② depends_on ⇄ Package.swift's .package(path: "../X") — bidirectional
#      (nothing missing, nothing extra, no ghost layers)
#   ③ the --package-path in the `test:` command exists
#   ④ roles: keys are all in the top-level tech-context.md `canonical_roles`,
#      and each entry really exists under Sources/<Pkg> (as a directory or
#      <entry>.swift)
#
# Shared by pre-commit and the CI policy job. The only language-specific part is
# the Package.swift dependency extraction.
set -uo pipefail
REPO="$(git rev-parse --show-toplevel)"; cd "$REPO"
command -v python3 >/dev/null || { echo "⚠️  no python3, skipping frontmatter check"; exit 0; }

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
for tc in Packages/*/tech-context.md; do
  [ -f "$tc" ] || continue
  dir="$(dirname "$tc")"; pkg="$(basename "$dir")"
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

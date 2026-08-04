#!/usr/bin/env bash
# Usage:
#   scripts/check-script-credentials.sh              # check the repo
#   scripts/check-script-credentials.sh --self-test  # prove the check can still fail
#
# Does any credential this repo's shell code handles end up somewhere it can be
# read?
#
# **The criterion is the credential's destination, not its appearance.** Nothing
# here matches the *shape* of a secret — no entropy threshold, no `[A-Za-z0-9]{40}`,
# no list of words like `token` or `password`. Two reasons, and the second is the
# one that matters:
#
#   1. Shape-matching cannot see a real credential that arrives at runtime. Every
#      credential in this repo comes from `${{ secrets.* }}` or the Keychain and
#      is a variable at rest — there is no literal to match, so a scanner built
#      on shapes reports zero and has reported zero honestly. That zero is
#      indistinguishable from "this repo handles no credentials", which is false.
#
#   2. Shape-matching is satisfiable without changing behaviour. Rename the
#      variable, split the literal, base64 it — the scanner goes quiet and the
#      credential still lands in the log. A check whose green can be bought that
#      cheaply teaches the next person that quiet means safe.
#
# So the variable declares its own identity and the check answers a mechanical
# data-flow question about it: **does this variable's value reach argv, a log
# line, a redirect, or a step output?** A name proves nothing here; only a
# declaration does. `check-script-credentials.sh --self-test` pins that with a
# case named "undeclared variable is not a credential", where a variable called
# `API_TOKEN` is echoed and the check must stay silent. If someone ever rewrites
# this to match names, that case goes red.
#
# Two ways a variable declares itself a credential:
#   * a workflow step's `env:` entry whose value is `${{ secrets.NAME }}` — the
#     workflow itself is saying so, and it cannot be wrong about it;
#   * `# credential: NAME` in a shell script, for values that arrive by other
#     means (Keychain, `read -s`, an argument).
#
# **Nothing found is not the same as nothing to find**, so a run that discovers
# zero declared credentials fails rather than passes: at time of writing this
# repo has four, and a scan that comes back with none has stopped looking rather
# than stopped finding. Same for a workflow file that mentions `secrets.` but
# yields no parsed declaration.
#
# ---- What this check does NOT do -------------------------------------------
#
# It is not a secret scanner. It never reads a value and never decides whether a
# string looks sensitive. That matters for one specific reason on this repo:
# `Packages/TransportKit` and `Packages/LocalisModels` contain test inputs like
# `/Users/tian/secret/path`, which exist precisely to prove the redaction code
# strips them. A shape-based scan flags those, someone "fixes" them, and the
# anti-leak tests quietly stop testing anything. This check cannot make that
# mistake, because it has no opinion about what a secret looks like — and it
# does not read Swift at all.
#
# ---- Acknowledged exposures --------------------------------------------------
#
# Some exposures have no better form available (`security unlock-keychain -p`
# takes the password in argv and offers no non-interactive alternative). Those
# are acknowledged in place, on or directly above the line:
#
#     # credential-exposure: argv — <why this is the least-bad available form>
#
# Acknowledged exposures are **printed on every run, including a clean one**, and
# counted in the summary. They are not suppressed and they do not go silent —
# the point is that the list stays in front of whoever reads the output, because
# an exposure nobody can see is one nobody revisits. A bare marker with no reason
# does not count as an acknowledgement.
set -uo pipefail
REPO="$(git rev-parse --show-toplevel)"; cd "$REPO"
command -v python3 >/dev/null || { echo "⚠️  no python3, skipping credential check"; exit 0; }

# ---- the check itself, as a function so --self-test can run it twice ---------
#
# $1: root directory to scan.
#
# Scans every shell file under the root — `*.sh`, `scripts/hooks/*`, and the
# `run:` blocks of `.github/workflows/*.yml` — and prints one line per problem:
#
#   ECHOED        <file:line>  <var>   value written to stdout/stderr → the log
#   STEP-OUTPUT   <file:line>  <var>   value written to $GITHUB_OUTPUT/$GITHUB_ENV
#   REDIRECT      <file:line>  <var>   value written into a file
#   HEREDOC       <file:line>  <var>   value interpolated into a heredoc body
#   ARGV          <file:line>  <var>   value passed to an external command's argv
#   ACK           <file:line>  <var>   an exposure, acknowledged in place
#   NO-DECLARATIONS                    scanned everything, found no credentials
#   PARSE-ERROR: ...                   a file names secrets we could not parse
#
# Silent when clean and nothing is acknowledged.
credential_exposures() {
  python3 - "$1" <<'PY'
import os, re, sys

root = sys.argv[1]

# ---- which files carry shell code -------------------------------------------
SKIP_DIRS = {'.git', '.build', 'node_modules', 'DerivedData'}

def shell_files(root):
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in names:
            path = os.path.join(base, name)
            rel = os.path.relpath(path, root)
            if name.endswith('.sh'):
                yield rel, 'sh'
            elif rel.startswith(os.path.join('.github', 'workflows')) and name.endswith(('.yml', '.yaml')):
                yield rel, 'yaml'
            elif os.sep + 'hooks' + os.sep in os.sep + rel and os.access(path, os.X_OK) and '.' not in name:
                yield rel, 'sh'


# ---- shell analysis ----------------------------------------------------------
#
# Builtins that do not fork. A value expanded here never reaches another
# process's argv, so `[ -z "${TOKEN:-}" ]` is a presence check, not an exposure
# — and treating it as one would make the safe way to check for a secret look
# identical to leaking it.
SAFE_BUILTINS = {'[', '[[', 'test', ':', 'true', 'false', 'return', 'shift', 'unset'}
LOGGING = {'echo', 'printf', 'print', 'cat', 'tee', 'logger'}
# Writing here persists the value into the step's outputs / the job environment,
# where later steps and the run log can read it. Distinct from a plain redirect
# because the remedy is different: there is no file to delete afterwards.
STEP_SINKS = ('GITHUB_OUTPUT', 'GITHUB_ENV', 'GITHUB_STEP_SUMMARY')

ACK = re.compile(r'#\s*credential-exposure:\s*\S+\s*[-—:]\s*(\S.{11,})')


def strip_comment(line):
    """Drop a trailing comment, respecting quotes.

    Naively cutting at the first `#` breaks on `"https://host/#frag"` and on
    `${VAR:-#}`, and the failure mode is silent: the rest of the line stops
    being analysed and whatever leak it contained is not reported.
    """
    out, quote = [], None
    for i, ch in enumerate(line):
        if quote:
            out.append(ch)
            if ch == quote and (i == 0 or line[i - 1] != '\\'):
                quote = None
        elif ch in '"\'':
            quote = ch
            out.append(ch)
        elif ch == '#' and (not out or out[-1].isspace()):
            break
        else:
            out.append(ch)
    return ''.join(out)


def split_commands(line):
    """Split into simple commands on `|`, `;`, `&&`, `||`, outside quotes."""
    parts, buf, quote, i = [], [], None, 0
    while i < len(line):
        ch = line[i]
        if quote:
            buf.append(ch)
            if ch == quote and line[i - 1] != '\\':
                quote = None
        elif ch in '"\'':
            quote = ch
            buf.append(ch)
        elif ch in ';|&' :
            if line[i:i + 2] in ('&&', '||'):
                i += 1
            parts.append(''.join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    parts.append(''.join(buf))
    return [p for p in parts if p.strip()]


def mask_single_quoted(text):
    """Blank out single-quoted spans, where `$VAR` is not an expansion.

    Shell does not expand inside `'...'`, so argv receives the literal
    characters `$GH_TOKEN` and the value never leaves the environment. This is
    the idiom for handing a secret to a helper that git spawns, and reporting it
    would flag the fix as the defect — the one false positive most likely to get
    the whole check overruled.

    Blanked to spaces rather than removed, so every offset and line number in
    the surrounding text is unchanged.
    """
    out, quote = [], None
    for i, ch in enumerate(text):
        if quote == "'":
            out.append('\n' if ch == '\n' else ' ')
            if ch == "'":
                quote = None
                out[-1] = "'"
        elif quote == '"':
            out.append(ch)
            if ch == '"' and (i == 0 or text[i - 1] != '\\'):
                quote = None
        elif ch in '"\'':
            quote = ch
            out.append(ch)
        else:
            out.append(ch)
    return ''.join(out)


def expansion(name):
    # `${NAME}`, `${NAME:-}`, `$NAME`. The trailing \b stops `$TOKEN` from
    # matching inside `$TOKENS`, which would report a different variable.
    return re.compile(r'\$\{?' + re.escape(name) + r'(?![A-Za-z0-9_])')


ASSIGN = re.compile(r'^\s*(?:export\s+|local\s+|readonly\s+)?([A-Za-z_]\w*)=(.*)$')
SUBST = re.compile(r'\$\((.*?)\)|`(.*?)`', re.S)


def classify(command, pattern):
    """Where does this command send the value? None when it does not escape."""
    command = command.strip()

    # An assignment moves the value sideways; taint propagation handles it. But
    # a command substitution inside the assignment does run a command, so the
    # value is in that command's argv — check the inner text, not the outer.
    assign = ASSIGN.match(command)
    if assign:
        inner = [m.group(1) or m.group(2) or '' for m in SUBST.finditer(assign.group(2))]
        for text in inner:
            if pattern.search(text):
                verdict = classify(text, pattern)
                if verdict:
                    return verdict
        return None

    # Redirect target built out of the value: the filename itself carries it.
    for target in re.findall(r'>>?\s*("[^"]*"|\'[^\']*\'|\S+)', command):
        if pattern.search(target):
            return 'STEP-OUTPUT' if any(s in target for s in STEP_SINKS) else 'REDIRECT'

    tokens = command.split()
    if not tokens:
        return None
    # Skip leading `VAR=value` prefixes, wrappers, and shell keywords.
    #
    # The keywords are not decoration. `if [ -z "$TOKEN" ]` splits to a command
    # whose first word is `if`, which is in neither SAFE_BUILTINS nor LOGGING —
    # so without this it fell through to ARGV and the check reported the repo's
    # own presence-check idiom as a leak. A checker that flags the correct way to
    # guard a secret gets argued with and then switched off.
    KEYWORDS = ('if', 'then', 'elif', 'else', 'while', 'until', 'do', 'done',
                'fi', '{', '}', '(', ')', '!', 'sudo', 'env', 'command', 'exec')
    while tokens and (ASSIGN.match(tokens[0]) or tokens[0] in KEYWORDS):
        if pattern.search(tokens[0]):
            break
        tokens = tokens[1:]
    if not tokens:
        return None
    cmd = os.path.basename(tokens[0].strip('"\''))

    if cmd in SAFE_BUILTINS:
        return None
    if cmd in LOGGING:
        for target in re.findall(r'>>?\s*("[^"]*"|\'[^\']*\'|\S+)', command):
            if any(s in target for s in STEP_SINKS):
                return 'STEP-OUTPUT'
            return 'REDIRECT'
        return 'ECHOED'
    return 'ARGV'


HEREDOC = re.compile(r'<<-?\s*(["\']?)([A-Za-z_]\w*)\1')


def analyse(text, creds, origin, line_offset, out):
    """Report every place a declared credential's value leaves the variable."""
    lines = text.split('\n')
    # Taint propagation to a fixpoint. Without it, `T="$SECRET"; echo "$T"` is
    # invisible — and that is a two-line edit, so a check that misses it is one
    # refactor away from useless.
    tainted = set(creds)
    for _ in range(len(tainted) + 8):
        grew = False
        for raw in lines:
            assign = ASSIGN.match(strip_comment(raw))
            if not assign:
                continue
            name, rhs = assign.group(1), assign.group(2)
            if name in tainted:
                continue
            if any(expansion(c).search(rhs) for c in tainted):
                tainted.add(name)
                grew = True
        if not grew:
            break

    patterns = {name: expansion(name) for name in tainted}
    heredoc_delim, heredoc_expands, heredoc_sink = None, False, None

    index = 0
    while index < len(lines):
        raw = lines[index]
        start = index
        lineno = line_offset + index + 1
        where = origin + ':' + str(lineno)

        if heredoc_delim is not None:
            if raw.strip() == heredoc_delim:
                heredoc_delim = None
                index += 1
                continue
            if heredoc_expands:
                for name, pattern in patterns.items():
                    if pattern.search(raw):
                        out.append((heredoc_sink or 'HEREDOC', where, name, raw.strip()))
            index += 1
            continue

        line = strip_comment(raw)

        # Join `\` continuations into one logical command.
        #
        # Not cosmetic. `security set-key-partition-list -S … \` / `  -s -k
        # "$PASSWORD" …` is two physical lines, and analysing the second one
        # alone makes `-s` look like the command being run. The real file this
        # check was written for is written exactly that way, so without this the
        # check reads a genuine argv exposure as something it has no opinion
        # about — and reports the file clean at that line.
        while line.rstrip().endswith('\\') and index + 1 < len(lines):
            index += 1
            line = line.rstrip()[:-1] + ' ' + strip_comment(lines[index])

        if not line.strip():
            index += 1
            continue

        heredoc = HEREDOC.search(line)
        if heredoc:
            heredoc_delim = heredoc.group(2)
            # A quoted delimiter (`<<'EOF'`) disables expansion, so the body is
            # literal text and cannot carry a value.
            heredoc_expands = heredoc.group(1) == ''
            heredoc_sink = 'STEP-OUTPUT' if any(s in line for s in STEP_SINKS) else None

        # An acknowledgement may sit on the line, anywhere in a joined
        # continuation, or in the contiguous comment block directly above.
        #
        # The block matters: a reason worth writing is usually longer than one
        # line, and a marker that only counts on the line immediately above
        # forces the reason to be crammed onto it or silently stops counting.
        # Scanning upward stops at the first non-comment line, so an
        # acknowledgement cannot drift onto an unrelated command.
        acknowledged = any(ACK.search(lines[n]) for n in range(start, index + 1))
        n = start - 1
        while not acknowledged and n >= 0 and lines[n].lstrip().startswith('#'):
            acknowledged = bool(ACK.search(lines[n]))
            n -= 1

        for command in split_commands(line):
            # Single-quoted spans are masked before the match: `$TOKEN` inside
            # `'...'` is literal text in argv, not the value.
            visible = mask_single_quoted(command)
            for name, pattern in patterns.items():
                if not pattern.search(visible):
                    continue
                verdict = classify(command, pattern)
                if verdict:
                    out.append(('ACK' if acknowledged else verdict, where, name, command.strip()))
        index += 1


# ---- declarations -----------------------------------------------------------
SECRET_ENV = re.compile(r'^\s*([A-Za-z_]\w*):\s*\$\{\{\s*secrets\.', re.M)
SHELL_DECL = re.compile(r'#\s*credential:\s*([A-Za-z_]\w*)')
STEP_SPLIT = re.compile(r'\n\s*-\s+(?=name:|uses:|id:|run:)')
# The final `\n?.*` matters: `STEP_SPLIT` cuts chunks so the last body line has
# no trailing newline, and a pattern requiring one silently drops it. That is
# not a hypothetical — it dropped `security set-key-partition-list … -k
# "$KEYCHAIN_PASSWORD"`, the last line of its step in this repo's own workflow,
# and the check reported the file clean at that line while flagging the
# identical call six lines above. A parser that stops early looks exactly like
# a file with nothing further wrong in it.
RUN_BLOCK = re.compile(r'^(\s*)run:\s*[|>]-?\s*\n((?:\1\s+.*\n|\s*\n)*(?:\1\s+.*)?)', re.M)


def scan_yaml(text, origin, out, problems):
    chunks = STEP_SPLIT.split(text)
    # Declarations above the first step (job-level `env:`) apply to every step.
    job_level = set(SECRET_ENV.findall(chunks[0])) if chunks else set()

    if 'secrets.' in text and len(chunks) == 1:
        problems.append('PARSE-ERROR: ' + origin + ' names secrets but no step could be parsed')
        return 0

    declared = set(job_level)
    for chunk in chunks[1:]:
        creds = job_level | set(SECRET_ENV.findall(chunk))
        declared |= creds
        if not creds:
            continue
        offset = text.index(chunk)
        base = text[:offset].count('\n')
        for block in RUN_BLOCK.finditer(chunk):
            analyse(block.group(2), creds, origin, base + chunk[:block.start(2)].count('\n'), out)
    return len(declared)


def scan_shell(text, origin, out):
    creds = set(SHELL_DECL.findall(text))
    if creds:
        analyse(text, creds, origin, 0, out)
    return len(creds)


findings, problems, declared = [], [], 0
for rel, kind in sorted(shell_files(root)):
    with open(os.path.join(root, rel), encoding='utf-8', errors='replace') as handle:
        text = handle.read()
    if kind == 'yaml':
        declared += scan_yaml(text, rel, findings, problems)
    else:
        declared += scan_shell(text, rel, findings)

for problem in problems:
    print(problem)

if declared == 0:
    # Not "clean". Nothing was found because nothing was looked for, and those
    # two produce the same silence.
    print('NO-DECLARATIONS')

seen = set()
for verdict, where, name, snippet in findings:
    key = (verdict, where, name)
    if key in seen:
        continue
    seen.add(key)
    print('\t'.join((verdict, where, name, snippet[:100])))
PY
}

# ---- --self-test: prove the check is still capable of failing ----------------
#
# A credential checker that cannot prove it goes red is worth exactly as much as
# any other scanner reporting zero: the reader cannot tell "nothing is wrong"
# from "nothing was examined". Every case below is one of the two, and the
# clean ones matter as much as the red ones — a check that fires on everything
# gets switched off, and a switched-off check is a silent one.
if [ "${1:-}" = "--self-test" ]; then
  FIXTURE="$(mktemp -d)"
  trap 'rm -rf "$FIXTURE"' EXIT
  mkdir -p "$FIXTURE/.github/workflows" "$FIXTURE/scripts"

  fail=0
  expect() { # $1 label  $2 expected verdicts (space-separated, sorted)  $3 workflow body
    printf '%s' "$3" > "$FIXTURE/.github/workflows/probe.yml"
    got="$(credential_exposures "$FIXTURE" | cut -f1 | sort | tr '\n' ' ' | sed 's/ *$//')"
    want="$(printf '%s' "$2" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ *$//')"
    if [ "$got" != "$want" ]; then
      echo "❌ self-test FAILED [$1]: expected '$want', got: '${got:-<nothing>}'"
      fail=1
    fi
  }

  # The value reaches the run log.
  expect "echoed to the log" 'ECHOED' 'jobs:
  j:
    steps:
      - name: leak
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          echo "$TOKEN"
'

  # The value reaches another process argv, where `ps` can read it.
  expect "passed in argv" 'ARGV' 'jobs:
  j:
    steps:
      - name: leak
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          curl -H "Authorization: $TOKEN" https://example.invalid
'

  # A presence check does not fork, so the value never leaves the shell. This
  # is the safe idiom the repo already uses; reporting it would make the
  # correct way to guard a secret indistinguishable from leaking one.
  expect "presence check is not an exposure" '' 'jobs:
  j:
    steps:
      - name: guard
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          if [ -z "${TOKEN:-}" ]; then echo "::error::not set"; exit 1; fi
'

  # Declared, handed to a child process through the environment, never expanded
  # in shell at all. This is the pattern to keep, and it must come back clean.
  expect "env-only hand-off is clean" '' 'jobs:
  j:
    steps:
      - name: fine
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: fastlane ios beta
'

  # **The case that pins the criterion.** A variable whose name says "token" as
  # loudly as possible, echoed straight out — and no declaration behind it, so
  # it is not this check''s business. If anyone ever rewrites the criterion to
  # match names, or bolts a shape-matching pass onto the side, this case goes
  # red and says why.
  #
  # A declared credential sits alongside it, used safely. Without one the step
  # would trip NO-DECLARATIONS and the case would pass for a reason that has
  # nothing to do with names — proving only that an empty scan is empty, which
  # is another case''s job.
  expect "undeclared variable is not a credential" '' 'jobs:
  j:
    steps:
      - name: not a secret
        env:
          REAL: ${{ secrets.REAL }}
        run: |
          if [ -z "${REAL:-}" ]; then exit 1; fi
          API_TOKEN="$(date +%s)"
          echo "$API_TOKEN"
'

  # One assignment away is still one echo away.
  expect "taint survives an assignment" 'ECHOED' 'jobs:
  j:
    steps:
      - name: laundered
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          COPY="$TOKEN"
          echo "$COPY"
'

  # Written into a file, where whatever reads that file gets it.
  expect "interpolated into a heredoc" 'HEREDOC' 'jobs:
  j:
    steps:
      - name: config
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          cat > config.ini <<EOF
          key=$TOKEN
          EOF
'

  # A quoted heredoc delimiter disables expansion, so the body is literal.
  expect "quoted heredoc does not expand" '' 'jobs:
  j:
    steps:
      - name: literal
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          cat > note.txt <<'"'"'EOF'"'"'
          $TOKEN is not expanded here
          EOF
'

  # Persisted into the step outputs, which outlive the step.
  expect "written to step output" 'STEP-OUTPUT' 'jobs:
  j:
    steps:
      - name: persist
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          echo "t=$TOKEN" >> "$GITHUB_OUTPUT"
'

  # An acknowledged exposure is reported as acknowledged — never dropped.
  expect "acknowledgement reclassifies, it does not silence" 'ACK' 'jobs:
  j:
    steps:
      - name: unavoidable
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          # credential-exposure: argv — the tool offers no stdin form
          security unlock-keychain -p "$TOKEN" login.keychain-db
'

  # A marker with no reason is not an acknowledgement. Otherwise the cheapest
  # way to clear a finding would be to paste a bare comment, which is the same
  # cheap green this check exists to refuse.
  expect "a reasonless marker does not count" 'ARGV' 'jobs:
  j:
    steps:
      - name: hand-waved
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          # credential-exposure: argv
          security unlock-keychain -p "$TOKEN" login.keychain-db
'

  expect_line() { # $1 label  $2 expected "verdict:line" $3 workflow body
    printf '%s' "$3" > "$FIXTURE/.github/workflows/probe.yml"
    got="$(credential_exposures "$FIXTURE" | awk -F'\t' 'NR==1{n=split($2,a,":"); print $1 ":" a[n]}')"
    if [ "$got" != "$2" ]; then
      echo "❌ self-test FAILED [$1]: expected '$2', got: '${got:-<nothing>}'"
      fail=1
    fi
  }

  # Two cases below pin defects this check actually shipped with, both found by
  # running it against the real workflow rather than by reasoning about it.

  # A `\` continuation is one command, not two.
  #
  # **Asserted on the reported line, not just the verdict.** Before the join,
  # this fixture also came back `ARGV` — but from line 9, having taken `-s` for
  # the command being run. Right answer, wrong reason, and a verdict-only
  # assertion cannot tell the two apart: it passed against the broken code. The
  # line number is what distinguishes "recognised the command" from "guessed".
  expect_line "backslash continuation is one command" 'ARGV:8' 'jobs:
  j:
    steps:
      - name: wrapped
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          security set-key-partition-list -S apple: \
            -s -k "$TOKEN" login.keychain-db
'

  # The last line of a step''s `run:` block has no trailing newline once the
  # step splitter has cut it. A body pattern that requires one drops that line
  # — which is precisely how this check first reported the repo''s own
  # `set-key-partition-list` call as clean while flagging the identical call
  # six lines above it. The exposure must be on the final line here, or the
  # case does not exercise the bug.
  expect "an exposure on the final line is not dropped" 'ARGV' 'jobs:
  j:
    steps:
      - name: last line
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          echo starting
          security unlock-keychain -p "$TOKEN" login.keychain-db'

  # A `$VAR` inside single quotes is literal text, not an expansion. Argv gets
  # the characters `$TOKEN`; the value is substituted only in the helper shell
  # git spawns, which reads it from the environment. Flagging this would report
  # the recommended fix as the defect.
  expect "single-quoted \$VAR is literal, not an expansion" '' 'jobs:
  j:
    steps:
      - name: helper
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          git -c '"'"'credential.helper=!f() { echo "password=$TOKEN"; }; f'"'"' push
'

  # …but the same text in double quotes really is expanded, so the mask must be
  # quote-aware rather than a blanket "ignore anything in quotes". Without this
  # pair, the case above could be satisfied by silencing every quoted string.
  expect "double-quoted \$VAR is still an expansion" 'ARGV' 'jobs:
  j:
    steps:
      - name: real
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          curl -H "Authorization: $TOKEN" https://example.invalid
'

  # An acknowledgement''s reason is usually longer than one line. Counting only
  # the line immediately above forces it onto one line or quietly stops
  # counting — and a marker that stops counting turns an acknowledged exposure
  # back into a hard failure for no stated reason.
  expect "acknowledgement may sit in a multi-line comment block" 'ACK' 'jobs:
  j:
    steps:
      - name: explained at length
        env:
          TOKEN: ${{ secrets.TOKEN }}
        run: |
          # credential-exposure: argv — the tool reads the password from argv
          # and offers no stdin form, so this is the least-bad available shape
          # and the runner is a dedicated machine.
          security unlock-keychain -p "$TOKEN" login.keychain-db
'

  # Nothing declared anywhere: the scan is vacuous, and must say so rather than
  # report a clean tree. This is the failure that every other case assumes away.
  expect "an empty scan is not a clean scan" 'NO-DECLARATIONS' 'jobs:
  j:
    steps:
      - name: nothing here
        run: echo hello
'

  if [ "$fail" -eq 0 ]; then
    echo "✅ self-test: the credential check still detects logged, argv-passed,"
    echo "   redirected, heredoc-interpolated and step-output credentials; still"
    echo "   follows a value through an assignment; still refuses a reasonless"
    echo "   acknowledgement; still calls an empty scan empty; and still passes"
    echo "   a presence check, an env-only hand-off and an undeclared variable."
    exit 0
  fi
  echo "   The check can no longer be trusted, so its green result means nothing."
  exit 1
fi

# ---- the real run -----------------------------------------------------------
RESULT="$(credential_exposures "$REPO")"

if echo "$RESULT" | grep -q '^PARSE-ERROR:'; then
  echo "$RESULT" | grep '^PARSE-ERROR:' | sed 's/^/❌ /'
  echo "   A file that names secrets and parses to nothing would make this check"
  echo "   pass forever. Fix the parse before trusting any other line here."
  exit 1
fi

if echo "$RESULT" | grep -q '^NO-DECLARATIONS$'; then
  echo "❌ credentials: nothing in this repo declares itself a credential."
  echo
  echo "   That is not a clean result — it is an empty one. A workflow env entry"
  echo "   reading \${{ secrets.NAME }} declares itself; a value from elsewhere"
  echo "   needs \`# credential: NAME\` next to it. With neither, this check looks"
  echo "   for nothing and finds nothing, and prints the same silence it would"
  echo "   print if everything were fine."
  exit 1
fi

ACKED="$(echo "$RESULT" | grep '^ACK' || true)"
PROBLEMS="$(echo "$RESULT" | grep -v '^ACK' | grep -v '^$' || true)"

if [ -n "$ACKED" ]; then
  # Printed on clean runs too. An exposure that stops being mentioned is one
  # nobody revisits, and "acknowledged" is a record of a decision, not a fix.
  echo "ℹ️  credentials: acknowledged exposures (still exposures):"
  echo "$ACKED" | while IFS=$'\t' read -r _ where name snippet; do
    echo "     - $name at $where — $snippet"
  done
  echo
fi

if [ -z "$PROBLEMS" ]; then
  echo "✅ credentials: no declared credential reaches a log, a file, an argv or a step output."
  exit 0
fi

echo "❌ credentials: a declared credential's value leaves the variable:"
echo "$PROBLEMS" | while IFS=$'\t' read -r verdict where name snippet; do
  case "$verdict" in
    ECHOED)      reason="written to stdout — it lands in the run log" ;;
    STEP-OUTPUT) reason="written to a step output/env — it outlives this step" ;;
    REDIRECT)    reason="written into a file — whoever reads that file gets it" ;;
    HEREDOC)     reason="interpolated into a heredoc body written out verbatim" ;;
    ARGV)        reason="passed in argv — any process of the same user can read it via ps" ;;
    *)           reason="$verdict" ;;
  esac
  echo "     - $name at $where"
  echo "       $reason"
  echo "       $snippet"
done
echo
echo "   Pass it through the environment to the process that needs it, or feed"
echo "   it on stdin. If the tool genuinely offers no other form, say so on the"
echo "   line and it becomes a recorded decision rather than an oversight:"
echo
echo "     # credential-exposure: argv — <why this is the least-bad form>"
echo
echo "   A marker without a reason does not count."
exit 1

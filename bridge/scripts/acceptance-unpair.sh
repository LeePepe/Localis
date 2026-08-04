#!/bin/bash
# End-to-end acceptance for `localis-bridge unpair`, over real TLS with curl.
#
# Deliberately does NOT touch ~/.localis: LOCALIS_BRIDGE_HOME redirects the
# bridge's whole config directory. core is running a bridge against the live one
# and this script issues and revokes grants — without the override it would
# revoke a device a teammate is using.
#
# The red-green shape is the point. Asserting only "revoked token is rejected"
# proves nothing: a token can be rejected for a dozen reasons. So the same token
# is asserted to WORK first (step 3), and only then revoked.
set -u

BRIDGE="$1"
HOME_DIR=$(mktemp -d /tmp/localis-unpair-acceptance.XXXXXX)
PORT=18765
LOG=""
FAILURES=0

cleanup() {
    [ -n "${BRIDGE_PID:-}" ] && kill "$BRIDGE_PID" 2>/dev/null
    wait "$BRIDGE_PID" 2>/dev/null
    # Deleting the home directory belongs here, not at the end of the happy
    # path. grants.json holds the pairing token in plaintext (TokenStore's
    # Entry.token is a String), and this script has two early exits — the
    # bridge failing to start, and pairing failing — each of which used to
    # leave that file behind in /tmp. A credential surviving the process that
    # created it is the failure Constitution I exists to prevent, and it was
    # reachable on exactly the paths where something had already gone wrong.
    [ -n "${HOME_DIR:-}" ] && rm -rf "$HOME_DIR"
}
trap cleanup EXIT

check() { # description, expected, actual
    if [ "$2" = "$3" ]; then
        echo "  PASS  $1 (= $3)"
    else
        echo "  FAIL  $1: expected '$2', got '$3'"
        FAILURES=$((FAILURES + 1))
    fi
}

start_bridge() {
    # A fresh log per start. Appending to one log and grepping it for "pairing
    # code" reports the *previous* run's line, so the readiness check passes
    # before the restarted bridge is listening — the curl that follows then
    # fails to connect and reads as "the bridge rejected me". Caught exactly
    # that way: step 6 returned HTTP 000 while step 7 got a clean 401.
    LOG="$HOME_DIR/bridge-$(date +%s%N).log"
    LOCALIS_BRIDGE_HOME="$HOME_DIR" LOCALIS_BRIDGE_PORT="$PORT" "$BRIDGE" >>"$LOG" 2>&1 &
    BRIDGE_PID=$!
    for _ in $(seq 1 50); do
        # Both conditions: the banner is printed before the socket is
        # necessarily reachable from another process, so the port is probed too.
        if grep -q "pairing code" "$LOG" \
           && curl -sk -o /dev/null --max-time 2 "https://127.0.0.1:$PORT/v1/models"; then
            return 0
        fi
        sleep 0.2
    done
    echo "FATAL: bridge did not start"; exit 1
}

# `code` and `error.code` off a response, without trusting field order.
json_field() { python3 -c "
import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split('.'):
    d = d.get(k, {}) if isinstance(d, dict) else {}
print(d if isinstance(d,str) else '')
" "$1"; }

echo "=== 1. start bridge (isolated config dir) ==="
start_bridge
CODE=$(grep "pairing code" "$LOG" | awk '{print $3}')
echo "  bridge up on $PORT, pairing code obtained"

echo
echo "=== 2. pair, obtain a real token ==="
PAIR=$(curl -sk -X POST "https://127.0.0.1:$PORT/localis/v1/pair" \
    -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\",\"device_name\":\"Acceptance Phone\",\"device_id\":\"dev-acceptance\"}")
TOKEN=$(printf '%s' "$PAIR" | json_field token)
if [ -z "$TOKEN" ]; then echo "FATAL: pairing failed: $PAIR"; exit 1; fi
echo "  paired, token obtained (not printed)"

echo
echo "=== 3. RED CONTROL: the token must work BEFORE revocation ==="
echo "        (without this, step 6's 401 would prove nothing)"
STATUS=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/v1/models" \
    -H "Authorization: Bearer $TOKEN")
check "same token before revoke -> 200" "200" "$STATUS"

echo
echo "=== 4. revoke via the CLI subcommand ==="
LOCALIS_BRIDGE_HOME="$HOME_DIR" "$BRIDGE" unpair dev-acceptance
UNPAIR_EXIT=$?
check "unpair exit code" "0" "$UNPAIR_EXIT"

echo
echo "=== 5. the running bridge still honours it (stated, not hidden) ==="
STATUS=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/v1/models" \
    -H "Authorization: Bearer $TOKEN")
echo "  running bridge answers $STATUS — in-memory grants are stale until restart."
echo "  This is what the command's own output warns about."

echo
echo "=== 6. restart, then the same token must be 401 token_revoked ==="
cleanup
start_bridge
BODY=$(curl -sk -w '\n%{http_code}' "https://127.0.0.1:$PORT/v1/models" -H "Authorization: Bearer $TOKEN")
STATUS=$(printf '%s' "$BODY" | tail -1)
ERRCODE=$(printf '%s' "$BODY" | sed '$d' | json_field error.code)
check "revoked token -> 401" "401" "$STATUS"
check "revoked token -> error.code" "token_revoked" "$ERRCODE"

echo
echo "=== 7. an UNKNOWN token must still be invalid_token, not token_revoked ==="
echo "        (the constraint iOS cannot verify: both are 401 and look identical)"
BODY=$(curl -sk -w '\n%{http_code}' "https://127.0.0.1:$PORT/v1/models" \
    -H "Authorization: Bearer tok-never-issued-by-anyone")
STATUS=$(printf '%s' "$BODY" | tail -1)
ERRCODE=$(printf '%s' "$BODY" | sed '$d' | json_field error.code)
check "unknown token -> 401" "401" "$STATUS"
check "unknown token -> error.code" "invalid_token" "$ERRCODE"

echo
echo "=== 8. the revoked token is not on disk in the clear ==="
if grep -qF "$TOKEN" "$HOME_DIR/grants.json"; then
    echo "  FAIL  revoked token found verbatim in grants.json"
    FAILURES=$((FAILURES + 1))
else
    echo "  PASS  revoked token absent from grants.json"
fi

echo
echo "=== 9. unpairing an id that does not exist fails loudly ==="
LOCALIS_BRIDGE_HOME="$HOME_DIR" "$BRIDGE" unpair dev-does-not-exist >/dev/null 2>&1
check "unknown device id -> non-zero exit" "1" "$?"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
else
    echo "$FAILURES CHECK(S) FAILED"
fi
# No rm here — cleanup() runs on EXIT and covers this path along with the two
# early exits. Deleting in both places would work, but it would suggest the
# happy path is where cleanup happens, which is the assumption that let the
# plaintext token survive the failing paths in the first place.
exit "$FAILURES"

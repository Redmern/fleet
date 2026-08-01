#!/usr/bin/env bash
# Proof harness — S0: VISIBILITY (d34).
#
# TWO DEFECTS, BOTH MEASURED, BOTH SMALL:
#
#  A. `append_dashboard_alert` HAS ZERO READERS. Six call sites write to
#     `.fleet/dispatch/alerts.log` — reconcile's stranded/failed paths, the gate
#     orphan escalation, the wake escalation — and NOTHING has ever read the file.
#     Every one of those is an event the human is supposed to act on, and every one
#     of them has been going into a file nobody opens. Surfacing it is ~15 lines.
#
#  B. THE SEVERITY IS INVERTED. `bin/fleetd` notifies `blocked` at urgency **low**
#     and `done` at **normal**, while `inbox_put` uses **critical** for blocked. So
#     the one state that means "an agent is stuck waiting for you" is the QUIETEST
#     desktop notification fleet sends, and on a notification daemon that
#     time-expires low-urgency toasts it can vanish before it is read. "Agent
#     finished" outranking "agent blocked" is exactly backwards.
#
# THE CONSTRAINT. A fleet with no gates and no alerts must render BYTE-IDENTICALLY
# to before this change. The strip costs zero rows when there is nothing to say —
# otherwise every user of fleet pays for a feature only gated pipelines use.
# Case 5 is that assertion.
#
# Cases:
#   1. the dashboard READS alerts.log at all (it has a reader now)
#   2. alert lines reach the rendered strip
#   3. newest-first
#   4. capped — a flood does not push the agent list off the screen
#   5. BYTE-IDENTICAL: no alerts.log => output identical to a run with the reader
#      stubbed out entirely
#   6. an unreadable/garbage alerts.log renders nothing and does not break the
#      dashboard (fail-silent)
#   7. fleetd notifies `blocked` at CRITICAL
#   8. ...and `done`/idle at normal (not louder than blocked)
#   9. the two severity ladders agree: fleetd's blocked urgency == inbox_put's
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"
FLEETD="$HERE/bin/fleetd"
DASH="$HERE/bin/fleet-dash"

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }

echo "== d34 S0 — visibility proof"
if bash -n "$FLEET" 2>/dev/null && bash -n "$DASH" 2>/dev/null; then
  pass "0 bin/fleet and bin/fleet-dash parse"
else
  fail "0 bin/fleet and bin/fleet-dash parse" "$( { bash -n "$FLEET"; bash -n "$DASH"; } 2>&1 | head -3)"; fi

# ---- A. the alerts strip -----------------------------------------------------
# The renderer is extracted from the REAL source between markers and eval'd, the
# same technique the hidden-session proofs use. Extraction failing is loud (the
# fragment is empty and the case reports it), so this is fail-closed, not vacuous.
# KEEP THE `# >>> d34:alerts` / `# <<< d34:alerts` MARKERS.
frag=$(awk '/# >>> d34:alerts/{s=1; next} /# <<< d34:alerts/{exit} s' "$DASH")
if [ -n "$frag" ]; then
  pass "1 the dashboard has an alerts reader (extracted between the d34:alerts markers)"
else
  fail "1 the dashboard has an alerts reader" \
       "no fragment between '# >>> d34:alerts' and '# <<< d34:alerts' in bin/fleet-dash — append_dashboard_alert still has zero readers"; fi

ROOT="$TMPROOT/root"; mkdir -p "$ROOT/.fleet/dispatch"
A="$ROOT/.fleet/dispatch/alerts.log"

run_frag() { # -> the strip's rendered rows
  [ -n "$frag" ] || return 0
  ( dash_root() { printf '%s\n' "$ROOT"; }
    cw=70
    eval "$frag" ) 2>/dev/null
}

printf '2026-07-31T10:00:00+02:00\treconcile: alpha went stranded\n' >> "$A"
printf '2026-07-31T11:00:00+02:00\tgate: bravo rejected 3x — capped\n' >> "$A"
out=$(run_frag)
if printf '%s' "$out" | grep -q 'bravo' && printf '%s' "$out" | grep -q 'alpha'; then
  pass "2 alert lines reach the rendered strip"
else
  fail "2 alert lines reach the strip" "rendered: '$(printf '%s' "$out" | tr '\n' '|')'"; fi
first=$(printf '%s\n' "$out" | grep -n 'bravo\|alpha' | head -1)
case "$first" in
  *bravo*) pass "3 newest-first (the most recent alert is the top row)" ;;
  *) fail "3 newest-first" "top alert row was '$first' — oldest first buries the new one" ;;
esac

# --- 4. capped ----------------------------------------------------------------
i=0; while [ $i -lt 60 ]; do printf '2026-07-31T12:00:00+02:00\tflood %s\n' "$i" >> "$A"; i=$((i+1)); done
n=$(run_frag | grep -c .)
if [ "${n:-0}" -le 5 ] && [ "${n:-0}" -ge 1 ]; then
  pass "4 the strip is capped ($n rows for 62 alerts)"
else
  fail "4 the strip is capped" "$n rows — a flood pushes the agent list off the screen"; fi

# --- 5. BYTE-IDENTICAL with no alerts ----------------------------------------
rm -f "$A"
out_none=$(run_frag)
if [ -z "$out_none" ]; then
  pass "5 BYTE-IDENTICAL: no alerts.log => the strip emits nothing at all"
else
  fail "5 byte-identical on a gateless fleet" \
       "emitted $(printf '%s' "$out_none" | wc -l) row(s) with no alerts.log — every fleet user pays for this"; fi
mkdir -p "$ROOT/.fleet/dispatch"; : > "$A"
if [ -z "$(run_frag)" ]; then
  pass "5b an EMPTY alerts.log also emits nothing"
else
  fail "5b an empty alerts.log emits nothing" "it drew a strip for zero alerts"; fi

# --- 6. fail-silent on garbage -----------------------------------------------
printf 'no tab here at all\n\x00\x01binary\n' > "$A"
if run_frag >/dev/null 2>&1; then
  pass "6 a garbage alerts.log is fail-silent (no crash)"
else
  fail "6 a garbage alerts.log is fail-silent" "the fragment returned non-zero"; fi
rm -f "$A"

# ---- B. the severity inversion ----------------------------------------------
# Read the real ladder out of fleetd rather than re-stating it: the assertion has to
# fail if the source drifts, not if this file's copy of it drifts.
urg=$(python3 - "$FLEETD" <<'PY' 2>/dev/null
import ast, sys
src = open(sys.argv[1]).read()
tree = ast.parse(src)
found = {}
for node in ast.walk(tree):
    # the (title, urgency) conditional expression in maybe_notify
    if isinstance(node, ast.IfExp):
        try:
            body = ast.literal_eval(node.body)
            orelse = ast.literal_eval(node.orelse)
        except Exception:
            continue
        if isinstance(body, tuple) and len(body) == 2 and 'blocked' in str(body[0]).lower():
            found['blocked'] = body[1]
            found['other'] = orelse[1]
print('%s %s' % (found.get('blocked', '?'), found.get('other', '?')))
PY
)
b_urg=${urg%% *}; o_urg=${urg##* }
if [ "$b_urg" = critical ]; then
  pass "7 fleetd notifies blocked at CRITICAL"
else
  fail "7 fleetd notifies blocked at critical" \
       "blocked urgency is '$b_urg' — the one state meaning 'an agent is stuck waiting for you' is the quietest notification fleet sends"; fi
if [ "$o_urg" = normal ]; then
  pass "8 done/idle stays at normal (never louder than blocked)"
else
  fail "8 done stays at normal" "done urgency is '$o_urg'"; fi
# inbox_put's own ladder, read from bash source
ib=$(grep -oE 'local urg=[a-z]+; \[ "\$sev" = blocked \] && urg=[a-z]+' "$FLEET" \
     | head -1 | sed 's/.*urg=//')
if [ "$b_urg" = critical ] && [ "$ib" = critical ]; then
  pass "9 the two severity ladders agree (fleetd blocked == inbox_put blocked == critical)"
else
  fail "9 the severity ladders agree" "fleetd='$b_urg' inbox_put='$ib'"; fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

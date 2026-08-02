#!/usr/bin/env bash
# Proof harness — S1: the DECISION OBJECT and the reject verb (d34).
#
# THE GAP. There is no reject verb anywhere in fleet. `cmd_gate` is
# `parse|post|park|waiting|popped` — and `popped` is an AUDIT STAMP, not a decision
# (its own comment says so). The only way to approve is for a human to POP a message
# into a pane, and the only way to reject is to type prose at a model. So:
#   * a decision is not an object — it exists only as tmux scrollback;
#   * "rejected" has no representation at all, therefore no routing, no attempt
#     counter, and no cap;
#   * nothing distinguishes "approved" from "approved with amendments" from
#     "the human typed something that happened to contain the sentinel".
#
# WHAT IS UNDER TEST. `fleet gate approve|reject|show|list` writes the decision to
# the ledger and synthesizes `<dispatch-dir>/decision-<N>.txt` in the EXISTING
# sentinel grammar, so `gate_parse` stays the sole advance oracle and needs no change.
#
# TWO PROPERTIES THAT MUST NOT SLIP, both encoded below as their own cases:
#
#   A. APPROVE DOES NOT UN-PARK. Un-parking is the courier's (S2), on CONFIRMED
#      landing. A decision that un-parks on write would drop the reap guard and the
#      reconcile exemption while the sub-orch has not yet heard anything — the exact
#      shape of the gate-park bug (a parked dispatch read as stranded, respawned, and
#      run straight PAST the gate).
#   B. SENTINEL PLACEMENT IS NOT WIDENED. `gate_parse` reads line 1, or line 2 ONLY
#      behind a real `From ` pop header. That offset is a CONSEQUENCE of the pop
#      header, never a free two-line allowance: `fleet inbox put` has no role check,
#      so any pane can enqueue a body, and a bare bound of N hands a forger N-1 lines
#      of camouflage lead-in. The decision file is therefore a BARE body, line 1.
#
# Cases:
#   1.  approve writes decision/decision_gate/decided_at/decided_by to the ledger
#   2.  approve synthesizes decision-1.txt
#   3.  ...whose line 1 is the approve sentinel, byte-identical to gate_post's
#   4.  ...which the shared oracle parses (no private grammar)
#   5.  APPROVE DOES NOT UN-PARK — state is still gate1-wait
#   6.  ...and `gate waiting` therefore still lists it (reap guard intact)
#   7.  approve is idempotent — re-approving is rc 0 and changes nothing
#   8.  reject REFUSES with no reason (rc 2), and writes NOTHING
#   9.  reject -m "" (explicitly empty) also refuses
#   10. reject with a reason writes decision=reject + the reason as a FILE
#   11. ...and decision-1.txt carries action=revise attempt=2
#   12. reject also does not un-park
#   13. an unresolvable target DIES (rc != 0, stderr) — the deliberate
#       non-fail-silent exception
#   14. `gate show` prints the pending question for the resolved dispatch
#   15. `gate list` lists parked dispatches with their gate
#   16. SENTINEL PLACEMENT: decision-1.txt parses from line 1 (bare body)
#   17. NEGATIVE: the same sentinel on line 2 with NO `From ` header does NOT parse
#   18. NEGATIVE: the same sentinel on line 3 behind a real header does NOT parse
#   19. CONTROL: the `From `-header form still parses from line 2
#   20. WIDENING REGRESSION: gate_parse still reads exactly 2 lines
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

TMPROOT=$(mktemp -d)
# Socket isolation is INTRINSIC, never inherited. Ambient `export TMUX_TMPDIR` is
# NOT enough on its own: any step running in a shell that did not inherit it falls
# back to /tmp/tmux-$(id -u)/default — the REAL server — and then a bare
# `tmux kill-server` in cleanup() tears down the live fleet. So resolve the socket
# HERE, assert it lives under TMPROOT, and inject it with -S on every tmux call via
# the wrapper below. TMUX_TMPDIR is still exported, but only so CHILD processes
# ($FLEET -> tmux) reach the SAME private server; correctness no longer rests on it.
export TMUX_TMPDIR="$TMPROOT/tmuxsock"
mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
# FLEET_HARNESS_SOCK exists ONLY so the guard below can be proven to fire; it is
# itself guarded, so it can never be used to escape to the real socket.
SOCK="${FLEET_HARNESS_SOCK:-$TMUX_TMPDIR/tmux-$(id -u)/default}"

# --- fail-fast guard: runs BEFORE any tmux call -------------------------------
if [ "$SOCK" = "/tmp/tmux-$(id -u)/default" ]; then
  echo "REFUSE: harness resolved to the real tmux socket ($SOCK)" >&2
  rm -rf "$TMPROOT"; exit 1
fi
case "$SOCK" in
  "$TMPROOT"/*) ;;
  *) echo "REFUSE: harness socket is not under TMPROOT ($SOCK not under $TMPROOT)" >&2
     rm -rf "$TMPROOT"; exit 1 ;;
esac

# Every tmux call in THIS FILE routes through here — defined in the same file as the
# calls, so -S can be neither forgotten nor lost across a subshell. `command tmux`
# avoids recursing into this function.
tmux() { command tmux -S "$SOCK" "$@"; }
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FLEET_SESSION="gd_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"

cleanup() { command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

echo "== d34 S1 — gate decision object + reject proof"

if bash -n "$FLEET" 2>/dev/null; then pass "0 bin/fleet parses"; else
  fail "0 bin/fleet parses" "$(bash -n "$FLEET" 2>&1 | head -3)"; fi

D="$FLEET_ROOT/.fleet/dispatch/d1"; mkdir -p "$D"
tmux new-session -d -s "$FLEET_SESSION" -n "so-d1" 'sleep 9999' 2>/dev/null
sleep 0.3
WID=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk '$2=="so-d1"{print $1; exit}')
printf 'window_id\t%s\n' "$WID" >> "$D/meta.tsv"
"$FLEET" dispatch rename d1 "Login Fix" >/dev/null 2>&1
SLUG=$("$FLEET" slug "Login Fix" 2>/dev/null)
"$FLEET" gate post 1 --slug "$SLUG" --summary "the plan" -d d1 >/dev/null 2>&1
"$FLEET" gate park d1 1 >/dev/null 2>&1

# --- 1..4. approve ------------------------------------------------------------
"$FLEET" gate approve d1 >/dev/null 2>&1; arc=$?
if [ "$(mget "$D" decision)" = approve ] && [ "$(mget "$D" decision_gate)" = 1 ] \
   && [ -n "$(mget "$D" decided_at)" ] && [ -n "$(mget "$D" decided_by)" ]; then
  pass "1 approve writes the decision object to the ledger"
else
  fail "1 approve writes the decision object to the ledger" \
       "rc=$arc decision='$(mget "$D" decision)' gate='$(mget "$D" decision_gate)' at='$(mget "$D" decided_at)' by='$(mget "$D" decided_by)'"; fi
if [ -f "$D/decision-1.txt" ]; then pass "2 approve synthesizes decision-1.txt"; else
  fail "2 approve synthesizes decision-1.txt" "no such file"; fi
want="[FLEET-GATE:1 slug=$SLUG action=implement]"
got=$(sed -n 1p "$D/decision-1.txt" 2>/dev/null)
if [ "$got" = "$want" ]; then
  pass "3 line 1 is byte-identical to gate_post's approve sentinel"
else
  fail "3 line 1 is byte-identical to gate_post's approve sentinel" "got '$got' want '$want'"; fi
if "$FLEET" gate parse "$D/decision-1.txt" >/dev/null 2>&1; then
  pass "4 the shared oracle parses the decision file"
else
  fail "4 the shared oracle parses the decision file" "gate_parse rc 1 on our own artifact"; fi

# --- 5/6. approve DOES NOT un-park -------------------------------------------
st=$(mget "$D" state)
if [ "$st" = "gate1-wait" ]; then
  pass "5 approve does NOT un-park (still gate1-wait — un-parking is the courier's)"
else
  fail "5 approve does NOT un-park" "state is '$st'; un-parking on write drops the reap guard and the reconcile exemption before the sub-orch has heard anything"; fi
if "$FLEET" gate waiting 2>/dev/null | grep -q .; then
  pass "6 gate waiting still lists it (reap guard intact)"
else
  fail "6 gate waiting still lists it" "the reap guard dropped at decision time"; fi

# --- 7. idempotent ------------------------------------------------------------
sum1=$(cat "$D/meta.tsv" "$D/decision-1.txt" 2>/dev/null | md5sum)
"$FLEET" gate approve d1 >/dev/null 2>&1; rc2=$?
sum2=$(cat "$D/meta.tsv" "$D/decision-1.txt" 2>/dev/null | md5sum)
if [ "$rc2" = 0 ] && [ "$sum1" = "$sum2" ]; then
  pass "7 re-approving a decided gate is rc 0 and changes nothing"
else
  fail "7 re-approving is an idempotent no-op" "rc=$rc2 changed=$([ "$sum1" = "$sum2" ] && echo no || echo yes)"; fi

# --- 8/9. reject REFUSES without a reason ------------------------------------
E="$FLEET_ROOT/.fleet/dispatch/d2"; mkdir -p "$E"
"$FLEET" dispatch rename d2 "Other Thing" >/dev/null 2>&1
SLUG2=$("$FLEET" slug "Other Thing" 2>/dev/null)
"$FLEET" gate post 1 --slug "$SLUG2" --summary "plan 2" -d d2 >/dev/null 2>&1
"$FLEET" gate park d2 1 >/dev/null 2>&1
out=$("$FLEET" gate reject d2 </dev/null 2>&1); rc=$?
if [ "$rc" = 2 ] && [ -z "$(mget "$E" decision)" ] && [ ! -f "$E/decision-1.txt" ]; then
  pass "8 reject with no reason exits 2 and writes nothing"
else
  fail "8 reject with no reason exits 2 and writes nothing" \
       "rc=$rc decision='$(mget "$E" decision)' file=$([ -f "$E/decision-1.txt" ] && echo present || echo absent) out='$(echo "$out" | head -2)'"; fi
out=$("$FLEET" gate reject d2 -m "" </dev/null 2>&1); rc=$?
if [ "$rc" = 2 ] && [ -z "$(mget "$E" decision)" ]; then
  pass "9 reject -m '' (explicitly empty) also refuses — reject is never reasonless"
else
  fail "9 reject -m '' also refuses" "rc=$rc decision='$(mget "$E" decision)'"; fi

# --- 10/11/12. reject with a reason ------------------------------------------
"$FLEET" gate reject d2 -m "drop the retry loop" >/dev/null 2>&1; rc=$?
if [ "$(mget "$E" decision)" = reject ]; then
  pass "10 reject with a reason writes decision=reject"
else
  fail "10 reject with a reason writes decision=reject" "rc=$rc decision='$(mget "$E" decision)'"; fi
rf=$(ls -1 "$E"/reason-*.txt 2>/dev/null | head -1)
if [ -n "$rf" ] && grep -q 'drop the retry loop' "$rf"; then
  pass "10b the reason lands as a FILE in the dispatch dir (the viewer is rooted there)"
else
  fail "10b the reason lands as a file in the dispatch dir" "no reason-*.txt with the text"; fi
l1=$(sed -n 1p "$E/decision-1.txt" 2>/dev/null)
case "$l1" in
  *"action=revise"*"attempt=2"*) pass "11 decision-1.txt carries action=revise attempt=2" ;;
  *) fail "11 decision-1.txt carries action=revise attempt=2" "line 1 = '$l1'" ;;
esac
if [ "$(mget "$E" state)" = "gate1-wait" ]; then
  pass "12 reject does NOT un-park either"
else
  fail "12 reject does NOT un-park" "state is '$(mget "$E" state)'"; fi

# --- 13. unresolvable target DIES --------------------------------------------
# The ONE deliberate non-fail-silent addition: everywhere else in fleet doubt means
# allow/skip. Here a silent no-op is a human believing they approved something.
out=$("$FLEET" gate approve d999 2>&1); rc=$?
if [ "$rc" != 0 ] && [ -n "$out" ]; then
  pass "13 an unresolvable target dies loudly (rc=$rc)"
else
  fail "13 an unresolvable target dies loudly" "rc=$rc out='$out' — a silent no-op is a human who believes they approved"; fi

# --- 14/15. show / list -------------------------------------------------------
out=$("$FLEET" gate show d1 2>&1)
if printf '%s' "$out" | grep -q 'FLEET-GATE:1'; then
  pass "14 gate show prints the question for the resolved dispatch"
else
  fail "14 gate show prints the question" "out='$(echo "$out" | head -3)'"; fi
out=$("$FLEET" gate list 2>&1)
if printf '%s' "$out" | grep -q 'd1' && printf '%s' "$out" | grep -q 'd2'; then
  pass "15 gate list lists the parked dispatches"
else
  fail "15 gate list lists the parked dispatches" "out='$(echo "$out" | head -5)'"; fi

# --- 16..20. sentinel placement, NOT widened ---------------------------------
S="$TMPROOT/s"
if "$FLEET" gate parse "$D/decision-1.txt" >/dev/null 2>&1; then
  pass "16 the decision file is a BARE body and parses from line 1"
else
  fail "16 the decision file parses from line 1" "rc 1"; fi
printf 'some lead-in text\n%s\n' "$want" > "$S"
if "$FLEET" gate parse "$S" >/dev/null 2>&1; then
  fail "17 sentinel on line 2 WITHOUT a From header must not parse" \
       "it parsed — that is a forger's free camouflage line (inbox put has no role check)"
else
  pass "17 sentinel on line 2 without a From header does not parse"; fi
printf 'From so-d1: GATE 1\n\n%s\n' "$want" > "$S"
if "$FLEET" gate parse "$S" >/dev/null 2>&1; then
  fail "18 sentinel on line 3 must not parse" "it parsed — the 2-line bound was widened"
else
  pass "18 sentinel on line 3 does not parse (bound not widened)"; fi
printf 'From so-d1: GATE 1\n%s\n' "$want" > "$S"
if "$FLEET" gate parse "$S" >/dev/null 2>&1; then
  pass "19 CONTROL: the From-header pop form still parses from line 2"
else
  fail "19 CONTROL: the From-header pop form still parses from line 2" \
       "rc 1 — this is the shape inbox_pop_text actually produces"; fi
# The bound is structural (a `sed -n '1,2p'` head read), not a tunable constant.
if grep -q "sed -n '1,2p'" "$FLEET"; then
  pass "20 gate_parse still reads exactly 2 lines (widening regression)"
else
  fail "20 gate_parse still reads exactly 2 lines" \
       "the head read changed shape — re-verify the anchoring rationale before accepting"; fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

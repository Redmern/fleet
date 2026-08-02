#!/usr/bin/env bash
# Proof harness — S4: GATE 3, implement -> commit (d34).
#
# WHAT GATE 3 IS AND IS NOT. It does NOT invent a commit step: d31 already made
# committing a human duty (workers `git add -A` and stop). What it does is promote
# that duty from an ordinary stretch of pipeline into a PARKED GATE. Today the
# gate-2 zero-commit refusal IS this decision point — it tells the human to review
# the staged diff and commit, and escalates a sev=blocked message — but it marks
# NOTHING in the ledger, so reconcile treats the dispatch as ordinary (dead pane =>
# stranded => respawn) and reap treats the worktree as ordinary. The human owes a
# commit and the machinery does not know it.
#
# WHY THE NUMBER 3 FOR THE CHRONOLOGICALLY-SECOND GATE. Renumbering would change
# the GATE 1 / GATE 2 sentinel strings that already shipped, and those exact bytes
# are pinned by test/gate-unpark-pointer-proof.sh and read by every live ledger. A
# confusing ordinal is cheaper than migrating all of them. Case 7 pins that the
# older two strings are untouched.
#
# THE SINGLE CLASSIFICATION SITE. `gate3-wait` is APPENDED to `ledger_parked` — the
# one predicate all three consumers share. Their divergence WAS the gate-park bug:
# reap treated gate<N>-wait as parked-leave-alone while reconcile read it as
# stranded, respawned the sub-orch, and it ran straight PAST the human gate.
#
# Cases:
#   1. `gate post 3 --park` parks the ledger at gate3-wait
#   2. gate3-wait is PARKED: `gate waiting` lists it (=> reap refuses it)
#   3. reconcile SKIPS a gate3-wait dispatch (never revives it past the gate)
#   4. a gate3-wait dispatch whose sub-orch pane is DEAD is escalated, not dropped
#   5. NEGATIVE CONTROL: an unknown state is NOT parked (the predicate did not
#      become "anything ending in -wait")
#   6. NEGATIVE CONTROL: gate3-wait is not TERMINAL (parked != terminal != stranded)
#   7. the GATE 1 and GATE 2 sentinel strings are byte-identical to before
#   8. the gate-3 body points at the staged diff and says agents do not commit
#   9. `gate park <id> 3` is accepted; `gate park <id> 4` is still refused
#  10. the gate-2 zero-commit path PROMOTES to a parked gate 3 rather than merely
#      refusing into the void
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
export FLEET_SESSION="g3_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"
cleanup() { command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

# The classification predicates are pure functions of a string, so exercise them
# DIRECTLY out of the real source rather than through a mock. sed-extract by
# function name — the same technique test/reconcile_sweep.sh uses, and the reason
# those functions must keep their names.
parked_says() { # <state> -> rc 0 if ledger_parked says parked
  bash -c "$(sed -n '/^ledger_parked()/p' "$FLEET"); ledger_parked '$1'"
}
terminal_says() { # <state> -> rc 0 if ledger_terminal says terminal
  bash -c "$(sed -n '/^ledger_terminal()/p' "$FLEET"); ledger_terminal '$1'"
}

echo "== d34 S4 — GATE 3 (implement -> commit) state proof"
if bash -n "$FLEET" 2>/dev/null; then pass "0 bin/fleet parses"; else
  fail "0 bin/fleet parses" "$(bash -n "$FLEET" 2>&1 | head -3)"; fi

D="$FLEET_ROOT/.fleet/dispatch/d1"; mkdir -p "$D"
tmux new-session -d -s "$FLEET_SESSION" -n "so-d1" 'sleep 9999' 2>/dev/null
sleep 0.3
WID=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk '$2=="so-d1"{print $1; exit}')
printf 'window_id\t%s\n' "$WID" >> "$D/meta.tsv"
"$FLEET" dispatch rename d1 "Commit Thing" >/dev/null 2>&1
SLUG=$("$FLEET" slug "Commit Thing" 2>/dev/null)

# --- 1. post 3 --park ---------------------------------------------------------
"$FLEET" gate post 3 --slug "$SLUG" --summary "the diff" -d d1 --park >/dev/null 2>&1; rc=$?
if [ "$(mget "$D" state)" = "gate3-wait" ] && [ -f "$D/GATE-3.md" ]; then
  pass "1 gate post 3 --park parks the ledger at gate3-wait"
else
  fail "1 gate post 3 --park parks at gate3-wait" \
       "rc=$rc state='$(mget "$D" state)' gate-file=$([ -f "$D/GATE-3.md" ] && echo yes || echo no)"; fi

# --- 2. it is PARKED (=> reap refuses) ----------------------------------------
if parked_says gate3-wait && "$FLEET" gate waiting 2>/dev/null | grep -q 'so-d1'; then
  pass "2 gate3-wait is parked and listed by gate waiting (reap refuses it)"
else
  fail "2 gate3-wait is parked" \
       "ledger_parked=$(parked_says gate3-wait && echo yes || echo no) waiting='$("$FLEET" gate waiting 2>/dev/null | tr '\n' ' ')'"; fi

# --- 3. reconcile skips it ----------------------------------------------------
# The bug this guards: a parked dispatch read as stranded, respawned, and the fresh
# sub-orch runs straight PAST the gate the human is still deciding.
#
# THE WINDOW MUST BE DEAD FIRST. With `so-d1` still alive `cmd_reconcile` takes the
# `suborch_live` branch and does nothing whether or not the parked skip exists — the
# case was COMPLETELY INERT and passed against an implementation with no skip at all.
# Killing the pane is what puts the sweep on the arm under test.
#
# THE CONTROL IS WHAT MAKES THE RESULT MEAN ANYTHING: the same dead pane, the same
# sweep, with a NON-parked state must be acted on. It is driven onto the abandon arm
# (respawns at the ceiling) rather than the spawn arm deliberately — a respawn here
# would launch a real harness inside the harness.
printf 'instruction\n' > "$D/instruction.txt"
# KEEP THE SESSION ALIVE. `so-d1` is its only window, and tmux destroys a session
# with its last window — `cmd_reconcile` then returns at `session_name` before the
# loop, so the sweep under test never runs at all. (This is why case 4 also had to
# stop being the first thing to kill that window.)
tmux new-window -d -t "=$FLEET_SESSION" -n keepalive 'sleep 9999' 2>/dev/null
sleep 0.2
tmux kill-window -t "$WID" 2>/dev/null; sleep 0.4
before_wins=$(tmux list-windows -a -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' ')
"$FLEET" reconcile >/dev/null 2>&1
after_wins=$(tmux list-windows -a -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' ')
parked_state_after=$(mget "$D" state)
# CONTROL: same dispatch, same dead pane, state NOT parked => reconcile must act.
DC="$FLEET_ROOT/.fleet/dispatch/d1c"; mkdir -p "$DC"
printf 'window\tso-d1c-gone\n' >> "$DC/meta.tsv"
printf 'instruction\n' > "$DC/instruction.txt"
"$FLEET" gate post 3 --slug "ctl" --summary "x" -d d1c >/dev/null 2>&1   # no --park
printf 'state\trunning\n'  >> "$DC/meta.tsv"
printf 'respawns\t9\n'     >> "$DC/meta.tsv"      # onto the abandon arm, never spawn
FLEET_RESPAWN_MAX=1 "$FLEET" reconcile >/dev/null 2>&1
ctl_state=$(mget "$DC" state)
if [ "$ctl_state" = running ]; then
  fail "3 VACUITY GUARD: reconcile did nothing to the NON-parked control either" \
       "control state stayed '$ctl_state' — the sweep never reached the arm under test, so 'parked was skipped' proves nothing"
elif [ "$before_wins" = "$after_wins" ] && [ "$parked_state_after" = "gate3-wait" ]; then
  pass "3 reconcile skips a gate3-wait dispatch with a DEAD pane (control: non-parked became '$ctl_state')"
else
  fail "3 reconcile skips a gate3-wait dispatch" \
       "windows '$before_wins' -> '$after_wins' state='$parked_state_after'"; fi

# --- 4. a DEAD sub-orch at gate 3 is escalated, not silently dropped ----------
# parked != terminal != stranded: never revive it, but never lose it either.
n1=$(ls -1 "$FLEET_ROOT"/.fleet/inbox/*.msg 2>/dev/null | grep -c .)
"$FLEET" reconcile >/dev/null 2>&1
n2=$(ls -1 "$FLEET_ROOT"/.fleet/inbox/*.msg 2>/dev/null | grep -c .)
esc=0
for m in "$FLEET_ROOT"/.fleet/inbox/*.msg; do
  [ -e "$m" ] || continue
  grep -q 'FLEET-GATE-ORPHAN' "$m" && esc=1
done
if [ "$esc" = 1 ] && [ "$(mget "$D" state)" = "gate3-wait" ]; then
  pass "4 a dead sub-orch parked at gate 3 is escalated once, never revived"
else
  fail "4 a dead sub-orch at gate 3 is escalated" \
       "escalated=$esc msgs $n1->$n2 state='$(mget "$D" state)'"; fi

# --- 5/6. NEGATIVE CONTROLS ---------------------------------------------------
if ! parked_says gate9-wait && ! parked_says planning && ! parked_says running; then
  pass "5 negative control: an unknown state is NOT parked (predicate is an enum, not a suffix match)"
else
  fail "5 negative control: unknown states are not parked" \
       "gate9-wait=$(parked_says gate9-wait && echo parked || echo no) planning=$(parked_says planning && echo parked || echo no) running=$(parked_says running && echo parked || echo no)"; fi
if ! terminal_says gate3-wait && terminal_says done; then
  pass "6 negative control: gate3-wait is parked but NOT terminal"
else
  fail "6 gate3-wait is not terminal" "terminal(gate3-wait)=$(terminal_says gate3-wait && echo yes || echo no)"; fi

# --- 7. the older sentinel strings are byte-identical -------------------------
E="$FLEET_ROOT/.fleet/dispatch/d2"; mkdir -p "$E"
"$FLEET" gate post 1 --slug abc --summary s -d d2 >/dev/null 2>&1
g1=$(sed -n 1p "$E/GATE-1.md" 2>/dev/null)
if [ "$g1" = "[FLEET-GATE:1 slug=abc action=implement]" ]; then
  pass "7 the GATE 1 sentinel is byte-identical to before"
else
  fail "7 the GATE 1 sentinel is byte-identical" "got '$g1'"; fi
if grep -qF '[FLEET-GATE:2 slug=$slug action=merge target=$target]' "$FLEET"; then
  pass "7b the GATE 2 sentinel is byte-identical to before"
else
  fail "7b the GATE 2 sentinel is byte-identical" "the gate-2 sentinel string changed shape"; fi

# --- 8. the gate-3 body says the right thing ---------------------------------
if grep -qi 'staged' "$D/GATE-3.md" && grep -qi 'not committed\|do not commit' "$D/GATE-3.md" \
   && grep -q 'diff-view' "$D/GATE-3.md"; then
  pass "8 the gate-3 body points at the staged diff and says agents do not commit"
else
  fail "8 the gate-3 body points at the staged diff" "body: $(head -6 "$D/GATE-3.md" | tr '\n' '|')"; fi

# --- 9. park validates the enum, still closed --------------------------------
"$FLEET" gate park d2 3 >/dev/null 2>&1 && ok3=1 || ok3=0
"$FLEET" gate park d2 4 >/dev/null 2>&1 && ok4=1 || ok4=0
if [ "$ok3" = 1 ] && [ "$ok4" = 0 ]; then
  pass "9 gate park accepts 3 and still refuses 4 (the enum stayed closed)"
else
  fail "9 gate park enum" "park 3 => $ok3, park 4 => $ok4"; fi

# --- 10. the zero-commit path PROMOTES to a parked gate 3 --------------------
# A real git worktree with staged-but-uncommitted work, i.e. exactly the state d31
# makes normal. Posting gate 2 there must not merely refuse into the sub-orch's
# stderr — it must leave the ledger PARKED at gate 3 so reconcile and reap know.
if command -v git >/dev/null 2>&1; then
  WT="$FLEET_ROOT/wt"; mkdir -p "$WT"
  ( cd "$WT" && git init -q -b main . && git config user.email t@t && git config user.name t \
    && echo base > base.txt && git add -A && git commit -qm base \
    && git checkout -qb feature && echo work > work.txt && git add -A ) >/dev/null 2>&1
  F="$FLEET_ROOT/.fleet/dispatch/d3"; mkdir -p "$F"
  "$FLEET" gate post 2 --slug feature --target main -d d3 -w "$WT" >/dev/null 2>&1; rc=$?
  if [ "$(mget "$F" state)" = "gate3-wait" ] && [ -f "$F/GATE-3.md" ]; then
    pass "10 the gate-2 zero-commit path promotes to a PARKED gate 3 (rc=$rc)"
  else
    fail "10 the zero-commit path promotes to a parked gate 3" \
         "rc=$rc state='$(mget "$F" state)' gate3=$([ -f "$F/GATE-3.md" ] && echo yes || echo no) — it still refuses into the void"; fi
else
  echo "  SKIP(10): git not installed"
fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

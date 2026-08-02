#!/usr/bin/env bash
# Proof harness — S6: HAND-DRIVE SAFETY (d34).
#
# The premise fleet added and never made safe: "…or it can be done manually by a
# user within an agent." Every mechanism here was built assuming the only thing in
# an agent pane or worktree is an agent. Where a HUMAN might be sitting there
# instead, three of them do the wrong thing, and all three are destructive or
# lossy rather than merely wrong:
#
#  A. `fleet send` NEVER-CLOBBER IS ORCHESTRATOR-ONLY. The orchestrator path
#     redirects into the durable inbox precisely so a human's half-typed prompt is
#     never spliced into. The WORKER path has no such check: it is `send-keys -l`
#     followed by Enter, which splices into a half-typed prompt AND SUBMITS IT.
#
#  B. `fleet watch` DOES NOT DISARM ON A VANISHED WORKER. A killed worker window
#     never matches, so it is never idle, so the watcher runs to the ~90 minute cap.
#     A vanished sub-orch pane is handled; a worker is not. There is also no way to
#     cancel a watch at all.
#
#  C. `fleet reap` HAS NO HUMAN-PRESENCE SIGNAL. Its live-state guard keys on
#     `@agent_state`, so a human sitting in a worktree with claude exited is
#     INVISIBLE to it — and gets their window killed and their worktree deleted.
#
# The fix for C is a `@fleet_human` PANE option — deliberately not a 10th TSV
# column: three independent readers parse that TSV positionally as exactly 9 fields
# and all three fail SILENTLY WRONG on a 10th.
#
# Cases:
#   1. `fleet send` refuses to splice into a worker's half-typed prompt
#   2. ...and says so, rather than failing silently
#   3. ...but a normal (empty-input) worker send still works — the guard is narrow
#   4. `fleet human on` stamps the pane option; `off` clears it; `status` reports
#   5. it is a PANE option, NOT a TSV column — the TSV is still exactly 9 fields
#   6. reap REFUSES a worktree a human is present in, even flagged ready and clean
#   7. ...and the refusal is not overridable by accident: it names the human
#   8. `fleet send` refuses to send-keys into a human-present pane
#   9. `fleet unwatch` exists and disarms a running watcher
#  10. a watch on a KILLED worker window terminates promptly (not at the 90min cap)
#  11. reconcile does not mark a dispatch failed while a human is present in it
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
export FLEET_SESSION="hd_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"
cleanup() { command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }

echo "== d34 S6 — hand-drive safety proof"
if bash -n "$FLEET" 2>/dev/null; then pass "0 bin/fleet parses"; else
  fail "0 bin/fleet parses" "$(bash -n "$FLEET" 2>&1 | head -3)"; fi

tmux new-session -d -s "$FLEET_SESSION" -n main 'cat' 2>/dev/null
sleep 0.3
MAINW=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' | awk '$2=="main"{print $1}')
MAINP=$(tmux list-panes -t "$MAINW" -F '#{pane_id}' | head -1)
tmux set -w -t "$MAINW" @fleet_role main 2>/dev/null

WT="$FLEET_ROOT/repo/fleet_task"; mkdir -p "$WT/.fleet"
tmux new-window -d -t "=$FLEET_SESSION" -n "repo/fleet_task" -c "$WT" 'cat' 2>/dev/null
sleep 0.3
WW=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' | awk '$2=="repo/fleet_task"{print $1}')
WP=$(tmux list-panes -t "$WW" -F '#{pane_id}' | head -1)
tmux set -w -t "$WW" @fleet_harness claude 2>/dev/null
tmux set -w -t "$WW" @agent_state idle 2>/dev/null
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$WT" repo fleet/task 0 main claude "" "" "" > "$XDG_CONFIG_HOME/fleet/sessions/$FLEET_SESSION.agents"

# --- 3. the narrow case first: an EMPTY input still receives a send -----------
out=$("$FLEET" send "repo/fleet_task" "hello worker" 2>&1); rc=$?
sleep 0.4
cap=$(tmux capture-pane -p -t "$WP" 2>/dev/null)
if [ "$rc" = 0 ] && printf '%s' "$cap" | grep -q 'hello worker'; then
  pass "3 a normal (empty-input) worker send still works — the guard is narrow"
else
  fail "3 a normal worker send still works" "rc=$rc out='$(echo "$out"|head -2)' cap='$(printf '%s' "$cap"|tr '\n' '|'|head -c 120)'"; fi

# --- 1/2. a HALF-TYPED prompt must not be spliced into ------------------------
# orch_input_state reports `draft` when the last ❯ line has text after it: exactly
# the shape of a human mid-sentence.
tmux send-keys -t "$WP" -l '❯ I was in the middle of typing' 2>/dev/null; sleep 0.4
before=$(tmux capture-pane -p -t "$WP" 2>/dev/null)
out=$("$FLEET" send "repo/fleet_task" "CLOBBER" 2>&1); rc=$?
sleep 0.4
after=$(tmux capture-pane -p -t "$WP" 2>/dev/null)
if [ "$rc" != 0 ] && ! printf '%s' "$after" | grep -q 'CLOBBER'; then
  pass "1 fleet send refuses to splice into a worker's half-typed prompt"
else
  fail "1 fleet send refuses to splice into a half-typed prompt" \
       "rc=$rc — it spliced into and SUBMITTED a human's in-progress prompt"; fi
if printf '%s' "$out" | grep -qi 'typ\|draft\|input\|in-progress\|force'; then
  pass "2 the refusal says why and how to override"
else
  fail "2 the refusal says why" "out='$(echo "$out" | head -2)'"; fi
tmux send-keys -t "$WP" C-u 2>/dev/null; tmux send-keys -t "$WP" -l '' 2>/dev/null
tmux clear-history -t "$WP" 2>/dev/null; sleep 0.3

# --- 4. the @fleet_human stamp ------------------------------------------------
"$FLEET" human on "repo/fleet_task" >/dev/null 2>&1
h=$(tmux show -pqv -t "$WP" @fleet_human 2>/dev/null)
st=$("$FLEET" human status "repo/fleet_task" 2>&1)
if [ "$h" = 1 ] && printf '%s' "$st" | grep -qi 'on\|present\|yes'; then
  pass "4 fleet human on stamps the pane option and status reports it"
else
  fail "4 fleet human on stamps the pane option" "@fleet_human='$h' status='$st'"; fi

# --- 5. it is a PANE option, NOT a TSV column --------------------------------
# Three independent readers parse the agents TSV positionally as exactly 9 fields
# and all three fail SILENTLY WRONG on a 10th (every row renders the `done` pill;
# a blank dashboard; a mangled restore owner). This is why presence is a pane option.
badrows=$("$FLEET" agents 2>/dev/null | awk -F'\t' 'NF!=9 && NF!=0 {n++} END{print n+0}')
if [ "${badrows:-0}" = 0 ]; then
  pass "5 the agents TSV is still exactly 9 fields (presence did not become a column)"
else
  fail "5 the agents TSV is still 9 fields" "$badrows row(s) with a different field count"; fi

# --- 6/7. reap refuses a human-present worktree ------------------------------
( cd "$WT" && git init -q -b fleet/task . && git config user.email t@t && git config user.name t \
  && echo x > f && git add -A && git commit -qm x ) >/dev/null 2>&1
touch "$WT/.fleet/ready"
out=$("$FLEET" reap "repo/fleet/task" 2>&1); rc=$?
if [ -d "$WT" ] && tmux display -p -t "$WW" '#{window_id}' >/dev/null 2>&1; then
  pass "6 reap REFUSES a human-present worktree (worktree and window survive)"
else
  fail "6 reap refuses a human-present worktree" \
       "worktree=$([ -d "$WT" ] && echo alive || echo GONE) window=$(tmux display -p -t "$WW" '#{window_id}' 2>/dev/null || echo GONE) — a human just lost their work"; fi
if printf '%s' "$out" | grep -qi 'human'; then
  pass "7 the refusal names the reason (a human is present)"
else
  fail "7 the refusal names the reason" "out='$(echo "$out" | head -3)'"; fi

# --- 8. send refuses a human-present pane ------------------------------------
out=$("$FLEET" send "repo/fleet_task" "typed at a human" 2>&1); rc=$?
sleep 0.3
cap=$(tmux capture-pane -p -t "$WP" 2>/dev/null)
if [ "$rc" != 0 ] && ! printf '%s' "$cap" | grep -q 'typed at a human'; then
  pass "8 fleet send refuses to send-keys into a human-present pane"
else
  fail "8 send refuses a human-present pane" "rc=$rc — it typed into a human's terminal"; fi
"$FLEET" human off "repo/fleet_task" >/dev/null 2>&1

# --- 9. fleet unwatch ---------------------------------------------------------
# BEHAVIOURAL, not existence: arm a watcher on a LIVE (working, never-idle) worker
# — which without unwatch runs the full ~90 minutes — then cancel it and require
# the process to be gone. Asserting the verb parses would prove nothing.
tmux new-window -d -t "=$FLEET_SESSION" -n "repo/fleet_busy" 'cat' 2>/dev/null
sleep 0.3
BW=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' | awk '$2=="repo/fleet_busy"{print $1}')
tmux set -w -t "$BW" @fleet_harness claude 2>/dev/null
tmux set -w -t "$BW" @agent_state working 2>/dev/null
( export TMUX_PANE="$MAINP"
  "$FLEET" watch "repo/fleet_busy" -m "busy done" >/dev/null 2>&1 )
sleep 1
if ! pgrep -f "watch-run.*fleet_busy" >/dev/null 2>&1; then
  fail "9 fleet unwatch disarms a running watcher" "the watcher never armed — case is vacuous"
else
  ( export TMUX_PANE="$MAINP"; "$FLEET" unwatch >/dev/null 2>&1 )
  w=0; while [ "$w" -lt 20 ]; do
    pgrep -f "watch-run.*fleet_busy" >/dev/null 2>&1 || break
    sleep 1; w=$((w+1))
  done
  if [ "$w" -lt 20 ]; then
    pass "9 fleet unwatch disarms a running watcher (${w}s)"
  else
    fail "9 fleet unwatch disarms a running watcher" \
         "still running after ${w}s — an armed watcher still cannot be cancelled"; fi
fi
pkill -f "watch-run.*fleet_busy" 2>/dev/null || true

# --- 10. a watch on a KILLED worker window terminates promptly ---------------
# The bug: a killed window never matches agents_tsv, so it is never `idle`, so the
# watcher spins to the ~90 minute cap. Bound the assertion well under that.
tmux new-window -d -t "=$FLEET_SESSION" -n "repo/fleet_doomed" 'cat' 2>/dev/null
sleep 0.3
DW=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' | awk '$2=="repo/fleet_doomed"{print $1}')
tmux set -w -t "$DW" @fleet_harness claude 2>/dev/null
tmux set -w -t "$DW" @agent_state working 2>/dev/null
( export TMUX_PANE="$MAINP"
  "$FLEET" watch "repo/fleet_doomed" -m "doomed done" >/dev/null 2>&1 )
sleep 1
tmux kill-window -t "$DW" 2>/dev/null
# Give the watcher a bounded window to notice. A correct implementation notices
# within a few poll ticks; the broken one takes 90 minutes.
waited=0
while [ "$waited" -lt 40 ]; do
  pgrep -f "watch-run.*fleet_doomed" >/dev/null 2>&1 || break
  sleep 1; waited=$((waited+1))
done
if [ "$waited" -lt 40 ]; then
  pass "10 a watch on a killed worker terminates promptly (${waited}s, not ~90min)"
else
  fail "10 a watch on a killed worker terminates promptly" \
       "still running after ${waited}s — it is heading for the ~90min cap"; fi
pkill -f "watch-run.*fleet_doomed" 2>/dev/null || true

# --- 11. reconcile does not overrun a human ----------------------------------
D="$FLEET_ROOT/.fleet/dispatch/d1"; mkdir -p "$D"
printf 'state\tplanning\n' >> "$D/meta.tsv"
printf 'window\tso-d1\n'   >> "$D/meta.tsv"
printf 'instruction\n' > "$D/instruction.txt"
tmux new-window -d -t "=$FLEET_SESSION" -n "so-d1" 'cat' 2>/dev/null
sleep 0.3
SP=$(tmux list-panes -t "=$FLEET_SESSION:so-d1" -F '#{pane_id}' | head -1)
tmux set -p -t "$SP" @fleet_human 1 2>/dev/null
"$FLEET" reconcile >/dev/null 2>&1
newstate=$(awk -F'\t' '$1=="state"{v=$2} END{print v}' "$D/meta.tsv")
if [ "$newstate" != failed ]; then
  pass "11 reconcile does not mark a human-present dispatch failed (state=$newstate)"
else
  fail "11 reconcile does not overrun a human" "it marked the dispatch failed while a human was in it"; fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

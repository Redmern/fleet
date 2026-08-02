#!/usr/bin/env bash
# Proof harness — S1b: REJECT ROUTING (d34).
#
# Approving is the easy half. The half that decides whether this feature is worth
# having is what happens when the human says NO: the pipeline has to go back exactly
# ONE rung, keep its identity (same dispatch id, same reports dir, same worktree —
# the whole point is that the next lap builds on what exists), count the lap, and
# STOP counting at three. A reject loop with no cap is how a gate turns into a
# perpetual motion machine that spends a model overnight.
#
# Cases:
#   1. reject at gate 1 routes role-phase back to `plan` (one rung), not to research
#   2. ...and keeps the dispatch identity: id, reports key, window all unchanged
#   3. rejects_g1 increments 0 -> 1 -> 2
#   4. the attempt counter in the sentinel tracks it (attempt=2, then 3)
#   5. each rejection's reason is kept as its OWN file — a lap's reason is not
#      overwritten by the next lap's
#   6. THE CAP: the 4th rejection is refused (rc 4), escalates sev=blocked, and
#      marks the ledger blocked instead of routing another lap
#  6b. …and `blocked` is PARKED: reap skips it, `gate list` shows it
#  6c. NEGATIVE CONTROL for that widening: an UNKNOWN state is still not parked
#  6d. …and reconcile neither revives it nor marks it failed
#   7. reject at gate 3 routes back to `impl` (the Implementation agent, same worktree)
#   8. gate-2 reject is PRE-MERGE only: once the ledger concluded, it is refused (rc 5)
#   9. `gate post --park` is ONE transaction: posted and parked, no second command
#  10. NEGATIVE CONTROL: approve does NOT touch role-phase or any rejects_g<N>
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
export FLEET_SESSION="gr_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"
cleanup() { command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

echo "== d34 S1b — gate reject routing proof"
if bash -n "$FLEET" 2>/dev/null; then pass "0 bin/fleet parses"; else
  fail "0 bin/fleet parses" "$(bash -n "$FLEET" 2>&1 | head -3)"; fi

tmux new-session -d -s "$FLEET_SESSION" -n "so-d1" 'sleep 9999' 2>/dev/null
sleep 0.3
mkD() { # <id> <window-name> -> dispatch dir
  local id="$1" wn="$2" d
  d="$FLEET_ROOT/.fleet/dispatch/$id"
  mkdir -p "$d"
  tmux new-window -d -t "=$FLEET_SESSION" -n "$wn" 'sleep 9999' 2>/dev/null
  sleep 0.2
  local w; w=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
               | awk -v n="$wn" '$2==n{print $1; exit}')
  printf 'window_id\t%s\n' "$w" >> "$d/meta.tsv"
  printf '%s\n' "$d"
}

# --- 9. gate post --park is ONE transaction -----------------------------------
D=$(mkD d1 so-d1x)
"$FLEET" dispatch rename d1 "Login Fix" >/dev/null 2>&1
SLUG=$("$FLEET" slug "Login Fix" 2>/dev/null)
"$FLEET" gate post 1 --slug "$SLUG" --summary "the plan" -d d1 --park >/dev/null 2>&1
if [ "$(mget "$D" state)" = "gate1-wait" ] && [ -f "$D/GATE-1.md" ]; then
  pass "9 gate post --park posts AND parks in one transaction"
else
  fail "9 gate post --park is one transaction" \
       "state='$(mget "$D" state)' gate-file=$([ -f "$D/GATE-1.md" ] && echo yes || echo no)"; fi

REPORTS_BEFORE=$(mget "$D" reports); WIN_BEFORE=$(mget "$D" window)

# --- 1..5. rejecting laps -----------------------------------------------------
"$FLEET" gate reject d1 -m "drop the retry loop" >/dev/null 2>&1
if [ "$(mget "$D" role-phase)" = plan ]; then
  pass "1 gate-1 reject routes back exactly one rung (-> plan)"
else
  fail "1 gate-1 reject routes back one rung" "role-phase='$(mget "$D" role-phase)' (want plan)"; fi
if [ "$(mget "$D" reports)" = "$REPORTS_BEFORE" ] && [ "$(mget "$D" window)" = "$WIN_BEFORE" ] \
   && [ -d "$FLEET_ROOT/.fleet/dispatch/d1" ]; then
  pass "2 the dispatch keeps its identity (id, reports, window)"
else
  fail "2 the dispatch keeps its identity" \
       "reports '$REPORTS_BEFORE'->'$(mget "$D" reports)' window '$WIN_BEFORE'->'$(mget "$D" window)'"; fi
r1=$(mget "$D" rejects_g1)
a1=$(sed -n 1p "$D/decision-1.txt" 2>/dev/null)

# lap 2: the decision must be re-openable for a NEW lap — a rejected gate is
# re-posted by the sub-orch, which is what makes the next decision legal.
"$FLEET" gate post 1 --slug "$SLUG" --summary "plan v2" -d d1 --park >/dev/null 2>&1
"$FLEET" gate reject d1 -m "still too clever" >/dev/null 2>&1
r2=$(mget "$D" rejects_g1)
a2=$(sed -n 1p "$D/decision-1.txt" 2>/dev/null)
if [ "$r1" = 1 ] && [ "$r2" = 2 ]; then
  pass "3 rejects_g1 increments 0 -> 1 -> 2"
else
  fail "3 rejects_g1 increments" "got '$r1' then '$r2'"; fi
case "$a1$a2" in
  *"attempt=2"*"attempt=3"*) pass "4 the sentinel's attempt counter tracks the lap (2, then 3)" ;;
  *) fail "4 the sentinel's attempt counter tracks the lap" "lap1='$a1' lap2='$a2'" ;;
esac
n_reasons=$(ls -1 "$D"/reason-g1-*.txt 2>/dev/null | grep -c .)
if [ "${n_reasons:-0}" = 2 ] && grep -q 'drop the retry loop' "$D/reason-g1-1.txt" 2>/dev/null \
   && grep -q 'still too clever' "$D/reason-g1-2.txt" 2>/dev/null; then
  pass "5 each lap's reason is kept as its own file (not overwritten)"
else
  fail "5 each lap's reason is its own file" "found $n_reasons reason files"; fi

# --- 6. THE CAP ---------------------------------------------------------------
"$FLEET" gate post 1 --slug "$SLUG" --summary "plan v3" -d d1 --park >/dev/null 2>&1
"$FLEET" gate reject d1 -m "third" >/dev/null 2>&1          # rejects_g1 -> 3, still routes
"$FLEET" gate post 1 --slug "$SLUG" --summary "plan v4" -d d1 --park >/dev/null 2>&1
out=$("$FLEET" gate reject d1 -m "fourth" 2>&1); rc=$?
blocked=0
for m in "$FLEET_ROOT"/.fleet/inbox/*.msg; do
  [ -e "$m" ] || continue
  grep -q '^sev=blocked' "$m" && grep -qi 'reject' "$m" && blocked=1
done
if [ "$rc" = 4 ] && [ "$(mget "$D" state)" = blocked ] && [ "$blocked" = 1 ]; then
  pass "6 the 4th rejection is capped (rc 4), ledger blocked, sev=blocked escalation"
else
  fail "6 the 4th rejection is capped" \
       "rc=$rc state='$(mget "$D" state)' blocked-msg=$blocked out='$(echo "$out" | head -2)'"; fi

# --- 6b. `blocked` IS PARKED — the cap must not un-guard what it stopped -------
# `gate_decide` is a NEW writer of the ledger `state`, and `blocked` began life in
# neither `ledger_terminal` nor `ledger_parked`. Unclassified means: reap stops
# skipping the worktree, `gate list` stops showing it, and reconcile reads
# "non-terminal + not parked" as STRANDED and revives or fails it — a fresh sub-orch
# reading the instruction and running straight past the cap that stopped it. Same
# class as the July 19 self-merge incident, reintroduced by this slice's own writer.
# The state under test is the one case 6 just produced, so this can never drift from it.
cap_state=$(mget "$D" state)
# `gate_waiting` emits the LIVE window name (ledger `window`, slugged by
# `dispatch rename`), falling back to bare so-<id> — derive it the same way rather
# than hard-coding, or this asserts against a name reap never matches.
WN6=$(mget "$D" window); [ -n "$WN6" ] || WN6=so-d1
w6=$("$FLEET" gate waiting 2>/dev/null)
l6=$("$FLEET" gate list 2>/dev/null | awk -F'\t' '$1=="d1"{print $2}')
if [ "$cap_state" != blocked ]; then
  fail "6b VACUITY GUARD: case 6 did not leave d1 blocked" "state='$cap_state' — 6b proves nothing"
elif printf '%s\n' "$w6" | grep -q "^$WN6$" && [ "$l6" = blocked ]; then
  pass "6b a capped (blocked) dispatch is PARKED — reap skips it and 'gate list' shows it"
else
  fail "6b a capped dispatch is parked" \
       "gate waiting='$(printf '%s' "$w6" | tr '\n' ' ')' (want '$WN6') gate-list-state='$l6' — the cap escalated to a human and then dropped the guards protecting the work"; fi

# NEGATIVE CONTROL for the same edit: widening `ledger_parked` must not swallow an
# unknown token. `reconcile` treating an unrecognised state as parked is how a real
# stranded dispatch becomes invisible — the inverse failure, and the reason this
# predicate is a closed `case` and not a "not terminal" test.
DU=$(mkD du so-dux)
printf 'state\tsomething-else\n' >> "$DU/meta.tsv"
if ! "$FLEET" gate waiting 2>/dev/null | grep -q '^so-dux$'; then
  pass "6c negative control: an UNKNOWN state is still not parked"
else
  fail "6c an unknown state is not parked" "'something-else' was classified as parked"; fi

# --- 6d. …and reconcile must not revive or FAIL it ----------------------------
# The third consumer of `ledger_parked`, and the one that does damage rather than
# merely losing a guard: unclassified, reconcile reads "non-terminal + not parked +
# pane not a harness" as STRANDED and marks the dispatch `failed` (measured) — a
# human-escalated gate silently reclassified as a dead pipeline. The pane here is
# `sleep`, so liveness reads DEAD, which is precisely the condition that triggers it.
# Counted for THIS dispatch's window only, never over the whole server: case 6c's
# unknown-state dispatch is revived by the same sweep, and that is CORRECT — an
# all-windows comparison fails on the negative control's own success.
printf 'instruction\n' > "$D/instruction.txt"
n_wn() { tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -cx "$WN6"; }
wins_before=$(n_wn)
"$FLEET" reconcile >/dev/null 2>&1
wins_after=$(n_wn)
if [ "$(mget "$D" state)" = blocked ] && [ "$wins_after" = "$wins_before" ]; then
  pass "6d reconcile leaves a capped dispatch alone (not revived, not marked failed)"
else
  fail "6d reconcile leaves a capped dispatch alone" \
       "state='$(mget "$D" state)' (want blocked) $WN6 windows $wins_before -> $wins_after — reconcile respawned a sub-orch onto a gate a human is holding"; fi

# --- 7. gate 3 routes back to impl -------------------------------------------
D3=$(mkD d3 so-d3x)
"$FLEET" dispatch rename d3 "Third Thing" >/dev/null 2>&1
S3=$("$FLEET" slug "Third Thing" 2>/dev/null)
"$FLEET" gate post 3 --slug "$S3" --summary "the diff" -d d3 --park >/dev/null 2>&1
"$FLEET" gate reject d3 -m "extract that helper" >/dev/null 2>&1
if [ "$(mget "$D3" role-phase)" = impl ]; then
  pass "7 gate-3 reject routes back to impl (same worktree, revision guidance)"
else
  fail "7 gate-3 reject routes back to impl" "role-phase='$(mget "$D3" role-phase)'"; fi

# --- 8. gate-2 reject is PRE-MERGE only --------------------------------------
D2=$(mkD d4 so-d4x)
"$FLEET" dispatch rename d4 "Ship Thing" >/dev/null 2>&1
S4=$("$FLEET" slug "Ship Thing" 2>/dev/null)
mkdir -p "$FLEET_ROOT/wt"
printf 'gate\t2\n' >/dev/null
# post gate 2 directly into the dir (the zero-commit precondition needs a real repo;
# what is under test here is the reject path, not the post path)
printf '[FLEET-GATE:2 slug=%s action=merge target=main]\nbody\n' "$S4" > "$D2/GATE-2.md"
"$FLEET" gate park d4 2 >/dev/null 2>&1
out=$("$FLEET" gate reject d4 -m "do not ship" 2>&1); rc_pre=$?
pre_ok=0; [ "$rc_pre" = 0 ] && [ "$(mget "$D2" decision)" = reject ] && pre_ok=1
# now conclude the ledger, as the SHIP path does, and reject again
printf 'state\tdone\n' >> "$D2/meta.tsv"
printf 'decision\t\n' >> "$D2/meta.tsv"          # re-open the decision for the retry
out=$("$FLEET" gate reject d4 --gate 2 -m "too late" 2>&1); rc=$?
if [ "$pre_ok" = 1 ] && [ "$rc" = 5 ] && printf '%s' "$out" | grep -qi 'revert'; then
  pass "8 gate-2 reject is legal pre-merge, refused (rc 5) once concluded, and points at revert"
else
  fail "8 gate-2 reject is pre-merge only" \
       "pre_ok=$pre_ok post-rc=$rc out='$(echo "$out" | head -2)'"; fi

# --- 10. NEGATIVE CONTROL -----------------------------------------------------
D5=$(mkD d5 so-d5x)
"$FLEET" dispatch rename d5 "Clean Thing" >/dev/null 2>&1
S5=$("$FLEET" slug "Clean Thing" 2>/dev/null)
"$FLEET" gate post 1 --slug "$S5" --summary "ok" -d d5 --park >/dev/null 2>&1
"$FLEET" gate approve d5 >/dev/null 2>&1
if [ -z "$(mget "$D5" role-phase)" ] && [ -z "$(mget "$D5" rejects_g1)" ]; then
  pass "10 negative control: approve touches neither role-phase nor rejects_g<N>"
else
  fail "10 negative control" \
       "role-phase='$(mget "$D5" role-phase)' rejects_g1='$(mget "$D5" rejects_g1)'"; fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

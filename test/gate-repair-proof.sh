#!/usr/bin/env bash
# Proof harness — d34 round 3 repair: B2, B4, B5 and the named residue.
#
# One file rather than four, because these are defect fixes against one another's
# fixtures: the same parked dispatch answers "is `blocked` visible", "does a re-post
# strand its decision file", and "can --gate approve the wrong gate".
#
# Cases:
#   1.  B2  `blocked` is PARKED (the 3-reject cap's own state), with the negative
#           control that an UNKNOWN token is still not parked
#   2.  B2  ...so `gate waiting` / `gate list` show it — the escalation message tells
#           the human to "decide it by hand" about a dispatch they can otherwise not see
#   3.  B2  ...and reconcile leaves it alone instead of relabelling it `failed`,
#           with a non-parked control on the same dead pane
#   4.  B5  a FAILED park writes NO inbox message (post+park is one transaction)
#   5.  B5  ...and the ordinary path still posts and parks
#   6.  B-6 a re-posted gate does not leave a stale decision-<N>.txt behind
#   7.  B-7 GATE 3 gets its audit stamp on pop (the enum was still `1|2`)
#   8.  B-4 --gate N is reconciled against the parked state: approving gate 1 while
#           parked at gate 3 refuses and writes NOTHING
#   9.  B4  gate 2 approve with NO tty and NO --yes REFUSES (rc 2, nothing written)
#   10. B4  ...--yes is the explicit escape hatch and proceeds
#   11. B4  ...and gates 1 and 3 are unaffected (no new friction where none was promised)
#   12. B3.3 gate_decide DIES when the decision keys cannot be written (the one verb
#           in fleet designed to fail loudly must not fail silently on a broken ledger)
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

TMPROOT=$(mktemp -d)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"
mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
SOCK="${FLEET_HARNESS_SOCK:-$TMUX_TMPDIR/tmux-$(id -u)/default}"
if [ "$SOCK" = "/tmp/tmux-$(id -u)/default" ]; then
  echo "REFUSE: harness resolved to the real tmux socket ($SOCK)" >&2; rm -rf "$TMPROOT"; exit 1; fi
case "$SOCK" in "$TMPROOT"/*) ;; *) echo "REFUSE: socket not under TMPROOT" >&2; rm -rf "$TMPROOT"; exit 1 ;; esac
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
inbox_n() { ls -1 "$FLEET_ROOT"/.fleet/inbox/*.msg 2>/dev/null | grep -c .; }
# The classification predicates are pure functions of a string — exercise them out of
# the real source, never a mock (the same technique gate3-state-proof.sh uses).
parked_says() { bash -c "$(sed -n '/^ledger_parked()/p' "$FLEET"); ledger_parked '$1'"; }
terminal_says() { bash -c "$(sed -n '/^ledger_terminal()/p' "$FLEET"); ledger_terminal '$1'"; }

echo "== d34 round 3 — gate repair proof (B2/B4/B5 + residue)"
if bash -n "$FLEET" 2>/dev/null; then pass "0 bin/fleet parses"; else
  fail "0 bin/fleet parses" "$(bash -n "$FLEET" 2>&1 | head -3)"; fi

tmux new-session -d -s "$FLEET_SESSION" -n main 'sleep 9999' 2>/dev/null
sleep 0.3

# --- 1. `blocked` is parked; an unknown token is not --------------------------
# The 3-reject cap writes `blocked`, and it shipped in NEITHER classification set —
# so the verb that escalates to a human promptly dropped every guard protecting the
# work it escalated. It is NOT terminal: nothing concluded, the human can still
# decide by hand, and `suborch_ledger_active` (which shares only the terminal set)
# must keep nudging. The negative control is mandatory: widening this predicate must
# not make an UNKNOWN token parked, which is the inverse failure — a genuinely
# stranded dispatch turning invisible. That is why it is a closed `case`, never a
# "not terminal" test.
if parked_says blocked && ! terminal_says blocked && ! parked_says zzz-unknown; then
  pass "1 blocked is PARKED and not terminal; an unknown token is still neither"
else
  fail "1 blocked is parked, unknown is not" \
       "parked(blocked)=$(parked_says blocked && echo y || echo n) terminal(blocked)=$(terminal_says blocked && echo y || echo n) parked(zzz-unknown)=$(parked_says zzz-unknown && echo y || echo n)"; fi

# --- 2. a blocked dispatch is VISIBLE -----------------------------------------
DB="$FLEET_ROOT/.fleet/dispatch/d10"; mkdir -p "$DB"
tmux new-window -d -t "=$FLEET_SESSION" -n "so-d10" 'sleep 9999' 2>/dev/null; sleep 0.3
WIDB=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
       | awk '$2=="so-d10"{print $1; exit}')
printf 'window_id\t%s\n' "$WIDB" >> "$DB/meta.tsv"
"$FLEET" dispatch rename d10 "Capped Thing" >/dev/null 2>&1
SLUGB=$("$FLEET" slug "Capped Thing" 2>/dev/null)
"$FLEET" gate post 1 --slug "$SLUGB" --summary "s" -d d10 --park >/dev/null 2>&1
# Drive it to the cap through the REAL verb, four rejections, never a hand-written state.
i=0; while [ $i -lt 4 ]; do
  "$FLEET" gate post 1 --slug "$SLUGB" --summary "s" -d d10 --park >/dev/null 2>&1
  "$FLEET" gate reject d10 -m "lap $i" >/dev/null 2>&1
  i=$((i+1))
done
if [ "$(mget "$DB" state)" != blocked ]; then
  fail "2 VACUITY GUARD: the cap never fired" \
       "state='$(mget "$DB" state)' after 4 rejections — the rest of this group tests nothing"
elif "$FLEET" gate waiting 2>/dev/null | grep -q 'd10' && "$FLEET" gate list 2>/dev/null | grep -q 'd10'; then
  pass "2 a capped/blocked dispatch is listed by gate waiting and gate list (reap refuses it, the human can see it)"
else
  fail "2 a blocked dispatch is visible" \
       "waiting='$("$FLEET" gate waiting 2>/dev/null | tr '\n' ' ')' list='$("$FLEET" gate list 2>/dev/null | tr '\n' ' ')' — the escalation says 'decide it by hand' about a dispatch the human cannot see"; fi

# --- 3. reconcile leaves a blocked dispatch alone -----------------------------
# With `blocked` unclassified, reconcile read "non-terminal + not parked + dead pane"
# as STRANDED and flipped it to `failed` — the July-19 class, reintroduced by this
# slice's own writer, at the exact moment fleet is escalating to a person.
printf 'instruction\n' > "$DB/instruction.txt"
tmux kill-window -t "$WIDB" 2>/dev/null; sleep 0.4      # session survives on `main`
FLEET_RESPAWN_MAX=1 "$FLEET" reconcile >/dev/null 2>&1
blocked_after=$(mget "$DB" state)
# CONTROL on the same dead-pane shape: a non-parked dispatch IS acted on, so a green
# result above cannot come from a sweep that did nothing at all.
DBC="$FLEET_ROOT/.fleet/dispatch/d10c"; mkdir -p "$DBC"
printf 'window\tso-d10c-gone\nstate\trunning\nrespawns\t9\n' >> "$DBC/meta.tsv"
printf 'instruction\n' > "$DBC/instruction.txt"
FLEET_RESPAWN_MAX=1 "$FLEET" reconcile >/dev/null 2>&1
ctl_after=$(mget "$DBC" state)
if [ "$ctl_after" = running ]; then
  fail "3 VACUITY GUARD: reconcile did nothing to the non-parked control either" \
       "control stayed 'running' — the sweep never reached the arm under test"
elif [ "$blocked_after" = blocked ]; then
  pass "3 reconcile leaves a blocked dispatch alone (control: non-parked became '$ctl_after')"
else
  fail "3 reconcile leaves a blocked dispatch alone" \
       "state blocked -> '$blocked_after' — crash-recovery relabelled an escalation as failed"; fi

# --- 4/5. B5: post + park is ONE transaction ----------------------------------
# `inbox_put` ran BEFORE `gate_park`, and the park failure was swallowed by
# `|| true` — so the reachable partial state was MESSAGE WITH NO PARK, which is the
# July-19 bug: invisible to every guard, and reap eats the worktree. (The comment
# above the code asserted this ordering "can only ever produce" the safe half — it
# was inverted relative to its own code, which is why review passed over it.)
# Park-with-no-message is the safe side, and not for the reason that comment gave:
# `gate_write_artifact` has already put GATE-<N>.md in the folder nvim shows, so the
# question is still visible even with no inbox message.
n_before=$(inbox_n)
"$FLEET" gate post 1 --slug "ghost-thing" --summary "s" -d dNOSUCH --park >/dev/null 2>&1; rc5=$?
n_after=$(inbox_n)
if [ "$n_after" = "$n_before" ] && [ "$rc5" != 0 ]; then
  pass "4 a park that CANNOT succeed posts no inbox message (rc=$rc5)"
else
  fail "4 a failed park writes no inbox message" \
       "messages $n_before -> $n_after rc=$rc5 — a message with no park is the invisible half: reap will take the worktree"; fi
# The positive twin: the ordinary path must still do BOTH. Reordering that silently
# broke posting would satisfy case 4 perfectly.
DOK="$FLEET_ROOT/.fleet/dispatch/d11"; mkdir -p "$DOK"
m_before=$(inbox_n)
"$FLEET" gate post 1 --slug "ok-thing" --summary "s" -d d11 --park >/dev/null 2>&1; rc5b=$?
m_after=$(inbox_n)
if [ "$rc5b" = 0 ] && [ "$m_after" -gt "$m_before" ] && [ "$(mget "$DOK" state)" = gate1-wait ] \
   && [ -f "$DOK/GATE-1.md" ]; then
  pass "5 the ordinary path still posts the message AND parks"
else
  fail "5 the ordinary post+park path still works" \
       "rc=$rc5b messages $m_before -> $m_after state='$(mget "$DOK" state)'"; fi

# --- 6. B-6: a re-post leaves no stale decision file --------------------------
# The zero-concurrency instance of the split-brain: `gate_write_artifact` clears the
# decision KEYS on a re-post but left `decision-<N>.txt` on disk. The dispatch is then
# undecided in the ledger with a decision artifact beside it — and if the keys are
# later half-written, `gate_deliver` bails at `[ -n "$dec" ]` forever: PARKED FOREVER,
# silently. A lock on meta.tsv cannot fix this; two files are not one transaction.
"$FLEET" gate approve d11 >/dev/null 2>&1
had_decision=$([ -f "$DOK/decision-1.txt" ] && echo yes || echo no)
"$FLEET" gate post 1 --slug "ok-thing" --summary "s2" -d d11 --park >/dev/null 2>&1
if [ "$had_decision" != yes ]; then
  fail "6 VACUITY GUARD: no decision file was ever written" "approve did not produce decision-1.txt"
elif [ ! -f "$DOK/decision-1.txt" ] && [ -z "$(mget "$DOK" decision)" ]; then
  pass "6 a re-posted gate clears the decision KEYS and the decision FILE together"
else
  fail "6 a re-post leaves no stale decision file" \
       "decision-1.txt=$([ -f "$DOK/decision-1.txt" ] && echo present || echo gone) key='$(mget "$DOK" decision)' — a stale artifact beside an empty key is the parked-forever split-brain"; fi

# --- 7. B-7: GATE 3 gets its audit stamp --------------------------------------
D12="$FLEET_ROOT/.fleet/dispatch/d12"; mkdir -p "$D12"
"$FLEET" gate post 3 --slug "third-gate" --summary "s" -d d12 --park >/dev/null 2>&1
MSG=$(grep -ls 'FLEET-GATE:3' "$FLEET_ROOT"/.fleet/inbox/*.msg 2>/dev/null | head -1)
if [ -z "$MSG" ]; then
  fail "7 VACUITY GUARD: no gate-3 inbox message to pop" "gate post 3 --park produced no message"
else
  "$FLEET" gate popped "$MSG" >/dev/null 2>&1
  if [ -n "$(mget "$D12" gate3_popped)" ]; then
    pass "7 popping a GATE 3 message writes its audit stamp"
  else
    fail "7 GATE 3 gets an audit stamp on pop" \
         "gate3_popped empty (gate1_popped='$(mget "$D12" gate1_popped)') — the enum still says 1|2, and gate 3 is the gate this slice ADDED"; fi
fi

# --- 8. B-4: --gate is reconciled against the parked state --------------------
# Same unsafe-advance class as the courier's false confirm: it records a decision
# against the WRONG gate, which the courier then faithfully delivers — un-parking a
# gate the human never saw.
D13="$FLEET_ROOT/.fleet/dispatch/d13"; mkdir -p "$D13"
"$FLEET" gate post 1 --slug "two-gates" --summary "s" -d d13 >/dev/null 2>&1
"$FLEET" gate post 3 --slug "two-gates" --summary "s" -d d13 --park >/dev/null 2>&1
"$FLEET" gate approve d13 --gate 1 >/dev/null 2>&1; rc8=$?
if [ "$rc8" != 0 ] && [ -z "$(mget "$D13" decision)" ] && [ ! -f "$D13/decision-1.txt" ] \
   && [ "$(mget "$D13" state)" = gate3-wait ]; then
  pass "8 --gate 1 is REFUSED while parked at gate 3 (rc=$rc8, nothing written)"
else
  fail "8 --gate is reconciled against the parked state" \
       "rc=$rc8 decision='$(mget "$D13" decision)' decision_gate='$(mget "$D13" decision_gate)' file=$([ -f "$D13/decision-1.txt" ] && echo written || echo none) — a decision recorded against a gate the human never saw"; fi
# CONTROL: the gate that IS parked must still be decidable by explicit --gate.
"$FLEET" gate approve d13 --gate 3 >/dev/null 2>&1; rc8b=$?
if [ "$rc8b" = 0 ] && [ "$(mget "$D13" decision_gate)" = 3 ]; then
  pass "8b CONTROL: --gate 3 (the parked gate) is still accepted"
else
  fail "8b --gate 3 is still accepted" \
       "rc=$rc8b decision_gate='$(mget "$D13" decision_gate)' — the guard is too wide and blocks legitimate explicit gates"; fi

# --- 9/10/11. B4: gate 2 asks for the slug, or refuses ------------------------
# The promise made twice in the approved plan: at gate 2 approving shows the merge
# preview and makes the human type the slug back. A tty-GATED prompt that silently
# proceeds when there is no tty makes that promise a lie in exactly the case that
# matters, so no-tty + no --yes must fail LOUDLY. `--yes` is the explicit, auditable
# escape hatch; the absence of a terminal is not consent. (The courier never calls
# gate_decide — it delivers an already-recorded decision — so this costs it nothing.)
D14="$FLEET_ROOT/.fleet/dispatch/d14"; mkdir -p "$D14"
"$FLEET" gate post 2 --slug "ship-thing" --summary "s" -d d14 --park >/dev/null 2>&1
if [ "$(mget "$D14" state)" != gate2-wait ]; then
  fail "9 VACUITY GUARD: gate 2 did not park" "state='$(mget "$D14" state)'"
else
  "$FLEET" gate approve d14 </dev/null >/dev/null 2>&1; rc9=$?
  if [ "$rc9" = 2 ] && [ -z "$(mget "$D14" decision)" ] && [ ! -f "$D14/decision-2.txt" ]; then
    pass "9 gate 2 approve with no tty and no --yes REFUSES (rc 2, nothing written)"
  else
    fail "9 gate 2 approve refuses without a tty or --yes" \
         "rc=$rc9 decision='$(mget "$D14" decision)' file=$([ -f "$D14/decision-2.txt" ] && echo written || echo none) — the slug prompt silently did not happen, which is the same as not building it"; fi
  "$FLEET" gate approve d14 --yes </dev/null >/dev/null 2>&1; rc10=$?
  if [ "$rc10" = 0 ] && [ "$(mget "$D14" decision)" = approve ] && [ "$(mget "$D14" decision_gate)" = 2 ]; then
    pass "10 --yes is the explicit escape hatch and proceeds"
  else
    fail "10 --yes proceeds" "rc=$rc10 decision='$(mget "$D14" decision)' gate='$(mget "$D14" decision_gate)'"; fi
fi
# 11. gates 1 and 3 gained no friction — the confirmation is gate-2 only.
D15="$FLEET_ROOT/.fleet/dispatch/d15"; mkdir -p "$D15"
"$FLEET" gate post 1 --slug "plain-thing" --summary "s" -d d15 --park >/dev/null 2>&1
"$FLEET" gate approve d15 </dev/null >/dev/null 2>&1; rc11=$?
D16="$FLEET_ROOT/.fleet/dispatch/d16"; mkdir -p "$D16"
"$FLEET" gate post 3 --slug "plain-three" --summary "s" -d d16 --park >/dev/null 2>&1
"$FLEET" gate approve d16 </dev/null >/dev/null 2>&1; rc11b=$?
if [ "$rc11" = 0 ] && [ "$(mget "$D15" decision)" = approve ] \
   && [ "$rc11b" = 0 ] && [ "$(mget "$D16" decision)" = approve ]; then
  pass "11 gates 1 and 3 approve headlessly, unchanged"
else
  fail "11 gates 1 and 3 are unaffected" \
       "gate1 rc=$rc11 decision='$(mget "$D15" decision)'; gate3 rc=$rc11b decision='$(mget "$D16" decision)' — the gate-2 confirmation leaked into every gate"; fi

# --- 12. B3.3/B-8: a broken ledger makes gate_decide DIE, not shrug -----------
# `meta_set` used to return 0 unconditionally, so a truncated/unwritable meta.tsv
# left `fleet gate approve` reporting SUCCESS with no decision recorded — silent
# failure in the ONE verb deliberately built to die loudly. The lock is held from
# outside with a zero wait, so the decision FILE still writes and only the ledger
# write fails: that is the exact split this case is about.
D17="$FLEET_ROOT/.fleet/dispatch/d17"; mkdir -p "$D17"
"$FLEET" gate post 1 --slug "broken-ledger" --summary "s" -d d17 --park >/dev/null 2>&1
( flock -x 9; sleep 6 ) 9>>"$D17/.meta.lock" &
HOLDER=$!
sleep 0.3
FLEET_META_LOCK_WAIT=0 "$FLEET" gate approve d17 </dev/null >/dev/null 2>&1; rc12=$?
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
if [ "$rc12" = 0 ]; then
  fail "12 a broken ledger makes gate_decide die" \
       "rc=0 with decision='$(mget "$D17" decision)' — the human is told they approved and walks away"
elif [ -f "$D17/decision-1.txt" ]; then
  # It must not die leaving the ARTIFACT behind: decision-<N>.txt with no ledger key
  # is precisely the split-brain B-6 closes, manufactured by the branch that just
  # told the human "NOT decided". Asserting only rc != 0 is green against that.
  fail "12b a loud failure leaves NO decision artifact behind" \
       "rc=$rc12 but decision-1.txt is on disk with key='$(mget "$D17" decision)' — undeliverable-but-decided-looking, i.e. parked forever"
else
  pass "12 gate approve fails LOUDLY and leaves no artifact when the ledger cannot be written (rc=$rc12)"; fi

# --- 13. a park whose ledger write FAILS posts no message ---------------------
# B5's de-swallow is only half: `gate_park` reporting success after LOSING the one
# write that IS the park would still let gate_post go on to inbox_put — the invisible
# message-with-no-park half, where reap eats the worktree. Case 4 exercises only the
# `die` path (no such dispatch), so it is green against an unchecked write.
D18="$FLEET_ROOT/.fleet/dispatch/d18"; mkdir -p "$D18"
( flock -x 9; sleep 6 ) 9>>"$D18/.meta.lock" &
HOLDER2=$!
sleep 0.3
p_before=$(inbox_n)
FLEET_META_LOCK_WAIT=0 "$FLEET" gate post 1 --slug "unparkable" --summary "s" -d d18 --park >/dev/null 2>&1; rc13=$?
p_after=$(inbox_n)
kill "$HOLDER2" 2>/dev/null; wait "$HOLDER2" 2>/dev/null
if [ "$rc13" != 0 ] && [ "$p_after" = "$p_before" ]; then
  pass "13 a park whose ledger write fails posts NO message (rc=$rc13)"
else
  fail "13 a park that cannot record itself posts no message" \
       "rc=$rc13 messages $p_before -> $p_after state='$(mget "$D18" state)' — the park reported success without recording, and the message went out anyway"; fi

# --- 14. an un-park that cannot be recorded leaves it PARKED ------------------
# The tear the courier must never leave: un-parked AND undelivered. In that state
# every reap/reconcile guard is off while fleetd re-Popens the courier every 2s and
# re-pastes the same approval. Whichever ledger write fails, the dispatch must end up
# on the parked side, never the running-but-undelivered one.
#
# HONEST LIMIT: this case is an INVARIANT PIN, not a discriminator. Holding the lock
# fails the FIRST un-park write (`state running`), which was already guarded, so it
# is green against the unchecked `delivered 1` too — reaching that write's failure
# needs the lock to be taken and released mid-sequence, i.e. timing this harness
# cannot make deterministic. The rollback on `delivered` is code-review-verified, not
# proven here. Say so rather than let a green run imply cover it does not have.
D19="$FLEET_ROOT/.fleet/dispatch/d19"; mkdir -p "$D19"
tmux new-window -d -t "=$FLEET_SESSION" -n "so-d19" 'cat' 2>/dev/null; sleep 0.3
WID19=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
        | awk '$2=="so-d19"{print $1; exit}')
printf 'window_id\t%s\nwindow\tso-d19\n' "$WID19" >> "$D19/meta.tsv"
"$FLEET" gate post 1 --slug "tear-thing" --summary "s" -d d19 --park >/dev/null 2>&1
"$FLEET" gate approve d19 >/dev/null 2>&1
P19=$(tmux list-panes -t "$WID19" -F '#{pane_id}' 2>/dev/null | head -1)
tmux set -w -t "$P19" @agent_state working 2>/dev/null
( flock -x 9; sleep 8 ) 9>>"$D19/.meta.lock" &
HOLDER3=$!
sleep 0.3
FLEET_META_LOCK_WAIT=0 FLEET_WAKE_CONFIRM=2 "$FLEET" gate deliver d19 >/dev/null 2>&1; rc14=$?
st14=$(mget "$D19" state); dl14=$(mget "$D19" delivered)
kill "$HOLDER3" 2>/dev/null; wait "$HOLDER3" 2>/dev/null
if [ "$st14" = running ] && [ "$dl14" != 1 ]; then
  fail "14 a failed un-park never leaves running-but-undelivered" \
       "state='$st14' delivered='$dl14' rc=$rc14 — un-parked with nothing recorded: the guards are off and fleetd will re-paste every 2s"
elif [ "$dl14" = 1 ] || [ "$st14" = gate1-wait ]; then
  pass "14 a ledger failure during the un-park leaves it PARKED, never half-way (state='$st14')"
else
  fail "14 a failed un-park leaves it parked" "state='$st14' delivered='$dl14' rc=$rc14"; fi

# --- 15. a courier that cannot take its lock does not report success ----------
# `exec 9>>… || true` + `flock … 2>/dev/null || return 0` collapsed real contention,
# a bad fd, and flock-not-installed into one silent rc 0 — and two of those three
# would have the courier return 0 on every 2s tick forever without ever stamping
# `delivered`: a recorded decision parked forever, the class this round closes.
D20="$FLEET_ROOT/.fleet/dispatch/d20"; mkdir -p "$D20"
printf 'window\tso-d20-gone\n' >> "$D20/meta.tsv"
"$FLEET" gate post 1 --slug "lockless" --summary "s" -d d20 --park >/dev/null 2>&1
"$FLEET" gate approve d20 >/dev/null 2>&1
chmod 555 "$D20" 2>/dev/null                      # the lock file cannot be created
"$FLEET" gate deliver d20 >/dev/null 2>&1; rc15=$?
chmod 755 "$D20" 2>/dev/null
if [ "$rc15" != 0 ] && [ "$(mget "$D20" delivered)" != 1 ]; then
  pass "15 a courier that cannot open its lock reports FAILURE, not silent success (rc=$rc15)"
else
  fail "15 a courier that cannot lock does not report success" \
       "rc=$rc15 delivered='$(mget "$D20" delivered)' — rc 0 with nothing delivered makes an undeliverable decision look handled forever"; fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

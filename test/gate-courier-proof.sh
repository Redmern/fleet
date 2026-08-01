#!/usr/bin/env bash
# Proof harness — S2: THE COURIER (d34).
#
# THE BUG IT CLOSES. `ledger_parked` enumerates gate1-wait|gate2-wait|gate3-wait and
# NO WRITER EVER CLEARS THEM. `parked_at` and `gate<N>_popped` are labelled in the
# source as "AUDIT FACT, NOT A GATE" and deliberately do not un-park. So a dispatch
# that reaches a gate stays parked forever: reconcile-exempt and reap-refused, by
# design, with nothing in the system able to say "the human answered".
#
# THE DESIGN. The decision (S1) is written but NOT delivered. A courier — one check
# on fleetd's existing 2s cadence, with ALL the logic in bash — pastes the decision
# into the sub-orch's harness pane and un-parks ONLY on CONFIRMED landing.
#
# THE TRAP THIS PROOF EXISTS FOR. `wake_confirmed` infers landing from the pane
# going `working` — and A HUMAN TYPING IN THAT PANE PRODUCES EXACTLY THE SAME
# SIGNAL. If the courier accepted that, a human who happened to be mid-prompt when
# the sweep fired would un-park a dispatch that never received anything, dropping
# both the reap guard and the reconcile exemption on live gated work. So confirmation
# additionally requires THE COURIER'S OWN SENTINEL to be visible in the pane.
# Case 4 is that assertion and it is the highest-value case in this file.
#
# Cases:
#   1. an undecided dispatch is not delivered (nothing to deliver)
#   2. a decided dispatch is delivered: the sentinel reaches the harness pane
#   3. ...and ONLY THEN is it un-parked, with delivered=1 stamped
#   4. A HUMAN TYPING IS NOT A DELIVERY: pane goes `working` but the sentinel never
#      arrives => still parked, delivered unset
#   5. a failed delivery (no pane at all) leaves it parked and stamps an attempt
#   6. the courier NEVER splices into a half-typed prompt: input state `draft`
#      defers instead of pasting
#   7. delivery is idempotent — a delivered decision is not re-pasted
#   8. backoff does not spin: consecutive immediate calls do not re-attempt
#   9. a dead sub-orch pane escalates ONCE (one-shot), not on every sweep
#  10. the fleetd trigger exists, shells out to bash, and adds no parsing to fleetd
#  11. the viewer pane is never the delivery target
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"
FLEETD="$HERE/bin/fleetd"

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
export FLEET_SESSION="gc_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"
export FLEET_WAKE_CONFIRM=2          # keep the confirm window short in the harness
cleanup() { command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

echo "== d34 S2 — gate courier proof"
if bash -n "$FLEET" 2>/dev/null; then pass "0 bin/fleet parses"; else
  fail "0 bin/fleet parses" "$(bash -n "$FLEET" 2>&1 | head -3)"; fi
if python3 -c "import py_compile,sys; py_compile.compile('$FLEETD', doraise=True)" 2>/dev/null; then
  pass "0b bin/fleetd compiles"
else
  fail "0b bin/fleetd compiles" "$(python3 -c "import py_compile;py_compile.compile('$FLEETD',doraise=True)" 2>&1 | tail -2)"; fi

tmux new-session -d -s "$FLEET_SESSION" -n main 'sleep 9999' 2>/dev/null
sleep 0.3

# A fake harness pane: `cat` echoes whatever is pasted into it, so "did the sentinel
# reach the pane" is answerable by capture-pane — the same question the courier asks.
mk_suborch() { # <id> <slug-text> -> dispatch dir
  local id="$1" text="$2" d wn w
  d="$FLEET_ROOT/.fleet/dispatch/$id"; mkdir -p "$d"
  wn="so-$id"
  tmux new-window -d -t "=$FLEET_SESSION" -n "$wn" 'cat' 2>/dev/null
  sleep 0.2
  w=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk -v n="$wn" '$2==n{print $1; exit}')
  printf 'window_id\t%s\n' "$w" >> "$d/meta.tsv"
  "$FLEET" dispatch rename "$id" "$text" >/dev/null 2>&1
  local slug; slug=$("$FLEET" slug "$text" 2>/dev/null)
  "$FLEET" gate post 1 --slug "$slug" --summary "s" -d "$id" --park >/dev/null 2>&1
  printf '%s\n' "$d"
}

# --- 1. undecided => nothing delivered ----------------------------------------
D1=$(mk_suborch d1 "First Thing")
"$FLEET" gate deliver d1 >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ] && [ -z "$(mget "$D1" delivered)" ] && [ "$(mget "$D1" state)" = gate1-wait ]; then
  undecided_ok=1
else
  undecided_ok=0
  fail "1 an undecided dispatch is not delivered" \
       "rc=$rc delivered='$(mget "$D1" delivered)' state='$(mget "$D1" state)'"; fi
# The POSITIVE TWIN lands in case 2/3 below, on THIS fixture: the same call, on the
# same dispatch, must deliver once it IS decided. Without it "not delivered" is
# satisfied by a courier that never delivers anything — the vacuity pattern this
# round exists to remove. Case 1 only claims a pass once its twin has run.

# --- 2/3. decided => delivered, THEN un-parked --------------------------------
"$FLEET" gate approve d1 >/dev/null 2>&1
parked_after_decide=$(mget "$D1" state)
PANE=$(tmux list-panes -t "=$FLEET_SESSION:so-d1" -F '#{pane_id}' 2>/dev/null | head -1)
# The confirmation the courier looks for is the agent going `working`; simulate the
# harness's own hook doing that, since there is no real claude in this window.
( sleep 1; tmux set -w -t "$PANE" @agent_state working 2>/dev/null ) &
"$FLEET" gate deliver d1 >/dev/null 2>&1; rc=$?
wait 2>/dev/null
cap=$(tmux capture-pane -p -t "$PANE" 2>/dev/null)
if printf '%s' "$cap" | grep -q 'FLEET-GATE:1'; then
  pass "2 the decision sentinel reaches the sub-orch's harness pane"
else
  fail "2 the decision reaches the harness pane" "pane shows: $(printf '%s' "$cap" | tr '\n' '|' | head -c 200)"; fi
if [ "$parked_after_decide" = gate1-wait ] && [ "$(mget "$D1" delivered)" = 1 ] \
   && ! "$FLEET" gate waiting 2>/dev/null | grep -q "so-d1$"; then
  pass "3 un-parked ONLY after confirmed landing (delivered=1, off the parked list)"
  delivered_twin=1
else
  delivered_twin=0
  fail "3 un-parked only after confirmed landing" \
       "state-at-decision='$parked_after_decide' delivered='$(mget "$D1" delivered)' state='$(mget "$D1" state)' waiting='$("$FLEET" gate waiting 2>/dev/null | tr '\n' ' ')'"; fi
# Case 1's verdict, now that its positive twin has run on the same fixture.
if [ "$undecided_ok" = 1 ] && [ "$delivered_twin" = 1 ]; then
  pass "1 an undecided dispatch is not delivered and stays parked (twin: the same call DOES deliver once decided)"
elif [ "$undecided_ok" = 1 ]; then
  fail "1 an undecided dispatch is not delivered" \
       "the negative held but its positive twin did not — 'nothing was delivered' is satisfied by a courier that delivers nothing"; fi

# --- 4c. CONTROL: a GENUINE landing into an already-`working` pane must confirm -
# The counterweight to 4b. `gate_landed` deliberately has NO transition requirement:
# 5/5 real landings were measured into a pane that was ALREADY `working`, so a
# confirmation that demanded idle->working would reject genuine deliveries. This case
# fails if the fix over-corrects; 4b fails if it under-corrects. Both or neither.
D2C=$(mk_suborch d2c "Third Thing")
"$FLEET" gate approve d2c >/dev/null 2>&1
P2C=$(tmux list-panes -t "=$FLEET_SESSION:so-d2c" -F '#{pane_id}' 2>/dev/null | head -1)
tmux set -w -t "$P2C" @agent_state working 2>/dev/null    # already busy BEFORE we send
"$FLEET" gate deliver d2c >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ "$(mget "$D2C" delivered)" = 1 ] && [ "$(mget "$D2C" state)" != gate1-wait ]; then
  pass "4c CONTROL — a genuine landing into an ALREADY-working pane still confirms"
else
  fail "4c a genuine landing into an already-working pane still confirms" \
       "rc=$rc delivered='$(mget "$D2C" delivered)' state='$(mget "$D2C" state)' — the confirmation over-corrected and now rejects real deliveries"; fi

# --- 4e. LINE WRAP: a narrow pane must not false-NEGATIVE ----------------------
# `capture-pane -p` returns the pane as DRAWN, so on a pane narrower than the
# sentinel the marker is split across two physical lines and `grep -cF` finds 0 — a
# genuine landing reads as a failure, `delivered` is never stamped, and the courier
# RE-PASTES the same approval every backoff tick (2 deliveries measured from one
# approval). At gate 2 that double-spawns SHIP workers and the second delivery's
# decoupled Enter fires against whatever is in the pane. `-J` joins wrapped lines
# while preserving line structure, so `grep -c` stays the right primitive.
# Sub-orch splits are routinely under 60 columns; the real sentinel is ~66 chars.
D2E=$(mk_suborch d2e "Narrow Pane Thing")
"$FLEET" gate approve d2e >/dev/null 2>&1
# Resolve through the LEDGER's window name, never the spawn name: `dispatch rename`
# appends the slug, so an exact match on `so-d2e` resolves nothing and `-t ""` then
# silently retargets the CURRENT window — which is how this case first "passed" while
# resizing and probing a pane the courier never touched.
WN2E=$(mget "$D2E" window); [ -n "$WN2E" ] || WN2E=so-d2e
W2E=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk -v n="$WN2E" '$2==n{print $1; exit}')
tmux set -w -t "$W2E" window-size manual 2>/dev/null
tmux resize-window -t "$W2E" -x 34 -y 20 2>/dev/null
sleep 0.3
P2E=$(tmux list-panes -t "$W2E" -F '#{pane_id}' 2>/dev/null | head -1)
WID2E=$(tmux display -p -t "$P2E" '#{pane_width}' 2>/dev/null)
SENT2E=$(sed -n 1p "$D2E/decision-1.txt" 2>/dev/null)
( sleep 1; tmux set -w -t "$P2E" @agent_state working 2>/dev/null ) &
"$FLEET" gate deliver d2e >/dev/null 2>&1; rc=$?
wait 2>/dev/null
# VACUITY GUARD: the case means nothing unless the pane really is narrower than the
# sentinel — otherwise there is no wrap and `-J` is not what made it pass.
if [ "${WID2E:-999}" -ge "${#SENT2E}" ]; then
  fail "4e VACUITY GUARD: the pane is not narrow enough to wrap the sentinel" \
       "pane_width=$WID2E sentinel=${#SENT2E} chars — resize-window did not take, so nothing wrapped"
elif [ "$rc" = 0 ] && [ "$(mget "$D2E" delivered)" = 1 ]; then
  pass "4e a genuine landing on a ${WID2E}-col pane (${#SENT2E}-char sentinel) confirms — no wrap false-negative"
else
  fail "4e a wrapped sentinel is still a landing" \
       "rc=$rc delivered='$(mget "$D2E" delivered)' pane_width=$WID2E sentinel=${#SENT2E} — a real delivery read as a failure, so the courier will re-paste this approval every backoff tick"; fi

# --- 4f. B1.4: two concurrent couriers paste EXACTLY ONCE ----------------------
# fleetd `Popen`s a fresh `fleet gate deliver` every 2s with no in-flight dedup,
# while gate_deliver itself blocks >=6s inside gate_landed. The overlap is not a
# corner case, it is EVERY delivery whose confirm window exceeds the tick. Two
# deliveries of one approval double-spawn SHIP workers at gate 2, and the second
# one's decoupled `send-keys Enter` fires 0.4s later against whatever is in the pane
# — which can be a human's half-written draft, submitting it. That breaks the
# never-clobber property directly, which is why this is blocker-class, not residue.
D2F="$FLEET_ROOT/.fleet/dispatch/d2f"; mkdir -p "$D2F"
"$FLEET" dispatch rename d2f "Concurrent Thing" >/dev/null 2>&1
SLUG2F=$("$FLEET" slug "Concurrent Thing" 2>/dev/null)
"$FLEET" gate post 1 --slug "$SLUG2F" --summary "s" -d d2f --park >/dev/null 2>&1
"$FLEET" gate approve d2f >/dev/null 2>&1
SENT2F=$(sed -n 1p "$D2F/decision-1.txt" 2>/dev/null)
# ONE LINE PER PASTE. A plain `cat` pane renders each paste TWICE — the tty echoes it
# and then `cat` writes it back — so a count of 2 is one delivery, not two, and the
# case would report a double delivery that never happened. `stty -echo` leaves `cat`
# as the only writer, making the count a true delivery count.
WN2F=$(mget "$D2F" window); [ -n "$WN2F" ] || WN2F=so-d2f
tmux new-window -d -t "=$FLEET_SESSION" -n "$WN2F" 'stty -echo 2>/dev/null; cat' 2>/dev/null
sleep 0.4
W2F=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk -v n="$WN2F" '$2==n{print $1; exit}')
P2F=$(tmux list-panes -t "$W2F" -F '#{pane_id}' 2>/dev/null | head -1)
pre2f=$(tmux capture-pane -p -J -t "$P2F" 2>/dev/null | grep -cF -- "$SENT2F")
# THE OVERLAP IS MADE DETERMINISTIC, exactly as fleetd produces it: the pane goes
# `working` late, so the first courier is still blocked inside gate_landed when the
# second fires — which is every delivery whose confirm window exceeds the 2s tick.
# Two racing `&`s with nothing holding the first inside its window can finish before
# they overlap at all, and then the case discriminates nothing (measured: it passed
# against the unlocked code).
( sleep 3; tmux set -w -t "$P2F" @agent_state working 2>/dev/null ) &
FLEET_WAKE_CONFIRM=8 "$FLEET" gate deliver d2f >/dev/null 2>&1 &
sleep 0.8
FLEET_WAKE_CONFIRM=8 "$FLEET" gate deliver d2f >/dev/null 2>&1 &
wait 2>/dev/null
sleep 0.6
post2f=$(tmux capture-pane -p -J -t "$P2F" 2>/dev/null | grep -cF -- "$SENT2F")
added2f=$((post2f - pre2f))
if [ "$added2f" = 1 ]; then
  pass "4f two concurrent couriers paste EXACTLY ONCE (a second courier goes home)"
elif [ "$added2f" = 0 ]; then
  fail "4f VACUITY GUARD: neither courier pasted" \
       "pre=$pre2f post=$post2f — 'at most one paste' is satisfied by zero pastes; this case must observe a real delivery"
else
  fail "4f two concurrent couriers paste exactly once" \
       "$added2f pastes reached the pane (pre=$pre2f post=$post2f) — the undeduped fleetd Popen overlap delivers the same approval twice"; fi

# --- 4. THE HEADLINE: a human typing is not a delivery ------------------------
# The pane goes `working` — exactly what wake_confirmed keys on — but the sentinel
# never arrives, because the paste is made to fail. Un-parking here would drop the
# reap guard and the reconcile exemption on live gated work.
D2=$(mk_suborch d2 "Second Thing")
"$FLEET" gate approve d2 >/dev/null 2>&1
P2=$(tmux list-panes -t "=$FLEET_SESSION:so-d2" -F '#{pane_id}' 2>/dev/null | head -1)
tmux set -w -t "$P2" @agent_state working 2>/dev/null      # the human is typing
rm -f "$D2/decision-1.txt"                                  # make the paste impossible
"$FLEET" gate deliver d2 >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ] && [ "$(mget "$D2" delivered)" != 1 ] && [ "$(mget "$D2" state)" = gate1-wait ]; then
  pass "4 A HUMAN TYPING IS NOT A DELIVERY — pane 'working' but no sentinel => still parked"
else
  fail "4 a human typing is not a delivery" \
       "rc=$rc delivered='$(mget "$D2" delivered)' state='$(mget "$D2" state)' — the courier read a busy human as an answered gate"; fi

# --- 4b. THE REAL HEADLINE: a STALE sentinel is not a delivery -----------------
# Case 4 removes decision-<N>.txt, so the courier bails before it ever pastes — it
# proves the `working` half in isolation and CANNOT see the defect below.
#
# The sub-orch posted this gate from this very pane, so the sentinel is ALREADY in
# its own scrollback. Here the pane additionally cannot echo (`sleep` discards its
# stdin), so the paste provably does not land — yet the pane is `working`, exactly
# as a human typing leaves it. Against the absolute form of the sentinel test both
# conjuncts are true before a byte is sent: measured 20/20 false confirm, un-parking
# a gate the human never answered. Confirmation must be a DELTA against a baseline
# sampled before the paste.
D2B="$FLEET_ROOT/.fleet/dispatch/d2b"; mkdir -p "$D2B"
"$FLEET" dispatch rename d2b "Stale Thing" >/dev/null 2>&1
SLUG2B=$("$FLEET" slug "Stale Thing" 2>/dev/null)
"$FLEET" gate post 1 --slug "$SLUG2B" --summary "s" -d d2b --park >/dev/null 2>&1
"$FLEET" gate approve d2b >/dev/null 2>&1
SENT2B=$(sed -n 1p "$D2B/decision-1.txt" 2>/dev/null)
# The window must carry the name the LEDGER records — `dispatch rename` appends the
# slug, and the courier resolves its pane from `meta_get window`. Naming it `so-d2b`
# made the courier find NO pane and defer, so the case passed for the wrong reason:
# it never reached the confirmation it exists to test. (Caught by the vacuity guard
# below only after it was pointed at the real pane.)
WN2B=$(mget "$D2B" window); [ -n "$WN2B" ] || WN2B=so-d2b
# A pane that shows the sentinel and can never show another one: `stty -echo` so the
# tty driver does not render the paste, and `sleep` so nothing consumes it. Without
# the `stty` the tty echoes the pasted line and the sentinel count genuinely rises —
# the paste DID reach the pane — so the case would fail against the fix as well and
# discriminate nothing. This pane is the one shape where the sentinel is on screen
# and the delivery provably is not.
tmux new-window -d -t "=$FLEET_SESSION" -n "$WN2B" \
     "stty -echo 2>/dev/null; printf '%s\\n' \"$SENT2B\"; sleep 9999" 2>/dev/null
sleep 0.4
W2B=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk -v n="$WN2B" '$2==n{print $1; exit}')
printf 'window_id\t%s\n' "$W2B" >> "$D2B/meta.tsv"
P2B=$(tmux list-panes -t "=$FLEET_SESSION:$WN2B" -F '#{pane_id}' 2>/dev/null | head -1)
tmux set -w -t "$P2B" @agent_state working 2>/dev/null      # a live turn / a human typing
pre2b=$(tmux capture-pane -p -t "$P2B" 2>/dev/null | grep -cF -- "$SENT2B")
"$FLEET" gate deliver d2b >/dev/null 2>&1; rc=$?
if [ "${pre2b:-0}" -lt 1 ] || [ -z "$P2B" ]; then
  fail "4b VACUITY GUARD: the case never reached the confirmation" \
       "pre-count=$pre2b pane='$P2B' window='$WN2B' — a stale sentinel that is not on screen, or a pane the courier cannot resolve, makes this refuse for the WRONG reason"
elif [ "$rc" != 0 ] && [ "$(mget "$D2B" delivered)" != 1 ] && [ "$(mget "$D2B" state)" = gate1-wait ]; then
  pass "4b A STALE SENTINEL IS NOT A DELIVERY — sentinel on screen + pane 'working' => still parked"
else
  fail "4b a stale sentinel is not a delivery" \
       "rc=$rc delivered='$(mget "$D2B" delivered)' state='$(mget "$D2B" state)' pre-count=$pre2b — the courier confirmed a delivery that never landed and UN-PARKED an unanswered gate"; fi

# --- 5. no pane at all => parked, attempt stamped -----------------------------
D3="$FLEET_ROOT/.fleet/dispatch/d3"; mkdir -p "$D3"
printf 'window\tso-d3-ghost\n' >> "$D3/meta.tsv"
printf '[FLEET-GATE:1 slug=ghost action=implement]\nx\n' > "$D3/GATE-1.md"
"$FLEET" gate park d3 1 >/dev/null 2>&1
"$FLEET" gate approve d3 >/dev/null 2>&1
"$FLEET" gate deliver d3 >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ] && [ "$(mget "$D3" state)" = gate1-wait ] \
   && [ -n "$(mget "$D3" deliver_attempts)" ]; then
  pass "5 a failed delivery leaves it PARKED and records the attempt"
else
  fail "5 a failed delivery leaves it parked" \
       "rc=$rc state='$(mget "$D3" state)' attempts='$(mget "$D3" deliver_attempts)'"; fi

# --- 8. backoff does not spin -------------------------------------------------
a1=$(mget "$D3" deliver_attempts)
"$FLEET" gate deliver d3 >/dev/null 2>&1
a2=$(mget "$D3" deliver_attempts)
if [ "$a1" = "$a2" ]; then
  pass "8 backoff does not spin — an immediate re-call does not re-attempt"
else
  fail "8 backoff does not spin" "attempts $a1 -> $a2 on a back-to-back call"; fi

# --- 9. a dead sub-orch escalates ONCE ---------------------------------------
n1=$(ls -1 "$FLEET_ROOT"/.fleet/inbox/*.msg 2>/dev/null | grep -c .)
i=0; while [ $i -lt 6 ]; do
  printf 'deliver_after\t0\n' >> "$D3/meta.tsv"
  "$FLEET" gate deliver d3 >/dev/null 2>&1; i=$((i+1))
done
n2=$(ls -1 "$FLEET_ROOT"/.fleet/inbox/*.msg 2>/dev/null | grep -c .)
added9=$((n2 - n1))
# EXACTLY once, and the message must NAME the dispatch. `-le 1` was satisfied by
# `added 0` — i.e. by the silent-drop failure the case exists to catch — and it
# reported exactly that on a green run. A one-shot escalation that never fires is
# not one-shot, it is missing.
if [ "$added9" != 1 ]; then
  fail "9 a dead sub-orch escalates EXACTLY once" \
       "6 sweeps produced $added9 messages — 0 is the silent-drop failure, >1 fires on every 2s tick"
elif ls -1t "$FLEET_ROOT"/.fleet/inbox/*.msg 2>/dev/null | head -1 | xargs grep -lq 'd3' 2>/dev/null; then
  pass "9 a dead sub-orch escalates EXACTLY once, naming the dispatch (added $added9)"
else
  fail "9 the escalation names the dispatch" \
       "one message was added but its body does not carry 'd3' — the human cannot act on it"; fi

# --- 6. never splice into a half-typed prompt ---------------------------------
# orch_input_state reports `draft` when the last ❯ line has text after it. The
# courier must DEFER, not paste — the never-clobber guarantee.
D4=$(mk_suborch d4 "Fourth Thing")
"$FLEET" gate approve d4 >/dev/null 2>&1
P4=$(tmux list-panes -t "=$FLEET_SESSION:so-d4" -F '#{pane_id}' 2>/dev/null | head -1)
printf '❯ half typed prompt\n' | tmux load-buffer - 2>/dev/null
tmux paste-buffer -t "$P4" 2>/dev/null; sleep 0.4
"$FLEET" gate deliver d4 >/dev/null 2>&1; rc=$?
cap4=$(tmux capture-pane -p -J -t "$P4" 2>/dev/null)
if [ "$rc" != 0 ] && [ "$(mget "$D4" delivered)" != 1 ] \
   && ! printf '%s' "$cap4" | grep -q 'FLEET-GATE'; then
  defer_ok=1
else
  defer_ok=0
  fail "6 the courier defers on a half-typed prompt" \
       "rc=$rc delivered='$(mget "$D4" delivered)' — it pasted into a draft"; fi
# THE POSITIVE TWIN, on the SAME PANE. "It did not paste" is satisfied by a courier
# that never pastes; the deferral only means something if clearing the draft makes
# the very next call land. The draft is removed by respawning the same pane —
# `send-keys C-u` kills the tty's line buffer but leaves the echoed text on screen,
# and orch_input_state reads the SCREEN. Same pane id, same window, no draft.
tmux respawn-pane -k -t "$P4" 'cat' 2>/dev/null; sleep 0.5
printf 'deliver_after\t0\n' >> "$D4/meta.tsv"
( sleep 1; tmux set -w -t "$P4" @agent_state working 2>/dev/null ) &
"$FLEET" gate deliver d4 >/dev/null 2>&1; rc4b=$?
wait 2>/dev/null
if [ "$defer_ok" = 1 ] && [ "$rc4b" = 0 ] && [ "$(mget "$D4" delivered)" = 1 ]; then
  pass "6 the courier defers on a half-typed prompt, and lands once the draft is cleared"
elif [ "$defer_ok" = 1 ]; then
  fail "6 the deferral was caused by the DRAFT, not by an inert courier" \
       "the draft cleared and delivery still did not land (rc=$rc4b delivered='$(mget "$D4" delivered)')"; fi

# --- 7. idempotent ------------------------------------------------------------
# The checksum alone is satisfied by a dead function. Its positive content is that
# the pane was NOT re-pasted, so count the sentinel on screen across the second call
# — the real "did not re-deliver" question — and assert `delivered` still stands.
SENT1=$(sed -n 1p "$D1/decision-1.txt" 2>/dev/null)
before=$(md5sum < "$D1/meta.tsv")
pre7=$(tmux capture-pane -p -J -t "$PANE" 2>/dev/null | grep -cF -- "$SENT1")
"$FLEET" gate deliver d1 >/dev/null 2>&1; rc=$?
sleep 0.5
after=$(md5sum < "$D1/meta.tsv")
post7=$(tmux capture-pane -p -J -t "$PANE" 2>/dev/null | grep -cF -- "$SENT1")
if [ "${pre7:-0}" -lt 1 ]; then
  fail "7 VACUITY GUARD: the first delivery is not on screen" \
       "pre-count=$pre7 — 'the count did not rise' means nothing if the sentinel never arrived"
elif [ "$before" = "$after" ] && [ "$post7" = "$pre7" ] && [ "$(mget "$D1" delivered)" = 1 ]; then
  pass "7 a delivered decision is not re-pasted (ledger unchanged, pane count $pre7 -> $post7, still delivered)"
else
  fail "7 delivery is idempotent" \
       "meta-changed=$([ "$before" = "$after" ] && echo no || echo yes) pane $pre7 -> $post7 delivered='$(mget "$D1" delivered)'"; fi

# --- 10. the fleetd trigger ---------------------------------------------------
# fleetd must stay stdlib-only and gain NO gate parsing: it may only notice the
# ledger key and shell out. A regex over the ledger inside fleetd would be a second
# implementation of the grammar, in a second language, in the one process whose
# death takes the whole daemon down (it has no try/except around method dispatch).
if grep -q 'gate deliver' "$FLEETD"; then
  pass "10 fleetd triggers: fleet gate deliver (logic stays in bash)"
else
  fail "10 fleetd triggers the courier" "no 'gate deliver' shell-out in bin/fleetd"; fi
if grep -qE 'FLEET-GATE|action=(implement|merge|commit|revise)' "$FLEETD"; then
  fail "10b fleetd gained no gate grammar" \
       "fleetd now parses the sentinel — a second implementation in a second language"
else
  pass "10b fleetd gained no gate grammar (no sentinel parsing)"; fi
nonstd=$(python3 - "$FLEETD" <<'PY' 2>/dev/null
import ast, sys
names = set()
for node in ast.walk(ast.parse(open(sys.argv[1]).read())):
    if isinstance(node, ast.Import):
        names.update(a.name.split('.')[0] for a in node.names)
    elif isinstance(node, ast.ImportFrom) and node.module:
        names.add(node.module.split('.')[0])
print(' '.join(sorted(n for n in names if n not in sys.stdlib_module_names)))
PY
)
if [ -z "$nonstd" ]; then pass "10c fleetd stays stdlib-only"; else
  fail "10c fleetd stays stdlib-only" "non-stdlib imports: $nonstd"; fi

# --- 11. the viewer is never the delivery target ------------------------------
if command -v nvim >/dev/null 2>&1; then
  D5=$(mk_suborch d5 "Fifth Thing")
  W5=$(mget "$D5" window_id)
  "$FLEET" attach-viewer "$W5" "$D5" >/dev/null 2>&1; sleep 0.5
  "$FLEET" gate approve d5 >/dev/null 2>&1
  VP=$(tmux list-panes -t "$W5" -F $'#{pane_id}\t#{@fleet_viewer}' 2>/dev/null | awk -F'\t' '$2=="1"{print $1}')
  HP=$(tmux list-panes -t "$W5" -F $'#{pane_id}\t#{@fleet_viewer}' 2>/dev/null | awk -F'\t' '$2!="1"{print $1; exit}')
  ( sleep 1; tmux set -w -t "$HP" @agent_state working 2>/dev/null ) &
  "$FLEET" gate deliver d5 >/dev/null 2>&1
  wait 2>/dev/null
  vcap=$(tmux capture-pane -p -t "$VP" 2>/dev/null)
  hcap=$(tmux capture-pane -p -t "$HP" 2>/dev/null)
  if ! printf '%s' "$vcap" | grep -q 'FLEET-GATE' && printf '%s' "$hcap" | grep -q 'FLEET-GATE'; then
    pass "11 delivery targets the harness pane, never the viewer"
  else
    fail "11 delivery targets the harness pane, never the viewer" \
         "viewer-has-sentinel=$(printf '%s' "$vcap" | grep -c 'FLEET-GATE') harness-has=$(printf '%s' "$hcap" | grep -c 'FLEET-GATE')"; fi
else
  echo "  SKIP(11): nvim not installed"
fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

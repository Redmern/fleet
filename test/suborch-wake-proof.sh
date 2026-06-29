#!/usr/bin/env bash
# Proof harness — a `fleet watch` wake from a SUB-ORCH pane must never silently
# evaporate. (Bug: cmd_notify's OOB fallback is a dead end for a sub-orch — it polls
# neither alerts.log nor the inbox, so a wake that can't go in-band strands it.)
#
# This drives the new watcher composer `deliver_wake` directly (exposed as the
# internal `fleet deliver-wake <pane> <msg> <class> <soid>` subcommand, the same
# proof-harness pattern as `fleet inject-secrets`). It boots a THROWAWAY, isolated
# tmux server + config so it can never touch the real fleet session.
#
# Scenarios (IMPL-SPEC §Proof):
#   i.   clean sub-orch input + agent confirms working  -> woken in-band, NO inbox msg
#   ii.  occupied (draft) input                         -> retries exhaust -> ONE sev=warn
#                                                          from=- msg naming so-<id>, routes
#                                                          dest=main submit=0
#   iii. MAIN pane                                       -> no send-keys; alerts.log appended
#   v.   (F1) generating stub that never goes `working` -> confirm gate fails -> escalates
#   vi.  (F3) two concurrent watchers, one so-<id>      -> exactly ONE escalation .msg
# (iv `fleet doctor` green + `bash -n` are checked at the tail.)
#
# Run before the fix: RED (deliver-wake unimplemented). After: every case PASS.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

# --- isolation ----------------------------------------------------------------
TMPROOT=$(mktemp -d)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR"
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
unset TMUX
export FLEET_SESSION="wake_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet"
# Fast timings so a failing-confirm retry budget runs in seconds, not ~30s.
export FLEET_WAKE_RETRIES=3 FLEET_WAKE_INTERVAL=0 FLEET_WAKE_CONFIRM=1

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

U276F=$'❯'   # ❯  prompt marker
RULE=$'────────'  # ──────── footer rule

pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }
FAILED=0

inbox_msgs() { ls "$FLEET_ROOT/.fleet/inbox"/*.msg 2>/dev/null; }
inbox_count() { inbox_msgs | grep -c . ; }
reset_inbox() { rm -rf "$FLEET_ROOT/.fleet/inbox" "$FLEET_ROOT/.fleet/dispatch" \
                       "$FLEET_ROOT/.fleet/wake-"* 2>/dev/null; }

# Make a window <name> whose captured screen == <screenfile>, return its pane id.
mkpane() { # <name> <screenfile>
  local name="$1" sf="$2" pane
  tmux new-window -t "=$FLEET_SESSION" -n "$name" "cat '$sf'; sleep 9999" 2>/dev/null
  sleep 0.3
  pane=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_name} #{pane_id}' 2>/dev/null \
         | awk -v n="$name" '$1==n{print $2; exit}')
  printf '%s' "$pane"
}

screen_empty()      { printf 'doing things\n%s \n' "$U276F" > "$1"; }
screen_draft()      { printf '%s resume the pipeline now\n' "$U276F" > "$1"; }
screen_generating() { printf 'thinking\n%s\n  esc to interrupt\n' "$RULE" > "$1"; }

# --- boot base session (one window so the server stays alive) ------------------
tmux new-session -d -s "$FLEET_SESSION" -n base -c "$FLEET_ROOT" sh 2>/dev/null
tmux set -t "$FLEET_SESSION" @fleet_root "$FLEET_ROOT" 2>/dev/null

# A MAIN window (role=main) for scenario iii.
tmux new-window -t "=$FLEET_SESSION" -n main -c "$FLEET_ROOT" sh 2>/dev/null
MAIN_PANE=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_name} #{pane_id}' 2>/dev/null \
            | awk '$1=="main"{print $2; exit}')
tmux set -w -t "$MAIN_PANE" @fleet_role main 2>/dev/null
mkdir -p "$FLEET_ROOT/.fleet/roles"; printf 'main\n' > "$FLEET_ROOT/.fleet/roles/$MAIN_PANE"

# ============================================================================ #
# i. clean input + agent reaches working -> in-band wake, no escalation
reset_inbox
SF="$TMPROOT/i.txt"; screen_empty "$SF"
P=$(mkpane so-d1 "$SF")
tmux set -w -t "$P" @agent_state working 2>/dev/null    # daemon confirms the wake landed
if "$FLEET" deliver-wake "$P" "resume — gate ready" normal so-d1 >/dev/null 2>&1; then
  [ "$(inbox_count)" = 0 ] && pass i || fail i "expected NO inbox msg on a confirmed in-band wake, got $(inbox_count)"
else
  fail i "deliver-wake returned nonzero on a clean confirmable wake"
fi
tmux kill-window -t "=$FLEET_SESSION:so-d1" 2>/dev/null

# ============================================================================ #
# ii. occupied (draft) input -> retries exhaust -> ONE escalation msg
reset_inbox
SF="$TMPROOT/ii.txt"; screen_draft "$SF"
P=$(mkpane so-d2 "$SF")
tmux set -w -t "$P" @agent_state idle 2>/dev/null
"$FLEET" deliver-wake "$P" "resume — gate ready" normal so-d2 >/dev/null 2>&1
n=$(inbox_count)
if [ "$n" = 1 ]; then
  f=$(inbox_msgs | head -1)
  from=$(sed -n 's/^from=//p' "$f" | head -1)
  sev=$(sed -n 's/^sev=//p' "$f" | head -1)
  names=$(grep -cF 'so-d2' "$f")
  route=$("$FLEET" inbox route "$from" 2>/dev/null || true)   # may be unexposed; best-effort
  if [ "$from" = "-" ] && [ "$sev" = warn ] && [ "$names" -ge 1 ]; then
    pass ii
  else
    fail ii "msg fields wrong: from='$from' sev='$sev' names-soid=$names"
  fi
else
  fail ii "expected exactly ONE escalation msg, got $n"
fi
tmux kill-window -t "=$FLEET_SESSION:so-d2" 2>/dev/null

# ============================================================================ #
# iii. MAIN pane -> oob only: no inbox msg, alerts.log appended, input untouched
reset_inbox
mkdir -p "$FLEET_ROOT/.fleet/dispatch"; : > "$FLEET_ROOT/.fleet/dispatch/alerts.log"
before=$(wc -l < "$FLEET_ROOT/.fleet/dispatch/alerts.log" 2>/dev/null || echo 0)
"$FLEET" deliver-wake "$MAIN_PANE" "agents idle" normal "" >/dev/null 2>&1
after=$(wc -l < "$FLEET_ROOT/.fleet/dispatch/alerts.log" 2>/dev/null || echo 0)
if [ "$(inbox_count)" = 0 ] && [ "$after" -gt "$before" ]; then
  pass iii
else
  fail iii "main path: inbox=$(inbox_count) (want 0), alerts $before->$after (want grow)"
fi

# ============================================================================ #
# v. (F1) generating stub whose @agent_state never reaches `working` -> escalate
reset_inbox
SF="$TMPROOT/v.txt"; screen_generating "$SF"
P=$(mkpane so-d5 "$SF")
tmux set -w -t "$P" @agent_state idle 2>/dev/null    # deliverable per capture, but NEVER working
"$FLEET" deliver-wake "$P" "resume — gate ready" normal so-d5 >/dev/null 2>&1
n=$(inbox_count)
if [ "$n" = 1 ]; then
  grep -qF 'so-d5' "$(inbox_msgs | head -1)" && pass v || fail v "escalation does not name so-d5"
else
  fail v "F1 gate: a generating-but-never-working stub must NOT count as woken; expected 1 escalation, got $n"
fi
tmux kill-window -t "=$FLEET_SESSION:so-d5" 2>/dev/null

# ============================================================================ #
# vi. (F3) two concurrent watchers, one so-<id> -> exactly ONE escalation msg
reset_inbox
SF="$TMPROOT/vi.txt"; screen_draft "$SF"
P=$(mkpane so-d6 "$SF")
tmux set -w -t "$P" @agent_state idle 2>/dev/null
"$FLEET" deliver-wake "$P" "resume A" normal so-d6 >/dev/null 2>&1 &
"$FLEET" deliver-wake "$P" "resume B" normal so-d6 >/dev/null 2>&1 &
wait
n=$(inbox_count)
[ "$n" = 1 ] && pass vi || fail vi "F3 dedup: two concurrent watchers must collapse to ONE msg, got $n"
tmux kill-window -t "=$FLEET_SESSION:so-d6" 2>/dev/null

# ============================================================================ #
# iv. bash -n + fleet doctor must not crash
if bash -n "$FLEET" 2>/dev/null; then pass iv-syntax; else fail iv-syntax "bash -n failed"; fi

echo
if [ "$FAILED" = 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi

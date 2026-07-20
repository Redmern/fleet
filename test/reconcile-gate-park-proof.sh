#!/usr/bin/env bash
# Proof harness — `fleet reconcile` must never re-animate a dispatch that is
# deliberately PARKED at a human gate.
#
# The bug: cmd_reconcile's skip set was `done|failed|cancelled`. A sub-orch parked at
# `gate1-wait`/`gate2-wait` is neither terminal nor stranded — it is HALTED WAITING FOR
# A HUMAN — but reconcile saw "non-terminal + dead window" and respawned it, and the
# fresh sub-orch ran straight PAST the gate, doing work nobody authorised (4 of 5
# dispatches on 2026-07-19; one self-merged to main). `gate_waiting` (which `fleet reap`
# consults) already classified those two states as parked-leave-alone: two consumers of
# the same ledger, opposite conclusions.
#
# The fix must NOT swing to the opposite failure. Blanket-skipping a parked dispatch
# whose sub-orch pane has DIED strands the gate forever — nobody can pop it, silently.
# So: never revive a parked dispatch, but if it is parked AND dead, SURFACE it once
# (durable system-origin inbox escalation + dashboard alert), in the shape of
# wake_escalate. Never silently strand, never silently revive.
#
# Isolation (every rule below previously cost real damage):
#   * throwaway tmux server (TMUX_TMPDIR) + config (XDG_CONFIG_HOME) + runtime
#     (XDG_RUNTIME_DIR, or agents_tsv answers from the LIVE fleetd)
#   * FLEET_DEBUG_PORT set (a reap path runs `fuser -k 9222/tcp` = dev's Chromium)
#   * GIT_CONFIG_GLOBAL/SYSTEM=/dev/null, explicit -c user.email/-c user.name
#   * FLEET_ROOT + FLEET_SESSION always non-empty (fleet_root falls back to `pwd`,
#     so an unset root writes into the LIVE repo)
#   * the live `pc` session, the orchestrator pane and real worktrees are never touched
#
# RED TALLY BEFORE THE FIX (verified, 2026-07-20): cases 1, 2, 5, 5b FAIL (4 of 9) —
# reconcile respawns a parked dispatch (1: "respawns=1 window=spawned", 2: same) and
# never escalates an orphaned gate (5, 5b: 0 msgs). Cases 3, 4, 6, 7, 8 pass pre-fix:
# they pin behaviour that must NOT regress (crash recovery, terminal skip, abandon cap,
# parked+live no-op, syntax).
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

# --- isolation ----------------------------------------------------------------
TMPROOT=$(mktemp -d)
export TMUX_TMPDIR="$TMPROOT/tmuxsock";      mkdir -p "$TMUX_TMPDIR"
export XDG_CONFIG_HOME="$TMPROOT/config";    mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run";       mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export FLEET_DEBUG_PORT=59223
export FLEET_SESSION="rgp_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"

# A real binary named `claude` so tmux's #{pane_current_command} reads `claude` and
# is_harness_cmd() calls the pane LIVE (a shebang script would report `sh`).
mkdir -p "$TMPROOT/bin"
cp "$(command -v sleep)" "$TMPROOT/bin/claude" 2>/dev/null
CLAUDE_BIN="$TMPROOT/bin/claude"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=$((FAILED+1)); }
FAILED=0

LED="$FLEET_ROOT/.fleet/dispatch"
ALERTS="$LED/alerts.log"

inbox_msgs()  { ls "$FLEET_ROOT/.fleet/inbox"/*.msg 2>/dev/null; }
inbox_count() { inbox_msgs | grep -c . ; }
alerts_lines(){ wc -l < "$ALERTS" 2>/dev/null || echo 0; }

meta_get() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$LED/$1/meta.tsv" 2>/dev/null; }

# Seed one ledger entry. <id> <state> [respawns]
mkdispatch() {
  local id="$1" st="$2" n="${3:-0}"
  mkdir -p "$LED/$id"
  printf 'instruction\n' > "$LED/$id/instruction.txt"
  { printf 'state\t%s\n' "$st"
    printf 'window\tso-%s\n' "$id"
    printf 'respawns\t%s\n' "$n"; } > "$LED/$id/meta.tsv"
}

# A LIVE sub-orch window for <id>: foreground proc is `claude`, so suborch_live() is true.
mkwin() { # <id>
  tmux new-window -d -t "=$FLEET_SESSION" -n "so-$1" -c "$FLEET_ROOT" \
    "$CLAUDE_BIN" 9999 2>/dev/null
  sleep 0.3
}

# Any window named so-<id> in the visible session OR its hidden sibling (where
# cmd_new --scratch parks sub-orchs) — the evidence that a respawn was attempted.
win_exists() { # <id>
  local s
  for s in "$FLEET_SESSION" "${FLEET_SESSION}_hidden"; do
    tmux list-windows -t "=$s" -F '#{window_name}' 2>/dev/null \
      | grep -qx "so-$1" && return 0
  done
  return 1
}

reconcile() { PATH="$TMPROOT/bin:$PATH" "$FLEET" reconcile >/dev/null 2>&1; }

reset_state() { rm -rf "$LED" "$FLEET_ROOT/.fleet/inbox" 2>/dev/null; mkdir -p "$LED"; : > "$ALERTS"; }

# --- boot the throwaway session ------------------------------------------------
tmux new-session -d -s "$FLEET_SESSION" -n base -c "$FLEET_ROOT" sh 2>/dev/null
tmux set -t "$FLEET_SESSION" @fleet_root "$FLEET_ROOT" 2>/dev/null

echo "== reconcile-gate-park: a gate-parked dispatch is never re-animated =="

# ============================================================================ #
# 1. gate1-wait + dead window -> survives untouched (the case nothing covered)
reset_state
mkdispatch d1 gate1-wait 0
reconcile
st=$(meta_get d1 state); n=$(meta_get d1 respawns)
if [ "$st" = gate1-wait ] && [ "$n" = 0 ] && ! win_exists d1; then
  pass 1
else
  fail 1 "gate1-wait was re-animated: state='$st' (want gate1-wait) respawns='$n' (want 0) window=$(win_exists d1 && echo spawned || echo none)"
fi

# ============================================================================ #
# 2. gate2-wait + dead window -> survives untouched
reset_state
mkdispatch d2 gate2-wait 0
reconcile
st=$(meta_get d2 state); n=$(meta_get d2 respawns)
if [ "$st" = gate2-wait ] && [ "$n" = 0 ] && ! win_exists d2; then
  pass 2
else
  fail 2 "gate2-wait was re-animated: state='$st' respawns='$n' window=$(win_exists d2 && echo spawned || echo none)"
fi

# ============================================================================ #
# 3. genuinely CRASHED (non-terminal, NOT parked, dead window) -> still revived.
#    The existing recovery behaviour must not regress.
reset_state
mkdispatch d3 planning 0
FLEET_RECONCILE_CAP=5 PATH="$TMPROOT/bin:$PATH" "$FLEET" reconcile >/dev/null 2>&1
n=$(meta_get d3 respawns); st=$(meta_get d3 state)
if [ "$n" = 1 ] && [ "$st" = planning ]; then
  pass 3
else
  fail 3 "a crashed dispatch must still be re-animated: respawns='$n' (want 1) state='$st'"
fi

# ============================================================================ #
# 4. done|failed|cancelled -> still skipped
reset_state
mkdispatch d4a done 0; mkdispatch d4b failed 0; mkdispatch d4c cancelled 0
reconcile
ok=1
for id in d4a d4b d4c; do
  [ "$(meta_get "$id" respawns)" = 0 ] || ok=0
  win_exists "$id" && ok=0
done
[ "$ok" = 1 ] && pass 4 || fail 4 "a terminal dispatch was re-animated"

# ============================================================================ #
# 5. PARKED + DEAD pane -> NOT revived, but SURFACED: exactly one system-origin
#    (from=-) sev=warn inbox message naming so-<id>, plus a dashboard alert.
#    Silent skipping here would strand the gate forever — nobody can pop it.
reset_state
mkdispatch d5 gate1-wait 0
before=$(alerts_lines)
reconcile
after=$(alerts_lines); nmsg=$(inbox_count); n=$(meta_get d5 respawns)
if [ "$nmsg" = 1 ]; then
  f=$(inbox_msgs | head -1)
  from=$(sed -n 's/^from=//p' "$f" | head -1)
  sev=$(sed -n 's/^sev=//p' "$f" | head -1)
  names=$(grep -cF 'so-d5' "$f")
  if [ "$from" = "-" ] && [ "$sev" = warn ] && [ "$names" -ge 1 ] \
     && [ "$after" -gt "$before" ] && [ "$n" = 0 ] && ! win_exists d5; then
    pass 5
  else
    fail 5 "escalation malformed: from='$from' (want -) sev='$sev' (want warn) names-soid=$names alerts $before->$after respawns='$n'"
  fi
else
  fail 5 "parked+dead must escalate exactly ONE durable message, got $nmsg"
fi

# ============================================================================ #
# 5b. the escalation is ONE-SHOT: a second reconcile (the hook runs one per prompt)
#     must not spam a duplicate.
reconcile
nmsg=$(inbox_count)
[ "$nmsg" = 1 ] && pass 5b || fail 5b "repeat reconcile duplicated the gate-orphan escalation: $nmsg msgs"

# ============================================================================ #
# 6. respawn cap / abandon-after-N still works (non-parked, dead, no live workers)
reset_state
mkdispatch d6 planning 1
FLEET_RECONCILE_CAP=1 PATH="$TMPROOT/bin:$PATH" "$FLEET" reconcile >/dev/null 2>&1
st=$(meta_get d6 state)
[ "$st" = failed ] && pass 6 || fail 6 "abandon-after-N regressed: state='$st' (want failed)"

# ============================================================================ #
# 7. PARKED + LIVE pane -> untouched and NOT escalated (negative control: the
#    escalation must fire on gate-orphaning, not on every parked dispatch).
reset_state
mkdispatch d7 gate2-wait 0
mkwin d7
reconcile
st=$(meta_get d7 state); n=$(meta_get d7 respawns); nmsg=$(inbox_count)
if [ "$st" = gate2-wait ] && [ "$n" = 0 ] && [ "$nmsg" = 0 ]; then
  pass 7
else
  fail 7 "parked+live: state='$st' respawns='$n' inbox=$nmsg (want gate2-wait/0/0)"
fi
tmux kill-window -t "=$FLEET_SESSION:so-d7" 2>/dev/null

# ============================================================================ #
# 8. bash -n
if bash -n "$FLEET" 2>/dev/null; then pass 8; else fail 8 "bash -n failed"; fi

echo
if [ "$FAILED" = 0 ]; then
  echo "RESULT: ALL CASES PASS — reconcile cannot run a human gate."
  exit 0
else
  echo "RESULT: $FAILED case(s) FAILED"
  exit 1
fi

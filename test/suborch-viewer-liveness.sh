#!/usr/bin/env bash
# Proof harness — the sub-orch VIEWER pane must never mask a dead harness.
#
# This is the critical proof of the d25 design. The literal ask ("open the sub-orch
# with nvim") would have made nvim the sub-orch pane's own program; `is_harness_cmd`
# allowlists nvim, and `suborch_live` probes only `head -1`, so the probe would read
# ALIVE forever after the agent died -> `fleet reconcile` never re-animates -> silent
# permanent stall. The revised design keeps the harness on pane 0 and adds nvim as a
# SECOND pane, which voids that by construction — but only if liveness identifies the
# harness pane EXPLICITLY. `head -1` alone is not enough: when the harness pane exits
# the window survives on the viewer, and the viewer becomes pane index 0.
#
# Cases:
#   1. after attach, `head -1` is still the harness pane (no -b on split-window)
#   2. the viewer pane really is running nvim (so the trap in case 4 is real)
#   3. suborch_live == TRUE while the harness is alive
#   4. CRITICAL — harness pane dies, viewer survives => suborch_live must be FALSE
#   5. suborch_prune kills a harness-less (viewer-only) sub-orch window...
#   6. ...and REFUSES a window that still has a harness pane
#
# Runs against a THROWAWAY tmux server + isolated FLEET_ROOT/XDG dirs — it can never
# touch the live session or the real .fleet/dispatch ledger. XDG_RUNTIME_DIR is
# redirected too, so `rpc` can never reach the real fleetd.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

command -v nvim >/dev/null 2>&1 || { echo "SKIP: nvim not installed"; exit 0; }

# ---- socket isolation: INTRINSIC, never ambient --------------------------------
# This harness must be unable to touch the REAL tmux server even if the environment
# it was launched with is empty or wrong. Ambient isolation (`export TMUX_TMPDIR`
# + bare `tmux`) is source-dependent: any step running in a shell that did not
# inherit it silently falls back to /tmp/tmux-$(id -u)/default — the live fleet
# server — and this file's cleanup runs `kill-server`. That is how a test harness
# takes down the command center. Two mechanisms, BOTH local to this file:
#   1. SOCK is derived from our own mktemp TMPROOT, never from inherited env.
#   2. every tmux call goes through the wrapper below, which pins -S "$SOCK".
_inherited_tmpdir="${TMUX_TMPDIR:-/tmp}"          # captured before we overwrite it
TMPROOT=$(mktemp -d)
# TMUX_TMPDIR still has to be exported: the `fleet` CLI under test calls tmux itself
# and resolves the server from it. Pin OUR calls to the exact same socket path so
# both sides talk to one throwaway server — and so a lost export can never redirect
# us to the real one.
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR"
SOCK="${FLEET_TEST_SOCK:-$TMUX_TMPDIR/tmux-$(id -u)/default}"
# 0700 is REQUIRED, not tidiness: tmux refuses a socket dir with "unsafe
# permissions" for any DEFAULT-socket caller — which is what `bin/fleet` (the code
# under test) is. Left at the umask default 0755, every fleet-side tmux call fails,
# fail-silently, and the harness proves nothing while still reporting PASS.
mkdir -p "$(dirname "$SOCK")" 2>/dev/null && chmod 700 "$(dirname "$SOCK")" 2>/dev/null
tmux() { command tmux -S "$SOCK" "$@"; }   # defined HERE, in the file that calls it

# Fail-fast, BEFORE any tmux call. FLEET_TEST_SOCK exists only so the safety proof
# can inject a hostile value: it can only ever FAIL these checks, never bypass them.
_realsock="/tmp/tmux-$(id -u)/default"
case "$SOCK" in
  "$_realsock"|"$_inherited_tmpdir/tmux-$(id -u)/default")
    echo "REFUSE: harness resolved to the real tmux socket ($SOCK)" >&2
    rm -rf "$TMPROOT"; exit 1 ;;
esac
case "$SOCK" in
  "$TMPROOT"/*) ;;
  *) echo "REFUSE: socket '$SOCK' is outside the harness TMPROOT ($TMPROOT)" >&2
     rm -rf "$TMPROOT"; exit 1 ;;
esac
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"   # no real fleetd
unset TMUX
export FLEET_SESSION="viewer_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"

# A fake "claude" so a pane's #{pane_current_command} reads as a live harness.
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cp "$(command -v sleep)" "$BIN/claude"
export PATH="$BIN:$PATH"

# kill-server is SCOPED: the wrapper above expands this to
# `command tmux -S "$SOCK" kill-server`, so it can only ever kill our own server.
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }

# Build a sub-orch-shaped window: pane 0 runs the fake harness.
mk_suborch() { # <id> -> echoes window_id
  local id="$1"                      # separate decls: `local id=.. d=..$id` trips set -u
  local d="$FLEET_ROOT/.fleet/dispatch/$id" wid
  mkdir -p "$d"
  if tmux has-session -t "=$FLEET_SESSION" 2>/dev/null; then
    tmux new-window -t "=$FLEET_SESSION" -n "so-$id" "$BIN/claude 9999" 2>/dev/null
  else
    tmux new-session -d -s "$FLEET_SESSION" -n "so-$id" "$BIN/claude 9999" 2>/dev/null
  fi
  sleep 0.3
  wid=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' 2>/dev/null \
        | awk -v n="so-$id" '$2==n{print $1; exit}')
  printf 'window_id\t%s\n' "$wid" >> "$d/meta.tsv"
  printf '%s' "$wid"
}

panes_of() { tmux list-panes -t "$1" -F $'#{pane_id}\t#{pane_current_command}\t#{@fleet_viewer}' 2>/dev/null; }

echo "== d25 suborch viewer — liveness proof"

# A spare window so the sub-orch is never the session's LAST one — safe_kill_window's
# last-window brake is deliberate and must stay in force; case 5 is about the husk, not
# about defeating that brake.
tmux new-session -d -s "$FLEET_SESSION" -n keep 'sleep 9999' 2>/dev/null
sleep 0.2

D="$FLEET_ROOT/.fleet/dispatch/d1"
WID=$(mk_suborch d1)
[ -n "$WID" ] || { echo "  FATAL: could not create test window"; exit 1; }
HARNESS=$(tmux list-panes -t "$WID" -F '#{pane_id}' | head -1)

"$FLEET" attach-viewer "$WID" "$D"
sleep 1.2   # let nvim get far enough to own the pane

# --- 1. head -1 is still the harness ------------------------------------------
first=$(tmux list-panes -t "$WID" -F $'#{pane_id}\t#{pane_current_command}' | head -1)
fpane=$(printf '%s' "$first" | cut -f1); fcmd=$(printf '%s' "$first" | cut -f2)
if [ "$fpane" = "$HARNESS" ] && [ "$fcmd" = claude ]; then
  pass "1 head -1 is the harness pane ($first)"
else
  fail "1 head -1 is the harness pane" "got '$first', wanted '$HARNESS claude' (a -b split would do this)"
fi

# --- 2. the viewer pane is really nvim ----------------------------------------
VIEWER=$(panes_of "$WID" | awk -F'\t' '$3=="1"{print $1; exit}')
vcmd=$(panes_of "$WID" | awk -F'\t' '$3=="1"{print $2; exit}')
if [ -n "$VIEWER" ] && [ "$vcmd" = nvim ]; then
  pass "2 viewer pane $VIEWER runs nvim"
else
  fail "2 viewer pane runs nvim" "viewer='$VIEWER' cmd='$vcmd'"
fi
# No viewer => cases 4-6 would pass VACUOUSLY (nothing to mask a dead harness).
[ -n "$VIEWER" ] || { echo; echo "  ABORT: no viewer pane attached — remaining cases would be vacuous"; echo "FAILURES"; exit 1; }

# --- 3. live while the harness is alive ---------------------------------------
if "$FLEET" suborch-live "$D" "$FLEET_SESSION" "so-d1"; then
  pass "3 suborch_live TRUE with a live harness"
else
  fail "3 suborch_live TRUE with a live harness" "returned false"
fi

# --- 4. CRITICAL: harness dies, viewer survives -> must read DEAD --------------
tmux kill-pane -t "$HARNESS" 2>/dev/null
sleep 0.4
remaining=$(panes_of "$WID")
if "$FLEET" suborch-live "$D" "$FLEET_SESSION" "so-d1"; then
  fail "4 CRITICAL dead harness reads DEAD" "suborch_live still TRUE — the viewer is masking a dead agent (panes: $remaining)"
else
  pass "4 CRITICAL dead harness reads DEAD (panes left: $(printf '%s' "$remaining" | tr '\n' ' '))"
fi

# --- 5. prune removes the harness-less window ---------------------------------
"$FLEET" suborch-prune "$WID" 2>/dev/null
sleep 0.3
if tmux list-panes -t "$WID" -F '#{pane_id}' >/dev/null 2>&1; then
  fail "5 prune kills a viewer-only window" "window $WID still exists"
else
  pass "5 prune kills a viewer-only window"
fi

# --- 6. prune REFUSES a window that still has a harness -----------------------
D2="$FLEET_ROOT/.fleet/dispatch/d2"
WID2=$(mk_suborch d2)
"$FLEET" attach-viewer "$WID2" "$D2"
sleep 1.0
"$FLEET" suborch-prune "$WID2" 2>/dev/null
sleep 0.3
if tmux list-panes -t "$WID2" -F '#{pane_id}' >/dev/null 2>&1; then
  pass "6 prune REFUSES a window with a live harness"
else
  fail "6 prune REFUSES a window with a live harness" "window $WID2 was killed — prune must never kill a live sub-orch"
fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

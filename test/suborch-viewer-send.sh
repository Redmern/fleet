#!/usr/bin/env bash
# Proof harness — adding the viewer pane must not reroute `fleet send`.
#
# Footgun: `@fleet_nvim_sock` is a WINDOW option and `cmd_send` keys on it to route
# ALL delivery over nvim RPC, `die`ing with no fallback. If the viewer stamped it,
# every gate pop, watcher wake and inbox route into the sub-orch would ride a socket
# belonging to an nvim with no agent terminal. The viewer therefore carries a PANE
# option (`@fleet_viewer`) and never touches `@fleet_nvim_sock`.
#
# Cases:
#   1. after attach, `@fleet_nvim_sock` on the sub-orch WINDOW is empty
#   2. `fleet send so-<id> ...` takes the plain send-keys path (not nvim RPC)
#   3. the text lands in the HARNESS pane, not in the viewer pane
#   4. with the harness dead, the send must NOT fall through onto the viewer pane
#
# Throwaway tmux server + isolated FLEET_ROOT/XDG. XDG_RUNTIME_DIR is redirected so
# `rpc fleet.list` cannot reach the real fleetd — `agents_tsv` takes its pane-derived
# fallback, which is exactly the path that must filter the viewer pane out.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

command -v nvim >/dev/null 2>&1 || { echo "SKIP: nvim not installed"; exit 0; }

TMPROOT=$(mktemp -d)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR"
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FLEET_SESSION="viewer_s"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cp "$(command -v cat)" "$BIN/claude"     # `cat` keeps the pane alive AND echoes what is sent
export PATH="$BIN:$PATH"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }

echo "== d25 suborch viewer — send-routing proof"

D="$FLEET_ROOT/.fleet/dispatch/d1"; mkdir -p "$D"
tmux new-session -d -s "$FLEET_SESSION" -n "so-d1" "$BIN/claude" 2>/dev/null
sleep 0.3
WID=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk '$2=="so-d1"{print $1; exit}')
[ -n "$WID" ] || { echo "  FATAL: no test window"; exit 1; }
printf 'window_id\t%s\n' "$WID" >> "$D/meta.tsv"
HARNESS=$(tmux list-panes -t "$WID" -F '#{pane_id}' | head -1)
# fleetd is not running here, so stamp the state the daemon would have mirrored —
# `agents_tsv`'s fallback keys on @agent_state (a WINDOW option, so it is inherited
# by every pane in the window; that inheritance is the row-skew this must filter).
tmux set -w -t "$WID" @agent_state idle
tmux set -w -t "$WID" @fleet_harness claude

"$FLEET" attach-viewer "$WID" "$D"
sleep 1.2
VIEWER=$(tmux list-panes -t "$WID" -F $'#{pane_id}\t#{@fleet_viewer}' | awk -F'\t' '$2=="1"{print $1; exit}')
# No viewer => every case below passes VACUOUSLY (there is no nvim to mis-route into).
[ -n "$VIEWER" ] || { echo "  ABORT: no viewer pane attached — remaining cases would be vacuous"; echo "FAILURES"; exit 1; }

# --- 1. no @fleet_nvim_sock on the window -------------------------------------
nsock=$(tmux show -w -t "$WID" -v @fleet_nvim_sock 2>/dev/null)
if [ -z "$nsock" ]; then
  pass "1 @fleet_nvim_sock unset on the sub-orch window"
else
  fail "1 @fleet_nvim_sock unset" "got '$nsock' — cmd_send would route every delivery over nvim RPC and die with no fallback"
fi

# --- 2 + 3. send takes send-keys and lands in the harness ----------------------
out=$("$FLEET" send so-d1 "PINGMARKER" 2>&1)
sleep 0.5
case "$out" in
  *"via pane send-keys"*) pass "2 send took the plain send-keys path" ;;
  *"via nvim RPC"*)       fail "2 send took the plain send-keys path" "routed over nvim RPC: $out" ;;
  *)                      fail "2 send took the plain send-keys path" "unexpected: $out" ;;
esac

hcap=$(tmux capture-pane -p -t "$HARNESS" 2>/dev/null)
vcap=$(tmux capture-pane -p -t "$VIEWER"  2>/dev/null)
if printf '%s' "$hcap" | grep -q PINGMARKER && ! printf '%s' "$vcap" | grep -q PINGMARKER; then
  pass "3 text landed in the harness pane, not the viewer"
else
  fail "3 text landed in the harness pane, not the viewer" \
       "harness_hit=$(printf '%s' "$hcap" | grep -c PINGMARKER) viewer_hit=$(printf '%s' "$vcap" | grep -c PINGMARKER)"
fi

# --- 4. harness dead -> send must not fall through onto the viewer -------------
tmux kill-pane -t "$HARNESS" 2>/dev/null
sleep 0.4
out2=$("$FLEET" send so-d1 "SECONDMARKER" 2>&1)
sleep 0.5
vcap2=$(tmux capture-pane -p -t "$VIEWER" 2>/dev/null)
if printf '%s' "$vcap2" | grep -q SECONDMARKER; then
  fail "4 dead harness: send never hits the viewer" "SECONDMARKER was typed into nvim (out: $out2)"
else
  pass "4 dead harness: send never hits the viewer"
fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

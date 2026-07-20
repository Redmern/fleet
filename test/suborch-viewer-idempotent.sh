#!/usr/bin/env bash
# Proof harness — attaching the viewer is idempotent and fail-silent.
#
# `resolve_or_spawn_suborch` runs on every `fleet dispatch <id>` and on every
# `fleet reconcile` sweep, so the viewer attach is re-entered constantly. A second
# nvim in the window would push the harness off `head -1` semantics, waste a pane and
# (worst) turn every reconcile tick into a pane leak.
#
# Cases:
#   1. two attaches -> exactly ONE @fleet_viewer pane and exactly TWO panes total
#   2. the second attach spawns no second nvim (pane ids unchanged)
#   3. a missing farm dir is a silent no-op (no pane added, rc 0)
#   4. a bogus window id is a silent no-op (rc 0, nothing created)
#   5. fail-silent contract: no stderr noise on any of the above
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

command -v nvim >/dev/null 2>&1 || { echo "SKIP: nvim not installed"; exit 0; }

TMPROOT=$(mktemp -d)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR"
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FLEET_SESSION="viewer_i"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cp "$(command -v sleep)" "$BIN/claude"
export PATH="$BIN:$PATH"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }

echo "== d25 suborch viewer — idempotence proof"

D="$FLEET_ROOT/.fleet/dispatch/d1"; mkdir -p "$D"
tmux new-session -d -s "$FLEET_SESSION" -n "so-d1" "$BIN/claude 9999" 2>/dev/null
sleep 0.3
WID=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk '$2=="so-d1"{print $1; exit}')
[ -n "$WID" ] || { echo "  FATAL: no test window"; exit 1; }

"$FLEET" attach-viewer "$WID" "$D"
sleep 1.2
before=$(tmux list-panes -t "$WID" -F '#{pane_id}' | tr '\n' ' ')

err=$("$FLEET" attach-viewer "$WID" "$D" 2>&1 >/dev/null)
sleep 0.6
after=$(tmux list-panes -t "$WID" -F '#{pane_id}' | tr '\n' ' ')
nv=$(tmux list-panes -t "$WID" -F $'#{pane_id}\t#{@fleet_viewer}' | awk -F'\t' '$2=="1"' | grep -c .)
np=$(tmux list-panes -t "$WID" -F '#{pane_id}' | grep -c .)

# --- 1 + 2 --------------------------------------------------------------------
if [ "$nv" = 1 ] && [ "$np" = 2 ]; then
  pass "1 exactly one viewer pane, two panes total after a double attach"
else
  fail "1 exactly one viewer pane, two panes total" "viewer_panes=$nv total_panes=$np"
fi
if [ "$before" = "$after" ]; then
  pass "2 second attach added no pane ($after)"
else
  fail "2 second attach added no pane" "before='$before' after='$after'"
fi

# --- 3. missing farm dir ------------------------------------------------------
tmux new-window -t "=$FLEET_SESSION" -n "so-d2" "$BIN/claude 9999" 2>/dev/null
sleep 0.3
WID2=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
       | awk '$2=="so-d2"{print $1; exit}')
err3=$("$FLEET" attach-viewer "$WID2" "$FLEET_ROOT/.fleet/dispatch/nope" 2>&1 >/dev/null); rc3=$?
sleep 0.4
np2=$(tmux list-panes -t "$WID2" -F '#{pane_id}' | grep -c .)
if [ "$rc3" = 0 ] && [ "$np2" = 1 ]; then
  pass "3 missing farm dir is a silent no-op"
else
  fail "3 missing farm dir is a silent no-op" "rc=$rc3 panes=$np2"
fi

# --- 4. bogus window id -------------------------------------------------------
# rc alone would be tautological (the function ends in an unconditional `return 0`),
# so assert on the WORLD: no window, no pane and no stray nvim may appear anywhere.
w_before=$(tmux list-windows -a -F '#{window_id}' | grep -c .)
p_before=$(tmux list-panes -a -F '#{pane_id}' | grep -c .)
err4=$("$FLEET" attach-viewer "@99999" "$D" 2>&1 >/dev/null); rc4=$?
sleep 0.5
w_after=$(tmux list-windows -a -F '#{window_id}' | grep -c .)
p_after=$(tmux list-panes -a -F '#{pane_id}' | grep -c .)
if [ "$rc4" = 0 ] && [ "$w_after" = "$w_before" ] && [ "$p_after" = "$p_before" ]; then
  pass "4 bogus window id creates nothing (windows $w_after, panes $p_after)"
else
  fail "4 bogus window id creates nothing" "rc=$rc4 windows $w_before->$w_after panes $p_before->$p_after"
fi

# --- 5. fail-silent -----------------------------------------------------------
if [ -z "$err" ] && [ -z "$err3" ] && [ -z "$err4" ]; then
  pass "5 no stderr noise from any no-op path"
else
  fail "5 no stderr noise from any no-op path" "err='$err' err3='$err3' err4='$err4'"
fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

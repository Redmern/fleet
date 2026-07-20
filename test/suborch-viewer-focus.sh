#!/usr/bin/env bash
# Proof harness — the viewer pane must be invisible to focus and to agent rows.
#
# Two distinct hazards, settled empirically (the PLAN left this open):
#
#  (a) FOCUS. `fleetd` prefers `#{pane_active}` when it picks the representative pane
#      for a stamped-but-unreported window, so a focus-stealing split would transiently
#      make `fleet send` / `fleet mode` target nvim. The split therefore uses -d.
#
#  (b) ROWS. Both row producers enumerate PANES, and both key on WINDOW options, which
#      tmux inherits down to every pane in the window:
#        * `agents_tsv`'s daemon-down fallback keys on @agent_state  -> emits ONE ROW
#          PER PANE, so the viewer would double the sub-orch's row and skew
#          fleet-dash's HIDDEN_N parked count (bin/fleet-dash:416).
#        * `fleetd.list_agents`'s synthetic pass keys on @fleet_harness -> one row per
#          WINDOW, so no duplicate, but it can pick the VIEWER pane as the window's
#          representative agent pane whenever the human focuses nvim.
#        * `fleetd.scrape_harnesses` keys on @fleet_state_src / @fleet_busy_re (hookless
#          harnesses like omp) -> it would capture-pane the nvim viewer and report a
#          state for it, putting a non-agent pane into the reported set.
#      All three must filter on the @fleet_viewer PANE option.
#
# Cases:
#   1. the harness pane is still #{pane_active} right after the split
#   2. daemon-down: exactly ONE agent row for the sub-orch window, pane == harness
#   3. same for a window parked in <sess>_hidden (the HIDDEN_N over-count)
#   4. daemon-up (real fleetd on a throwaway socket): one row, pane == harness,
#      EVEN WITH THE VIEWER PANE ACTIVE
#   4b. …and fleetd SURVIVED serving it — without this, a daemon that crashed mid-reply
#      scores a PASS on case 4, because agents_tsv silently falls back to the
#      tmux-option path and returns the same answer. (This is not hypothetical: it
#      caught a real ValueError, then a real IndexError, in the fleetd changes here.)
#   4c. …and the reply really came over RPC, not from that fallback
#   4d. scrape-mode harness: the viewer is not scraped into the reported set
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
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"   # never the real fleetd
unset TMUX
export FLEET_SESSION="viewer_f"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cp "$(command -v sleep)" "$BIN/claude"
export PATH="$BIN:$PATH"

DPID=""
# kill-server is SCOPED: the wrapper above expands this to
# `command tmux -S "$SOCK" kill-server`, so it can only ever kill our own server.
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; tmux kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }

# rows for a given window_id out of `fleet agents` (field 4 = window_id, 7 = pane_id)
rows_for() { "$FLEET" agents 2>/dev/null | awk -F'\t' -v w="$1" '$4==w'; }

echo "== d25 suborch viewer — focus + agent-row proof"

D="$FLEET_ROOT/.fleet/dispatch/d1"; mkdir -p "$D"
tmux new-session -d -s "$FLEET_SESSION" -n "so-d1" "$BIN/claude 9999" 2>/dev/null
sleep 0.3
WID=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk '$2=="so-d1"{print $1; exit}')
[ -n "$WID" ] || { echo "  FATAL: no test window"; exit 1; }
HARNESS=$(tmux list-panes -t "$WID" -F '#{pane_id}' | head -1)
tmux set -w -t "$WID" @agent_state idle       # what fleetd would have mirrored
tmux set -w -t "$WID" @fleet_harness claude

"$FLEET" attach-viewer "$WID" "$D"
sleep 1.2
VIEWER=$(tmux list-panes -t "$WID" -F $'#{pane_id}\t#{@fleet_viewer}' | awk -F'\t' '$2=="1"{print $1; exit}')
# No viewer => every case below passes VACUOUSLY (a 1-pane window cannot skew rows).
[ -n "$VIEWER" ] || { echo "  ABORT: no viewer pane attached — remaining cases would be vacuous"; echo "FAILURES"; exit 1; }

# --- 1. focus did not move ----------------------------------------------------
act=$(tmux list-panes -t "$WID" -F $'#{pane_id}\t#{pane_active}' | awk -F'\t' '$2=="1"{print $1; exit}')
if [ "$act" = "$HARNESS" ]; then
  pass "1 harness pane is still active after the split"
else
  fail "1 harness pane is still active after the split" "active=$act harness=$HARNESS (missing -d on split-window)"
fi

# --- 2. daemon-down fallback: exactly one row ---------------------------------
n=$(rows_for "$WID" | grep -c .)
p=$(rows_for "$WID" | head -1 | cut -f7)
if [ "$n" = 1 ] && [ "$p" = "$HARNESS" ]; then
  pass "2 daemon-down: 1 row for the sub-orch window, pane=$p"
else
  fail "2 daemon-down: 1 row for the sub-orch window" \
       "rows=$n pane='$p' harness=$HARNESS — the viewer inherits @agent_state and doubles the row"
fi

# --- 3. same, parked in <sess>_hidden (the HIDDEN_N over-count) ---------------
tmux new-session -d -s "${FLEET_SESSION}_hidden" -n park 'sleep 9999' 2>/dev/null
tmux move-window -s "$WID" -t "=${FLEET_SESSION}_hidden:" 2>/dev/null
sleep 0.3
nh=$(rows_for "$WID" | grep -c .)
if [ "$nh" = 1 ]; then
  pass "3 hidden-session: still 1 row (HIDDEN_N counts the sub-orch once)"
else
  fail "3 hidden-session: still 1 row" "rows=$nh — fleet-dash's HIDDEN_N would over-count parked agents"
fi
tmux move-window -s "$WID" -t "=${FLEET_SESSION}:" 2>/dev/null
sleep 0.3

# --- 4. daemon-up synthetic pass, viewer pane ACTIVE ---------------------------
if command -v python3 >/dev/null 2>&1; then
  python3 "$HERE/bin/fleetd" >"$TMPROOT/fleetd.log" 2>&1 &
  DPID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$XDG_RUNTIME_DIR/fleet.sock" ] && break
    sleep 0.3
  done
  if [ -S "$XDG_RUNTIME_DIR/fleet.sock" ]; then
    tmux select-pane -t "$VIEWER" 2>/dev/null     # human focuses nvim to read files
    sleep 0.3
    nd=$(rows_for "$WID" | grep -c .)
    pd=$(rows_for "$WID" | head -1 | cut -f7)
    if [ "$nd" = 1 ] && [ "$pd" = "$HARNESS" ]; then
      pass "4 daemon-up: 1 row, pane=$pd, with the viewer focused"
    else
      fail "4 daemon-up: 1 row with pane==harness" \
           "rows=$nd pane='$pd' harness=$HARNESS viewer=$VIEWER — fleetd's synth pass picked the active viewer pane"
    fi

    # --- 4b. …and the daemon SURVIVED serving that request ---------------------
    # Case 4 alone is not proof: `agents_tsv` falls back to the tmux-option path the
    # moment `rpc` fails, and that fallback yields the same 1-row answer. A daemon
    # that crashed while building the reply would score a PASS. (It did: the synth
    # pass unpacked the widened meta tuple into too few names -> ValueError -> the
    # select loop has no guard -> fleetd exits -> systemd crash-loops it to failed.)
    # So: assert the process is still alive AND that the reply really came over RPC.
    if kill -0 "$DPID" 2>/dev/null; then
      pass "4b fleetd survived serving fleet.list"
    else
      fail "4b fleetd survived serving fleet.list" \
           "the daemon died building the reply — every case above silently measured the daemon-DOWN fallback"
      sed -n '1,20p' "$TMPROOT/fleetd.log" | sed 's/^/      | /' 
    fi
    if "$FLEET" agents 2>/dev/null | grep -q .; then
      # the fallback prints '-' for `since`; the daemon prints a real 0m00s age
      if rows_for "$WID" | cut -f6 | grep -qE '^[0-9]+m[0-9]+s$'; then
        pass "4c the row came from the daemon, not the tmux-option fallback"
      else
        fail "4c the row came from the daemon" "since field is '$(rows_for "$WID" | cut -f6)' — that is the fallback's shape"
      fi
    fi

    # --- 4d. the harness SCRAPE path must not scrape the viewer ----------------
    # @fleet_state_src / @fleet_busy_re are window options too (hookless harnesses
    # like omp), so they are inherited by the viewer pane.
    tmux set -w -t "$WID" @fleet_state_src scrape
    tmux set -w -t "$WID" @fleet_busy_re 'esc to interrupt'
    sleep 5      # > SCRAPE_INTERVAL (2s) — the scrape runs on fleetd's own select loop
    ns=$(rows_for "$WID" | grep -c .)
    if [ "$ns" = 1 ] && kill -0 "$DPID" 2>/dev/null; then
      pass "4d scrape-mode harness: still 1 row, daemon alive"
    else
      alive=no; kill -0 "$DPID" 2>/dev/null && alive=yes
      fail "4d scrape-mode harness: still 1 row" \
           "rows=$ns daemon_alive=$alive — fleetd scraped the nvim viewer and reported it as an agent"
      [ "$alive" = no ] && sed -n '$p;1,20p' "$TMPROOT/fleetd.log" | sed 's/^/      | /' 
    fi
    tmux set -w -t "$WID" -u @fleet_state_src 2>/dev/null
    tmux set -w -t "$WID" -u @fleet_busy_re 2>/dev/null

    tmux select-pane -t "$HARNESS" 2>/dev/null
  else
    echo "  SKIP(4): fleetd did not come up on the throwaway socket"
  fi
else
  echo "  SKIP(4): python3 missing"
fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

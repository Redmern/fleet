#!/usr/bin/env bash
# TESTER A ROUND 2 — independent B1 measurement. NOT a shipped proof.
# Arm S: stale sentinel in scrollback + @agent_state=working + pane cannot echo.
#        Round 1 measured 20/20 FALSE CONFIRM. Must now be 0/N.
# Arm G: GENUINE landing into an ALREADY-working pane (echoing `cat`). Must confirm N/N.
# Arm C: control — stale sentinel, state=idle. Must be 0/N.
set -u
FLEETBIN="${FLEETBIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/fleet}"
N="${N:-20}"
TMPROOT=$(mktemp -d /tmp/ta2b1.XXXXXX)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"
mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"
case "$SOCK" in "$TMPROOT"/*) ;; *) echo "REFUSE bad sock"; exit 1;; esac
tmux() { command tmux -S "$SOCK" "$@"; }
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FLEET_SESSION="ta2b1"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"
export FLEET_WAKE_CONFIRM=2 FLEET_NO_PROMOTE=1
trap 'command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"' EXIT
tmux new-session -d -s "$FLEET_SESSION" -n main 'sleep 9999' 2>/dev/null; sleep 0.3
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

mk() { # <id> <text> -> dir, posts+parks gate1, approves
  local id="$1" d
  d="$FLEET_ROOT/.fleet/dispatch/$id"; mkdir -p "$d"
  "$FLEETBIN" dispatch rename "$id" "$2" >/dev/null 2>&1
  local slug; slug=$("$FLEETBIN" slug "$2" 2>/dev/null)
  "$FLEETBIN" gate post 1 --slug "$slug" --summary s -d "$id" --park >/dev/null 2>&1
  "$FLEETBIN" gate approve "$id" >/dev/null 2>&1
  printf '%s' "$d"
}

run_arm() { # <arm> <paneshape> <state>
  local IDBASE="${IDBASE:?}"
  local arm="$1" shape="$2" st="$3" i confirms=0 vac=0
  for i in $(seq 1 "$N"); do
    local id="d${IDBASE}$i" d sent wn w p pre
    d=$(mk "$id" "Arm $arm $i")
    sent=$(sed -n 1p "$d/decision-1.txt" 2>/dev/null)
    [ -n "$sent" ] || { echo "SETUP FAIL: no decision file for $id" >&2; vac=$((vac+1)); continue; }
    wn=$(mget "$d" window)
    if [ "$shape" = stale ]; then
      tmux new-window -d -t "=$FLEET_SESSION" -n "$wn" \
        "stty -echo 2>/dev/null; printf '%s\\n' \"$sent\"; sleep 9999" 2>/dev/null
    else
      # genuine: an echoing pane that ALREADY shows unrelated busy output
      tmux new-window -d -t "=$FLEET_SESSION" -n "$wn" 'cat' 2>/dev/null
    fi
    sleep 0.4
    w=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' | awk -v n="$wn" '$2==n{print $1;exit}')
    printf 'window_id\t%s\n' "$w" >> "$d/meta.tsv"
    p=$(tmux list-panes -t "=$FLEET_SESSION:$wn" -F '#{pane_id}' 2>/dev/null | head -1)
    tmux set -w -t "$p" @agent_state "$st" 2>/dev/null
    pre=$(tmux capture-pane -p -J -t "$p" 2>/dev/null | grep -cF -- "$sent")
    # vacuity guard
    if [ -z "$p" ]; then vac=$((vac+1));
    elif [ "$shape" = stale ] && [ "${pre:-0}" -lt 1 ]; then vac=$((vac+1)); fi
    "$FLEETBIN" gate deliver "$id" >/dev/null 2>&1
    [ "$(mget "$d" delivered)" = 1 ] && confirms=$((confirms+1))
    tmux kill-window -t "=$FLEET_SESSION:$wn" 2>/dev/null
  done
  echo "ARM $arm ($shape, state=$st): confirmed=$confirms/$N  vacuous=$vac/$N"
}

IDBASE=91 run_arm S stale working
IDBASE=92 run_arm G genuine working
IDBASE=93 run_arm C stale idle

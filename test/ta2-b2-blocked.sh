#!/usr/bin/env bash
# TESTER A ROUND 2 — B2: `blocked` must be PARKED on all three consumers,
# and an UNKNOWN state must NOT be (the inverse failure: a stranded dispatch going invisible).
set -u
FLEETBIN="${FLEETBIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/fleet}"
TMPROOT=$(mktemp -d /tmp/ta2b2.XXXXXX)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"; case "$SOCK" in "$TMPROOT"/*) ;; *) exit 1;; esac
tmux() { command tmux -S "$SOCK" "$@"; }
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FLEET_SESSION=ta2b2 FLEET_ROOT="$TMPROOT/root" FLEET_NO_PROMOTE=1
mkdir -p "$FLEET_ROOT/.fleet/dispatch"
trap 'command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"' EXIT
tmux new-session -d -s $FLEET_SESSION -n main 'sleep 9999'; sleep 0.3
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

probe() { # <id> <state>
  local id="$1" st="$2" d="$FLEET_ROOT/.fleet/dispatch/$1"
  mkdir -p "$d"
  printf 'window\tso-%s-x\nstate\t%s\nreports\t%s/_reports/x\n' "$id" "$st" "$FLEET_ROOT" > "$d/meta.tsv"
  local inlist inwait rec
  "$FLEETBIN" gate list 2>/dev/null | grep -q "$id" && inlist=YES || inlist=no
  "$FLEETBIN" gate waiting 2>/dev/null | grep -q "so-$id" && inwait=YES || inwait=no
  FLEET_RECONCILE_GRACE=0 "$FLEETBIN" reconcile >/dev/null 2>&1
  rec=$(mget "$d" state)
  printf '  state=%-10s gate-list=%-3s gate-waiting(reap-skip)=%-3s state-after-reconcile=%s\n' "$st" "$inlist" "$inwait" "$rec"
}

echo "== B2: ledger_parked classification (window is DEAD in all rows: reconcile's revive/fail branch)"
probe d701 blocked
probe d702 gate1-wait
probe d703 gate3-wait
probe d704 planning
probe d705 wibble-garbage
probe d706 done

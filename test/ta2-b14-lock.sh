#!/usr/bin/env bash
# TESTER A ROUND 2 — B1.4: the non-blocking flock at gate_deliver entry.
# a) two couriers fired together => exactly ONE paste reaches the pane
# b) flock ABSENT from PATH => still DELIVERS (degrade to unlocked, not to no delivery)
# c) lock file cannot be created => rc!=0, not delivered, parked (no silent success)
set -u
FLEETBIN="${FLEETBIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/fleet}"
TMPROOT=$(mktemp -d /tmp/ta2b14.XXXXXX)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"
case "$SOCK" in "$TMPROOT"/*) ;; *) echo REFUSE; exit 1;; esac
tmux() { command tmux -S "$SOCK" "$@"; }
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FLEET_SESSION=ta2b14 FLEET_ROOT="$TMPROOT/root" FLEET_WAKE_CONFIRM=4 FLEET_NO_PROMOTE=1
mkdir -p "$FLEET_ROOT/.fleet/dispatch"
trap 'command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"' EXIT
tmux new-session -d -s $FLEET_SESSION -n main 'sleep 9999'; sleep 0.3
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

mk() { # <id> <text> [nopane]
  local id="$1" d wn w
  d="$FLEET_ROOT/.fleet/dispatch/$id"; mkdir -p "$d"
  "$FLEETBIN" dispatch rename "$id" "$2" >/dev/null 2>&1
  local slug; slug=$("$FLEETBIN" slug "$2")
  "$FLEETBIN" gate post 1 --slug "$slug" --summary s -d "$id" --park >/dev/null 2>&1
  "$FLEETBIN" gate approve "$id" >/dev/null 2>&1
  wn=$(mget "$d" window)
  if [ "${3:-}" != nopane ]; then
    tmux new-window -d -t "=$FLEET_SESSION" -n "$wn" 'stty -echo 2>/dev/null; cat' 2>/dev/null; sleep 0.4
    w=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}'|awk -v n="$wn" '$2==n{print $1;exit}')
    printf 'window_id\t%s\n' "$w" >> "$d/meta.tsv"
    local p; p=$(tmux list-panes -t "=$FLEET_SESSION:$wn" -F '#{pane_id}'|head -1)
    tmux set -w -t "$p" @agent_state working 2>/dev/null
    printf '%s\t%s' "$d" "$p"
  else
    printf '%s\t' "$d"
  fi
}

# (a) two couriers at once
IFS=$'\t' read -r DA PA < <(mk d801 "Lock Race")
SENT=$(sed -n 1p "$DA/decision-1.txt")
"$FLEETBIN" gate deliver d801 >/dev/null 2>&1 &
"$FLEETBIN" gate deliver d801 >/dev/null 2>&1 &
wait
sleep 0.5
n=$(tmux capture-pane -p -J -t "$PA" | grep -cF -- "$SENT")
echo "(a) two simultaneous couriers: pastes on pane = $n (want 1); delivered=$(mget "$DA" delivered)"

# vacuity guard for (a): a single courier must produce exactly 1
IFS=$'\t' read -r DA2 PA2 < <(mk d802 "Lock Single")
S2=$(sed -n 1p "$DA2/decision-1.txt")
"$FLEETBIN" gate deliver d802 >/dev/null 2>&1; sleep 0.4
n2=$(tmux capture-pane -p -J -t "$PA2" | grep -cF -- "$S2")
echo "(a-guard) single courier: pastes = $n2 (want 1)"

# (b) flock absent from PATH
IFS=$'\t' read -r DB PB < <(mk d803 "No Flock")
SB=$(sed -n 1p "$DB/decision-1.txt")
mkdir -p "$TMPROOT/nopath"
# mirror the ENTIRE PATH, minus flock: anything else missing would confound the arm
IFS=: read -ra _pd <<< "$PATH"
for dir in "${_pd[@]}"; do [ -d "$dir" ] || continue
  for f in "$dir"/*; do b=$(basename "$f"); [ "$b" = flock ] && continue
    [ -e "$TMPROOT/nopath/$b" ] || ln -sf "$f" "$TMPROOT/nopath/$b" 2>/dev/null; done; done
PATH="$TMPROOT/nopath" "$FLEETBIN" gate deliver d803 >/dev/null 2>&1; rcb=$?
sleep 0.4
nb=$(tmux capture-pane -p -J -t "$PB" | grep -cF -- "$SB")
echo "(b) flock ABSENT: rc=$rcb delivered=$(mget "$DB" delivered) state=$(mget "$DB" state) pastes=$nb  [flock on nopath: $(PATH=$TMPROOT/nopath command -v flock || echo none)]"

# (c) lock file cannot be created
IFS=$'\t' read -r DC PC < <(mk d804 "No Lockfile")
chmod 555 "$DC"
"$FLEETBIN" gate deliver d804 >/dev/null 2>&1; rcc=$?
chmod 755 "$DC"
echo "(c) unwritable dispatch dir: rc=$rcc delivered='$(mget "$DC" delivered)' state='$(mget "$DC" state)'"

# (b-control) same stripped PATH but WITH flock available
IFS=$'\t' read -r DD PD < <(mk d805 "Flock Present Control")
SD=$(sed -n 1p "$DD/decision-1.txt")
ln -sf "$(command -v flock)" "$TMPROOT/nopath/flock"
PATH="$TMPROOT/nopath" "$FLEETBIN" gate deliver d805 >/dev/null 2>&1; rcd=$?
sleep 0.4
nd=$(tmux capture-pane -p -J -t "$PD" | grep -cF -- "$SD")
echo "(b-control) same PATH + flock present: rc=$rcd delivered=$(mget "$DD" delivered) pastes=$nd"

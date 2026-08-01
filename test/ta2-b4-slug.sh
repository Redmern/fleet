#!/usr/bin/env bash
# TESTER A ROUND 2 — B4: gate-2 slug confirmation.
set -u
FLEETBIN="${FLEETBIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/fleet}"
TMPROOT=$(mktemp -d /tmp/ta2b4.XXXXXX)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FLEET_SESSION=ta2b4 FLEET_ROOT="$TMPROOT/root" FLEET_NO_PROMOTE=1
mkdir -p "$FLEET_ROOT/.fleet/dispatch"
trap 'rm -rf "$TMPROOT"' EXIT
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

mk() { # <id> <gate> <slug> [nosluginsentinel]
  local id="$1" n="$2" slug="$3" d="$FLEET_ROOT/.fleet/dispatch/$1"
  mkdir -p "$d"
  printf 'window\tso-%s-%s\nstate\tgate%s-wait\n' "$id" "$slug" "$n" > "$d/meta.tsv"
  if [ "${4:-}" = noslug ]; then
    printf '[FLEET-GATE:%s action=merge target=main]\nbody\n' "$n" > "$d/GATE-$n.md"
  elif [ "$n" = 2 ]; then
    printf '[FLEET-GATE:2 slug=%s action=merge target=main]\nbody\n' "$slug" > "$d/GATE-$n.md"
  elif [ "$n" = 3 ]; then
    printf '[FLEET-GATE:3 slug=%s action=commit]\nbody\n' "$slug" > "$d/GATE-$n.md"
  else
    printf '[FLEET-GATE:1 slug=%s action=implement]\nbody\n' "$slug" > "$d/GATE-$n.md"
  fi
  printf '%s' "$d"
}
res() { # <dir>
  printf 'decision="%s" decision_gate="%s" files=[%s]' \
    "$(mget "$1" decision)" "$(mget "$1" decision_gate)" "$(cd "$1" && ls decision-*.txt 2>/dev/null | tr '\n' ' ')"
}

echo "== B4 gate-2 slug confirmation"
D=$(mk d501 2 alpha); "$FLEETBIN" gate approve d501 </dev/null >/dev/null 2>&1; echo "1 no-tty, no --yes:        rc=$?  $(res "$D")   [want rc=2, nothing]"
D=$(mk d502 2 alpha); "$FLEETBIN" gate approve d502 --yes </dev/null >/dev/null 2>&1; echo "2 no-tty, --yes:           rc=$?  $(res "$D")   [want rc=0, written]"
D=$(mk d503 2 alpha); script -qec "$FLEETBIN gate approve d503" /dev/null <<< "wrongslug" >/dev/null 2>&1; echo "3 tty, WRONG slug typed:   rc=$?  $(res "$D")   [want rc=2, nothing]"
D=$(mk d504 2 alpha); script -qec "$FLEETBIN gate approve d504" /dev/null <<< "alpha" >/dev/null 2>&1; echo "4 tty, RIGHT slug typed:   rc=$?  $(res "$D")   [want rc=0, written]"
D=$(mk d505 2 alpha); script -qec "$FLEETBIN gate approve d505" /dev/null <<< "" >/dev/null 2>&1; echo "5 tty, bare Enter:         rc=$?  $(res "$D")   [want rc=2, nothing]"
D=$(mk d506 2 alpha noslug); "$FLEETBIN" gate approve d506 </dev/null >/dev/null 2>&1; rc=$?; echo "6 sentinel has NO slug= (no tty): rc=$rc  $(res "$D")   [want refuse]"
D=$(mk d507 2 alpha noslug); script -qec "$FLEETBIN gate approve d507" /dev/null <<< "" >/dev/null 2>&1; echo "6b sentinel NO slug=, tty, bare Enter: rc=$?  $(res "$D")   [want refuse, nothing]"
D=$(mk d508 1 alpha); "$FLEETBIN" gate approve d508 </dev/null >/dev/null 2>&1; echo "7 GATE 1 headless:         rc=$?  $(res "$D")   [want rc=0, written]"
D=$(mk d509 3 alpha); "$FLEETBIN" gate approve d509 </dev/null >/dev/null 2>&1; echo "8 GATE 3 headless:         rc=$?  $(res "$D")   [want rc=0, written]"
D=$(mk d510 2 alpha); "$FLEETBIN" gate reject d510 -m "nope" </dev/null >/dev/null 2>&1; echo "9 GATE 2 REJECT headless:  rc=$?  $(res "$D")   [reject is not slug-gated]"
D=$(mk d511 2 alpha); "$FLEETBIN" gate approve d511 --gate 1 </dev/null >/dev/null 2>&1; echo "10 --gate 1 while gate2-wait: rc=$?  $(res "$D")   [want refuse]"

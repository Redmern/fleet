#!/usr/bin/env bash
# TESTER A ROUND 2 — B3: meta_set / meta_compact under concurrency.
# arm1: 30 concurrent distinct-key writers -> how many keys survive? (round 1: 29/30 LOST)
# arm2: approve || reject race -> decision file present but ledger `decision` EMPTY?
#       (round 1: 9/30 -> silently parked forever)
# arm3: meta_compact concurrent with meta_set -> key loss?
set -u
FLEETBIN="${FLEETBIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/fleet}"
R="${R:-30}"
TMPROOT=$(mktemp -d /tmp/ta2b3.XXXXXX)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FLEET_SESSION=ta2b3 FLEET_ROOT="$TMPROOT/root" FLEET_NO_PROMOTE=1
mkdir -p "$FLEET_ROOT/.fleet/dispatch"
trap 'rm -rf "$TMPROOT"' EXIT
export FLEET_SOURCE_ONLY=1
. "$FLEETBIN" || exit 1
unset FLEET_SOURCE_ONLY
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

# arm1
D="$FLEET_ROOT/.fleet/dispatch/d601"; mkdir -p "$D"
for i in $(seq 1 "$R"); do meta_set "$D" "k$i" "v$i" >/dev/null 2>&1 & done
wait
have=0; for i in $(seq 1 "$R"); do [ "$(mget "$D" "k$i")" = "v$i" ] && have=$((have+1)); done
bad=$(awk -F'\t' 'NF!=2{b++} END{print b+0}' "$D/meta.tsv")
echo "arm1 concurrent distinct-key writes: survived=$have/$R  lost=$((R-have))  malformed-lines=$bad"

# arm3: compact racing sets
D3="$FLEET_ROOT/.fleet/dispatch/d603"; mkdir -p "$D3"
for i in $(seq 1 "$R"); do printf 'p%s\tq%s\n' "$i" "$i" >> "$D3/meta.tsv"; done
for i in $(seq 1 "$R"); do meta_set "$D3" "z$i" "y$i" >/dev/null 2>&1 &
  [ $((i % 5)) = 0 ] && meta_compact "$D3" >/dev/null 2>&1 & done
wait
h3=0; for i in $(seq 1 "$R"); do [ "$(mget "$D3" "z$i")" = "y$i" ] && h3=$((h3+1)); done
p3=0; for i in $(seq 1 "$R"); do [ "$(mget "$D3" "p$i")" = "q$i" ] && p3=$((p3+1)); done
echo "arm3 meta_compact || meta_set: new keys survived=$h3/$R  pre-existing survived=$p3/$R"

# arm2: approve || reject on the same dispatch, R rounds
lost=0
for i in $(seq 1 "$R"); do
  id="d62$i"; d="$FLEET_ROOT/.fleet/dispatch/$id"; mkdir -p "$d"
  "$FLEETBIN" dispatch rename "$id" "Race $i" >/dev/null 2>&1
  slug=$("$FLEETBIN" slug "Race $i")
  "$FLEETBIN" gate post 1 --slug "$slug" --summary s -d "$id" --park >/dev/null 2>&1
  "$FLEETBIN" gate approve "$id" >/dev/null 2>&1 &
  "$FLEETBIN" gate reject "$id" -m "no" >/dev/null 2>&1 &
  wait
  if ls "$d"/decision-1.txt >/dev/null 2>&1 && [ -z "$(mget "$d" decision)" ]; then lost=$((lost+1)); fi
done
echo "arm2 approve||reject: decision FILE exists but ledger decision EMPTY in $lost/$R  (=> undeliverable, parked forever)"

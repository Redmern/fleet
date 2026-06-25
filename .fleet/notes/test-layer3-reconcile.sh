#!/usr/bin/env bash
# Layer-3 unit tests for cmd_reconcile (respawn cap / generation guard).
# Extracts the REAL meta_* + cmd_reconcile funcs from bin/fleet, stubs the rest,
# and drives each scenario. Runs under `set -u` (the code runs under set -u).
set -u

REPO="/home/red/proj/pc-tune/fleet/fleet_reconcile-zombie-terminal-state"
FLEET_BIN="$REPO/bin/fleet"

PASS=0; FAIL=0; FAILED_NAMES=""

# Extract real functions into a lib and source it once.
EXTRACT_DIR=$(mktemp -d)
[ "${EXTRACT_DIR#/tmp/}" != "$EXTRACT_DIR" ] || { echo "FATAL: mktemp not under /tmp"; exit 1; }
sed -n '/^meta_get()/,/^}/p; /^meta_set()/,/^}/p; /^meta_compact()/,/^}/p; /^cmd_reconcile()/,/^}/p' \
  "$FLEET_BIN" > "$EXTRACT_DIR/lib.sh"
# sanity: cmd_reconcile actually extracted
grep -q '^cmd_reconcile()' "$EXTRACT_DIR/lib.sh" || { echo "FATAL: cmd_reconcile not extracted"; exit 1; }
# shellcheck disable=SC1090
source "$EXTRACT_DIR/lib.sh"

# ---- Stubs (defined AFTER sourcing so they win) ----
ROOT=""   # set per scenario
session_name(){ echo S; }
fleet_root(){ printf '%s' "$ROOT"; }
suborch_live(){ return "${LIVE_RC:-1}"; }                 # default 1 = DEAD window
suborch_has_live_workers(){ return "${HASWORK_RC:-1}"; }  # default 1 = NO live worker
resolve_or_spawn_suborch(){ echo "SPAWN $3" >> "$ROOT/spawns.log"; }
append_dashboard_alert(){ echo "ALERT $*" >> "$ROOT/alerts.log"; }
tmux(){ case "$1" in info) return "${TMUX_INFO_RC:-0}";; *) return 0;; esac; }

# ---- Helpers ----
fresh_root(){
  ROOT=$(mktemp -d)
  case "$ROOT" in /tmp/*) : ;; *) echo "FATAL: ROOT not under /tmp: $ROOT"; exit 1 ;; esac
  : > "$ROOT/spawns.log"
  : > "$ROOT/alerts.log"
}
# mkmeta <id> <line...>  — create dispatch dir + meta.tsv from tab lines
mkmeta(){
  local id="$1"; shift
  local d="$ROOT/.fleet/dispatch/$id"
  mkdir -p "$d"
  : > "$d/meta.tsv"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$d/meta.tsv"; done
}
TAB=$(printf '\t')
mline(){ printf '%s\t%s' "$1" "$2"; }   # key val -> "key<TAB>val"

state_of(){ meta_get "$ROOT/.fleet/dispatch/$1" state; }
respawns_of(){ meta_get "$ROOT/.fleet/dispatch/$1" respawns; }
spawn_count(){ local c; c=$(grep -c "^SPAWN $1$" "$ROOT/spawns.log" 2>/dev/null); printf '%s' "${c:-0}"; }
alert_count(){ wc -l < "$ROOT/alerts.log" 2>/dev/null | tr -d ' '; }

check(){ # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "    ok: $1 ($2)";
  else FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $CUR/$1"; echo "    FAIL: $1 -> got [$2] want [$3]"; fi
}

scenario(){ CUR="$1"; echo "== $1 =="; }

# Reset env vars to defaults before each scenario
reset_env(){ unset LIVE_RC HASWORK_RC TMUX_INFO_RC FLEET_RECONCILE_CAP; }

###############################################################################
# S1 OVER-CAP + responsive + no worker -> ABANDON
###############################################################################
scenario "S1 over-cap+responsive+no-worker => failed+alert+no-spawn"
fresh_root; reset_env
mkmeta d1 "$(mline state running)" "$(mline respawns 1)"
LIVE_RC=1 HASWORK_RC=1 TMUX_INFO_RC=0   # defaults but explicit
cmd_reconcile
check "state=failed"     "$(state_of d1)"    "failed"
check "respawns unchanged=1" "$(respawns_of d1)" "1"
check "alert present"    "$(alert_count)"    "1"
check "no spawn"         "$(spawn_count d1)" "0"

###############################################################################
# S2 UNDER-CAP -> RESPAWN
###############################################################################
scenario "S2 under-cap => running, respawns->1, spawn, no alert"
fresh_root; reset_env
mkmeta d1 "$(mline state running)" "$(mline respawns 0)"
cmd_reconcile
check "state still running" "$(state_of d1)"  "running"
check "respawns bumped=1"   "$(respawns_of d1)" "1"
check "spawn logged"        "$(spawn_count d1)" "1"
check "no alert"            "$(alert_count)"    "0"

###############################################################################
# S3 CAP reached BUT live worker owned -> re-animate, not fail
###############################################################################
scenario "S3 cap reached + live worker => not failed, respawns->2, spawn"
fresh_root; reset_env
mkmeta d1 "$(mline state running)" "$(mline respawns 1)"
HASWORK_RC=0   # live worker present
cmd_reconcile
check "state still running" "$(state_of d1)"  "running"
check "respawns bumped=2"   "$(respawns_of d1)" "2"
check "spawn logged"        "$(spawn_count d1)" "1"
check "no alert"            "$(alert_count)"    "0"

###############################################################################
# S4 tmux UNRESPONSIVE -> never mass-fail
###############################################################################
scenario "S4 tmux unresponsive => not failed, respawn bumped, spawn"
fresh_root; reset_env
mkmeta d1 "$(mline state running)" "$(mline respawns 5)"
TMUX_INFO_RC=1 HASWORK_RC=1
cmd_reconcile
check "state still running" "$(state_of d1)"  "running"
check "respawns bumped=6"   "$(respawns_of d1)" "6"
check "spawn logged"        "$(spawn_count d1)" "1"
check "no alert"            "$(alert_count)"    "0"

###############################################################################
# S5 LIVE sub-orch -> untouched
###############################################################################
scenario "S5 live sub-orch => no spawn, no alert, respawns unchanged, running"
fresh_root; reset_env
mkmeta d1 "$(mline state running)" "$(mline respawns 3)"
LIVE_RC=0   # window alive -> whole if-body skipped
cmd_reconcile
check "state still running" "$(state_of d1)"  "running"
check "respawns unchanged=3" "$(respawns_of d1)" "3"
check "no spawn"            "$(spawn_count d1)" "0"
check "no alert"            "$(alert_count)"    "0"

###############################################################################
# S6 ALREADY-TERMINAL skip (done / failed / cancelled)
###############################################################################
scenario "S6 already-terminal => skipped entirely"
fresh_root; reset_env
mkmeta d1 "$(mline state done)"      "$(mline respawns 0)"
mkmeta d2 "$(mline state failed)"    "$(mline respawns 0)"
mkmeta d3 "$(mline state cancelled)" "$(mline respawns 0)"
# defaults: dead window, no worker, responsive — would normally fire spawn/fail
cmd_reconcile
check "d1 state=done unchanged"     "$(state_of d1)"    "done"
check "d1 respawns unchanged=0"     "$(respawns_of d1)" "0"
check "d2 state=failed unchanged"   "$(state_of d2)"    "failed"
check "d2 respawns unchanged=0"     "$(respawns_of d2)" "0"
check "d3 state=cancelled unchanged" "$(state_of d3)"   "cancelled"
check "d3 respawns unchanged=0"     "$(respawns_of d3)" "0"
check "no spawns at all"            "$(grep -c SPAWN "$ROOT/spawns.log")" "0"
check "no alerts at all"            "$(alert_count)"    "0"

###############################################################################
# S7 CAP boundary with FLEET_RECONCILE_CAP=2
###############################################################################
scenario "S7a cap=2, respawns=1 (under) => respawn->2"
fresh_root; reset_env
mkmeta d1 "$(mline state running)" "$(mline respawns 1)"
FLEET_RECONCILE_CAP=2
cmd_reconcile
check "state still running" "$(state_of d1)"  "running"
check "respawns bumped=2"   "$(respawns_of d1)" "2"
check "spawn logged"        "$(spawn_count d1)" "1"
check "no alert"            "$(alert_count)"    "0"

scenario "S7b cap=2, respawns=2 (>=cap)+no worker+responsive => failed"
fresh_root; reset_env
mkmeta d1 "$(mline state running)" "$(mline respawns 2)"
FLEET_RECONCILE_CAP=2 HASWORK_RC=1 TMUX_INFO_RC=0
cmd_reconcile
check "state=failed"     "$(state_of d1)"    "failed"
check "respawns unchanged=2" "$(respawns_of d1)" "2"
check "alert present"    "$(alert_count)"    "1"
check "no spawn"         "$(spawn_count d1)" "0"

###############################################################################
# S8 numeric guard: respawns="" and "abc" treated as 0
###############################################################################
scenario "S8a respawns missing (empty) => treated as 0, respawn->1"
fresh_root; reset_env
mkmeta d1 "$(mline state running)"   # no respawns line at all
cmd_reconcile
check "state still running" "$(state_of d1)"  "running"
check "respawns set=1"      "$(respawns_of d1)" "1"
check "spawn logged"        "$(spawn_count d1)" "1"
check "no alert"            "$(alert_count)"    "0"

scenario "S8b respawns='abc' (non-numeric) => treated as 0, respawn->1"
fresh_root; reset_env
mkmeta d1 "$(mline state running)" "$(mline respawns abc)"
cmd_reconcile
check "state still running" "$(state_of d1)"  "running"
check "respawns set=1"      "$(respawns_of d1)" "1"
check "spawn logged"        "$(spawn_count d1)" "1"
check "no alert"            "$(alert_count)"    "0"

###############################################################################
# S9 (bonus) multiple dispatch dirs handled independently in one call
###############################################################################
scenario "S9 mixed dirs independent in one cmd_reconcile"
fresh_root; reset_env
mkmeta d1 "$(mline state running)" "$(mline respawns 0)"   # under cap -> respawn
mkmeta d2 "$(mline state running)" "$(mline respawns 1)"   # over cap -> fail (no worker, responsive)
mkmeta d3 "$(mline state done)"    "$(mline respawns 0)"   # terminal -> skip
LIVE_RC=1 HASWORK_RC=1 TMUX_INFO_RC=0
cmd_reconcile
check "d1 respawned ->1"   "$(respawns_of d1)" "1"
check "d1 spawn logged"    "$(spawn_count d1)" "1"
check "d1 still running"   "$(state_of d1)"    "running"
check "d2 failed"          "$(state_of d2)"    "failed"
check "d2 no spawn"        "$(spawn_count d2)" "0"
check "d3 skipped done"    "$(state_of d3)"    "done"
check "d3 no spawn"        "$(spawn_count d3)" "0"
check "exactly one alert"  "$(alert_count)"    "1"

###############################################################################
echo
echo "================ RESULT ================"
echo "PASS=$PASS  FAIL=$FAIL"
[ -n "$FAILED_NAMES" ] && echo "FAILED:$FAILED_NAMES"
rm -rf "$EXTRACT_DIR"
[ "$FAIL" -eq 0 ] && echo "VERDICT: DONE" || echo "VERDICT: NEEDS-WORK"
exit "$FAIL"

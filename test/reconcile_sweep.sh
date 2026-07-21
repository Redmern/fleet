#!/usr/bin/env bash
# Deterministic proof harness for the runaway sub-orchestrator spawn fix (3 layers).
#
# NO live tmux fan-out. We sed-extract the REAL functions from bin/fleet
# (meta_*, dispatch_age_secs, cmd_reconcile) into a temp lib, stub the spawn
# primitive + liveness probes + tmux, drive cmd_reconcile over a synthetic ledger,
# and COUNT spawns via a shim log. The K-window runaway is reproduced as a number
# (SPAWN_LOG line count); the fix is proven by that number dropping to the budget.
#
# Pre-fix: scenario L1 spawns K (RED). Post-fix: every scenario GREEN.
#
# Isolation: every scenario uses its own mktemp -d root; we NEVER touch the real
# .fleet ledger. fleet_root/session_name are stubbed to the temp root.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
FLEET_BIN="${FLEET_BIN:-$HERE/../bin/fleet}"
[ -f "$FLEET_BIN" ] || { echo "FATAL: bin/fleet not found at $FLEET_BIN"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [ "$1" = "$2" ]; then ok "$3 ($1)"; else no "$3 (got '$1' want '$2')"; fi; }

# --- Extract the real functions under test from bin/fleet -----------------------
LIB=$(mktemp); trap 'rm -f "$LIB"' EXIT
extract() { sed -n "/^$1() {/,/^}/p" "$FLEET_BIN" >> "$LIB"; }
for fn in meta_get meta_set meta_compact dispatch_age_secs cmd_reconcile; do
  extract "$fn"
done
# dispatch_age_secs may be absent pre-impl; cmd_reconcile must exist.
grep -q '^cmd_reconcile()' "$LIB" || { echo "FATAL: cmd_reconcile not extracted"; exit 2; }

# Build a scenario sandbox: temp root + stubs, source the extracted lib.
# Usage: run_sweep <root>  (env knobs FLEET_RECONCILE_* / FLEET_RESPAWN_MAX honoured)
# Stubs are exported via a generated preamble so each sweep runs in a fresh subshell
# with deterministic liveness/spawn behaviour.
#   STUB_LIVE       : return code for suborch_live (0=live,1=dead). default 1 (dead)
#   STUB_WORKERS    : return code for suborch_has_live_workers. default 1 (none)
#   STUB_TMUX_INFO  : return code for `tmux info`. default 0 (responsive)
run_sweep() {
  # NB: var names here MUST NOT collide with cmd_reconcile's locals
  # (`local sess root led d id state`). Bash is dynamic-scoped, so a stub that reads
  # `$root` would see cmd_reconcile's (empty) local, not ours — hence FROOT/FLOG.
  local FROOT="$1"
  local stub_live="${STUB_LIVE:-1}" stub_workers="${STUB_WORKERS:-1}" stub_tmux="${STUB_TMUX_INFO:-0}"
  local FLOG="$FROOT/.spawnlog"; : > "$FLOG"
  SPAWN_LOG="$FLOG"
  # The subshell inherits FROOT/stub_*/FLOG/LIB as in-scope locals; stubs reference
  # them and override the sourced lib (defined AFTER source so the definitions win).
  (
    set +u
    session_name() { printf 'testsess'; }
    fleet_root()   { printf '%s' "$FROOT"; }
    append_dashboard_alert() { printf '%s\n' "$1" >> "$FROOT/.alerts"; }
    source "$LIB"
    # stubs override the sourced lib (must come after source) ---------------------
    suborch_live()              { return "$stub_live"; }
    suborch_has_live_workers()  { return "$stub_workers"; }
    # tmux shim: only `info` is consulted by cmd_reconcile.
    tmux() { case "$1" in info) return "$stub_tmux";; *) return 0;; esac; }
    # spawn shim: log the would-be window name instead of fanning out tmux. Uses $4
    # (the root arg) — NOT $root — for the same dynamic-scope reason as above.
    resolve_or_spawn_suborch() { # <sess> <wname> <id> <root>
      printf '%s\t%s\n' "$3" "$2" >> "$FLOG"
      # mimic the real pin: a spawn persists window_id so liveness is id-resolved
      meta_set "$4/.fleet/dispatch/$3" window_id "@win-$3"
    }
    cmd_reconcile
  )
}

# Create a synthetic dispatch dir. Usage: mk <root> <id> <state> <respawns> <age_secs>
mk() {
  local root="$1" id="$2" state="$3" respawns="$4" age="$5"
  local d="$root/.fleet/dispatch/$id"; mkdir -p "$d"
  # created = now - age_secs, ISO-8601 so dispatch_age_secs parses it.
  local created; created=$(date -d "@$(( $(date +%s) - age ))" -Is 2>/dev/null || date -Is)
  {
    printf 'state\t%s\n' "$state"
    printf 'respawns\t%s\n' "$respawns"
    printf 'created\t%s\n' "$created"
    printf 'window\tso-%s\n' "$id"
  } > "$d/meta.tsv"
}
state_of() { sed -n 's/^state\t//p' "$1/meta.tsv" | tail -1; }
spawns()   { wc -l < "$1/.spawnlog" | tr -d ' '; }

echo "== reconcile_sweep proof harness =="
echo "   bin/fleet: $FLEET_BIN"
echo "   dispatch_age_secs present in source: $(grep -qc '^dispatch_age_secs()' "$FLEET_BIN" && echo yes || echo no)"
echo

# ============================================================================
# Scenario L1 — RED repro / Layer 1 budget: K dead non-terminal corpses, one sweep.
# Pre-fix: spawns == K (runaway). Post-fix: spawns <= FLEET_RECONCILE_SWEEP (1).
# ============================================================================
echo "[L1] K dead non-terminal dispatches, single sweep"
K=6
R=$(mktemp -d)
for i in $(seq 1 $K); do mk "$R" "d$i" running 0 9999; done
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
N=$(spawns "$R")
echo "    spawns this sweep = $N  (K=$K, budget=${FLEET_RECONCILE_SWEEP:-1})"
# RED evidence on unfixed code: N == K. GREEN target: N <= 1.
if [ "$N" -le 1 ]; then ok "L1 sweep bounded to <=1 spawn"; else no "L1 RUNAWAY: $N spawns from one sweep (expected <=1)"; fi
# spawned window name must be a sub-orch (so-dN), closing the screenshot caveat.
if [ "$N" -ge 1 ]; then
  wname=$(head -1 "$R/.spawnlog" | cut -f2)
  case "$wname" in so-d*) ok "L1 spawned a sub-orch window ($wname)";; *) no "L1 spawned non-suborch '$wname'";; esac
fi
rm -rf "$R"

# Paced across K sweeps (simulating K prompts) — never bursty.
echo "[L1b] K sequential sweeps stay 1-per-call (no burst)"
R=$(mktemp -d); for i in $(seq 1 $K); do mk "$R" "d$i" running 0 0; done  # age 0 => within grace, re-animate path
maxburst=0
for s in $(seq 1 $K); do
  STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
  b=$(spawns "$R"); [ "$b" -gt "$maxburst" ] && maxburst=$b
done
if [ "$maxburst" -le 1 ]; then ok "L1b max per-sweep burst <=1 ($maxburst)"; else no "L1b bursty sweep: $maxburst"; fi
rm -rf "$R"

# ============================================================================
# Scenario L2 — death sentinel: aged corpse, no live workers => failed, NOT spawned.
# ============================================================================
echo "[L2] aged corpse (dead, no workers, aged) => failed, no spawn"
R=$(mktemp -d); mk "$R" d1 running 0 9999
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
eq "$(state_of "$R/.fleet/dispatch/d1")" failed "L2 aged corpse marked failed"
eq "$(spawns "$R")" 0 "L2 aged corpse NOT spawned"
rm -rf "$R"

echo "[L2b] dead pane but LIVE workers => re-animate (no false-kill)"
R=$(mktemp -d); mk "$R" d1 running 0 9999
STUB_LIVE=1 STUB_WORKERS=0 STUB_TMUX_INFO=0 run_sweep "$R"   # WORKERS=0 => has_live_workers true
eq "$(state_of "$R/.fleet/dispatch/d1")" running "L2b live-worker pipeline kept alive"
eq "$(spawns "$R")" 1 "L2b live-worker pipeline re-animated"
rm -rf "$R"

echo "[L2c] within-grace fresh corpse => not killed (re-animate within budget)"
R=$(mktemp -d); mk "$R" d1 running 0 0    # age 0 < grace
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
eq "$(state_of "$R/.fleet/dispatch/d1")" running "L2c within-grace not failed"
eq "$(spawns "$R")" 1 "L2c within-grace re-animated"
rm -rf "$R"

echo "[L2d] tmux unresponsive => never mass-fail (respawn instead)"
R=$(mktemp -d); mk "$R" d1 running 0 9999
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=1 run_sweep "$R"   # tmux info fails
eq "$(state_of "$R/.fleet/dispatch/d1")" running "L2d unresponsive tmux: not failed"
eq "$(spawns "$R")" 1 "L2d unresponsive tmux: re-animated"
rm -rf "$R"

# ============================================================================
# Scenario L3 — absolute per-id ceiling: respawns>=MAX fails EVEN with live workers.
# ============================================================================
echo "[L3] per-id ceiling: respawns>=FLEET_RESPAWN_MAX + live workers => failed"
R=$(mktemp -d); mk "$R" d1 running 5 9999    # respawns=5 >= default MAX 5
STUB_LIVE=1 STUB_WORKERS=0 STUB_TMUX_INFO=0 run_sweep "$R"   # WORKERS live, would normally re-animate
eq "$(state_of "$R/.fleet/dispatch/d1")" failed "L3 ceiling fires despite live workers"
eq "$(spawns "$R")" 0 "L3 ceiling: not spawned"
rm -rf "$R"

echo "[L3b] single id cannot exceed ceiling across repeated sweeps"
R=$(mktemp -d); mk "$R" d1 running 0 0       # start fresh, within grace, live workers
# Each sweep: live-worker re-animate bumps respawns by 1, until the ceiling bites.
for s in $(seq 1 8); do
  STUB_LIVE=1 STUB_WORKERS=0 STUB_TMUX_INFO=0 run_sweep "$R"
done
final_resp=$(sed -n 's/^respawns\t//p' "$R/.fleet/dispatch/d1/meta.tsv" | tail -1)
eq "$(state_of "$R/.fleet/dispatch/d1")" failed "L3b id terminally failed, not churning forever"
if [ "${final_resp:-0}" -le 5 ]; then ok "L3b respawns capped at ceiling ($final_resp <= 5)"; else no "L3b respawns ran away: $final_resp"; fi
rm -rf "$R"

# ============================================================================
# Scenario REG — regressions: live + terminal dispatches untouched.
# ============================================================================
echo "[REG] live sub-orch never touched; terminal skipped"
R=$(mktemp -d); mk "$R" d1 running 0 9999
STUB_LIVE=0 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"   # LIVE
eq "$(state_of "$R/.fleet/dispatch/d1")" running "REG live dispatch state unchanged"
eq "$(spawns "$R")" 0 "REG live dispatch not respawned"
rm -rf "$R"

R=$(mktemp -d); mk "$R" d1 done 0 9999
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"   # terminal, dead
eq "$(state_of "$R/.fleet/dispatch/d1")" done "REG terminal(done) skipped"
eq "$(spawns "$R")" 0 "REG terminal(done) not spawned"
rm -rf "$R"

R=$(mktemp -d); mk "$R" d1 failed 0 9999
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
eq "$(spawns "$R")" 0 "REG terminal(failed) not spawned"
rm -rf "$R"

# ============================================================================
# Scenario MIX — the incident shape: K corpses in ONE sweep, budget bounds spawns
# AND corpses still drain (failed), proving Layer1+Layer2 compose.
# ============================================================================
echo "[MIX] K aged corpses, one sweep: <=budget spawns, corpses drain to failed"
R=$(mktemp -d); for i in $(seq 1 $K); do mk "$R" "d$i" running 0 9999; done
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
nf=0; for i in $(seq 1 $K); do [ "$(state_of "$R/.fleet/dispatch/d$i")" = failed ] && nf=$((nf+1)); done
eq "$(spawns "$R")" 0 "MIX no spawns (all corpses sentinel-failed first)"
eq "$nf" "$K" "MIX all K corpses drained to failed in one sweep"
rm -rf "$R"

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

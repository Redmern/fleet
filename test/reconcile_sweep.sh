#!/usr/bin/env bash
# Deterministic proof harness for the runaway sub-orchestrator spawn fix (3 layers)
# AND its integration with the gate-park skip (main's 88fefb0).
#
# NO live tmux fan-out. We sed-extract the REAL functions from bin/fleet
# (meta_*, dispatch_age_secs, the ledger classifiers, cmd_reconcile) into a temp
# lib, stub the spawn primitive + liveness probes + tmux, drive cmd_reconcile over a
# synthetic ledger, and COUNT spawns via a shim log. The K-window runaway is
# reproduced as a number (SPAWN_LOG line count); the fix is proven by that number
# dropping to the budget.
#
# RED->GREEN is SELF-CONTAINED (scenario L1): the same K-corpse sweep is run twice —
# once with FLEET_RECONCILE_SWEEP cranked wide open (budget disabled => the runaway
# returns as spawns==K, RED) and once at the default budget (spawns<=1, GREEN).
#
# Isolation belt (a harness took down the live tmux session twice on 2026-07-20):
#   * every scenario uses its own `mktemp -d` root; we NEVER touch the real .fleet
#     ledger — fleet_root/session_name are stubbed to the temp root.
#   * tmux is a pure in-file stub that NEVER execs a real tmux — it cannot reach any
#     server. As a tripwire we still resolve $SOCK under our own mktemp TMPROOT and
#     refuse to start unless it lives there, and force TMUX_TMPDIR/empty TMUX so any
#     accidental future real-tmux subprocess lands on an isolated socket, not `pc`.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
FLEET_BIN="${FLEET_BIN:-$HERE/../bin/fleet}"
[ -f "$FLEET_BIN" ] || { echo "FATAL: bin/fleet not found at $FLEET_BIN"; exit 2; }

# --- ISOLATION BELT: never touch a real tmux server or the real ledger ----------
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/reconcile_sweep.XXXXXX") || { echo "FATAL: mktemp"; exit 2; }
SOCK="$TMPROOT/tmux.sock"
# Tripwire: refuse to run unless our socket path lives under our own mktemp root — a
# guard against a future edit that resolves SOCK from the environment/real server.
case "$SOCK" in
  "$TMPROOT"/*) : ;;
  *) echo "FATAL: SOCK ($SOCK) escaped TMPROOT ($TMPROOT) — refusing to run"; exit 2 ;;
esac
# Any accidental real `tmux` subprocess must land on an isolated server, never `pc`.
export TMUX= TMUX_TMPDIR="$TMPROOT"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [ "$1" = "$2" ]; then ok "$3 ($1)"; else no "$3 (got '$1' want '$2')"; fi; }

# --- Extract the real functions under test from bin/fleet -----------------------
LIB=$(mktemp "$TMPROOT/lib.XXXXXX")
extract() { sed -n "/^$1() {/,/^}/p" "$FLEET_BIN" >> "$LIB"; }
for fn in meta_get meta_set meta_compact dispatch_age_secs cmd_reconcile; do
  extract "$fn"
done
# ledger_terminal/ledger_parked are SINGLE-LINE definitions (`name() { … }` all on one
# line), so the multi-line `extract` sed would over-slurp to the next `^}`. Pull the
# whole one-liner with grep instead — this uses the REAL predicate cmd_reconcile calls,
# not a hand-rolled copy (the single-classification-point contract, per CLAUDE.md).
for fn in ledger_terminal ledger_parked; do
  grep -m1 "^$fn()" "$FLEET_BIN" >> "$LIB"
done
# dispatch_age_secs may be absent pre-impl; cmd_reconcile must exist.
grep -q '^cmd_reconcile()' "$LIB" || { echo "FATAL: cmd_reconcile not extracted"; exit 2; }
grep -q '^ledger_terminal()' "$LIB" || { echo "FATAL: ledger_terminal not extracted"; exit 2; }
grep -q '^ledger_parked()'   "$LIB" || { echo "FATAL: ledger_parked not extracted"; exit 2; }

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
    # Husk-prune + gate escalation are real callees of cmd_reconcile's abandon/parked
    # arms; stub them so a sweep neither shells out nor mutates ledger STATE through
    # them (gate_orphan_escalate flips only the gate_orphan FLAG, not state).
    suborch_prune_orphan_window() { return 0; }
    gate_orphan_escalate()        { meta_set "$2" gate_orphan 1; }
    # tmux shim: NEVER execs a real tmux; only `info` is consulted by cmd_reconcile.
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
mktmp_root() { mktemp -d "$TMPROOT/root.XXXXXX"; }

echo "== reconcile_sweep proof harness =="
echo "   bin/fleet: $FLEET_BIN"
echo "   dispatch_age_secs present in source: $(grep -qc '^dispatch_age_secs()' "$FLEET_BIN" && echo yes || echo no)"
echo "   TMPROOT (isolated): $TMPROOT"
echo

# ============================================================================
# Scenario L1 — Layer 1 spawn BUDGET, isolated from the sentinel, RED->GREEN.
# All K corpses are WITHIN GRACE (age 0), so the sentinel never drains them and
# every one reaches the ALLOCATING path — the budget is then the ONLY thing that
# bounds spawns. RED arm cranks the knob open (runaway returns); GREEN arm at the
# default budget bounds it.
#   Mutation proving each assertion can fail:
#     L1 RED  — if the budget deferral is removed / knob ignored, spawns stay K
#               even at default => the GREEN assertion (<=1) fails.  Conversely the
#               RED assertion (==K at budget=999) fails if a spurious cap sneaks in.
# ============================================================================
K=6
echo "[L1] Layer-1 budget isolates the K-window runaway (age 0 => all reach allocating)"
# RED arm: budget cranked wide open => the runaway reproduces as spawns == K.
R=$(mktmp_root); for i in $(seq 1 $K); do mk "$R" "d$i" running 0 0; done
FLEET_RECONCILE_SWEEP=999 STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
red=$(spawns "$R")
echo "    RED  arm (budget=999): spawns=$red  (K=$K)"
eq "$red" "$K" "L1 RED: budget disabled reproduces the K-window runaway"
rm -rf "$R"
# GREEN arm: default budget (1) bounds the identical shape to <=1.
R=$(mktmp_root); for i in $(seq 1 $K); do mk "$R" "d$i" running 0 0; done
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
grn=$(spawns "$R")
echo "    GREEN arm (default budget): spawns=$grn"
if [ "$grn" -le 1 ]; then ok "L1 GREEN: default budget bounds runaway to <=1 ($grn)"; else no "L1 GREEN RUNAWAY: $grn spawns (expected <=1)"; fi
# the spawned window must be a sub-orch (so-dN), closing the "what got spawned" caveat.
if [ "$grn" -ge 1 ]; then
  wname=$(head -1 "$R/.spawnlog" | cut -f2)
  case "$wname" in so-d*) ok "L1 spawned a sub-orch window ($wname)";; *) no "L1 spawned non-suborch '$wname'";; esac
fi
rm -rf "$R"

# Paced across K sweeps (simulating K prompts) — never bursty.
#   Mutation: remove the `sweep_spawned>=sweep_budget` deferral and maxburst jumps to K.
echo "[L1b] K sequential sweeps stay 1-per-call (no burst)"
R=$(mktmp_root); for i in $(seq 1 $K); do mk "$R" "d$i" running 0 0; done  # age 0 => within grace, re-animate path
maxburst=0
for s in $(seq 1 $K); do
  STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
  b=$(spawns "$R"); [ "$b" -gt "$maxburst" ] && maxburst=$b
done
if [ "$maxburst" -le 1 ]; then ok "L1b max per-sweep burst <=1 ($maxburst)"; else no "L1b bursty sweep: $maxburst"; fi
rm -rf "$R"

# ============================================================================
# Scenario L2 — death sentinel: aged corpse, no live workers => failed, NOT spawned.
#   Mutation: drop the `age>=grace` sentinel arm and the aged corpse re-animates
#   (state stays running, spawns=1) => both L2 assertions fail.
# ============================================================================
echo "[L2] aged corpse (dead, no workers, aged) => failed, no spawn"
R=$(mktmp_root); mk "$R" d1 running 0 9999
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
eq "$(state_of "$R/.fleet/dispatch/d1")" failed "L2 aged corpse marked failed"
eq "$(spawns "$R")" 0 "L2 aged corpse NOT spawned"
rm -rf "$R"

echo "[L2b] dead pane but LIVE workers => re-animate (no false-kill)"
R=$(mktmp_root); mk "$R" d1 running 0 9999
STUB_LIVE=1 STUB_WORKERS=0 STUB_TMUX_INFO=0 run_sweep "$R"   # WORKERS=0 => has_live_workers true
eq "$(state_of "$R/.fleet/dispatch/d1")" running "L2b live-worker pipeline kept alive"
eq "$(spawns "$R")" 1 "L2b live-worker pipeline re-animated"
rm -rf "$R"

echo "[L2c] within-grace fresh corpse => not killed (re-animate within budget)"
R=$(mktmp_root); mk "$R" d1 running 0 0    # age 0 < grace
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
eq "$(state_of "$R/.fleet/dispatch/d1")" running "L2c within-grace not failed"
eq "$(spawns "$R")" 1 "L2c within-grace re-animated"
rm -rf "$R"

echo "[L2d] tmux unresponsive => never mass-fail (respawn instead)"
R=$(mktmp_root); mk "$R" d1 running 0 9999
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=1 run_sweep "$R"   # tmux info fails
eq "$(state_of "$R/.fleet/dispatch/d1")" running "L2d unresponsive tmux: not failed"
eq "$(spawns "$R")" 1 "L2d unresponsive tmux: re-animated"
rm -rf "$R"

# ============================================================================
# Scenario L3 — absolute per-id ceiling: respawns>=MAX fails EVEN with live workers.
#   Mutation: gate the ceiling on `!has_workers` (like the old cap) and L3 re-animates
#   (state running, spawns=1) because it owns live workers => both assertions fail.
# ============================================================================
echo "[L3] per-id ceiling: respawns>=FLEET_RESPAWN_MAX + live workers => failed"
R=$(mktmp_root); mk "$R" d1 running 5 9999    # respawns=5 >= default MAX 5
STUB_LIVE=1 STUB_WORKERS=0 STUB_TMUX_INFO=0 run_sweep "$R"   # WORKERS live, would normally re-animate
eq "$(state_of "$R/.fleet/dispatch/d1")" failed "L3 ceiling fires despite live workers"
eq "$(spawns "$R")" 0 "L3 ceiling: not spawned"
rm -rf "$R"

echo "[L3b] single id cannot exceed ceiling across repeated sweeps"
R=$(mktmp_root); mk "$R" d1 running 0 0       # start fresh, within grace, live workers
# Each sweep: live-worker re-animate bumps respawns by 1, until the ceiling bites.
for s in $(seq 1 8); do
  STUB_LIVE=1 STUB_WORKERS=0 STUB_TMUX_INFO=0 run_sweep "$R"
done
final_resp=$(sed -n 's/^respawns\t//p' "$R/.fleet/dispatch/d1/meta.tsv" | tail -1)
eq "$(state_of "$R/.fleet/dispatch/d1")" failed "L3b id terminally failed, not churning forever"
if [ "${final_resp:-0}" -le 5 ]; then ok "L3b respawns capped at ceiling ($final_resp <= 5)"; else no "L3b respawns ran away: $final_resp"; fi
rm -rf "$R"

# ============================================================================
# Scenario PARK — INTEGRATION: a gate-parked dispatch is NEVER touched by the
# budget / sentinel / ceiling (88fefb0's guarantee must survive this branch's guards).
# A parked dispatch that is dead + aged + owns no workers would, if it were `running`,
# be sentinel-failed; parked, it must stay parked and never spawn.
#   Mutation: delete the `if ledger_parked "$state"` skip block in cmd_reconcile and
#   the parked corpse falls into the sentinel => state flips to `failed` (PARK fails),
#   or (within grace) gets re-animated => spawns=1. Either way both PARK assertions fail.
#   This is the guard that reconcile-gate-park-proof.sh proves end-to-end; here we prove
#   the runaway layers specifically do not disturb it.
# ============================================================================
echo "[PARK] gate1-wait dead corpse => left parked, never sentinel-failed, never spawned"
R=$(mktmp_root); mk "$R" d1 gate1-wait 0 9999
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
eq "$(state_of "$R/.fleet/dispatch/d1")" gate1-wait "PARK parked state preserved (sentinel did not fire)"
eq "$(spawns "$R")" 0 "PARK parked dispatch not respawned"
rm -rf "$R"

echo "[PARK2] gate2-wait alongside K corpses: corpses drain, parked untouched, no spawn"
R=$(mktmp_root); mk "$R" d1 gate2-wait 0 9999
for i in 2 3 4; do mk "$R" "d$i" running 0 9999; done
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
eq "$(state_of "$R/.fleet/dispatch/d1")" gate2-wait "PARK2 parked survives a corpse-draining sweep"
nf=0; for i in 2 3 4; do [ "$(state_of "$R/.fleet/dispatch/d$i")" = failed ] && nf=$((nf+1)); done
eq "$nf" 3 "PARK2 the 3 running corpses drained to failed"
eq "$(spawns "$R")" 0 "PARK2 no spawns (parked skipped, corpses sentinel-failed)"
rm -rf "$R"

echo "[PARK3] parked + budget cranked open => STILL never revived (budget can't override skip)"
R=$(mktmp_root); mk "$R" d1 gate1-wait 0 0   # within grace: for `running` this would re-animate
FLEET_RECONCILE_SWEEP=999 STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
eq "$(state_of "$R/.fleet/dispatch/d1")" gate1-wait "PARK3 parked untouched even with budget wide open"
eq "$(spawns "$R")" 0 "PARK3 parked not spawned even at budget=999"
rm -rf "$R"

# ============================================================================
# Scenario REG — regressions: live + terminal dispatches untouched.
#   Mutation: replace `ledger_terminal "$state" && continue` with a no-op and the
#   dead `done`/`failed` dispatches fall into the sentinel => REG terminal(done) flips
#   state and the not-spawned counts break.
# ============================================================================
echo "[REG] live sub-orch never touched; terminal skipped"
R=$(mktmp_root); mk "$R" d1 running 0 9999
STUB_LIVE=0 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"   # LIVE
eq "$(state_of "$R/.fleet/dispatch/d1")" running "REG live dispatch state unchanged"
eq "$(spawns "$R")" 0 "REG live dispatch not respawned"
rm -rf "$R"

R=$(mktmp_root); mk "$R" d1 done 0 9999
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"   # terminal, dead
eq "$(state_of "$R/.fleet/dispatch/d1")" done "REG terminal(done) skipped"
eq "$(spawns "$R")" 0 "REG terminal(done) not spawned"
rm -rf "$R"

R=$(mktmp_root); mk "$R" d1 failed 0 9999
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
eq "$(spawns "$R")" 0 "REG terminal(failed) not spawned"
rm -rf "$R"

# ============================================================================
# Scenario MIX — the incident shape: K corpses in ONE sweep, budget bounds spawns
# AND corpses still drain (failed), proving Layer1+Layer2 compose.
#   Mutation: drop the sentinel and the K aged corpses re-animate under the budget
#   (spawns rises to 1 and nf drops to 0) => both MIX assertions fail.
# ============================================================================
echo "[MIX] K aged corpses, one sweep: <=budget spawns, corpses drain to failed"
R=$(mktmp_root); for i in $(seq 1 $K); do mk "$R" "d$i" running 0 9999; done
STUB_LIVE=1 STUB_WORKERS=1 STUB_TMUX_INFO=0 run_sweep "$R"
nf=0; for i in $(seq 1 $K); do [ "$(state_of "$R/.fleet/dispatch/d$i")" = failed ] && nf=$((nf+1)); done
eq "$(spawns "$R")" 0 "MIX no spawns (all corpses sentinel-failed first)"
eq "$nf" "$K" "MIX all K corpses drained to failed in one sweep"
rm -rf "$R"

# ============================================================================
# Scenario KNOB — numeric-knob sanitization: garbage env must fail-silent to the
# default, never leak `[: integer expression expected` or disable a layer.
#   Mutation: remove the `case … *[!0-9]* … esac` coercions and a garbage
#   FLEET_RESPAWN_MAX makes `[ "$n" -ge "$respawn_max" ]` error => ceiling silently
#   disabled, L3-shaped corpse re-animates => this assertion (failed) breaks.
# ============================================================================
echo "[KNOB] garbage numeric env coerces to default (fail-silent), layer still fires"
R=$(mktmp_root); mk "$R" d1 running 5 9999
FLEET_RESPAWN_MAX=notanum STUB_LIVE=1 STUB_WORKERS=0 STUB_TMUX_INFO=0 run_sweep "$R" 2>"$R/.err"
eq "$(state_of "$R/.fleet/dispatch/d1")" failed "KNOB garbage RESPAWN_MAX -> default 5, ceiling still fires"
if grep -q 'integer expression' "$R/.err"; then no "KNOB leaked integer-expression error to stderr"; else ok "KNOB no integer-expression error leaked"; fi
rm -rf "$R"

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

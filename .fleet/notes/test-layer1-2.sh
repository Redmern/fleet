#!/usr/bin/env bash
# Test phase (Tester A): prove LAYERS 1 + 2 of the zombie-reconcile fix (commit de13b6b).
#   Layer 1: `fleet dispatch done|fail|cancel <id>` terminal verb (cmd_dispatch_finish)
#   Layer 2: fleet-dash confirm_teardown teardown stickiness guard
# Read-only on bin/*; never touches the live /home/red/proj/pc-tune ledger.
set -u

REPO="/home/red/proj/pc-tune/fleet/fleet_reconcile-zombie-terminal-state"
FLEET_BIN="$REPO/bin/fleet"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 — want [$3] got [$2]"; fi; }

# --- ISOLATION: every real-fleet invocation pins root to a fresh /tmp dir ---
fl() { FLEET_SESSION=__nope__ FLEET_ROOT="$T" "$FLEET_BIN" "$@"; }

newT() {
  T=$(mktemp -d)
  case "$T" in /tmp/*|/tmp) : ;; *) printf 'FATAL: T not under /tmp: %s\n' "$T" >&2; exit 99 ;; esac
}

# read state key from a ledger meta.tsv (last-wins)
rstate() { awk -F'\t' '$1=="state"{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

# build a fixture dispatch dir with state=running (+ instruction.txt so it's a real ledger)
mkfix() { # <id>
  local d="$T/.fleet/dispatch/$1"
  mkdir -p "$d"
  printf 'state\trunning\n' > "$d/meta.tsv"
  printf 'do a thing\n'      > "$d/instruction.txt"
  printf '%s' "$d"
}

echo "===================== LAYER 1: cmd_dispatch_finish ====================="

# --- 1. each verb writes the right terminal state, prints msg, rc 0 ---
for pair in "done done" "fail failed" "failed failed" "cancel cancelled" "cancelled cancelled"; do
  set -- $pair; verb="$1"; want="$2"
  newT; d=$(mkfix d1)
  out=$(fl dispatch "$verb" d1 2>/dev/null); rc=$?
  chk "L1.1 verb=$verb rc"          "$rc" 0
  chk "L1.1 verb=$verb state"       "$(rstate "$d")" "$want"
  chk "L1.1 verb=$verb stdout"      "$out" "dispatch d1 → $want"
  rm -rf "$T"
done

# --- 2. last-wins / idempotent ---
newT; d=$(mkfix d1)
fl dispatch done d1 >/dev/null 2>&1
out=$(fl dispatch fail d1 2>/dev/null); rc=$?
chk "L1.2 done→fail rc"    "$rc" 0
chk "L1.2 done→fail state" "$(rstate "$d")" failed
rm -rf "$T"

newT; d=$(mkfix d1)
fl dispatch done d1 >/dev/null 2>&1
out=$(fl dispatch done d1 2>/dev/null); rc=$?
chk "L1.2 done→done rc"    "$rc" 0
chk "L1.2 done→done state" "$(rstate "$d")" done
rm -rf "$T"

# --- 3. die-loud on misuse (rc != 0) ---
# bad verb. NOTE: 'bogus' is NOT a recognised verb, so cmd_dispatch's case falls
# THROUGH to the generic id path (treats 'bogus' as the dispatch id). So the error
# we actually get is the generic-path die, not the finish-verb usage string. We
# assert rc!=0 + an error on stderr, and record the exact message for the report.
newT; mkfix d1 >/dev/null
err=$(fl dispatch bogus d1 2>&1 >/dev/null); rc=$?
if [ "$rc" -ne 0 ]; then ok "L1.3 bad-verb rc!=0 ($rc)"; else bad "L1.3 bad-verb rc!=0 — got 0"; fi
case "$err" in *usage*|*"no such dispatch"*) ok "L1.3 bad-verb stderr non-empty err [$err]" ;; *) bad "L1.3 bad-verb stderr — got [$err]" ;; esac
rm -rf "$T"

# missing id: `fleet dispatch done` (no id). 'done' IS a verb → routes to finish → usage.
newT
err=$(fl dispatch done 2>&1 >/dev/null); rc=$?
if [ "$rc" -ne 0 ]; then ok "L1.3 missing-id rc!=0 ($rc)"; else bad "L1.3 missing-id rc!=0 — got 0"; fi
case "$err" in *usage*) ok "L1.3 missing-id usage on stderr" ;; *) bad "L1.3 missing-id usage — got [$err]" ;; esac
rm -rf "$T"

# unknown dispatch: dir absent.
newT
err=$(fl dispatch done dZZ 2>&1 >/dev/null); rc=$?
if [ "$rc" -ne 0 ]; then ok "L1.3 unknown rc!=0 ($rc)"; else bad "L1.3 unknown rc!=0 — got 0"; fi
case "$err" in *"no such dispatch"*) ok "L1.3 unknown 'no such dispatch' on stderr" ;; *) bad "L1.3 unknown stderr — got [$err]" ;; esac
rm -rf "$T"

# --- 4. sanity: terminal write reads back equal (reconcile skip predicate input) ---
newT; d=$(mkfix d1)
fl dispatch done d1 >/dev/null 2>&1
chk "L1.4 readback==terminal" "$(rstate "$d")" done
rm -rf "$T"

echo "===================== LAYER 2: teardown stickiness ====================="

# Pull the REAL helpers out of bin/fleet-dash, stub dash_root onto our fixture.
eval "$(grep -E '^is_suborch_name\(\)' "$REPO/bin/fleet-dash")"
eval "$(sed -n '/^card_meta_state()/,/^}/p' "$REPO/bin/fleet-dash")"
dash_root(){ printf '%s' "$T"; }

# Reproduce the confirm_teardown guard + the close-branch cancel, verbatim in logic.
# Returns nothing; mutates the ledger only if the guard decides to cancel.
run_teardown_guard() { # <window_name>
  local _wn="$1" _did=""
  if is_suborch_name "$_wn"; then
    case "$(card_meta_state "$_wn")" in
      done|failed|cancelled) ;;                  # already terminal — leave it
      *) _did="${_wn#so-}"; _did="${_did%%-*}" ;;
    esac
  fi
  # close branch: kill window (n/a in test), then the guarded cancel.
  # (suppress the cancel command's own stdout so only the guard decision surfaces)
  [ -n "$_did" ] && fl dispatch cancel "$_did" >/dev/null 2>&1 || true
  printf '%s' "$_did"   # expose decision for assertion
}

# --- a. STICKINESS: a finished sub-orch torn down keeps its terminal state ---
for st in done failed cancelled; do
  newT; d=$(mkfix d3); printf 'state\t%s\n' "$st" > "$d/meta.tsv"   # already terminal
  did=$(run_teardown_guard "so-d3")
  chk "L2.a stick $st: _did empty (no cancel)" "${did:-<empty>}" "<empty>"
  chk "L2.a stick $st: state preserved"        "$(rstate "$d")"  "$st"
  rm -rf "$T"
done

# --- b. NON-TERMINAL: running -> cancel sets cancelled ---
newT; d=$(mkfix d4)   # state=running
did=$(run_teardown_guard "so-d4")
chk "L2.b running: _did=d4"          "$did" "d4"
chk "L2.b running: state→cancelled"  "$(rstate "$d")" cancelled
rm -rf "$T"

# NO state line at all -> card_meta_state empty -> non-terminal -> cancel fires
newT; d="$T/.fleet/dispatch/d4"; mkdir -p "$d"; printf 'created\tx\n' > "$d/meta.tsv"
did=$(run_teardown_guard "so-d4")
chk "L2.b no-state: _did=d4"         "$did" "d4"
chk "L2.b no-state: state→cancelled" "$(rstate "$d")" cancelled
rm -rf "$T"

# --- c. non-suborch names: guard body never runs, ledger untouched ---
newT
T_HOLD="$T"
for wn in "myrepo_feature" "scratch"; do
  if is_suborch_name "$wn"; then bad "L2.c is_suborch_name rejects '$wn'"; else ok "L2.c is_suborch_name rejects '$wn'"; fi
done
# even with a live ledger present, a non-suborch teardown must not touch it
d=$(mkfix d9)
did=$(run_teardown_guard "myrepo_feature")
chk "L2.c non-suborch: _did empty"      "${did:-<empty>}" "<empty>"
chk "L2.c non-suborch: ledger untouched" "$(rstate "$d")" running
rm -rf "$T"

# accepts slugged names + card_meta_state strips slug to d11
newT
if is_suborch_name "so-d11-new-project"; then ok "L2.c accepts slugged so-d11-new-project"; else bad "L2.c accepts slugged so-d11-new-project"; fi
d="$T/.fleet/dispatch/d11"; mkdir -p "$d"; printf 'state\tplanning\n' > "$d/meta.tsv"
chk "L2.c card_meta_state strips slug→d11" "$(card_meta_state 'so-d11-new-project')" planning
rm -rf "$T"

echo "======================================================================="
TOTAL=$((PASS+FAIL))
printf 'RESULT: %d/%d\n' "$PASS" "$TOTAL"
[ "$FAIL" -eq 0 ]

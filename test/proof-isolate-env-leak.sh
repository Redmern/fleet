#!/usr/bin/env bash
# Proof 9 (F1) — proof_isolate scrubs the ambient fleet env.
#
# THE BUG THIS LOCKS IN. A proof is usually run FROM a fleet pane, often a
# sub-orchestrator's. That pane exports FLEET_SUBORCH_ID, `bin/fleet` inherits
# it, and cmd_new owner-prefixes the spawned window name (`d32-parked` instead of
# `parked`). Every `wait_window parked` then misses and the proof dies on its
# first assertion with "parked scratch agent never spawned" — a message
# indistinguishable from the feature actually being broken. 6 of the 8 d32 proofs
# went red this way (2026-07-30).
#
# HOW THIS PROOF WORKS. It is a META-proof: it does NOT call proof_isolate or
# touch tmux itself. It re-runs a real proof as a child with hostile values
# deliberately exported, and asserts the child still goes green. All isolation
# (throwaway server, TMPROOT, EXIT teardown) is the child's own — so this script
# creates nothing and removes nothing.
#
# It fails against pre-fix code (the child goes red) and passes after — which is
# the whole point; a proof that passes either way would be worthless here.
set -u
. "$(cd "$(dirname "$0")" && pwd)/hidden-proof-common.sh"

# The victim: the cheapest proof that spawns a scratch agent AND a nested child
# from inside it, so it exercises both the wname prefix and the owner stamp.
VICTIM="$FLEET_REPO/test/proof-bar-omits-hidden.sh"

run_leak() { # run_leak <desc> <VAR=value>...
  local desc="$1"; shift
  local out rc
  out=$(env "$@" "$VICTIM" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$desc — victim proof still green"
  else
    no "$desc — victim proof went RED (rc=$rc): $(printf '%s\n' "$out" | grep -m2 '^FAIL' | tr '\n' ' ')"
  fi
  # Belt and braces: the specific symptom must be absent even if some other
  # assertion is what failed.
  case "$out" in
    *'never spawned'*) no "$desc — 'never spawned' symptom present (env leaked into cmd_new)" ;;
    *) ok "$desc — no 'never spawned' symptom" ;;
  esac
}

section 'case 1 — FLEET_SUBORCH_ID does not leak into the spawned window name'
run_leak 'FLEET_SUBORCH_ID=so-d99-leak' FLEET_SUBORCH_ID=so-d99-leak

section 'case 2 — FLEET_NEW_SUBORCH_ID does not leak'
run_leak 'FLEET_NEW_SUBORCH_ID=so-d99-leak' FLEET_NEW_SUBORCH_ID=so-d99-leak

section 'case 3 — both together (the real sub-orch-spawning-a-worker shape)'
run_leak 'both suborch vars' FLEET_SUBORCH_ID=so-d99-leak FLEET_NEW_SUBORCH_ID=so-d99-leak

section 'case 4 — FLEET_HARNESS does not override the PATH-shimmed claude'
run_leak 'FLEET_HARNESS=omp' FLEET_HARNESS=omp

section 'case 5 — FLEET_NEW_WID_FILE is not written outside the child TMPROOT'
WIDF="$(mktemp -d)/wid"     # created by us, so removed by us — never a glob sweep
run_leak "FLEET_NEW_WID_FILE=$WIDF" FLEET_NEW_WID_FILE="$WIDF"
if [ -e "$WIDF" ]; then no 'cmd_new wrote the inherited FLEET_NEW_WID_FILE'
else ok 'inherited FLEET_NEW_WID_FILE left untouched'; fi
rm -rf "$(dirname "$WIDF")"

section 'case 6 — the scrub is in the shared preamble, not per-proof'
# Fails LOUDLY if someone "fixes" this by patching one proof: the unset must live
# in hidden-proof-common.sh, where all eight callers inherit it.
if grep -q '^ *unset .*FLEET_SUBORCH_ID' "$FLEET_REPO/test/hidden-proof-common.sh"; then
  ok 'proof_isolate unsets FLEET_SUBORCH_ID'
else
  no 'hidden-proof-common.sh does not unset FLEET_SUBORCH_ID'
fi

proof_summary

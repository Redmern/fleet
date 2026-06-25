# TEST-VERDICT — dispatch-seed-fix (GATE 2)

## Verdict: DONE

Two INDEPENDENT testers (dsf-test-a, dsf-test-b), separate contexts + separate
throwaway FLEET_SESSIONs, both reached DONE.

Confirmed:
- ROOT FIX: a real dispatch now ACTUALLY spawns a so-d<N> pane (boot is a small
  ~200B pointer, well under tmux MAX_IMSGSIZE 16384; the old ~20KB inline seed
  over-capped → silent no-pane → reconcile respawn-forever). Decisive gate: the
  spawned sub-orch READ the manual + instruction before acting.
- LOUD FAILURE: empty win_id now prints a real stderr error + returns non-zero
  (never "spawned … in window " blank); genuine tmux-missing stays fail-silent.
- NO REGRESSION: normal worker spawns unaffected by the cmd_new guard.
- Hidden session recreates when absent (secondary bug, fixed free).
- suborch_seed deletion left no dangling caller; FLEET_SUBORCH.md :9/:18 reworded
  coherently; relative .fleet/dispatch/<id>/ refs still valid (cwd=root).

## Convergent non-blocking finding — FIXED before merge
Both testers flagged the same env-prefix wart: a comment severed the FLEET_*=…
prefix on the cmd_new call, leaking the vars as un-exported globals (fragile inside
cmd_reconcile's per-dispatch loop). Fix (commit 630a43a): comment moved above the
assignment block → command-scoped prefix restored. Re-verified: OLD form leaks
across calls, NEW form's values do not survive the call; real so-d<N> still spawns
+ reads the manual. → DONE.

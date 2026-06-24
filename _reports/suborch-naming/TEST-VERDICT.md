# TEST-VERDICT — suborch-naming (GATE 2)

## Verdict: DONE

Two INDEPENDENT testers (sn-test-a, sn-test-b), separate contexts + separate
throwaway FLEET_SESSIONs, both reached **DONE** (all 7 items PASS).

Confirmed end-to-end through the real functions:
- Core invariant: @fleet_owner stays BARE so-d<N> across a window rename; worker
  still GROUPS under the renamed card (group_rows bare->full map) and inbox routing
  resolves prefix-tolerantly; NO re-stamp mutated the owner.
- Worker d<N>- prefix derivation correct; 4 dash tweaks correct (is_suborch_name
  suffix-tolerant; ledger/card_meta_state strip; GNUM digit-slug slurp fixed —
  so-d11-ipv6-fix no longer mis-sorts); slug sanitizer; so-*/d*/ globs survive;
  un-renamed so-d<N> no regression; restore round-trip persists+re-stamps owner.

## Adversary check — non-blocking gaps (documented fast-follows, not merge blockers)
1. `from=so-*` gate-resume branch is the lone EXACT resolver; correct under the
   documented rename-before-gate ordering (§3.0.1a) but not robust-by-construction.
   Fast-follow: route it through suborch_pane_for (prefix-tolerant) — one line.
2. `cmd_reap` `wrecon` unprefixed fallback: a *dead* sub-orch-owned worker's
   needs-human `from=` could slip the fallback (low sev: dead worker + unread
   needs-human + non-force reap). `--force` overrides. Accepted.

Neither is a reachable break in the normal flow. → DONE.

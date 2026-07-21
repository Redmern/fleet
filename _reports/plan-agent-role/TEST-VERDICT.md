# TEST-VERDICT — plan-agent-role (d28) — ADVERSARY

Role: attack the joint verdict. Verdict rule: DONE only if the case cannot be broken. It broke.

## Attacks REPELLED (the testers were right)

- **tb28 provenance.** Verified independently, not taken on trust. `/tmp/tb28/root/fleetcopy`
  is on `main` @486ac88 and `536b72f` is **not** an ancestor — but fleetcopy is only the
  *target* repo. `bin/fleet:1670` seeds the sub-orch with `$FLEET_DIR/FLEET_SUBORCH.md`, and
  both tb28 sub-orch transcripts (`~/.claude_personal/projects/-tmp-tb28-root/{3a342513,b87d8941}.jsonl`)
  literally carry `operating manual: /home/red/proj/pc-tune/fleet/fleet_plan-agent-role-test/FLEET_SUBORCH.md`.
  Manual was the committed 536b72f text (commit 06:53, runs 07:02+). P1/P2/P3/P5 do **not** rest on sand.
- **P5 not a replayed context.** 8 distinct `agent-*.jsonl` files with distinct ids and staggered
  mtimes under the PLAN session's `subagents/`. Structurally distinct. PASS stands.

## Attacks LANDED

1. **The six-section RECON.md schema was never written into either doc.** `grep` for
   `## TASK|## SLUG|TERRITORY|PRIOR ART|OPEN QUESTIONS|BUDGET SPENT` returns **zero** hits in
   FLEET_SUBORCH.md *and* SKILL.md. This is not agent non-compliance (Tester A's framing) — it is
   a **silent deletion of PLAN.md W1 by the implementation**. P1's audit clause ("`## BUDGET SPENT`
   matches the transcript — this is the reason that section exists") is unimplementable by construction.
2. **NEW — the shipped regression test greenwashes both failures.** `test/plan-role-recon-proof.sh`
   is **ALL PASS** on this branch. It asserts neither the six sections nor W3's anti-duplication rule;
   its `[7]` check only requires that *some* trust asymmetry be "stated" — which the **inverted**
   rule satisfies. Shipped in the same commit as the text it validates, it certifies green exactly
   the two things the proof design says must fail. Neither tester caught this.
3. **P3 is mis-graded — it passes only by redefining "the cap".** The manual says RECON.md
   "**≤25 lines**, then stop"; the vague fixture shipped **33** (and the normal one 35), digest 22 vs ≤15.
   P3 asks whether the cap is "structural or merely aspirational" — 2-of-2 over cap answers that.
   Tester B narrowed the budget to read-calls only and graded PASS. On the spec's own terms P3 FAILS,
   which independently triggers the honest failure condition.
4. **NEW — the REVERT verdict is not executable and both testers waved it through.**
   `~/.claude_personal` is **not a git repo** (verified: `fatal: not a git repository`). `git revert 536b72f`
   restores FLEET_SUBORCH.md but cannot touch SKILL.md, leaving the live pipeline with a manual saying
   `<slug>-research`/no-recon and a skill saying `<slug>-plan`/RECON.md — the exact doc disagreement
   proof step `[10]` exists to prevent, and the reverted commit takes `[10]` away with it. A REVERT
   verdict with no revert path for half its surface is not a verdict.

## On the REVERT-vs-keep dispute

Tester B's defence (the inversion may be better engineering; 12 corrections, an 18-row wrong-anchor
table) is evidence about the *shipped* design, not the *specified* one. It does not rescue the work:
a proof design the implementation silently redefined — W1's schema deleted, W3's rule inverted — is
itself the finding. Neither "revert" nor "keep" is decidable until the human rules on which design
was actually agreed. Both testers' verdicts are premature.

NEEDS-WORK

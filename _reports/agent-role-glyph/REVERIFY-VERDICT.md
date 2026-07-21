# REVERIFY-VERDICT — independent re-verification of d26 loop 2

**Subject:** commit `13891a8` "fix(task): d26 loop 2 — label-aware shed gate, hard-reject
generic, close 5 test holes" on branch `fleet/agent-role-glyph`.

**What this is checked against:** the commit under test, `CLAUDE.md`, and the prior
`TEST-VERDICT.md` (which returned NEEDS-WORK on the four blockers). **d26 has no
`PLAN.md` / `SYNTHESIS.md`** in this worktree — there is no approved spec, so
conformance is checkable only against the commit message and `CLAUDE.md` prose. This
is an INDEPENDENT re-check; none of the verifiers wrote the code under test.

**Method:** 3 independent verifiers (2 testers + 1 adversary), each in its own isolated
git worktree, plus a baseline harness run in the target checkout. Every relied-upon
assertion was **mutation-tested**: apply a mutation to the shipped impl → run the suite
→ confirm the target case goes RED → `git checkout --` restore → confirm clean. A green
run alone was trusted for nothing.

## Environmental hazard (recorded, handled)

The isolated worktrees were cut from branch tip **`daf0f07`**, which sits *on top of*
13891a8 with later d28 work — at `daf0f07` the test harness `test/agent-task-proof.sh`
is **deleted entirely** and all three bins are heavily rewritten (`bin/fleet` +355/-211).
All three verifiers **independently detected this** (missing harness) and checked out
**13891a8 detached** before attacking. The baseline run executed in the main worktree,
which is at 13891a8. Every result below is against the exact commit under test.

## Result per blocker

| # | Blocker (prior NEEDS-WORK) | Tester A | Tester B | Adversary | Verdict |
|---|---|---|---|---|---|
| 1 | Shed gate was a constant floor; defect returned for labels >floor; 19b went RED on shipped code | FIXED | FIXED | HELD | **FIXED** |
| 2 | Status-bar fix had ZERO coverage (deleting it left ALL PASS) | FIXED | FIXED | HELD | **FIXED** |
| 3 | case 16 could not fail; baseline read the same option it asserts on | FIXED | FIXED | HELD | **FIXED** |
| 4 | `--task generic` shipped warn-and-drop exit 0, not hard reject | FIXED | FIXED | HELD | **FIXED** |

Baseline (13891a8, main worktree): **ALL PASS** (45–46 cases, per verifier count).

### Blocker 1 — label-aware shed gate (tag-XOR-ellipsis)

Shipped gate `bin/fleet-dash:1059` is `(( LW < ${#label} ))` — the exact negation of
`fit_left`'s elision point (same string, same codepoint measure), so a row's task tag is
shed at the instant its label would begin to elide. **Mutation-proven falsifiable:**
reverting to `(( LW < 1 ))` (the original bug) and to a constant `(( LW < 20 ))` each
drives **19b RED** ("a task tag survived while its label was squeezed"); an over-large
constant drives **19c RED** (over-shed pincer). All three verifiers ran their **own**
`capture-pane` in a private `-S`-isolated tmux across the full width band and found
**zero** tag+`…` rows: Tester A/B stepped 70→120 with a 43–60-cell label; the adversary
stepped **every integer width 40–125** with a 60-cell label, a **CJK wide-char** label,
and **4 tagged rows at once** — TOTAL_VIOLATIONS=0. Under the `LW<1` mutation the long
row reproduces `impl` + `…` together at w=105→70, i.e. the wide-end band the prior
suite's w=80 blind had masked. The invariant holds; the test is non-vacuous.

### Blocker 2 — status-bar surface now has real coverage (16b)

Loop 1's 16b used `( . "$FLEET"; inject_status_format )`, which fell through the CLI
dispatch to usage and never called the function. Loop 2 drives the real internal
subcommand `"$FLEET" inject-status-format`. **Mutation-proven:** removing the
`@fleet_task_tag` append → **16b RED** "did not append a task token"; pointing the append
at `@fleet_task` instead of the rendered `@fleet_task_tag` → **16b RED** "expanded the
RAW ENUM WORD" (the `research→rsch` discriminator fires). The adversary confirmed the
tested path equals the real `cmd_up` path.

### Blocker 3 — independent-source baseline (case 16 + 16d)

Loop 2 adds **16d**, which exercises fleetd's SECOND, independent Python implementation
`heal_status_format` (`bin/fleetd`) rather than the bash twin. **Mutation-proven:**
deleting fleetd's task branch → **16d RED**; drifting the heal to `@fleet_task` → **16d
RED** "healed to @fleet_task, not @fleet_task_tag" (16/16b stay green, confirming the
source is genuinely independent). Case 16 itself is non-vacuous: a poison stored value
drives it RED via its enum whitelist against an independent `WBASE` baseline window. The
adversary confirmed the two twins agree byte-for-byte. **Documented residual (all three
agree, non-blocking):** case 16's `#[`-*count* sub-check is **dormant at its position**
— the token is only injected later at 16b, so no window exceeds the baseline `#[` count
when case 16 runs; the operative guard at case 16 is the stored-value whitelist. The
literal `#[`-count positive-control the prior verdict suggested was not added. This does
NOT reinstate the blocker: the blocker was "baseline reads the same option it asserts
on / cannot fail," and that is resolved — 16d reads an independent source and case 16 is
mutation-provably falsifiable via the whitelist; the injection surface is separately
proven capable of failing at 16b. Recorded as a quality note for a future loop.

### Blocker 4 — `--task generic` is a hard reject

Exact `--task generic` → **rc=2**, error naming `generic` on stderr, **no** window, **no**
`@fleet_task_tag`, **no** durable sidecar, **no** `.agents` line — nothing that could flip
`HAS_TASKS`. **Mutation-proven:** reverting to warn-and-drop (accept + exit 0 + spawn) →
**26a RED** "exited 0"; re-advertising `generic` in the first position of the closed-enum
warning → **26c RED**; a leaked tag → **26b RED** (non-vacuous). Adjacent inputs
(`Generic`, ` generic `) warn-drop untagged with no leak. **`main` remains warn-and-drop
by design** (case 14 depends on it spawning to verify the role brakes) — this is the
pre-existing inconsistency the prior verdict *noted* (it "needs a decision"), not a
regression introduced by loop 2, and is outside the four blockers.

## Confidence

- **Three-way convergence.** Two independent testers and an adversary, plus a baseline
  in the exact commit, all reach the same result on all four. Mutants killed: A **12/12**,
  B **10/10**, adversary confirmed the load-bearing set independently. Every mutation
  drove its target case RED and every restore returned a clean tree.
- **Independent captures, not trusted greens.** The tag-XOR-ellipsis invariant was
  confirmed by each verifier's own `capture-pane` in a private tmux server, including
  adversarial widths (every integer 40–125), a CJK label, and multiple simultaneous tags
  — the specific failure modes the prior verdict said the old suite stepped over.
- **Isolation was sound.** All dynamic tests ran on throwaway `-S`-scoped tmux servers
  under `mktemp` roots with the REFUSE guard active; the live `pc` server was never
  touched. The prior dispatch's harness-isolation failure did not recur.
- **One residual, non-blocking:** case 16's `#[`-count positive control is dormant
  (Blocker 3 above). All three verifiers independently rated it not blocking, and the
  blocker it relates to is independently resolved.

## Ruling

All four blockers from the prior `TEST-VERDICT.md` NEEDS-WORK are **resolved**, each with
mutation-proven, non-vacuous test coverage, corroborated by three independent verifiers
and a clean baseline at the exact commit. The single residual (dormant `#[`-count in
case 16) is documented and does not reinstate any blocker.

CONFIRMED

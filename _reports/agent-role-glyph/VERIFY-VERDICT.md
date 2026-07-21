# VERIFY-VERDICT — independent verification of d26 loop 1 (commit c8eb395)

Subject: `c8eb395` "fix(task): d26 loop 1 — label-vs-tag threshold, ls alignment, real
status-bar test" on branch `fleet/agent-role-glyph`.

Role: independent verifier. I did not write this code. Every ruling below rests on
execution and capture — rendering the dashboard and reading `capture-pane`, piping
`fleet ls` through `column -t`, and mutating the implementation to see whether the
tests go red. Nothing is graded by reading the diff and judging it plausible, and
nothing is taken from the implementer's own account of compliance.

Evidence base: three agents run independently and blind to each other — two testers
(`VERIFY-a.md`, `VERIFY-b.md`) and one adversary tasked solely with refuting the fixes
(`VERIFY-adversary.md`) — plus my own first-hand confirmations of the load-bearing
claims, recorded inline below.

---

## What I conformed to — stated plainly, not papered over

**There is no approved spec for d26.** `PLAN.md` and `SYNTHESIS.md` do not exist in this
worktree. I confirmed their absence; all three agents confirmed it independently. So
conformance was checkable **only** against three things:

1. the commit `c8eb395` itself and its message,
2. `CLAUDE.md`'s prose (notably "shed **first** … so the label is never squeezed", and
   the `task_tag_trim` / `column -t` rationale),
3. `TEST-VERDICT.md`'s four blocking findings and its seven "what would have to change".

**What this means, and what it does not.** I can rule on whether the four defects are
fixed. I **cannot** rule on whether the fixes are the *approved* ones, whether the enum
membership was a designed decision or an implementer choice, or whether any planned step
was silently dropped. Where I say a fix is "half-met" against red's hard-reject ruling,
that ruling is prose in a review document, not an approved specification — I flag the gap
rather than resolve it, because resolving it is not mine to do. Any reader treating this
verdict as spec-conformance is overreading it.

**Step 0 (merge `main`) was not performed, and this is not a coverage gap.** `git merge`
is hard-denied by fleet-guard's always-on worker merge/push floor (this project carries
`.fleet/no-self-merge`); `FLEET_SELF_MERGE=1` on the command line does not reach the hook,
which reads its own environment. I refused to route around the guard and posted it as a
needs-human message. The orchestrator then attempted the merge itself, hit conflicts in
`bin/fleet`, `bin/fleet-dash` and `FLEET_SUBORCH.md`, and aborted — those conflicts are
d26's feature code against main's evolution and need the author. The subject is therefore
`c8eb395` **as committed**, which is a valid subject.

**The dedupe question the merge was meant to answer, answered by measurement instead:**

| harness source | result |
|---|---|
| this branch's own (2e9ae8a) | **19 passed, 0 failed** |
| `main`'s file checked out into this tree | **19 passed, 0 failed** |

I did **not** reproduce the reported 13/19 regression, because on this branch there is
nothing to regress: `reap-tracked-notes-proof.sh`, `reap-teardown-safety.sh`,
`worktree-secrets-proof.sh` and `suborch-wake-proof.sh` are **byte-identical** between
`main` and this branch. 2e9ae8a is not a divergent hand-rolled variant here. The 13/19
belonged to another agent's own diff, and its decision to discard that diff as redundant
is consistent with what I measure.

**Full suite on the branch as committed: green.** agent-task-proof ALL PASS; reap-teardown
8/8; reap-tracked-notes 19/19; suborch-wake ALL PASS; worktree-secrets ALL PASS. That green
is precisely what the rest of this document is about.

**One transient-state note.** The adversary encountered the worktree mid-merge, with
conflict markers in `bin/fleet` and a non-parsing script. It detected this, refused to test
it, and extracted a pristine `git archive c8eb395` instead. I verified afterwards that the
worktree is clean at `c8eb395` with zero conflict markers and `bin/fleet` parsing. The
adversary's results are valid and, if anything, better isolated than the others'.

---

## BLOCKER 1 — dash shed threshold: **NOT FIXED**

The gate moved from `LW < 1` to `LW < LBLMIN` with `local LBLMIN=20`
(`bin/fleet-dash:966`, `:1061`). `fit_left` still elides as soon as `LW < ${#label}`
(`:1067`). **`LBLMIN` is a constant; `${#label}` is not.** The fix therefore installs a
readability *floor*, not the invariant `CLAUDE.md` states. The old gate was the degenerate
case of the same shape, `LBLMIN=1`.

**The original bug reproduces, loudly** — so the fix is falsifiable. On pre-fix `4edd86b`,
both testers independently measured a deterministic failure band of **16 consecutive widths,
72–87**. At w=85: `…r/worker-none` / `…worker-tagged` while `rsch` holds 5 columns. This
matches `TEST-VERDICT.md`'s capture exactly.

**The defect returns on shipped code as soon as the label exceeds the floor:**

- Tester B, 40-cell label: fails across **w=91–110** — `rsch   …g-feature-branch-name-tagged`
- Adversary, 43-cell label: `impl` tag held across **w=113→91** while the label is
  left-ellipsised. At w=100: `idle  impl  …e_very-long-branch-name-here  ✓  default  -`

Both derived the same mechanism independently: **band = `len(label) − LBLMIN`**.

**Tester A swept 70–100 at every width and found it clean — this is not a contradiction,
and the reason is the finding.** A's fixtures were ~13 cells, *under* the 20-cell floor,
so the gate always fired before elision could. I confirmed the mechanism directly at
`bin/fleet-dash:966/1061`. A tested one axis; B and the adversary tested two.

**The commit's own test goes RED on the shipped code.** The adversary inserted a single
realistically-named agent before 19b's loop, changing nothing else:
`FAIL(19b) … w=100 … w=95`. 19b's *rule* is exactly right — "a row may show a task tag, or
a squeezed label, but never both". Its **fixtures** are all `repo/feat_one`-shaped (~13
cells, `test/agent-task-proof.sh:149-536`), so it never enters the band where the ladder
now trades. I confirmed the fixture lengths and the `LBLMIN` value first-hand.

That is the same blindness that produced A's clean sweep, in the test that is supposed to
be the guard.

On the specific instruction — **19b is a real render+capture assertion, not a grep**, and
A proved it independently load-bearing via mutation M5b (`LBLMIN` 20→1, which leaves 19a's
grep string satisfied): 19a stayed green, **19b caught it alone**. So the "still a grep →
automatic FAIL" condition does **not** apply. 19b fails on fixture coverage, not on kind.

**But 19a is exactly the ac3af4d defect class.** `lad=$(grep -n 'LW < LBLMIN' …)` is
computed at `test/agent-task-proof.sh:424` and referenced **only inside the failure message
string** at :428 — never in the `if`. I confirmed this by reading the assertion. Reverting
the gate cannot make 19a fail. It is an assertion that computes its subject and then
discards it.

Two further weaknesses, both real: 19b **samples** seven widths rather than sweeping, and an
**empty capture reads as a pass** (no retry, `sleep 0.8`) — the adversary showed 19b survives
`exit 0` inserted into `bin/fleet-dash`. No positive control.

Minor, and in the opposite direction: the adversary measured an **overcorrection** — at
cw=90 with a 3-cell label the tag is shed while ~30 columns sit empty; `--task` renders
nothing below w≈91 regardless of label length.

**Ruling: NOT FIXED.** Two independent measurements of the surviving defect, a third
explained by its fixtures, and the commit's own test red on one realistic name.

## BLOCKER 2 — `fleet ls | column -t`: **BEHAVIOUR FIXED, ZERO COVERAGE**

The `-` placeholder (`bin/fleet:420`) genuinely works. All three agents converged: the
baseline bug reproduces at `ff9da68^` (never-tagged fleet, **every** row shifts one column
left, agent name under `TASK`), and on `c8eb395` alignment is correct across never-tagged,
mixed and all-tagged; bare `column -t` now matches the `-s $'\t'` control byte-for-byte.
The adversary could not break it across `--all`, `cat`/`head`/`awk`, non-tty stdout, zero
and one agent, slash and space names, long names, and every task value.

**But the fix has no test that can fail.** I confirmed this myself, not by report: deleting
the placeholder line from a pristine `git archive c8eb395` extraction —

```
sed -i '/if (tg == "") tg = "-"/d' bin/fleet     # verified applied: grep count 0
bash test/agent-task-proof.sh                     # → ALL PASS
```

Tester A (M8) and the adversary (C5) reproduced this independently. Case 18b uses
`awk -F'\t'`, which counts empty fields and **structurally cannot** observe whitespace-run
collapsing — the very mechanism of the bug. `grep 'column -t' test/` returns nothing.

**Ruling: the user-visible defect is fixed; the fix ships undefended.** The next edit to
that awk block reintroduces the bug silently, in the surface `CLAUDE.md` cites as its own
justification.

## BLOCKER 3 — case 16b: **VACUITY FIXED, GUARD STILL VACUOUS**

**(a) PASS.** 16b now genuinely executes `inject_status_format`. Both testers traced the
body running and the token reaching the global format (`#I:#W` → both tokens; a tagged
window expands to `2:repo/feat_one impl`).

Worth recording: **the commit's own root-cause diagnosis is wrong.** Tester B traced the
pre-fix failure to `bin/fleet:17 SOCK=` clobbering the harness's `SOCK`, not to
`*) print_usage` exiting the subshell as `TEST-VERDICT.md` supposed. The fix is
nonetheless correct. The commit message documents a cause that was not the cause.

**(b) PARTIAL — and the specific thing red required was not done.** Mutation results
converge across agents: no-op'ing `inject_status_format` → 16b RED (M1/m1); dropping the
task token → RED (M3b/m3); non-idempotent → 16c RED (M9b/m11); opening the write-site enum
→ `FAIL(16)`. Those are real positive controls.

**Hole, confirmed twice independently — case 16's `#[`-injection guard still cannot fail.**
Injecting a literal `#[` survives ALL PASS (A's M4b, B's m4). Two measured causes: case 16
runs *before* 16b injects, and `base_n` is measured from **the same global option**, so
poison raises baseline and tagged equally — A measured `tagged(1) > baseline(1)? NO`. This
is precisely the ac3af4d shape you asked me to hunt: **a baseline computed from the broken
path, so both sides move together and the assertion can never go red.**
`TEST-VERDICT.md` item 2 explicitly required re-baselining case 16 after fixing 16b. **Not
met.**

Two further holes: the adversary showed stamping `@fleet_task_tag` with the **raw enum word**
survives ALL PASS — 16b's only tagged window uses `impl`, whose tag is byte-identical to its
enum word, so the bar could print `research` (7 cells) and no test would notice, defeating
the 4-cell guarantee the whole design rests on. And **`fleetd.heal_status_format` has zero
functional coverage** (B's m16, adversary's C9): deleting its task branch outright leaves
ALL PASS. The Python twin of the injection path is untested.

**Ruling: the reported vacuity is fixed; a second, deeper vacuity of the same class remains
in the guard that carries the design's safety claim.**

## `--task generic` — **HALF-MET**

All three agents agree on shipped behaviour, and the adversary could not break it across 13
input variants (`-T`, `--task=`, `GENERIC`/`Generic`, whitespace, `main`, `''`,
`#[fg=red]`, `#{q:…}`, `impl#[fg=red]`).

- **The value is rejected.** `@fleet_task`, `@fleet_task_tag`, the sidecar and `task_of` all
  come back empty; no tasks dir is created. Every out-of-band path re-validates — poisoned
  sidecars and `fleet restore` yield empty, and a stale `generic` sidecar written by the
  previous version is now dropped on read (an unclaimed upgrade benefit).
- **HAS_TASKS is not flipped**, captured with a positive control: adding one real
  `--task research` agent turns the column on for all rows, proving the detector works.
  Labels keep full width fleet-wide. This half is solid.
- **But it is warn-and-drop with exit 0 — the agent still spawns.** `generic`, `main` and a
  random unknown all behave identically. Red's ruling was **hard reject**. `generic` now has
  parity with `main`, but neither is a hard rejection. Case 26a asserts only the empty
  option, never the exit status.

Whether exit 0 satisfies "hard-rejected" is exactly the kind of question an approved spec
would settle and, absent one, I will not settle by assertion. It is consistent with the
existing `--task main` contract and the repo's fail-silent house style; it is not what the
words in the ruling say. **Flagged for the gate, not ruled.**

Coverage hole (A's M11): re-adding `generic` to the dash read-side enum arm
(`bin/fleet-dash:225`) survives ALL PASS. Shipped behaviour is correct, but a regression
there ships silently and causes exactly the harm this item closed.

---

## Cross-cutting: the tests, under the ac3af4d lens

Applying "not *does it pass* but *what mutation would make it fail, and does that mutation
actually make it fail*" to every new and changed assertion, not only the status-bar one:

| assertion | load-bearing? | evidence |
|---|---|---|
| 19b (render+capture) | **yes**, but under-fixtured | catches `LBLMIN`→1 alone (M5b); red on one realistic name; empty capture = pass |
| 19a (`$lad` gate) | **no** | computed at :424, never asserted; reverting the gate stays green |
| 16b / 16c | **yes** | M1/M3b/M9b all caught |
| case 16 `#[` guard | **no** | baseline shares the poisoned global option — counts cancel |
| blocker-2 `-` placeholder | **no test at all** | deleting the fix → ALL PASS (confirmed by me) |
| `@fleet_task_tag` value | **no** | raw enum word survives; `impl` == its own tag |
| `fleetd.heal_status_format` | **no test at all** | branch deletable → ALL PASS |
| dash read-side enum | **no** | re-adding `generic` survives |
| 26c enum advertisement | weak | positional `*"|generic"*`; re-ordering the list still passes |

Eight of nine surfaces touched or claimed by this commit have an assertion that cannot fail
on regression. **Two of the three blocker fixes are real in behaviour and undefended in
evidence.** The pattern is consistent and it is the same pattern that produced this loop:
the harness reports ALL PASS, and that sentence carries much less information than it appears to.

Also stale, and worth fixing while here: `CLAUDE.md` does not mention the `LBLMIN=20` floor,
and its `task_tag_trim` "unset → *empty*" paragraph now contradicts the shipped `-`
placeholder — so shipping as-is makes the documentation wrong in the same file that
supplied the acceptance criterion. Case 16's accept-list still contains `generic`,
contradicting the enum this commit closed.

## Not verified

`fleetd heal_status_format` behaviour (only its absence of coverage); real attached-client
status-bar rendering; widths outside 60–120; sub-orch / dispatch-layer spawns carrying
`--task`; multi-byte and wide-character labels beyond the adversary's spot checks; anything
requiring the `main` merge.

## What would close this out

1. **Make the shed gate track the label, not a constant** — the invariant is
   "tag XOR ellipsis", so gate on `LW < ${#label}` (with `LBLMIN` as a floor beneath it, not
   as the rule). Then re-check the overcorrection at the low end.
2. **Give 19b a long-label fixture** (≥35 cells), sweep the band rather than sampling it,
   and **fail on an empty capture** instead of passing. Add the positive control.
3. **Assert `$lad` in 19a**, or delete it — an assertion that computes its subject and
   discards it is worse than no assertion, because it reads as coverage.
4. **Re-baseline case 16 off a source independent of the injection path** so a literal `#[`
   makes it red. This was already required by `TEST-VERDICT.md` item 2 and is the one
   unmet instruction carried forward verbatim.
5. **Test the blocker-2 fix** — one `fleet ls | column -t` assertion on a never-tagged fleet,
   checking field-under-header, not `awk -F'\t'`.
6. **Assert the rendered tag is 4 cells** using a tag whose text differs from its enum word
   (`research`→`rsch`), not `impl`.
7. **Decide `--task generic`'s exit status against an actual spec**, and assert whichever is
   decided.
8. Cover `fleetd.heal_status_format` and the dash read-side enum; refresh `CLAUDE.md` on
   `LBLMIN` and the `-` placeholder; drop `generic` from case 16's accept-list.

Items 1–5 are blocking. Item 1 alone is dispositive: the defect `TEST-VERDICT.md` blocked
on is measurably still present on shipped code, and the commit's own test detects it as soon
as it is given a realistic agent name.

---

**NEEDS-WORK**

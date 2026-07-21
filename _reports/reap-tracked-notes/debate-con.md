# CON — adversarial review of PLAN.md (`fleet reap` tracked-notes / atomicity)

Method: every factual claim re-derived by experiment in a throwaway repo under
`$TMPDIR` (`/tmp/conadv.zF4sWR`, isolated `GIT_CONFIG_GLOBAL`, no real worktree
or live pc session touched), plus read-only inspection of the live worktrees.
Code read at `main` = `041e14b`. No tracked file edited.

---

## Verdict in one line

The plan's **mechanism is right**, its **line citations are all correct**, but
**two load-bearing premises are factually wrong** — and both of them inflate the
fix. The wrong premises are what force the plan from a ~4-line change into a
6-part restructure of a destructive code path.

---

## A. CONFIRMED-WRONG claims

### C1 — "plain `git worktree remove` refuses on untracked files too" (§2(a), lines 156–161) — **WRONG in the shape fleet actually creates**

The plan uses this to kill option (a) (`cp -a` instead of `mv`) and to funnel
everything into (b)'s tracked/untracked partition.

Untracked ≠ what fleet has. `cmd_new:1068` appends `/.fleet/` to the repo's
**common** `info/exclude`. So `.fleet/` is **ignored**, not untracked — and
`git worktree remove` **ignores ignored files**.

```
E1  (no exclude line):   ?? .fleet/          -> remove REFUSES  (exit 128)
E1b (exclude line, prod):porcelain empty     -> remove SUCCEEDS (exit 0), dir gone
E7  (exclude, .fleet/notes/x.md + .fleet/ready left in place)
                                             -> remove SUCCEEDS, deletes .fleet/ too
```

Verified live: **all four** `fleet/main` worktrees have `exclude=Y`.

Consequences:
- (a) does **not** regress the untracked case. The `cp -a` leftover is ignored;
  `worktree remove` deletes it for you.
- `3200`'s comment *"else it blocks remove"* is **wrong** for every worktree
  `cmd_new` created. The `rm -f ready` / `rmdir` line is dead weight there.
- §2(c)'s convergence onto (b) ("`rm -rf` only of untracked leftovers"),
  §3-B2's whole partition machinery, and edge-case row *"`cp` leaves a non-empty
  notes dir → `rmdir` fails"* all rest on C1 and collapse with it.

Residual truth: (a) *does* regress **iff** the exclude line is absent (E8 —
worktree predating the feature, or the fail-silent `|| true` at 1068 lost).
That is a one-line guard, not a design driver: after the copy, `rm -rf .fleet`
only when `git ls-files -- .fleet/notes` is empty.

### C2 — R1 "guard-5 widening (B1) could over-block on `.fleet/ready`, `roles/`, `devport`" (§6-R1) — **WRONG, phantom risk**

Same root cause. Those are untracked **under an ignore rule**, so they never
appear in `git status --porcelain` at all. Verified live: every worktree's
`.fleet/`-matching porcelain lines are empty except the one orphan.

So the filter `grep -vE '^...\.fleet/'` at 3136 has **exactly one live effect
today: hiding tracked `.fleet/` changes** — i.e. it exists only to cause defect
1.4. The "survey of what under `.fleet/` is ever tracked" R1 asks for: done, see
below. B1's careful `??`-vs-code partition + marker allowlist is over-engineering
for a filter that should simply be **deleted**.

### C3 — R5 "a live worker shell holding the cwd could make `worktree remove` fail post-B0" (§6-R5, §2(e) sub-decision, Q1) — **WRONG on Linux**

```
E5: background process cwd = the worktree; git worktree remove -> exit 0, dir gone
```
POSIX unlink/rmdir do not care about another process's cwd (no ETXTBSY/EBUSY on
a plain filesystem). The plan makes this a named risk, a constrained ordering
(`remove → kill → forget`) **and** a proof case. It is none of those. The
ordering inside the success branch is free; pick it for legibility.

(Caveat honestly stated: NFS silly-rename or a bind-mount/overlay could differ.
Neither is in play here.)

### C4 — §2(c) contains a self-contradicting bullet — **editorial, but it reads as a live argument**

Line 208–209: *"Con: does **not** by itself fix the tracked case … actually it
*does* fix it."* Thinking-out-loud left in a decision document. Cut it; the
conclusion (c is folded into B0) is fine, the reasoning shown is not.

---

## B. SURVIVES (attacked, held up)

| Claim | Evidence |
|---|---|
| **All line citations** (3114, 3136, 3153, 3187, 3188, 3193, 3197, 3200, 3202, 3203, 3215, 3221, 1068, 186–200) | Spot-checked line-by-line against `041e14b`. **Every one correct.** Unusually clean. |
| **1.4: the filter hides a tracked-and-locally-modified note** | E2: `M .fleet/notes/plan.md` → filtered to empty → guard 5 passes. And plain `worktree remove` then refuses (128). Exactly as described, including "fails safe by accident". |
| **The mechanism (§1.2)** | E3: `mv` of a tracked notes dir → ` D` lines → plain remove refuses 128 → `git restore .fleet/notes` → plain remove exit 0. The "recovery needed no `--force`" tell reproduces exactly. |
| **"Guards 5,6,7,8 all run before any mutation"** | Read `inbox_has_needs_human_from` (2337) and `gate_waiting` (1958): pure reads, archive-as-truth inbox is not touched. `git status` / `merge-base` / `tmux list-panes`: reads. The only pre-guard mutation is the stale-dir `cmd_forget` at 3129–3131, which fires only when `$dir` doesn't exist. **Claim holds.** |
| **§1.3 orphan state is real, not theoretical** | Live, read-only: `fleet/fleet_worktree-secrets` is sitting there right now with ` D .fleet/notes/TEST-VERDICT.md` ×4 — the exact residue, still unreaped. |
| **`--force` unreachable after a late failure** | 3114 selects on `.fleet/ready`, deleted at 3200; `cmd_forget` (580) drops the line the next run iterates. Both destroyed. Confirmed by reading. |
| **Archive-collision nesting (§4)** | E6: `mv src dest` where `dest` exists → nests as `dest/src/…`, exit 0, silent. `cp -a src/. dest/` merges. Real, if unreachable in <1s. |
| **B3 (force + unmerged + tracked notes = real loss)** | `branch -D` at 3215 is unconditional on the success path; guard 6 is skipped under `--force`. Sound. |
| **B5 / Q4 (`2>/dev/null` at 3203 discards the diagnosis)** | git's message is `contains modified or untracked files, use --force` — printing it verbatim would still have misdirected, but at least names *modified*. Fix worth doing. |

---

## C. Attack on B0 (reorder) — survives, but for different reasons than the plan gives

B0 is **cheaper and safer than the plan argues**, and the plan's own justification
for it is partly bogus:

- **R5 is void** (C3) — the ordering constraint and its proof case evaporate.
- **R6 ("rollback can itself fail") is self-inflicted.** It only exists because
  B0's sketch (§2(e) lines 250–257) deletes untracked notes *before* `worktree
  remove`, then must restore them on failure. Per C1 you never needed to delete
  them: they're ignored, git removes them on success. **Archive = pure copy, zero
  pre-remove deletion ⇒ no rollback branch, no R6, no "loud print the archive
  path" fallback.** That is the single biggest simplification available.
- **`cmd_forget` contract is unharmed by the move.** It's keyed on `$dir` (580),
  idempotent, and 3129–3131 already handles "registered agent, dir gone". So if
  the process dies between `worktree remove` and `cmd_forget`, the next `reap`
  self-heals via the stale path. B0's ordering is *more* crash-safe than today's.
- **Genuine residual concerns the plan does not raise:**
  1. **`cmd_restore` (734)** respawns saved agents whose windows are gone. Today's
     late failure forgets the agent, so restore can't touch it. Post-B0 the window
     is never killed on the failure path, so still fine — but on the **success**
     path there is a window between `worktree remove` and `cmd_forget` where the
     agent is registered, its dir gone, its window alive. A concurrent
     `fleet restore` / dashboard tick landing there is a new (tiny) interleaving.
     Today the equivalent window is kill→forget, also 1 statement. Net: unchanged
     in size, different in content. Not a blocker; do **not** let it grow into a
     lock.
  2. **Dashboard**: reads the agents file; both orders leave it consistent within
     one statement. No attack found.
  3. **Multi-worktree loop**: `$lines` is snapshotted at 3109 before iteration, so
     moving `cmd_forget` later cannot corrupt the iteration. Confirmed by reading.

**Verdict: B0 IN, in a reduced form** — decide-then-mutate, archive by copy,
delete nothing before `worktree remove`, no rollback branch, kill+forget on the
success branch in whatever order reads best.

---

## D. Attack on B1 — over-engineered; the right change is DELETION

Per C2 the filter has no legitimate live job. Options, ranked:

1. **Drop `| grep -vE '^...\.fleet/'` entirely.** Correct for every
   `cmd_new`-created worktree (exclude ⇒ markers invisible anyway), and it
   closes 1.4 by construction with an honest `skip … uncommitted file(s)`.
2. Keep a **narrow** fallback for exclude-less worktrees: filter only the exact
   untracked marker lines (`^?? \.fleet/$`), nothing else. ~1 line.

B1 as written (partition by porcelain code **and** a marker allowlist) is
strictly more code than (1)+(2) and buys nothing that C2 doesn't refute.

Also note the filter's other latent bug the plan misses: porcelain v1 renames are
`R  ORIG -> DEST`, so `^...\.fleet/` matches on the **origin** path — a rename
*out of* `.fleet/notes` is hidden, a rename *into* it is not. Deleting the filter
kills this too.

---

## E. The smaller fix I am arguing for

Against the plan's six parts, the defensible minimum is **three lines plus a
message**, and it fixes the reported bug, defect 1.4, and the misdirection:

- **S1** — 3197: `mv` → `cp -a "$dir/.fleet/notes/." "$arch/"` (into a freshly
  `mkdir`'d `$arch`). Tree is never dirtied. Per C1 the leftover is ignored and
  `worktree remove` deletes it. Guard for the exclude-less case: after the copy,
  `rm -rf "$dir/.fleet"` only if `git -C "$dir" ls-files -- .fleet` is empty.
  Archive becomes **complete** (tracked + untracked + local mods) — which also
  makes B2's split archive, B3's force-path special case, B4's two-count message
  and R2's "conditionally complete archive" doc problem all **unnecessary**.
- **S2** — 3136: delete the `.fleet/` filter (§D).
- **S3** — 3203/3221: capture git's stderr, print it, drop the hard-coded
  `use --force`.

S1+S2+S3 make T1–T9 pass. What they do **not** fix is the *class*: a late
`worktree remove` failure from any unanticipated cause (`chmod a-w` on the
parent, locked file, a submodule) still orphans. That is the honest case for B0,
and it stands on its own — it does not need C1/R5/R6 to justify it.

**So: ship S1+S2+S3 and B0-reduced. Drop B1-as-written, B2, B3, B4, R2's doc
narrowing, R5's proof case, R6's rollback.** Roughly half the plan is answering
premises that experiment refutes.

---

## F. Should tracked `.fleet/notes` be treated as user error? (R3)

**No — and the plan under-states its own case.** Not hypothetical: three of four
live `fleet/main` worktrees carry **4 tracked files under `.fleet/`**. Whatever
the intent of the `info/exclude` design, `git add -f` is a legal user action and
fleet's response is currently to *dirty the tree and orphan the worktree*.
"Detect and warn" is not cheaper than S1 (one token) and leaves the atomicity
hole. Reject R3.

---

## G. Test-design objections

- **§5/R4 is right that `mkrepo` must write `info/exclude`** — and C1 shows this
  is not a fidelity nicety but the **difference between pass and fail**: without
  it, T2/T7's untracked cases hit E8's refusal and the harness would "prove" the
  opposite of production. Make it a loud comment in the harness.
- **Add an explicit case for the exclude-less worktree** (E8). It is the only
  place S1 can regress, and the plan currently has no case for it.
- **A1a/A2's fixture:** the plan's preferred option (ii) — abuse the 1.4 filter
  hole — is **self-invalidating**, since S2/B1 closes that hole in the same
  change. Go straight to the stated fallback: `chmod a-w` on the worktree's
  parent. Honest, external, survives the fix. (Do **not** ship a
  `FLEET_TEST_FAIL_REMOVE` env hook in a destructive production path.)
- **T4/A4 are the right assertions** and should be treated as the acceptance
  bar: after any refusal, unfiltered `git status --porcelain` in the worktree is
  empty.
- **Q7 (recover the already-orphaned worktree)**: not hypothetical either —
  `fleet/fleet_worktree-secrets` is orphaned *right now*. Whatever is decided,
  that one needs cleaning by hand (`git restore .fleet/notes` then plain
  `git worktree remove`; E3 proves no `--force` is needed).

---

## H. Answers to the open questions

- **Q1** — resolved; ordering inside the success branch is unconstrained (C3).
- **Q2** — yes, `--force` should print that it deleted an unmerged branch. Cheap.
- **Q3** — with S1 the archive is complete, so a silent no-archive when `$root`
  is unset is now the *only* silent loss path. One `echo` to stderr. Worth it.
- **Q4** — yes, unconditionally (S3). It is the cheapest item in the whole plan
  and would have made this bug self-diagnosing.
- **Q5** — `mktemp -d "${arch}.XXXX"` is fine; nothing parses the archive name
  (grepped: no reader of `notes/archive/` beyond the `echo`). Low priority.
- **Q6** — keep `--force`, stop recommending it (B5). **Do not split the flag**
  in this change: it touches docs, the dashboard action, and muscle memory, for a
  problem S1/S2 mostly dissolve. Scope discipline.

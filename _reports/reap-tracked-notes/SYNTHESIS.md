# SYNTHESIS — reap tracked-notes / atomicity: consolidated verdict

Inputs: `PLAN.md`, `debate-pro.md`, `debate-con.md`, `debate-proof.md`.
Adjudicated by re-running the two load-bearing experiments directly (§0).
Base `main` = `041e14b`. No tracked file edited.

---

## 0. Facts I re-verified myself (both contested, both settled)

**F1 — ignored ≠ untracked, and it decides half the plan.**

```
A: .fleet/devport, NO exclude line  -> porcelain "?? .fleet/"
   git worktree remove  -> fatal: contains modified or untracked files
   post-state: dir EXISTS, still listed in `worktree list`   (fully intact)
B: same + "/.fleet/" in common info/exclude (production shape)
   -> porcelain EMPTY;  git worktree remove SUCCEEDS, deletes .fleet/ too
```
CON and PRO both asserted this independently; confirmed. **PLAN §2(a)'s
"plain `worktree remove` refuses on untracked files too" is wrong as applied to
worktrees `cmd_new` creates** — they all carry the exclude line (CON verified
`exclude=Y` on all four live `fleet/main` worktrees).

**F2 — `fleet_root` never returns empty.** Line 94–100 ends in bare **`pwd`**.
`cmd_reap:3101` binds `root=$(fleet_root 2>/dev/null)` and 3193 only tests
`[ -n "$root" ]`. **PLAN §4's "`$root` unset → archive block skipped" is wrong**,
and PROOF's HF-1 is a genuine hard fail: a T9 written as "omit the root" would
`mkdir -p` and `mv` fixture notes **into the live `fleet/main` checkout**.

---

## 1. CONFIRMED-WRONG in PLAN.md (5)

| # | Claim | Verdict | Consequence |
|---|---|---|---|
| W1 | §2(a): plain `worktree remove` refuses on untracked ⇒ `cp -a` regresses the untracked case | **WRONG** for fleet-created worktrees (F1-B) | Collapses the justification for **B2**'s partition, **B4**'s split-count message, **B3**'s force special case, **R2**'s doc-narrowing. `cp -a` alone does not regress. |
| W2 | §6-R1: widening the dirty filter could over-block on `.fleet/ready`/`roles/`/`devport` | **WRONG** (phantom) — those are ignored, so never in porcelain at all | The filter at 3136 has **exactly one live effect: hiding tracked `.fleet/` changes**, i.e. it exists only to cause defect 1.4. B1 shrinks to a one-regex change. |
| W3 | §6-R5: a live worker shell holding the cwd could make removal fail | **WRONG on Linux** — CON's E5 experiment: removal exit 0 with a background process cwd'd there | Deletes an ordering constraint, a named risk, and a proof case. Order inside the success branch is free. |
| W4 | §4: `$root` unset ⇒ archive skipped | **WRONG** (F2) | T9 must be rewritten or it contaminates the live repo. |
| W5 | §5: preferred fixture (ii) — abuse the 1.4 filter hole; fallback `chmod a-w` | **BOTH unusable, for opposite reasons** — see §3 | The fixture question is genuinely reopened. |

Editorial: §2(c) contains a sentence that contradicts itself mid-clause ("does
not fix it … actually it *does* fix it") — flagged by both PRO and CON. Cut.

**Survived attack:** every line citation (3114, 3136, 3153, 3187–3188, 3193,
3197, 3200, 3202–3203, 3215, 3221, 1063–1069, 186–200) — checked line-by-line by
two advisers, all correct. The mechanism (§1.2), defect 1.4, the guards-run-before-
mutation claim, the orphan analysis (§1.3), and `--force`-unreachable-after-failure
all hold. CON found a live orphan **right now**: `fleet/fleet_worktree-secrets`
sitting with ` D .fleet/notes/*` ×4, unreaped.

---

## 2. Final recommendation — the reconciled fix

Roughly **half the plan dies with W1/W2/W3**. What is left is smaller and better:

**S1 — archive by copy.** 3197: `mv` → `cp -a "$dir/.fleet/notes/." "$stage/"`
into a freshly-made `$stage`. Tree is never dirtied; per F1-B the leftover is
ignored and `worktree remove` deletes it. Archive becomes **complete** (tracked +
untracked + local mods), which is *why* B2/B3/B4/R2 are unnecessary.
*One guard:* for an exclude-less worktree, after the copy `rm -rf "$dir/.fleet"`
only when `git -C "$dir" ls-files -- .fleet` is empty.

**S2 — close defect 1.4.** 3136: `grep -vE '^...\.fleet/'` → `grep -vE '^\?\? \.fleet/'`.
Ignore untracked `.fleet/` only; a tracked-and-modified note now trips guard 5
**before** anything is killed. (Also kills the latent porcelain-`R  ORIG -> DEST`
rename hole CON found.) Reject R1's marker allowlist — `??` subsumes it.

**S3 — honest diagnosis.** 3203: capture git's stderr instead of `2>/dev/null`;
3221: print it and drop the hard-coded `use --force`.

**B0-reduced — the atomicity fix, and the only reason to keep the big change.**
S1–S3 fix today's trigger; they do **not** fix the class — any other late
`worktree remove` failure still orphans. B0: resolve `$win` during DECIDE (hoist
3181–3186, pure reads), then on the **success** branch only: `remove → branch -D →
safe_kill_window → cmd_forget`. Failure branch leaves worktree, window, agents
line and `.fleet/ready` untouched, so **a plain re-run is the retry**.

**The one genuine PRO↔CON disagreement, resolved:** CON says delete nothing
pre-remove ⇒ no rollback branch, R6 evaporates. PRO says the **exclude-less**
worktree needs the marker deleted pre-remove or plain reap regresses (F1-A).
Both are right in their own case → **make it conditional**: delete `.fleet`
members pre-remove *only* when they are not ignored
(`git -C "$dir" check-ignore -q .fleet/ || …`), and only that path carries PRO's
restorable-marker rollback (§3.3 of `debate-pro.md`, incl. the verify-the-marker-
and-print-the-exact-`touch` recovery). The common path needs no rollback at all.

**Dropped:** B1-as-written, B2, B3, B4, R2's doc narrowing, R5's proof case, R6's
general rollback, the dry-run probe (PRO: don't build one — there is no
`worktree remove --dry-run`; use precondition + rollback).
**Added:** PRO's **worktree-lock DECIDE guard** (`git worktree list --porcelain`
reports `locked`) — the one real post-guard refusal cause worth pre-empting.
**Q6:** keep `--force`, stop recommending it; do **not** split the flag (both
advisers agree — post-B0 a plain re-run is the retry).

---

## 3. Proof design — the fixture question is REOPENED (new finding)

PROOF settled candidate (ii) `chmod a-w` decisively: `git worktree remove`
**deletes the contents and unregisters the worktree first**, then fails on the
final `rmdir` — so the "failure" is a successful destruction with rc≠0. Every
`assert_intact` sub-assertion is already false. **Reject permanently**; also it
breaks `rm -rf "$TMPROOT"` in `cleanup()`.

But **PROOF's own two recommendations contradict each other**, and neither
adviser noticed:

- M2 says `mkrepo` must append `/.fleet/` to the common exclude for production
  fidelity (correct — PLAN R4, PRO agrees).
- Fixture (i) needs `?? .fleet/devport` to appear in porcelain and block removal.

**With the exclude line present, `.fleet/devport` is ignored and removal
succeeds (F1-B) — fixture (i) never fires.** PROOF's supporting claim that
production also shows `?? .fleet/` is refuted by F1-B and by CON's live check.

**Resolution:** the late-failure fixture is a worktree deliberately built
**without** the exclude line, plus an untracked `.fleet/devport`. F1-A verifies
that exact shape: removal refuses **and post-state is fully intact** (dir present,
still listed) — which is what `assert_intact` needs, and it survives S1/S2/B0.
This doubles as PRO's **T11** (exclude-less worktree must still reap), the one
case B0-as-written would have regressed. So the harness needs **both** `mkrepo`
variants, and must say which fidelity each one buys.

**Other required §5 corrections, all accepted:** rewrite T9 (HF-1);
`export FLEET_DEBUG_PORT=<unused>` — `cmd_reap`'s trailing `fuser -k 9222/tcp`
kills the developer's Chromium and **the existing harness already does this**
(HF-2, pre-existing); constrain T8's symlink target inside `$TMPROOT` (HF-3);
`commit_in()` with explicit `-c user.email/-c user.name` (M1 — `mkrepo` only
sets identity on its one init commit); single-source the case count (M3);
`assert_intact` must call `fail()` (which exits the subshell) and `return 0`, or
`&& pass` silently swallows the case (M4); capture the worker window id from
`addwin` (M5); `export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null`.

**Red-first expectation corrected:** PLAN said "expect T1/T3/T4 red". Actual on
current `main`: **11 red** — T1, T3, T4b, T6(by-intent), T8, A1a, A1b, A2, A3,
A4, A5. Green: T2, T4a, T5, T7, T9(rewritten), T10. T4a is green today (guard 5
fires pre-mutation); only T4b is red. Put the tally in the harness header or the
first run reads as a broken harness.

Acceptance bar (both advisers converge): **after any refusal, unfiltered
`git status --porcelain` in the worktree is empty** (A4) — reap never leaves dirt
it created itself — **and a second plain reap still selects the worktree** (A2).

---

## 4. Residual risks

- B0 makes reap **restartable**, not transactional. A SIGKILL between the
  fleet-owned deletions and the removal still orphans (exclude-less path only,
  post-conditional-deletion). Accepted; strictly better than today's guaranteed
  orphan on a routine refusal.
- S2 will start refusing reaps that today half-succeed. That is the point; S3's
  message is what makes it legible.
- `cmd_restore` interleaving on the success branch (registered agent, dir gone,
  window alive) is one statement wide — same width as today's kill→forget window,
  different content. Not a blocker; do not grow it into a lock.
- **Cleanup owed regardless of this fix:** `fleet/fleet_worktree-secrets` is
  orphaned right now. `git restore .fleet/notes` → plain `git worktree remove` →
  `git branch -D`. Needs no `--force`.

# `fleet reap` is not atomic: a refused reap orphans the worktree — research + fix plan

> **Framing (escalated).** The tracked-`.fleet/notes` `mv` is the *trigger*. The
> **root cause is ordering / atomicity**: `cmd_reap` performs four irreversible
> mutations (kill window → forget → move notes → delete the `ready` marker)
> **before** the step that can fail, and refuses only at that last step. The
> advertised contract — *"refuses; nothing gets deleted"* — is false for any
> late-stage failure. `mv`-vs-`cp` is a sub-fix; the ordering is the bug.


Scope: research only. No code written, no tracked file touched. All line numbers
are `bin/fleet` at `main` = `041e14b` unless stated.

---

## 1. Mechanism — confirmed

### 1.1 The actual order of operations in `cmd_reap` (lines 3091–3229)

Read in order, per flagged worktree inside the `while IFS=$'\037' read` loop
(3112–3223):

| # | Line(s) | Step |
|---|---------|------|
| 1 | 3114 | `[ -e "$dir/.fleet/ready" ]` — only flagged worktrees |
| 2 | 3120–3127 | target label match |
| 3 | 3129–3131 | stale-dir → `cmd_forget` |
| 4 | 3132–3133 | must be a linked worktree |
| 5 | **3134–3139** | **GUARD: uncommitted changes** (`git status --porcelain`, `.fleet/` filtered) |
| 6 | **3140–3155** | **GUARD: branch merged into base** (`merge-base --is-ancestor`) |
| 7 | 3156–3167 | GUARD: unread needs-human inbox message |
| 8 | 3168–3174 | GUARD: sub-orch parked at a gate |
| 9 | 3176–3187 | resolve window → `safe_kill_window "$win"` |
| 10 | 3188 | `cmd_forget "$dir"` (drops the saved-agents line) |
| 11 | **3189–3199** | **ARCHIVE: `mv "$dir/.fleet/notes" "$arch"`** |
| 12 | 3200 | `rm -f .fleet/ready`; `rmdir .fleet/notes .fleet` |
| 13 | 3201–3203 | `git worktree remove $rmflag "$dir"` |
| 14 | 3204–3219 | `git branch -D "$branch"` on success |
| 15 | 3221 | else → `skip … worktree remove failed (uncommitted? use --force)` |

**Every safety guard (5,6,7,8) runs BEFORE the archive (11).** Answer to question
3: the guards are computed *before* the mutation, and that ordering is precisely
what makes the failure invisible to them — see 1.3.

### 1.2 The failing sequence (matches the reported reproduction exactly)

1. Worktree is **clean**. `.fleet/notes/*.md` are **committed on the branch** and
   already merged into `main`.
2. Guard 5 (3136) runs `git status --porcelain` → empty → passes.
3. Guard 6 (3153) `merge-base --is-ancestor HEAD main` → true → passes.
4. Window killed (3187), agent forgotten (3188). **Both already irreversible.**
5. Archive (3197) `mv "$dir/.fleet/notes" "$arch"` succeeds → prints
   `archived fleet/suborch-wake-fix notes -> …/archive/fleet__suborch-wake-fix__1784473547`.
6. The tree is now **dirty by reap's own hand**: 4 tracked files show as ` D`.
7. `git worktree remove` **without** `--force` (3202–3203: `rmflag=""` on the
   non-force path) refuses, because plain `worktree remove` requires a clean
   worktree.
8. `2>/dev/null` swallows git's real message; the `else` (3221) prints the
   misleading `skip … (uncommitted? use --force)`.

The comment at 3190–3191 — *"Fully fail-silent — must NEVER block removal"* — is
factually wrong: `mv` cannot *fail*, it **succeeds** and the damage is downstream
in git's cleanliness precondition. Fail-silence protects only against `mv`
erroring, not against `mv` mutating tracked state.

### 1.3 THE REAL BUG: reap is not atomic — a refused reap orphans the worktree

**Two kinds of refusal, with opposite safety properties.**

- **Early skip** — guards 5,6,7,8 (3134–3175) each `continue` **before** any
  mutation. These are genuinely safe: nothing is killed, forgotten, moved, or
  deleted. This is the behaviour the docs describe.
- **Late skip** — the `else` at 3220–3221 (`worktree remove` failed). By the time
  this prints, **four irreversible mutations have already run**:

  | Order | Line | Mutation | Reversible? |
  |-------|------|----------|-------------|
  | 1 | 3187 | `safe_kill_window "$win"` — the agent's tmux window is **destroyed** | No |
  | 2 | 3188 | `cmd_forget "$dir"` — the saved-agents line is **dropped** | No (hand-edit `~/.config/fleet/sessions/<sess>.agents`) |
  | 3 | 3197 | `mv .fleet/notes → archive` — **this is what dirties the tree** | By hand |
  | 4 | 3200 | `rm -f "$dir/.fleet/ready"` + `rmdir .fleet/notes .fleet` — the **selection marker is deleted** | By hand |
  | 5 | 3203 | `git worktree remove` — **fails** → `skip … (uncommitted? use --force)` | — |

**Observed live consequence.** Retrying with the documented escape hatch:

```
$ fleet reap suborch-wake-fix --force
nothing flagged ready (mark one with 'fleet ready')
```

`--force` does not help, because step 4 deleted `.fleet/ready`, and the loop
selects on exactly that marker at **3114** (`[ -e "$dir/.fleet/ready" ] || continue`).
Step 2 additionally removed the line the loop iterates over (3109/3112). The
worktree is therefore **unreachable by `fleet reap` under any flag** — the
selector and the iteration source were both destroyed by the failed attempt.

**Resulting orphan state:**
- worktree still on disk, still a linked worktree, branch still present;
- its tmux window **gone**;
- **forgotten** — invisible to `fleet ls` / the dashboard;
- `.fleet/` gone (marker, notes, roles);
- **not reapable by name**, so no in-fleet recovery path exists.

**Recovery that worked (and what it proves):**

```
git restore .fleet/notes      # in the worktree — tree clean again
git worktree remove <dir>     # plain, NO --force
git branch -D <branch>
```

It needed **no `--force`**. That is the tell: the dirt blocking removal was
**100% self-inflicted by step 3**. There was never any real user work in the way,
and `--force` — the flag the error message recommends — was never the right
answer. The message actively misdirects toward the flag that disables the two
guards that *do* matter.

**Restated root cause.** `cmd_reap` interleaves decision and mutation. Correct
shape for a destructive teardown: compute **all** refusal conditions, decide
go/no-go, and only then mutate — with the mutations ordered so the *least*
recoverable ones happen last, after the operation has actually succeeded.
`mv`-vs-`cp` (§2) fixes the trigger; it does **not** fix the class. Any future
late-stage failure (`worktree remove` refusing for a reason we did not anticipate
— locked file, permission, submodule, concurrent process) reproduces the same
orphan.

### 1.4 Secondary defect found while reading (same code path)

The dirty guard at 3136 filters `grep -vE '^...\.fleet/'`. Porcelain status lines
are `XY <path>` (3 chars then path), so this drops **every** line whose path
starts `.fleet/` — designed for the untracked `?? .fleet/` ready marker, but it
also drops ` M .fleet/notes/plan.md`, i.e. **a tracked note with real uncommitted
local edits does not trip guard 5**. Today that "fails safe" by accident: the
tree is dirty, so `git worktree remove` refuses at 3203 and prints the same
misleading skip. **Any fix that makes the tracked case removable must not also
make that unreviewed local edit silently disappear.** This is a hard constraint
on options (a) and (b) below and is the main reason the recommendation adds an
explicit check rather than relying on guard 5.

---

## 2. Candidate fixes

Notation: "notes" = `$dir/.fleet/notes`, "archive" = `$root/.fleet/notes/archive/<repo>__<branch>__<ts>`.

### (a) `cp -a` instead of `mv`

```
cp -a "$dir/.fleet/notes/." "$arch/"      # then let step 12's rmdir/rm handle the worktree copy
```

- **Pro:** one-token change; archive still gets everything; tracked files are not
  deleted, so the tree stays clean and `worktree remove` succeeds.
- **Con:** the comment at 3192 says *"The move also empties `.fleet/notes` so the
  `rmdir .fleet` path below still works."* With `cp`, `notes/` still holds files,
  so the `rmdir` at 3200 fails (non-empty) and `.fleet/` survives. For **untracked**
  notes that leaves `?? .fleet/` residue — which `git worktree remove` tolerates?
  **No:** plain `worktree remove` refuses on untracked files too (it requires a
  clean worktree modulo submodules). So (a) alone *regresses the untracked case*
  unless the leftover is explicitly `rm -rf`'d. That turns (a) into "copy then
  `rm -rf` the untracked ones" = option (b) with extra steps for tracked ones.
- **Con:** doubles disk I/O for large notes dirs (negligible in practice; notes
  are markdown).
- **Verdict:** not sufficient alone. Its useful kernel — *never `mv` a tracked
  file* — is absorbed into (b).

### (b) Archive only UNTRACKED files; leave tracked ones alone

Partition the notes dir with `git -C "$dir" ls-files -z -- .fleet/notes` (tracked)
vs the rest, archive only the untracked set, then `rm -rf` only what was archived.
Tracked files are left in place; `git worktree remove` then only has to deal with a
clean tree, which it does happily (it deletes tracked files as part of removal).

- **The "already in git" claim — is it true?** Mostly, with two real holes:
  1. **Branch deletion.** Step 14 (3215) runs `git branch -D "$branch"`
     unconditionally on the success path. On the non-force path the branch was
     verified merged into base (guard 6), so the commits are reachable from the
     base branch → content survives. On the **`--force`** path guard 6 is skipped
     *and* the branch is still `-D`'d, so an unmerged branch's tracked notes
     become reachable only via reflog/dangling objects → effectively lost. So the
     claim holds for plain reap and **fails for `--force` + unmerged**.
  2. **Uncommitted local modifications to a tracked note** (see 1.4). The
     *committed* version is in git; the user's edit is not. Leaving it "alone"
     means `worktree remove` deletes it. This must **block**, not archive-and-hope.
- **Pro:** the tree is never dirtied by reap; guard semantics are unchanged; the
  untracked-scratch value proposition (the reason the feature exists) is
  preserved verbatim.
- **Con:** "notes preserved" becomes conditional on the branch surviving in
  history. For a user staring at an archive dir that now contains only *some* of
  the files they wrote, this is surprising unless it is stated in the output line.
- **Con:** partially-tracked dirs produce a *split* archive (some in
  `archive/…`, some only in git). Mitigable by printing which.

### (c) Stage the archive, remove the worktree, then finalize

`cp -a` notes → a temp staging dir; `git worktree remove`; on success `mv` the
staging dir into the archive; on failure `rm -rf` the staging dir and leave the
worktree untouched.

- **Pro:** strictly transactional — the archive only ever materialises for a reap
  that actually happened; a refused reap leaves **zero** residue, which directly
  fixes the 1.3 orphan-state problem for the archive step specifically.
- **Pro:** captures tracked *and* untracked *and* locally-modified content
  unconditionally — the archive is a faithful snapshot of what was on disk.
- **Con:** the `worktree remove` still refuses when the tree is dirty from a real
  local edit — correct, but now the archive is discarded and the user gets no
  hint that their edit was the blocker. Needs a diagnostic.
- **Con:** does **not** by itself fix the tracked case: `cp` leaves the files in
  place, so the tree is clean → remove succeeds → actually it *does* fix it.
  The residual issue is the `rmdir` at 3200 (see (a)): the staging copy must not
  leave a non-empty `.fleet/notes` behind, i.e. step 12 must become `rm -rf
  "$dir/.fleet"` on the path where we intend to remove the worktree anyway.
  `rm -rf` of tracked files is exactly the `mv` problem again **unless** it is
  ordered *after* a successful `worktree remove` — which for a removed worktree is
  moot (the dir is gone). So (c) wants `rm -rf` **only of untracked** leftovers
  pre-remove. Again converging on (b)'s partition.
- **Con:** most moving parts; two failure paths (`cp` fails, finalize `mv` fails)
  each needing a decision.

### (d) `mv` then `git restore` the notes path

Keep the `mv`, then `git -C "$dir" checkout -- .fleet/notes` (or `restore`) to
resurrect the tracked files and un-dirty the tree.

- **Pro:** smallest diff that literally fixes the reported symptom.
- **Con:** **destroys data in the locally-modified case.** A tracked note with
  uncommitted edits gets `mv`'d (edited version into the archive — fine) and then
  `restore`d to HEAD; the tree is clean; `worktree remove` succeeds; the branch is
  `-D`'d. The user's edit now exists *only* in the archive, and only if the `mv`
  half succeeded. The guard that should have blocked (1.4) never fires. This
  converts a safe refusal into a silent destructive reap.
- **Con:** conceptually "dirty the tree, then launder it" — it defeats guard 5 by
  construction, which is exactly the anti-pattern the constraints forbid.
- **Verdict:** reject.

### (e) REORDER — decide first, mutate last (the atomicity fix)

Independent of *how* notes are archived. Restructure the per-worktree body so
that every refusal condition is computed up front and every mutation happens on a
single committed path, ordered least-recoverable-last:

```
# ---- DECIDE (no mutation) ----
compute: linked-worktree?  dirty?  merged?  inbox?  gate-wait?
compute: CAN the worktree actually be removed?   # dry-run probe, see below
any refusal -> print skip, `continue`   # nothing touched, marker intact

# ---- MUTATE (committed) ----
archive notes (copy)                    # recoverable: archive is additive
remove leftover untracked notes
git worktree remove                     # the real point of no return
  success -> git branch -D
             rm -f .fleet/ready         # marker dies only after success (moot: dir is gone)
             safe_kill_window
             cmd_forget
  failure -> print the REAL git error, roll back the untracked-notes deletion
             from the archive copy, leave marker/window/agent INTACT
```

Two sub-decisions to settle in the debate:

- **Dry-run probe.** Git has no `worktree remove --dry-run`. The practical probe
  is the existing dirty check made *complete* (i.e. B1, plus not filtering away
  the conditions git itself will object to). It cannot be exhaustive — hence the
  rollback branch.
- **Window kill / forget after removal.** Moving `safe_kill_window` (3187) and
  `cmd_forget` (3188) to the success branch is the change that makes a late
  failure survivable. Risk: on the *success* path a worker process may still hold
  the cwd we just deleted; today the kill happens first, which avoids that. Order
  within the success branch should therefore be `worktree remove` → kill → forget,
  and the kill must remain routed through `safe_kill_window` (its three brakes,
  186–200, are untouched either way).

- **Pro:** fixes the whole class, not the trigger. Makes the documented contract
  true. Makes a failed reap retryable — the single most valuable property here.
- **Con:** the largest diff in a destructive path; touches the ordering that
  `test/reap-teardown-safety.sh` cases 1,2,3,7,8 exercise (they assert the center
  survives and the *right* worktrees are/aren't reaped — none of them assert kill
  happens before removal, so they should still hold, but this must be proven, not
  assumed → T10).
- **Con:** rollback-from-archive is itself a step that can fail. Keep it
  best-effort and *loud*: print where the archive copy is so a human can finish.

**Verdict: required.** Escalated evidence shows (a)–(d) alone leave the orphan
class intact.

---

## 3. RECOMMENDATION

**(e) + (b): reorder so decision precedes mutation, and archive by partition so
the trigger is removed too.** (e) is the load-bearing half — without it the next
unanticipated `worktree remove` failure re-creates the orphan. Six parts:

**B0 — Reorder (option (e)).** All refusal conditions computed before any
mutation; `safe_kill_window`, `cmd_forget`, and the `.fleet/ready` deletion move
to the **success** branch of `git worktree remove`; the failure branch prints
git's real stderr and leaves marker + window + agent registration intact so a
plain retry works. This is the change that restores the documented contract.

Then, to remove the trigger that exposed it:

**B1 — Extend guard 5 to see inside `.fleet/notes` for TRACKED paths.**
Today `^...\.fleet/` blanket-filters. Change it to filter only *untracked*
`.fleet/` entries (porcelain `??`) plus the known fleet markers, so that a
tracked-and-locally-modified note (` M`, ` D`, `A `, `R `) **does** trip the
uncommitted guard and reap refuses **before** killing anything. This is the
answer to "a tracked note with uncommitted LOCAL modifications is real user work
and must still block": it becomes a first-class guard hit with an honest message,
instead of today's accidental refusal with a misleading one.

**B2 — Archive only what git does not already hold.**
Partition via `git -C "$dir" ls-files -z -- .fleet/notes`. Copy (not move) the
untracked members into the archive, then `rm -rf` **only those** paths. Tracked
members are left in place for `git worktree remove` to delete. Post-B1, tracked
members are guaranteed identical to HEAD, so leaving them is lossless.

**B3 — Keep the `--force` path honest.**
`--force` skips guard 6, so a tracked note on an **unmerged** branch that is then
`branch -D`'d is genuinely lost. On the `--force` path, archive **everything**
(tracked included) by *copy*, and rely on `worktree remove --force` (3202) to
tolerate the resulting state — it already does. Cost: a redundant archive copy of
content that is usually also in history. That is the right trade for the flag
whose whole purpose is "I accept the risk"; here it *reduces* risk.

**B4 — Report what happened.**
The `archived …` line should say how many files went to the archive and how many
were left to git history, e.g.
`archived fleet/foo notes -> …  (3 files; 4 tracked notes kept in branch history)`.
Silent partial archiving is the main UX hazard of (b), and one line removes it.

**B5 — Fix the escape-hatch message and stop recommending `--force`.** The late
skip (3221) hard-codes `(uncommitted? use --force)` while discarding git's actual
stderr (`2>/dev/null`, 3203). Post-B0 the honest message is git's own error plus
*"worktree left intact — retry after resolving"*. `--force` should be mentioned
only where it is genuinely the answer (a real dirty tree the user has decided to
discard, an intentionally unmerged branch) — never as the generic remedy, since
it disables guards 5 **and** 6 wholesale. See Q6.

**Why (c) is folded in rather than adopted whole:** (c)'s transactional staging
is the right instinct, and B0 takes its ordering insight. Full stage-then-finalize
adds a second failure mode (finalize `mv`) for little extra benefit once the
archive is a copy and the deletions are on the success branch.

**Partially-tracked dirs** fall out naturally: B2 splits them, B4 explains the
split. **Branch-deleted-right-after** is covered by guard 6 on the plain path
(merged ⇒ content reachable from base) and by B3 on the force path.

---

## 4. Edge cases

| Case | Today | Under the recommendation |
|------|-------|--------------------------|
| **Empty notes dir** | `ls -A` test at 3193 is false → archive skipped; `rmdir` at 3200 removes it. Correct. | Unchanged — keep the `ls -A` short-circuit as the first condition. |
| **`.fleet/notes` is a symlink** | `[ -d ]` at 3193 follows the link → true; `mv` moves the **link**, not the target, into the archive → archive holds a dangling symlink; the worktree loses the link. If the link is tracked, same dirty-tree failure. | Add `[ ! -L "$dir/.fleet/notes" ]` to the guard: treat a symlinked notes dir as "not ours", skip archiving, let the normal dirty/remove logic handle it. Fail-closed. Also relevant to secrets confinement (`inject_secrets` already rejects source symlinks, line ~813 comment) — same posture. |
| **Archive target already exists** | Path is `<repo>__<branch>__<epoch-seconds>`. Two reaps of the same repo/branch **within one second** collide; `mv` into an existing dir nests (`arch/notes/…`) rather than failing. Practically unreachable but silently wrong. | Copy into a freshly `mkdir`'d dir; on collision append a counter suffix, or use `mktemp -d "${arch}.XXXX"`. Cheap. |
| **`$root` unset** | `fleet_root` fails (3101, `2>/dev/null`) → `$root` empty → whole archive block skipped (3193 leading `[ -n "$root" ]`). Notes are simply deleted with the worktree. No dirtying, so no self-block. | Unchanged; still the correct fail-silent behaviour. Worth an `echo` note that notes were not archived — currently silent data loss for untracked scratch. Flag as Q3. |
| **`mkdir`/`mv` fails mid-way** | `mkdir -p … && mv … && echo … \|\| true` — a failed `mkdir` skips the `mv` (notes survive, no dirt). A **partially completed `mv`** (cross-device, ENOSPC) can leave *some* files moved and the rest in place → dirty tree → the exact reported failure, but now with a split archive and no message. | Copy-then-delete makes a mid-way failure non-destructive: on any copy error, abort the archive and **do not** delete anything; the worktree is still clean, remove proceeds (or the operator reruns). |
| **`--force` path** | `rmflag="--force"` (3202) so remove tolerates the `mv`-dirt; the tracked bug is invisible under `--force`. Notes archived; branch `-D`'d even if unmerged → tracked-only notes lost. | B3: archive everything by copy on the force path. Guards 5/6/7/8 stay bypassed — unchanged. |
| **Tracked notes identical to HEAD** | The reported bug. | B1 sees no modification → no guard hit; B2 leaves them for `worktree remove` → **plain reap succeeds**. |
| **Tracked note with local mods** | Guard 5's `.fleet/` filter misses it (1.4); `mv` dirties; remove refuses; misleading message; window already killed. | B1 → clean refusal at guard 5, *before* `safe_kill_window`, with an accurate message. |
| **Notes dir contains a nested git repo / submodule** | `mv` moves it wholesale. | Copy handles it; nested `.git` is untracked from the outer repo's view so it lands in the untracked partition. Low priority. |

Non-goals explicitly preserved: `safe_kill_window`'s three brakes (empty target,
`is_main_pane`, last-window — lines 186–200) are untouched; guard 6's
merge-ancestry check is untouched; the label-only target match (3120–3127) is
untouched. Every one of those is what `test/reap-teardown-safety.sh` cases 1–8
lock in.

---

## 5. Proof design

New harness `test/reap-tracked-notes.sh`, **shaped exactly like**
`test/reap-teardown-safety.sh`:

- `set -u`; `HERE=$(cd "$(dirname "$0")/.." && pwd)`; `FLEET="$HERE/bin/fleet"`.
- **Isolation identical to lines 26–33 of the existing harness:** `TMPROOT=$(mktemp -d)`,
  `export TMUX_TMPDIR="$TMPROOT/tmuxsock"`, `export XDG_CONFIG_HOME="$TMPROOT/config"`,
  `unset TMUX`, `trap cleanup EXIT` with `tmux kill-server; rm -rf "$TMPROOT"`.
  Every `fleet` call goes through `reap() { FLEET_SESSION="$1" "$FLEET" reap "${@:2}" 2>&1; }`
  with a throwaway `FLEET_SESSION`. **No live pc session, no real worktree, no
  real `~/.config/fleet` is reachable** — the private `XDG_CONFIG_HOME` means the
  saved-agents file the loop reads (3102) is the harness's own.
- Reuse `mkrepo`/`boot`/`addwin` verbatim; add `mknotes <wt> <mode>` that creates
  `.fleet/notes/` and, per mode, commits them (`tracked`), leaves them untracked
  (`untracked`), or both (`mixed`). Note: `cmd_new`'s `info/exclude` line (1068) is
  **not** written by `mkrepo`, so untracked notes really do show as `??` — matching
  production only after the harness appends `/.fleet/` to `.git/info/exclude`
  itself. Do that in `mkrepo` so the untracked cases mirror reality.
- Same `pass()`/`fail()` subshell-exit idiom, per-case `rN=$?`, `tot=$((...))`
  aggregation, and the `== summary: N passed, M failed ==` +
  `RESULT: …` two-line report. Exit 0 only when every case passes.
- Run **red first** (expect T1/T3/T4 to fail on current `main`) then green.

Scenarios and pass conditions:

| # | Scenario | Setup | Pass condition |
|---|----------|-------|----------------|
| **T1** | **Tracked notes → plain reap succeeds** | notes committed on branch, branch merged into `main`, tree clean, flagged ready | `reap` prints `reaped repo/feat`; worktree dir gone; `git branch --list feat` empty; **notes content present under `$root/.fleet/notes/archive/…` OR reachable from `main` at the committed path** (assert the union, per §3 — the tracked half legitimately lives in history); center alive |
| **T2** | **Untracked notes → still archived (no regression)** | notes present, untracked, excluded via `info/exclude` | worktree gone; branch gone; **every** untracked filename present under the archive dir with byte-identical content; center alive |
| **T3** | **Mixed tracked + untracked** | 2 committed + 2 untracked notes | worktree gone; the 2 untracked files in the archive; the 2 tracked files retrievable from `main`; **no file lost in either direction**; the output line names both counts (B4) |
| **T4** | **Real uncommitted user change → plain reap REFUSES** | two sub-cases: (a) a modified tracked file **outside** `.fleet/`; (b) a modified tracked file **inside** `.fleet/notes/` (the 1.4 hole) | `reap` output matches `skip .*uncommitted`; worktree dir **still exists**; branch still exists; **`.fleet/notes/` still in the worktree** (no residue — proves the archive did not run before the guard); the tmux worker window **still exists** (proves no premature `safe_kill_window`); the saved-agents line still present (no premature `cmd_forget`); center alive |
| **T5** | **Unmerged branch → still REFUSES** | notes tracked, branch has a commit not in `main` | `skip .*not merged into main`; worktree present; branch present; notes still in the worktree; center alive |
| **T6** | **`--force` on unmerged + tracked notes** | as T5 plus `--force` | worktree gone; branch gone; **tracked note content present in the archive** (B3 — the only place it still exists); center alive |
| **T7** | **Empty notes dir** | `.fleet/notes` exists, empty | reap succeeds; no archive dir created for this label; worktree gone; center alive |
| **T8** | **Symlinked notes dir** | `.fleet/notes -> /tmp/elsewhere` | reap does **not** move/copy through the link; the link target's files are untouched; either a clean reap or a clean skip — **never** a dangling archive entry; center alive |
| **T9** | **No `$root`** | run with the project-root lookup unresolvable | archive block skipped; reap still succeeds; worktree gone; center alive; no crash |
| **T10** | **Existing 8 teardown-safety cases** | `bash test/reap-teardown-safety.sh` | exits 0 — all 8 PASS, unmodified file |

**Atomicity cases (from the escalation — these are the primary proof).** A helper
`assert_intact <case> <wt> <sess> <win>` asserts *all five* at once: worktree dir
exists, `$wt/.fleet/ready` exists, `$wt/.fleet/notes` exists with its files, the
worker window still exists (`tmux list-windows … | grep -qx "$win"`), and the
saved-agents line for `$wt` is still in `$XDG_CONFIG_HOME/fleet/sessions/<sess>.agents`.

| # | Scenario | Setup | Pass condition |
|---|----------|-------|----------------|
| **A1** | **A refused reap must not kill the window** — currently it does, on the late path | tracked notes, clean, merged (the reproduced case) — on current `main` this takes the 3221 late skip | `assert_intact`. Specifically the worker window **survives**. Expected **RED** pre-fix (the window is killed at 3187 before the failure). Post-fix the case reaps cleanly, so assert instead: `reaped`, worktree gone, window gone, notes preserved. Split into A1a (pre-fix regression witness, run against a stubbed always-failing removal) and A1b (post-fix success) — see below. |
| **A2** | **Late-failure retryability** | force a `worktree remove` failure by an *unrelated* real dirty file created **after** the guards would have run (simulate with `FLEET_TEST_FAIL_REMOVE=1` hook, or by a genuinely un-removable worktree) | first `reap` prints a skip; **`assert_intact`**; a **second plain `fleet reap` (no `--force`) still selects and processes the same worktree** — i.e. `.fleet/ready` and the agents line survived. This is the exact property that failed live (`nothing flagged ready`). |
| **A3** | **The marker is never deleted before success** | any refusing scenario (T4, T5, A2) | `$wt/.fleet/ready` present after the refusal, in every one of them |
| **A4** | **No self-inflicted dirt** | tracked notes, clean tree | after **any** refusal, `git -C "$wt" status --porcelain` (unfiltered) is **empty** — reap never leaves dirt it created itself. Directly encodes the "recovery needed no `--force`" tell from §1.3. |
| **A5** | **`--force` is not required for a self-inflicted case** | the reproduced case | plain `reap` succeeds (no `--force` anywhere in the passing path); assert the test never invokes `--force` for T1/T3 |

For A1a/A2 the harness needs a deterministic way to make `git worktree remove`
fail *after* the guards pass. Two options for the debate: (i) a test-only env
hook in `cmd_reap`, which means shipping test scaffolding in production code
(against repo style); (ii) create the blocking condition in a way the guards
legitimately do not see — e.g. an untracked file under a path the dirty filter
ignores, which is exactly the `.fleet/` filter hole (1.4). **(ii) is preferred**:
it uses a real defect as the fixture and needs no production change. Note it must
be re-derived if B1 closes that hole — in which case fall back to `chmod a-w` on
the worktree's parent, which makes removal fail for a genuinely external reason
(and is the more honest fixture for "an unanticipated failure").

T10 is run as the last case of the new harness (or as a documented companion
invocation) so a single command proves both the fix and the invariants it must
not disturb.

Explicitly asserted non-residue in T4/T5 (worktree present **and** notes still in
place **and** window alive **and** agent not forgotten) is what turns §1.3 from
an observation into a locked-in property.

---

## 6. Risks and open questions (for the adviser debate)

**Risks**

- **R1 — Guard 5 widening (B1) could over-block.** Loosening the `.fleet/`
  filter risks catching fleet's own churn: `.fleet/ready` (untracked → still
  filtered as `??`), `.fleet/roles/<pane>` (untracked), `devport`. If any project
  ever *commits* `.fleet/` markers, plain reap would start refusing everywhere.
  Mitigation: filter by porcelain status code (`??` → ignore) **and** by an
  explicit marker allowlist, not by path prefix alone. Needs a survey of what
  under `.fleet/` is ever tracked in practice.
- **R2 — The archive becomes conditionally complete.** After (b), "my notes are
  in the archive" is no longer universally true. If any tooling or habit reads the
  archive as the sole record, tracked notes will look missing. B4 mitigates by
  telling the user; a doc line in `FLEET.md`/`CLAUDE.md` (`$FLEET_DOCS` bullet,
  which currently promises "archived to `<root>/.fleet/notes/archive/…` on `fleet
  reap`") should be updated to match — that doc string is currently a promise the
  fix narrows.
- **R3 — `.fleet/notes` should arguably never be tracked at all.** The whole
  feature is designed around `info/exclude` (1059–1069). If tracked notes are a
  user mistake, the "right" fix could be to detect and warn rather than support.
  Counter-argument: fleet must not corrupt state just because a repo made a
  choice fleet did not anticipate; and this very repo's branches carry tracked
  notes, so it is not hypothetical.
- **R4 — Test harness fidelity.** `mkrepo` does not write `info/exclude`; without
  adding that, the "untracked" cases would show `?? .fleet/` at a *different*
  status than production and could pass for the wrong reason.

- **R5 — Reordering the kill after the removal changes process/cwd timing.** Today
  the window dies first, so no shell is sitting in the doomed dir when git removes
  it. Post-B0 a live worker shell in the worktree cwd could make `worktree remove`
  fail where it previously succeeded — converting today's silent-orphan bug into a
  visible refusal. That is a *better* failure, but it is a behaviour change and
  needs a proof case (worker pane parked in the worktree, plain reap must still
  reap or must refuse cleanly and retryably — never orphan).
- **R6 — Rollback can itself fail.** B0's failure branch restores untracked notes
  from the archive copy. If that restore fails, state is partly mutated again.
  Keep it best-effort and print the archive path loudly so a human can finish;
  never let rollback failure hide the original error.

**Open questions**

- **Q1 — RESOLVED by the escalation: yes, and it is the core of the fix.** Moving
  `safe_kill_window` (3187), `cmd_forget` (3188) and the `.fleet/ready` deletion
  (3200) onto the success branch is B0, no longer a follow-up. Remaining sub-question
  for the debate: exact ordering *within* the success branch (remove → kill →
  forget), given R5.
- **Q2 — Is `git branch -D` (3215) on the `--force` path correct?** It deletes an
  unmerged branch by design. Combined with archiving-everything (B3) the content
  survives, but should `--force` at least *print* that it deleted unmerged work?
- **Q3 — Silent non-archive when `$root` is unset.** Today untracked notes are
  deleted with no message. Add a warning line, or leave the fail-silent
  convention intact (the repo's stated style is `|| true` everywhere)?
- **Q4 — Should the misleading skip message at 3221 be fixed regardless?**
  It hard-codes `(uncommitted? use --force)` while discarding git's actual stderr
  (`2>/dev/null` at 3203). Capturing and printing git's first stderr line would
  have made this bug self-diagnosing. Cheap, orthogonal, arguably belongs in the
  same change.
- **Q5 — Archive naming collision.** Is `mktemp -d "${arch}.XXXX"` acceptable, or
  does anything parse the `<repo>__<branch>__<epoch>` archive name?
- **Q6 — Should `--force` remain the documented escape at all?** Evidence against:
  (i) the live failure was entirely self-inflicted and recovery needed **no**
  `--force`; (ii) `--force` did not even work, because the marker was already
  gone; (iii) it bypasses guard 5 *and* guard 6 together, so a user reaching for
  it to clear self-inflicted dirt also silently disables the unmerged-branch
  check. Options: keep `--force` but stop recommending it in the late-skip
  message (B5, minimum); or split it into `--force-dirty` / `--force-unmerged` so
  a user can override exactly one guard; or add a `fleet reap --retry` that only
  re-attempts removal. Splitting the flag also touches `FLEET.md` / `CLAUDE.md`
  docs and the dashboard's reap action — scope check needed.
- **Q7 — Recovery for worktrees already orphaned by this bug.** At least one
  exists (the reproduction). Should `fleet reap` learn to re-discover linked
  worktrees that are flagged-ready-but-forgotten, or is `git worktree remove` by
  hand the documented answer? `fleet reconcile` may be the natural home.

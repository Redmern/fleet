# Adviser PRO — argue FOR B0 (reorder) + B1..B5, and make it shippable

Role: read-only adviser. No tracked file edited, `bin/fleet` untouched.
Base: `main` = `041e14b` (matches PLAN.md's stated base).

---

## 0. Verdict up front

**Ship B0 + B1 + B2 + B4 + B5. Ship B3 in reduced form.** The plan's diagnosis is
correct and its line citations check out. But as written B0 is **not shippable**:
it contains one instruction that would break the plain-reap path outright (moving
the `.fleet/ready` deletion after `git worktree remove`, §3 B0) and two
under-specified steps (`win` resolution timing, rollback content). §2–§5 below fix
those and commit to an exact mutate order, an exact failure branch, and answers to
Q1–Q7 and R5.

---

## 1. Verification of the plan's citations — all confirmed, three corrections

Read `bin/fleet` @ `041e14b`. Every line the plan cites says what it claims:

| Plan claim | Line | Verdict |
|---|---|---|
| loop selects on the ready marker | 3114 `[ -e "$dir/.fleet/ready" ] \|\| continue` | ✅ exact |
| dirty guard blanket-filters `.fleet/` | 3136 `... \| grep -vE '^...\.fleet/'` | ✅ exact; porcelain is `XY<space>path`, so col 4 onward is the path — the filter really does drop ` M .fleet/notes/x.md`, not just `?? .fleet/` |
| merged guard | 3153 `merge-base --is-ancestor HEAD "$baseref"` | ✅ |
| inbox / gate-wait guards | 3156–3175 | ✅ both `continue` before any mutation |
| window resolve + kill | 3181–3187, `safe_kill_window "$win"` | ✅ |
| forget | 3188 `cmd_forget "$dir"` | ✅ |
| archive is a `mv` | 3197 `mv "$dir/.fleet/notes" "$arch"` | ✅ |
| marker deleted pre-remove | 3200 `rm -f "$dir/.fleet/ready"; rmdir ...` | ✅ |
| remove swallows stderr, `rmflag=""` on plain path | 3202–3203 | ✅ |
| late skip hard-codes the wrong remedy | 3221 | ✅ verbatim `worktree remove failed (uncommitted? use --force)` |
| `safe_kill_window` brakes: empty target / `is_main_pane` / last-window | 186–200 | ✅ all three present, fail-silent default is refuse |
| nothing parses the archive leaf name | — | ✅ verified: `notes/archive` appears only at `bin/fleet:3189,3195,3196` plus a prose bullet in `CLAUDE.md:179` / `FLEET.md:33`. Q5 is unconstrained. |

**So the ordering claim in §1.1 and the orphan mechanism in §1.3 are sound.** Four
irreversible mutations (kill, forget, `mv`, `rm` marker) do run before the only
step that can refuse, and the refusal at 3221 leaves the worktree unreachable
because both the selector (3114) and the iteration source (3109/3112, mutated by
`cmd_forget`) are gone. That is the bug, and it is a class, not a typo.

### Corrections / misreadings to call out

**C1 — the plan under-reads the `info/exclude` line, and this changes B0.**
`cmd_new` appends an anchored `/.fleet/` to the repo's **common** exclude file
(`bin/fleet:1063–1069`, `--git-common-dir`, shared by every worktree). So in a
worktree created by `fleet new`, everything under `.fleet/` is **ignored**, not
untracked. Consequences the plan never draws:

- `git worktree remove` refuses on *untracked* files but tolerates *ignored*
  ones (it deletes them). So in the normal case the `rm -f ready` + `rmdir` at
  3200 is **defensive, not load-bearing** — and the trailing comment
  `# else it blocks remove` is only true for a worktree whose exclude line is
  missing (hand-made worktree, older fleet, a repo where the common exclude was
  reset).
- Conversely, in *that* case the marker **does** block removal, and B0's
  instruction "`rm -f .fleet/ready` — marker dies only after success" would make
  plain reap start failing where it works today. **B0 as written is a
  regression on that path.** §3 resolves it: the marker deletion stays *before*
  the removal, but becomes **rollback-restorable**, which delivers the same
  retryability without the regression.
- It also means the plan's §1.2 step 6 is right for the wrong stated reason: the
  `mv` dirt is ` D` on **tracked** paths, which are visible to git regardless of
  the exclude line. Exclusion never protected the tracked case. Fine — the
  conclusion stands.

**C2 — R5 is overstated.** "A live worker shell in the worktree cwd could make
`worktree remove` fail." On Linux, unlinking a directory tree that is some
process's cwd succeeds; the process is simply left on a stale cwd. `git worktree
remove` fails on *locked* worktrees, dirty/untracked trees, and submodules — not
on a cwd holder. So reordering kill-after-remove does **not** introduce a new
refusal. §5-R5 commits to this and downgrades the proof case to a smoke test.

**C3 — §2(c)'s bullet contradicts itself mid-sentence** ("does not by itself fix
the tracked case: … → actually it *does* fix it"). Harmless, but the plan should
not ship that sentence into a design doc. The reasoning that survives is exactly
what B2 encodes.

---

## 2. Why B0 is the load-bearing half (the FOR case)

Three arguments, in decreasing order of force.

**2.1 It is the only change that makes a failure retryable.** The live evidence in
§1.3 is the whole argument: `fleet reap X --force` answered `nothing flagged
ready`. The escape hatch the error message recommends *cannot reach the object it
is about*. Every other option (a)–(d) leaves that property intact — they only
reduce the probability of entering the state. `git worktree remove` has failure
modes fleet does not enumerate (locked worktree, submodule, EPERM on the parent,
a concurrent `git` holding `index.lock`, NFS EBUSY on an open file). B1/B2 close
today's trigger; B0 is what makes the *next* one a bad afternoon instead of an
orphan.

**2.2 It makes the documented contract true.** `CLAUDE.md` and `FLEET.md` both
promise reap "refuses any worktree with uncommitted changes or a branch not merged
into its base". Today that promise holds only for early skips. A contract that is
true on four of five refusal paths is a contract users will trust on the fifth.

**2.3 The blast radius is smaller than the plan fears.** The plan calls it "the
largest diff in a destructive path". In practice B0 is: (i) hoist the `win`
resolution (3181–3186) up with the guards — it is pure `tmux list-panes`, already
read-only; (ii) move two calls (3187, 3188) into the existing `if` at 3203; (iii)
add an `else`-branch rollback. The guards themselves, `safe_kill_window`'s three
brakes (186–200), guard 6's ancestry check, and the label-only target match
(3120–3127) are all untouched — which is precisely the set
`test/reap-teardown-safety.sh` cases 1–8 lock in. The plan's own T10 is the right
check and it should pass unmodified.

**2.4 Rebutting the strongest objection against B0.** *"Kill-last risks killing a
window after the worktree is gone / resolving the wrong window."* Real, and the
plan does not answer it. Answer: **resolve the window id during DECIDE, use it
during MUTATE.** `pane_current_path` is read from the pane process's cwd; after
removal that cwd is stale and tmux may report it differently or with a `(deleted)`
suffix, so a post-removal resolution is genuinely unreliable. Resolution is
read-only, so hoisting it costs nothing. With the id captured up front,
`safe_kill_window "$win"` behaves identically to today — same brakes, same target.

---

## 3. The shippable version — exact ordering

Prose + pseudocode only. Names match the existing locals.

### 3.1 DECIDE phase — read-only, ends in `continue` or falls through

```
per flagged worktree:
  ready-marker present?            (3114, unchanged)
  target label match               (3120–3127, unchanged)
  dir exists? else forget+drop     (3129–3131, unchanged — the ONLY early mutation, and it is correct: the dir is already gone)
  linked worktree?                 (3132–3133, unchanged)

  if not --force:
    G5' dirty?      <- B1 (see 3.4)
    G6  merged?     (3140–3155, unchanged)
    G7  inbox needs-human?   (3156–3167, unchanged)
    G8  gate-wait?           (3168–3174, unchanged)

  # NEW, still read-only:
  win  := resolve window by pane_current_path == dir, skipping is_main_pane   # hoisted 3181–3186
  keep := tracked members of .fleet/notes      (git ls-files -z -- .fleet/notes)
  toss := non-tracked members of .fleet/notes  (everything else on disk there)
  notes_is_symlink? -> treat as "not ours": keep={} toss={} , skip archiving entirely
  locked? -> git worktree list --porcelain | grep '^locked'  for this dir  -> skip with the lock reason
```

**On the dry-run probe (plan says "settle in the debate").** Commit to this:
there is no `git worktree remove --dry-run` and there will not be one, so **do not
build a probe.** Build a *precondition + rollback* pair instead:

> Precondition: after G5' passes, the only things standing between this worktree
> and a clean `git worktree remove` are artifacts **fleet itself owns** (`.fleet/`
> untracked/ignored members). Reap is allowed to delete exactly those, because it
> can put every one of them back.

That is a claim reap can *make true*, unlike "will git succeed?", which is
unknowable. The one probe worth adding is cheap and covers the most common real
non-dirt refusal: **the worktree-lock check** above (`git worktree list
--porcelain` prints `locked` for locked worktrees). Add it as a DECIDE guard with
its own message. Everything else falls to the rollback branch.

### 3.2 MUTATE phase — exact order

```
# 1. ADDITIVE ONLY — nothing in the worktree changes yet
stage := mkdir "<root>/.fleet/notes/archive/<repo>__<branch>__<ts>"        # Q5: plain mkdir first
         on collision -> mktemp -d "<same>_XXXX"                          #     fallback only
if force:  cp -a  "$dir/.fleet/notes/."  "$stage/"        # B3: EVERYTHING, tracked included
else:      cp -a  only $toss members     "$stage/"        # B2: git already holds $keep
if any cp fails -> rm -rf "$stage"; print "notes not archived: <err>"; DO NOT DELETE ANYTHING; continue
   # (a failed archive must never license a deletion — this is the §4 "mid-way mv" row, closed)

# 2. FLEET-OWNED DELETIONS — each one restorable from $stage or from a saved var
if not force:
  saved_ready := contents of "$dir/.fleet/ready"          # tiny; hold in a variable
  rm -f  $toss members
  rm -f  "$dir/.fleet/ready"
  rmdir  "$dir/.fleet/notes" "$dir/.fleet"   2>/dev/null || true
# on --force: delete nothing here. `worktree remove --force` tolerates the lot.

# 3. POINT OF NO RETURN
rmerr := $( git -C "${main:-$dir}" worktree remove $rmflag "$dir" 2>&1 )    # B5: CAPTURE, don't discard
```

### 3.3 The two branches

**Success:**
```
git branch -D "$branch"        # unchanged, incl. the existing kept-branch note
   if force AND branch was NOT an ancestor of base -> also print
     "  (unmerged branch <b> deleted; full notes copy at <stage>)"      # Q2
safe_kill_window "$win"        # $win resolved in DECIDE
cmd_forget "$dir"
print "reaped <lbl>"
print "archived <lbl> notes -> <stage>  (N archived; M tracked notes kept in branch history)"   # B4
```
Order inside the branch: **remove → branch -D → kill → forget.** `branch -D`
before the kill because it is the only remaining step that can partially fail and
whose message the user needs; kill before forget because forget mutates the file
the outer loop already snapshotted (3109) and is therefore order-free — put the
tmux side effect first so a `cmd_forget` hiccup cannot leave a live window
pointing at a deleted dir.

**Failure — this is the branch that defines the fix:**
```
# roll back, in exact reverse order of 3.2 step 2:
mkdir -p "$dir/.fleet/notes"
cp -a "$stage/." "$dir/.fleet/notes/"          # restores only what we deleted ($toss)
printf '%s' "$saved_ready" > "$dir/.fleet/ready"
rm -rf "$stage"                                 # archive was never earned
# window, agents line, tracked notes: NEVER touched, so nothing to undo
print "skip   <lbl>: worktree remove failed — worktree left intact, retry after resolving"
print "       git: <first line of $rmerr>"                                    # B5
```

**Rollback-failure handling (plan calls this vague — commit).** Rule: **rollback
is best-effort, but its failure is LOUD and it never overwrites the original
error.** Concretely, only one thing must be verified rather than fire-and-forget:
the marker. After the restore, re-test `[ -e "$dir/.fleet/ready" ]`. If it is
back, print the normal skip. If it is not:

```
print to STDERR:
  "reap: ROLLBACK INCOMPLETE for <lbl>"
  "  worktree still present: <dir>"
  "  ready marker could NOT be restored — this worktree will not be selected by 'fleet reap'"
  "  archived copy of its untracked notes KEPT at: <stage>"          # do NOT rm -rf on this path
  "  recover with:  touch <dir>/.fleet/ready   (then re-run fleet reap)"
```
and keep a non-zero-ish signal by still printing the original git error above it.
Rationale: the marker is the *only* rollback item whose loss re-creates the
original orphan (unreachable by any flag). Notes are re-derivable from `$stage`,
which we deliberately do not delete on this path. So: verify the one thing that
matters, tell the human the exact `touch` that fixes it, keep the evidence.

### 3.4 B1 — the exact filter

Replace the blanket `grep -vE '^...\.fleet/'` with: **ignore a line only if its
status code is `??` AND its path starts `.fleet/`.**

```
dirty := git -C "$dir" status --porcelain 2>/dev/null \
         | grep -vE '^\?\? \.fleet/'
```
Everything else survives, including ` M .fleet/notes/plan.md`, ` D `, `A `, `R `,
`UU `. That is exactly the 1.4 hole, closed, and it turns today's accidental
misleading refusal into a first-class guard hit *before* anything is killed.

**Against R1's proposed marker allowlist: don't.** Keying on `??` already
subsumes it — the markers (`ready`, `roles/<pane>`, `devport`) are per-worktree
runtime state that is either ignored (normal, via the common exclude at 1063–1069)
or untracked (`??`), never tracked. And if a repo somehow *did* commit a `.fleet/`
path and then modify it locally, that is real uncommitted user content and reap
**should** refuse. An allowlist adds a maintenance surface to defend a case where
refusing is the correct answer. R1 is a real question with a boring answer.

### 3.5 Minimal safe diff shape

Six edits, no new functions required (one small helper optional):

1. **3181–3186 → moved up**, verbatim, to just after the guard block. Zero
   semantic change; it is `tmux list-panes` + `is_main_pane`.
2. **3136** — one regex swap (B1).
3. **3189–3199** — `mv` becomes the stage/copy block of 3.2 step 1, with the
   `$keep`/`$toss` partition and the `[ ! -L ]` symlink test added to the existing
   `[ -n "$root" ] && [ -d ] && [ -n "$(ls -A)" ]` chain. Keep the `ls -A`
   short-circuit first (§4 empty-notes row).
4. **3200** — `rm -f ready` gains a `saved_ready=` capture immediately before it,
   and the `$toss` deletion joins it. Position unchanged (see C1).
5. **3203** — `2>/dev/null` → capture into `rmerr`; `if` body gains
   `safe_kill_window` + `cmd_forget` + the B4 line; the existing `branch -D`
   block is untouched.
6. **3220–3221** — `else` branch becomes the rollback + honest message (B5).

Net: one regex, one hoist, one block rewritten, one `else` grown. No change to
`safe_kill_window` (186–200), the guards, the label match, or the `\037`
harness. That is a reviewable diff, not a rewrite — which is the answer to the
plan's own §2(e) "largest diff" worry.

---

## 4. B3 — ship it reduced

Ship: **on `--force`, `cp -a` the whole notes dir (tracked included) and delete
nothing pre-remove.** That is 2 lines and it closes the only genuine data-loss
path in the design (force + unmerged + `branch -D` at 3215 ⇒ tracked notes
reachable only via reflog).

Do **not** ship the plan's implicit framing that `--force` should archive
"redundantly, as the safe default". Say it plainly in the output instead (Q2's
line above), because on the force path the archive is not redundant — it is the
last copy.

---

## 5. Committed answers to the plan's open items

| Item | Answer |
|---|---|
| **Q1 — order inside success branch** | `worktree remove` → `branch -D` → `safe_kill_window` → `cmd_forget`. Window id resolved in DECIDE (§2.4). |
| **R5 — worker shell in cwd** | Not a refusal risk: Linux unlinks a cwd-held tree fine; `worktree remove` objects to locks/dirt/submodules, not cwd holders. Keep one smoke case (worker pane parked in the worktree ⇒ plain reap still reaps, window gone, center alive) rather than the plan's full proof case. Add the **lock** check to DECIDE — that is the real "remove refuses for a reason the guards didn't see". |
| **Dry-run probe** | Don't build one. Precondition + rollback (§3.1). Only added probe: worktree-lock. |
| **Rollback failure** | Best-effort, loud, marker verified explicitly, `$stage` KEPT, exact `touch` recovery printed to stderr, original git error never suppressed (§3.3). |
| **Q2 — force + unmerged `branch -D`** | Yes, print it, with the archive path. |
| **Q3 — `$root` unset** | Print one line: `notes NOT archived (no fleet root) — <N> untracked file(s) deleted with the worktree`. This is an `echo`, not a failure — it does not violate the `\|\| true` style, and silent deletion of the only copy is the worse sin. |
| **Q4 — fix 3221 regardless** | Yes, same change (B5). It is the reason this bug took a live reproduction to find. |
| **Q5 — archive collision** | `mkdir "$arch"`; on failure `mktemp -d "${arch}_XXXX"`. Verified nothing parses the leaf name (only `bin/fleet:3189/3195/3196` + prose in `CLAUDE.md:179`, `FLEET.md:33`), so the fallback shape is free. |
| **Q6 — keep `--force`?** | Keep it; stop recommending it (B5 only). Reject the `--force-dirty`/`--force-unmerged` split and `--retry` for this change: post-B0 a plain re-run *is* the retry, and splitting the flag touches `FLEET.md`, `CLAUDE.md` and the dashboard action — a separate scope. |
| **Q7 — already-orphaned worktrees** | Out of scope. Post-B0 no new ones are created; the existing one is `git worktree remove` + `git branch -D` by hand (§1.3 shows it needs no `--force`). If it recurs, `fleet reconcile` is the home, not `cmd_reap`. |
| **R2 — archive no longer universally complete** | Real; B4 says it per-reap, and the `CLAUDE.md:179` / `FLEET.md:33` bullet must be narrowed in the same change ("untracked scratch archived; tracked notes stay in branch history"). Do not ship the code fix while the doc still over-promises. |
| **R3 — should notes ever be tracked?** | Support it. Fleet must not corrupt a repo for making a choice fleet didn't anticipate, and this repo's own branches carry tracked notes. Not hypothetical. |
| **R4 — harness fidelity** | Agreed and load-bearing: `mkrepo` must append `/.fleet/` to the **common** exclude (`--git-common-dir`, mirroring 1063–1069), or the untracked cases test a different status than production. Per C1 this also means the harness needs a variant *without* the exclude line, to cover the marker-blocks-removal case B0 must not regress. |

---

## 6. Test additions beyond the plan's T1–T10 / A1–A5

The plan's matrix is good. Three gaps, all from §1's corrections:

- **T11 — worktree with NO `/.fleet/` exclude line** (marker shows as `??`).
  Plain reap must still succeed. This is the case B0-as-written would have broken
  (C1); it must be red-lined before the reorder is accepted.
- **T12 — locked worktree** (`git worktree lock`). Plain reap skips with the lock
  reason, `assert_intact`. Covers the new DECIDE guard and gives A2 a *real*
  post-guard failure fixture — better than the plan's proposed `chmod a-w` or the
  test-only env hook, and it needs no production scaffolding.
- **T13 — rollback path itself.** Using T12's lock as the fixture but with the
  lock applied *between* guards and removal is fiddly; simpler: force the failure
  with a lock and assert the failure branch's full contract — `$stage` cleaned
  up, `$toss` files back in `.fleet/notes` byte-identical, `.fleet/ready` back,
  git's real error text in the output, and a second plain `fleet reap` selects the
  same worktree. That is A2 made concrete.

A2's fixture should be **T12's lock**, not the 1.4 filter hole — B1 closes that
hole in the same change, so the plan's preferred fixture (ii) evaporates on
green.

---

## 7. Residual honest caveats

- B0 does not make reap *transactional* in any strong sense; it makes it
  **restartable**, which is the property that actually matters here. A crash
  (SIGKILL) between step 2 and step 3 still orphans — accepted, and strictly
  better than today's guaranteed orphan on a routine refusal.
- The `cp` doubles I/O on the archive path. Notes are markdown. Non-issue.
- B1 will start refusing reaps that today silently half-succeed. That is the
  point, and it will look like a regression to anyone who has been living with
  the old behaviour. B5's message is what makes it legible.

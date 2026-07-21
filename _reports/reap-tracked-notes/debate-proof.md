# Adviser review — PLAN.md §5 "Proof design"

Read-only. No file under `test/` created or edited. All line refs are `bin/fleet`
on current `main`; the existing harness is `test/reap-teardown-safety.sh` (220 lines).

**Verdict up front.** The proposed shape is close but has **6 real mismatches**
with the existing harness and **2 hard-fail contamination paths** (T9 as written
writes into the live repo; every successful reap case runs `fuser -k 9222/tcp` on
the developer's machine). The open fixture question is **settled by experiment**:
candidate (i) — the `.fleet/` porcelain-filter hole — **works and is the only
correct choice**; candidate (ii) — `chmod a-w` the parent — **is destructive and
must be rejected**, because git deletes the worktree contents *and* unregisters
it before failing, which destroys the very thing A1a/A2 exist to assert survives.

---

## 1. Does the proposed harness match the existing one?

### Matches (no change needed)

| Element | Existing | Plan §5 | OK? |
|---|---|---|---|
| `set -u`, `HERE`, `FLEET` | L20–23 | same | ✅ |
| `TMPROOT=$(mktemp -d)` + `TMUX_TMPDIR` + `XDG_CONFIG_HOME` + `unset TMUX` | L27–30 | same | ✅ |
| `trap cleanup EXIT` → `tmux kill-server; rm -rf` | L32–33 | same | ✅ |
| `pass()`/`fail()` exit-the-subshell idiom | L37–38 | same | ✅ |
| `( c=N; … ) ; rN=$?` + `tot=$((…))` + `== summary: …` / `RESULT: …` | L104–219 | same | ✅ |
| `reap() { FLEET_SESSION="$1" "$FLEET" reap "${@:2}" 2>&1; }` | L96 | same | ✅ |
| Exit 0 only if every case passes | L214–219 | same | ✅ |

### Mismatches — name them

**M1 — `mkrepo` cannot be reused "verbatim" for any case that commits.**
`mkrepo` (L57–70) passes `-c user.email=t@t -c user.name=t` **only** on the one
`--allow-empty` init commit. Every new case commits notes (T1, T3, T4b, T5, T6),
and those commits run in the *worktree*, where no identity is configured. If the
developer's global `user.email` is set it silently works; on a clean machine or
under `GIT_CONFIG_GLOBAL=/dev/null` it fails and the case passes/fails for the
wrong reason. Fix: a `commit_in()` helper that always carries the `-c` pair, used
everywhere — do not rely on ambient config.

**M2 — `mkrepo` writes no `info/exclude`.** Already caught as R4; restating
because it is load-bearing, not cosmetic. Production `cmd_new` appends `/.fleet/`
to the **common** `info/exclude` (L1063–1068). Without it, `git status --porcelain`
in the harness shows `?? .fleet/` — which *is* what production shows too (verified
below), so the untracked cases do not silently diverge on the *status code*; but
the archive/exclude semantics of `.fleet/notes` do. Add it in `mkrepo` against
`git rev-parse --git-common-dir`, exactly as L1063–1068 does, not against `.git/`
(a linked worktree's `.git` is a file).

**M3 — the summary hard-codes `8`.** L212–213 (`tot=$((r1+…+r8))`,
`$((8-tot))`). With T1–T10 + A1–A5 that is 15 explicit `rN` slots and two
hard-coded counts. Keep the same idiom (the plan says so) but state the count in
one place; a stale literal turns a missing case into a silently green run.

**M4 — no `assert_intact` contract stated.** `assert_center_alive` (L45–52) works
only because `fail()` *exits the subshell*, so it can be `&&`-chained
(`assert_center_alive … && pass`). The plan's proposed `assert_intact` must obey
the identical contract: call `fail "$c" "<what>"` on each violation, `return 0` at
the end. If it instead returns nonzero, `assert_intact … && pass` silently drops
the case to "no pass, no fail" and `rN` becomes the exit of the last command.
Spell this out.

**M5 — the A-cases need a worker window id; the plan never says who creates it.**
`addwin` (L92–94) echoes the window_id, so `win=$(addwin "$s" worker "$wt")` is
the idiom. But note the *reap resolver* (L3176–3186) matches a pane by
`pane_current_path == $dir` — `addwin … "$wt"` gives exactly that. Required for
A1a/A2/A3 ("the worker window survives"); without it those cases assert nothing
because there is no window to kill.

**M6 — T9 ("no `$root`") is not achievable by omission, and as written it writes
into the live repo.** See §4 HF-1. This is the single largest design error in §5.

### Optional hardening (a deliberate deviation, flag it as such)

`export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null` alongside the
existing isolation. The current harness does not do this and gets away with it
(`branch -M main 2>/dev/null`, no content commits). The new harness commits real
content and asserts on branch names and mergedness, so ambient
`init.defaultBranch`, `core.hooksPath`, and `includeIf` blocks become live
variables. Combined with M1 this is cheap and makes the run reproducible.

---

## 2. The fixture question — SETTLED BY EXPERIMENT

Both candidates were run in a throwaway repo under `$TMPDIR` (real `git`, real
`git worktree remove`, non-root). Reproduction of what was run and observed:

### Candidate (i) — the `.fleet/` porcelain-filter hole ✅ **USE THIS**

```
mkdir -p wt/.fleet; echo junk > wt/.fleet/junk
git -C wt status --porcelain                        →  ?? .fleet/
git -C wt status --porcelain | grep -vE '^...\.fleet/'  →  (empty)   # guard 5 passes
git -C repo worktree remove wt
  fatal: 'wt' contains modified or untracked files, use --force to delete it
  rc=128
```

Post-failure state — **fully intact**:

```
git -C repo/wt rev-parse --git-dir   →  repo/.git/worktrees/wt      (still linked)
git -C repo worktree list --porcelain →  still lists repo/wt on refs/heads/feat
wt/ contents                          →  untouched
```

Why it works end-to-end inside `cmd_reap`: guard 5 (L3136) filters `?? .fleet/`
away → passes. Guard 6 passes (branch merged). L3200's
`rmdir "$dir/.fleet/notes" "$dir/.fleet"` **fails** because `.fleet` still holds
`junk` → `.fleet/` survives as untracked → `git worktree remove` (no `--force`,
L3202) refuses at L3203 → the L3221 late skip fires, *after* `safe_kill_window`
(L3187) and `cmd_forget` (L3188) already ran. That is precisely the A1a/A2
fixture: a real late failure, no production change, worktree recoverable, second
reap genuinely retryable.

**It is not synthetic.** `fleet devport <n>` (`cmd_devport`, L3256–3266) writes
`<worktree>/.fleet/devport` — a real, untracked, non-`notes` file that any worker
running a dev server leaves behind. Use `fleet devport 4173` (or a literal
`.fleet/devport` file) as the fixture rather than an invented `junk`; then the
case documents a real user path instead of a contrivance.

**It survives B1.** The plan worries the fixture dies if B1 closes the filter
hole. It does not: B1 narrows the filter to *keep ignoring untracked (`??`)
`.fleet/` entries* and stop ignoring tracked-modified ones. `?? .fleet/` stays
filtered, so guard 5 still passes and the fixture still produces a late failure.
It also survives B2 (partition-archive touches only `.fleet/notes`; `devport`
sits beside it, so `rmdir .fleet` still fails). No fallback needed.

### Candidate (ii) — `chmod a-w` the parent dir ❌ **REJECT**

```
chmod a-w repo/sub                       # parent of the worktree
git -C repo/sub/wt2 status --porcelain   →  (clean)
git -C repo worktree remove repo/sub/wt2
  error: failed to delete '…/sub/wt2': Permission denied
  rc=255
```

`rc != 0`, so `cmd_reap` takes the late-skip branch as desired — **but the state
afterwards is destroyed**, which invalidates the case:

```
ls -a sub/wt2                            →  EMPTY (all files deleted)
git -C repo worktree list --porcelain    →  wt2 NO LONGER LISTED (admin dir pruned)
second `git worktree remove sub/wt2`     →  fatal: … is not a working tree
```

`git worktree remove` deletes the contents and unregisters the worktree **first**,
then fails only on the final `rmdir` of the top directory. So the "failure" is a
successful destruction with a nonzero exit. A1a/A2 assert `assert_intact` —
worktree dir, `.fleet/ready`, `.fleet/notes` with files — and all three are gone.
The case would report RED for the wrong reason and could never go GREEN.

Two further strikes: `rm -rf "$TMPROOT"` in `cleanup()` **fails** on a read-only
parent (`rm: cannot remove …: Permission denied`, rc=1), leaking the temp tree on
every run unless `cleanup()` gains `chmod -R u+w "$TMPROOT"` first — a deviation
from the existing harness's cleanup. And a bare `chmod a-w "$dir"` with an unset
`$dir` under `set -u` is a footgun in a script that manipulates permissions.

### Verdict

Use **(i)**, sourced from a real `.fleet/devport` marker. Do **not** ship any
`FLEET_TEST_FAIL_REMOVE` env hook — (i) removes the need, and the plan is right
that test scaffolding in a destructive production path is against repo style.
Drop the `chmod a-w` fallback from §5 entirely and record *why* (it destroys
before it fails), so nobody re-proposes it.

---

## 3. Concrete assertions, and RED/GREEN on current `main`

Conventions: `wt` = worktree dir, `s` = throwaway `FLEET_SESSION`, `root` =
`$TMPROOT/cN`, `out=$(reap "$s" …)`. Every case calls `boot` and ends with
`assert_center_alive "$c" "$s"`. "RED" = fails on current `main`.

### Functional cases

| # | Exact assertion | Now |
|---|---|---|
| **T1** | `out=$(reap "$s")`; `printf '%s' "$out" \| grep -q '^reaped repo/feat'` **and** `[ ! -d "$wt" ]` **and** `[ -z "$(git -C "$root/repo" branch --list feat)" ]` **and** `git -C "$root/repo" show "main:.fleet/notes/plan.md" >/dev/null 2>&1` (tracked half reachable from history) | **RED** — `mv` dirties, `worktree remove` refuses, output is `skip … (uncommitted? use --force)`, `[ -d "$wt" ]` still true |
| **T2** | notes untracked; after reap: `[ ! -d "$wt" ]`, and for each name `n`: `cmp -s "$arch/$n" "$saved/$n"` where `arch=$(printf '%s' "$out" \| sed -n 's/^archived .* -> //p')` | **GREEN** (must stay green — regression lock) |
| **T3** | 2 committed + 2 untracked. `[ ! -d "$wt" ]`; both untracked names `cmp -s` under `$arch`; both tracked names resolve via `git -C "$root/repo" cat-file -e "main:.fleet/notes/<n>"`; `printf '%s' "$out" \| grep -qE 'archived .*2 files.*2 tracked'` (B4 counts) | **RED** — same `mv`-dirt refusal as T1; the B4 count string does not exist |
| **T4a** | modified tracked file **outside** `.fleet/`: `grep -q 'skip .*uncommitted'`; `[ -d "$wt" ]`; `[ -e "$wt/.fleet/ready" ]`; `[ -d "$wt/.fleet/notes" ]`; `tmux list-windows -t "=$s" -F '#{window_id}' \| grep -qx "$win"`; `grep -qF "$wt" "$XDG_CONFIG_HOME/fleet/sessions/$s.agents"`; branch still listed | **GREEN** — guard 5 fires at L3136 before any mutation |
| **T4b** | same, but the modified tracked file is **inside** `.fleet/notes/` (the 1.4 hole) | **RED** — guard 5's `^...\.fleet/` filter drops ` M .fleet/notes/x.md`; reap proceeds, kills the window and forgets the agent, then late-skips. The *message* matches by luck (`skip … uncommitted?`) but `assert_intact` fails on window + agents-line |
| **T5** | branch has a commit not in `main`: `grep -q 'skip .*not merged into main'`; `assert_intact` | **GREEN** — guard 6, L3153 |
| **T6** | T5 + `--force`: `[ ! -d "$wt" ]`; `[ -z "$(git … branch --list feat)" ]`; tracked note byte-present under `$arch` | **RED** — today `mv` archives everything so the *content* assertion passes, but only by accident of the bug; post-B2/B3 this must be the explicit force-path guarantee. Mark it RED-by-intent and assert on the B4 output line too, else it green-lights the wrong implementation |
| **T7** | `mkdir -p "$wt/.fleet/notes"` (empty): reap succeeds; `[ -z "$(ls -A "$root/.fleet/notes/archive" 2>/dev/null)" ]`; `[ ! -d "$wt" ]` | **GREEN** — `ls -A` short-circuit at L3193 |
| **T8** | `ln -s "$TMPROOT/c8/elsewhere" "$wt/.fleet/notes"` with a file inside the target: after reap `[ -f "$TMPROOT/c8/elsewhere/keep.md" ]` **and** `[ ! -L "$arch" ]` (no dangling link archived) | **RED** — `[ -d ]` at L3193 follows the link, `mv` moves the *link*; archive holds a dangler and the target is orphaned |
| **T9** | see HF-1 — must be `FLEET_ROOT` unset **and** cwd forced inside `$TMPROOT`, **and** `@fleet_root` never set. Assert reap succeeds, `[ ! -d "$wt" ]`, `[ ! -d "$PWD/.fleet/notes/archive" ]` | **GREEN once rewritten**; as written in §5 it is a live-repo write |
| **T10** | `bash "$HERE/test/reap-teardown-safety.sh" >/dev/null 2>&1` → rc 0 | **GREEN** — must stay green through B0's reordering (this is the case that catches R5) |

### Atomicity cases (the primary proof)

`assert_intact <c> <wt> <sess> <win>` = all five: `[ -d "$wt" ]`,
`[ -e "$wt/.fleet/ready" ]`, `[ -n "$(ls -A "$wt/.fleet/notes")" ]`,
`tmux list-windows -t "=$sess" -F '#{window_id}' | grep -qx "$win"`,
`grep -qF "$wt" "$XDG_CONFIG_HOME/fleet/sessions/$sess.agents"`.

| # | Exact assertion | Now |
|---|---|---|
| **A1a** | fixture (i): tracked notes, clean, merged, **plus** `echo 4173 > "$wt/.fleet/devport"`. `reap "$s"` → `grep -q '^skip'`; then `assert_intact` | **RED** — window killed at L3187, agent forgotten at L3188, `.fleet/ready` removed at L3200; four of five sub-assertions fail |
| **A1b** | post-fix, no `devport`, tracked notes, clean, merged: `grep -q '^reaped'`; `[ ! -d "$wt" ]`; window gone; agents line gone; notes union-preserved (T1 rule) | **RED** — identical to T1 today |
| **A2** | fixture (i). First `reap "$s"` → `grep -q '^skip'` + `assert_intact`. Then **second plain** `reap "$s"` (no `--force`) → output **must not** contain `nothing flagged ready`, and must again name `repo/feat` | **RED** — this is the exact live failure: the marker and the agents line are gone, so pass 2 prints `nothing flagged ready` |
| **A3** | for each of T4a, T4b, T5, A2-pass-1: `[ -e "$wt/.fleet/ready" ]` after the refusal | **RED** for T4b and A2 (L3200 already deleted it); GREEN for T4a and T5 |
| **A4** | after any refusal: `[ -z "$(git -C "$wt" status --porcelain)" ]` — **unfiltered** | **RED** for A2/T1-shaped refusals (`mv` left ` D .fleet/notes/*`); GREEN for T4a/T5. This is the §1.3 "recovery needed no `--force`" tell, encoded |
| **A5** | `grep -c -- '--force' <the T1/T3 case bodies>` = 0, plus T1/T3 pass | **RED** transitively (T1/T3 red). Implement as a plain source-level assertion over the harness's own text, or simply by construction — do not add a `--force` retry anywhere in T1/T3 |

**Red-first tally on current `main`:** RED = T1, T3, T4b, T6(by-intent), T8,
A1a, A1b, A2, A3, A4, A5 → 11. GREEN = T2, T4a, T5, T7, T9(rewritten), T10 → 6.
§5's claim "expect T1/T3/T4 to fail" **undercounts**: T8 and the entire A-block
are also red, and T4 is red only in its **b** sub-case (T4a is green today).
Say so in the harness header, or the first red run reads as a broken harness.

---

## 4. Contamination risks — hard fails

**HF-1 — T9 as written writes into the live repo. Hard fail.**
`fleet_root()` (L94–100) is *not* fail-empty: `@fleet_root` unset → `$FLEET_ROOT`
→ **`pwd`**. `cmd_reap` binds `root=$(fleet_root 2>/dev/null)` at L3101 and the
archive block only tests `[ -n "$root" ]` (L3193) — which `pwd` always satisfies.
Run the harness from the repo (the normal way), omit `@fleet_root` to "simulate no
root", and `cmd_reap` does
`mkdir -p /home/red/proj/pc-tune/fleet/main/.fleet/notes/archive` **and moves the
fixture notes into the live tracked checkout**. T9 must instead `cd "$TMPROOT/c9"`
inside the subshell (or set `FLEET_ROOT="$TMPROOT/c9"`) and additionally assert
`[ ! -e "$HERE/.fleet/notes/archive" ]`. The §5 sentence "run with the project-root
lookup unresolvable" describes a state that does not exist.

**HF-2 — `fuser -k "${FLEET_DEBUG_PORT:-9222}/tcp"` fires on every successful
reap.** `cmd_reap`'s last line runs it whenever `reaped > 0`. Nothing about
`TMUX_TMPDIR`/`XDG_CONFIG_HOME` isolates a TCP port: any real Chromium (or
anything else) listening on 9222 on the developer's machine gets **killed** by
T1/T2/T3/T6/T7/T9/A1b — and by the existing harness's cases 1 and 8 today. Fix:
`export FLEET_DEBUG_PORT=<unused high port>` next to the other isolation exports.
Pre-existing hole; the new harness multiplies its frequency.

**HF-3 — T8's symlink target must be inside `$TMPROOT`.** Post-B2 the fix will
`rm -rf` untracked archive members. A `.fleet/notes` symlink pointing anywhere
real turns that into deletion of real files. Assert the target path begins with
`$TMPROOT` before creating it, and never use a bare `/tmp/elsewhere` as §5's table
literally writes.

**HF-4 — every `fleet` invocation must carry `FLEET_SESSION`.** `session_name()`
(L89–92) falls back to `tmux display -p`. With `TMUX` unset and a private
`TMUX_TMPDIR` that resolves against the *private* server, so it is safe — but only
as long as `TMUX_TMPDIR` is exported before the first tmux call and no case
`unset`s it. The existing `reap()` wrapper enforces this; any new direct
`"$FLEET" …` call (e.g. a `fleet devport` fixture step) must go through an
equivalent wrapper, not a bare call.

**Not a risk:** `tmux kill-server` in `cleanup()` is confined by `TMUX_TMPDIR`
(verified pattern, existing L32). Guard against an *early* trap firing before
`mkdir -p "$TMUX_TMPDIR"` — the existing harness sets both on one line, keep that.

---

## 5. Summary of required changes to §5

1. Fixture: adopt candidate (i) via a real `.fleet/devport` marker. Delete the
   `chmod a-w` fallback and the `FLEET_TEST_FAIL_REMOVE` option, with the reason
   recorded (chmod destroys-then-fails; env hook ships test code in prod).
2. Rewrite T9 (HF-1) — `pwd` fallback, not an unresolvable root.
3. `export FLEET_DEBUG_PORT=<unused>` (HF-2).
4. Constrain T8's symlink target to `$TMPROOT` (HF-3).
5. `commit_in()` with explicit `-c user.email/-c user.name` (M1); `info/exclude`
   via `--git-common-dir` in `mkrepo` (M2).
6. State `assert_intact`'s fail-exits-subshell contract (M4); capture the worker
   window id from `addwin` (M5); single-source the case count (M3).
7. Correct the red-first expectation to the 11 cases listed above.

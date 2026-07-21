# TEST-VERDICT — adversary review of `fleet new-project`

**Verdict: DONE** (re-test of fix commit 9d9c0dc — both gaps closed, no new defect)

---

## Re-test (commit 9d9c0dc)

Re-ran the full adversary checklist in throwaway `/tmp` HOME sandboxes
(`HOME=$(mktemp -d)/home`, `XDG_CONFIG_HOME`/`TMUX`/`FLEET_SESSION`/`FLEET_ROOT`
unset, wizard driven non-interactively via heredoc). Real config and live tmux
never touched. Every run exited 0 (fail-silent property holds).

**GAP #1 (duplicate NAME clobber) — CLOSED.** First create `…/a/foo` (repo
alpha) wrote `foo.yml` → `root: …/a/foo`. Second create `…/b/foo` (basename
"foo", repo beta) was refused — `fleet: project foo already exists — pick
another directory/name`, exit 0, no write. `foo.yml` AFTER the second run STILL
pointed at `a/foo` (NOT clobbered to `b/foo`). The `[ -e "$yml" ]` guard at
bin/fleet:452 fires before the printf at bin/fleet:473. PASS. Also verified the
post-sanitize collision: `f.oo` (dot stripped → derives "foo") is likewise
clash-refused against an existing `foo`, first pointer intact.

**GAP #2 (reserved sentinel + empty name) — CLOSED.** Dir basename
`__fleet_new__` → refused (`'__fleet_new__' is not a usable project name`),
exit 0, NO `__fleet_new__.yml` (the projects dir was never even created). Dir
`@@@` (sanitizes to empty) → refused (`'' is not a usable project name`), exit 0,
no yml. Guard at bin/fleet:447 (`[ -z "$name" ] || [ "$name" = "__fleet_new__" ]`).
PASS.

**NEW DEFECT HUNT (check 3).**
- 3a/3b leftover-dir: `mkdir -p "$pdir"` (bin/fleet:438) runs BEFORE name
  validation, so a refused project leaves behind the **empty** dir the user
  literally named (e.g. `…/r/__fleet_new__/`). Confirmed: the dir exists but
  contains **zero repos**. **Judgment: ACCEPTABLE / benign.** The orphan is just
  an empty directory at the exact path the user typed — not an orphaned tree of
  bare repos. The harmful case the spec warned about (repos seeded for a doomed
  project) does NOT occur.
- 3c ordering: validation (bin/fleet:447–455) provably precedes the repo loop
  (`while` at bin/fleet:458, `new_bare_repo` at bin/fleet:464). A refused project
  never reaches the loop — confirmed empty refused dirs in both the reserved-name
  and clash cases.
- 3d re-create-on-same-project: re-running create on an already-created project
  dir hits the non-empty-dir confirm prompt first (answered `y`), then the clash
  check refuses BEFORE the repo loop — so no second repo is seeded into the
  existing project and its yml is untouched. The confirm-prompt × clash-check
  ordering interacts sanely. No new defect found.

**REGRESSION (check 4) — PASS.** Fresh valid project under `$HOME`
(`~/work/coreproj`, 2 repos): yml written with non-vacuous `~` contraction
(`root: ~/work/coreproj`); each repo bare-seeded (`is-bare-repository=true`,
`HEAD -> refs/heads/main`, `refs/heads/main` resolves); `git worktree add -b feat
… main` exits 0 with no "invalid reference: main".
`bash .fleet/notes/proof-new-project.sh` → all checks GREEN, exit 0.
`bash -n bin/fleet` → syntax 0.

**Bottom line:** Both spec gaps are genuinely closed; I could not break the fix.
The only residual is a benign empty leftover directory (the user's own named
path) on a refused run — no repos, no orphaned data, no yml. **DONE.**

---

## Prior history (commit before 9d9c0dc)

**Verdict: NEEDS-WORK**

Two distinct spec-level defects, both independently reproduced in throwaway
`/tmp` HOME sandboxes (TMUX/FLEET_SESSION/XDG_CONFIG_HOME/FLEET_ROOT unset, real
config and live tmux never touched). Neither crashes — every invocation exits 0,
so the "never hard-crashes" property holds — but the spec asks for behaviour the
impl does not deliver.

---

## BLOCKING gaps (spec violation / data loss)

### 1. Duplicate project NAME silently overwrites `projects/<name>.yml`  (bin/fleet:457-459)

Spec: "name clash → refused". Impl: no existence check before the redirect.
`name` is derived from the project-dir basename (`basename "$pdir" | tr -cd ...`,
bin/fleet:454) and the yml is written unconditionally with `printf ... > "$yml"`
(bin/fleet:458). Two project dirs sharing a basename collide.

Reproduced:
```
printf '%s\nalpha\n\n' "$P/A/foo" | fleet new-project   # yml: root=$P/A/foo
printf '%s\nbeta\n\n'  "$P/B/foo" | fleet new-project   # yml: root=$P/B/foo  <- CLOBBERED
ls projects/  -> single foo.yml, now pointing at B
```

**Blast radius:** the FIRST project becomes unreachable from the picker — its
saved pointer (`projects/foo.yml`) is gone; `fleet up foo` / the fzf row now resolve
to the second root only. The first project's *on-disk repo data is NOT lost*
(`$P/A/foo/alpha/.git` still exists), but there is no longer any saved entry
pointing at it, so it is orphaned until the user re-creates it by hand. This
confirms Tester B's CHECK 1. **Fix:** add an `[ -e "$yml" ]` guard before
bin/fleet:458 and refuse (or prompt) on collision.

### 2. Sentinel `__fleet_new__` COLLIDES with a real project of that name  (bin/fleet:400 vs 417-418, reachable via :454)

The collision Tester A waved off as "irrelevant to the create path" is **real and
reachable**, and it is the picker — the documented entry point — that breaks.

- The picker emits the sentinel row with `field1 == __fleet_new__` (bin/fleet:400),
  then real-project rows whose `field1` is the yml basename (bin/fleet:404, 407/409).
- Routing is `field1=$(cut -f1); if [ "$field1" = "__fleet_new__" ] then cmd_new_project else cmd_up` (bin/fleet:417-418).
- `cmd_new_project` will happily create a project literally named `__fleet_new__`:
  the name sanitizer `tr -cd 'a-zA-Z0-9_-'` (bin/fleet:454) keeps every char of
  `__fleet_new__`, so a project dir named `__fleet_new__` writes
  `projects/__fleet_new__.yml`.

Reproduced — the yml is created:
```
printf '%s\ngamma\n\n' "$P2/__fleet_new__" | fleet new-project
ls projects/ -> __fleet_new__.yml  (name: __fleet_new__, root: .../__fleet_new__)
```
And the routing, fed that row's field1, mis-routes:
```
field1='__fleet_new__'  ->  ROUTES TO cmd_new_project   (WRONG: should be cmd_up __fleet_new__)
```
**Consequence:** once a `__fleet_new__` project exists, its picker row is
indistinguishable from the create-new sentinel; selecting it re-launches the
wizard instead of booting the project — the project is **permanently unreachable
through the picker.** Severity is below #1 (needs a user to name a project
`__fleet_new__`, unlikely but not guarded), but it is a genuine sentinel/data
collision the spec called out to verify. **Fix:** either reject `__fleet_new__`
as a project name in the sanitizer, or key routing on a tab/column that real
project names cannot produce (e.g. a non-printable marker, or check membership in
the yml set rather than a magic string).

---

## NON-blocking / verified-safe (no action required)

- **`new_bare_repo` repo named `HEAD`** — created fine; `is-bare-repository=true`,
  `refs/heads/main` resolves, `worktree add -b feat ... main` exits 0. No issue.
- **`.git` already exists as a FILE under `$pdir/$repo`** — `[ -e "$pdir/$repo" ]`
  (bin/fleet:447) fires first → "already exists, skipped"; `new_bare_repo` never
  runs, the file is untouched. Safe.
- **Slash branch name (`feat/x`)** — `cmd_new` dir-substitutes to `feat_x` but
  passes the original `feat/x` to `-b`; `worktree add -b feat/x .../feat_x main`
  exits 0 off the seeded container. The seed satisfies the slash path too.
- **Hardcoded `main` base** — correct here. The seed defines exactly
  `refs/heads/main`; `cmd_new`'s base resolution (bin/fleet:780-798) finds no
  `origin/HEAD` and no local non-main branch on a fresh container, so
  `from="main"` and `baseref="refs/heads/main"` — matches the seed. There is no
  wizard path that produces a container with a different default branch, so the
  hardcode is not a latent bug; just note it is coupled to the seed.
- **`git` missing on PATH** — `new_bare_repo` guards every `git` with
  `... || return 1` and backs out (`rm -rf`); the wizard prints "failed to create"
  and continues, exit 0. Fail-silent holds. (My first PATH=/nonexistent run
  mis-fired on `env` not found and was discarded; the code path is verifiable by
  inspection — bin/fleet:137-145 each return non-zero on git failure.)

---

## Tester-check audit

- **Tester B** — solid. CHECK 1 (dup name) is the correct headline finding,
  correctly pinned, independently reproduced here. CHECKS 2-6 (repo-dup, non-empty
  dir both branches, traversal/sanitization, empty input, unwritable path) are
  real negative tests with genuine evidence; the `.`/`..` traversal probe is
  thorough and the "neutralized only by the `[ -e ]` guard" note is fair.
- **Tester A** — mostly solid; the load-bearing Check 3/4 (real `cmd_new`
  worktree-add off `main`, no "invalid reference") are the strongest evidence and
  I confirm them. BUT: (a) Tester A's claim that the sentinel collision is
  "irrelevant to the create path" is **wrong** — the collision is reachable and
  breaks the picker (gap #2 above). (b) Tester A reported GREEN while never
  testing a duplicate *project* name at all (only duplicate *repo* names, ADV2),
  so it missed gap #1 entirely. (c) Tester A's own Drive-2 fixes the genuinely
  vacuous `~`-contraction check that Drive-1 left untested (Drive-1's project dir
  was outside HOME, so the contraction never fired) — that self-correction was the
  right call and the contraction is now properly proven.

---

## Bottom line

The create-and-seed machinery is sound (bare repos seed `main`, the real
`fleet new` consumes them, sanitization/traversal/fail-silent all hold). It fails
the spec on two points of **identity/uniqueness**: duplicate project names
silently clobber the saved pointer (data-orphaning, bin/fleet:457-459), and the
`__fleet_new__` sentinel is forgeable as a real project name that then becomes
unreachable through the picker (bin/fleet:400/417-418, reachable via :454).
**NEEDS-WORK.**

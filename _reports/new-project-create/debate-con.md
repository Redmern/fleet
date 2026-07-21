# CON / RISK adviser — fleet "new-project-create"

Adversarial review of the design. Every risk below was verified against `bin/fleet`
(line refs) and, where behaviour was in doubt, reproduced with live `git`
(git 2.54.0, local `init.defaultBranch=master`). Each risk has a severity and a
**concrete mitigation the PLAN must adopt**.

Severity scale: **BLOCKER** (ships broken / crashes fleet) · **HIGH** (common path
fails or corrupts state) · **MED** (bad UX, recoverable) · **LOW** (polish).

---

## 0. The one structural risk: `die()` is `exit 1`, not fail-silent

`bin/fleet:21` → `die() { echo "fleet: $*" >&2; exit 1; }`.

The picker (`cmd_pick_project`) runs in the **foreground fleet process** at the
bare-`fleet` entry. The MAP-picker plan routes the sentinel to `cmd_new_project`
*inside that same process*. If `cmd_new_project` (or any helper it calls, e.g.
`cmd_up`, `resolve_repo`, `git worktree add … || die`) hits a `die`, **the whole
`fleet` invocation exits 1** — the user is dumped back to a bare shell with a
half-created project on disk. That directly violates the project's load-bearing
fail-silent convention (CLAUDE.md: "guard external calls and `exit 0` / fall back").

**Mitigation (BLOCKER):** `cmd_new_project` must **never let a `die` escape**. Run
the wizard so that any failure (`mkdir` fails, git init fails, user Esc) prints a
message and `return 0` back to the shell — never `exit`. Concretely: do **not**
call functions that `die` on the create path without wrapping; validate inputs
yourself and `return 0` on every rejection. The single legitimate hard-exit is
the final successful `cmd_up "$name"` handing off to the session (and even that
should be the last statement so nothing is left half-done).

---

## 1. EMPTY PROJECT, NO REPOS — what does the repo-less root do?

**Verified safe (the fail-silent convention holds here):**

- `discover_repos` (102): `for d in "$root"/*/` with `[ -d "$d" ] || continue`.
  Reproduced in **bash**: on an empty root the glob stays literal, the `[ -d ]`
  guard skips it, **0 repos, no error, no divide-by-zero.** (Note: the same loop
  in zsh errors `no matches found` — but fleet is bash, so this is fine. Do NOT
  port any of this to a zsh context.)
- `cmd_repos` (405) → `discover_repos | cut | awk` → empty output, rc 0. The
  dashboard new-agent form just shows an empty repo list. No crash.
- `cmd_up` (3455) boots a session on any existing dir; it never counts repos. A
  repo-less root boots a clean command center fine.

**The real risk is downstream UX, not a crash:** after creating an empty project,
the user lands in a command center where **`fleet new <repo> <branch>` cannot work
at all** (no repo to resolve → `resolve_repo` returns 1 → `cmd_new` calls
`die "repo '…' not found"`, exit 1). If the wizard boots the session *without*
having added at least one repo, the user is stuck in a dead-end session.

**Severity: HIGH (dead-end UX).**
**Mitigations the PLAN must adopt:**
1. The wizard's **add-repos loop must run before `cmd_up`**, and should **strongly
   steer** the user to create at least one repo (offer "add another / done"). It's
   acceptable to allow booting with zero repos (user may add later), but then
   **print an explicit hint** ("project has no repos yet; create one with
   `fleet new-repo …` or re-run the wizard") so the empty session isn't silently
   confusing.
2. Confirm `fleet-dash` tolerates a 0-agent / 0-repo session (it already consumes
   `fleet agents` which is empty here — low risk, but the test plan must include
   "boot a brand-new empty project and look at the dashboard").

---

## 2. BARE REPO CREATION — the empty-bare-repo worktree trap (BLOCKER)

**Reproduced the exact failure** the PLAN must design around:

```
$ git init --bare repo.git           # HEAD -> ref: refs/heads/master  (NOT main)
$ git -C repo.git for-each-ref refs/heads   # (empty — zero refs)
$ git -C repo.git worktree add -b feat ./feat main
fatal: invalid reference: main       # <-- cmd_new's hardcoded fallback dies here
```

Trace through `cmd_new` (690–733) against a fresh `git init --bare`:
- `is_bare_repo` = `true` → `anchor=$repo_base` ✓ (697).
- `refs/heads/$branch` and `refs/remotes/origin/$branch` both absent → else branch.
- `from` = `symbolic-ref origin/HEAD` (empty, no remote) → `from="${from:-main}"` = `main` (713).
- `have_l=0` (no `refs/heads/main`), `have_o=0` → `baseref="$from"` = `main` (730).
- `git worktree add -b feat "$dir" main` → **`fatal: invalid reference: main`,
  `worktree add failed`, `die`, exit 1.** The whole fleet process dies.

So **creating a repo as a plain `git init --bare` and then doing the first
`fleet new` is guaranteed to crash today.** Two independent problems compound:

**(a) HEAD points at `master` not `main`.** `git init --bare` uses the user's
`init.defaultBranch` (here `master`); fleet hardcodes `main` everywhere
(`from="${from:-main}"` 713, CLAUDE.md). Mismatch.

**(b) Zero commits = zero refs.** Even if HEAD said `main`, `refs/heads/main`
doesn't exist until the first commit, so `worktree add … main` can't resolve.

**Mitigation (BLOCKER): the create-repo step must SEED the bare repo so the first
`fleet new` resolves a real ref.** Verified-working recipe that needs **no temp
checkout and no `cd`**:

```bash
git init --bare --initial-branch=main "$repo".git     # HEAD -> refs/heads/main
# seed an empty root commit directly into the bare repo:
empty=$(git -C "$repo".git hash-object -t tree /dev/null)   # 4b825dc6… (empty tree)
c=$(printf 'init' | git -C "$repo".git commit-tree "$empty")
git -C "$repo".git update-ref refs/heads/main "$c"
```

Reproduced end-to-end: after this, `git -C repo.git worktree add -b feat ./feat
main` **succeeds** ("HEAD is now at … init"). This is the minimum seeding.

**Edge cases the PLAN must handle around the seed:**
- **`--initial-branch` on old git (< 2.28):** flag is rejected. Fallback that works
  on **any** version (verified): after a plain `git init --bare`, run
  `git -C repo.git symbolic-ref HEAD refs/heads/main`. Prefer the portable
  `symbolic-ref` form, or feature-detect `--initial-branch`. (Belt-and-braces:
  `git -c init.defaultBranch=main init --bare` also yields `main` and is verified
  working — but still needs the seed commit.)
- **User's `init.defaultBranch` is something exotic** (e.g. `trunk`): irrelevant if
  you force `main` via `--initial-branch`/`symbolic-ref`. **Force it; don't trust
  the global.** This keeps the seeded branch consistent with fleet's `main`
  assumption everywhere else (713, CLAUDE.md layout section).
- **`cmd_branches` (428) on a freshly-seeded repo:** `symbolic-ref
  refs/remotes/origin/HEAD` fails (no remote — these are local bare repos with no
  origin), so `def` is empty; `for-each-ref refs/remotes/origin` is empty; only
  `for-each-ref refs/heads` returns `main`. **Result: the dashboard branch list
  shows just `main`.** That's correct and non-crashing *given the seed*. Without
  the seed it's an empty list (and then `fleet new` dies as above). The test plan
  must assert `fleet branches <newrepo>` prints `main`.
- **Detached HEAD / `commit-tree` author identity:** `commit-tree` needs
  `user.name`/`user.email`. If global git identity is unset, `commit-tree`
  fails. **Mitigation:** pass identity explicitly via env on the seed commit
  (`GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`/committer = e.g. "fleet"/"fleet@local")
  so it never depends on the user having configured git. Guard the whole seed
  with `|| { warn; return 0; }` — don't `die`.

**Decision the PLAN must make explicit:** "create a repository" = create a **bare
container** (`repo.git/` or `repo/`?). The user said bare with "everything in the
.git folder". MAP-repo-model shows `discover_repos` keys on `[ -e "$d/.git" ]`
OR a subdir with `.git`. A top-level **bare** repo (`repo.git/`) has **no `.git`
entry** — it has `HEAD`/`config`/`objects` at its top. **Re-check discover_repos:
does it actually discover a bare-at-top-level container?** It checks
`[ -e "$d/.git" ]` (false for a bare repo) then scans subdirs for `.git` (none
yet, until a worktree is cut). **So a freshly-created bare repo with no worktrees
is NOT discovered by `discover_repos`** — `resolve_repo` returns 1, and
`fleet new` dies "repo not found". (HIGH.) Mitigation: either (a) the create-repo
step must *also cut a first worktree* so a `.git`-bearing subdir exists for
discovery, or (b) `discover_repos` must be extended to recognise a bare repo at
top level (detect `HEAD`+`objects/`, or `git -C "$d" rev-parse
--is-bare-repository`). **The plan cannot ship without choosing one** — otherwise
the repo it just created is invisible to fleet. (Verify this against
`discover_repos` 102–116 during implementation; this is the single most likely
silent dead-end.)

---

## 3. FOLDER ALREADY EXISTS / HAS CONTENT — enumerate every input

The wizard prompts for a project root path. Each case + guard:

| Input | Risk | Guard the PLAN must add |
|---|---|---|
| **Relative path** (`myproj`) | `cmd_up` does `readlink -f` only on the *direct-path* branch; the wizard writes the yml. A relative path saved into the yml is ambiguous later. | Resolve to absolute (`readlink -f` / `realpath -m`) **before** writing the yml; store with `$HOME→~` like `cmd_save` (3590). |
| **`~/...`** | Tilde is a shell token; if read via `read -e` it is NOT expanded → literal `~`. | Expand `~`/`~user` explicitly (`"${path/#\~/$HOME}"`) before validating/creating. |
| **Spaces in path** | Word-splitting in unquoted `mkdir`/`git`/glob. | Quote every expansion; test with a path containing a space in the test plan. |
| **Does not exist** | Need to create it. | `mkdir -p "$path" || { warn; return 0; }`. Confirm before creating (see §6). |
| **Exists, empty** | Fine. | Proceed. |
| **Exists, non-empty, NOT a fleet project** | User may clobber/confuse an unrelated dir. | Detect non-empty; **warn + require explicit confirm** before adopting it as a project root. |
| **Exists, already a git repo (`.git` at root)** | Adopting a working repo as a *project root* (root-of-repos) is a category error — fleet treats root as a *container of repos*, not a repo. | Detect `.git` at the chosen root; **warn** ("this looks like a git repo, not a project folder; repos live *under* the project root") and require confirm or reject. |
| **Already a registered fleet project** (a yml already points at this root, or `$CONF_DIR/projects/<name>.yml` exists) | Silent overwrite of an existing project definition. | See §4 — name-collision guard. |
| **Unwritable / permission denied** | `mkdir`/`git init` fail mid-wizard, leaving partial state. | Pre-check writability (`mkdir -p` rc, or `[ -w ]`); on failure print the reason and `return 0` (never `die`). |
| **Path is a file, not a dir** | `mkdir -p` fails or `[ -d ]` false. | `[ -e "$path" ] && [ ! -d "$path" ]` → reject. |
| **Trailing slashes / `.`/`..` segments** | Inconsistent yml. | Normalise via `realpath -m`. |

**Severity: HIGH** (the non-empty / already-a-git-repo / already-a-project cases
are the ones that silently corrupt or confuse).

---

## 4. NAME COLLISIONS

- **Project name collides** with an existing `$CONF_DIR/projects/<name>.yml`.
  `cmd_save` (3590) does `printf … > "$yml"` — **unconditional overwrite.** If the
  wizard derives the name from the folder basename (like `cmd_up` 3468:
  `tr -cd 'a-zA-Z0-9_-'`), two different folders named `repos` collide to the same
  yml and **silently clobber** the earlier project's root.
  **Mitigation (HIGH):** before writing, `[ -f "$CONF_DIR/projects/$name.yml" ]`
  → refuse or prompt for a different name / explicit overwrite confirm. Also
  sanitize exactly like `cmd_up`/`cmd_save` (`tr -cd 'a-zA-Z0-9_-'`) and reject if
  the sanitized name is **empty** (e.g. a folder named `…` or all-punctuation) —
  an empty name yields `$CONF_DIR/projects/.yml`, a hidden landmine.
- **Repo name collides** with an existing dir under the root (the user adds a repo
  whose name already exists). `git init --bare existing.git` into an occupied path,
  or worse a name that already resolves via `resolve_repo`'s **substring fuzzy
  match** (118–126) — a new repo `web` shadows/ambiguates an existing `webshop`.
  **Mitigation (MED→HIGH):** before creating, check `[ -e "$root/$name" ]` /
  `[ -e "$root/$name.git" ]` and reject; warn on fuzzy-substring overlap with an
  existing discovered repo so resolution stays unambiguous.

---

## 5. PICKER UX IN FZF — free-text dir entry from inside a terminal picker

The hard constraint: **fzf is a chooser, not a text-input widget.** You cannot type
an arbitrary new directory path "into" the project list. The MAP-picker sentinel-row
approach (`__create_new__`) is sound for *selecting* "create new", but everything
after it must drop out of fzf into a plain prompt.

Pitfalls + the clean flow:

- **Sentinel row + drop to `read -e`.** After fzf returns `__create_new__`,
  **exit fzf** and use `read -e -p "project folder> "` (readline editing + tab path
  completion via `-e`) for the directory. This is the cleanest terminal flow; it
  matches "drop to a `read -e -p`" and gives the user filename completion.
  Do **not** try `fzf --print-query` to capture a typed path — `--print-query`
  returns the *filter string*, has no tab-completion, no `~` expansion, and is
  surprising UX for a path.
- **Esc returns nothing — at every stage.** `cmd_pick_project` already handles
  picker-Esc (`|| return 0`, line 396; `[ -n "$choice" ] || return 0`, 397).
  The wizard's own prompts must each treat **empty/Esc/EOF (Ctrl-D) as cancel →
  `return 0`**, not as "" silently passed downstream (an empty path would become
  `$PWD` via `cmd_up` 3480 — a nasty surprise: "create new" silently adopts the
  cwd). Guard every `read` for empty.
- **Double-prompt / re-entry.** Don't re-enter fzf after creating; hand straight to
  `cmd_up`. If you want "return to picker on cancel", call `cmd_pick_project` again
  explicitly (watch for unbounded recursion — cap it or just `return 0`).
- **Popup vs inline.** The project picker is **inline** (`--height=100%`, run in the
  foreground fleet process at bare `fleet`), NOT a tmux popup — so `read -e`
  afterwards works on the real tty. **But** if "create new" is ever reached from
  the **leader-menu / dashboard** path (which runs pickers inside `tmux
  display-popup`), a bare `read` has no usable tty/readline and the wizard breaks.
  **Mitigation:** scope the wizard to the **bare-`fleet` inline picker only** for
  v1; if dashboard entry is wanted, it must run the wizard in a real pane
  (`tmux new-window`/command-prompt), not inside a popup. The PLAN must state which
  entry points are supported and refuse the others gracefully.
- **Add-repos loop ergonomics.** After the dir, loop: `read -e -p "repo name (blank
  = done)> "`; blank → finish. Echo back each created repo. Keep it obviously
  exitable so the user is never trapped.

**Severity: HIGH** (get the read/Esc/empty handling wrong and "create new" either
hangs, double-prompts, or silently adopts `$PWD`).

---

## 6. INTERACTION WITH FAIL-SILENT — where to be LOUD vs silent

Fleet's convention is fail-*silent* for **integration** calls (tmux/git/nvim/notify
missing → degrade). But this feature does **filesystem-destructive-ish** work
(creating dirs, `git init`, writing config). The two must not be conflated.

**Be SILENT / degrade (keep the convention):**
- Missing `fzf` → already falls back to usage (373). Keep.
- Daemon/tmux/notify down during the eventual `cmd_up` → existing fail-silent paths.
- Optional niceties (colour, running-marker) — never block on them.

**Be LOUD / confirm (must NOT be silent):**
1. **Creating a new directory** that didn't exist → confirm ("create `<path>`?
   [y/N]").
2. **Adopting a non-empty / already-git / already-project dir** (§3) → explicit
   confirm, default **No**.
3. **Overwriting an existing project yml** (§4) → confirm, default No.
4. **`git init --bare` + seed failing** → print the actual error and `return 0`;
   do **not** swallow it silently (the user just asked to create a repo; a silent
   no-op leaves them thinking it worked, then `fleet new` dies later).
5. **Any partial-state rollback.** If the wizard creates the project dir + 2 repos
   then the user Escs, say what was created and where (don't auto-`rm -rf` user
   data — that's worse than leaving it). Idempotency: re-running the wizard on the
   same dir should detect the existing repos and not clobber them.

**The non-negotiable rule:** destructive prompts default to **No** and creation is
**confirmed**; everything else degrades quietly; **nothing in this path calls
`die`/`exit`** (§0).

---

## Cross-cutting test plan the PLAN must include
1. Bare `fleet` → pick "create new" → new empty dir → add 1 repo → boot; assert
   session boots, `fleet repos`/`fleet branches <repo>` show the repo + `main`,
   and a first `fleet new <repo> feat` cuts a worktree **without dying**.
2. Same, but enter an **existing non-empty** dir, an **existing git repo**, and an
   **existing project name** — assert each is caught with a confirm/refusal, no
   clobber.
3. Path with a **space** and a **`~`** prefix.
4. **Esc/Ctrl-D** at the dir prompt, the confirm prompt, and the repo-loop prompt —
   assert clean `return 0`, no `$PWD` adoption, no partial yml.
5. Boot a project with **zero repos** and open the dashboard — assert no crash.
6. (If feasible) simulate **old git** / unset `user.email` for the seed-commit
   fallback paths.

# PLAN — new-project-create (technical)

Verdict: **BUILD**. Minimal, high-reuse, fail-silent. ~2 edited picker lines + 2
new functions (~55 lines). Zero changes to `cmd_new`, `discover_repos`,
`resolve_repo`, `cmd_up`, `cmd_save`.

All anchors in `bin/fleet` unless noted.

---

## 0. Verified ground truth (do not re-derive)

Reproduced live against the real fleet container and a throwaway repo
(scratchpad). The facts the plan rests on:

- **Real bare-container shape** (`/home/red/proj/pc-tune/fleet/`): the bare repo
  lives at `<root>/<repo>/.git/` with `core.bare = true`; worktrees are siblings
  `<root>/<repo>/<branchdir>/` whose `.git` is a `gitdir:` pointer file. The
  user's phrase *"bare repository with everything in the .git folder"* maps
  **exactly** to this. → create bare repos at `<root>/<repo>/.git`, NOT
  `<root>/<repo>.git`.
- `git -C "<root>/<repo>" rev-parse --is-bare-repository` returns **`true`** for
  this shape, and `[ -e "<root>/<repo>/.git" ]` is **true** — so
  `discover_repos` (102) finds it via its **first** branch (`[ -e "$d/.git" ]`),
  and `cmd_new`'s layout detector (`bin/fleet:691`) takes the
  `is_bare_repo == true` → `anchor=$repo_base` path (697-698). **No change to
  either function is required.**
- A virgin `git init --bare` has HEAD→`master` and **zero refs**, so
  `cmd_new`'s first-worktree path (`from="${from:-main}"`, 713 →
  `worktree add -b "$branch" "$dir" "$baseref"`) dies `invalid reference: main`.
  **The create flow must seed a `main` ref before the project is usable.**
- Project yml is just `name:` + `root:` (`cmd_save`, 3590), standalone-writable;
  `cmd_up` keys off the **filename**, reads `root:` (3475), re-expands `~`. No
  tmux session needed to create a valid project.

### Validated command sequence (ran end-to-end, all steps succeeded)

```bash
git init --bare "$ROOT/$repo/.git"                       # 1. bare container
GD="$ROOT/$repo/.git"
# 2. seed an empty root commit on main, deterministically, no working tree:
SHA=$(GIT_AUTHOR_NAME=fleet GIT_AUTHOR_EMAIL=fleet@local \
      GIT_COMMITTER_NAME=fleet GIT_COMMITTER_EMAIL=fleet@local \
      git -C "$GD" commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m init)
git -C "$GD" update-ref refs/heads/main "$SHA"
git -C "$GD" symbolic-ref HEAD refs/heads/main
# 3. later, `fleet new <repo> <branch>` cuts the first worktree unchanged:
git -C "$ROOT/$repo" worktree add -b feat/x "$ROOT/$repo/feat_x" refs/heads/main  # OK
```

`4b825dc642cb6eb9a060e54bf8d69288fbee4904` is git's constant empty-tree (sha1).
Format-agnostic alternative if sha256 repos matter:
`ET=$(git -C "$GD" hash-object -t tree --stdin </dev/null)` then commit-tree
`$ET`. Explicit `GIT_*_NAME/EMAIL` env is **required** — `commit-tree` fails if
the user has no global git identity; we must not depend on their config.

---

## 1. Picker change — `cmd_pick_project` (371-402)

Two edits. Inject one synthetic row and add one routing branch.

### 1a. Always offer "create new", even with zero projects (377-383)

The current zero-projects guard early-returns **before** fzf — but a fresh
install (zero projects) is the *primary* moment a user wants "create new".
Restructure so the synthetic row is always present:

- Drop the early `return 0` in the `${#ymls[@]} -eq 0` branch (377-383). Keep
  the "no saved projects yet" line as a one-line `echo` hint, but fall through
  to build rows.
- Guard the glob so an empty `projects/` dir doesn't iterate a literal
  `*.yml` (the existing `[ -f "$f" ] || continue` at 386 already handles this).

### 1b. Inject the synthetic row (after the `for` loop, ~393, before fzf)

```bash
# synthetic action row — sentinel in field 1, styled like the running marker
rows+=$(printf '%s\t\033[33m＋\033[0m %-18s %s' '__fleet_new__' 'create new project' '')$'\n'
```

Field format matches the existing rows exactly: `name<TAB>display` where fzf
shows only field 2 (`--with-nth=2`, 395) and selection is recovered with
`cut -f1` (398). Yellow `\033[33m` distinguishes the action from
running(green)/idle(blank). Sentinel `__fleet_new__` is matched by literal
string, so even the (pathological) case of a project literally named
`__fleet_new__` only risks shadowing — acceptable; can be hardened by also
checking the row has empty root.

Place it **last** so real projects stay at the top of the list.

### 1c. Route the selection (current line 398)

Replace:

```bash
cmd_up "$(printf '%s' "$choice" | cut -f1)"
```

with:

```bash
local pick; pick=$(printf '%s' "$choice" | cut -f1)
if [ "$pick" = '__fleet_new__' ]; then cmd_new_project; else cmd_up "$pick"; fi
```

Esc/empty already handled by `|| return 0` (396) and `[ -n "$choice" ]` (397).

---

## 2. New function — `cmd_new_project` (insert after `cmd_save`, ~3601)

Runs in the **foreground** bare-`fleet` process (a real terminal, stdin/stdout
TTY — guaranteed by the dispatch gate at 4138 `[ -t 0 ] && [ -t 1 ]`), so
`read -e` (readline + tab completion) works. **Never `die`** — `die` is
`exit 1` (21) and would hard-crash fleet, violating the fail-silent rule. Every
rejection is `echo` + `return 0`; only the final `cmd_up` hands off.

```bash
cmd_new_project() { # interactive: create a project dir, seed bare repos, boot it
  local root name
  # --- project directory (free-text, readline + tab-complete) ---
  read -e -r -p "new project directory: " root || return 0   # Ctrl-D = cancel
  [ -n "$root" ] || { echo "cancelled."; return 0; }
  root="${root/#\~/$HOME}"
  root=$(readlink -m -- "$root") || { echo "bad path."; return 0; }

  name=$(basename "$root" | tr -cd 'a-zA-Z0-9_-')
  [ -n "$name" ] || { echo "could not derive a project name from $root"; return 0; }
  if [ -f "$CONF_DIR/projects/$name.yml" ]; then
    echo "project '$name' already exists ($CONF_DIR/projects/$name.yml)"; return 0
  fi

  # --- create / adopt the root dir (LOUD on adopting non-empty) ---
  if [ -e "$root" ]; then
    [ -d "$root" ] || { echo "$root exists and is not a directory."; return 0; }
    if [ -n "$(ls -A "$root" 2>/dev/null)" ]; then
      read -r -p "$root is not empty — use it anyway? [y/N] " a || return 0
      case "$a" in y|Y) ;; *) echo "cancelled."; return 0 ;; esac
    fi
  else
    mkdir -p "$root" 2>/dev/null || { echo "could not create $root"; return 0; }
  fi

  # --- register the project yml (inline; cmd_save is session-coupled) ---
  mkdir -p "$CONF_DIR/projects" 2>/dev/null
  local rootc="${root/#$HOME/\~}"
  printf 'name: %s\nroot: %s\n' "$name" "$rootc" > "$CONF_DIR/projects/$name.yml" \
    || { echo "could not write project yml."; return 0; }
  echo "created project '$name' -> $root"

  # --- add-repository loop ---
  local rname
  while :; do
    read -e -r -p "add repository (name, empty to finish): " rname || break
    [ -n "$rname" ] || break
    rname=$(printf '%s' "$rname" | tr -cd 'a-zA-Z0-9_.-')
    [ -n "$rname" ] || { echo "  invalid name, skipped."; continue; }
    if [ -e "$root/$rname" ]; then echo "  '$rname' already exists, skipped."; continue; fi
    new_bare_repo "$root/$rname" || echo "  failed to create '$rname'."
  done

  # --- boot the project (reuse the standalone boot path) ---
  cmd_up "$name"
}
```

## 3. New helper — `new_bare_repo` (insert near `discover_repos`, ~117)

Isolated so it is testable and reused if the dashboard ever grows an "add repo"
button. Creates the bare container at `<repo>/.git` and seeds `main` so
`cmd_new` can cut the first worktree immediately.

```bash
new_bare_repo() { # new_bare_repo <repo-dir> — bare container at <dir>/.git, seeded main
  local rdir="$1" gd="$1/.git" sha
  git init --bare --quiet "$gd" 2>/dev/null || return 1
  sha=$(GIT_AUTHOR_NAME=fleet GIT_AUTHOR_EMAIL=fleet@local \
        GIT_COMMITTER_NAME=fleet GIT_COMMITTER_EMAIL=fleet@local \
        git -C "$gd" commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m init 2>/dev/null) \
    || return 1
  git -C "$gd" update-ref refs/heads/main "$sha" 2>/dev/null || return 1
  git -C "$gd" symbolic-ref HEAD refs/heads/main 2>/dev/null || return 1
  echo "  created bare repo '$(basename "$rdir")' (main seeded)"
}
```

Note `git init --bare <dir>/.git` makes `.git` the gitdir (verified: the
resulting `<repo>` reads `is-bare-repository = true` and is discovered).

---

## 4. Dispatch — no change needed

No new subcommand. The flow is reached entirely through the existing bare-`fleet`
→ `cmd_pick_project` path (4138). Optionally expose `fleet new-project` as a
thin alias for scripting, but it is **not required** by the ask. If added: one
`case` arm `new-project) shift; cmd_new_project "$@" ;;` near 4120.

---

## 5. Files / functions touched (summary)

| Change | Location | Kind |
|---|---|---|
| Always-offer + inject synthetic row | `cmd_pick_project` 377-393 | edit ~4 lines |
| Route sentinel → `cmd_new_project` | `cmd_pick_project` 398 | edit 1→3 lines |
| `cmd_new_project` | after `cmd_save` ~3601 | new ~45 lines |
| `new_bare_repo` | after `discover_repos` ~117 | new ~12 lines |
| (optional) `new-project` alias | dispatch ~4120 | new 1 line |

Untouched and relied-upon as-is: `discover_repos` (102), `resolve_repo` (118),
`cmd_new` layout/worktree logic (691-733), `cmd_up` (3455), `cmd_save` (3570).

---

## 6. Edge cases the implementer MUST handle (from CON; all have mitigations above)

1. **`die` must never escape `cmd_new_project`/`new_bare_repo`** — both crash
   fleet. Done: every failure is `echo`+`return`.
2. **Empty bare repo breaks first `fleet new`** — solved by seeding `main` in
   `new_bare_repo`.
3. **Top-level bare (`repo.git/`, no `.git`) is NOT discovered** — avoided by
   creating at `<repo>/.git`, the discovered shape.
4. **fzf can't free-text a path** — solved by `read -e` AFTER the picker, in the
   inline TTY path only (not the dashboard popup; out of scope).
5. **Name / dir collisions** — guarded: existing yml rejected, existing repo dir
   skipped.
6. **Non-empty / already-git / unwritable root** — LOUD confirm on non-empty;
   `mkdir`/`init` failures reported and aborted.
7. **Empty-tree hash & git identity** — constant + explicit `GIT_*` env;
   sha256-repo alternative noted.
8. **Zero-repo project boots into an empty session** (no crash — `discover_repos`
   yields 0, fail-silent holds) — acceptable; the add-repo loop steers the user
   to add ≥1 before boot.

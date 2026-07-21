# PRO adviser — new-project-create: the cleanest minimal design

**Thesis:** This feature needs **one synthetic picker row + one sentinel branch +
one new function (`cmd_new_project`)**. Everything else is reuse: the yml format is
two lines, `cmd_up` already boots standalone, and `cmd_new` already cuts worktrees
against a bare container. The ONLY genuinely new mechanic is **creating** a
bare-repo container that `cmd_new` can immediately cut from — and I verified the
exact on-disk shape + git commands below against the live fleet repos.

---

## 0. Verified facts (ran these, don't re-litigate)

1. **A fleet bare-repo container is `<root>/<repo>/.git/` — a bare repo living in a
   `.git` subdir**, with worktrees as siblings. NOT `<repo>.git/`. Confirmed on the
   live `fleet/` container: `fleet/.git/config` has `core.bare=true`,
   `git -C fleet rev-parse --is-bare-repository` → `true`, and `fleet/main/` is a
   worktree sibling. Reproduced from scratch: `git init --bare <root>/<repo>/.git`
   yields exactly that — `[ -e "$repo/.git" ]` true AND `is-bare-repository` true.
   This is the shape that lands cmd_new on the `anchor="$repo_base"` branch
   (bin/fleet:697-698) AND that `discover_repos` matches on its **first** branch
   (bin/fleet:104, `[ -e "$d/.git" ]`).

   > **Why this matters / a trap CON will raise:** if you instead do
   > `git init --bare <root>/<repo>.git` (the "myrepo.git" pattern the repo-model
   > MAP §6/§8 suggests), the top-level `.git` test is FALSE and the container is
   > **NOT discovered at all** until a worktree exists inside it. The
   > `<root>/<repo>/.git` form is the only one that is both discoverable while empty
   > and matches the existing layout. **Use `<root>/<repo>/.git`.**

2. **Fresh `git init --bare` HEADs to `master` and has zero refs**, so
   `git worktree add … main` fails: `fatal: invalid reference: main`. Confirmed.

3. **Seeding fixes it deterministically** with porcelain-free plumbing (no temp
   clone, no working tree, no config dependency on init.defaultBranch):

   ```bash
   git -C "$gitdir" update-ref refs/heads/main \
     "$(git -C "$gitdir" commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m 'init')"
   git -C "$gitdir" symbolic-ref HEAD refs/heads/main
   ```

   `4b825dc6…4904` is git's well-known **empty-tree hash** (stable across all git
   versions). After this, `refs/heads/main` exists, HEAD→main, and I verified
   `git -C <container> worktree add -b feat <dir> main` succeeds — which is exactly
   the path cmd_new takes (branch not found → `worktree add -b "$branch" "$dir"
   "$baseref"` with `baseref` resolving to `main`, bin/fleet:730-731).

---

## 1. The picker change (cmd_pick_project, bin/fleet:371-399)

**Inject the synthetic row after the yml loop closes (after line 393):**

```bash
  done
  # synthetic "create new project" entry — sentinel in field 1, yellow ＋ in field 2.
  rows+=$(printf '%s\t\033[33m＋\033[0m %-18s %s' '__new__' 'create new project' '')$'\n'
```

**Route the sentinel (replace lines 397-398):**

```bash
  [ -n "$choice" ] || return 0
  local pick; pick="$(printf '%s' "$choice" | cut -f1)"
  [ "$pick" = "__new__" ] && { cmd_new_project; return 0; }
  cmd_up "$pick"
```

Notes that keep it minimal & correct:
- Sentinel `__new__` can't collide with a real project: `cmd_save` sanitizes names
  to `[a-zA-Z0-9_-]` (bin/fleet:3582) so no yml is ever literally `__new__` *and* it
  doesn't matter even if one were, because we route before `cmd_up`.
- **Drop the early-return on zero projects?** No. Keep it simpler: leave the
  "no saved projects" guard (lines 377-382) as-is for now — a first-run user with
  zero projects still types `fleet up <path>` or `fleet save`. (If we want create-
  on-empty too, the *minimal* change is to let the loop produce an empty `rows` and
  always append the synthetic row, then delete the early `return 0`. That's a
  1-line win but slightly widens scope; I'd ship it in the same PR since it's the
  natural "I have no projects, let me make one" entry — **recommend including it**:
  replace the zero-project early-return body with nothing and let the synthetic row
  carry the empty picker.)

---

## 2. cmd_new_project — the one new function

Insert after `cmd_up` ends (~bin/fleet:3569, before `cmd_save`). Plain `read`
prompts — no fzf directory picker (over-engineering; the user *types a new path*,
which fzf-over-existing-dirs can't express). Fail-silent throughout per CLAUDE.md.

```bash
cmd_new_project() { # interactive: create a new project dir, seed bare repos, boot it
  command -v git >/dev/null || die "git required"
  local root name
  printf 'new project directory (will be created): ' >&2
  read -r root || return 0
  [ -n "$root" ] || { echo "cancelled" >&2; return 0; }
  root="${root/#\~/$HOME}"
  root=$(readlink -m "$root")                 # absolute, no need to exist yet
  mkdir -p "$root" 2>/dev/null || die "could not create $root"

  # project name: default basename, sanitized like cmd_save.
  printf 'project name [%s]: ' "$(basename "$root")" >&2
  read -r name || return 0
  [ -n "$name" ] || name="$(basename "$root")"
  name=$(printf '%s' "$name" | tr -cd 'a-zA-Z0-9_-')
  [ -n "$name" ] || die "invalid project name"

  # write the project yml standalone (same 2-field format cmd_save emits).
  mkdir -p "$CONF_DIR/projects" 2>/dev/null || die "could not create $CONF_DIR/projects"
  local yml="$CONF_DIR/projects/$name.yml" rootc="${root/#$HOME/\~}"
  printf 'name: %s\nroot: %s\n' "$name" "$rootc" > "$yml" || die "could not write $yml"
  echo "created project '$name' -> $rootc" >&2

  # add-repository loop: each repo is a fresh, seeded bare container.
  local repo
  while :; do
    printf 'add repository (bare; blank to finish): ' >&2
    read -r repo || break
    [ -n "$repo" ] || break
    repo=$(printf '%s' "$repo" | tr -cd 'a-zA-Z0-9_.-')
    [ -n "$repo" ] || continue
    new_bare_repo "$root/$repo" || echo "skip: could not create repo '$repo'" >&2
  done

  cmd_up "$name"     # boot the session via the existing standalone path
}
```

And the **one tiny helper** that encapsulates the verified git incantation (keep it
separate so it's testable and reusable from a future `fleet repo add` CLI verb):

```bash
new_bare_repo() { # new_bare_repo <container-dir> — create a fleet bare container seeded on main
  local container="$1" gitdir="$1/.git"
  [ -e "$gitdir" ] && { echo "exists: $container" >&2; return 0; }   # idempotent
  git init --bare -q "$gitdir" 2>/dev/null || return 1
  # seed an empty root commit on refs/heads/main + point HEAD at it, so cmd_new can
  # immediately cut a worktree (a virgin bare repo HEADs to master with zero refs).
  local empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904
  local c; c=$(git -C "$gitdir" commit-tree "$empty_tree" -m init 2>/dev/null) || return 1
  git -C "$gitdir" update-ref refs/heads/main "$c"  2>/dev/null || return 1
  git -C "$gitdir" symbolic-ref HEAD refs/heads/main 2>/dev/null || return 1
  echo "created bare repo '$(basename "$container")' (main)" >&2
  return 0
}
```

---

## 3. Why this lands correctly on disk (the discover_repos contract)

After `new_bare_repo "$root/myrepo"`:

```
$root/myrepo/.git/           <- bare repo (core.bare=true), HEAD->refs/heads/main
$root/myrepo/.git/refs/heads/main   <- empty root commit (seeded)
```

- `discover_repos "$root"` (bin/fleet:104) hits `[ -e "$d/.git" ]` → emits
  `myrepo<TAB>$root/myrepo`. **Discovered immediately, while empty.** ✔
- `cmd_new myrepo <branch>`: `is_bare_repo` = `true` (bin/fleet:691) → not the
  plain-repo branch → `anchor="$repo_base"` (bin/fleet:698) → branch absent →
  `from` falls to `main` (bin/fleet:712-713) → `baseref` resolves to local
  `refs/heads/main` (bin/fleet:728) → `git worktree add -b <branch> $dir main`
  **succeeds** (verified). ✔
- Worktree lands at `$root/myrepo/<branchdir>/` exactly like every existing fleet
  container — same shape as live `fleet/main/`. ✔

This matches the real on-disk layout **byte-for-byte in structure** (init --bare
into `.git`), so there is zero special-casing anywhere downstream.

---

## 4. Reuse decisions (the questions asked)

- **Reuse cmd_save's yml writer vs inline?** Inline the one `printf`. cmd_save is
  session-coupled: it reads `@fleet_root` from the *current* tmux session and dies
  if it can't (bin/fleet:3572-3579). We have no session yet — we're *creating* one.
  Refactoring cmd_save to take an explicit (name, root) is a bigger blast radius
  than copying one 30-char `printf` line that the config-MAP already documents as
  "the actual write." **Inline it.** (If a reviewer insists on DRY, extract
  `write_project_yml <name> <root>` and call it from both — a 3-line helper — but
  that's optional polish, not required for minimality.)
- **Reuse cmd_up to boot at the end?** **Yes, unconditionally.** `cmd_up <name>`
  is already the standalone boot path the picker uses; config-MAP §7/§9 confirms it
  needs no pre-existing session. End cmd_new_project with `cmd_up "$name"` and the
  new project boots identically to picking any saved one. No new boot logic.

---

## 5. Why this is the minimal-correct design (vs. plausible alternatives)

- **vs. a fzf directory picker for the path:** rejected. The user is entering a
  *non-existent* directory; fzf picks from what exists. `read -r` + `mkdir -p` is
  both simpler and the only thing that can express "make a new folder here."
- **vs. temp-clone-and-push to seed the default branch** (repo-model MAP §3 step 3):
  rejected — that needs a working tree, a scratch dir, network-free push config, and
  cleanup. `commit-tree` on the empty-tree hash + `update-ref` + `symbolic-ref` is
  three plumbing calls, no working tree, no temp dir, version-stable.
- **vs. a brand-new dashboard form / CLI surface:** out of scope. The ask is "the
  option *there*" — in the picker. One row, one function.
- **Fail-silent compliance:** every git/mkdir call is guarded (`2>/dev/null`,
  `|| return 1`, `|| die` only on user-fatal path errors), matching CLAUDE.md's
  "guard external calls and fall back" rule. `read` returns on EOF/^D → graceful.

## 6. Anchors touched

| Change | File:line |
|---|---|
| synthetic row | bin/fleet:393 (after the `done`) |
| sentinel route | bin/fleet:397-398 |
| `cmd_new_project` + `new_bare_repo` | new, ~bin/fleet:3569 (before cmd_save) |
| (no change needed) discover/cmd_new just work | bin/fleet:104, 691-731 |

Total: ~2 edited lines in the picker + ~2 new functions (~45 lines). No changes to
cmd_new, discover_repos, cmd_up, or cmd_save. That is the whole feature.

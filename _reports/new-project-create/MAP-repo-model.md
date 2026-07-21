# Fleet Repository Model Mapping

**Goal:** Document how fleet discovers, resolves, and uses repositories across three layouts to enable creating bare repos in brand-new empty projects.

---

## 1. Repository Discovery: `discover_repos()` (bin/fleet:102–116)

Fleet auto-discovers repositories under a project root by scanning immediate subdirectories. A directory counts as a repo/container if:

1. **It contains `.git` directly** (a git object/file), OR
2. **Any of its subdirectories contains `.git`** (it's a worktree or bare-repo container)

```bash
discover_repos() { # discover_repos <root> → "name<TAB>path" lines
  local root="$1" d sub
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    if [ -e "$d/.git" ]; then
      printf '%s\t%s\n' "$(basename "$d")" "$d"
    else
      # worktree container: a dir whose subdirs are git checkouts
      for sub in "$d"/*/; do
        [ -e "${sub%/}/.git" ] && { printf '%s\t%s\n' "$(basename "$d")" "$d"; break; }
      done
    fi
  done
}
```

**File/Line Reference:** `/home/red/proj/pc-tune/fleet/main/bin/fleet:102–116`

**Key Points:**
- Top-level directories **only** (no recursive descent beyond one level).
- `.git` is checked as **a file or directory exists** (`[ -e "$d/.git" ]`), not whether it's a file vs directory.
- Both plain repos and containers are discovered in a single pass.
- No attempt to initialize or create; purely **discovery** of existing layouts.

---

## 2. Repository Resolution: `resolve_repo()` (bin/fleet:118–126)

Takes a repo name/alias and returns its path. Uses fuzzy matching (substring) with exact-match preference.

```bash
resolve_repo() { # resolve_repo <root> <name> → path
  local root="$1" want="$2" line name path match=""
  while IFS=$'\t' read -r name path; do
    [ "${name,,}" = "${want,,}" ] && { echo "$path"; return 0; }
    case "${name,,}" in *"${want,,}"*) match="$path" ;; esac
  done < <(discover_repos "$root")
  [ -n "$match" ] && { echo "$match"; return 0; }
  return 1
}
```

**File/Line Reference:** `/home/red/proj/pc-tune/fleet/main/bin/fleet:118–126`

---

## 3. The Three Repository Layouts

Fleet recognizes and operates on three distinct on-disk layouts. The distinction is made in `cmd_new` (bin/fleet:644–887) based on the structure at `repo_base`.

### Layout 1: Plain Working Repository

**Structure:**
```
<project-root>/<repo-name>/
├── .git/
│   ├── config (with bare=false or absent)
│   ├── HEAD
│   ├── refs/
│   ├── objects/
│   └── ...
├── <worktree files: src/, bin/, etc.>
└── ...
```

**Detection Code (bin/fleet:691–693):**
```bash
local is_bare_repo; is_bare_repo=$(git -C "$repo_base" rev-parse --is-bare-repository 2>/dev/null)
if [ -e "$repo_base/.git" ] && [ "$is_bare_repo" != "true" ]; then
  dir="$repo_base"   # plain working repo, no worktree layout
```

**Characteristics:**
- Has a `.git/` directory at the repo root.
- `git rev-parse --is-bare-repository` returns `"false"` or empty (not `"true"`).
- **No worktrees**: used in place as-is; `cmd_new` doesn't create new worktrees.
- Suitable for small projects with a single checkout per repo.

---

### Layout 2: Bare-Repo Container

**Structure:**
```
<project-root>/<container-name>/
├── HEAD (ref: refs/heads/main)
├── config (with [core] bare=true)
├── refs/
│   ├── heads/
│   └── tags/
├── objects/
│   ├── info/
│   └── pack/
├── worktrees/
│   └── ... (created by `git worktree add`)
└── hooks/, info/, description
```

**On-disk signature of a bare repo** (created by `git init --bare` or `git clone --bare`):
- **`config` file with `bare = true`** in the `[core]` section.
- **`HEAD` file** is a symbolic ref or direct object ref (e.g., `ref: refs/heads/main`).
- **`refs/`, `objects/`, `hooks/` directories** at the top level.
- **`worktrees/` subdirectory** can appear later when worktrees are added.
- **No working tree files** (no `.git/`; git stores everything at the top level).

**Detection Code (bin/fleet:697–698):**
```bash
if [ "$is_bare_repo" = "true" ]; then
  anchor="$repo_base"   # container holds a bare repo (.git) + worktree subdirs
```

**How fleet uses it:**
- When `fleet new <repo> <branch>` is called:
  - Fleet runs `git worktree add <worktree-path> <branch>` with `anchor` = `$repo_base`.
  - Worktrees are created as subdirectories of the container: `<container-name>/<branch-with-underscores>/`.
  - Each worktree has its own `.git` file (not a directory), containing a path to the bare repo's `worktrees/<id>/` directory.

**Example workflow:**
```bash
# Before any worktree is created:
repo/
  HEAD -> ref: refs/heads/main
  config (bare=true)
  refs/, objects/, hooks/, ...

# After `fleet new myrepo feat`:
repo/
  HEAD, config, refs/, objects/, ...
  worktrees/
    feat-<id>/
  feat/  # the worktree directory created by git
    .git (file, not dir: "gitdir: ../worktrees/feat-<id>")
    <checked-out files>
```

---

### Layout 3: Worktree Container

**Structure:**
```
<project-root>/<container-name>/
├── <first-worktree-name>/
│   ├── .git/
│   │   ├── config (not bare)
│   │   ├── HEAD
│   │   ├── commondir (pointer to shared .git)
│   │   └── ...
│   ├── <worktree files>
│   └── ...
├── <second-worktree-name>/
│   ├── .git/
│   └── ...
└── ...
```

**Detection Code (bin/fleet:700–704):**
```bash
else
  local sub
  for sub in "$repo_base"/*/; do
    [ -e "${sub%/}/.git" ] && { anchor="${sub%/}"; break; }
  done
```

**Characteristics:**
- **No `.git` at the container root**.
- **One or more subdirectories** each containing a `.git/`.
- These are typically created by older workflows or manual git worktree setup where the "anchor" worktree is a sibling.
- Fleet finds the **first** subdirectory with `.git` and uses it as the anchor for `git worktree add`.
- All worktrees share a common `.git` directory (git's "common-dir" feature).

---

## 4. Worktree Creation: `cmd_new` Worktree/Repo Layout Section (bin/fleet:644–887)

When `fleet new <repo> <branch>` is invoked and the repo layout is a bare or worktree container:

**Key steps:**

1. **Resolve repo** to `repo_base` (bin/fleet:689).
2. **Determine layout** via `git rev-parse --is-bare-repository` (bin/fleet:691).
3. **Pick the anchor**:
   - **Bare container**: anchor = `repo_base` itself (the bare repo).
   - **Worktree container**: anchor = the first subdirectory with `.git` (bin/fleet:701–704).
   - **Plain repo**: no anchor needed; work in place.
4. **Create worktree** if not already present (bin/fleet:707–733):
   - `git -C "$anchor" fetch --quiet` (refresh remotes).
   - If the branch exists locally or remotely, use it as-is.
   - Otherwise, create it from the `--base` branch (or the default remote branch, or `main`).
   - **Code (bin/fleet:708–733):**
     ```bash
     if [ ! -d "$dir" ]; then
       ...
       git -C "$anchor" fetch --quiet 2>/dev/null
       if git -C "$anchor" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
          || git -C "$anchor" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
         git -C "$anchor" worktree add "$dir" "$branch" || die "worktree add failed"
       else
         local from="${base:-$(git -C "$anchor" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||')}"
         from="${from:-main}"
         # ... logic to pick local vs origin base ...
         git -C "$anchor" worktree add -b "$branch" "$dir" "$baseref" || die "worktree add failed"
       fi
     fi
     ```

**Directory naming convention:**
- Branches with `/` are converted to `_` in the worktree directory name: `feature/new-ui` → `feature_new-ui/`.
- **Code (bin/fleet:690):** `local branchdir="${branch//\//_}"`

**CLAUDE.md Worktree/Repo Layout Quote (CLAUDE.md:95–102):**

> A "project" is any root folder of repos; repos are auto-discovered. `fleet new`
> resolves the repo then picks a layout: a **plain working repo** is used in place
> (no worktree); a **bare-repo container** or a **worktree container** gets a new
> worktree at `<repo>/<branch-with-slashes-as-underscores>`, anchored off the
> container's bare repo or first worktree, cut from `--base` (or the remote default
> branch). Branches with `/` become `_` in directory and window names.

---

## 5. Supporting Functions

### `repo_anchor()` (bin/fleet:410–417)

Returns a path where git commands can run (a working tree, not a bare repo itself).

```bash
repo_anchor() { # repo_base -> a dir git can run in (the repo, bare container, or a worktree)
  local repo_base="$1" is_bare sub
  is_bare=$(git -C "$repo_base" rev-parse --is-bare-repository 2>/dev/null)
  if [ -e "$repo_base/.git" ] && [ "$is_bare" != "true" ]; then echo "$repo_base"; return 0; fi
  [ "$is_bare" = "true" ] && { echo "$repo_base"; return 0; }
  for sub in "$repo_base"/*/; do [ -e "${sub%/}/.git" ] && { echo "${sub%/}"; return 0; }; done
  return 1
}
```

**File/Line Reference:** `/home/red/proj/pc-tune/fleet/main/bin/fleet:410–417`

**Note:** Despite bare repos having no working tree, `git -C <bare-repo>` works for read-only operations (rev-parse, for-each-ref, etc.) and worktree creation.

### `cmd_worktrees()` (bin/fleet:419–426)

Lists existing worktree branches for a repo:

```bash
cmd_worktrees() {
  local repo="${1:-}"; [ -n "$repo" ] || die "usage: fleet worktrees <repo>"
  local root; root=$(fleet_root) || die "not inside tmux"
  local repo_base; repo_base=$(resolve_repo "$root" "$repo") || die "repo '$repo' not found under $root"
  local anchor; anchor=$(repo_anchor "$repo_base") || return 0
  git -C "$anchor" worktree list --porcelain 2>/dev/null \
    | awk '/^branch /{sub("refs/heads/","",$2); print $2}' | awk 'NF && !seen[$0]++'
}
```

**File/Line Reference:** `/home/red/proj/pc-tune/fleet/main/bin/fleet:419–426`

### `cmd_branches()` (bin/fleet:428–439)

Lists available branches for a repo, with the default branch first:

```bash
cmd_branches() {
  local repo="${1:-}"; [ -n "$repo" ] || die "usage: fleet branches <repo>"
  local root; root=$(fleet_root) || die "not inside tmux"
  local repo_base; repo_base=$(resolve_repo "$root" "$repo") || die "repo '$repo' not found under $root"
  local anchor; anchor=$(repo_anchor "$repo_base") || return 0
  local def; def=$(git -C "$anchor" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  {
    [ -n "$def" ] && echo "$def"
    git -C "$anchor" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null | sed 's|^origin/||'
    git -C "$anchor" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null
  } | grep -vxE 'HEAD|origin' | awk 'NF && !seen[$0]++'
}
```

**File/Line Reference:** `/home/red/proj/pc-tune/fleet/main/bin/fleet:428–439`

---

## 6. CRITICAL: Fleet Does NOT Create Bare Repositories

**Finding:** Fleet **never** runs `git init --bare` or `git clone --bare`. It only **consumes** pre-existing bare-repo containers.

**Search results:**
- Zero matches for `init --bare` in bin/fleet (grep: `/home/red/proj/pc-tune/fleet/main/bin/fleet`).
- Zero matches for `clone --bare`.
- Fleet assumes bare repos are already present (created externally or by a setup script).

**Implication for "new-project-create" feature:**
- When seeding a new empty project with repos, you (or an external script) **must pre-create bare repos** using:
  ```bash
  git init --bare <repo-name>.git
  ```
- Then fleet will discover and use them.

---

## 7. Empty Repository / No Commits Gotcha

**Critical issue:** A freshly created bare repo has **no refs/heads** and **no default branch** until the first commit.

**Example:**
```bash
$ git init --bare myrepo.git
$ cd myrepo.git
$ git symbolic-ref --short refs/remotes/origin/HEAD
# (no output; command fails because origin doesn't exist in a bare repo)
$ git for-each-ref refs/heads/
# (no output; no branches created yet)
```

**Impact on `cmd_branches()` and `cmd_new()`:**
- `cmd_branches` will return an empty list (the default branch lookup fails).
- In `cmd_new`, the fallback to hardcoded `main` (bin/fleet:713) will kick in:
  ```bash
  from="${from:-main}"
  ```
- **But if the repo has zero commits**, `main` doesn't exist on disk, so the following attempt will fail:
  ```bash
  git -C "$anchor" worktree add -b "$branch" "$dir" "$baseref"
  # fails: bad revision "main"
  ```

**Workaround for new bare repos with no commits:**
1. Initialize the bare repo with at least one commit (e.g., an empty root commit or a README) from **any** worktree.
2. Or explicitly specify `--base` when spawning the first worktree:
   ```bash
   fleet new <repo> <branch> --base <existing-branch>
   ```
3. The dashboard form will show an empty branch list until the first commit exists.

---

## 8. On-Disk Layout of a Bare Repository (Reference)

When you run `git init --bare myrepo.git`, the resulting directory contains:

```
myrepo.git/
├── HEAD                    # Symbolic ref: "ref: refs/heads/master" (or "main")
├── config                  # [core] bare = true
├── description             # (empty or a description for gitweb)
├── info/
│   └── exclude             # Global gitignore patterns (like .gitignore)
├── objects/                # Compressed object store
│   ├── info/
│   └── pack/
├── refs/                   # Branch and tag refs
│   ├── heads/              # (empty until first commit)
│   └── tags/
├── hooks/                  # Server-side hook scripts
│   ├── pre-receive.sample
│   ├── post-update.sample
│   └── ...
└── worktrees/              # (created dynamically by git worktree add)
    └── <id>/               # One per worktree, keyed by UUID
```

**Key properties:**
- **`config`:** Contains `[core] bare = true` (detected by `git rev-parse --is-bare-repository`).
- **`HEAD`:** Points to the default branch (e.g., `ref: refs/heads/main`).
- **`refs/heads/`:** Empty until the first commit; newly-created branches appear here.
- **`worktrees/`:** Managed by git; each worktree directory contains a back-reference to the bare repo.

---

## Summary: How to Create Repos in New Projects

To bootstrap a new empty project for fleet:

1. **Create the project directory:**
   ```bash
   mkdir -p /path/to/project
   ```

2. **Create bare-repo containers for each repo:**
   ```bash
   git init --bare /path/to/project/repo1.git
   git init --bare /path/to/project/repo2.git
   ```

3. **Initialize each bare repo with at least one commit** (to establish a default branch):
   ```bash
   # From a temporary worktree:
   git clone /path/to/project/repo1.git /tmp/repo1-init
   cd /tmp/repo1-init
   echo "# Repo 1" > README.md
   git add README.md
   git commit -m "Initial commit"
   git push
   cd .. && rm -rf /tmp/repo1-init
   ```

4. **Run `fleet up /path/to/project`:**
   - `discover_repos` will find `repo1.git` and `repo2.git` (both contain `.git` at the top level).
   - `cmd_new repo1 <branch>` will work, creating worktrees under each bare container.

---

## File/Line Reference Summary

| Function/Section | File:Line | Purpose |
|---|---|---|
| `discover_repos()` | bin/fleet:102–116 | Auto-discover repos under a project root |
| `resolve_repo()` | bin/fleet:118–126 | Resolve a repo name to a path |
| `repo_anchor()` | bin/fleet:410–417 | Find a directory where git commands can run |
| `cmd_worktrees()` | bin/fleet:419–426 | List existing worktrees of a repo |
| `cmd_branches()` | bin/fleet:428–439 | List available branches for a repo |
| `cmd_new()` (main) | bin/fleet:644–887 | Spawn an agent + create worktree if needed |
| `cmd_new()` layout detect | bin/fleet:691–704 | Determine repo layout (plain/bare/worktree) |
| `cmd_new()` worktree create | bin/fleet:706–733 | Create worktree with `git worktree add` |
| CLAUDE.md layout section | CLAUDE.md:95–102 | High-level description of the three layouts |


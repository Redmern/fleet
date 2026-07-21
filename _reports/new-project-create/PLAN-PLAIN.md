# PLAN (plain English) — create a new project from the fleet picker

## What you asked for

When you run `fleet` in a terminal, you get the project picker (the fzf list of
your saved fleet projects). You want a **"create new project"** entry there.
Picking it lets you:

1. type a folder where the new project will live, and
2. add/create repositories inside it — each created as a **bare repository with
   everything in the `.git` folder**.

## What we'll build

- A new line at the bottom of the project picker: **`＋ create new project`**
  (in yellow). It shows up even when you have no saved projects yet — which is
  exactly when a first-timer needs it.
- Picking it starts a short text wizard, right there in the terminal:
  - **"new project directory:"** — type a path (with tab-completion). We create
    the folder (or, if it already exists and has stuff in it, we ask before using
    it).
  - **"add repository (name, empty to finish):"** — type a repo name, we create
    it; repeat as many as you want; press Enter on an empty line to stop.
- When you're done, fleet boots the new project session automatically (same as
  picking any existing project).

Each repository is created the way fleet already expects them: a **bare repo at
`<project>/<repo>/.git`**, with your working copies (worktrees) appearing
alongside it as `<project>/<repo>/<branch>` once you spawn agents. That matches,
byte-for-byte in shape, how your current `fleet/` repo is laid out.

## The one tricky bit (already solved)

A brand-new empty bare repo has no commits and no `main` branch yet, so fleet's
"spawn an agent on a new branch" step would fail with `invalid reference: main`.
So when we create each repo, we also drop in a single empty starter commit on
`main`. This is invisible, needs no checkout, and means the very first
`fleet new <repo> <branch>` just works. We tested this exact sequence and it
worked.

## What we are careful about

- **Won't crash fleet.** Fleet's rule is "never hard-fail." Every step that can
  go wrong (bad path, name clash, unwritable folder) just prints a short message
  and backs out cleanly.
- **Won't clobber.** A project name that already exists is refused; a repo folder
  that already exists is skipped; a non-empty target folder asks first.
- **Small and additive.** ~2 changed lines in the picker plus two small new
  helper functions. Nothing in the existing repo-discovery, worktree, or boot
  code changes.

## What this v1 does NOT do

- It only works from the **inline terminal picker** (the one you get by typing
  `fleet`), not from the in-tmux dashboard popup — a popup can't take typed
  input cleanly. (Can be added later if wanted.)
- Empty projects with zero repos are allowed but boot into an empty session; the
  add-repo loop nudges you to add at least one first.

---

# PROOF DESIGN — how we'll show it works end-to-end

A single scripted walkthrough, runnable by hand (fleet has no test runner; the
smoke test is `fleet doctor` + manual exercise). Steps and the exact pass checks:

### Setup
- Pick a throwaway path, e.g. `/tmp/np-proof/demo`. Ensure
  `~/.config/fleet/projects/demo.yml` does not already exist.

### 1. The picker shows the entry
- Run `fleet` in a terminal.
- **PASS:** the list contains `＋ create new project` (yellow), even if you have
  zero saved projects.

### 2. Create the project
- Select it; at **"new project directory:"** type `/tmp/np-proof/demo`.
- **PASS:**
  - `/tmp/np-proof/demo/` now exists.
  - `~/.config/fleet/projects/demo.yml` exists and contains
    `name: demo` + `root: /tmp/np-proof/demo` (HOME contracted to `~` if under
    home).

### 3. Add a bare repo
- At **"add repository (name, empty to finish):"** type `api`, then Enter on the
  next (empty) prompt to finish.
- **PASS (the bare-repo shape — the heart of the ask):**
  - `git -C /tmp/np-proof/demo/api rev-parse --is-bare-repository` → `true`
  - `/tmp/np-proof/demo/api/.git/config` contains `bare = true`
  - `/tmp/np-proof/demo/api/.git/refs/heads/main` exists (seeded commit)
  - `git -C /tmp/np-proof/demo/api/.git symbolic-ref HEAD` → `refs/heads/main`
  - layout matches the real `~/proj/pc-tune/fleet/` container.

### 4. Fleet sees the repo
- The wizard ends by booting the `demo` session. In it (or via
  `fleet up demo` then inside): run `fleet repos`.
- **PASS:** output lists `api`.

### 5. Spawn a worker on the bare repo (the real end-to-end)
- `fleet new api work -p "noop"` (or via the dashboard new-agent form).
- **PASS:**
  - a worktree `/tmp/np-proof/demo/api/work/` is created,
  - `/tmp/np-proof/demo/api/work/.git` is a `gitdir:` pointer file,
  - `git -C /tmp/np-proof/demo/api/work branch --show-current` → `work`,
  - a tmux window for the agent opens and the agent starts.
  - **No `invalid reference: main` error** — proving the seed fixed the
    empty-repo gotcha.

### 6. Re-entry
- Quit, run `fleet` again.
- **PASS:** `demo` now appears as a normal saved project in the picker (and
  `(running)` if its session is still up).

### Negative checks (fail-silent)
- Re-run create with the **same** project name → refused with a message, fleet
  does not crash, returns to a usable shell.
- Enter a repo name that already exists → skipped with a message, loop continues.
- Point the project dir at a non-empty folder → prompted to confirm; declining
  cancels cleanly.

Steps 1–5 already have their core git sequence reproduced live in scratchpad, so
the risk left at implementation time is wiring, not feasibility.

# SYNTHESIS — new-project-create

**BUILD**

Minimal, high-reuse, fail-silent. The ask is fully satisfiable by adding one
synthetic row to the existing project picker + two small new bash functions, with
**zero changes** to the repo-discovery, repo-resolution, worktree-cutting, or
boot code. The single non-obvious requirement — seeding a `main` ref into each
fresh bare repo — was reproduced and solved end-to-end.

---

## Reconciled design (PRO + CON converged)

1. **Picker entry.** Inject a yellow `＋ create new project` row (sentinel
   `__fleet_new__` in field 1) into `cmd_pick_project`, shown even when zero
   projects exist (the fresh-install case). Route the sentinel to a new
   `cmd_new_project`; everything else still goes to `cmd_up`. (PRO's design;
   `cmd_pick_project:371`.)

2. **Create flow.** `cmd_new_project` runs in the inline bare-`fleet` TTY, so it
   uses `read -e` (readline + tab-complete) for the project dir and the
   add-repo loop — fzf cannot do free-text path entry (CON risk #4). It writes
   the `name:`/`root:` yml inline rather than calling `cmd_save` (which is coupled
   to a live tmux session via `@fleet_root`), then ends by reusing `cmd_up` to
   boot.

3. **Repo creation.** Each repo is created by `new_bare_repo` as
   `git init --bare <root>/<repo>/.git` — the *exact* on-disk shape of fleet's
   real bare containers (verified against `/home/red/proj/pc-tune/fleet/`), which
   `discover_repos` finds via `[ -e "$d/.git" ]` and `cmd_new` drives via its
   `is_bare_repo == true` branch. This is the literal meaning of the user's
   "bare repository with everything in the .git folder."

4. **The load-bearing fix.** A virgin bare repo has HEAD→`master` and zero refs,
   so the first `fleet new` dies `invalid reference: main`. `new_bare_repo` seeds
   an empty root commit on `main` with git plumbing (`commit-tree` of the
   empty-tree + `update-ref` + `symbolic-ref HEAD`), no working tree, explicit
   `GIT_*` identity. Validated: after seeding, `git worktree add -b feat/x … main`
   succeeds with no change to `cmd_new`.

5. **Fail-silent discipline.** `die` is `exit 1` and would hard-crash the
   foreground fleet (CON's BLOCKER). Both new functions `echo`+`return 0` on every
   rejection; only the terminal `cmd_up` hands control off.

---

## The one research correction

The first-pass repo-model report concluded fleet bare containers are
`<repo>.git/` at the project-root level and recommended `git init --bare
repo.git`. **That is wrong and would silently dead-end** — a top-level bare
`repo.git/` has no `.git` entry and no subdir-with-`.git`, so `discover_repos`
never finds it and `fleet new` dies "repo not found" (CON risk #3). Live
inspection settled it: fleet's containers are `<repo>/.git/` (bare) with worktree
siblings. The PLAN uses that shape. **Both advisers and the live repro agree.**

---

## Rejected / deferred alternatives

- **Reuse `cmd_save` to write the yml.** Rejected: it reads the current tmux
  session's `@fleet_root` and only falls back to `$PWD` — wrong root for a
  not-yet-booted project. Inline the 1-line `printf` instead. (Could extract a
  shared `write_project_yml` helper later; not worth it now.)
- **fzf-driven directory picker** for the project path. Rejected for v1: a
  filesystem fzf is heavier and worse for *creating* a not-yet-existing dir than
  `read -e` with tab completion. Revisit if users ask.
- **Top-level `repo.git/` container** (+ teach `discover_repos` to recognise a
  bare-at-top-level dir). Rejected: diverges from the existing on-disk
  convention and the user's wording, and needs a `discover_repos` change.
- **New `fleet new-project` subcommand as the primary entry.** Deferred to an
  optional alias — the ask is specifically about the picker, and routing through
  `cmd_pick_project` needs no dispatch change.
- **Auto-cut a first worktree at create time** (so even an unsedeed bare repo is
  discoverable). Unnecessary once `main` is seeded; would also force a branch
  name on the user prematurely.

---

## Confidence

High. The two unknowns that could have sunk the feature — the exact bare shape
and the empty-repo worktree-cut — were both reproduced live, not assumed. The
change surface is tiny and additive, fits fleet's bash idioms, and preserves the
fail-silent contract. Proceed to implementation per PLAN.md.

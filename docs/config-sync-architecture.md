# Config-sync architecture — keeping it crystal-clear what is *live*

> **Status:** design doc + runbook (research, not implementation). Written
> 2026-06-18 from a verified audit of this machine (`trivium`). Cites exact paths,
> symlink targets, and chezmoi keys as observed on disk this session.

This document covers the four live tool-config repos under
`/home/red/proj/pc-tune` — **fleet, nvim, tmux, tmuxinator** — which are (a) wired
into the running system by symlinks and (b) version-controlled through fleet's
per-branch git-worktree model, with a second laptop kept in sync via chezmoi. The
recurring failure is *losing track of which branch / folder / file is actually
behind what is running.*

The doc has three parts:

1. **[RUNBOOK](#1-runbook)** — copy-pasteable, numbered, everyday order of
   operations (review → merge → deploy → push → other-laptop pull) plus recovery
   for "I edited the wrong worktree" and "two laptops diverged".
2. **[Mental model & failure modes](#2-mental-model)** — the diagram and the
   concrete ways "what is live" goes ambiguous.
3. **[Recommended architecture & phased plan](#3-recommended-architecture)** —
   the durable guardrails, options where there's a real tradeoff, and an MVP.

---

## 1. RUNBOOK

### 1.0 The one rule that prevents most confusion

> **`<repo>/main` is the only live worktree. chezmoi never touches these four
> repos. The cross-laptop sync for them is plain `git pull`, not `chezmoi`.**

The two sync systems are **orthogonal** and must stay that way (verified
2026-06-18: `~/.local/share/chezmoi/.chezmoiexternal.toml` contains only the TPM
external; `chezmoi managed` lists none of nvim/tmux/tmuxinator/fleet). chezmoi
owns the *desktop/shell/Claude* dotfiles (`~/.config/{hypr,waybar,ghostty,…}`,
`dot_zshrc`, `dot_claude*`). The four config repos own themselves via their own
git remotes. **Never `chezmoi add` any path that resolves into
`/home/red/proj/pc-tune`** — that is the single action that would re-couple the
two axes and resurrect the collision.

### 1.1 Per-repo facts you need (verified 2026-06-18)

| repo | container (bare) | live worktree | live wiring (symlink) | git remote | remote branch |
|------|------------------|---------------|-----------------------|-----------|---------------|
| nvim | `pc-tune/nvim/.git` | `pc-tune/nvim/main` | `~/.config/nvim → nvim/main` | `Redmern/nvim_0.12` | `main` |
| tmux | `pc-tune/tmux/.git` | `pc-tune/tmux/main` | `~/.tmux.conf → tmux/main/tmux.conf` | `Redmern/tmux` | `main` |
| tmuxinator | `pc-tune/tmuxinator/.git` | `pc-tune/tmuxinator/main` | `~/.config/tmuxinator → tmuxinator/main` | `Redmern/tmuxinator` | `main` |
| fleet | `pc-tune/fleet/.git` | `pc-tune/fleet/main` | `~/.local/bin/{fleet,fleet-guard,fleet-hook,fleet-tile,fleetd} → fleet/main/bin/*` | `Redmern/fleet` | `main` |

> **All four repos are now `main ↔ main`.** fleet used to be the odd one out — its
> remote default was `master` and the local live branch `main`, so push/pull
> crossed a `main ↔ master` boundary. That split was collapsed (2026-06-18):
> `origin/main` now holds the canonical history, the GitHub default is `main`, and
> the stale `master` branch was deleted. Treat fleet exactly like the others.

The **apply** step (what makes a merged change take effect in the running tool):

| repo | apply (make it live) | verify |
|------|----------------------|--------|
| nvim | restart nvim (`:qa`, reopen) | `nvim --headless +qa` (no errors) |
| tmux | `tmux source-file ~/.tmux.conf` (or `prefix + r`) | `tmux show-options -g \| grep …` |
| tmuxinator | `tmuxinator start <project>` | `tmux ls`, window layout |
| fleet | `fleet main --reload` and/or `systemctl --user restart fleetd`; `./install.sh` if bins/hooks changed | `fleet doctor` |

### 1.2 NORMAL CASE — a fleet-agent change becomes live, on this device

You dispatched an agent with `fleet new <repo> <branch> -p "…"`. It worked in the
isolated worktree `pc-tune/<repo>/<branch>` and flagged itself done (`fleet ready`).
The live config has **not** changed yet. To deploy:

```sh
# ── 0. variables (set these two) ───────────────────────────────────────────
REPO=nvim                 # nvim | tmux | tmuxinator | fleet
BR=my-feature-branch      # the agent's branch
ROOT=/home/red/proj/pc-tune
MAIN="$ROOT/$REPO/main"   # the live worktree
WT="$ROOT/$REPO/$BR"      # the agent's worktree

# ── 1. REVIEW the diff (what will go live) ─────────────────────────────────
git -C "$MAIN" diff main.."$BR"            # or: dashboard `v` on the agent
git -C "$WT"  status -sb                    # branch must be clean/committed

# ── 2. PRE-FLIGHT the live worktree — it MUST be clean to fast-forward ─────
git -C "$MAIN" status -sb
#   If DIRTY: you have un-reviewed hand-edits sitting live. Resolve first —
#   see §1.5 "I edited the live worktree directly". Do NOT proceed dirty.

# ── 3. Make the branch fast-forwardable, then MERGE into the live worktree ──
git -C "$WT"   rebase main                  # replay agent work onto current main
git -C "$MAIN" merge --ff-only "$BR"        # FF-only: live main just advances

# ── 4. DEPLOY = apply (table in §1.1). e.g. for nvim: restart nvim. ────────
#   nvim:        :qa then reopen        (or in a scratch shell: nvim --headless +qa)
#   tmux:        tmux source-file ~/.tmux.conf
#   tmuxinator:  tmuxinator start <project>
#   fleet:       fleet main --reload ; systemctl --user restart fleetd

# ── 5. VERIFY it actually loaded (table in §1.1), e.g. fleet doctor ────────

# ── 6. PUSH to origin (see §1.3 — fleet differs) ──────────────────────────
git -C "$MAIN" push origin main            # all repos (incl. fleet) — main ↔ main

# ── 7. REAP the now-merged agent worktree ──────────────────────────────────
fleet reap "$REPO/$BR"                      # refuses if unmerged/dirty — good
```

**Why this order:** review before merge (the diff is the gate); FF-only so the
live `main` history stays linear and "the symlinked HEAD *is* what's deployed"
stays literally true (no merge commit to introduce surprise content); apply +
verify before push (don't publish a config that doesn't load); reap last (only a
merged branch is safe to delete — `reap` enforces this).

### 1.3 When/how to PUSH to origin (`github.com/Redmern/<repo>`)

- **When:** after step 5 (applied + verified) of any deploy. Push so the *other
  laptop* and GitHub reflect the live state. There is no auto-push; an unpushed
  `main` is the #1 source of two-laptop divergence.
- **all repos (nvim / tmux / tmuxinator / fleet)** — branch is `main` both ends:
  ```sh
  git -C "$ROOT/$REPO/main" push origin main
  ```
  (fleet was migrated off its old `master` default on 2026-06-18; it now pushes
  `main → origin/main` like the rest.)
- **Quick "am I ahead?" check** before/after:
  ```sh
  git -C "$ROOT/$REPO/main" status -sb        # shows ahead/behind origin
  ```

### 1.4 Where chezmoi fits (short answer: not here)

For the four config repos, **chezmoi is not in the loop at all**:

- You **never** run `chezmoi add` / `chezmoi re-add` on `~/.config/nvim`,
  `~/.tmux.conf`, `~/.config/tmuxinator`, or `~/.local/bin/fleet`. They are
  unmanaged by design; adding them re-creates the collision.
- `chezmoi apply` leaves these four paths untouched (they're not in the source),
  so there is **no ordering constraint** between a git merge and `chezmoi apply`
  for these repos — they cannot clobber each other.
- chezmoi's own loop (for the *desktop* dotfiles it does manage) is unchanged:
  ```sh
  chezmoi add <some ~/.config/... file>   # only for chezmoi-managed dotfiles
  chezmoi cd && git commit -am … && git push   # (or the czp alias)
  chezmoi update                          # pull + apply, on either laptop
  ```
- The **guardrail:** if you ever see `chezmoi managed | grep pc-tune` return a
  line, or `chezmoi diff` mention nvim/tmux/tmuxinator/fleet, stop — something
  re-coupled the axes; `chezmoi forget <path>` it and remove any
  `.chezmoiexternal.toml` block that points at these repos.

### 1.5 RECOVERY — "I edited the wrong worktree"

**(a) I edited the LIVE worktree directly** (`<repo>/main`), bypassing review.
This is exactly today's `nvim/main` state (7 modified, 1 deleted, untracked
`omp.lua` + `*.bak.*`). The live tool already reflects these edits, but they're on
no branch and nowhere pushed. Regularize — pick one:

```sh
MAIN=$ROOT/nvim/main
# Option A — keep them as a normal main commit (simplest for a small hotfix):
git -C "$MAIN" add -A
git -C "$MAIN" rm lua/plugins/opencode.lua 2>/dev/null   # record the deletion
git -C "$MAIN" commit -m "config: <describe live edits>"
git -C "$MAIN" push origin main          # all repos → origin/main
# clean up stray backups that are cluttering the tree:
git -C "$MAIN" clean -n                  # DRY RUN first — review what it'd remove
# then, only the .bak.* you don't want:  git -C "$MAIN" clean -f -- '*.bak.*'

# Option B — move them onto a review branch instead of committing to main:
git -C "$MAIN" stash -u
fleet new nvim live-edits-review          # cuts a worktree off main
git -C "$ROOT/nvim/live-edits-review" stash pop   # (or re-apply by hand)
#   …then review + go through §1.2 to bring them back to main.
```

**(b) I edited a FEATURE worktree thinking it was live.** Nothing live changed
(good — that's the isolation working). Finish/commit the work in that worktree and
run §1.2 to deploy it when ready. The live tool was never affected.

**(c) I edited the STALE clone `/home/red/proj/fleet`.** That directory is a
*separate* clone, not wired to anything (symlinks point at `fleet/main`). Edits
there go nowhere live. Recover the work into the container, then delete the clone:

```sh
# salvage any commits the stale clone has that the container lacks:
git -C "$ROOT/fleet/main" fetch /home/red/proj/fleet master
git -C "$ROOT/fleet/main" log --oneline HEAD..FETCH_HEAD   # unique commits?
#   (audited 2026-06-18: ZERO unique commits — it's 14 behind, nothing stranded)
# salvage any uncommitted file (e.g. its untracked AGENTS.md) by hand, then:
rm -rf /home/red/proj/fleet              # see §3.4 — kill the duplicate
```

### 1.6 RECOVERY — "two laptops diverged"

Symptom: `git push` rejected (`non-fast-forward`), or the two machines show
different live config for the same repo.

**For a config repo (nvim/tmux/tmuxinator/fleet):**

```sh
MAIN=$ROOT/$REPO/main
git -C "$MAIN" fetch origin
git -C "$MAIN" status -sb                 # see ahead/behind
# integrate remote work under your local (linear history; you're solo per repo):
git -C "$MAIN" pull --rebase origin main           # all repos → origin/main
#   resolve any conflicts, then:
#   git -C "$MAIN" rebase --continue
# re-APPLY (§1.1 table) so the running tool matches the merged result, then:
git -C "$MAIN" push origin main                     # all repos → origin/main
```

**For chezmoi-managed desktop dotfiles** (separate axis):

```sh
chezmoi git -- fetch origin
chezmoi git -- status
chezmoi git -- pull --rebase            # resolve conflicts in the SOURCE
chezmoi apply                           # push desired state to the targets
chezmoi git -- push
```

Resolve the two axes **independently** — they share no files, so a conflict in one
never implies a conflict in the other.

### 1.7 OTHER LAPTOP — pull these changes (exact commands)

On the second machine (already bootstrapped per `pc-tune/bootstrap.sh`):

```sh
ROOT=$HOME/proj/pc-tune

# 1. the four config repos — plain git pull into each LIVE worktree:
for r in nvim tmux tmuxinator fleet; do
  git -C "$ROOT/$r/main" pull --ff-only origin main
done

# 2. APPLY each so the running tools pick it up (§1.1 table):
#    nvim: restart nvim
#    tmux: tmux source-file ~/.tmux.conf
#    tmuxinator: tmuxinator start <project>
#    fleet: (if bins/hooks changed) cd "$ROOT/fleet/main" && ./install.sh
#           then: fleet main --reload ; systemctl --user restart fleetd

# 3. the DESKTOP/shell dotfiles — separate axis, chezmoi:
chezmoi update            # = chezmoi git pull + chezmoi apply

# 4. sanity:
fleet doctor
```

**Order:** steps 1–2 (config repos) and step 3 (chezmoi) are independent; do them
in either order. The `--ff-only` guarantees you never silently create a merge on
pull — if it refuses, the laptop has local commits → go to §1.6.

---

## 2. Mental model

```
                         github.com/Redmern/*            github.com/Redmern/dotfiles
                         (per-repo remotes)              (chezmoi source remote)
                                 ▲                                  ▲
                          git push/pull                      chezmoi git push / update
                                 │                                  │
  ┌──────────────────────────────────────────────┐     ┌──────────────────────────────┐
  │  META-REPO  /home/red/proj/pc-tune (.git)      │     │  ~/.local/share/chezmoi (.git)│
  │  tracks: MISSION.md PLAN.md CLAUDE.md           │     │  dot_config/{hypr,waybar,…}   │
  │          AGENTS.md bootstrap.sh                 │     │  dot_zshrc dot_claude*         │
  │  .gitignores the 4 container dirs ↓             │     │  .chezmoiexternal.toml (TPM)  │
  └──────────────────────────────────────────────┘     └──────────────┬───────────────┘
        │            │            │            │                       │ chezmoi apply
        ▼            ▼            ▼            ▼                        ▼
   ┌─────────┐  ┌─────────┐  ┌──────────┐  ┌────────────┐      ~/.config/{hypr,waybar,
   │ nvim/   │  │ tmux/   │  │tmuxinator│  │ fleet/     │       ghostty,…}, ~/.zshrc, …
   │  .git ◄─bare repos────────────────────────────────┘       (DISJOINT from the 4 repos)
   │  main/ │  │  main/  │  │  main/   │  │  main/     │ ◄── THE LIVE WORKTREE (one per repo)
   │  <br>/ │  │  <br>/  │  │          │  │  <br>/ …   │ ◄── agent scratch worktrees (NOT live)
   └────┬────┘  └────┬────┘  └────┬─────┘  └─────┬──────┘
        │ symlink    │ symlink    │ symlink      │ symlinks
        ▼            ▼            ▼              ▼
  ~/.config/nvim  ~/.tmux.conf  ~/.config/    ~/.local/bin/{fleet,fleet-hook,
                                tmuxinator     fleetd,fleet-guard,fleet-tile}
        └──────────── THE RUNNING SYSTEM (what is actually live) ──────────┘

   ✗ STALE: /home/red/proj/fleet  — a SECOND, standalone clone (not a worktree,
            14 commits behind fleet/main, no unique commits). Wired to nothing now,
            but a trap. → delete (§3.4).
```

**Read it as:** a *meta-repo* holds intent + a bootstrap script and gitignores
four *container* repos; each container is a bare repo plus exactly one **live
worktree (`main`)** that the running system reaches through symlinks; fleet agents
add *scratch worktrees* per branch that are NOT live until merged to `main`;
chezmoi is a **completely separate** sync axis covering the rest of the dotfiles,
sharing no files with the four repos.

### 2.1 Failure modes that cause "lost track of what is live"

| # | failure mode | why it confuses "what's live" | observed today? |
|---|--------------|-------------------------------|-----------------|
| F1 | **Branch worktree not merged to main** | edits sit in `<repo>/<branch>`; you think they're live but the symlink points at `main` | latent (3 fleet scratch worktrees) |
| F2 | **Live worktree edited directly & left dirty** | running tool reflects uncommitted edits on no branch, nowhere pushed; GitHub/other-laptop disagree with reality | **YES** — `nvim/main` dirty (7 mod, 1 del, untracked `omp.lua` + `.bak.*`) |
| F3 | **Stale / duplicate clone** | a second clone (`/home/red/proj/fleet`) looks authoritative; editing it or running its `install.sh` re-points symlinks at stale code | **happened** — clone was 14 behind, install was once pointed at it; **removed during this session** (gone as of final check). Guardrail still needed against recurrence |
| F4 | **Symlink target ambiguity** | a live symlink silently points at a non-`main` worktree or a stale clone → "what I edited" ≠ "what runs" | resolved today (all symlinks verified → container `main`), but nothing *prevents* recurrence |
| F5 | **chezmoi ↔ worktree re-coupling** | a `chezmoi add` / re-added external on `~/.config/nvim` or `~/.tmux.conf` makes `chezmoi apply` overwrite the live symlink | resolved (no such entry now), but only by discipline |
| F6 | **Two-laptop divergence** | unpushed `main`, or each laptop committing to `main` independently → different live config, same repo | latent (`fleet/main` ahead 1 of origin; nvim live edits unpushed) |
| F7 | **fleet `main`↔`master` skew** | fleet's local live branch was `main`, remote default `master`; a naive `push origin main` created a stray remote `main`, and "is it pushed?" was ambiguous | **resolved 2026-06-18** — collapsed to `main` everywhere (default + sole branch); `master` deleted |

---

## 3. Recommended architecture

Principle: **make the live worktree unmistakable, make the wrong worktree hard to
touch by accident, and assert the single-source-of-truth mechanically.** Keep the
existing bare-repo-per-config + worktree model (it's sound and fleet-native);
*don't* layer Stow/chezmoi onto these four repos (that adds a second
source-of-truth and its own symlink-following footguns). Harden what's there.

### 3.1 Make "what is live" queryable — a `fleet status` view (highest value)

The single biggest win for the stated pain is a **read-only status command** that
prints, per repo, the whole live picture at a glance. A draft non-destructive
implementation ships with this doc at `bin/fleet-status` (run it as
`fleet/main/bin/fleet-status`; wiring it into the `fleet` dispatch as `fleet
status` / a dashboard pill is the MVP follow-up). It reports, per repo:

- the **live symlink(s)** and their resolved target, asserting it equals the
  canonical `<repo>/main` (flags F3/F4);
- `main`'s **branch, dirty/clean, ahead/behind** origin (flags F2/F6);
- **other worktrees** that exist (so scratch branches are visible, F1);
- whether any pc-tune path is **chezmoi-managed** (flags F5);
- presence of **stale sibling clones** in `~/proj` (flags F3).

This converts every latent failure mode above into a visible line. It's the MVP:
clarity first, automation later.

### 3.2 Make the live worktree unmistakable (choose one)

| option | what | pro | con |
|--------|------|-----|-----|
| **A. Direct symlink (today)** | `~/.config/nvim → nvim/main` | simplest; already in place | "which is live" is implicit in each symlink; no single switch; no atomic rollback |
| **B. Indirection symlink** *(recommended for durability)* | `~/.config/nvim → nvim/LIVE`, `LIVE → main` | single queryable/atomically-switchable source of truth; instant rollback by repointing `LIVE` (`ln -sfn` = atomic `rename(2)`) | one extra hop; `bootstrap.sh` + status helper must learn the indirection |
| **C. Marker file** *(complements A or B)* | drop `.fleet/LIVE` in `<repo>/main` only | cheap; survives independent of symlink state; drives prompt/statusline role badge; matches existing `.fleet/ready` idiom | doesn't itself prevent mis-targeting; advisory |

**Recommendation:** keep **A** for now (don't churn the working symlinks for MVP),
add **C** immediately (near-zero cost, powers the status view + prompt badge), and
adopt **B** only if/when you want atomic rollback or find the implicit-per-symlink
model still confusing after the status view lands.

### 3.3 Make the wrong worktree hard to edit (defense in depth)

- **Prompt / statusline role badge** (cheap, always-on, human-facing): when `cwd`
  is inside a `<repo>/main` live worktree, show a distinctive badge (e.g. bold red
  `LIVE`) plus dirty + `git log main..HEAD`-style ahead state; scratch worktrees
  render normal. Drives off the `.fleet/LIVE` marker (3.2-C). Git's
  `GIT_PS1_SHOWDIRTYSTATE` / starship give the dirty/branch half for free; the
  *role* segment is the addition.
- **Edit guard on the live tree** (hard stop): fleet already has `bin/fleet-guard`
  (a PreToolUse hook denying edits to protected paths). Extend it to **hard-deny
  agent edits whose resolved path is inside any `<repo>/main`** — agents should
  only ever touch their own scratch worktree. Backstop with a shared
  `no-commit-to-branch`-style hook (`core.hooksPath`, inherited by all worktrees)
  refusing direct commits on `main`. *(Tradeoff: the guard binds claude agents;
  omp agents have `H_GUARD_KIND=none`, so for an omp fleet the real safeguard
  stays worktree-isolation + the review gate. The guard is belt; review is
  suspenders.)*

### 3.4 Enforce single-source-of-truth (kill duplicates, assert symlinks)

- **Stale clone** `/home/red/proj/fleet` (F3) — audited zero unique commits (14
  behind `fleet/main`); **already removed during this session** (verify with
  `ls ~/proj/fleet` → should be gone). The lasting fix is the doctor check below
  so a future stray clone is *detected*, since nothing structurally prevents one.
- **`fleet doctor` symlink-integrity check:** for each managed config, assert
  `realpath(deployed) == (git worktree list | branch==main)` for its container.
  Flag dangling links, a deployed *copy* (not a symlink → config drifted out of
  git), more than one worktree claiming `main`, or a target outside the known
  container roots. This makes git itself the source of truth (robust if the repo
  moves) and turns F3/F4 into a failing smoke test.
- **Guard against re-coupling chezmoi** (F5): a doctor assertion that
  `chezmoi managed` returns nothing under `/home/red/proj/pc-tune` and that
  `.chezmoiexternal.toml` has no block targeting these paths.

### 3.5 Integration flow (keep main always-deployable)

- **Rebase scratch branch → FF-only merge into `main` → apply → push → reap**
  (§1.2). FF-only keeps live history linear so the deployed HEAD is unambiguous.
- Surface **`git log main..<branch>` ("N commits not yet live")** in the dashboard
  per scratch worktree, so "this branch is NOT live yet" is explicit (F1).
- **fleet `main`↔`master`:** ~~standardize the push as `main:master`~~ — **done
  (2026-06-18):** fleet's remote default is now `main` and `master` is deleted, so
  the status helper compares `main` against `origin/main` like every other repo and
  "is it pushed?" is unambiguous (F7 resolved).

### 3.6 Cross-laptop (the real chezmoi gap)

chezmoi reproduces the *desktop* env on a second laptop but **not** these four
repos or their symlinks — `bootstrap.sh` does that, out of band. That's fine and
intentional, but it means a fresh laptop needs `bootstrap.sh` run explicitly
(it's idempotent). Keep the two bootstraps documented together (they already are,
in `PLAN.md §12`). Do **not** try to fold the four repos into chezmoi externals to
"unify" sync — that reintroduces F5 and the externals-vs-worktree footguns.

### 3.7 Phased plan

**Phase 0 — immediate cleanup (do now, low-risk):**
1. Commit or branch the dirty `nvim/main` live edits (F2, §1.5a); clean stray
   `*.bak.*`.
2. ~~Delete the stale `/home/red/proj/fleet`~~ — **done this session** (verify it's
   gone; salvage its `AGENTS.md` from a backup if it wasn't preserved) (F3).
3. ~~Push `fleet/main → origin master`~~ — superseded by the main standardization
   (2026-06-18): `fleet/main → origin main`, `master` deleted (F6/F7 resolved).

**Phase 1 — MVP visibility (clarity first):**
4. Land `bin/fleet-status` and wire it as `fleet status` + a dashboard pill (3.1).
5. Add the `.fleet/LIVE` marker (3.2-C) and a prompt/statusline role badge (3.3).

**Phase 2 — guardrails (automation):**
6. `fleet doctor` symlink-integrity + chezmoi-decoupling checks (3.4).
7. Extend `fleet-guard` to deny edits inside `<repo>/main`; add the
   `no-commit-to-branch` hook (3.3).

**Phase 3 — optional hardening:**
8. Indirection symlink + atomic rollback (3.2-B), only if still warranted.

### 3.8 Open questions & risks

- **omp vs claude guard coverage:** the edit-guard (3.3) only binds claude agents;
  an omp-driven fleet relies on worktree isolation + review. Acceptable? Or add an
  omp-side equivalent?
- **Direct vs indirection symlink (3.2):** is atomic rollback worth the extra hop,
  or is the status view enough to kill the confusion? Recommend deferring B until
  after the MVP proves insufficient.
- ~~**fleet `main`/`master` duality:**~~ **resolved (2026-06-18)** — the fleet
  remote default was made `main` and `master` deleted, eliminating F7 entirely.
- **AGENTS.md churn:** both `pc-tune` and the stale clone carry an untracked
  `AGENTS.md` (fleet's orchestrator guidance for omp harnesses). Decide where it's
  canonical (the meta-repo? the fleet repo?) and commit it, so it stops showing as
  untracked everywhere.
- **`tmux/chezmoi-collision` worktree:** a leftover branch at the same HEAD as
  `main` — prune it (`fleet reap` / `git worktree remove`) once confirmed unneeded.
```

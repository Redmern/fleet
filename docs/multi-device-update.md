# Multi-device update runbook — sync an existing fleet install to the latest push

**Goal:** a second device (e.g. a laptop) already has `pc-tune` + fleet installed.
This brings it up to date with whatever has been pushed from another device — the
four config repos (`fleet`, `nvim_0.12`, `tmux`, `tmuxinator`), `dotfiles` via
chezmoi — and re-applies the deploy/install steps (symlinks, `fleetd`, hooks, the
`fleet browser` driver) so the new state is live. Run it whenever you want a
device to catch up; it only touches the device you run it on.

This runbook **only updates the laptop**; nothing here touches the desktop. Run
the blocks in order, top to bottom. `PC=~/proj/pc-tune` is assumed below — adjust
if the laptop keeps the container somewhere else.

---

## Two update models — git-worktree vs pacman repo

There are now **two** ways a device gets fleet updates, and they coexist:

- **Git-worktree model (dev box).** The machine where you *develop* fleet keeps
  the `$PC/fleet/main` worktree + `~/.local/bin` symlinks (`install.sh`). Those
  symlinks intentionally shadow `/usr/bin/fleet` on PATH, so the dev checkout
  always wins. Updates come from the rest of this runbook (`git pull --ff-only`
  + `install.sh`). Use this on any device where you edit fleet.

- **Pacman-repo model (other devices).** A device that only *consumes* fleet can
  skip the worktree entirely: add the self-hosted `[fleet]` pacman repo once and
  update with plain `sudo pacman -Syu`. See `docs/custom-repo.md` for the
  one-time `pacman.conf` stanza and `pacman -S fleet-git`. CI republishes the
  package on every push to `main`, so the laptop catches up with a normal system
  upgrade — no worktree pull, no `install.sh`.

  ```bash
  # one-time, per device (see docs/custom-repo.md for the pacman.conf stanza):
  sudo pacman -Sy && sudo pacman -S fleet-git
  fleet setup                 # per-user: fleetd unit + Claude hooks (pacman can't do this)
  # thereafter:
  sudo pacman -Syu            # fleet updates arrive like any package
  ```

  `fleet setup` is still required once per device (pacman installs only system
  files). The other config repos (`nvim`, `tmux`, `tmuxinator`, `dotfiles`) are
  **not** packaged — if the device uses them, keep following the worktree/chezmoi
  steps below for those even while fleet itself comes from pacman.

**Pick one for fleet per device.** Don't run both the `~/.local/bin` symlinks and
the `fleet-git` package as your primary on the same box — the symlinks would
shadow the packaged binary, masking pacman upgrades. The rest of this runbook is
the **git-worktree** path.

---

## Layout reminder (why the commands look the way they do)

Per `bootstrap.sh`, each config repo is a **worktree container** under
`$PC/<name>/`:

- bare repo at `<name>/.git`
- a checked-out `main` worktree at `<name>/main`
- live `$HOME` paths are **symlinks into the `main` worktree**:
  - `~/.config/nvim`      → `nvim/main`
  - `~/.tmux.conf`        → `tmux/main/tmux.conf`
  - `~/.config/tmuxinator`→ `tmuxinator/main`

`fleet` itself lives the same way: `fleet/main/bin/*` is symlinked into
`~/.local/bin` by `install.sh`. So updating fleet = pull `fleet/main`, then re-run
its `install.sh`.

All four repos are **`main`-only** on origin (the old fleet `main`↔`master` split
was collapsed on 2026-06-18, commit `56cd970`). Only `dotfiles` uses `master`.

Container dir → GitHub repo:

| container dir | remote                          | branch |
|---------------|---------------------------------|--------|
| `fleet`       | `Redmern/fleet`                 | main   |
| `nvim`        | `Redmern/nvim_0.12`             | main   |
| `tmux`        | `Redmern/tmux`                  | main   |
| `tmuxinator`  | `Redmern/tmuxinator`            | main   |
| (chezmoi)     | `Redmern/dotfiles`              | master |

---

## 0. Pre-flight

```bash
PC=~/proj/pc-tune
cd "$PC"

# See if any container has local uncommitted edits BEFORE pulling.
for r in fleet nvim tmux tmuxinator; do
  echo "=== $r ==="
  git -C "$PC/$r/main" status --short
done
```

A line beginning `??` (e.g. `?? .fleet/`) is just untracked local fleet markers —
**harmless**, a `--ff-only` pull ignores them. Lines beginning ` M`/`M ` mean a
tracked file was edited locally; handle those in step 1.

---

## 1. Update the four config repos (`--ff-only` per worktree)

`--ff-only` refuses to merge — it only advances if the laptop has no divergent
local commits, so it can't silently create a merge commit or conflict.

```bash
PC=~/proj/pc-tune
for r in fleet nvim tmux tmuxinator; do
  echo "=== $r ==="
  git -C "$PC/$r/main" fetch origin
  git -C "$PC/$r/main" pull --ff-only origin main
done
```

**If a repo has local uncommitted changes** and the pull complains
(`cannot pull with rebase: You have unstaged changes` / `Your local changes …
would be overwritten`):

```bash
# Inspect first — decide keep vs discard:
git -C "$PC/<repo>/main" diff

# (a) keep them — stash, pull, reapply:
git -C "$PC/<repo>/main" stash push -m "laptop-local pre-update"
git -C "$PC/<repo>/main" pull --ff-only origin main
git -C "$PC/<repo>/main" stash pop        # resolve any conflict here

# (b) discard them — only if you're sure they're throwaway:
git -C "$PC/<repo>/main" checkout -- .
git -C "$PC/<repo>/main" pull --ff-only origin main
```

**If `--ff-only` is refused because the laptop has its own commits**
(`Not possible to fast-forward`): the laptop branch diverged. Don't force. Inspect
`git -C "$PC/<repo>/main" log --oneline origin/main..main` to see the local
commits, then either rebase them (`git -C … rebase origin/main`) or, if they're
unwanted, reset (`git -C … reset --hard origin/main` — **destructive**, discards
local commits). When unsure, stop and ask.

---

## 2. Update dotfiles (chezmoi)

`chezmoi update` = `git pull` the source (`Redmern/dotfiles` **master**) + `apply`.

```bash
chezmoi update -v        # -v shows what it changes; pulls master, then applies
```

> ⚠️ **chezmoi vs pc-tune symlinks.** On the desktop, `~/.config/nvim`,
> `~/.tmux.conf`, `~/.config/tmuxinator` are **pc-tune-owned symlinks**, not
> chezmoi-managed — `bootstrap.sh` warns and tells you to `chezmoi forget` them so
> `chezmoi apply` won't clobber the symlinks. **Verify the laptop did the same:**
>
> ```bash
> chezmoi managed | grep -E '(^|/)\.config/nvim($|/)|^\.tmux\.conf$|(^|/)\.config/tmuxinator($|/)'
> ```
>
> If that prints any of those paths, chezmoi will overwrite the pc-tune symlink on
> apply. Fix on the laptop with:
> `chezmoi forget .config/nvim .tmux.conf .config/tmuxinator`
> then re-run `bootstrap.sh` (step 3a) to restore the symlinks.

---

## 3. Re-run fleet install + browser driver

### 3a. (only if symlinks/containers might be missing) re-run bootstrap

`bootstrap.sh` is idempotent — it (re)creates any missing container or live
symlink and backs up anything in the way. Safe to run; skip if step 0 showed all
symlinks already resolving.

```bash
cd "$PC" && ./bootstrap.sh
```

### 3b. Re-run fleet's installer (idempotent)

This re-links the bins, re-asserts the `fleetd` systemd `--user` unit, re-wires
the Claude Code hooks into **both** `~/.claude` and `~/.claude_personal`
`settings.json`, and vendors the browser driver.

```bash
cd "$PC/fleet/main" && ./install.sh
```

What it does (from `install.sh`), and what to expect in the output:

- Symlinks `fleet fleetd fleet-hook fleet-guard` → `~/.local/bin`.
- `fleetd.service`: `systemctl --user enable --now fleetd` (or, if no user
  systemd bus, prints `--no-systemd` and starts `fleetd` via `nohup`).
- Wires `fleet-hook` (state reporting) + `fleet-guard` (write-guard, dormant
  until `fleet guard on`) into both profile `settings.json`.
- **Browser driver:** if `lib/node_modules/playwright-core` is absent, runs
  `(cd lib && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm i)` — vendors
  **playwright-core only, no ~150 MB browser download** (it drives the **system
  Chromium**). You want to see either `fleet browser ready` or `already vendored`.
  - If it prints `note: npm not found` or `WARN: 'cd lib && npm i' failed`, the
    laptop is missing `npm` — install Node/npm (`sudo pacman -S nodejs npm`), then:
    `(cd "$PC/fleet/main/lib" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm i)`
  - `fleet browser`/`fleet devport` also need a **system Chromium** at runtime:
    `command -v chromium || sudo pacman -S chromium`.

### 3c. Confirm the dormant dispatch hook is NOT wired

`install.sh` does **not** touch `bin/fleet-dispatch.sh` — it's a deliberately
opt-in `UserPromptSubmit` hook (enabled only via `fleet dispatch enable`). Leave
it off. Confirm it didn't sneak into either profile:

```bash
grep -l fleet-dispatch ~/.claude/settings.json ~/.claude_personal/settings.json 2>/dev/null \
  && echo "!! dispatch wired — remove it" || echo "ok: dispatch hook not wired"
```

Expect `ok: dispatch hook not wired`. Do **not** run `fleet dispatch enable` on
the laptop as part of this update.

---

## 4. Restart services / reload

Picks up the new `fleetd` (C-v2 scratch-hidden session + notification gate),
fleet-dash, and nvim code.

```bash
# fleetd — required for the scratch-hidden + notification-gate changes:
systemctl --user restart fleetd
#   (no systemd user bus? instead: pkill -f '/fleetd'  then  fleet up  restarts it)

# fleet-dash — only if a fleet session is currently running:
fleet main --reload      # restarts just the dashboard pane in place

# nvim — restart any open nvim so it reloads the pulled config (fleet.lua + config).
#   Just quit and relaunch nvim; live sessions keep the old Lua until restarted.
```

---

## 5. Verify

```bash
fleet doctor      # deps (tmux/nvim/git/python3/fzf), harnesses, fleetd socket,
                  # fleet-hook resolves, hooks wired in both profiles, unit enabled
fleet ls          # lists agents — confirms the CLI + daemon talk
```

`fleet doctor` should be green: `ok fleet-hook -> …`, `ok hooks wired` in both
profiles, `ok fleetd socket` (after step 4), `ok fleetd.service enabled`. A `warn`
on `tmuxinator`/`notify-send` is non-fatal.

**Smoke-test a new feature** — scratch agent hides in the tab bar + shows in dash:

```bash
fleet up                       # boot a session if none is running
fleet new --scratch smoke -p "say hi"
# Expect: the scratch agent does NOT add a normal window to the tmux tab bar
# (it parks in the *_hidden session); it appears in the dashboard instead
# (surface it with Enter in the dash). Notification gate: an unfocused
# blocked/done agent fires exactly one desktop notify, not a storm.
```

Optionally smoke-test the browser driver:

```bash
node "$PC/fleet/main/lib/browser-test.js" 2>&1 | head    # or: fleet browser --help
```

---

## 6. Gotchas — device-specific bits, do NOT blindly sync

- **No `master` branches anymore (commit `56cd970`).** The config repos are
  `main`-only. If the laptop still has stale local `master` branches in any
  container from the old split, they're dead — ignore or delete
  (`git -C "$PC/<repo>/.git" branch -D master`). Only **dotfiles** uses `master`.
- **chezmoi-owned vs pc-tune-owned paths (step 2).** `~/.config/nvim`,
  `~/.tmux.conf`, `~/.config/tmuxinator` must be pc-tune symlinks, **not**
  chezmoi-managed, or `chezmoi apply` clobbers them. The laptop may have been set
  up before the `chezmoi forget` convention — re-check with `chezmoi managed` and
  `chezmoi forget` them if listed, then re-run `bootstrap.sh`.
- **The dispatch hook stays dormant (step 3c).** `bin/fleet-dispatch.sh` is a
  fork-bomb-guarded opt-in. Don't enable it during a sync. `install.sh` never
  wires it; verify it didn't get wired by hand.
- **System deps the laptop may lack:**
  - `chromium` — required by `fleet browser`/`fleet devport` at runtime.
  - `nodejs`/`npm` — required once to vendor playwright-core (step 3b).
  - `fzf` — `fleet doctor` flags it `MISS`; pickers need it.
  - `tmux` / `nvim` versions — the nvim container is `nvim_0.12` (Neovim 0.12+).
    An older nvim on the laptop may error on the pulled Lua; check `nvim --version`.
  - `notify-send` (libnotify) — without it the fleetd notification gate is silent
    (non-fatal; `fleet doctor` warns).
- **No force-pushes.** Every step uses `--ff-only` / stash. If a pull won't
  fast-forward, the laptop diverged — inspect and rebase, don't `reset --hard`
  unless you've confirmed the local commits are disposable.

---

### One-shot (paste after reading the gotchas)

```bash
PC=~/proj/pc-tune
cd "$PC"
for r in fleet nvim tmux tmuxinator; do
  git -C "$PC/$r/main" pull --ff-only origin main
done
chezmoi update -v
cd "$PC/fleet/main" && ./install.sh
systemctl --user restart fleetd
fleet main --reload 2>/dev/null || true
fleet doctor
```
Then restart nvim, and re-check chezmoi-vs-symlink ownership if `chezmoi update`
touched any of the three config paths.

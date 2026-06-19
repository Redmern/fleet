# fleet

Personal agent fleet manager (cmux/herdr-style) for **tmux + nvim + Claude Code**.
Standalone: fleet only *calls* tmux/nvim/git/claude. Every integration is
fail-silent — if the daemon or any app is down, the rest keeps working.

## What it does

- **Status visibility** — every Claude agent reports its state (working /
  blocked / idle) via Claude Code hooks → `fleetd` → tmux window glyphs
  (`●` colored by state, appended to your status bar at runtime).
- **Jump picker** — `prefix+a` opens an fzf popup of all agents sorted by
  urgency (blocked first); Enter jumps to that window.
- **Fast spawn** — `fleet new backend feature-x -p "do the thing"` creates the
  git worktree (matching the `<Repo>/<branch-dir>` layout, bare-repo containers
  supported), opens a tmux window with nvim, auto-opens claude and seeds the
  prompt. `--bare` for a plain claude pane without nvim.
- **Cost meter** — each agent's row shows live token spend (`$X.YZ Ntok`),
  summed from its Claude transcript × per-model pricing (the hook records the
  transcript path). `fleet cost <agent>` prints it on the CLI.
- **Stall detector** — an agent stuck `working` past `FLEET_STALL` seconds
  (default 600) flips its state pill to a red `stalled`, so runaway/looping
  agents stand out at a glance.
- **Best-of-N fan-out** — `fleet fan <repo> <name> -n 3 -p "task"` spawns N
  agents on the same prompt (branches `<name>-1..N`); review each with `v`,
  promote a winner by closing the rest (`d`).
- **Write-guard** — opt-in PreToolUse hook (`fleet guard on`) that asks before
  an agent edits tests, CI configs, or lockfiles — and hard-denies paths listed
  with a leading `!` in `.fleet/protected` (or `~/.config/fleet/protected`). Off
  by default; agents can't quietly delete tests to make a build pass.
- **Session restore** — spawned agents are remembered per project; after a
  tmux/server restart, `fleet restore` (or `fleet up --restore`) respawns the
  ones whose windows are gone. `fleet up` hints when a saved set exists.
  Tearing an agent down (dashboard `d`) forgets it.
- **Desktop notifications** — notify-send when an agent blocks or finishes
  while its window isn't focused (30s cooldown, flap guard).
- **Command center** — `fleet main`: orchestrator claude at the project root on
  the left, an interactive **agent dashboard** on the right (`fleet-dash`),
  framed in a rounded box and redrawn in place (no flicker on refresh). One row
  per agent, as fixed-width rounded pills (omarchy-style): **state ·
  repo/branch · git status · permission mode**. Git status is
  `*dirty +ahead -behind` vs upstream (`ok` when clean), pills are coloured by
  severity and all the same size so the columns align. Sorted by urgency,
  self-refreshing every 1s (set `FLEET_DASH_REFRESH`); the label flexes and
  pills drop right-to-left when the pane is narrow. Pills use Nerd Font caps.
  Drive it from the keyboard:

  | Key | Action |
  |---|---|
  | `j`/`k` (or ↑/↓) | move selection (`g`/`G` = first/last) |
  | `⏎` | jump to the selected agent's window |
  | `v` | view the selected agent's `git diff HEAD` in a popup pager |
  | `m` | open the permission-mode popup for the selected agent |
  | `s` | send a message to the selected agent |
  | `n` | open the new-agent form (Repo/Base dropdowns, Branch, Prompt, Bare) |
  | `d` | close the selected agent (confirm popup: close window / remove worktree / force) |
  | `r` | refresh now |

  The permission-mode column and the `m` popup read the mode live from claude's
  own footer (the `… on (shift+tab to cycle)` line), so they're authoritative.
  Because claude only exposes mode *cycling* (Shift+Tab), not "set mode X", the
  `m` popup **discovers** the available modes the first time it's used — cycling
  the agent one full loop, recording each mode, and returning it to where it
  started — then caches that list for the session and presents it as a pick-list
  (`j`/`k`, `Enter`). Selecting a mode drives the agent to it. Works regardless
  of how many modes that claude version has or what they're called.

  The selected row's left marker bar is **green when the dashboard pane has
  keyboard focus** and dim grey when focus is on the orchestrator/claude pane
  or another window — so you can tell at a glance whether `j/k`/`m`/… will land
  in the dashboard. It updates instantly via tmux focus events (the dashboard
  enables `focus-events` and requests focus reporting), falling back to the
  idle refresh.

  The `n` form's fields are dropdowns (`←/→` cycles, `Enter` opens a scrollable
  picker; `j/k` or `↑/↓` move between fields). **Repo** lists the project's
  repos. **Branch** lists the repo's **existing worktrees** — pick one to launch
  an agent on it — or `+ new branch` to create one, which reveals a name field
  and a **Base** dropdown (the new branch is cut off the chosen base, via
  `fleet new --base`). Changing Repo reloads both lists. **Harness** picks which
  agent CLI to launch (claude/omp/…).

  `d` tears down the selected agent: a confirm popup offers *close window*
  (keep files), *remove worktree*, or *force remove*. Removing a worktree with
  uncommitted/untracked changes is refused unless you pick force — the agent
  window is still closed, the worktree is kept.

  `fleet main --reload` restarts just the dashboard process in place (same pane,
  size, and position) — handy after editing `fleet-dash`. The orchestrator pane
  and every agent window keep running; no work is lost.
- **Pluggable harness** — the agent CLI fleet drives is selectable per agent.
  `claude` (full-featured) and `omp` (oh-my-pi, omp.sh) ship today; each is a
  drop-in `harness.d/<name>.conf` describing how to launch it, seed a prompt,
  read its state, and read its cost — so a new harness is a new file, not a code
  change. Pick one with `fleet new <repo> <br> --harness omp` (`-h` for short),
  the dashboard `n`
  form's **Harness** dropdown, or set a default in `~/.config/fleet/config`
  (`harness=omp`) or a project `.fleet/harness`. The **orchestrator** itself is
  selectable too: `fleet up <root> --harness omp` boots the command center with
  an omp driver, and `fleet orchestrator <name>` swaps it **live** on a running
  session — it respawns just the orchestrator pane (the dashboard and every agent
  window keep running; the previous orchestrator's conversation ends). Bare
  `fleet orchestrator` prints the current one. Capabilities vary by tool and
  the UI adapts: harnesses without a permission-mode cycle hide the mode pill +
  `m` key; cost works for any harness that writes a usage log. Harnesses that
  don't emit Claude-style hooks (omp) get their state from a fleetd **scrape**
  loop (the window carries a `busy` regex fleet stamps on it) instead — so
  working/idle still light up with zero integration on the tool's side. The
  **orchestrator guide** is installed harness-neutrally: `fleet up` (and a live
  `fleet orchestrator` switch) writes the same `FLEET.md` content into **both**
  `CLAUDE.md` (claude) and `AGENTS.md` (omp / the cross-tool convention) at the
  project root, so whichever harness drives the orchestrator reads identical
  fleet instructions. A harness can also carry launch flags (`H_ARGS` in its
  `.conf`) — e.g. omp gets `--allow-home` so an orchestrator rooted at `~`
  stays in the project dir instead of auto-jumping to a temp dir (which would
  hide the repos and the guide).
- **Orchestration** — the orchestrator (or you) can `fleet ls`, `fleet new`,
  `fleet send <agent> "msg"` (delivered via nvim RPC into the claude terminal),
  and `fleet mode <agent>` to cycle an agent's permission mode. See `FLEET.md`
  for the orchestrator instructions.
- **Non-blocking waits** — `fleet watch <agents> -m "msg"` lets the orchestrator
  fire-and-forget instead of holding its turn hostage in a `sleep`+`fleet ls`
  poll loop. It returns instantly and arms a *detached* watcher bound to the
  calling pane; when every named agent goes idle (for ~6s straight, so a blip
  doesn't trip it) it injects `msg` into the orchestrator's claude input —
  waking it to read the results and report. Polling happens in the background
  process, not the orchestrator's context. The orchestrator's `CLAUDE.md` now
  instructs it to dispatch, `fleet watch`, and end its turn.
- **Feature menu + keybinds** — `prefix+F` opens a rounded tmux menu listing
  every feature with its key; pick an entry to run it, or "Change a keybind" to
  rebind live. Keys are stored in `~/.config/fleet/keybinds.conf` and
  re-applied on every `fleet up`. `fleet keys` prints them; `fleet rebind`
  changes one from the CLI.

## Keybinds (under tmux prefix)

| Key | Feature |
|---|---|
| `F` | Feature menu |
| `a` | Pick / jump to agent |
| `n` | New agent (prompts for `repo branch`) |
| `m` | Rebuild command center |
| `R` | Reload the dashboard pane in place (picks up new code, no Claude involved) |
| `l` | List agents |

`prefix+R` works from any pane — handy when the orchestrator Claude is busy and
you don't want to queue `fleet main --reload` behind its work. (The dashboard
pane itself also has an `R` key that self-reloads.)

All defaults; override any in `~/.config/fleet/keybinds.conf` (`action=key`) or
via the menu.

## Install

```sh
./install.sh        # symlinks bins, enables fleetd.service, wires claude hooks
fleet doctor        # verify
fleet up ~/path/to/project-root     # boot a project (any root folder of repos)
```

`install.sh --uninstall` reverses everything.

**No systemd?** `./install.sh --no-systemd` skips the user unit (auto-detected
when `systemctl --user` isn't usable — containers, no user bus). The daemon then
starts on demand: `fleet up`'s `ensure_daemon` runs `nohup fleetd &` whenever the
socket is missing. Everything else (hooks, bins) is identical.

## Layout

| Path | What |
|---|---|
| `bin/fleetd` | unix-socket daemon (`$XDG_RUNTIME_DIR/fleet.sock`), state + tmux mirroring + notifications |
| `bin/fleet` | CLI: `up new fan ls pick send watch mode cost guard browser devport main orchestrator restore menu keys rebind harnesses status doctor` |
| `lib/browser-test.js` | vendored Playwright driver — `fleet browser` drives the system Chromium to test a worker's dev app ([docs](docs/browser-testing.md)) |
| `harness.d/` | one `<name>.conf` per supported agent CLI (claude, omp); drop in a file to add a harness |
| `bin/fleet-hook` | Claude Code hook → daemon reporter + transcript recorder (fail-silent) |
| `bin/fleet-guard` | Claude Code PreToolUse hook → write-guard for tests/CI/lockfiles |
| `bin/fleet-dash` | interactive agent dashboard for the command center (the right pane of `main`) |
| `nvim/fleet.lua` | loaded into spawned nvim via `--cmd` — claude autostart + `FleetSend()` + `FleetCycleMode()` |
| `FLEET.md` | orchestrator instructions, copied to project `CLAUDE.md` by `fleet up` |

Projects are any root folder containing repos; repos are auto-discovered
(plain repos, worktree containers, bare-repo containers). Pin a root with
`~/.config/fleet/projects/<name>.yml` (`root: ~/path`).

## State model

Hook events → state: UserPromptSubmit/PreToolUse → working,
PermissionRequest/Notification → blocked, Stop/SessionStart → idle,
SessionEnd → release. Multiple claude sessions in one pane aggregate by
severity (blocked > working > idle). Dead panes are swept every 60s.
Subagent events never mark the parent pane done (herdr lesson, kept verbatim).

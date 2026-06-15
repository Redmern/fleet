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

  The `n` form's **Repo** and **Base** are dropdowns: `←/→` cycles or `Enter`
  opens a scrollable picker. Repo lists the project's repos; Base lists that
  repo's branches (default branch first) — the new branch is created off it
  (passed to `fleet new --base`). Changing Repo reloads the Base list.

  `d` tears down the selected agent: a confirm popup offers *close window*
  (keep files), *remove worktree*, or *force remove*. Removing a worktree with
  uncommitted/untracked changes is refused unless you pick force — the agent
  window is still closed, the worktree is kept.

  `fleet main --reload` restarts just the dashboard process in place (same pane,
  size, and position) — handy after editing `fleet-dash`. The orchestrator pane
  and every agent window keep running; no work is lost.
- **Orchestration** — the orchestrator (or you) can `fleet ls`, `fleet new`,
  `fleet send <agent> "msg"` (delivered via nvim RPC into the claude terminal),
  and `fleet mode <agent>` to cycle an agent's permission mode. See `FLEET.md`
  for the orchestrator instructions.
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
| `l` | List agents |

All defaults; override any in `~/.config/fleet/keybinds.conf` (`action=key`) or
via the menu.

## Install

```sh
./install.sh        # symlinks bins, enables fleetd.service, wires claude hooks
fleet doctor        # verify
fleet up ~/path/to/project-root     # boot a project (any root folder of repos)
```

`install.sh --uninstall` reverses everything.

## Layout

| Path | What |
|---|---|
| `bin/fleetd` | unix-socket daemon (`$XDG_RUNTIME_DIR/fleet.sock`), state + tmux mirroring + notifications |
| `bin/fleet` | CLI: `up new ls pick send mode main restore menu keys rebind status doctor` |
| `bin/fleet-hook` | Claude Code hook → daemon reporter (fail-silent, ~1ms when fleet is down) |
| `bin/fleet-dash` | interactive agent dashboard for the command center (the right pane of `main`) |
| `bin/fleet-tile` | legacy single-pane tile renderer — no longer used by `main`, kept for a future preview pane |
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

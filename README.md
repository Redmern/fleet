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
- **Desktop notifications** — notify-send when an agent blocks or finishes
  while its window isn't focused (30s cooldown, flap guard).
- **Command center** — `fleet main`: orchestrator claude at the project root on
  the left, live read-only tiles of every agent on the right (capture-pane
  polling, nvim panes clipped to the claude split).
- **Orchestration** — the orchestrator (or you) can `fleet ls`, `fleet new`,
  and `fleet send <agent> "msg"` (delivered via nvim RPC into the claude
  terminal). See `FLEET.md` for the orchestrator instructions.
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
| `bin/fleet` | CLI: `up new ls pick send main menu keys rebind status doctor` |
| `bin/fleet-hook` | Claude Code hook → daemon reporter (fail-silent, ~1ms when fleet is down) |
| `bin/fleet-tile` | live tile renderer for the command center |
| `nvim/fleet.lua` | loaded into spawned nvim via `--cmd` — claude autostart + `FleetSend()` |
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

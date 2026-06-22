# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> This file does double duty. The **orchestrator capabilities** section at the
> bottom is the verbatim content of `FLEET.md`, which `fleet up` installs as a
> project's `CLAUDE.md` so the orchestrator Claude learns the `fleet` CLI. Keep
> that section in sync with `FLEET.md` when you change orchestration commands.
> Everything above it is guidance for developing fleet itself.

## What this is

Fleet is a standalone manager for a personal "fleet" of Claude Code coding
agents, each running in its own tmux window (nvim + claude split) on its own git
worktree. Fleet only *calls* tmux/nvim/git/claude — it embeds none of them.
**Every integration is fail-silent:** if the daemon, tmux, nvim, or claude is
missing, each command degrades to a working subset rather than erroring. Preserve
this property in any change — guard external calls and `exit 0` / fall back on
failure rather than propagating errors.

## No build, no test suite

There is nothing to compile and no test runner. The deliverables are scripts run
directly via symlinks in `~/.local/bin`:

- `./install.sh` — symlink bins, install + enable the systemd user unit, and
  idempotently wire the Claude Code hooks into `~/.claude` and
  `~/.claude_personal` `settings.json`. `./install.sh --uninstall` reverses all.
- `fleet doctor` — verify dependencies (tmux, nvim, git, python3, fzf), the
  daemon socket, hook wiring, and the systemd unit. Use this as the smoke test.
- `fleet up <project-root>` — boot a project session (orchestrator + command center).
- After editing `bin/fleet-dash`, reload it in place with `fleet main --reload`
  or tmux `prefix+R` — no need to restart the session or the orchestrator.
- `systemctl --user restart fleetd` after editing `bin/fleetd`; tail it with
  `journalctl --user -u fleetd -f`.

Languages: `bin/fleet` and `bin/fleet-dash` are **bash**;
`bin/fleetd` is **Python 3 (stdlib only)**; `bin/fleet-hook` and `bin/fleet-guard`
are **POSIX sh**. Keep `fleetd` stdlib-only and the hooks fast and dependency-light
(they run on every Claude hook event).

## Architecture

Five cooperating processes plus an nvim plugin, communicating through a Unix
socket and tmux options — there is no shared in-process state.

- **`bin/fleetd`** — the only long-lived process. A stdlib daemon on
  `$XDG_RUNTIME_DIR/fleet.sock` speaking newline-delimited JSON. It owns agent
  state keyed by tmux pane id, mirrors it into per-window tmux user options
  (`@agent_state` / `@agent_since` / `@agent_glyph`) for the status bar, sends
  desktop notifications when an unfocused agent blocks/finishes, and sweeps dead
  panes every 60s. RPC methods: `agent.report`, `agent.release`, `fleet.list`,
  `fleet.ping`.
- **`bin/fleet-hook`** — wired into Claude Code's hooks by `install.sh`. Maps
  hook events to states and reports them to the daemon:
  UserPromptSubmit/PreToolUse → `working`, PermissionRequest/Notification →
  `blocked`, Stop/SessionStart → `idle`, SessionEnd → `release`. **Subagent
  events must never mark the parent pane done** (a hard-won lesson carried over
  from the predecessor "herdr" — keep the subagent filtering intact).
- **`bin/fleet-guard`** — opt-in PreToolUse hook. No-op unless `fleet guard on`
  created `~/.config/fleet/guard-on`. Asks before edits to tests/CI/lockfiles and
  hard-denies paths flagged with a leading `!` in `.fleet/protected` (or
  `~/.config/fleet/protected`).
- **`bin/fleet`** — the user/orchestrator CLI; the bulk of the logic. Subcommands
  dispatch at the bottom `case` block to `cmd_*` functions. It is mostly
  stateless: it reads live agent state from the daemon (`agents_tsv` calls
  `fleet.list`, falling back to tmux `@agent_state` options when the daemon is
  down) and shells out to tmux/git/nvim.
- **`bin/fleet-dash`** — the interactive dashboard, the right pane of the `main`
  window. Self-refreshing TUI that consumes `fleet agents` (raw TSV) and drives
  tmux. The orchestrator Claude runs in the left pane.
- **`nvim/fleet.lua`** — loaded into each spawned nvim via `--cmd`. Provides
  claude autostart (`FLEET_AUTOCLAUDE` / `FLEET_PROMPT` env), `FleetSend()`
  (delivers `fleet send` messages into the claude terminal via RPC), and
  `FleetCycleMode()`.

### State and persistence

State lives in three places, none of them a database:

- **Live agent state** — in `fleetd`'s memory, mirrored to tmux window options.
- **Per-session saved agents** — `~/.config/fleet/sessions/<session>.agents`
  (tab-separated: dir, repo, branch, bare, base, harness). Written on `fleet new`, read by
  `fleet restore` to respawn agents whose windows vanished after a tmux/server
  restart. Teardown (`forget`) drops the line.
- **Config** — `~/.config/fleet/`: `keybinds.conf` (`action=key`, re-applied on
  every `fleet up`), `projects/<name>.yml` (`root:` to pin a project root),
  `guard-on` marker, `protected` glob list.
- **Done markers** — `<worktree>/.fleet/ready` (written by `fleet ready` when a
  work item is finished). Read by `agents_tsv`/the dashboard to show the agent as
  `done`, and consumed by `fleet reap`, which removes flagged worktrees (skipping
  unmerged/dirty ones). The dirty check ignores `.fleet/` so the marker itself
  never blocks a reap.

### Worktree / repo layout (`cmd_new`)

A "project" is any root folder of repos; repos are auto-discovered. `fleet new`
resolves the repo then picks a layout: a **plain working repo** is used in place
(no worktree); a **bare-repo container** or a **worktree container** gets a new
worktree at `<repo>/<branch-with-slashes-as-underscores>`, anchored off the
container's bare repo or first worktree, cut from `--base` (or the remote default
branch). Branches with `/` become `_` in directory and window names.

### Permission-mode discovery (notable)

Claude only exposes mode *cycling* (Shift+Tab), not "set mode X". `cmd_mode`
cycles one step per call. The dashboard's `m` popup presents the modes from the
static `MODES` list (`bin/fleet-dash`) — the verified Shift+Tab cycle order
`default → accept-edits → plan → auto` (looping; `bypass` is **not** in the
Shift+Tab cycle). It then drives the agent toward the chosen mode with
`apply_mode`, which reads the live footer after each press — so even if a claude
version reorders the cycle, the agent still lands on the right mode and `MODES`
only governs the picker's display order. Sending into nvim agents prefers
headless nvim RPC (`FleetCycleMode`), falling back to tmux `send-keys BTab`
(focus-dependent).

## Conventions

- Match the existing fail-silent style: `2>/dev/null`, `|| true`, `|| return 0`,
  `|| exit 0` around every tmux/git/nvim/notify call.
- `fleetd` swallows all tmux/notify errors — it must never take anything else
  down with it.
- Keep `bin/fleet`'s subcommand `case` dispatch and the `cmd_*` function names in
  sync; several are internal (`agents`, `repos`, `branches`, `worktrees`,
  `forget`, `watch-run`) and consumed by the dashboard or detached watchers.

---

# Fleet — orchestrator capabilities

You are running inside a fleet command center, where you act as a
**coordinator, not a worker**. You manage coding agents in other tmux windows of
this project with the `fleet` CLI.

> These instructions are read by **every** orchestrator harness (claude reads
> them from `CLAUDE.md`, omp and others from `AGENTS.md`), so they are written
> agent-neutral. Capabilities only some harnesses support are noted inline.

- `fleet ls` — list THIS project's agents: state (working/blocked/idle), repo/branch, window. `--all`/`-a` lists every project on the server.
- `fleet new <repo> <branch> [-p "task"] [--bare] [--base <branch>] [--harness|-h <name>] [--self-merge]`
  — spawn an agent: creates a git worktree for `<branch>` if needed, opens a tmux
  window (editor + agent split by default, `--bare` for a plain agent pane), and
  seeds it with the `-p` prompt. `<repo>` is a repo name/alias in this project
  root. `--harness` (alias `-h`) picks the agent CLI (`claude` default, or `omp`,
  …; see `fleet harnesses`). By default a worker may **not** `git merge`/`git push`
  (fleet-guard blocks it — you review the diff and integrate); pass `--self-merge`
  to grant *that* worker merge/push rights for its branch.
- `fleet new --scratch [label] [-p "task"] [--harness|-h <name>]` — spawn a
  **repo-less** agent: no repo, branch, or worktree, just a plain agent pane at
  the project root. `[label]` names the window (default `scratch`). Use for
  throwaway/helper agents not tied to a checkout.
- **`$FLEET_DOCS`** — every spawned worker gets this env var: an absolute,
  per-branch scratch-docs dir (`<worktree>/.fleet/notes`, git-ignored so it never
  dirties or clutters the repo; archived to `<root>/.fleet/notes/archive/…` on
  `fleet reap`). When you dispatch, **instruct the worker in its `-p` prompt** to
  write research/plans/architecture/scratch markdown to `$FLEET_DOCS` instead of
  the repo root — keeps returned diffs clean.
- `fleet send <agent> "message"` — send a follow-up message into a running
  agent's input. `<agent>` matches window name or repo/branch.
- `fleet mode <agent>` — cycle that agent's permission mode one step. Only for
  harnesses that expose permission modes (e.g. claude); a no-op for harnesses
  like omp that have none.
- `fleet watch <agent>... -m "message"` — **don't busy-poll.** Returns
  immediately and arms a background watcher; when every named agent goes idle it
  delivers `"message"` into your pane, waking you. Use this to wait on agents
  without burning your own turn in a `sleep`/`fleet ls` loop.
- `fleet ready [<agent>] [-m "reason"]` — signal that a work item is **done and
  its worktree is ready for deletion.** A worker runs bare `fleet ready` from
  inside its own worktree; you flag someone else's with `fleet ready <agent>`.
  This drops a `.fleet/ready` marker, so the agent shows as `done` in `fleet ls`
  and the dashboard. `--clear` removes the flag.
- `fleet reap [<target>] [--force]` — remove every worktree flagged ready (close
  its window, delete the worktree and its merged branch). Refuses any worktree
  with uncommitted changes or a branch not merged into its base unless `--force`.

## Leader menu (which-key)

The command center has a which-key-style **leader menu**: a grouped popup of
one-key actions. Open it with **prefix+Space** (works from any pane, including
this orchestrator pane), with **prefix+F** as a secondary alias, or by pressing
**bare Space while the dashboard pane is focused**. Press the shown key to run an
action; **Esc/q/Space** closes. Actions are grouped **+Agents** (pick `a`, new
`n`, ready `y`, reap `x`, orchestrator `m`, rebuild `M`), **+Inbox** (view `i`),
**+Session** (save `s`, sessions `o`, reload `R`, quit `Q`), and **+Info** (ls
`l`, keys `?`, rebind `c`). `fleet keys` lists every binding; `fleet rebind`
(or the menu's `c`) changes one. Per-agent verbs (send, mode, diff, close) stay
on the dashboard's selected row, not in the leader.

## Delegate first

Your default move for any non-trivial request is to **delegate**, not to do the
work yourself. Do small, simple things directly: quick reads/greps to understand
a request, answering questions, status checks (`fleet ls`), a tiny single-file
edit, dispatching work, reviewing returned diffs, merges. Rule of thumb: if it's
more than a couple of quick steps or touches real implementation, delegate.

Delegate in preference order:
1. **Fleet agents** — the primary mechanism. Split the request into per-repo
   tasks and `fleet new` one agent per task with a precise prompt, then wait with
   `fleet watch` and end your turn (see below).
2. **Harness sub-agents** — where your harness supports them, for in-context
   research or parallel search.
3. **Background agents** — where supported, for long-running async work.

To wait for fleet agents, **never** loop on `sleep` + `fleet ls` (it holds your
turn hostage for minutes and burns context). After dispatching, run one
`fleet watch <agents> -m "<what to do when they finish>"` and **end your turn** —
tell the user you've dispatched and will report when done. The watcher pings you
when they're all idle; you resume then, read their results with `fleet ls` /
their diffs, and report consolidated status.

When a delegated task is finished, the worker (or you) flags its worktree with
`fleet ready`; once you've reviewed and merged the diff, `fleet reap` clears out
all the finished worktrees in one step (it refuses unmerged or dirty ones).

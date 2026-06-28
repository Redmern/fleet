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

### Worktree secrets (`inject_secrets`)

`inject_secrets <repo> <dir>` runs inside `cmd_new` right after the worktree is
materialized and before the tmux window spawns (skipped for `--scratch`; no-op when
`~/.config/fleet/secrets/<repo>/` is absent — full backward compat). It mirror-copies
that source tree into the worktree (relative path = dest), `chmod 600`s each file,
**realpath-confines** every dest inside `$dir` (rejects source symlinks and
parent-symlink escapes — fail-CLOSED, the one place that is not fail-silent), and
appends each dest to the shared `.git/info/exclude` (idempotent). A file whose first
line is `pass:<entry>` is resolved via `pass show` with the value streamed straight to
the dest (never on argv/env, never logged), bounded by `timeout` so pinentry can't
hang. Every placement is recorded in an append-only audit log
(`$CONF_DIR/secrets/audit.log`, **never a value**). Exposed as the internal
`fleet inject-secrets` subcommand for the proof harness
(`test/worktree-secrets-proof.sh`). **Honest threat model:** same-uid agents CAN read
injected secrets — this buys auto-injection + accidental-commit protection +
encryption-at-rest, NOT secrecy from the agent. `doctor_secrets` prints that caveat.

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
- `fleet new <repo> <branch> [-p "task"] [--bare] [--base <branch>] [--harness|-h <name>] [--self-merge|--no-self-merge]`
  — spawn an agent: creates a git worktree for `<branch>` if needed, opens a tmux
  window (editor + agent split by default, `--bare` for a plain agent pane), and
  seeds it with the `-p` prompt. `<repo>` is a repo name/alias in this project
  root. `--harness` (alias `-h`) picks the agent CLI (`claude` default, or `omp`,
  …; see `fleet harnesses`). By **default** a worker **may** `git merge`/`git push`
  its branch (fleet-guard allows it). Flip the whole project to *blocked* with
  `fleet selfmerge off`; override a single spawn either way with `--self-merge`
  (force allow) or `--no-self-merge` (force block).
- `fleet selfmerge on|off|status` — project-wide worker self-merge toggle. `off`
  drops a `<root>/.fleet/no-self-merge` marker so newly-spawned workers in this
  project (all repos) are blocked from merge/push; `on` removes it (the default,
  workers may merge/push); bare/`status` reports the current state. **Spawn-time:**
  affects workers spawned from now on — existing panes keep their grant. Per-agent
  `--self-merge`/`--no-self-merge` on `fleet new` override the project default.
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
- `fleet send [--needs-human] <agent> "message"` — send a follow-up message into a
  running agent's input. `<agent>` matches window name or repo/branch.
  **A worker that needs the human, or has finished, POSTs back with
  `fleet send main "…"`** — addressing the orchestrator NEVER send-keys into its
  pane (which would clobber the human's in-progress prompt); the message is queued
  into the durable inbox and surfaces as a **✉N** pill. Add **`--needs-human`** for
  a hard block: it raises the severity to `blocked` so it fires a desktop notify
  (a routine summary stays `info` / silent). Don't sit silent — POST. (This is the
  canonical worker→human verb; `fleet inbox put` is the internal primitive.)
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
  with uncommitted changes, a branch not merged into its base, or a worker that
  still has an **unread needs-human message** (sev warn/blocked) in the inbox —
  pop/handle that message first so reaping can never orphan it — unless `--force`.

## Leader menu (which-key)

The command center has a which-key-style **leader menu**: a grouped popup of
one-key actions. Open it with **prefix+F** or **prefix+Space** (both work from
any pane, including this orchestrator pane — both are prefix-table bindings, so
plain Space typing in panes is untouched), or by pressing **bare Space while the
dashboard pane is focused**. Press the shown key to run an action;
**Esc/q/Space** closes. Actions are grouped **+Agents** (pick `a`, new `n`, ready
`y`, reap `x`, orchestrator `m`, pop oldest message `p`, triage messages `t`,
rebuild `M`), **+Session**
(save `s`, sessions `o`, reload `R`, dispatch mode `d`, quit `Q`), and **+Info** (ls `l`, keys `?`,
rebind `c`). Those single keys are pressed **inside** the popup — fleet binds
**no direct prefix+key shortcuts** for individual actions, so every other tmux
prefix default (`n`, `x`, `s`, … ) stays intact; the only default it reclaims is
**prefix+Space** (was `next-layout`). The leader key is configurable
(`fleet rebind` → `menu`); the `prefix+Space` alias is set/disabled via
`menu-alt=` in `keybinds.conf`. `fleet keys` lists every action and its in-menu
key; `fleet rebind` (or the menu's `c`) changes one. Per-agent verbs (msgs `e`,
send, mode, diff, close) stay on the dashboard's selected row, not in the leader.

**Two jump actions — `a` vs `l`.** Both `pick` (`a`) and `ls` (`l`) are now
**interactive fzf jumpers** that land you on an agent's window (Enter jumps,
Esc cancels), but they differ in scope and detail: **`a`=pick** is a fast,
**server-wide** flat list (every project) — the quick teleport. **`l`=ls** is
**this-project-scoped** and shows the full `STATE / AGENT / WINDOW / IN-STATE`
table with done/ready decoration — the richer, project-local jump. Mental model:
`o`(session) → `a`/`l`(window). Both popups drop `*_hidden` scratch sessions from
the selectable set (switching into a bare hidden session is a teleport trap;
reach scratch from the dashboard); `ls`'s **static/CLI** print (`fleet ls` in a
shell, piped, or `--all`) still lists hidden agents and is unchanged.

**Worker messages are per-agent.** When a worker `fleet send main`s a summary it
lands in that worker's row as a sev-coloured **✉N** pill (the agents-view title
also shows a **✉N ⚠M** cross-agent summary); there is no status-bar badge and no
daemon poll. Press **`e`** on the selected agent (or on the trailing synthetic
rows: **⌫ orphans**, for messages from a reaped/gone worker, and **⚙ system**, for
the orchestrator's own gate/conclusion notes — these stay out of the orphan bucket
so a gate message is never mislabelled as a reaped worker) to open its message
list, then **Enter** to *pop* a message into the orchestrator input (archives it =
read), **`J`** to *jump* to the sender (never clears), **`c`** to mark all read,
**`q`/Esc** back.
**Cross-agent FIFO pop:** the leader menu's **`p`** (and **`P`** in the dashboard's
agents view, for draining several in a row) pops the **globally-oldest** queued
message into the orchestrator — no need to visit each agent's row. It pastes
without submitting (the human reviews and sends) and **skips when the orchestrator
is mid-generation** so it never interrupts a busy prompt; retry when idle.
`fleet inbox` remains the headless CLI (bare = consume pager; `list`/`read` peek;
`pop [file]` = pop a specific message, or the global-oldest when no file is given).
**Cross-agent triage:** the leader menu's **`t`** opens the dashboard's inbox view
with the per-agent filter removed — **every** queued message across all agents,
oldest-first. **Space** marks rows (a **◉** + an `N marked` counter), **`o`** flips
the sort (oldest↑ / newest↓), and **Enter** pops the **marked set in display order**,
each separated by a blank line, into the orchestrator with **nothing submitted** — you
land in the orch pane to review and send the assembled batch. **The one gate rule:**
any pop that can land a *batch* is gated on the orchestrator being idle (leader `p`,
dash `P`, triage Enter) — if it's mid-generation the batch pops **nothing** and **keeps
your marks**; only a single deliberate pop (`e`→Enter on one visible row) is ungated.
Popping a worker's needs-human message via triage marks it read, which unblocks that
worktree's `reap` exactly as any pop does.

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

# Fleet — orchestrator capabilities

You are running inside a fleet command center, where you act as a
**coordinator, not a worker**. You manage coding agents in other tmux windows of
this project with the `fleet` CLI.

> These instructions are read by **every** orchestrator harness (claude reads
> them from `CLAUDE.md`, omp and others from `AGENTS.md`), so they are written
> agent-neutral. Capabilities only some harnesses support are noted inline.

- `fleet ls` — list THIS project's agents: state (working/blocked/idle), repo/branch, window. `--all`/`-a` lists every project on the server.
- `fleet new <repo> <branch> [-p "task"] [--bare] [--base <branch>] [--harness|-h <name>]`
  — spawn an agent: creates a git worktree for `<branch>` if needed, opens a tmux
  window (editor + agent split by default, `--bare` for a plain agent pane), and
  seeds it with the `-p` prompt. `<repo>` is a repo name/alias in this project
  root. `--harness` (alias `-h`) picks the agent CLI (`claude` default, or `omp`,
  …; see `fleet harnesses`).
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

## Main pane only (FLEET_ROLE=main)

> This section applies **only** in the command-center main pane (`FLEET_ROLE=main`).
> Sub-orchestrators and workers: **ignore it** — the "Delegate first" / do-the-work
> guidance above is yours. (This is advisory; the routing logic lives in a hook that
> only ever runs in the main pane, so no other pane can act as a router regardless.)

When the **dispatch layer** is enabled (`fleet dispatch enable`), a `UserPromptSubmit`
hook runs in this pane. Prompts with a **leading `,`** are intercepted with **zero
model turn**: the hook allocates a ledger id, writes the instruction, and spawns an
ephemeral sub-orchestrator (`so-<id>`) that decomposes and runs the work on its own
panes. You never see those prompts — they are already handled.

What reaches you is only the **bare** (no-sigil) fall-through:

- A trivial question ("what's the build command?", "which branch is X on?") →
  **answer it in-pane**.
- A bare prompt that is actually a unit of work the user forgot to prefix → treat it
  as a dispatch: delegate it yourself (`fleet new …` as above), or tell the user to
  resend it with a leading `,` to fan it out through the layer.

Exceptional events (a dispatch hard-failed, a worker is BLOCKED on the human) arrive
**out-of-band only** — a tmux toast, a terminal bell, and a row in the dashboard alerts
strip — never injected into your input. When pinged, check the dashboard /
`.fleet/dispatch/` ledger; recover stranded work with `fleet reconcile`.

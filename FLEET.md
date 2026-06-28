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

## Main pane only (FLEET_ROLE=main)

> This section applies **only** in the command-center main pane (`FLEET_ROLE=main`).
> Sub-orchestrators and workers: **ignore it** — the "Delegate first" / do-the-work
> guidance above is yours. (This is advisory; the routing logic lives in a hook that
> only ever runs in the main pane, so no other pane can act as a router regardless.)

When the **dispatch layer** is enabled (`fleet dispatch enable`), a `UserPromptSubmit`
hook runs in this pane and intercepts prompts with **zero model turn**: it allocates a
ledger id, writes the instruction, and spawns an ephemeral sub-orchestrator (`so-<id>`)
that decomposes and runs the work on its own panes. You never see those prompts — they
are already handled.

**Which prompts get dispatched is set by `fleet dispatch mode`:**

- `sigil` (default) — **opt-in**: a prompt with a **leading `,`** dispatches; a bare
  prompt falls through to you in-pane.
- `all` — **the dispatch-everything front door (opt-out)**: **every** bare prompt is
  dispatched (your pane returns to ready the instant you press Enter — never tied up
  running a pipeline); a prompt with a **leading `\` (escape sigil)** is the exception,
  answered **inline** in your pane for a quick question/status check.
- `off` — the layer is dormant; everything falls through in-pane.

Set/inspect it with `fleet dispatch mode [sigil|all|off]` (bare prints the current
mode; `fleet dispatch status` also reports it). Or flip it from the **leader menu**:
**+Session → `d`** opens a picker showing the current mode and whether the hook is
wired, then off/sigil/all in one keystroke (sigil/all wire the hook first).

What reaches you in-pane is only the fall-through (a bare prompt under `sigil`, or an
escaped `\…` prompt under `all`):

- A trivial question ("what's the build command?", "which branch is X on?") →
  **answer it in-pane**.
- A bare prompt that is actually a unit of work the user forgot to prefix (under
  `sigil`) → treat it as a dispatch: delegate it yourself (`fleet new …`), or tell the
  user to resend it with a leading `,` to fan it out through the layer.

### Gated pipelines (the two human gates)

A dispatched feature run through the `fleet-implementation-pipeline` skill **stops
twice and waits for you**, surfacing each decision as a **✉ pill** in the dashboard
inbox (posted at `sev warn`, so a desktop notify fires):

- **🚧 GATE 1 — approve the plan.** The sub-orch posts a plain-English plan + proof
  design, then **parks** (ends its turn). **Pop** the message (`e`→Enter on its row, or
  the leader `p` FIFO drain) to approve → the approval routes **back to that sub-orch**
  and auto-submits, and test-first implementation begins. Type a course-correction
  instead → a fresh prompt; nothing is built.
- **🚧 GATE 2 — approve the merge.** After the tests are green the sub-orch posts *how
  the tests prove it* + manual-test steps, with the **merge target baked in**
  (`fleet integration-branch`; absent ⇒ `main`), then parks. **Pop** = "merge + push to
  that branch"; the sub-orch reviews the diff, merges, and `fleet ready`s. Type a defect
  → it loops and builds further on what's there.

A pipeline **never advances past a gate on its own** — only your pop moves it. A sub-orch
parked at a gate carries a ledger `state=gate{1,2}-wait`, and **`fleet reap` skips it**
(alongside the existing unread-needs-human guard) so a parked pipeline is never
torn down before you pop. Gate mechanics for the sub-orch side live in
`FLEET_SUBORCH.md §7`.

Exceptional events (a dispatch hard-failed, a worker is BLOCKED on the human) arrive
**out-of-band only** — a tmux toast, a terminal bell, and a row in the dashboard alerts
strip — never injected into your input. When pinged, check the dashboard /
`.fleet/dispatch/` ledger; recover stranded work with `fleet reconcile`.

## Worktree secrets (per-repo auto-injection)

Keep per-repo secret files in one place and have fleet drop them into **every** new
worktree it creates — so a fresh debug worktree already has its `.env.local` / DSN at
the right path, no pasting into a prompt.

**Setup (default mechanism — a mirrored folder, no schema):**
```sh
mkdir -p ~/.config/fleet/secrets/<repo>
$EDITOR ~/.config/fleet/secrets/<repo>/.env.local      # lay files out exactly as the worktree wants them
```
On `fleet new <repo> <branch>`, fleet mirror-copies that tree into the worktree (the
file's path **relative to** `secrets/<repo>/` IS its destination), `chmod 600`s each
file, and appends each dest to the worktree's `.git/info/exclude` so a secret can never
be accidentally committed. Re-running is idempotent (overwrites, no duplicate ignore
lines). `--scratch` agents and repos with no `secrets/<repo>/` dir are untouched.

**Optional `pass` sugar (encryption-at-rest):** if a file's content is exactly
`pass:<entry>` (e.g. `pass:fleet/myapp/db-url`), fleet resolves it with `pass show` at
injection and writes the decrypted value instead (value streamed straight to the file —
never on a command line, never logged). Store the secret encrypted with
`pass insert fleet/myapp/db-url` once.

**Fail-silent:** a missing source, locked gpg, or absent `pass` only warns — it never
aborts `fleet new` and never hangs on a pinentry prompt. Every placement is recorded in
an append-only audit log (`~/.config/fleet/secrets/audit.log`, timestamp/repo/dest/outcome,
**never the value**). `fleet doctor` reports `pass` state and whether referenced entries
resolve (no decrypt).

**Honest threat model — read this.** On a single-user box the agent runs as the **same
uid** as you, so it **CAN** `cat` an injected file or run `pass show` itself. This feature
buys **auto-injection + accidental-commit protection + encryption-at-rest** — it does
**NOT** make the secret unreadable by the agent, and is not documented as such. Genuine
"the AI cannot read it" is impossible same-uid and would need a separate uid for both
placement and the consuming process (a much larger, separate project).

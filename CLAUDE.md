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
  unmerged/dirty ones). The dirty check ignores only **untracked** (`??`)
  `.fleet/` entries so the marker itself never blocks a reap — a *tracked*
  `.fleet/` path with local edits is real user work and still refuses.

### Ledger state: terminal vs parked (`ledger_terminal` / `ledger_parked`)

Dispatch ledger state is classified in **exactly one place**: `ledger_terminal`
(`done|failed|cancelled`) and `ledger_parked` (`gate1-wait|gate2-wait`). Three
consumers hand-rolled this before and diverged, which *was* a bug: `cmd_reconcile`
skipped only the terminal set, so a sub-orch parked at a human gate looked
"non-terminal + dead window = stranded" and got respawned — and the fresh sub-orch
read the instruction and ran straight **past** the gate (4 of 5 dispatches on
2026-07-19; one self-merged to main). Meanwhile `gate_waiting`, which `cmd_reap`
consults, already treated those states as parked-leave-alone. **parked != terminal
!= stranded.** `cmd_reconcile` now skips revival for both sets; a parked dispatch
whose sub-orch pane is **dead** is never revived *and* never silently dropped —
`gate_orphan_escalate` surfaces it once (system-origin `--from -` inbox message →
⚙ system row + desktop notify, plus a dashboard alert), one-shot via a
`gate_orphan` ledger flag that re-arms when the pane comes back. The wake path's
`suborch_ledger_active` shares `ledger_terminal` but deliberately **not**
`ledger_parked`: a gate-parked sub-orch losing its pane is exactly when the human
most needs the nudge. Locked in by `test/reconcile-gate-park-proof.sh` (9 cases).

### Reap is atomic (`cmd_reap`)

`cmd_reap` is split into **DECIDE** (pure reads: the ready marker, target match,
linked-worktree, dirty, merged, inbox, gate-wait, worktree-**lock**, plus resolving
the window to kill) and **MUTATE**. Nothing destructive happens until
`git worktree remove` has *succeeded*; only then does it run `branch -D` →
`safe_kill_window` → `cmd_forget`. Scratch docs are archived by **`cp -a` into a
freshly-made stage dir, never `mv`** — moving a *tracked* note deletes it from the
worktree, which dirties the tree and makes removal refuse: reap dirtying the tree
and then refusing because the tree is dirty (the orphan bug). The only pre-remove
deletion is on an **exclude-less** worktree (`git check-ignore -q .fleet/` fails),
where fleet's own untracked markers would block removal; that path — and only that
path — carries a rollback that restores the notes and the marker and, if the
marker cannot be restored, prints the exact `touch` recovery to stderr. Net
contract: **any refusal leaves worktree + window + agents line + marker intact, so
a plain re-run is the retry.** Locked in by `test/reap-tracked-notes-proof.sh`
(19 cases) and `test/reap-teardown-safety.sh` (8).

### Worktree / repo layout (`cmd_new`)

A "project" is any root folder of repos; repos are auto-discovered. `fleet new`
resolves the repo then picks a layout: a **plain working repo** is used in place
(no worktree); a **bare-repo container** or a **worktree container** gets a new
worktree at `<repo>/<branch-with-slashes-as-underscores>`, anchored off the
container's bare repo or first worktree, cut from `--base` (or the remote default
branch). Branches with `/` become `_` in directory and window names.

### Hidden agents: `session_name` (identity) vs `project_session` (targeting)

"Hidden" is **physical parking**, not an attribute: tmux has no per-window
"don't draw this on the bar" option and — decisively — no skip-in-next/prev
flag, so a `--scratch` spawn is *moved* into the detached sibling session
`<sess>_hidden` (`cmd_new`) and marked `@fleet_hidden` (1=system, 2=user via
`cmd_hide`, 0=surfaced). Living outside the visible session is what makes it both
off-bar **and** unreachable by `C-b n`. `agents_tsv` and `fleetd` use
`list-panes -a` (server-global), so the daemon and dashboard still see it and
render a normal `(hidden)`-tagged row.

Two questions look identical here and are not:

- **`session_name()`** — *which session is MY pane in?* (identity). Unchanged.
- **`project_session()`** — *which session does this PROJECT live in?*
  (targeting). Every site that targets or scopes a session wants this one:
  `cmd_new`'s parking base, `--switch` move-in, **worker window target and
  `persist_agent`**, `cmd_hide`, `cmd_unhide`, `cmd_ls`'s scope, `cmd_send`'s
  fan-out scope, `sessions_rows`, **`cmd_restore`**, **`cmd_forget`**.

`cmd_new` resolves it **once**, at the top, into `psess` (the project) and
`tsess` (where the window will physically land — `psess` or its parked sibling).
Everything downstream reads those, so the window target, the name-collision
check and the saved-agents file can never disagree about which session a spawn
belongs to. That disagreement was a second live bug: only the *scratch* branch
was converted at first, so a sub-orch-spawned **code worker** still landed in
`<sess>_hidden` — off the bar, unreachable by `C-b n` — and, durably, persisted
to `<sess>_hidden.agents`, a file `cmd_restore` and `cmd_forget` never read. The
worker was un-restorable after a tmux restart and its saved-agents line
immortal. **Writer and readers must name the same file**, which is why
`persist_agent`, `cmd_restore` and `cmd_forget` all key on `project_session()`.

Conflating them was a live bug. `FLEET_SESSION` is exported only by `fleet up` /
`fleet main` / `fleet restore` — **never** into a spawned pane — so inside a
sub-orchestrator (itself a parked scratch agent) `session_name()` returned
`pc_hidden`, and appending `_hidden` parked its children in `pc_hidden_hidden`.
Nothing looks there: the dashboard's exact depth-1 comparison dropped the row,
`fleet ls`/`fleet send` could not see the project's own workers, and tmux
destroys the depth-1 session the moment its last window leaves — orphaning the
depth-2 one with **no parent left to name it back**. Two such orphans were live
on the machine, one a week old.

`project_session()` strips every trailing `_hidden` and uses the base **only if
tmux confirms that session exists** — it never invents one — **and only if the
caller's own session does not itself look like a fleet project**
(`session_is_project`: does it contain a `main` window? `fleet up` always makes
one; a parking session never has one, since `cmd_hide` refuses to hide `main`).

That second condition is load-bearing and the naive version was wrong. With
genuine projects `a` **and** `a_hidden` both booted, plain stripping resolved
`a_hidden` → `a` and parked `a_hidden`'s own scratch agents back into
`a_hidden` — the caller's **visible** session: on the bar, reachable by `C-b n`,
dashboard `hid=0`, yet stamped `@fleet_hidden 1`. "Hidden" that does not hide.
Be precise about the guarantee: **a genuine fleet *project* named `foo_hidden`
resolves to itself**; a *bare tmux session* named `foo_hidden` with no `main`
window is genuinely indistinguishable from a parking sibling and is still
treated as one. That is the honest limit of what fleet can know from a name.
Belt and braces, `cmd_new` also stamps `@fleet_hidden 0` rather than `1` whenever
the window in fact lands in a real project session — the marker never claims a
hiding that did not happen.

Deliberate non-changes and one added guard:

- **`cmd_quit` stays on `session_name()`** — normalizing it would let a sub-orch
  tear down the human's session. But literal is **not sufficient**: a sub-orch
  lives in the parking session, so its `fleet quit` used to kill `<sess>_hidden`,
  i.e. *every parked agent of the project* — sibling sub-orchs and the human's
  own hidden agents. The human session survived, which is what made the
  collateral easy to miss (the first version of `proof-quit-blast-radius.sh`
  asserted it as correct). `cmd_quit` now **refuses outright when the calling
  pane is parked** (`psess != sess` is exactly "I am parked"). Deliberately
  *not* `is_main_pane`, unlike `cmd_hide`'s guard: quit is reached from the
  leader menu's `Q` → `run-shell`, a server-wide prefix binding that fires from
  the dashboard pane and from any agent window, none of them role=main —
  requiring main would break the menu.
- **`fleet pick` / `ls --pick` keep dropping `*_hidden`** — a `switch-client`
  into a bare parking session is a teleport trap, and the glob is already
  depth-agnostic.
- **`agents_tsv`, `fleetd` and the 9-field TSV are untouched** — every parser is
  positional.

Defence-in-depth for machines that already have nested sessions is **narrow and
deliberate: two places only** — the dashboard's row filter and `fleet up`'s ghost
sweep. Both **strip suffixes** rather than matching one depth, and strip rather
than glob `<sess>_hidden*` (which would also swallow an unrelated
`<sess>_hiddenX`). Everything else — `cmd_ls`'s scope, `cmd_send`'s, and the
`main_pane_for_target` / `window_pane_for` / `suborch_pane_for` lookups — still
compares against exactly `<sess>_hidden`. That is on purpose: widening them would
legitimise nesting in six more filters and hide the next recurrence. The
consequence to know is that on a **pre-fix** machine with a live nested session,
the dashboard draws those agents but `fleet ls` / `fleet send` cannot address
them.

**Do not over-read the sweep.** `fleet up` only reclaims *harness-less* debris —
tmux-resurrect ghosts of dead shells. It deliberately refuses any nested session
whose windows still carry `@fleet_harness`, because that is running work. Every
nested orphan actually on this machine is harness-stamped
(`pc_hidden_hidden` → `d31-…-plan`, `d32-…-plan`; `techweb2_hidden_hidden` →
`d5-…-test-4`, from 2026-07-23), so **the sweep will not touch a single one of
them** — they need a manual drain: finish or kill those windows, then the empty
session goes on the next `fleet up`. What actually rescues them today is the
dashboard's suffix-strip, which renders them; the sweep only stops *new* ghost
debris accumulating.

The dashboard's strip stops **at `$SESS`** rather than peeling every `_hidden` it
can. `$SESS` may itself legitimately end in `_hidden` — that is the genuine
`foo_hidden` *project* case above, which `project_session()` resolves to itself.
Peeling unconditionally reduces that project's own rows to a non-match and empties
its dashboard entirely — caught in review, guarded by the four `SESS=foo_hidden`
rows in `proof-hidden-row-renders.sh` claim B.

The alternative (keep every window in one session; omit hidden ones with a
`window-status-format` conditional) was re-tested on tmux 3.7b and **rejected** —
see the note in `cmd_new` for the four failure modes; the load-bearing one is
that it cannot deliver non-navigability at all.

Locked in by `test/proof-{no-nested-hidden,hidden-row-renders,bar-omits-hidden,
hide-unhide-roundtrip,quit-blast-radius,fail-silent,ghost-sweep-depth,
worker-spawn-session}.sh` (shared isolation preamble in
`test/hidden-proof-common.sh`). Highest-value: `proof-no-nested-hidden.sh` case 2
is the headline regression; `proof-worker-spawn-session.sh` is the only proof
that spawns a **non-scratch** worker, and therefore the only cover for the
`persist_agent` / `restore` / `forget` half; `proof-quit-blast-radius.sh` case 4
is the collateral guard.

Two things to know before trusting a green run:

- The dashboard and sweep proofs `eval` fragments extracted from the real source
  between `# >>> d32:` / `# <<< d32:` markers — **keep those markers.** Deleting
  one fails *loudly* (the extraction is empty and the proof reports it), so this
  is fail-closed, not silently vacuous.
- Extraction always reads `$FLEET_REPO/bin/...` (the checkout next to the
  script) while execution honours `$FLEET_BIN`. The default is correct and they
  are the same tree; point `FLEET_BIN` at another checkout and a proof would
  extract one source while exercising another.

Three of the proofs — `bar-omits-hidden`, `fail-silent`, and the surviving half
of `hide-unhide-roundtrip` — pass on pre-fix code too. That is intended: they
assert invariants the change must not break, not the new behaviour. Six of the
eight go red against `HEAD`.

### Task tag (`--task`, `@fleet_task`) — NOT `role`

`fleet new --task <research|plan|impl|test|scratch>` tags what KIND of work
an agent does, for display only. Three load-bearing constraints:

1. **It is never a TSV column.** The `.agents` line and `fleet agents` are both
   read positionally as exactly **9** fields by three independent readers that all
   fail *silently wrong* on a 10th: `bin/fleet-dash`'s `while IFS=$'\t' read …
   ready` (tab is IFS-whitespace → an empty col 9 collapses, col 10 lands in
   `$ready` → **every** agent renders the `done` pill → a human reaps live work),
   `bin/fleetd`'s hard `len(parts) == 9` (blank dashboard), and `cmd_restore`'s
   `IFS=$'\037' read … owner` (last var absorbs extras → mangled owner → mangled
   `d<N>-` window prefix). There is no schema/version/migration mechanism here and
   a pacman copy runs alongside the dev symlink, so version skew is live. Storage
   is the **`@fleet_task` window option** (live) plus a **window-name-keyed**
   `<root>/.fleet/tasks/<wname>` file (durable across a tmux server restart;
   window name, not pane id — tmux reassigns pane ids, which is why
   `.fleet/roles/<pane-id>` accumulates dead entries). `cmd_restore` re-passes
   `--task` from the file; `cmd_forget` removes it, inside reap's MUTATE phase.
2. **`task` is a separate namespace from `role`.** `FLEET_ROLE`, `.fleet/roles/<pane>`
   and `@fleet_role` all mean orchestrator-vs-worker and all three gate something
   (fork-bomb, merge/push, `is_main_pane`). `main` is not in the task enum, so a
   worker cannot self-promote through this surface.
3. **The enum is closed, validated at the single write site AND re-validated on
   read** (`task_of`). `@fleet_task`'s *contents* are format-expanded by tmux via
   the `window-status-format` token, so an unvalidated value carrying `#[` would
   corrupt the status bar for the **whole tmux server**. Tags are 4 pure-ASCII
   chars (`rsch`/`plan`/`impl`/`test`/`scr `, blank otherwise) because
   `popup_fit_content`, `fit_left` and `hrule` all count **codepoints, not display
   cells**, and there is no ASCII-fallback ladder to degrade to.

Rendered in three places:

- **the tmux status bar** — a second token appended beside `@agent_glyph`, never
  *into* it (`@agent_glyph` is fleetd-owned and rewritten on every state
  transition). Healed by both `inject_status_format` and fleetd's
  `heal_status_format`. It expands a companion **`@fleet_task_tag`** option
  holding the already-rendered tag: a tmux format expands an option's value
  verbatim and cannot map `research`→`rsch` itself, so pointing the token at
  `@fleet_task` would print the full enum word. Both options are stamped at the
  same validated write site; `@fleet_task` stays the canonical machine-readable
  one that `task_of` / the dash / `fleet ls` read.
- **the dashboard row** — a 4-char text field (not a pill: a pill costs `PW+4`=11
  columns), shed **first** in the width ladder so the label is never squeezed, and
  hidden entirely when no visible agent has a task (`HAS_TASKS`), so a task-less
  fleet renders byte-identically to before the flag.
- **`fleet ls`'s TASK column** — resolved in the shell into a `wname<TAB>tag`
  sidecar that awk reads as its first FILENAME; the TSV shape is untouched. The
  tab-separated surfaces use `task_tag_trim` (unset → *empty*, not 4 spaces),
  because a padded field makes `fleet ls | column -t` mis-align that row; the
  padded `task_tag` is only for the dashboard's fixed-width row.

Locked in by `test/agent-task-proof.sh` (22 cases / 36 assertions; the regression
group asserting the 9-field shapes and the absent `done` pill is the highest-value
part).

### Guard: executed command vs inert argument (`fleet-guard` block 1)

The always-on worker merge/push floor asks exactly one question: **is this text a
command being EXECUTED, or an argument that merely mentions it?** Both errors are
real. Scanning raw text denied `fleet new … -p "…git merge…"` — a sub-orch
delegating integration, the sanctioned path — and taught the operator to route
around the guard by stashing the prompt in a file. Scanning only the command word
of each `;`/`&&`/`|` run lets `eval`, `sh -c`, `xargs`, `` ` ` `` and `$V` walk
straight through.

So the parse follows every construct that turns text back INTO a command, and
nothing else: `$(…)`/backtick bodies are **lifted out** of the text (leaving the
surrounding quoting exactly as balanced as it was — rewriting them in place as
`;`-separated statements is what breaks a payload back into false tokens) and
scanned as their own script; `eval`'s args are re-joined and re-parsed; a shell's
`-c` operand is recursed into; `xargs`/`env`/`timeout`/`sudo`/`nohup`/`command`
are transparent prefixes; leading shell keywords are skipped (`then git push` is a
command); simple `V=…` assignments are tracked so an expanded command word
resolves. Quote state is **not symmetric** and the code says so: `$(git push)` runs
inside DOUBLE quotes and is inert inside SINGLE ones.

Unbalanced quotes fall **CLOSED** — a raw regex over the line, the inverse of the
guard's general "on any doubt, allow". A false deny is recoverable by rephrasing;
a false allow merges unreviewed code into main. `FLEET_SELF_MERGE=1` (from
`fleet new --self-merge`) still exempts the pane, and only `role=worker` + `Bash`
is in scope.

Remaining accepted gaps, unchanged in kind: shell functions/aliases, a wrapper
script not named `git`, `find -exec`, and a command word built by expansion we
cannot resolve. This block is a speed-bump against ACCIDENTAL self-merge, not a
sandbox.

Locked in by `test/guard-quoted-payload-proof.sh` (57 assertions, no tmux/daemon —
synthesized hook JSON on stdin). Run it against an older checkout with
`GUARD=<path>/bin/fleet-guard` to see the halves go red: 22 of the DENY cases fail
against `HEAD~`, and the ALLOW half additionally fails against pre-`034bb75` code.

### No agent commits (`ready_instructions`, `FLEET_AUTOCOMMIT`, `cmd_diff_view`)

Workers **stage** (`git add -A`) and never commit; the human reviews the staged tree
and makes the one commit that enters history. The whole design rests on one fact:
**`git add` is not `git commit`, and `git diff HEAD` includes the index.** Staged work
is therefore already visible in every existing surface, still counts as dirty for
`cmd_reap`'s guard, and is one command from shipped. **`git add` must never be
blocked** — every guard here deliberately omits it (also `stash` and `rebase`, so a
worker keeps `rebase --abort` and a non-destructive park).

Five load-bearing pieces:

- **The wording is the real lever, the guard is a backstop.** The whole policy is one
  string (`ready_instructions`), which feeds BOTH the prompt trailer and the durable
  `.fleet/ready-instructions`. It is also the only lever that reaches non-claude
  harnesses: `fleet-guard` is claude-only (`omp` has `H_GUARD_KIND=none`, and that
  variable has no consumer at all), and its tokenizer cannot see `sh -c` / `eval` /
  aliases. Say so in the docs rather than implying a wall. A leak costs one unwanted
  commit on a throwaway branch — not lost work, which is what makes this safe.
- **`fleet autocommit` has POSITIVE marker polarity** (`<root>/.fleet/autocommit`
  present = commits allowed), unlike `selfmerge`'s negative `no-self-merge` marker.
  Deliberate: the safe state must be the state of an untouched project, so an existing
  fleet gets the new behaviour with no migration. Resolved at spawn and frozen into
  the pane env as `FLEET_AUTOCOMMIT` (no live re-read), like `FLEET_SELF_MERGE`.
- **Persistence is column 10 and CONDITIONAL.** `persist_agent` writes it *only* when
  it is `1`, so a default agent's `.agents` line stays exactly 9 fields — a
  pacman-installed fleet running alongside the dev symlink has a 9-var `cmd_restore`
  whose last var would otherwise absorb the 10th column and mangle `owner` (and with
  it the `d<N>-` window prefix). An absent column reads back as the SAFE default, so
  any skew loses a *grant*, never re-grants commit rights. This is the `.agents` file,
  NOT the 9-field agents TSV — that one still may not grow a column (see "Task tag").
- **`review` is DERIVED, never stored.** ready + dirty = `review` (the worker is
  finished, your commit is owed); ready + clean = `done` (reapable). It reuses TSV
  field 9 and is computed from `uncommitted_status`, the SAME expression `cmd_reap`
  refuses on — so the pill and "reap will refuse" can never disagree. **Both**
  `agents_tsv` emission paths must derive it (daemon-up python and the daemon-down
  tmux fallback) or the pill flips whenever `fleetd` is down.
- **Durability replaced the commit.** A commit was also the reflog/`fsck` net, and
  there is no stash/format-patch machinery anywhere in `bin/`. Two replacements:
  `write_checkpoint_ref` snapshots the **index** into `refs/fleet/checkpoint/<slug>`
  via `write-tree` + `commit-tree` (a real, GC-anchored commit object, but under
  `refs/fleet/`, never on the worker's branch — which is why "the agent did not
  commit" still holds literally); and `cmd_export_uncommitted` writes
  `uncommitted.patch` + `untracked.tgz` outside the worktree before **every**
  destructive path. Because the checkpoint snapshots the INDEX, unstaged work is
  outside the net — which is exactly why the seeded instruction mandates `git add -A`.

Two destructive paths, not one. `cmd_reap --force` was the known one; the dashboard's
`x` (`confirm_teardown`) is a 3-keystroke force-remove that never had a dirty guard at
all and whose failure text used to coach `FORCE` — a **shorter** path to loss. Both now
export first and refuse the removal if the export fails. `cmd_reap`'s dirty refusal no
longer advertises `--force` (dirty is the normal end state now); it points at
`fleet diff-view` + `git commit`. Note `cmd_reap`'s unmerged guard silently stops
guarding in this mode: `merge-base --is-ancestor HEAD $baseref` is trivially true with
zero commits, so protection drops from two orthogonal guards to one.

`cmd_diff_view` is the single definition of "the diff": diffstat + tracked diff +
untracked rendered via `diff --no-index -- /dev/null <f>`, with the clean/dirty branch
keyed off `status --porcelain` — NOT off whether `diff HEAD` came back empty. The old
inline `git diff HEAD` in `fleet-dash`'s `view_diff` omitted untracked files and then
printed "working tree clean vs HEAD", so an agent whose whole job was creating files
showed as having done nothing. In no-commit mode that popup is the primary review
surface and may not lie.

**GATE 2 gained a zero-commit precondition.** Popping a gate-2 message is what makes
the sub-orch merge and push; with a commit-free branch that merge is a silent
`Already up to date`, the push a no-op, and the ledger still reaches `done` — the
pipeline declaring shipped work that does not exist. `gate_post 2` now refuses (rc 3)
while the branch has no commits ahead of the target, resolving the worktree from `-w`
or from the saved-agents line (`gate_worktree_for_slug`).

Known limitation, documented not fixed: base selection and `worktree add` only see
*committed* work, so a NEEDS-WORK loop or a parallel peer would start from a base
missing the prior round. It survives today only via worktree reuse.

Locked in by `test/no-auto-commit-proof.sh` (22 cases; case 4 — staging and the
non-destructive git verbs still allowed — is the highest-value one, since a guard that
blocks `git add` breaks the entire feature).

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

### Sub-orch viewer pane (`suborch_attach_viewer`)

A sub-orch window is **two panes**: pane 0 is the harness (byte-identical to any other
`--scratch` spawn), pane 1 is an **nvim viewer** rooted at `.fleet/dispatch/<id>/`, the
per-dispatch **symlink farm** the sub-orch populates itself (`reports ->`, one link per
worker worktree, one per worker notes dir — `FLEET_SUBORCH.md` §3.0.6). The absolute
reports path comes from the ledger `reports` key, written by `cmd_dispatch_rename` — the
only place `d<N>` and `<slug>` are both in hand.

Making nvim the sub-orch's *own* pane instead would be **silent death**: `is_harness_cmd`
allowlists `nvim`, so the pane would read ALIVE forever after the agent inside it died,
`cmd_reconcile` would never re-animate, and the dispatch would stall showing green. Hence
the pane is *added*, `-d` (no focus steal) and **no `-b`** (pane 0 stays the harness), and
it carries the `@fleet_viewer` **pane** option — never the `@fleet_nvim_sock` *window*
option, which `cmd_send` keys on to route all delivery over nvim RPC with no fallback.

Two consequences everything else must respect:

- **Liveness may not use `head -1`.** When the harness pane exits the window survives on
  the viewer and the viewer *becomes* pane 0 → false ALIVE. `suborch_live` resolves through
  `suborch_harness_pane` (first non-viewer pane) instead, and
  `suborch_prune_orphan_window` drops the harness-less husk before reconcile respawns.
- **Row producers enumerate panes and key on WINDOW options, which tmux inherits down to
  every pane.** Three of them: `agents_tsv`'s daemon-down fallback keys on `@agent_state`
  (→ a duplicate row per sub-orch, skewing `fleet-dash`'s `HIDDEN_N`); `fleetd`'s
  synthetic pass keys on `@fleet_harness` and *prefers the active pane* (→ `fleet
  send`/`mode` targeting nvim the moment the human focuses it); `fleetd.scrape_harnesses`
  keys on `@fleet_state_src`/`@fleet_busy_re` (→ for a hookless harness like omp it
  capture-panes the viewer and reports a state for it). All three filter on
  `@fleet_viewer`, as do `window_pane_for` and `suborch_pane_for`. **Any new pane
  enumeration must too.** `suborch_has_live_workers` is the documented exception —
  a sub-orch is excluded from `@fleet_owner` stamping, so its viewer reads an empty owner.

`fleetd`'s tmux format grew a 10th field for this. Note `meta` stores `parts[1:]`, so
format index *n* is `m[n-1]` — the synth pass unpacks `(pane,) + tuple(m)` (10 names)
while the reported-pane loop indexes `m[8]`. Both arities were wrong on the first pass and
`fleetd` has no try/except around method dispatch, so each one exited the daemon;
`Restart=on-failure` then crash-looped it to permanently `failed` while everything
silently degraded to the stale tmux-option fallback. Any change here must keep
`test/suborch-viewer-focus.sh` case **4b** (daemon still alive after serving) green —
case 4 alone passes just as happily against a corpse.

Proofs: `test/suborch-viewer-{liveness,send,focus,idempotent}.sh` and
`test/dispatch-symlink-farm.sh`. The liveness one is the critical guard.

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
- `fleet new <repo> <branch> [-p "task"] [--bare] [--base <branch>] [--harness|-h <name>] [--self-merge|--no-self-merge] [--task|-T <kind>]`
  — spawn an agent: creates a git worktree for `<branch>` if needed, opens a tmux
  window (editor + agent split by default, `--bare` for a plain agent pane), and
  seeds it with the `-p` prompt. `<repo>` is a repo name/alias in this project
  root. `--harness` (alias `-h`) picks the agent CLI (`claude` default, or `omp`,
  …; see `fleet harnesses`). By **default** a worker **may** `git merge`/`git push`
  its branch (fleet-guard allows it). Flip the whole project to *blocked* with
  `fleet selfmerge off`; override a single spawn either way with `--self-merge`
  (force allow) or `--no-self-merge` (force block). **`--task <kind>`** tags what
  KIND of work this agent does — one of `research|plan|impl|test|scratch`
  — shown as a 4-char tag (`rsch`/`plan`/`impl`/`test`/`scr`) in the tmux window
  status bar, the dashboard row, and `fleet ls`'s TASK column. Unset (or unknown,
  which warns and drops) renders blank. Display only: it is a separate namespace
  from the orchestrator/worker *role*, and `--task main` and `--task generic` are hard-rejected (error + non-zero exit, no spawn).
- `fleet selfmerge on|off|status` — project-wide worker self-merge toggle. `off`
  drops a `<root>/.fleet/no-self-merge` marker so newly-spawned workers in this
  project (all repos) are blocked from merge/push; `on` removes it (the default,
  workers may merge/push); bare/`status` reports the current state. **Spawn-time:**
  affects workers spawned from now on — existing panes keep their grant. Per-agent
  `--self-merge`/`--no-self-merge` on `fleet new` override the project default.
- `fleet autocommit on|off|status` — project-wide worker **commit** toggle.
  **Default: off — agents do not commit.** A worker stages its work (`git add -A`)
  and stops; you review it and make the one commit that enters history. `on` drops
  a `<root>/.fleet/autocommit` marker so newly-spawned workers in this project may
  commit again; `off` removes it; bare/`status` reports the state. **Spawn-time:**
  affects workers spawned from now on — existing panes keep their grant. Per-agent
  `--autocommit`/`--no-autocommit` on `fleet new` override the project default.
  **Enforcement is honest about its limits:** the real lever is the instruction
  seeded into every worker; on top of it `fleet-guard` denies `git commit` (and
  `cherry-pick`/`revert`/`am`) for worker panes — but that guard is a **backstop,
  not a wall**. It is claude-only (`omp` has no guard at all, so for `omp` the
  policy is purely advisory) and it cannot see a commit hidden inside `sh -c`,
  `eval`, an alias or a wrapper script. `git add` is deliberately never blocked.
  A leak costs one unwanted commit on a throwaway branch, not lost work.
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
  without burning your own turn in a `sleep`/`fleet ls` loop. **Sub-orch wake
  guarantee:** when the waiting pane is a **sub-orch** (or any non-main pane), the
  watcher retries the in-band wake and **confirms it actually landed** (the
  sub-orch must go `working`); if it can't be delivered (input busy, pane parked,
  or the agent never resumes) the wake is **escalated to a durable inbox message**
  (a sev=warn **⚙ system** ✉ naming `so-<id>`, desktop-notified) instead of being
  silently dropped — pop it to resume that sub-orch. The **main** (human) pane is
  unchanged: it is never send-keys'd, its wake stays out-of-band (toast + bell +
  dashboard alert).
- `fleet ready [<agent>] [-m "reason"]` — signal that a work item is **done: the
  worker's hands are off it.** **Workers: when the task you were spawned for is
  complete, run `git add -A` to stage everything and do NOT commit — a human
  reviews the staged work and makes the commit — then run bare `fleet ready` from
  inside your own worktree. Not when you are pausing, blocked, or asking a
  question.** (Every spawned worker is seeded this instruction on its first prompt
  and again in `<worktree>/.fleet/ready-instructions`, which survives a `/clear`.)
  You flag someone else's with `fleet ready <agent>`, or press **`y`** on its row
  in the dashboard. This drops a `.fleet/ready` marker. A flagged worktree that is
  still dirty shows as **`review`** (yellow) in `fleet ls` and the dashboard —
  finished, but your commit is owed; once committed it shows `done` and `fleet
  reap` will take it. `--clear` removes the flag.
- `fleet reap [<target>] [--force]` — remove every worktree flagged ready (close
  its window, delete the worktree and its merged branch). Refuses any worktree
  with uncommitted changes, a branch not merged into its base, or a worker that
  still has an **unread needs-human message** (sev warn/blocked) in the inbox —
  pop/handle that message first so reaping can never orphan it — a **locked**
  worktree is refused too — unless `--force`. **Reap is atomic:** every refusal,
  early or late, leaves the worktree, its window, its saved-agents line and its
  `.fleet/ready` marker untouched, so a plain **re-run is the retry** — reach for
  `--force` only to genuinely discard dirty or unmerged work, never as the generic
  remedy (it disables the dirty *and* unmerged guards together). Because workers
  now leave work **staged but uncommitted**, dirty-at-reap is the normal state: the
  refusal points you at `fleet diff-view` + `git commit`, not at `--force`. Any
  destructive path that *does* run (`--force`, or the dashboard's `x`) first
  exports `uncommitted.patch` + `untracked.tgz` to `<root>/.fleet/salvage/…` and
  **refuses to proceed if that export fails**.
- `fleet diff-view [<dir>]` — the honest diff of a worktree's uncommitted work:
  diffstat + staged + unstaged + **untracked new files** (which a bare `git diff
  HEAD` silently omits). This is what the dashboard's **`v`** key runs.

## Leader menu (which-key)

The command center has a which-key-style **leader menu**: a grouped popup of
one-key actions. Open it with **prefix+F** or **prefix+Space** (both work from
any pane, including this orchestrator pane — both are prefix-table bindings, so
plain Space typing in panes is untouched), or by pressing **bare Space while the
dashboard pane is focused**. Press the shown key to run an action;
**Esc/q/Space** closes. Actions are grouped **+Agents** (pick `a`, new `n`,
reap `x`, orchestrator `m`, pop oldest message `p`, triage messages `t`,
rebuild `M`), **+Session**
(save `s`, sessions `o`, reload `R`, dispatch mode `d`, quit `Q`), and **+Info** (ls `l`, keys `?`,
rebind `c`). Those single keys are pressed **inside** the popup — fleet binds
**no direct prefix+key shortcuts** for individual actions, so every other tmux
prefix default (`n`, `x`, `s`, … ) stays intact; the only default it reclaims is
**prefix+Space** (was `next-layout`). The leader key is configurable
(`fleet rebind` → `menu`); the `prefix+Space` alias is set/disabled via
`menu-alt=` in `keybinds.conf`. `fleet keys` lists every action and its in-menu
key; `fleet rebind` (or the menu's `c`) changes one. Per-agent verbs (msgs `e`,
ready `y`, send, mode, diff, close) stay on the dashboard's selected row, not in
the leader — mark-ready moved off the leader menu entirely, because a leader key
cannot know which row you mean. In the dashboard's agents view
**`y`** toggles the ready flag on the selected agent — no confirm modal, because
the same key undoes it, and a flagged row carries a **⚑** glyph whatever its
live state (the `done` pill stays idle-only, so it never lies about a live agent).

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

When a delegated task is finished, the worker stages its work (`git add -A`) and
flags its worktree with `fleet ready` — **nothing is committed by an agent**. Review
the staged diff (`fleet diff-view <worktree>`, or `v` in the dashboard), make the
commit yourself, then merge. Once merged, `fleet reap` clears out all the finished
worktrees in one step (it refuses unmerged or dirty ones — an uncommitted worktree
shows as `review`, not `done`).


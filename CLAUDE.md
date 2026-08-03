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
(`done|failed|cancelled`) and `ledger_parked`
(`gate1-wait|gate2-wait|gate3-wait|blocked`). Three
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

### The allocator creates instead of counts (`alloc_id`, `cmd_dispatch_alloc`, d38)

`fleet dispatch-alloc` read `.fleet/dispatch/seq`, added one, and `mkdir -p`'d the result.
Every clause of that is wrong for an allocator. `seq` is a counter the function does not
own — anything can create a ledger dir out-of-band, and three things did (`d36`/`d37`/`d38`
were filed by hand) — and **`mkdir -p` is precisely what converts "already exists" into
success**. On 2026-08-02, with `seq`=35 and `d36` a **live** dispatch (`state=planning`,
sub-orch working in `@53`), alloc returned `d36` and stamped `state queued` + a fresh
`created` over its `meta.tsv`. The next line of `bin/fleet-dispatch.sh` would have written
a new brief over that dispatch's own — silently, while its sub-orch kept working from text
it had already read. A human caught it, not the system.

The honest guarantee is narrow and is written at the function: **"the allocator never
returns a directory it did not create."** It is **not** "ids are never reused" —
`_reports/<slug>` and archived `dispatch=dN` messages outlive a deleted dispatch, and
empty/partial dirs are never reclaimed (explicit non-goal).

- **The create IS the exclusion.** Bare `mkdir`, never `-p`: the kernel arbitrates and two
  racers cannot both win. Same primitive as `acquire_lock` and the notes-archive create.
- **Seed from `max(seq, disk-max)`,** where the scan is `find -maxdepth 1 -type d` filtered
  `^d[0-9]+$`. The filter is mandatory — a filename reaches `[ "$b" -gt "$m" ]`, an
  arithmetic (eval) context — and `d1c`/`alerts.log`/`seq` all live in that dir while
  `dispatch_farm` plants symlinks there. The comparison is deliberately **not**
  `2>/dev/null`: with the filter in place the suppression is dead code, and dead
  suppression is what makes the filter's absence unobservable (proof case A4).
- **EEXIST ⇒ advance and retry, bounded (`ALLOC_MAX_TRIES`, 64) — never `die`.** One stray
  directory must not wedge the prompt hook, whose stderr is swallowed: a `die` there
  becomes silently vanished prompts. Exhausting the cap is the one refusal.
- **`seq` is written only after a successful create, and its rc is CHECKED** — fail-soft,
  because `max(seq,disk)` self-heals the next allocation. A lost write costs an alert.
- **Provenance is passed in GLOBALS (`ALLOC_ID`, `ALLOC_CREATED_DIR`), so
  `cmd_dispatch_alloc` calls `alloc_id` WITHOUT `$( )`.** A command substitution runs the
  function in a subshell and would discard provenance at exactly the caller that needs it.
  `cmd_dispatch_alloc` stamps meta only into the path alloc recorded — and deliberately
  **never re-tests `[ -d "$d" ]`**: that was the incident's own oracle, and `[ -d ]`
  follows symlinks where `mkdir(2)` does not. (Measured: with `mkdir -p` restored and a
  symlink planted at the next candidate id, `meta.tsv` is written straight through it —
  proof case A4 under mutation `M_A4`.)

`bin/fleet-dispatch.sh:84-86` was the other half and shipped as one change with it: it
branched on `[ -d "$DIR" ]` (existence — the one condition that must force refusal),
discarded alloc's rc and every `die` message via `2>/dev/null`, and truncated
`instruction.txt`. It now branches on the **rc**, refuses when `instruction.txt` already
exists, writes the brief **no-clobber under `set -C`**, and routes every refusal to
`fleet dispatch-alert` (a new internal verb — the hook is POSIX sh and cannot reach
`append_dashboard_alert`) plus a `systemMessage`, because an `exit 0` there is
indistinguishable from the user having typed nothing.

Locked in by `test/dispatch-alloc-proof.sh` (A1–A7b; A6 is the repo's **first** test that
drives `bin/fleet-dispatch.sh` at all) and `test/cross-root-guard-proof.sh` (B1–B4), with
`test/d38-sabotage.sh` as the RED harness: 13 delete-the-operation mutations, each with a
vacuity guard that aborts if its target text is absent. Two results worth keeping: **A2's
headline is double-covered** (deleting the disk seed leaves the id correct because the
retry reaches `d39` anyway — only the alert goes red), and **A3 needs both the bare `mkdir`
and the seqlock gone** before duplicates appear. Neither is a weak case; both are two
mechanisms covering each other, and the sabotage script says which is which.

### Cross-root ledger writes: detection, never refusal (d38)

`fleet_root()` resolves tmux `@fleet_root` **first**, `FLEET_ROOT` second, `pwd` third, and
**nothing anywhere compares the environment that produced the root with the argument that
produced the target.** A test fixture that exported `FLEET_ROOT` into a sandbox but did not
isolate `TMUX_TMPDIR` therefore wrote the **real** ledger on 2026-08-02: it parked a gate on
the human's live `d1`, dropped a message in their real inbox, and their own pop stamped
`gate1_popped` on it.

**Refusal was examined and killed, and the reason must not be re-litigated.** Flipping the
precedence breaks worker panes (they carry no `FLEET_ROOT` and fall through to `pwd`) and
`fleetd`, which discovers projects *by* `@fleet_root`. Making a mismatch fatal fails
**OPEN** at `is_main_pane:230` — `fleet_root … || return 1` reads as "not main", which
switches off the never-clobber brake in `safe_kill_window`, the brake installed after a
prior dispatch tore down a whole session. *A guard whose failure mode disables an older
guard is worse than no guard.* A **containment** assertion is worse still and was killed as
a **tautology**: the target path is *built* from the root, so a proof of it is green by
construction — exactly the false green this dispatch exists to eliminate.

What ships instead is four narrow things, all of them audit or blast-radius, **none of them
security** (same uid throughout; `inbox_put` has no role check by design):

- **`root_disagreement_alert`**, called from `fleet_root` and changing nothing it returns.
  Fires when `FLEET_ROOT` is set and differs from tmux, writing into the
  log of the root that **won** — so an escaping fixture writes the evidence into the *real*
  project's `alerts.log` and cannot suppress it. The flag is set **before**
  the call, which is what stops the recursion through `append_dashboard_alert`.
  **It de-duplicates per SHELL CONTEXT, not per process** — the earlier "once per process"
  wording was wrong and is corrected here rather than quietly dropped. `fleet_root` is
  almost always called as `$(fleet_root)`, and a subshell's assignment to
  `_ROOT_DISAGREE_ALERTED` cannot propagate back to its parent, so a verb that resolves the
  root twice alerts twice (**measured: 2 for `dispatch rename`**, 1 each for
  `dispatch done` / `gate park` / `dispatch farm`). The **claim** was fixed, not the
  behaviour: the alert is audit and fail-soft, a duplicate line costs nothing, and the
  alternatives (a marker file, or exporting into the environment) add a durable side effect
  to a function every code path calls.
- **`valid_dispatch_id`** at **nine** sites — `cmd_dispatch`, `cmd_dispatch_finish`,
  `cmd_dispatch_rename`, `dispatch_farm`, `gate_write_artifact`, `gate_park`,
  `gate_record_pop`, `gate_resolve_dir` and `gate_deliver` (`bin/fleet` 2784, 2814, 2835,
  2882, 3237, 3278, 3316, 3374, 3661 at `05a323d`). Round 1 shipped **four** — the read/
  resolve sites only — and that four-site list survived in this file for a round after the
  code had nine; `CROSSROOT-RESIDUE.md` and the `05a323d` commit message say "seven" while
  enumerating nine. The commit message cannot be amended; **nine is the number**.
  The old `d[0-9]*` glob matched `d1/../../evil`, which resolves
  clean **outside** the ledger whenever that path exists. Deliberately **not** the strict
  `^d[0-9]+$`: the live corpus allocates `d1c`, `d2c`, `d2e`, `d2f` out-of-band, and the
  strict form silently unresolves them at every gate verb while buying nothing — a name
  with no separator and no `..` cannot leave the ledger dir. Strict `^d[0-9]+$` *is* used at
  `ledger_disk_max`, for the different reason above.
- **`ledger_entry_dir`, the second half of that check — and the half round 2 found
  missing.** `valid_dispatch_id` bounds the NAME; every site then asked `[ -d "$d" ]`, and
  **`[ -d ]` follows symlinks**. Measured against `05a323d`: with `ln -sfn <victim>
  $LED/d99`, `gate park d99 1`, `dispatch done d99` and `dispatch rename d99 slugx` each
  wrote a 0600 `meta.tsv` and planted a farm symlink in the victim — outside every ledger,
  hence outside every `alerts.log`. That is round 1's V1 outcome by a second route, and
  strict `^d[0-9]+$` would **not** have closed it (`d99` is strict-valid), so it is not an
  argument about the non-strict choice. It is the lesson the *allocator* half already wrote
  down (`mkdir(2)` does not follow a trailing symlink where `[ -d ]` does) reaching the gate
  half a round late. `ledger_entry_dir` is `[ ! -L ]` before `[ -d ]`, with the trailing
  slash stripped (`[ -L "$d/" ]` resolves the link and is false), and it replaced the
  `[ -d ]` at every ledger-entry site including the read/enumerate ones. **Residual, stated:
  it bounds the final path component only** — a symlinked `.fleet/dispatch` *itself*, or a
  symlinked `.fleet`, still redirects everything, and no realpath containment is asserted
  anywhere (a containment proof built from the root is the tautology killed above).
  Pinned by `cross-root-guard-proof.sh` **B5** (a–h; 11 assertions go red when the `[ ! -L ]`
  line is deleted, with a narrowness case proving a REAL `d99` directory still parks).
- **The `gate_post` reorient cut.** `$FLEET_DIR` comes from the binary's own location and
  was never compared to the root; that split is how `/tmp/adv3/tree/FLEET_SUBORCH.md` — a
  manual under a path anything on the box can plant — was written into a real dispatch's
  gate artifact, aimed at the reader whose job is to re-read it. **The trigger is
  "under the root OR under `$HOME`", not the plainer "inside the root"**, and that is
  load-bearing: in every real install the binary is outside the project by construction
  (release tree / a checkout), so the plainer rule fires on *every* gate message and
  replaces a pointer that resolves with one that does not. `gate-unpark-pointer-proof.sh`
  measures that (4 assertions go red under the blanket form).
- **The harness refuses to run half-isolated** (`proof_root_tripwire`, plus a `TMUX_TMPDIR`
  check beside the existing socket ones). The escaping fixture simply did not source
  `hidden-proof-common.sh` — which is the argument for making the harness impossible to
  half-use rather than for adding one more thing a fixture author must remember. Fail-CLOSED,
  the deliberate inversion of fleet's usual rule.

`gate_write_artifact`, `gate_park` and `inbox_put` are **unchanged and still reachable from
any root** — that residue is stated, not hidden, in
`_reports/alloc-collision/CROSSROOT-RESIDUE.md`, which is the deliverable this half is
judged on. FLEET_SUBORCH.md §8 documents the supported way to file a follow-up dispatch,
removing the motive for the hand-`mkdir` that started all of it.

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
  fan-out scope, `sessions_rows`, **`cmd_restore`**, **`cmd_forget`**,
  **`cmd_reap`**.

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
`persist_agent`, `cmd_restore`, `cmd_forget` and `cmd_reap` all key on
`project_session()`.

`cmd_reap` was the last reader still on `session_name()`, and that was a second
live bug (d36): from a parked pane it opened
`~/.config/fleet/sessions/<sess>_hidden.agents`, which holds none of the
project's workers, so **reap was simply INERT from any sub-orch pane** —
`fleet reap fleet/task-tag-off-bar` printed `nothing flagged ready` for a
worktree that was flagged, clean, merged and pushed. The wrong file is read
*before* the ready marker or the `<target>` label is ever consulted, so no
per-worktree guard could catch it, and none was relying on the accidental
scoping: `<target>` matches the repo/branch **label**, the window to kill is
resolved from server-global `tmux list-panes -a`, `gate_waiting` keys on
`fleet_root`, and every refusal (live-state, dirty, unmerged, unread
needs-human, lock, gate-wait) is per-worktree. That is also the whole of
`$sess`'s use in `cmd_reap` — it appears in exactly one place, and `cmd_forget`
re-resolves `project_session()` itself, so DECIDE and MUTATE cannot disagree
about which file the line is struck from. Locked in by
`test/proof-reap-project-session.sh` (13 cases; 3-5 are the headline, 7-13 assert
the guards still refuse from that same parked pane). **`cmd_quit` is the
deliberate exception and must stay on `session_name()`** — see below; do not
"make it consistent".

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
   read** (`task_of`). It no longer *has* to be — the value stopped reaching a tmux
   format string when the status-bar token was removed (d35), and with it the blast
   radius where an unvalidated `#[` corrupted `window-status-format` for the **whole
   tmux server**. Both checks stay: they are free, and they are what keeps a garbage
   tag out of the two surfaces that remain. Tags are 4 pure-ASCII
   chars (`rsch`/`plan`/`impl`/`test`/`scr `, blank otherwise) because
   `popup_fit_content`, `fit_left` and `hrule` all count **codepoints, not display
   cells**, and there is no ASCII-fallback ladder to degrade to.

Rendered in **two** places — the tmux status bar was the third and is **gone**
(d35). It used to be a second token appended beside `@agent_glyph`, expanding a
companion `@fleet_task_tag` option that held the already-rendered tag (a tmux
format expands an option's value verbatim and cannot map `research`→`rsch`
itself). With the token gone **nothing reads `@fleet_task_tag`**, so it is no
longer stamped — only actively *unset* at the write site, on both branches, so a
window carrying a stale value from an older fleet cannot render one. `@fleet_task`
is now the sole stored form, canonical and machine-readable, read by `task_of` /
the dash / `fleet ls`.

Removing the token is not enough on its own: a **running tmux server, or a
resurrected/saved format, still carries it baked in**, and the global
`window-status-format` is only ever rewritten by `inject_status_format` and
fleetd's `heal_status_format`. Both therefore **strip** it — idempotent,
fail-silent, and by **literal substring removal, never a regex**, because the
fleetd-owned `@agent_glyph` token sits immediately next to it and is load-bearing.
Both twins must keep doing it: fleetd's sweep re-heals the bar after a theme
switch, so fixing only `bin/fleet` would let the stale token return every 60s.

- **the dashboard row** — a 4-char text field (not a pill: a pill costs `PW+4`=11
  columns), shed **first** in the width ladder so the label is never squeezed, and
  hidden entirely when no visible agent has a task (`HAS_TASKS`), so a task-less
  fleet renders byte-identically to before the flag.
- **`fleet ls`'s TASK column** — resolved in the shell into a `wname<TAB>tag`
  sidecar that awk reads as its first FILENAME; the TSV shape is untouched. The
  tab-separated surfaces use `task_tag_trim` (unset → *empty*, not 4 spaces),
  because a padded field makes `fleet ls | column -t` mis-align that row; the
  padded `task_tag` is only for the dashboard's fixed-width row.

Locked in by `test/agent-task-proof.sh` (22 cases; the regression group asserting
the 9-field shapes and the absent `done` pill is the highest-value part). Cases
**16b** and **16d** were inverted at d35: they now assert the token is *absent*
from both formats, that an already-installed legacy token is *stripped* (by the
bash injector and by fleetd's Python twin independently), and that `@agent_glyph`
survives both — the coverage was inverted rather than deleted. Case 16's
server-wide scan now fails on **any** stamped `@fleet_task_tag`.

### GATE 2 integration: the SHIP worker, and why the oracle rejected every approval

At a popped GATE 2 a sub-orch must get feature branch `S` into target `T`, and it
cannot do that in its own pane (`FLEET_ROLE=worker`). The ruled answer — already
documented in `FLEET_SUBORCH.md` §7 — is to **delegate to a SHIP worker spawned
with `--self-merge`**. That was paper: never executed, and broken in four places.

- **`gate_parse` read only line 1.** `gate post` does put the sentinel on body
  line 1, but the human never feeds the oracle a bare body — they POP, and
  `inbox_pop_text` prepends `From <from>: <title>` + a blank line. So the oracle
  returned **rc 1 for every genuine approval**, while §7 says "run it through the
  oracle, never eyeball it". `inbox_pop_text` is `printf '%s\n%s\n\n' head body` —
  header then body *immediately*, blank *after* — so a genuine popped sentinel is on
  **line 2 and never lower**. The parser reads **line 1 and line 2 only** — a
  structural bound, not a knob crediting a constant — and, decisively,
  **anchored**: line 2 is honoured only when line 1 is an actual pop header. The
  offset is then a consequence of the format rather than a free allowance, which
  matters because `fleet inbox put` has **no role check** — any pane can enqueue a
  body, so a bare bound of N hands an attacker N−1 lines of camouflage lead-in to
  bury a forged sentinel behind. Pinned by three proof cases (line 2 parses, line 3
  does not, a non-header lead-in does not) plus a byte-pin of the popped line
  against the sentinel — the only assertion that catches the header format drifting
  again, which is what produced this bug in the first place.
- **The prompt shape.** §7 told the sub-orch to put "the exact commit/merge/push
  steps" in the SHIP worker's `-p` string. §7 now writes them to
  `<worktree>/.fleet/notes/SHIP.md` and the prompt is **one line naming the file**.
  **The guard rationale for this is DEAD — do not restore it.** It used to be a
  workaround for a live `fleet-guard` defect (newline split before the quote-aware
  tokenizer, so a **quoted** prompt line whose first word was `git merge`/`git push`
  was DENIED). `cb4a42b` (d32) fixed that by tokenizing the text whole; measured on
  current `main`, the verb at **column 0 of line 2 of a quoted `-p` is ALLOWED**.
  Group B pins that measurement — the row is now an **ALLOW**, beside its mid-line
  control and a genuinely multi-line script whose real `git push` is still DENIED,
  so the pair discriminates fixed-defect from blanket-allow.
  What survives is a **separate** rationale, hit live on 2026-07-31: the harness's
  own auto-mode classifier denies a batched command carrying the verb, and fleet
  cannot see or fix that. So §7.1 keeps the one-line pointer — for the classifier,
  not for the guard.
- **Nothing terminated the ledger.** §7 now ends in `fleet dispatch done <id>` after
  a *verified* merge, and `fleet send --needs-human main` on failure — a silent park
  at GATE 2 is indistinguishable from a wedged pipeline.
- **Reap would delete `main`.** See below.

Two rules the docs must keep. First, the SHIP worker **integrates and the human
publishes** — and that split is an **operational instruction, not a grant**: merge is
local and reflog-recoverable, while push is outward-facing, triggers CI + the pacman
republish, and needs a non-default credential helper to work headless. There is no
merge-only permission and there cannot be one at a single uid; measured, `git push`
under `FLEET_SELF_MERGE=1` is **allowed**, and group B pins that measurement so this
paragraph goes red if it ever changes. Second, this design does **not claim tamper-resistance**: everything runs as the
same uid, the ledger is writable by the very agents it records, the hook fails open, so
no unforgeable approval grant is achievable — and it adds **zero capability**: any
pane could already run `fleet new --self-merge`. What it buys is that the merge
becomes a visible, owned, recorded step. That claim was written before `fleet gate
approve` existed and remains literally true, but the **cost** of a pane approving its
own gate has dropped from "forge an inbox message and get a human to pop it" to one
CLI call the courier then delivers autonomously — `gate_decide` has **no role check**,
deliberately (a check at a single uid is a speed-bump, not a control, and the audit
trail is the design). `bin/fleet-guard` is deliberately
**untouched** by this feature, and the proof byte-compares it to prove that.

`--name <window>` on `cmd_new` exists for **routing, and only routing**: the derived
window name is a pure function of repo+branch, so a SHIP worker on the impl worker's
branch gets a byte-identical name and `send`/`ready`/`watch` hit whichever pane tmux
resolves first. It does **not** protect the impl worker's `.fleet/ready` marker and
never could — the marker lives in `$dir`, which the window name never enters. That is
handled separately, by **pane occupancy**: `cmd_new`'s reap-safety clear keeps a marker
only while its `pane=` writer is a live pane whose cwd is that worktree (`cmd_reap`'s
live-occupant scan, not `agents_tsv`'s row-local predicate), and clears it otherwise —
including every ambiguous case, because a cleared marker costs a pill and a kept one
costs a worktree. Residual, stated: this is a reliability check, not a control.
`.fleet/ready` is plain text in a same-uid world, so any agent can stamp any pane id —
including a live occupant's — or delete the marker outright; and `cmd_ready` writes
with `>`, so two live agents flagging one worktree still race and the last writer wins.
The occupancy test only stops the *accidental* case: a pane id recycled across a tmux
server restart that happens to be live somewhere unrelated. `--name`
is validated on the same closed charset logic as `@fleet_task`, since the name reaches
`window-status-format`, and it is validated **once for both spawn branches** — it used
to be parsed and then silently dropped for `--scratch`. It is also **re-passed by
`cmd_restore`**: without that a restored SHIP worker came back under the derived name
(the collision returning at exactly the event restore exists for) and the respawn
overwrote col 8, destroying the record. That re-pass is only safe because the `d<N>-`
owner prefix is **idempotent** — a plain prepend grows the name a segment per restart,
and the name keys `.fleet/tasks/<wname>`, restore's own match and `cmd_forget`.
Window names are additionally **uniquified at spawn** (`scratch_wname`), so two roles
on one branch stop sharing an address **for `send`/`ready`/`watch` routing only**; the
matcher rework their consumers want is deliberately deferred.

**STATED LIMITATION — a same-branch pair does not survive a tmux server restart.**
`persist_agent` keys the saved-agents record on column 1, the **worktree dir**, which
`--name` never enters, so the second spawn *deletes* the first's line: spawn order
decides which of the pair returns (usually the SHIP worker, losing the impl worker) and
the other must be respawned by hand. Once the survivor is forgotten or reaped the
worktree has **no record at all** — `fleet restore` never respawns it, `cmd_reap` never
sees it, an orphan only a human can clear. Re-keying on `dir + wname` is a named
follow-up with its cost written down: 2 lines plus ~25-30 of consequence across
`cmd_forget`, `cmd_reap` (two lines, one `$dir`, so decide/mutate runs twice) and
`bin/fleet-dash`, a ~45-60 line proof that does not exist, and it makes `cmd_restore`
respawn TWO agents into ONE worktree — inside the reap-safety clear's own blast radius.

### KNOWN, UNMITIGATED: a conflicted integration worktree takes the CLI down machine-wide

`~/.local/bin/fleet` is a **symlink into `/home/red/proj/pc-tune/fleet/main/bin/fleet`**,
so the integration worktree *is* the machine's `fleet` CLI. The moment a merge leaves
conflict markers in that file, every `fleet` command on the box dies with a syntax
error — every project, every concurrent dispatch, every running agent, not just the one
merging. **This is not theoretical: it happened on 2026-07-30**, took the fleet down
mid-resolution and broke d32's SHIP worker in flight.

- **It is not mitigated.** SHIP.md step 3 ("on a conflict `git merge --abort`") is an
  **instruction to an agent, not a control** — nothing enforces it and nothing detects
  the window.
- **Recovery, and it must be fleet-free** because `fleet` itself is what is broken:
  `git -C /home/red/proj/pc-tune/fleet/main merge --abort`. Proven by group G (a
  genuinely conflicted `bin/fleet` does not parse; the abort restores a clean,
  parseable tree). That proves the *recovery path*, not the absence of the window.
- **Do not close this by adding another be-quick instruction.** Every real fix is a
  deployment-model change — an ephemeral integration worktree (which *contradicts* the
  reap guard below) or serving the CLI from a snapshot — and both are out of scope
  here. Descoped deliberately, in writing, rather than shipped in silence.

**Audit, not authorisation (S7).** `gate_park` stamps `parked_at`, and `inbox_pop`
calls `gate_record_pop` **after** the paste rc-guard (nothing is recorded for a pop
that did not land) to write `gate<N>_popped <ts>` into that dispatch's `meta.tsv` —
parsed through `gate_parse` itself, never a private regex. Both are facts on disk for
a human to read; nothing may ever *authorise* off them, because the agent they
describe can write them. `fleet-dash`'s `card_park_note` renders `gate2-wait 3h` on
the card header so "waiting on you" is distinguishable from "wedged" (extracted by
the proof between the `# >>> smg:parknote` markers — keep them).

### Reap and the integration branch (`cmd_reap`)

`cmd_reap` refuses any worktree whose branch is the project **integration branch**
(`fleet integration-branch`, default `main`) or literally `main`/`master`, checked
**before** the `--force` block and **not overridable by it**. The branch is
identified by **both the `.agents` record (trimmed) and the checked-out HEAD** —
either name matching is decisive, and `--force` overrides neither. Keying on the
record alone was a live hole: nothing rewrites field 3 when a worktree is later
switched, an observed real record was `'main '` (trailing space, which a `case`
pattern misses outright), and the worktree this protects on this machine is
`fleet/main`, i.e. the live CLI. When `symbolic-ref` cannot name HEAD the guard falls
back to **commit equality** against the target's tip, so a worktree detached at that
tip is still refused while one detached elsewhere stays reapable; if even `rev-parse`
cannot answer, the repo is unreadable and reap **fails closed** and skips. The same
disagreement also disarms the **`branch -D`**: `-D` is a force-delete of the
*recorded* name, so when record and HEAD differ reap would silently destroy an
unrelated real branch — it now skips the delete and prints the disagreement. This is not
hypothetical: merging into `T` requires `T` checked out, the only worktree holding it
is the *linked* `fleet/main`, and every existing guard passes for it trivially — it
is clean, and `merge-base --is-ancestor HEAD main` is true of `main` itself. So reap
would `git worktree remove` it and then `git branch -D main`, armed by the
`fleet ready` every worker is seeded to run. `--force` means "discard THIS item's
dirty/unmerged state", never "delete the branch everything merges into"; a human who
genuinely means it has two lines of `git`. Locked in by
`test/suborch-merge-gate-proof.sh` group C (including the `--force` pin and a
narrowness case proving ordinary worktrees still reap).

### Release tree + lazy promote (`cmd_promote`, the hot-path prologues)

`~/.local/bin/{fleet,fleetd,fleet-hook,fleet-guard}` no longer symlink into the
dev worktree. They point at `$RELEASE_DIR/current/bin/*`
(`~/.local/lib/fleet`, overridable via `FLEET_RELEASE_DIR`, which is how the
proofs stay out of the live install).

The bug this removes is not "a symlink pointed at a worktree". It is that **the
artifact every agent EXECUTES and the artifact the human EDITS were the same
bytes, with no validity gate between them.** Git is *designed* to write
syntactically invalid files into a working tree; on 2026-07-30 that working tree
was the production install, so a conflicted merge published `<<<<<<<` into
`bin/fleet` **and** `bin/fleet-guard` — the latter running before every tool call
of every agent — and the fleet was down until the merge was committed.

Two properties are in tension and both are kept: **live** (my edit takes effect
with no ceremony) and **valid** (what agents execute parses and runs). An
explicit `fleet promote` per edit would buy `valid` by spending `live`, trading a
rare, loud, 60-second outage for a frequent silent one ("I'm debugging stale
code"). So promote is **lazy**: every entry point asks "is my source newer than
my release?" and promotes if so. Save a file, next invocation runs it. The only
time you run older code is while your working copy does not validate — exactly
the old outage window, except now the fleet keeps working.

Five things that are load-bearing and were each a measured failure mode:

- **The release is a TREE, not four files.** `fleet:10` derives `FLEET_DIR` from
  the resolved script path, so `FLEET_DIR` becomes the release root and every
  `$FLEET_DIR/…` read must ship: `harness.d/*.conf`, `nvim/fleet.lua`, `FLEET.md`,
  `FLEET_SUBORCH.md`, `systemd/`, `lib/` (not `node_modules`), `skills/`, and all
  of `bin/` (`fleet-dash:15` derives `FLEET_BIN` from its own dirname). That is
  `release_manifest`, and it converges with what `packaging/PKGBUILD:61-113`
  already installs into `/usr/lib/fleet` — `test/release-manifest-proof.sh`
  cross-checks the two so the shapes cannot drift apart silently.
- **One atomic `ln -sfnT`, never a per-file loop.** `-n`/`-T` are mandatory: bare
  `ln -sf` onto an existing dir symlink creates the link *inside* the target.
  Nothing is ever rewritten in place — bash reads a script incrementally by byte
  offset, so `cp` over a RUNNING script corrupts the running process (`unexpected
  EOF`, rc=2); `cp` succeeds and *is* the hazard. And a **half-promote is worse
  than the outage it replaces**: new `fleet` + old `fleet-guard` is silent, and a
  stale fail-silent guard *allows* what it should deny.
- **`bash -n` is provably insufficient**, which is why `release_gate` has five
  checks: git-in-progress refusal (fires on the actual incident condition before
  a byte is read) → anchored marker grep → shebang-dispatched `bash -n`/`sh -n`/
  `py_compile` → **compile every embedded python heredoc** → **behavioural smoke**.
  A quoted heredoc is an opaque string to a shell parser, so markers or a
  SyntaxError inside one give rc=0 and die at runtime — the exact shape of
  `fleet-guard`/`fleet-hook`. The smoke is behavioural (assert a worker `git push`
  is DENIED), not exit-code, because the guard ends its python with `|| exit 0`:
  a guard whose python is dead still exits 0 while silently allowing everything.
  `test/conflicted-worktree-proof.sh` variants 4 and 5 are those two cases.
- **Lazy promote NEVER restarts `fleetd`.** It compiles its source once at import,
  so it is immune until restarted; an unconditional restart drops the socket ~2 s
  and `fleet-hook` silently discards transitions in that window — one lost edge
  leaves an agent stuck "working" forever. Skew is reported by `doctor` (fleetd
  returns its own source sha256 in `fleet.ping`) and restarted only by an explicit
  promote / `fleet up`. Benign and visible beats a dropped socket.
- **Recovery may not depend on what it repairs.** `./bin/fleet promote` works from
  the worktree with no dependence on `current`; `--rollback` toggles back (≥3
  trees retained); `--from-head` materialises via `git archive HEAD`, which is
  structurally immune since no commit has ever contained a marker — an escape
  hatch, never the default, because HEAD-only would kill instant-live.

The **prologue** in `fleet-guard`/`fleet-hook` is the risky part: new code on the
hottest path in the system. It sits at the very top, **before stdin is read and
before any output**, so a re-exec inherits an untouched stdin and the hook
protocol is byte-identical either way; it is silent on every path including
failure; and every steady-state check is a shell **builtin** (two stats, no
fork) — a wrapper *process* was measured at +0.60 ms, which is +88% of the hook's
0.9 ms fast path, and was rejected on that number. It fires **only when `$0` is
inode-identical (`-ef`) to `current/bin/<name>`**, so running a worktree copy by
hand — or from any other proof in `test/` — exercises *that* file and is never
hijacked into the release. `FLEET_PROMOTED` bounds the re-exec to one hop;
`FLEET_NO_PROMOTE=1` disables the mechanism entirely and is what the gate's own
smoke run sets, so a staged tree can never recurse back into promote.

Four sharp edges found in review, each now load-bearing:

- **`FLEET_PROMOTED` must be CONSUMED, not merely tested.** It is passed through
  `exec`, so it lands in the new process's *environment* — and `fleet up` starts
  the tmux **server**. Testing it without `unset` meant one `fleet up` after an
  edit stamped it on every agent pane for the session, silently disabling every
  guard/hook prologue fleet-wide: the design's promise quietly stops holding with
  no symptom but stale code. `release_lazy_self` unsets it **first**, before even
  the `FLEET_NO_PROMOTE` early return (the promote child is invoked with both set
  and spawns git/tar/python of its own); the hook prologues unset it too. Note a
  prefix assignment on `exec` does *not* avoid this — only `unset` does.
- **The negative cache is not an optimisation.** The trigger stays true for as
  long as the worktree is broken, so without it every PreToolUse of every agent
  re-ran the whole gate — measured **15 ms → 88 ms, indefinitely, precisely while
  mid-merge**. The degraded mode would be the incident mode. The prologues take a
  third stat: retry only if the source is newer than the `drift` marker.
- **The gate fails CLOSED, in both places it previously did not.** `cmd_promote`
  keys on `release_gate`'s *exit status*, not on whether it printed (a check
  returning non-zero with no detail — python3 OOM-killed — would have published);
  and a smoke sandbox that cannot be created is a refusal, not a skip. Everywhere
  else in fleet doubt means allow; here it means refuse.
- **Pruning is cold-only.** `release_prune` keeps ≥3 and reaps nothing younger
  than 10 minutes, because a long-running `fleet` may still be reading
  `harness.d/` or `FLEET.md` out of the tree its `FLEET_DIR` resolved to. It also
  reaps abandoned `.stage-*` trees older than an hour — a SIGKILL'd promote leaks
  its whole private stage and nothing else would ever collect them.

Two smaller ones: `harness.d/*.conf` is `bash -n`'d as well as marker-grepped
(it is `.`-sourced on every invocation, so a marker-free syntax error there
breaks every `fleet` call from an otherwise valid release); and the prefix tests
for "am I running from the release" resolve **both** sides through `readlink -f`
(`release_running_from_release`) — `FLEET_DIR` is resolved while `RELEASE_DIR` is
a literal `$HOME` path, so a symlinked `$HOME`/`/home`/`~/.local` silently made
every one of them false, disabling lazy promote and baking a soon-to-be-pruned
`rel-<stamp>` into `settings.json`. It is a `${x#…}` prefix test, not a `case`
glob, because `$RELEASE_DIR` is data and a `[` or `*` in it would be a pattern.

Anything **written to disk** must name `current/`, not the `rel-<stamp>` this
process happens to be running from (immutable *and* eventually pruned): that is
`release_stable_dir`, used by `cmd_setup`'s hook paths and systemd `ExecStart`,
`ensure_daemon`'s nohup fallback, and `install.sh`'s symlinks + skill link.
`install.sh` promotes *first* and refuses to install at all if the gate rejects —
adviser B rates a re-run of the old `install.sh` the highest-probability path
back to the bug. Everything here is manifest-driven, never glob-driven: the
dangling `~/.local/bin/fleet-tile` (a binary removed in `443674b` whose symlink
was never reaped — `--uninstall` now reaps it) would otherwise abort a `set -e`
repair midway, i.e. a half-promote caused by the repair tool.

`fleet setup`'s dev-shadow guard needed widening: the `fleet` on PATH now
legitimately resolves into the release, so comparing it against `$FLEET_DIR/bin/
fleet` made `./bin/fleet setup` from the canonical worktree — the normal case —
abort with "another fleet shadows this one". It now also accepts "the release
built from this worktree".

Locked in by `test/{conflicted-worktree,promote-atomicity,release-manifest,
hot-path-budget}-proof.sh`. The first is the headline: it reproduces 07-30 five
ways and then asserts the *other* half — resolve the conflict, and with **no
human promote step** the released bytes equal the worktree bytes. A design that
passed the first half and failed that one is the explicit-promote design that was
rejected. The atomicity proof was checked against a deliberately non-atomic
implementation (publish file-by-file into a live `current`) and goes red on 7
assertions, including 2,821 failed reads — it is not vacuous. The budget proof is
**soft** (reports, `STRICT=1` to harden), because "we added an invisible 5 ms to
every tool call" is precisely how this design would fail quietly.

### The gate DECISION: three surfaces, one verb, and only the courier un-parks (d34)

Before this, a gate decision was not an object. Approval existed **only** as a human
popping a message into a pane — i.e. as tmux scrollback — and **rejection had no
representation at all**, so there was no routing, no attempt counter and no cap. Worse,
`ledger_parked` enumerated the `gate<N>-wait` states and **no writer ever cleared them**
(`parked_at` / `gate<N>_popped` are labelled in-source as "AUDIT FACT, NOT A GATE"), so a
dispatch that reached a gate stayed parked forever.

`fleet gate approve|reject|show|list|deck|deliver` closes both. Load-bearing pieces:

- **Three surfaces, ONE verb.** `gate_decide` is reached from the CLI, from the viewer's
  `:FleetApprove`/`:FleetReject` Ex commands, and from the leader deck. Nothing else
  decides. This is why approving *with amendments* — just talking to the harness pane —
  costs zero code: it was never a fourth surface, it is the sub-orch running the verb.
- **DECIDING DOES NOT UN-PARK.** Un-parking is `gate_deliver`'s alone, and only on
  confirmed landing. A decision that cleared the parked state on write would drop the reap
  guard and the reconcile exemption while the sub-orch has heard nothing — the gate-park
  bug wearing a new hat. Every failure path here fails towards *still parked*.
- **Confirmation is CONJUNCTIVE, and that is the whole of `gate_landed`.**
  `wake_confirmed` infers landing from the pane going `working` — **and a human typing in
  that pane produces exactly the same signal.** So the courier additionally requires its
  own sentinel to **APPEAR** — a delta against a baseline `gate_sentinel_count` sampled
  **before** the paste. Either half alone is a false positive: `working` alone is a busy
  human; the sentinel alone is stale scrollback.

  **The delta is the load-bearing half, and the first implementation did not have it.**
  Both conjuncts were sampled only *after* the paste, as absolutes — and the sub-orch
  posted the gate **from that very pane**, so its own sentinel is already on that screen
  and the sentinel test is true before a byte is sent. Any live turn (or a human typing)
  supplies `working`, so the conjunction confirmed a delivery that never happened and
  **un-parked**, dropping the reap guard and the reconcile exemption on a gate the human
  never answered: the gate-park bug wearing a third hat. Measured **20/20 false confirm**
  by the independent test, against a control of 0/10 at `state=idle`.

  Pinned by `gate-courier-proof.sh` case **4b**, not case 4 — and the distinction is the
  point. Case 4 deletes `decision-<N>.txt` so the courier bails *before* it ever pastes:
  it exercises the `working` half in isolation and is structurally blind to this defect,
  which is how the defect shipped past a green suite. 4b is 3/3 RED against the pre-fix
  tree (`delivered=1 state=running`) and 3/3 green after.

  Two ways 4b passed **vacuously** while being written, both now guarded in-file: the
  window must carry the name the **ledger** records (`dispatch rename` appends the slug —
  a `so-<id>` window makes the courier resolve no pane and defer, refusing for the wrong
  reason); and the pane needs **`stty -echo`**, because otherwise the tty renders the
  paste, the sentinel count genuinely rises, and the case fails against the fix too,
  discriminating nothing. The vacuity guard asserts both the pre-count and the resolved
  pane before the case is allowed to claim anything.
- **The decision file is a BARE body, sentinel on line 1.** `gate_parse` stays the sole
  advance oracle and needs no change. The `From `-header two-line form is the *inbox's*
  shape — a consequence of `inbox_pop_text`'s header, never a free two-line allowance
  (`fleet inbox put` has no role check, so a bare bound of N hands a forger N−1 lines of
  camouflage). Do **not** widen the `sed -n '1,2p'` head read.
- **Reject is never reasonless, and the loop is capped at 3.** No reason ⇒ rc 2 ⇒ nothing
  written. Each lap's reason is its own `reason-g<N>-<k>.txt`; `rejects_g<N>` is
  deliberately **not** cleared by a re-post, so a pipeline cannot reset its own cap.
  Gate-2 reject is pre-merge only (rc 5 once the ledger concluded) and points at revert.
- **The cap's `blocked` is PARKED, and classifying it was not optional.** `gate_decide`
  is a NEW writer of the ledger `state`, and `blocked` shipped in *neither* set — so the
  verb that escalates to a human promptly dropped every guard protecting the work it
  escalated: measured `gate waiting` empty (reap would take the worktree), `gate list`
  empty (the human cannot even see it), and `cmd_reconcile` reading
  "non-terminal + not parked + dead pane" as stranded and flipping it to **`failed`**.
  That is the July-19 class reintroduced by this slice's own writer, which is the whole
  argument for having a single classification site: the fix is one token there, and it
  reaches reap, reconcile, `gate list` and the orphan escalation together. It is
  **not terminal** — nothing concluded, the human can still decide it by hand, and
  `suborch_ledger_active` (sharing only the TERMINAL set) must keep nudging.
  Pinned by `gate-reject-routing-proof.sh` 6b/6d, with **6c** as the mandatory negative
  control: widening this predicate must not make an *unknown* token parked, which is the
  inverse failure — a genuinely stranded dispatch turning invisible. That is why this is
  a closed `case` and never a "not terminal" test.
- **`gate_post --park` is one transaction.** Two commands left a window in which the gate
  message existed but the ledger did not say parked — and in that window reap could take
  the worktree. The park is last: a park with no message is a wedge; a message with no
  park is the bug.
- **fleetd learns ONE fact and shells out.** `Fleet.courier` reads `decision` and
  `delivered` from `meta.tsv` and `Popen`s `fleet gate deliver`. It must never learn the
  sentinel grammar: that would be a second implementation, in a second language, in the
  one process with no try/except around method dispatch, where a single exception exits
  the daemon and `Restart=on-failure` crash-loops it to permanently `failed`.

Locked in by `test/{gate-decision,gate-reject-routing,gate-courier,gate3-state}-proof.sh`.

### The sub-orch window is self-sufficient (d34 S3)

The window is harness pane + nvim viewer rooted at `.fleet/dispatch/<id>/`. It held the
**evidence** and not the **question**, and the evidence only if a model remembered a chore:

- `gate_post` now also writes `<dispatch-dir>/GATE-<N>.md` — the inbox's own bytes, so a
  decision made from the file cannot differ from one made from the message. Last-wins,
  never appended. No `-d` ⇒ nothing written, because a GATE file at an invented path is a
  lie aimed at the reader least able to catch it.
- **`dispatch_farm` populates the symlink farm in BASH**, from the ledger `reports` key
  plus `workers.tsv`, run at `dispatch rename` and at every `gate post` — the two moments
  the human is about to look. It was pure prose before (`FLEET_SUBORCH.md` §3.0.6), and
  `test/dispatch-symlink-farm.sh` case 6 evals *the manual's* commands, which proves the
  commands and never that a live sub-orch ran them. The prose stays as belt-and-braces.
- **Viewer surface is Ex commands, not keymaps or RPC.** The viewer is plain `nvim .` with
  the **human's own config** and **no `--listen`** (the `--listen` elsewhere is the *agent*
  nvim), and `test/suborch-viewer-send.sh` asserts `@fleet_nvim_sock` stays unset — setting
  it flips `cmd_send` to RPC-only, which then dies. `suborch_viewer_vimrc` writes
  `.fleet-viewer.vim` and it is sourced via `-c`; it defines only `Fleet*` commands, maps
  no keys, and **`echoerr`s on failure** — the one place the fail-silent rule is inverted,
  because the whole attach path is fail-silent and a command that never installed is
  otherwise indistinguishable from an approval that worked.
- **The deck is a POPUP, never a third pane.** `suborch_attach_viewer`'s `npanes >= 2`
  guard permanently disables viewer self-heal if a third pane exists, so the deck is
  structurally excluded from being one. It is also one `fleet_actions()` row, not a prefix
  chord — the only prefix binding is `menu`.

### Human presence is a PANE OPTION (`@fleet_human`, d34 S6)

"…or it can be done manually by a user within an agent" was added and never made safe.
Every guard in fleet keys on `@agent_state`, i.e. on an **agent's** hook reports, so a
human in a worktree with claude exited reports nothing and reads as abandoned.

`fleet human on|off|status` stamps `@fleet_human` on the pane. **Not a 10th TSV column** —
three readers parse that TSV positionally as exactly 9 fields and all three fail *silently
wrong* on a 10th (every row renders the `done` pill and a human reaps live work; a blank
dashboard; a mangled restore owner). Consumed by `cmd_reap` (refuses, **not even with
`--force`** — `--force` has never meant "delete the tree a person is typing in", and the
escape hatch is one word), `cmd_send` (refuses to type into the pane), and `cmd_reconcile`
via `suborch_human_present` (never revive over them, never mark their work failed).

Two more from the same slice: `cmd_send`'s never-clobber guarantee now extends to the
**worker** path (`draft`/`modal` refuse, overridable with `--force`; `generating` is
deliberately allowed, since an agent mid-turn is the ordinary case and the harness queues
input), and `cmd_watch_run` gained both `fleet unwatch` and a **vanished-target-is-terminal**
exit — streaked over three ticks, because `agents_tsv` falls back to tmux options and one
empty read during a fleetd restart is a blip, not a death.

### IDENTITY IS NOT ENTITLEMENT: the worker self-submit defang (d37)

`cmd_new` stamps a sub-orch-spawned worker's window with `@fleet_owner`; `inbox_put`
copies it into the envelope as `owner=so-dN`; `inbox_route` reads that stamp and returns
`dest=suborch submit=1`; `inbox_paste_to` presses Enter for it. Meanwhile `gate_parse`
honours a sentinel on line 2 behind a `From ` header — exactly the shape `inbox_pop_text`
emits. So **any** worker `.msg` whose body line 1 was `[FLEET-GATE:n …]` auto-submitted
into its own orchestrator as a genuine gate instruction, with a completely honest
provenance stamp on it. Nothing was forged and nothing was broken.

The stamp does not merely **fail** to prove the sender may instruct `so-dN` — it proves
the sender is `so-dN`'s **subordinate**, i.e. precisely the party not entitled to. The
code routed on that fact and never asked it. **A proven sender is necessary, never
sufficient.**

The cut is at **actuation, not authorisation**: `inbox_pop_text` emits a **second header
line** for an owner-stamped message, so the body's first line lands on line 3, which
`gate-decision-proof.sh:229-235` already pins as non-parseable. The sentinel still
renders verbatim; it is no longer in an actionable position. `gate_parse` is untouched,
routing and `submit=1` are untouched (waking a sub-orch with its worker's report is the
feature), and `meta_set`/`gate_deliver`/`gate_decide` are deliberately **not opened** —
d33 and d34 own those hunks.

The **rejected** design was a per-delivery `warrant=` capability in the envelope, checked
under d33's CAS. Four of five advisers killed it and the grounds are in-source at
:3084-3086: *the ledger is writable by the very agent it records, so nothing may ever
authorise off it.* CAS buys atomicity, not authentication. `inbox_put` is also not a
chokepoint — the writer is `printf > tmp; mv -f` and every reader is `sed`, so a worker
writes the bytes itself; and a header field the sub-orch's model never reads is not a
control. **Do not resurrect it.**

Four things that are load-bearing:

- **The guarantee is POSITIONAL, so it must hold on every emission path.** `head` is
  always exactly one line (`from`/`title`/`owner` are newline-scrubbed at write and
  `inbox_field` is `sed … | head -1`, so no field can add or remove a line), and
  `inbox_pop_text` is the **one** assembler of paste text in the tree — pop, unpop,
  archive re-pop and the dashboard's triage batch all route through it (the dash never
  assembles its own). An offset that shifts can only shift **down** (a body whose own
  line 1 is blank), never up. `test/worker-selfsubmit-defang-proof.sh` group B walks
  that surface: empty title, duplicated/multi-line title, partial write with no `from=`
  and no `title=`, hand-written `.msg`, archived re-pop, blank body line 1.
- **Line 2 leads with a CONSTANT prefix**, never sender text. `from` is
  attacker-controlled, and a sender-text-first line would put a sentinel straight back
  onto the actionable line (case 10).
- **S1: `dispatch` and `key` are newline-scrubbed** in `inbox_put`. They were printf'd
  raw while `title`/`from`/`owner` were scrubbed, so `-d $'-\nowner=so-d1'` wrote a whole
  forged `owner=` LINE — and `inbox_field` takes the first match above `--`, so a pane
  with no `@fleet_owner` forged one and won `submit=1`, routing around the `--from so-*`
  block. Additive lines: do not reflow that block, `gate-visibility-proof.sh:154-157`
  greps a literal source line in it.
- **The premise is `gate_parse`'s two-line bound.** If it ever widens, this guard stops
  defending **silently**. Case 14 pins it — but pins the `sed -n '1,2p'` *literal*, which
  the RED driver's `widen-bound-literal` mutation shows is a proxy: the real bound is the
  `l1`/`l2` `case` structure. Do not upgrade case 14's wording to claim a behavioural pin.

**This removes the ACCIDENT, not the CAPABILITY, and the report must not imply otherwise.**
**Five** routes remain open and verified end to end:

1. **`tmux rename-window so-d1-x` + unset `@fleet_owner`, then a plain `fleet inbox put`.**
   This is the polished, CLI-only version of "write the bytes by hand", found by review
   *after* the change and reproduced: `inbox_route`'s **second** auto-submit arm keys on
   `from=so-*`, and `inbox_put` auto-derives `from=` from the caller pane's
   `#{window_name}` when no `--from` is given. The `--from so-*` block covers the
   *supplied* flag only, so the comment claiming that arm "is no longer a forgery vector"
   was a fourth overclaim of exactly the corrected kind, and is now corrected in place.
   That arm is deliberately **not** defanged: it is the **entitled** class — a genuine
   gate message from a sub-orch must still parse, and defanging it would break every real
   approval. A `@fleet_suborch`-style verifier would be self-settable in the same breath.
2. A worker writing `.msg` bytes directly with `from=so-dN` and no `owner=`.
3. `fleet notify … inband-ok` / `deliver-wake` / `send` — Enter into a non-main pane with
   no human step at all.
4. Raw `tmux send-keys` to the sub-orch pane, bypassing `fleet` entirely.
5. Writing `decision-<n>.txt` for `gate_deliver` to un-park with no message at all.

Under a single uid none of these close in-band — the same wall d23 hit. Also corrected: the
overclaiming owner comments — at `cmd_new`, `inbox_put`, `inbox_route`, **and the ownership
section header of `bin/fleet-dash`**, which was missed by the first sweep and is the first
place a reader of the ownership model lands. Treat that as a list of the sites found, not a
closed set: re-run the grep rather than trusting the enumeration. `@fleet_owner` has one
writer and **no verifier**; the stamp resists forgery through `fleet` CLI *arguments* only,
and any pane can set it on itself with `tmux set -w`. That is survivable rather than fixed —
forging the stamp is what routes you to the sub-orch, and forging it is what defangs you.

**Known residual risk (non-blocking, from the d37 adversary):**

- **NB1** — the two `so-*` globs at `bin/fleet:4505` (`inbox_route`) and `:4603`
  (`inbox_pop_text`) are coupled by *convention only*. Route ⊆ defang holds today as an
  identity of patterns, but nothing pins them together; a one-sided edit silently
  reintroduces the whole class.
- **NB2** — proof case 14 pins the `sed -n '1,2p'` **source literal**, not the `l1`/`l2`
  `case` structure that is the real bound. A structural widening of `gate_parse` makes this
  defence stop defending with the suite still green.
- **NB3** — `bin/fleet:4417` (bare `fleet inbox`) and `:4798` (`inbox archive list`) print
  the body raw; they are positionally safe only because `inbox_show` happens to emit two
  header lines first, and nothing pins that. Slim either renderer to a bare body and a
  subordinate's sentinel becomes parseable on line 1 via `gate_parse`'s bare-body arm —
  bypassing the defang with no forgery at all.

Locked in by `test/worker-selfsubmit-defang-proof.sh` (20 cases) **plus
`test/worker-selfsubmit-defang-red.sh`**, a mutation driver that neuters one operation at
a time and asserts *exactly* the expected cases go red. That second file is not optional
polish: this whole surface had **zero** coverage before d37, group E's auto-submit case
asserts on what the destination pane actually received rather than on the routing
decision, and a case whose green state is "nothing changed" passes when the operation
under test never ran — which is how d36's V1 shipped.

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

The text is tokenized **once, whole** — never pre-split on `\n`. A newline is a
statement separator only *outside* quotes, and the quote-aware walk that lifts
substitutions marks those (emitting `\n;` — the newline still terminates a `#`
comment, the `;` is the separator token shlex sees). Splitting first threw that
away and was the F3 bug: a multi-line `-p "…"` payload — the normal shape of
`fleet new` — was cut into fragments with unbalanced quotes, and an indented
payload line read as a command word, so the guard denied the very calls F2 was
commissioned to allow. The inverse case is the one to protect: a genuinely
multi-line script (`printf 'a\nb\n'` then a real `git push` on its own line) is
still caught, because that newline is outside quotes.

Unbalanced quotes fall **CLOSED** — a raw regex over the line, the inverse of the
guard's general "on any doubt, allow". A false deny is recoverable by rephrasing;
a false allow merges unreviewed code into main. `FLEET_SELF_MERGE=1` (from
`fleet new --self-merge`) still exempts the pane, and only `role=worker` + `Bash`
is in scope.

Remaining accepted gaps, unchanged in kind: shell functions/aliases, a wrapper
script not named `git`, `find -exec`, and a command word built by expansion we
cannot resolve. This block is a speed-bump against ACCIDENTAL self-merge, not a
sandbox.

Locked in by `test/guard-quoted-payload-proof.sh` (75 assertions, no tmux/daemon —
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
  — shown as a 4-char tag (`rsch`/`plan`/`impl`/`test`/`scr`) in the dashboard
  row and `fleet ls`'s TASK column (**not** in the tmux status bar). Unset (or unknown,
  which warns and drops) renders blank. Display only: it is a separate namespace
  from the orchestrator/worker *role*, and `--task main` and `--task generic` are hard-rejected (error + non-zero exit, no spawn).
  **`--name <window>`** overrides the derived `<repo>/<branch>` window name — needed
  only when a SECOND agent lands on a branch that already has one (the GATE 2 SHIP
  worker), where the identical name would misroute `send`/`ready`/`watch`. It fixes
  **routing only**: the other agent's `.fleet/ready` marker lives in the shared
  worktree dir, which the window name never enters, and is protected instead by the
  spawn's pane-**occupancy** check. Honoured for `--scratch` too, persisted, and
  re-passed by `fleet restore`. **Restore is single-record per worktree:** the
  saved-agents file is keyed on the worktree dir, so a second agent on the same branch
  overwrites the first's record — after a tmux server restart only the LAST-spawned of
  the pair comes back, and the other must be respawned by hand. Rejected (warn +
  derived name) unless `[A-Za-z0-9._/-]`.
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
- `fleet gate approve|reject|show|list [<id|slug>] [--gate N] [-m reason] [--yes]` — **decide a
  gate.** This is the single authority; the viewer's `:FleetApprove`/`:FleetReject` Ex
  commands and the leader deck (`prefix+F` → `g`) both funnel into it, and so does simply
  talking to the sub-orch's harness pane when you want to approve *with amendments*.
  Headless: no tmux, no dashboard, no nvim needed. With no target it resolves the dispatch
  whose sub-orch window you are in. **`reject` ALWAYS requires a reason** (`-m`, `--file`,
  or `$EDITOR`) — an empty one aborts and writes nothing — and routes the pipeline back
  exactly one rung (gate 1 → the PLAN role, gate 3 → the IMPLEMENTATION role in the same
  worktree), counting the lap and **escalating instead of routing at 3**. Deciding
  **does not un-park**: the decision is written to the ledger and a courier delivers it,
  un-parking only once the sub-orch has demonstrably received it — so an undelivered
  decision leaves every reap guard and reconcile exemption in place. Unlike the rest of
  fleet this verb **dies** on a target it cannot resolve rather than failing silently: a
  silent no-op here is a human who believes they approved and walks away.
  **Gate 2 asks you to type the slug back.** It is the approval that actually moves
  code, so approving it shows the merge preview and requires the slug — and with **no
  terminal and no `--yes` it REFUSES (rc 2, nothing written)** rather than silently
  skipping the prompt, because a confirmation that quietly does not happen is the same
  as not having one. `--yes` is the explicit, recorded escape hatch for scripts; the
  absence of a tty is not consent. Gates 1 and 3 are unchanged. An explicit `--gate N`
  that disagrees with the parked gate is refused for the same reason.
- `fleet human on|off|status [<agent>]` — declare that **a human, not an agent, is working
  in this pane.** Everything else in fleet keys on `@agent_state`, i.e. on an *agent's*
  hook reports — so a person sitting in a worktree with claude exited is invisible, and
  `fleet reap` would kill their window and delete the tree. With this set, reap refuses
  that worktree (**not even with `--force`** — `fleet human off` is the escape hatch),
  `fleet send` refuses to type into the pane, and `fleet reconcile` leaves the dispatch
  alone. Stored as a pane option, never a TSV column.
- `fleet unwatch [<pane>]` — disarm the watcher armed on a pane. Until now an armed
  `fleet watch` could not be cancelled at all; its only exits were "all idle", "one
  blocked", or the ~90-minute cap. A watch whose targets have **vanished** now also ends
  on its own instead of running out that cap.
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
  worktree is refused too — unless `--force`. The **integration branch** (`fleet
  integration-branch`, default `main`) and its worktree are refused **even with
  `--force`**: it is the branch everything merges into, and merging into it requires
  it checked out in a worktree that otherwise passes every reap guard trivially. It
  is identified by **both the saved record and the checked-out HEAD** (a stale record
  used to disarm the guard), falling back to commit-equality — and skipping outright —
  when HEAD is undeterminable.
  **Reap is atomic:** every refusal,
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
- `fleet promote [--from-head|--rollback|--status]` — publish the worktree to the
  **release tree** that `~/.local/bin/{fleet,fleetd,fleet-hook,fleet-guard}`
  actually point at (`~/.local/lib/fleet/current`). **You almost never run this:**
  it happens by itself. Every entry point asks "is my source newer than my
  release?" and promotes if so, so you save a file and the next invocation runs
  it — instant-live, unchanged. What promote adds is a **validity gate**: no
  merge in progress, no conflict markers, everything parses, embedded python
  compiles, and `fleet-guard`/`fleet-hook` actually run. If the gate fails,
  nothing is published and the fleet keeps running the last good release —
  instead of a conflicted merge taking every agent down, which is what happened
  on 2026-07-30. `fleet` then prints **one** stderr line saying so; `fleet
  doctor`'s `--- release ---` section says which file and which check.
  `--rollback` swaps back to the previous release (≥3 are kept), `--from-head`
  builds from `git archive HEAD` instead of the worktree (the escape hatch: no
  commit has ever contained a conflict marker), `--status` prints the doctor
  section alone.

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

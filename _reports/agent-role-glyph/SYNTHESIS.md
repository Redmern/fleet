BUILD

# agent-role-glyph — synthesis (d26)

## Verdict

**BUILD**, in the revised shape all three advisers converged on independently:

> A validated `--task` enum, stored in a **new** `@fleet_task` window option plus a
> **window-name-keyed** `<root>/.fleet/tasks/<wname>` file, rendered as a 4-char
> ASCII tag in `fleet ls`, the dashboard, and the tmux window status bar, with
> **zero** changes to either TSV and **zero** changes to `fleetd`'s agent listing.

Adviser 3 filed REVISE, not REJECT, and its revision is exactly the plan above; its
REJECT argument (§S8: "role is decoration, the window name already carries it") is
answered by a fact Adviser 1 and the producer explorer both surfaced: the **impl**
worker's branch is plain `fleet/<slug>` (`FLEET_SUBORCH.md:120`) and its window name
is byte-identical to a flat human worker's (`bin/fleet:1055`). The one distinction
the human most needs is precisely the one the window name cannot express today. The
feature is not decoration; it is the missing third of an existing convention.

## Why the obvious design is wrong

The natural implementation — "add a role column to the agents TSV" — is a
silent-corruption bomb in three independent readers, and this repo is fail-silent by
house rule (CLAUDE.md:16-19), so every one of them fails *quietly with a wrong
answer*:

1. `bin/fleet-dash:409` positional `read` of 9 tab fields: tab is IFS-whitespace, so
   the empty col-9 `ready` collapses and col 10 lands in `$ready` → **every agent
   renders the `done` pill** while `fleet ls` (`bin/fleet:343,391`) stays correct.
   Dash and ls disagree; a human trusting the dash reaps live work. Adviser 3
   reproduced this at a shell prompt. The codebase already knows this trap and
   defused it twice with `tr '\t' '\037'` (`bin/fleet:742-744`, `:3105-3108`) — the
   dash was never converted.
2. `bin/fleetd:333` `if len(parts) == 9:` → a 10th field empties every row's
   metadata → the dash session filter (`bin/fleet-dash:398`) drops everything →
   blank dashboard. The synth pass `bin/fleetd:365-410` unpacks a fixed 8-tuple and
   would `ValueError` the whole `fleet.list` RPC.
3. `.agents`: `cmd_restore`'s `IFS=$'\037' read … owner` (`bin/fleet:745`) — the last
   var absorbs extras, so a new binary's col 10 becomes part of `$owner`, which is
   re-exported as `FLEET_SUBORCH_ID` (`:764`) and sliced into the `d<N>-` window
   prefix (`:1084-1088`). There is **no version or migration mechanism anywhere**
   (grep `schema|version|migrat` in `bin/` = 0 hits), and this project deliberately
   runs a pacman-installed `/usr/bin/fleet` alongside a dev symlink — version skew
   is a live condition, not a hypothetical.

## The second trap: the word "role" is already load-bearing

`FLEET_ROLE` (env), `.fleet/roles/<pane-id>`, `@fleet_role` (window option) and dash
`ROW_ROLE` are four distinct existing meanings, and three of them are **security**:
the fork-bomb gate (`bin/fleet-dispatch.sh:18`), the worker merge/push block
(`bin/fleet-guard:33`), and `is_main_pane` (`bin/fleet:163-172`) which is the sole
brake in front of every cleanup `kill-window` (`safe_kill_window`). A worker that
could write `main` into any of them self-promotes to orchestrator. Renaming the new
concept to **task** costs zero diff now and removes the whole class.

## Adviser debate digest

**A1 (minimal diff / fail-silent conservatism).** Explicit flag, not inference —
`scratch_wname` (`bin/fleet:562`) appends `-2`/`-3` on collision and impl has no
marker, so inference can never cover the case that matters; a wrong badge is worse
than none. Window option only; accept that a tmux server restart resets everything
to blank, because "a task badge is an at-a-glance convenience, not state anything
depends on." Rename to `--task`. Single ASCII letters. Fixed enum, because it pins
the badge at a constant width forever, which is what makes the width math safe.
Leave the fzf pickers alone — three near-duplicate hand-padded formatters, triple
blast radius, badge nobody reads mid-teleport. ~40 lines.

**A2 (human UX / durability).** Disagreed on two points and won both.
*Ranking:* the **tmux status bar** is the surface the human sees without running
anything — that is literally the ask ("so that it's visible"). A dash-only badge
under-delivers. *Durability:* every pane-id-keyed store is already poisoned (tmux
reassigns pane ids across a restart and `.fleet/roles/` is never GC'd), so key the
durable copy by **window name** — the key `cmd_restore` already round-trips
(persisted col 8, `bin/fleet:749-751`) and every target resolver already matches on.
A2's own proposal was to encode the role *as a window-name suffix*, which lights up
all four surfaces with no renderer change at all — elegant, and it extends the
`<slug>-research` / `<slug>-test` convention that `FLEET_SUBORCH.md:108,130` already
uses. **Rejected** on one ground: the window name is user-visible, user-renamable,
and is the matching key for `fleet send` / `mode` / `ready` / reap targeting, so
mutating it for display makes a cosmetic field load-bearing in the resolvers. We
took A2's *key choice* (window name) without taking its *storage location* (inside
the name). A2 also killed unicode outright — seven roles cannot be made mnemonic in
width-1, the free single-cell pool is picked over, and a glyph needs a legend the
human must memorize; 4-char lowercase tags are self-documenting and width-safe by
construction. And A2's fail-mode argument decided the default: **blank, not `gen`** —
missing is honest, wrong is corrosive, because the human uses this tag to decide who
to interrupt.

**A3 (adversary).** Produced the reproduction for the `$ready` collapse (S1), the
`len(parts)==9` cascade (S3), the `--task main` self-promotion path (S2), and the
one risk the other two missed: **status-bar format injection** (S6) — `@agent_glyph`'s
*contents* are format-expanded by tmux and already ship live `#[fg=…]` markup, so any
option appended to `window-status-format` whose value carries `#[` or an unbalanced
`#{` corrupts the status bar for the entire tmux server. This is what forces
validation to live at the **single write site** as a hard enum (`bin/fleet:981`) and
to be re-applied on **read** (`task_of`) so a hand-edited file cannot inject either.
It is also what makes A2's status-bar win affordable: with a closed enum, the value
is provably three-to-eight lowercase letters and nothing else. A3 further noted the
synth `starting`/`stale` rows (`bin/fleetd:365-410`) — under our design they read the
window option like any other row, so they are covered, which is a real advantage of
the option-based store over anything sourced from `fleet.list`.

## What the three agreed on without prompting

- Never widen `agents_tsv` or `.agents`. (unanimous, and it is the load-bearing call)
- Never reuse `role` / `@fleet_role` / `.fleet/roles/` / `ROW_ROLE`, never write `main`.
- ASCII, not unicode — no ASCII-fallback ladder exists anywhere in the codebase to
  degrade to, and `popup_fit_content` / `fit_left` / `hrule` all count codepoints.
- Fixed enum, validated at spawn, tolerated-as-blank on read.
- Drop `orchestrator` as a role: main and the dash pane are filtered out of the TSV
  by design, and un-filtering makes `main` a closable dashboard row — the exact
  whole-session-teardown class fixed at f63c3d8.

## Residual risks accepted

- One extra `tmux show -wqv` per window per dash refresh (`TASK_RAW`, mirroring the
  existing `OWN_RAW` at `bin/fleet-dash:187-198`).
- `.fleet/tasks/<wname>` entries leak if a window is destroyed outside `fleet forget`
  (killed by hand). Harmless: stale file + no live window = never rendered; a
  same-named future agent gets its own stamp at spawn, overwriting.
- `fleet ls`'s static path must resolve the tag outside the awk pipeline, since the
  role is deliberately not in the TSV. Slightly awkward, and the price of not
  breaking three readers.

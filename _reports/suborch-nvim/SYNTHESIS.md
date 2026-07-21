REVISE

# d25 suborch-nvim — synthesis

**Verdict: REVISE.** The human's *need* is real and should be built. The human's
*mechanism* ("open the sub-orch with nvim", i.e. route it down cmd_new's nvim
path) is the wrong one, and the premise it rests on ("the folder where all its
created files are visible") names a directory that does not exist today.

Build a different shape that satisfies the ask literally:

1. **Make the folder exist** — a per-dispatch symlink farm inside
   `.fleet/dispatch/<id>/`, dropped by the sub-orch itself.
2. **Open nvim on it** — as an *added tmux pane* in the sub-orch window, not by
   converting the window to the nvim path.

## Why not the literal ask (convert sub-orch to cmd_new's nvim path)

`cmd_new --scratch` forces `bare=1` (bin/fleet:998-999) and pins `dir="$root"`.
Routing sub-orchs to the nvim branch (bin/fleet:1160-1174) means:

- **B1 (critical, silent).** `is_harness_cmd` allowlists `nvim`
  (bin/fleet:1593). `suborch_live` (bin/fleet:1601-1611) probes only
  `pane_current_command` of `head -1`. With nvim as the pane command the probe
  reads ALIVE forever, including after the harness inside nvim dies. Then
  `cmd_reconcile` never re-animates and the dispatch stalls permanently while
  showing green. This is a strict regression of the only auto-recovery path.
- **B2 (critical, silent).** Seed delivery changes from a synchronous argv
  positional (bin/fleet:1108-1109) to `VimEnter` + 300 ms defer +
  `terminal.open` + a 3000 ms deferred `FleetSend` (nvim/fleet.lua:33-38) — a
  timing guess whose own comment concedes CLI-arg delivery "proved unreliable".
  In a pane parked in a *detached* session nobody is watching. B1 ∘ B2 = a
  permanently dead dispatch with a live-looking pane.
- **B3.** `FLEET_SUBORCH_ID` is exported only in the scratch branch
  (bin/fleet:1130). Empirically confirmed this session: the live `so-d25` pane
  carries `FLEET_SUBORCH_ID=so-d25`, and its research workers carry *no*
  `FLEET_SUBORCH_ID` — the owner edge rides the `@fleet_owner` **window**
  option (bin/fleet:1205), read back at bin/fleet:2408 and 1627. The window
  option survives a path change; the env var does not, and nvim→claudecode env
  propagation is inferred from `termopen` lacking `clear_env`, never observed
  (verified: no live nvim-path fleet pane exists to test against).
- **B4.** The nvim branch hardcodes `-t "$sess"` (bin/fleet:1166) — the visible
  session. A scratch+nvim spawn would land visible, so the safety-critical
  TOCTOU hidden-session block (bin/fleet:1131-1149) must be duplicated or
  refactored. That block is the one place `<sess>_hidden` is created race-free.
- **B5.** The nvim path stamps `@fleet_nvim_sock` (bin/fleet:1173-1174), and
  `cmd_send` keys on it (bin/fleet:1386-1400) to route *all* delivery over nvim
  RPC, with `die` on failure and **no fallback**. Every gate pop, watcher wake
  and inbox route into the sub-orch would depend on that socket.

PRO's strongest points survive and are honoured by the revised shape: the
sub-orch is the one agent whose entire product is files and the only one with
no file view (impl/test workers, whose product is a diff, *do* get nvim —
bin/fleet:1161-1173); the allocation is inverted. PRO also correctly killed
three of EXPLORE-B's flagged risks: nvim's split is an nvim window, not a tmux
pane, so `head -1` probes and dash row counts are untouched *on the nvim path*.
PRO conceded its own weakest point is exactly B2.

## Why the premise is false

Verified on disk (EXPLORE-C): the sub-orch writes only
`.fleet/dispatch/<id>/` (`STATUS.md`, `meta.tsv`, `workers.tsv`,
`instruction.txt`). `_reports/<slug>/` is a **relative** path with no env var
behind it, resolved against each writing agent's cwd:

- research agents are `--scratch`, cwd `$root` → `$root/_reports/<slug>/`
- impl/test workers live in worktrees → `$root/fleet/<branch>/_reports/<slug>/`

Four `_reports` trees exist today; `fleet/main/_reports` is git-tracked, so every
new worktree inherits a copy of all history. `nvim .` at `$root` would show 50+
slug dirs and 20 ledger dirs, and would **not** show worker reports living in
worktrees. Co-location today is an accident of prompts carrying absolute paths
(this very dispatch's reports landed in `fleet/main/_reports/suborch-nvim/`
only because the prompt said so).

This is already a live correctness bug, not just ergonomics:
`FLEET_SUBORCH.md:194` makes crash recovery depend on finding
`_reports/<slug>/SYNTHESIS.md` relative to the sub-orch cwd. A scattered write
makes recovery silently mis-read the phase. An editor fixes 0% of that.

## The revised shape (see PLAN.md)

- **P1** `meta_set "$d" reports <abs>` — one line, gives the ledger the missing
  `d<N>` ↔ `<slug>` join column and fixes the recovery bug. Prerequisite for
  any slug-derived viewer.
- **P2** symlink farm in `.fleet/dispatch/<id>/` — **zero `bin/` lines**, pure
  `FLEET_SUBORCH.md` instruction; the sub-orch already appends `workers.tsv`
  rows carrying repo/branch, so it has everything needed to link
  `reports ->`, `<worktree> ->`, `notes-<label> ->`. This literally creates the
  folder the ask presupposes.
- **P3** an nvim **viewer pane** added to the sub-orch window, rooted at the
  farm. Harness pane 0 stays byte-identical, so B1/B2/B3/B4 are all void by
  construction, and the "cwd must stay `$root`" constraint dissolves — the
  viewer pane's `-c` is independent of the harness's cwd. Precedent in-tree:
  the dashboard pane (bin/fleet:3576-3585) is split post-hoc and keyed on a
  `@fleet_dash` **pane** option.

Two footguns P3 must respect, both verified against source this session:

- **Do NOT set `@fleet_nvim_sock`** on the viewer. It is a *window* option and
  `cmd_send` (bin/fleet:1386-1400) would reroute every delivery into an nvim
  with no agent terminal, then `die` at 1399. Use a distinct **pane** option
  (`@fleet_viewer 1`), mirroring `@fleet_dash`.
- **The split must not steal focus.** `split-window` appends after pane 0 (no
  `-b`), so `suborch_live`'s `head -1` still lands on the harness — but
  `fleetd` prefers `pane_active` for its pre-first-hook synthetic row, so a
  focus-stealing split transiently makes `fleet send`/`fleet mode` target nvim.
  Use `-d`, or `select-pane` back as the dash pane does (bin/fleet:3584).

## Scope ruling

Sub-orch panes only. Not all `--scratch` panes (a 6-way research fan-out would
spawn 6 nvims). Not an `--editor` flag on `cmd_new` — its cost is not
arg-parsing but B4, and it buys nothing P3 doesn't. Defer `--editor` unless a
second consumer appears.

## Seed-size hazard: cleared

`MAX_IMSGSIZE` is 16384 **total per tmux command**, not per-arg (bisected in
`_reports/dispatch-seed-fix/PROOF-DESIGN.md:33-40`). The sub-orch seed is a
~200 B pointer since ae61c81 (content commit c4376dd), and P3 adds nothing to
the spawn command at all — the viewer pane is a separate, later
`tmux split-window`. The loud empty-`win_id` guard (bin/fleet:1178-1189) stays
the backstop.

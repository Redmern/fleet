# ADVISE-ALT — d25 scope & design-space

Lens: enumerate the axes, cost them, rank by value/blast-radius. No advocacy for a
pre-picked option. All citations `bin/fleet:<line>` unless marked.

---

## 0. The one finding that reorders the whole design space

**Adding a pane to the sub-orch window is strictly cheaper than making the sub-orch
window an nvim window,** because the harness pane then stays byte-for-byte what it is
today — same argv, same cwd, same env, same spawn primitive, same `@fleet_*` stamps.

Everything that makes the "make `--scratch` take the nvim path" option expensive
(§2 below) is a consequence of the harness pane *changing identity*. If it doesn't
change, the cost collapses to "one `split-window` + one pane option", and the
`cwd must stay $root` constraint **dissolves entirely** — the viewer pane's `-c` is
independent of the harness's `-c`.

There is already a precedent for exactly this shape in-tree: the `main` window is
orchestrator-pane-0 + dashboard-pane-1, created post-hoc, idempotently, keyed on a
**pane** option (`bin/fleet:3576-3585`):

```
  dash=$(tmux list-panes -t "$win" -F $'#{pane_id}\t#{@fleet_dash}' | awk -F'\t' '$2=="1"{print $1; exit}')
  if [ -z "$dash" ]; then
    orch=$(tmux list-panes -t "$win" -F '#{pane_id}' | head -1)
    dash=$(tmux split-window -P -F '#{pane_id}' -h -t "$orch" -l '40%' "$FLEET_DIR/bin/fleet-dash" "$sess")
    tmux set -p -t "$dash" @fleet_dash 1
    tmux select-pane -t "$orch" 2>/dev/null
  fi
```

A 2-pane fleet-managed window is therefore an **already-supported shape**, not a new one.

---

## 1. Axis 1 — scope: sub-orch only vs `--editor` flag vs all scratch

| scope | change | value | blast |
|---|---|---|---|
| **sub-orch panes only** | one call in `resolve_or_spawn_suborch` (1635-1672), post-`cmd_new` | answers the ASK exactly | ~6 lines, one call site, nothing else on the planet spawns a sub-orch |
| **`--editor` opt-in on `--scratch`** | new flag + inverting `bare=1` at 998 + the nvim-branch session fix (§2) | generality nobody asked for | high — see §2 |
| **all scratch panes** | drop `bare=1` at 998 | actively harmful | every adviser/tester/researcher pane grows an editor it never reads; ~6 concurrent nvims per dispatch |

**Narrowest-with-most-value: sub-orch only.** The ASK names sub-orchestrators. Advisers
and testers are write-then-die agents; an editor in their pane is dead weight and
6× the nvim instances during a fan-out phase.

### Cost of `--editor` concretely (962-1010)

Arg-parsing itself is trivial (one `case` arm at ~968, one local at 964). The cost is
**not** parsing, it's the interaction:

1. `998` `bare=1` becomes conditional. Fine.
2. But the nvim branch at **1166** hardcodes `-t "$sess"` — the *visible* session. A
   scratch+nvim spawn would land on the window bar, defeating hidden-session parking
   (`@fleet_hidden 1` at 1222 would then lie). You must either duplicate the
   TOCTOU-tolerant `has-session||new-session` double-fallback (1139-1149) for the nvim
   argv, or refactor that block into an argv-taking helper. That block is annotated as
   safety-critical (comment 1131-1138: "the loser gets rc=1 / empty win_id and the agent
   is LOST"). Refactoring it to serve a viewer feature is a bad trade.
3. `--editor` also has to mean something for **non**-scratch spawns, where it's just a
   confusing alias for "not `--bare`". Two flags, one axis, inverse polarity.

Verdict: `--editor` is ~4× the diff of the sub-orch-only change and touches the one
block in `cmd_new` you least want to touch. Defer it; it is a trivial follow-up *once*
the viewer mechanism exists as a helper.

---

## 2. Axis 2 — nvim root, and the cwd question

### Can nvim's cwd differ from the harness's cwd? Yes — two different ways.

**(a) In the split-pane design: trivially, they are unrelated processes.** The harness
pane keeps `-c "$root"` from 1140/1145. The viewer pane gets its own `-c`. No coupling
at all. The "sub-orch cwd must stay `$root`" constraint is simply **not a constraint on
the viewer**.

**(b) In the nvim-path design: only via the buffer argument, never via `:cd`.**
`claudecode.lua:6-8` sets `cwd_provider = function(ctx) return ctx.cwd end`, and
`claudecode.nvim/lua/claudecode/terminal.lua:245` builds `cwd_ctx.cwd = vim.fn.getcwd()`,
resolved at `:251-254` and passed to `termopen{cwd=…}` (`terminal/native.lua:91`).
So **harness cwd ≡ nvim's `getcwd()` at terminal-open time**. You may not `:cd`.
You *may* pass a directory as an argument: nvim does not chdir to its argv, and
`grep -rn autochdir /home/red/.config/nvim/lua/` returns **nothing** (default off), so
`nvim $root/.fleet/dispatch/$id` with `-c "$root"` gives an oil buffer on the dispatch
dir while `getcwd()` stays `$root`. That works — but it is a fragile invariant hanging
on one absent option in the user's personal config, and it silently breaks the harness's
cwd (⇒ every relative `_reports/` write) if anyone ever adds `set autochdir` or a
project-root plugin. In the split design that failure mode does not exist.

### Which root to point the viewer at

| candidate | verdict |
|---|---|
| `$root` | Shows `_reports/`, `.fleet/`, and the repo containers side by side — but as EXPLORE-C §4 shows, that is 53 report slugs + 20 ledger dirs + N worktrees. It is the *common ancestor*, not a *view*. Low value: the human already has `$root`. |
| `$root/.fleet/dispatch/<id>/` | Dispatch-scoped and always exists — but holds only `instruction.txt`, `meta.tsv`, `workers.tsv`, `STATUS.md` (EXPLORE-C §1). Status *about* the work, none of the work. Answers "which files did it produce?" with "none of the ones you want". |
| generated manifest file | Stale by construction. Nothing regenerates it as the sub-orch spawns workers mid-run; a viewer showing a stale list is worse than no viewer. Reject. |
| `$root` + initial buffer/quickfix on the dispatch dir | The nvim-path-only workaround from (b). Buys nothing the split design doesn't get for free. |
| **`.fleet/dispatch/<id>/` as a symlink farm** | See below — the only candidate that actually satisfies "the folder where all its created files are visible". |

**Symlink farm.** The sub-orch already owns `.fleet/dispatch/<id>/` and already appends
`workers.tsv` rows as it spawns each worker (`FLEET_SUBORCH.md:31,:232-238`). Have it
also drop `ln -s` entries next to them: `reports -> $root/_reports/<slug>`,
`<repo>_<branch> -> <worktree>`, `notes-<label> -> $root/.fleet/notes/scratch/<label>`.
Then `nvim $root/.fleet/dispatch/<id>` **is** the single directory EXPLORE-C §4 proves
doesn't exist today — oil traverses symlinks. Cost: **zero lines in `bin/`** — it is
prompt text in `FLEET_SUBORCH.md` next to the existing `workers.tsv` instruction.
Highest value/blast ratio of anything in this document, and it is independent of, and
composes with, every other option here.

---

## 3. Axis 3 — layout: post-spawn `split-window` (the recommended mechanism)

Sketch (in `resolve_or_spawn_suborch`, after the `cmd_new` call at 1662-1668, guarded on
non-empty `$wid`):

```
# idempotent, mirrors the dashboard pane idiom at 3576-3585
if ! tmux list-panes -t "$wid" -F '#{@fleet_view}' 2>/dev/null | grep -q 1; then
  vp=$(tmux split-window -d -P -F '#{pane_id}' -h -t "$wid" -l '45%' -c "$d" nvim . 2>/dev/null)
  [ -n "$vp" ] && tmux set -p -t "$vp" @fleet_view 1 2>/dev/null || true
fi
```

Evaluated against every layout assumption the explorers flagged:

- **`suborch_live`'s `head -1` probe (1601-1611).** `tmux list-panes` orders by pane
  index; `split-window` without `-b` creates index 1. Pane 0 stays the harness ⇒
  `#{pane_current_command}` still reads `claude`/`node`, the probe is unchanged.
  Note this also *avoids* EXPLORE-B's false-alive hazard: `nvim` is in the allowlist
  (1593), but we never rely on it, because the harness is still pane 0. **Constraint:
  never use `-b`.**
- **`_wpane` role/owner stamp (1203).** Runs inside `cmd_new`, i.e. **before** the
  split. Unaffected by construction.
- **`suborch_pane_for` (1285-1296)** returns the first `list-panes -a` row for the
  window = pane 0 = harness. Gate-pop `send-keys` lands correctly.
- **`cmd_send` (1386-1400).** Keyed on the **window** option `@fleet_nvim_sock`.
  **Do NOT set it.** Use a *pane* option (`@fleet_view`) as the dash does at 3583.
  If you set `@fleet_nvim_sock`, every `fleet send` to the sub-orch — gate pops, watcher
  wakes, inbox routing — reroutes to `FleetSend` RPC into a viewer nvim that has no agent
  terminal, and 1399 `die`s. This is the single sharpest footgun in the whole design.
- **dash's pane-derived rows (`bin/fleet-dash:405-416`).** Rows come from
  `fleetd.list_agents`, which iterates `self.panes` — panes that **reported via
  `fleet-hook`**. A plain nvim never reports ⇒ no extra row ⇒ `HIDDEN_N` (:416) is not
  over-counted. (EXPLORE-B §6's over-count concern does not apply to a non-reporting
  pane.) The synthetic pass (`fleetd:363-378`) is `@fleet_harness`-keyed and *is*
  window-scoped, but skips any `window_id in covered`, and it prefers `pane_active == 1`
  — hence **`split-window -d`**, so the viewer never becomes the window's representative
  pane during the pre-first-hook window. Without `-d` there is a real transient where
  `fleet send`/`fleet mode` would target the nvim pane.
- **`safe_kill_window` (186-202)** already iterates *all* panes (the one function that
  doesn't `head -1`) — correct for 2 panes with no change.
- **Degraded mode only:** with `fleetd` down, `agents_tsv`'s fallback (271-278) filters on
  `#{?@agent_state,…}`, a *window* option, so a 2-pane window emits two rows. Cosmetic,
  daemon-down only, and identical to what the `main` window already does.

Blast radius: **one call site, ~6 lines, zero changes to `cmd_new`.** It also inherits
`--switch`/dash Enter/`h` for free — those are all `move-window`, window-granular, so a
2-pane sub-orch window moves in and out of `<sess>_hidden` as a unit (EXPLORE-B §6).

Residual cost worth naming: the viewer is a live nvim per sub-orch that nothing ever
kills except window teardown, and it does not auto-refresh — oil needs a manual `R`. It
is a *browser*, not a monitor.

---

## 4. Axis 4 — is `_reports` determinism a prerequisite?

**For a `$root`-rooted viewer: no. For any dispatch-scoped viewer: yes, hard.**

EXPLORE-C §3 establishes `_reports/<slug>/` is a bare relative path with no env var
behind it, resolving against each writer's cwd: `$root` for scratch roles,
`$root/fleet/fleet_<slug>/` for impl/test roles — and it lands in a *third* place
(`fleet/main/_reports/`) whenever a prompt happens to carry an absolute path, which is
exactly what happened to this very dispatch's `EXPLORE-A/B/C.md`. A viewer pointed at a
directory computed from a slug will therefore be right sometimes and empty other times,
which is worse than being absent.

Two candidate fixes, and they are not equivalent:

- **`FLEET_REPORTS` env export** — `$root/_reports/<slug>` exported by the sub-orch and
  passed down in every worker `-p`. Makes the location deterministic *if* every agent
  honours it — but it is the same class of prompt-discipline enforcement that already
  fails today (EXPLORE-C §3 obs. 2), just with a longer string. It also forces impl/test
  artifacts *out* of the worktree, which loses the property that a branch's PROOF/TEST
  files travel with its diff.
- **`meta_set "$d" reports "<abs path>"`** — one line beside the existing
  `meta_set "$d" window "$new"` at **1831** (the rename verb, which already has the slug
  in hand at 1829). Cheap, durable, machine-readable, and it makes the *viewer* correct
  without dictating where agents write. This is the right primitive: record the truth
  rather than legislate it.

Independently of any viewer, note `FLEET_SUBORCH.md:194` already makes **crash recovery**
depend on finding `_reports/<slug>/SYNTHESIS.md` and `TEST-VERDICT.md` relative to `$root`.
The scatter is therefore a live correctness bug today, not merely an ergonomic one — it
deserves its own fix regardless of whether d25 ships a viewer.

**Ordering consequence:** the symlink farm (§2) makes the determinism question moot for
the viewer, because the sub-orch links whatever path it actually used, whatever that is.
That is why it ranks above the `meta.tsv` fix despite being weaker in principle.

---

## 5. Ranking by value / blast radius

| # | option | value | blast | ratio |
|---|---|---|---|---|
| 1 | **Symlink farm in `.fleet/dispatch/<id>/`** (prompt text in `FLEET_SUBORCH.md`, next to the `workers.tsv` instruction) | creates the single dispatch-scoped directory that provably does not exist today | **zero `bin/` lines** | highest |
| 2 | **Post-spawn `split-window -d` viewer pane** in `resolve_or_spawn_suborch`, `@fleet_view` pane option, mirroring 3576-3585 | answers the ASK; harness pane untouched | ~6 lines, one call site | very high |
| 3 | **`meta_set "$d" reports <abs>`** at 1831 | makes any future viewer/tooling able to *find* the artifacts; also mitigates the `FLEET_SUBORCH.md:194` recovery bug | 1 line | high |
| 4 | `--editor` flag on `cmd_new` | generality | requires refactoring the TOCTOU hidden-session block (1131-1149) | low — defer |
| 5 | Drop `bare=1` at 998 for all scratch | negative | 6 nvims per fan-out | reject |
| 6 | Generated manifest file | stale by construction | — | reject |

1+2 compose into the actual ASK: `nvim` opened on `.fleet/dispatch/<id>/`, a directory
that — because of the links — genuinely shows everything the dispatch produced.

## 6. Non-negotiable constraints for whoever implements

1. `split-window` **without `-b`** — pane 0 must stay the harness (`suborch_live:1607`,
   `suborch_pane_for:1285`).
2. `split-window` **with `-d`** — the viewer must never be the active pane
   (`fleetd:373` prefers `pane_active` for the pre-hook synthetic row).
3. **Never set `@fleet_nvim_sock`** on a viewer window — it reroutes all `fleet send`
   delivery to nvim RPC and `die`s at 1399. Use a **pane** option.
4. Guard the split on non-empty `$wid` and make it idempotent (`@fleet_view` probe) —
   `resolve_or_spawn_suborch` is re-entered by `cmd_reconcile`'s per-dispatch loop.
5. Everything fail-silent (`2>/dev/null || true`): a missing nvim must cost the sub-orch
   nothing.

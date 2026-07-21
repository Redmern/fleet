# d25 suborch-nvim — implementation plan

Verdict: **REVISE** (see SYNTHESIS.md). Three parts, independently shippable,
in dependency order. P1 and P2 have value on their own; P3 is the ask.

Repo: `/home/red/proj/pc-tune/fleet/main`. All line numbers are pre-change.

---

## P1 — record the reports path in the ledger (1 line)

**Why:** `_reports/<slug>/` is a relative path with no env var behind it, so it
resolves against whichever agent's cwd wrote it. The ledger is keyed `d<N>`,
reports are keyed `<slug>`, and `meta.tsv` has no join column. This also fixes
a live crash-recovery bug: `FLEET_SUBORCH.md:194` reads
`_reports/<slug>/SYNTHESIS.md` relative to the sub-orch cwd.

**Change:** in `cmd_dispatch_rename`, beside the existing `meta_set` at
`bin/fleet:1831` (the slug is already in hand at `bin/fleet:1829`):

```
meta_set "$d" reports "$root/_reports/$slug"
```

Record the truth; do not legislate it with a `FLEET_REPORTS` export. Workers
already receive absolute report paths in their prompts.

**Anchors:** `bin/fleet:1829-1831` (`cmd_dispatch_rename`), `meta_set`
definition, `meta_get` consumers.

---

## P2 — per-dispatch symlink farm (0 lines of bash)

**Why:** creates the directory the ask presupposes. Pure documentation change.

**Change:** add a section to `FLEET_SUBORCH.md` instructing the sub-orch, at the
point where it appends a `workers.tsv` row, to also drop a symlink into its own
`.fleet/dispatch/<id>/`:

- `reports -> <abs reports dir>` (from the P1 `meta.tsv` key)
- `<repo>-<branch> -> <abs worktree path>` (both columns already in
  `workers.tsv`)
- `notes-<label> -> $FLEET_DOCS` of each spawned agent

Use `ln -sfn`. Symlinks are re-pointable and idempotent, so re-running is safe.
Note they dangle after `fleet reap` deletes a worktree — acceptable; a dangling
link is a visible tombstone, and oil.nvim renders it plainly.

**Anchors:** `FLEET_SUBORCH.md` (the `workers.tsv` append instructions, and
`:194` recovery section which should be rewritten to read the P1 `reports` key
rather than a relative path).

---

## P3 — nvim viewer pane on the sub-orch window (~6-10 lines, one call site)

**Why not the literal ask:** see SYNTHESIS.md B1-B5. Converting the sub-orch to
`cmd_new`'s nvim path (`bin/fleet:1160-1174`) breaks `suborch_live`
(`bin/fleet:1601-1611`), the seed delivery, `FLEET_SUBORCH_ID`
(`bin/fleet:1130`), the hidden-session TOCTOU block (`bin/fleet:1131-1149`) and
`cmd_send` routing (`bin/fleet:1386-1400`). A split-off pane touches none of it.

**Where:** in `resolve_or_spawn_suborch` (`bin/fleet:1635-1672`), *after* the
existing empty-`win_id` guard succeeds and the wid handback has been read from
`FLEET_NEW_WID_FILE`. Guard on the pane not already existing so re-resolution
is idempotent — mirror the `@fleet_dash` lookup at `bin/fleet:3577-3579`.

**Shape** (modelled on the dashboard pane, `bin/fleet:3576-3585`):

```
# viewer: read-only file view of this dispatch's artifacts, rooted at the
# symlink farm in .fleet/dispatch/<id>/. Pane 1, never pane 0 — suborch_live
# and suborch_pane_for both probe `head -1`, which must stay the harness.
viewer=$(tmux list-panes -t "$wid" -F $'#{pane_id}\t#{@fleet_viewer}' \
          | awk -F'\t' '$2=="1"{print $1; exit}')
if [ -z "$viewer" ]; then
  harness=$(tmux list-panes -t "$wid" -F '#{pane_id}' | head -1)
  viewer=$(tmux split-window -d -P -F '#{pane_id}' -h -t "$harness" \
            -l '40%' -c "$root/.fleet/dispatch/$id" nvim .)
  tmux set -p -t "$viewer" @fleet_viewer 1
fi
```

**Hard constraints, each verified against source:**

1. **No `-b` on `split-window`.** Pane 0 must remain the harness:
   `suborch_live` (`bin/fleet:1608`) and `suborch_pane_for`
   (`bin/fleet:1285-1296`) both take `head -1`.
2. **`-d` (or `select-pane` back, as `bin/fleet:3584` does).** `fleetd:373`
   prefers `pane_active` for its pre-first-hook synthetic row, so a
   focus-stealing split transiently makes `fleet send` / `fleet mode` target
   nvim.
3. **Never set `@fleet_nvim_sock`.** It is a *window* option; `cmd_send`
   (`bin/fleet:1386-1400`) keys on it, routes all delivery over nvim RPC and
   `die`s at 1399 with no fallback. Use the `@fleet_viewer` **pane** option.
4. **Do not pass `--cmd ... nvim/fleet.lua` and do not set
   `FLEET_AUTOCLAUDE`.** The viewer must not autostart a harness — that is the
   whole point of keeping it separate from pane 0.
5. **`-c` is the farm dir, independent of the harness cwd.** The harness pane
   is untouched, so the "sub-orch cwd must stay `$root`" constraint is
   satisfied by construction. (On the nvim path it would not be: `cwd_provider`
   at `~/.config/nvim/lua/plugins/claudecode.lua:5-8` pins harness cwd to
   nvim's.)
6. **Teardown.** `safe_kill_window` (`bin/fleet:186-202`) already iterates all
   panes, so a 2-pane sub-orch window tears down correctly. `cmd_reap` never
   touches sub-orchs (scratch agents are not persisted, `bin/fleet:1236`).
7. **Hidden-session moves.** `cmd_hide` (`bin/fleet:3528`), `cmd_unhide`
   (`bin/fleet:3549`) and fleet-dash Enter/`h` (`bin/fleet-dash:1806-1834`) are
   all `move-window`, i.e. window-granular → layout-agnostic, no change needed.

**Open item for the implementer:** confirm `fleetd`'s row derivation. EXPLORE-B
read dash rows as pane-derived (`bin/fleet-dash:416` `HIDDEN_N` over-count);
ADVISE-ALT read them as hook-reported only (`fleetd.self.panes`), in which case
a plain nvim pane adds no row. If EXPLORE-B is right, `HIDDEN_N` needs a filter
on `@fleet_viewer`. **Resolve this empirically before merging** — do not take
either report on faith.

---

## Rejected options (and why)

| Option | Verdict |
|---|---|
| Convert sub-orch to `cmd_new` nvim path | Reject — B1-B5, SYNTHESIS.md |
| `--editor` flag on `cmd_new --scratch` | Defer — cost is B4 (visible-session `-t "$sess"` at `bin/fleet:1166` forces duplicating the TOCTOU block), buys nothing over P3 |
| nvim for all `--scratch` panes | Reject — a 6-way research fan-out spawns 6 nvims |
| Generated `MANIFEST.md` instead of symlinks | Reject — stale by construction; symlinks are live |
| `fleet dispatch view <id>` CLI verb | Fold in — P1+P2 are its guts; add the verb later if a non-tmux consumer appears |

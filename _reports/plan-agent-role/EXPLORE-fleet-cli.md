# EXPLORE — bin/fleet dispatch machinery (digest recovered from read-only explorer)

All refs `/home/red/proj/pc-tune/fleet/main/bin/fleet` unless noted.

## 1. Sub-orch spawn + seed
- `cmd_dispatch` :1770 (verbs enable/disable/status/rename/mode/done|fail|cancel)
- `resolve_or_spawn_suborch` :1639, guarded by `.spawnlock-$id` (id-keyed, survives rename)
- :1788-89 `meta_set window so-$id`, `meta_set state planning`
- Seed prompt :1669-1671, verbatim:
  ```
  You are a fleet dispatch sub-orchestrator (so-$id). Your project root is your CWD ($root).
  FIRST, read and follow your operating manual: $FLEET_DIR/FLEET_SUBORCH.md
  THEN handle DISPATCH ID: $id — read your instruction at .fleet/dispatch/$id/instruction.txt
  ```
- :1662-67 comment: inlining the ~20KB manual overflows tmux `MAX_IMSGSIZE` (16384) → **silent spawn failure**. This is the seed-bloat fix.
- Spawn = `cmd_new --scratch "$wname"` with `FLEET_NEW_WID_FILE/FLEET_SESSION/FLEET_ROOT/FLEET_NEW_SUBORCH_ID`; wid pinned `meta_set window_id` :1675.

## 2. Ledger
`<root>/.fleet/dispatch/<id>/` = `instruction.txt` (written by hook `bin/fleet-dispatch.sh:84-86` via `fleet dispatch-alloc` :1843) + `meta.tsv`.
- `meta_get` :1549 (last-wins), `meta_set` :1555 (atomic upsert), `meta_compact` :1563
- Fields the CLI writes: `state` (:1852 queued, :1789 planning, :1955 gate{1,2}-wait, :1813 done|failed|cancelled, :2005 failed-by-reconcile), `created` :1853, `window` :1788/:1835, `window_id` :1675, `respawns` :2008
- **`role-phase` is NOT written or read anywhere in bin/fleet.** It exists only as model discipline in FLEET_SUBORCH.md:174-196.

## 3. `fleet gate` :1873
- `gate_parse` :1888 — sentinel must be FIRST line, form `[FLEET-GATE:N k=v …]`
- `gate_post` :1907 — GATE1 `action=implement`, GATE2 `action=merge target=…`; **defaults plan paths `_reports/$slug/PLAN-PLAIN.md` / `DONE-PLAIN.md`** (the one place the artifact contract is in code)
- `gate_park` :1949 — only writes `state gate${gate}-wait`
- `gate_waiting` :1962 — emits live window names for reap-skip, consumed :3114

## 4. `fleet reconcile` :1979
- loops `.fleet/dispatch/d*/`, `meta_compact`, **skips only `done|failed|cancelled`** (:1988) ⇒ `gate1-wait`/`gate2-wait`/`planning`/`queued` are all respawn-eligible (the parked-suborch-revival footgun)
- respawn cap :1996-2010: abandons as `failed` only if respawns ≥ `FLEET_RECONCILE_CAP` (default 1) AND `tmux info` responsive AND `suborch_has_live_workers` (:1624, via `@fleet_owner`) false

## 5. `fleet new --scratch` :997/:1231
repo-less, `bare=1`, `dir=$root`, label via `scratch_wname` :566, docs `.fleet/notes/scratch/<label>`.
Prompt via `-p` → argv (`H_PROMPT_FLAG` empty ⇒ positional) :1113-1116. Parked in detached `<sess>_hidden`, TOCTOU-safe fallback :1136-1152. Env always `FLEET_ROLE=worker` (fork-bomb gate) + `FLEET_SUBORCH_ID` when `FLEET_NEW_SUBORCH_ID` set :1134. Loud failure on empty win_id :1191-1194.

## 6. Role-name hardcoding: NONE
No `research`/`impl`/`test`/`plan` role literals in bin/fleet. Only role vocabulary is `FLEET_ROLE=main|worker` and `record_pane_role` :1573 → `.fleet/roles/<pane>` = `worker` / `worker:so-<id>`.
**⇒ The three-role pipeline is entirely prose. A role rename is a DOC-ONLY change** (except gate_post's `PLAN-PLAIN.md` default at :1907).

## 7. Harness
`harness_select` :27 (FLEET_HARNESS → `<root>/.fleet/harness` → config → `claude`), `harness_list` :42, `cmd_harnesses` :522, `harness_load` :47 sources `harness.d/<name>.conf` into `H_*`, `harness_bin` :58.
Adapters present: `harness.d/claude.conf`, `harness.d/omp.conf` — **no opencode adapter exists.**
Seeding differs only via `H_PROMPT_FLAG` (both "" = positional) and bare-vs-nvim (`H_NVIM_PLUGIN`): bare = argv :1113-1116, nvim = `FLEET_PROMPT` env :1167. **Sub-orchs are always bare/scratch ⇒ always argv ⇒ always under the MAX_IMSGSIZE cap.**

# PROOF — `d<N>`-prefix sub-orch & worker naming (executed)

GATE 1 = BUILD. This supersedes the PROOF **design** with the **executed** proof.
Fleet has no test runner (CLAUDE.md), so each proof is a hand-run harness that
sources the REAL (extracted) functions or drives REAL `bin/fleet` verbs against a
**throwaway** tmux session (`fleetproof$$`, never the live `pc` session), asserting
on observable artifacts (tmux window names, `meta.tsv`, route verdict, group_rows
output). Every check prints `PASS`/`FAIL`. Both scripts live in `$FLEET_DOCS`
(`.fleet/notes/proof_unit.sh`, `proof_tmux.sh`, plus the extracted modules
`dash_funcs.sh`, `slug_func.sh`).

**Result: 49/49 PASS** — `proof_unit.sh` 31/31, `proof_tmux.sh` 18/18.
`bash -n` clean on `bin/fleet` and `bin/fleet-dash`. The live `pc` session was
never touched (the throwaway session is torn down in an EXIT trap; post-run
`tmux list-sessions` shows `pc` intact and no `fleetproof*` leak).

---

## A. Unit proof — real extracted functions (`proof_unit.sh`, 31/31)

Sources the REAL `suborch_slug` (from `bin/fleet`) and the REAL `is_suborch_name`,
`suborch_ledger`, `card_meta_state`, `group_rows`, `field` (from `bin/fleet-dash`);
`owner_of` is stubbed to read a seeded `OWN_RAW` so `group_rows` runs without tmux.

- **1. `suborch_slug`** — `New Project Create` → `new-project-create`; `IPv6  Fix!!`
  → `ipv6-fix`; empty/all-punct → `''` (so rename is a no-op, stays bare `so-d<N>`);
  7-word input length-caps to `one-two-three-four-five-six` (≤28, trailing `-`
  trimmed); a word split mid-cut is dropped (`alpha-bravo-charlie`); a digit-leading
  slug survives (`3d-render-pipeline`).
- **2. `is_suborch_name`** (`^so-d[0-9]+(-[A-Za-z0-9-]+)?$`) — matches bare `so-d11`,
  slugged `so-d11-new-project`, digit-slug `so-d11-ipv6-fix`; **rejects** a worker
  `d11-myrepo/mybranch` and a non-`d` `so-foo`.
- **3. `suborch_ledger` / `card_meta_state`** — both strip the `-slug` suffix
  (`%%-*`) to recover the `d<N>` dir; `so-d11-new-project` and bare `so-d11` both
  resolve to dir `d11` and read `state=running`; `so-d404-x` misses.
- **4. worker `d<N>-` prefix derivation** (the `cmd_new` gate logic) — from a bare
  owner `so-d11`, a slugged owner `so-d11-new-project`, and `so-d7`, the worker name
  is prefixed `d11-…` / `d7-…` regardless of whether the slug is present in env.
- **5. `group_rows` grouping** — a worker whose `@fleet_owner` is the **bare**
  `so-d11` groups under the **renamed** header `so-d11-new-project` (bare→full map);
  a worker owned by `so-d99` groups under the un-renamed `so-d99`; `HAS_CARDS=1`;
  **zero orphan annotations** for owned workers. (This is the must-fix #1 regression
  the con doc found — proven fixed end-to-end through the real function.)
- **6. GNUM** — `so-d11-ipv6-fix` → `11` (NOT `116`); `so-d11-3d-render` → `11`;
  `so-d7` → `7`. The old `//[^0-9]/` slurp is gone.
- **7. persist/restore field round-trip** — a 9-col line round-trips
  `wname=d11-myrepo/mybranch` + `owner=so-d11`; a legacy 7-col line reads back with
  empty `wname`/`owner` and falls back to the reconstructed `legacyrepo/legbr` match
  (backward-compatible).

## B. Integration proof — real verbs + real tmux (`proof_tmux.sh`, 18/18)

Throwaway session `fleetproof$$`; `bin/fleet` invoked with `FLEET_SESSION`/`FLEET_ROOT`
overrides so it resolves the throwaway, not `pc`. Sub-orch windows are real tmux
windows; the worker window carries a real `@fleet_owner` option.

1. **`dispatch rename`** — window is `so-d99` **before**; after
   `fleet dispatch rename d99 'New Project Create!!'` the window is
   `so-d99-new-project-create`, `meta window` = `so-d99-new-project-create`, while
   the **ledger dir `d99` and `window_id` are unchanged** (identity = immutable id,
   slug = display only — must-fix #1 invariant).
2. **prefix-tolerant `inbox_route`** — a worker (`d99-myrepo/mybranch`,
   `@fleet_owner=so-d99` **bare**) routes to `dest=suborch submit=1 pane=<so-d99's
   pane>` even though the live window is now `so-d99-new-project-create`. The bare
   owner still auto-submits to the renamed sub-orch (`suborch_pane_for` prefix match).
3. **un-renamed regression** — a bare `so-d98` (never renamed) still resolves
   `dest=suborch submit=1` by exact match. No regression.
4. **d1-vs-d11 trailing-dash guard** — with only `so-d1-real` and `so-d11-foo` live,
   owner `so-d1` resolves to `so-d1-real` (prefix `so-d1-`) and **does NOT leak** to
   `so-d11-foo` (which does not start with `so-d1-`). The trailing `-` in the match
   is load-bearing and proven.
5. **`gate waiting` reads `meta window`** — with `d99` parked `gate1-wait`,
   `fleet gate waiting` emits the slugged `so-d99-new-project-create` (not bare
   `so-d99`), so `fleet reap`'s skip-guard matches the live renamed window and won't
   tear down a parked sub-orch.
6. **globs** — `so-d99-new-project-create` matches `so-*`; the ledger dir `d99`
   matches `d*/`; a worker name `d99-myrepo/mybranch` is NOT a `so-*` glob target
   (it is a window name, never a ledger dir — no collision).

---

## C. Edit set (what shipped)

`bin/fleet`:
- `persist_agent` — two new trailing cols: `wname` (col 8), bare `owner` (col 9).
- `cmd_restore` — read 9 cols; match by persisted `wname` (fallback legacy
  reconstruction); re-export the saved bare owner as `FLEET_SUBORCH_ID` into the
  `cmd_new` respawn so the worker comes back **prefixed AND owner-stamped**
  (must-fix #2).
- `cmd_new` — inject the `d<N>-` window prefix for a sub-orch-owned worker (gated on
  `FLEET_SUBORCH_ID` set ∧ `FLEET_NEW_SUBORCH_ID` unset); capture `_owner` (bare
  `so-d<N>`) and persist it. `@fleet_owner` stamp UNCHANGED (still bare).
- `suborch_pane_for` — new prefix-tolerant resolver (window `== owner` OR starts with
  `owner-`); used by the `inbox_route` owner branch.
- `resolve_or_spawn_suborch` — spawn lock re-keyed `.spawnlock-$wname` →
  `.spawnlock-$id` (stable across rename).
- `cmd_dispatch_rename` (new `fleet dispatch rename <id> <text>` verb) — under
  `.spawnlock-$id`: `suborch_slug`, `tmux rename-window`, `meta_set window`.
  **No owner re-stamp.**
- `suborch_slug` — new sanitizer (kebab + ≤28-char cap, partial-word trim, empty→'').
- `gate_waiting` / `cmd_reconcile` — read `meta window` (fallback `so-$id`) so a
  renamed window is resolved by the name-search liveness fallback and the reap-skip.

`bin/fleet-dash`:
- `is_suborch_name` — `^so-d[0-9]+(-[A-Za-z0-9-]+)?$` (suffix-tolerant).
- `suborch_ledger` / `card_meta_state` — `%%-*` strip to recover `d<N>`.
- `group_rows` — `HDR_BY_ID` bare→full map (pass 1) + bare-owner translation (pass 2);
  GNUM prefix-strip (`%%-*`, `#d`) so a digit-slug can't slurp.

`FLEET_SUBORCH.md` — new §3.0.1a: advisory "after classifying, before spawning a
worker, run `fleet dispatch rename <id> <slug>`" (skipped ⇒ stays `so-d<N>`, no
regression).

`bin/fleet-dispatch.sh` — ack left as `so-d<N>` (PLAN §4.E): now a TRUE prefix of the
eventual name, not a lie.

## D. Accepted residuals (documented, per PLAN §6 / SYNTHESIS)

- **`cmd_reap` `wrecon`** stays unprefixed: the live path (`wlive`, the actual window
  name `d<N>-repo/branch`) covers a worker while its window lives; a *dead*
  sub-orch-owned worker's needs-human `from=` could slip the `wrecon` fallback (low
  severity: dead worker + unread needs-human + non-force reap). `--force` overrides.
- **Rename is advisory** — a sub-orch that never renames stays `so-d<N>` =
  today's behaviour (proven: B.3 un-renamed regression).

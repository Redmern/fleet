# TDD GREEN — dashboard orchestrator cards (feature implemented, all proof tests pass)

**Phase 3b — implement.** The RED proving tests under
`_reports/dashboard-orchestrator-cards/proof/` now pass GREEN. The proof files
are **byte-identical** to the RED phase (verified: `git diff` over `proof/` and
`TDD-RED.md` is empty). No test was weakened.

```
$ bash _reports/dashboard-orchestrator-cards/proof/run.sh ; echo $?
  PASS  test_grouping.sh
  PASS  test_width.sh
  PASS  test_owner_real.sh
0
```

## What changed (scoped to `bin/fleet-dash`)

Per SYNTHESIS.md (authoritative revisions) + PLAN.md §2:

- **`owner_of <window_id>`** — reads the non-forgeable `@fleet_owner` tmux window
  option (`tmux show -wqv`), **cached PROCESS-LIFETIME** in `OWN_RAW` (owner is
  immutable per window), NOT cleared per `load_rows` (SYNTHESIS #5).
- **Classification helpers** — `is_suborch_name` (`^so-[A-Za-z0-9]+$`),
  `suborch_ledger` (cross-checks `<root>/.fleet/dispatch/<id>` so a worker merely
  *named* `so-*` is not mistaken for a header, PLAN edge 9), `urgrank`
  (blocked<idle<working<other), `card_meta_state`, `unowned_rule`.
- **`group_rows`** (called by `load_rows` after the urgency sort) — reorders
  `ROWS[]` into contiguous per-card display order via a decorate→stable-sort→
  undecorate on **original indices** (rows rebuilt from `OLDROWS` by index, so
  content is never round-tripped through string ops → byte-safe). Cards ordered
  by **MAX-SEVERITY-WITHIN** (blocked floats up), tie-break **NUMERIC** dispatch
  id (`10#` to avoid octal/lexical traps); within a card header-first then
  workers by (urgency rank, name); **unowned bucket last** (keeps flat order).
  Fills parallel `ROW_GID/ROW_ROLE/ROW_ANNOT` + `CARD_NWORK/CARD_WARN/CARD_STATE`.
  **Fail-silent / zero-regression:** no live sub-orch header ⇒ pure identity,
  `HAS_CARDS=0`, byte-identical flat list; never half-rewrites `ROWS[]`.
- **`sel`-follows-`window_id`** — `load_rows` stashes `field sel 3` before the
  rebuild and restores the index after the reorder (SYNTHESIS #4: prevents a 1s
  refresh re-ranking a card and the next `d`/`m` hitting the wrong agent).
- **`render` card chrome** (gated on `HAS_CARDS`) — header rows draw as a
  **labelled divider** (`hrule`, `so-<id> · state · N workers · ⚠M`); owned
  workers get a **2-space indent + tree glyph** (`├─`/`└─` last) prepended to the
  label (shrinks `LW` only — **no rail column moves**, so the documented
  `:692` scroll bug cannot regress); **tight-in / loose-between** spacing (0 gap
  header→worker, blank between cards); empty card → `(no workers yet)`; unowned
  bucket under a plain `╶ unowned ╴` rule; orphan-owner folded into unowned with
  `(owner so-dX gone|out of scope)`. NOT a four-sided box — no per-row side rails.
- **`hrule` off-by-one fix** — when a truncated label exactly filled the width,
  `printf '%.0s─' $(seq 1 0)` emitted a stray `─` (the pre-existing bug flagged
  in TDD-RED). Guarded so `n==0`/`w==0` produces no fill. This is what lets the
  divider reuse `hrule` and keeps the bottom border at `cols-1`.

## Verification beyond the proof suite

- `fleet doctor` — green; the dash still sources clean under `DASH_LIB`.
- Zero-regression: a no-`so-*` fixture renders `HAS_CARDS=0` with **no card
  chrome** (flat list unchanged).
- Visual render at COLUMNS=120 confirmed: `so-d2` (blocked worker → `⚠1`) floats
  above `so-d1`; tree-glyph workers nested; empty `so-d3` shows `(no workers
  yet)`; `╶ unowned ╴` bucket last; right rail aligned on every line.

## bash 5.3 gotchas hit + fixed during implementation

1. The GIDX feed read the whole `rank⇥num⇥gid` line into the key (missing
   `cut -f3`) → every `${GIDX[$gid]}` was unbound and cascaded to an empty
   `SEQ`/`ROW_GID`. Fixed by extracting field 3.
2. `${#IS_HEADER[@]}` on an **empty** `local -A` throws under `set -u` in bash
   5.3 — replaced with a plain `have_hdr` counter.

Files touched: `bin/fleet-dash` (+ this report). Not merged (`--no-self-merge`).
Next: two independent test agents try to break it before merge to `main`.

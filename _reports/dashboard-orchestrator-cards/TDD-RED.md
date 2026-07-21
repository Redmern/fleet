# TDD RED — dashboard orchestrator cards (proving tests, feature NOT implemented)

**Phase 3a — test author.** Executable proving tests live under
`_reports/dashboard-orchestrator-cards/proof/`. They are written FIRST: the
feature (per-orchestrator cards in `bin/fleet-dash`) is **not implemented**, so
every test **fails now — and fails only because the feature is absent.** Each
passing assertion inside a failing test is a deliberate regression guard
(width invariant, nav counts, zero-regression flat fallback, harness sanity).

Run them: `bash _reports/dashboard-orchestrator-cards/proof/run.sh`
(non-zero exit if any test fails). Current result: **all 3 FAIL (exit 1).**

## How they are isolated (never touch the live `pc` session / real ~/.fleet)

- Layer A drives `bin/fleet-dash` through its **`DASH_LIB=1 source` seam**
  (`bin/fleet-dash:80-89`, returns at `:1431` before the tty/alt-screen/event
  loop). Every run uses a throwaway `mktemp -d` root + a fabricated dispatch
  ledger; `fleet agents` is replaced by a fake bin emitting a canned 9-col TSV;
  `tmux`/`dash_root`/`owner_of` are stubbed; `FLEET_BIN` is repointed at the
  fake (the dash resets it to the real `fleet` on source — `:15`).
- Layer B (`test_owner_real.sh`) uses a **private `tmux -L fleettest_$$` socket**
  — its own server, killed + socket-file removed on EXIT. The live tmux server
  is never contacted. Skips with a note if `tmux` is unavailable.
- **Harness-bug guard:** two known traps were found and fixed so the *only*
  reason for failure is the missing feature, not the harness:
  1. `declare -A` must run at (sub)shell top level, never inside a helper
     function — otherwise the dash's caches (`GIT_TS`, …) become function-LOCAL,
     lose `-A`, and `render` later recreates them indexed → a `%101` pane key
     throws an arithmetic error. Sourcing is now inlined at subshell top level.
  2. A pre-existing `hrule` off-by-one (when a truncated label exactly fills the
     width, `n==0` and `printf '%.0s─' $(seq 1 0)` still emits one stray `─`, so
     the bottom hint border is `cols` not `cols-1` chars). This is unrelated to
     cards, so the width invariant is measured over the outer-rail content lines
     (where card alignment lives) and overflow is flagged only at `> COLS`, so
     this quirk does not taint the feature-absent signal.

---

## Test 1 — `proof/test_grouping.sh` (Layer A, pure-function grouping)

Fabricates a ledger (`d1/d2/d3` + numeric `d2/d10`) and a stubbed `fleet agents`
TSV, drives `load_rows`, asserts the reordered `ROWS[]` display order.

**Case 1 — full grouping.** Fixture: `so-d1`(idle) owns `fleet/fleet_aaa`(idle)+
`adv-pro`(working); `so-d2`(idle) owns `fleet/fleet_bbb`(**blocked**); `so-d3`
empty; `loose-worker`(idle) unowned. Asserts:
- grouped order `so-d2 fleet/fleet_bbb so-d1 fleet/fleet_aaa adv-pro so-d3 loose-worker`
  — card order by **max-severity-within** (d2's blocked worker floats the card
  above d1 despite d1<d2), tie-break **numeric** id (d1 before d3), header first
  then workers by urgency-rank then name (PLAN §2.3 / SYNTHESIS #2).
- `N == 7` (empty card header counts; no pending inflation). *(PASS now — count
  is feature-independent.)*
- `arows() == N + ORPHAN_ROW + SYSTEM_ROW == 7` (nav invariant). *(PASS now.)*
- `field <sel> 3` (window_id) maps per index after regroup — actions still
  target the right agent.
- empty card `so-d3` is a lone header immediately preceding the unowned bucket.

**Case 2 — numeric tie-break.** `so-d2` vs `so-d10` (equal severity) ⇒ order
`so-d2 w-bbb so-d10 w-ccc` (numeric, NOT lexical `d10<d2`).

**Case 3 — zero sub-orchs (zero-regression).** No `so-*` rows ⇒ `ROWS[]` order ==
today's flat urgency order, computed feature-independently by replaying
`load_rows`' filter+urgency pipeline. *(PASS now AND must stay passing — this is
the zero-regression default, SYNTHESIS #10 / VALUE-1.5.)*

**Exact failure now (feature absent):**
```
FAIL: case1 grouped ROWS[] order (severity-first, numeric tie, within-card)
      got:  fleet/fleet_bbb loose-worker fleet/fleet_aaa so-d1 so-d2 so-d3 adv-pro
      want: so-d2 fleet/fleet_bbb so-d1 fleet/fleet_aaa adv-pro so-d3 loose-worker
PASS: case1 N == live row count (7; empty card header counts, no pending inflate)
PASS: case1 arows == N + ORPHAN_ROW + SYSTEM_ROW
PASS: case1 arows == 7 (no synthetic rows in this fixture)
FAIL: case1 field <sel> 3 (window_id) maps per index after regroup
      got:  @203 @301 @201 @101 @102 @103 @202
      want: @102 @203 @101 @201 @202 @103 @301
FAIL: case1 empty card so-d3 immediately precedes the unowned bucket
      got:  5
      want: 0
FAIL: case2 numeric tie-break d2 BEFORE d10 (not lexical)
      got:  w-bbb w-ccc so-d2 so-d10
      want: so-d2 w-bbb so-d10 w-ccc
PASS: case3 zero-suborch ROWS[] == today's flat urgency order (byte-identical)
```
**Confirmation — reason is FEATURE ABSENT:** `load_rows` today emits the **flat
urgency list** with no owner grouping. The `got` rows are exactly that flat order
(blocked first, then idles, then working) — owned workers are scattered, headers
are not contiguous with their workers, the empty card is not isolated. This is
the correct "asserting grouped order, getting flat order" red signal. The
feature-independent assertions (N, arows, zero-suborch) pass, proving the harness
itself is sound.

## Test 2 — `proof/test_width.sh` (Layer A, render alignment + card chrome)

Captures `render` at `COLUMNS ∈ {60,80,120,200}` over the card fixture and at
tiny `LINES=8`. Asserts:
- **width invariant** — every outer-rail content line is the same display width
  (after stripping SGR) `== COLUMNS-1`; no line overflows `> COLUMNS`. *(PASS now
  — regression guard for the §2.4 card-chrome width-budget bug.)*
- **card chrome present** — a labelled divider rule carrying both the `so-<id>`
  AND the `─` rule glyph for each of `so-d1/so-d2/so-d3`, and a `unowned` bucket
  rule. *(FAIL now — the feature signal.)*
- **clean clip** — at `LINES=8`, output line count `<= LINES` (no overscroll).

**Exact failure now (feature absent):**
```
PASS: w60: every rail content line is the same display width (col aligned)
PASS: w60: rail content width == COLUMNS-1 (59); got common=59
PASS: w60: no line overflows the terminal (maxw=60 <= 60)
FAIL: w60: card divider rule present for so-d1
      got:  0
      want: 1
FAIL: w60: card divider rule present for so-d2 ... (so-d2, so-d3 identical)
FAIL: w60: unowned bucket rule present
      got:  0
      want: 1
```
(The width loop aborts on the first failing width, so only `w60` prints in the
red phase; all widths run once the feature lands.)
**Confirmation — reason is FEATURE ABSENT:** today `render` draws a flat list —
`so-d1` is a normal pill row (no `─` divider) and the word `unowned` is never
printed. The width-invariant assertions PASS, proving the harness measures real
render output correctly; only the missing card chrome fails.

## Test 3 — `proof/test_owner_real.sh` (Layer B, REAL `@fleet_owner`)

Private `tmux -L fleettest_$$` server: sets the real `@fleet_owner=so-d1` window
option on a worker window, then calls the dash's `owner_of` (NOT stubbed) with
its tmux routed to the private socket. Asserts `owner_of(worker) == so-d1` and
`owner_of(so-d1 window) == ""`.

**Exact failure now (feature absent):**
```
PASS: harness: @fleet_owner is really set on the worker window
FAIL: owner_of(worker window) reads real @fleet_owner == so-d1
      got:  
      want: so-d1
PASS: owner_of(so-d1 window itself) == '' (carries no owner)
```
**Confirmation — reason is FEATURE ABSENT:** `owner_of` does not exist in
`bin/fleet-dash` yet (`grep -n owner_of bin/fleet-dash` → none), so the call
resolves to nothing and returns "". The harness sanity assertion (the option IS
really set on the private server) PASSES, proving the failure is the missing
`owner_of`, not a tmux/harness problem. The empty-owner case passes vacuously
(absent function returns "" == expected "").

---

## Summary

| Test | Feature-absent assertions that FAIL | Regression guards that PASS now |
|---|---|---|
| test_grouping | grouped order, field/sel map, empty-card isolation, numeric tie | N, arows, zero-suborch flat == today |
| test_width | card dividers (so-d1/2/3), unowned rule | width invariant, no-overflow, clip |
| test_owner_real | `owner_of` reads real `@fleet_owner` | option-really-set sanity, empty-owner |

`run.sh` exit **1**; each test exit **1**; **zero stderr** (no syntax/harness
errors). Every failure is attributable solely to the unimplemented feature.

**Next (green phase):** implement `owner_of` + `^so-<id>$` classification, the
`load_rows` grouping reorder, and the `render` divider+indent card chrome — per
PLAN §2 and the SYNTHESIS revisions — until `run.sh` is green. Only the test
files are committed in this phase; the dashboard change is NOT made here.

# Test verdict — dashboard orchestrator cards

**Verdict: NEEDS-WORK** (loop once — build on what exists, two localized fixes).

Two independent testers, complementary findings (not in conflict):

## Confirmed working (both testers, strong evidence)
- Grouping / max-severity-within ordering / numeric tie-break / ownership via
  real `@fleet_owner` (un-stubbed, private tmux socket) — WORKS.
- Orphan-owner `gone` vs `out of scope` annotations — WORKS.
- Tree glyphs `├─`/`└─`, empty-card `(no workers yet)`, unowned bucket — WORKS.
- **Nav/action correctness post-regroup** (the debate's headline risk): cursor
  follows `window_id` across a re-rank; `d`/`m` hit the right window — WORKS
  (B, 12/12, drove `load_rows` twice with a state change between).
- **Width invariant** at odd widths 61/73/99/137 — WORKS (B, 33/33).
- **Zero-regression**: `ROWS[]` byte-identical to pre-feature with no `so-*`;
  rendered bytes identical except a *bundled* `hrule` off-by-one fix that is a
  strict improvement (B). WORKS.
- **Fail-silent** on malformed `meta.tsv` / missing ledger / dup header:
  `N == #ROWS` always, never blanks — WORKS (B, 16/16).

## Defects to fix (the loop)

### D1 — card-mode overscroll + half-written header at clip boundary (Tester A) — MUST FIX
At pane heights where the per-row card chrome consumes the final slot, render
emits **> `slots` lines** (terminal scrolls; top border drifts off → flicker),
and a clipped `so-<id>` header **falls through to the worker-row printer**,
drawing the header as a plain `state·repo·pills` row instead of a divider.
- Root cause (`bin/fleet-dash` render loop ~881–968): the **worker-row print
  (~954–968) is not guarded** by `(( drawn < slots ))`; and the header block's
  `continue` (~908) sits **inside** the `drawn < slots` guard (~894), so a
  clipped header skips the `continue` and falls through to the worker print.
- Why it escaped: `test_width.sh` "clean clip" samples **only LINES=8** (passes).
  A sweep of LINES 3..24 shows overscroll at 6,10,13,14,…
- Fix direction: guard the worker-row print with `(( drawn < slots ))`; lift the
  header `continue` out of the clip guard so a clipped header is skipped, never
  re-rendered as a worker. **Flat path is unaffected** (regression is card-only).

### D2 — `owner_of` process-lifetime cache is dead code (Tester B, F-1) — FIX (cheap)
`owner_of` memoises into `OWN_RAW[$wid]` but its only caller invokes it via `$()`
command substitution (`group_rows:453`), so the cache write lands in a subshell
and is discarded — it re-queries `tmux show -wqv @fleet_owner` every non-header
row every 1s refresh (the CON adviser's Attack-2 perf concern, unmitigated).
- Severity LOW (correctness fine — `@fleet_owner` is immutable per window), but
  the code promises an optimization it doesn't deliver, and the per-refresh tmux
  fork count is exactly what the design said it avoided.
- Fix: populate a global instead of `$()` (e.g. `owner_of "$wid"; own=$REPLY`),
  or drop the cache + comment. Prefer the real cache (keep the design's intent).

## Loop plan (test-first, build on existing)
1. Add a RED proving test: sweep LINES (e.g. 3..24) over a card fixture asserting
   (a) output line count ≤ LINES (no overscroll), (b) no clipped `so-<id>` header
   renders as a worker pill row. Confirm it FAILS on current HEAD for D1.
2. Add/strengthen a check that `owner_of` actually memoises (D2) — assert the
   tmux query count stays flat across multiple `load_rows`.
3. Implement both fixes; all proof tests (old + new) GREEN; re-run testers' spot
   checks. Then GATE 2.

# Synthesis — dashboard orchestrator cards

**Verdict: BUILD** (with the debate-revised design below).

The debate was decisive and the three lenses converge:

- **PRO**: the sort+decoration strategy is the right core — flat-index nav
  preservation is code-verified across every action handler (`:1453-1602`);
  `@fleet_owner` is the correct non-forgeable ownership signal; zero-regression
  default is free.
- **CON**: the SORT half is sound and valuable; the **full four-sided box chrome
  is the wrong half** — it concentrates 5 of 7 named risks (width re-budget vs the
  documented scroll bug `:692-694`, broken gap rails, clip-open straddling cards,
  doubled vertical cost) and its alignment proof has a blind spot exactly where
  the risk lives. Recommends indent + tree-glyphs instead of an enclosing box.
- **VALUE**: grouping *without* re-surfacing per-card urgency **regresses the
  board's reason to exist** (a blocked worker must float up). Max-severity marker
  is the price of admission, not a nice-to-have. Tight-in/loose-between spacing
  beats colour for binding.

## What we BUILD (revised plan — folds in the debate)

Core stays: derive ownership from the **`@fleet_owner` tmux window option**
(non-forgeable, set at spawn), reorder `ROWS[]` in `load_rows` into contiguous
per-card display order so the flat-index `sel`/`field`/`arows`/action machinery
is **unchanged**. `render` decorates group boundaries. Then these MANDATORY
revisions from the debate:

1. **Drop the full four-sided box.** Visual division instead = a **labelled
   header rule** per card (reuse `hrule`, which already truncates safely) + a
   **2-space indent + tree-glyph** (`└─`/`├─`) on worker labels (shrink `LW`
   only — no rail column moves, so the `:692-694` scroll bug *cannot* regress) +
   **tight-in / loose-between spacing** (0 gap header→first worker, ≥1 gap
   between cards). No per-worker `│ │` side rails, no bottom rail, no card-aware
   gap/fill-loop rewrite. Kills CON attacks 1a/1b/1c/1d and 7.
2. **Card order by max-severity-WITHIN the card**, not the sub-orch's own state
   (CON-4 / VALUE-1). Tie-break by **numeric** dispatch id (`d2` before `d10` —
   CON landmine). Unowned bucket sorts last. This keeps "blocked floats to the
   top" as a card-block.
3. **Card max-severity marker on the header** — colour the header rule + append
   `⚠N` when any worker is blocked/stalled (reuse `state_pcol`/`sev_pcol`).
   Price of admission (VALUE-1).
4. **`sel`-follows-`window_id` remap** — MANDATORY and EARLY. Stash `field sel 3`
   before reload, restore the index after reorder. Without it a 1s refresh
   re-ranks a card and the next `d` (close window) hits the wrong agent —
   data-loss, not cosmetic (CON-3 / VALUE-2.1).
5. **`owner_of` cached process-lifetime** keyed by window_id (owner is immutable
   per window), NOT cleared per `load_rows` (CON-2 perf).
6. **Fail-silent reorder** that degrades a malformed `meta.tsv`/owner to
   "unowned" and never half-rewrites `ROWS[]` (would desync `N`/`sel`).
7. **Header worker-count must not lie.** Count only live rows actually shown.
   Skip the pending-from-`workers.tsv` decoration in v1 (it would paint a live
   filtered/doubly-hidden worker as `pending` — CON-6 / VALUE-3.3). Empty card
   gets a `(no workers yet)` placeholder (VALUE-1.6).
8. **Orphan-owner** (worker whose owner sub-orch isn't a live header) → fold into
   the unowned bucket with inline `(owner so-dX gone)` annotation; distinguish
   *gone* (no ledger dir) from *out-of-scope* (ledger dir exists) via a dir check
   (CON-5 / VALUE-2.2). Simpler than a synthetic "(gone)" card.
9. **Unowned bucket** = plain labelled rule (`╶ unowned ╴`), less chrome than a
   card (VALUE-1.4).
10. **Zero-regression flat fallback**: no `so-*` rows ⇒ exactly today's flat list,
    no card chrome. First proof assertion (VALUE-1.5).

## What we SKIP (debate consensus)

Collapse/expand (breaks flat-index nav), per-card accent colour (collides with
the semantic palette, dilutes severity), pending-from-`workers.tsv` v1, card
count in the top title.

## Proof (revised)

Keep the **DASH_LIB pure-function harness** (Layer A) asserting grouped `ROWS[]`
order + nav invariants + zero-regression default + width invariant across widths
+ clean clipping at small `LINES`. **Add real-`@fleet_owner` coverage** (CON-2
coverage inversion): a throwaway `tmux -L fleettest` socket that sets the real
window option and asserts `owner_of` reads it — do NOT only stub `owner_of`. Plus
`fleet doctor` smoke + a live `fleet main --reload` visual confirm.

# Adviser debate — CON / red-team

**Lens:** skeptic. Target: `bin/fleet-dash` (1605 lines). Plan: `PLAN.md` (group
agents into per-orchestrator box cards). Verdict up front: **the SORT half is
sound and valuable; the BOX-CHROME half concentrates 5 of the 7 named risks and
should be cut in favour of indent + tree-glyphs.** Concrete attacks below, then
the simpler design.

---

## TL;DR for the decision gate

- **Ship the grouping reorder** (`load_rows`, §2.3). Clustering owned workers
  under their sub-orch is the real win and is geometry-free.
- **Do NOT ship the nested `┌─┐ │ │ └─┘` card box.** It forces a width re-budget
  on a TUI whose width math is already documented as fragile (`:692-694`),
  breaks the inter-row gap rails, clips *open* at the bottom, doubles per-card
  vertical cost, and its alignment proof has a blind spot exactly where the risk
  lives. Replace with a 2-space label indent + `▾ so-dN` header + `└─` tree
  prefix. Zero changes to `inner`/`slots`/`cw`/`LW`.
- **Two changes the plan marks "optional" must be MANDATORY:** (a) card order by
  *max-severity-within-card*, not the sub-orch's own state (Attack 4); (b)
  `sel`-follows-`window_id` remap (Attack 3). Without (b), a 1-second refresh
  moving the cursor turns the next `d`/`m`/`s` keystroke into a wrong-agent —
  and `d` closes a window. That is a data-loss bug, not polish.

---

## Attack 1 — width / alignment re-budget for nested chrome (the dominant risk)

The plan calls this "the real render risk" (§2.4, §3) and still under-scopes it.
The width invariant holds today because every content line is built to **exactly**
`cw = inner - 2*PAD_X` (`:694`): pills are fixed `PW=PILL_W+4`, the label is
padded by `fit_left` to `LW`, and `LW = cw - np*PW - CF - (np+1)*G` (`:770`)
back-solves the filler. The print at `:801` is `│ <ins> <content=cw> <ins> │`.

**1a — ROW_GAP rails break.** Inside a card every line must become
`│ │ <content> │ │`. The plan's §2.4 sketch only redraws *worker* and *header*
rows. It never touches the inter-agent gap (`:805-807`), which prints
`│ <blank=inner> │` full-width. Inside a card those gap rows will render with
**no card rails** — the card's `│ │` columns vanish on every gap row, so the box
sides come out dashed/broken. Same for the bottom-fill loop (`:857-860`).

**1b — cards clip OPEN, not "cleanly".** §2.4 claims wrapping the new rule prints
in `drawn<slots` makes a straddling card "clip cleanly". It does not. The
fallback fill loop at `:857-860` is **unconditional** and card-unaware. If
`drawn` hits `slots` *between* a card's header and its `└` bottom rule, the fill
loop immediately draws plain full-width `│ blank │` rows down to the bottom
border — leaving an **unclosed card**: `│ │` columns running into the void with
no closing corner. The plan's edge 7 says this clips fine; it does not, unless
the fill loop (`:857`) and the bottom border (`:867`) are also made card-aware.
That is more surface than §2.4 admits.

**1c — the alignment proof (§4.2) has a blind spot.** The proof strips SGR and
asserts every line has the same `${#s}` display width. But `${#s}` counts the
powerline pill caps `PILL_L`/`PILL_R` (`:208-209`, nerd-font half-circles) and
the box-drawing glyphs as **1 column each**. On a terminal that renders any of
them double-width (common with mis-fonted nerd glyphs), the *arithmetic* stays
constant — the proof PASSES — while the *terminal* misaligns and wraps→scrolls
(the `:692-694` failure). Adding a card `│` immediately right of a pill's `` cap
puts a colored-background glyph flush against a rail column, the worst case for
this. The proof validates the math, not the render. **False confidence precisely
where the documented bug lives.**

**1d — vertical cost roughly doubles.** Today an agent costs 1 row + 1 gap
(`:803-807`). A card costs: top-rule + header-row + gap + N·(worker+gap) +
bottom-rule. The header info is **duplicated** — §2.4 embeds
`so-d7 · running · "title" · 4 workers` in the top rule AND renders the sub-orch
as its own pill row below it. At `LINES=40` (`slots=38`), after the title and the
config/repo row (which eats up to 2 `drawn` rows, `:727-738`), three small cards
exhaust the budget and everything below clips. The flat list fits ~12 agents in
the same height. This directly worsens Attack 4 and Attack 7.

---

## Attack 2 — per-row `@fleet_owner` queries at scale

§2.1/§2.6 claim `owner_of` is "the same cost class as `git_cached`/`harness_of`".
**It is the most expensive class, not the same one.**

- `git_cached` (`:149`) has a 4s TTL; `cost_cached` (`:158`) 10s; `harness_of`
  (`:167`) caches for the **whole process lifetime**. The plan's `owner_of`
  clears `OWN_RAW=()` **every `load_rows`** (§2.1 "Clear at the top of
  `load_rows`"), i.e. every `REFRESH=1` second (`:17`). So it is **one `tmux show`
  fork per row per second** — uncached across loads. At N=30 that is +30
  subprocess forks/sec on a hot loop that *already* runs `mode_label` (`:117`, an
  **uncached** `tmux capture-pane | grep | sed` per row per refresh).
- The cache lifetime is simply wrong for the data: owner is **immutable per
  window_id** (the plan says so itself). It should be cached like `harness_of`
  (process-lifetime, keyed by window_id), never cleared per load. The plan picked
  per-load clearing and then mis-stated the resulting cost as cheap.
- The render pass also needs owner (§2.4 "re-derived in render, cheap & cached")
  → either it shares `OWN_RAW` or it doubles the calls. Plus a new `suborch_meta`
  cache doing `meta.tsv` file reads per card per render (§2.7). More IO in the 1s
  loop.
- **Coverage inversion:** Layer A (§4.1) *overrides* `owner_of` (`:444` of the
  proof sketch), so the deterministic layer never exercises the real
  `tmux show -wqv @fleet_owner`. Only Layer B does, and Layer B is "gate on
  `command -v tmux`, skip-with-note" (§4.3). In any tmux-less CI the single most
  novel line in the change has **zero** coverage.

Fix is cheap: process-lifetime cache keyed by window_id. But the plan as written
adds measurable per-second load and tests the wrong half.

---

## Attack 3 — `sel` positional index jumps cards on regroup (edge 8)

The plan keeps `sel` a flat index (§2.3) and dismisses edge 8 as "not new — the
same risk exists on urgency re-sort". **It is materially worse, and it is a
destructive-action bug, not cosmetic.**

- Today a re-sort only moves rows when an agent **changes state** — infrequent,
  and it shifts one row past the cursor. The plan adds a **second reorder axis**:
  card order by the sub-orch's own urgency (§2.3 step 2). Now any **sub-orch**
  changing state reorders an entire **card block** (header + all its workers) past
  the cursor at once. Cursor displacement becomes card-sized.
- `REFRESH=1` (`:17`) means a reorder can fire *between two of your keystrokes*.
  Every per-row action keys off `field "$sel" …` (Enter `:1520`, `m`, `s`, `d`,
  `v`, `h`). `d` = close window (`:1588`). So: select worker → 1s refresh hoists a
  card → your `d` kills a **different** worker's window. Near-certain during any
  multi-key interaction, and effectively irreversible.
- The mitigation (stash `field sel 3` = window_id, restore the index post-reorder)
  is marked "optional polish" (§5 step 5, edge 8 "if feasible"). **It must be
  mandatory and early.** Build order §5 puts it *after* the risky render work —
  backwards.

---

## Attack 4 — group-first / urgency-within buries a blocked worker

The flat urgency sort (`:365-368`) exists for one reason: a **blocked** agent
floats to row 0, impossible to miss. Grouping destroys that global guarantee.

- A blocked worker inside `so-d9` (a low-urgency *idle* sub-orch, sorted to the
  bottom by §2.3 step 2) now sits below every other card. At realistic `LINES`
  with card overhead (Attack 1d), that card is **clipped off the bottom** — and
  its header, hence the §2.4 "card max-severity marker", is clipped with it. **A
  blocked worker can become entirely invisible**, which the flat list never
  permitted.
- §2.4's mitigation marker only helps if the header is on-screen. The plan
  conflates two different signals: message-severity (the `✉N ⚠M` title summary,
  `:714` — still works) versus **state-blocked** (an agent on a permission prompt,
  conveyed *only* by sort position + red pill). Grouping removes the position
  guarantee for the latter and the marker doesn't restore it when clipped.
- **The plan rejected the right default.** §2.3 step 2 considered keeping global
  urgency and rejected it to preserve "bounded cards". Invert: order cards by
  **max severity of any worker within** (a card containing a blocked/needs-human
  worker hoists to the top *as a block*), tie-broken by dispatch id. That keeps
  cards contiguous AND preserves "blocked floats up". Non-negotiable for a
  human-in-the-loop dashboard.

---

## Attack 5 — sub-orch in `pc`, workers in `pc_hidden` (edge 6)

Edge 6 is mostly right: both pass the `load_rows` session filter (`:362`,
`SESS || SESS_hidden`) and group via window-id-addressable `@fleet_owner`. The
gap is the **inverse** case the plan doesn't separate from edge 4:

- If a worker's `@fleet_owner` names a sub-orch whose **header row was filtered
  out** (sub-orch parked into a session outside `SESS`/`SESS_hidden`, or
  doubly-hidden per Attack 6), the worker is owned-but-headerless. The plan's
  edge-4 path renders it under an **orphan-owner card `so-dX (gone)`** — but the
  sub-orch is **alive**, merely out of filter scope. A live sub-orch mislabeled
  "(gone)". The "(gone)" detection (§3 edge 4: "owner not in the set of live
  `so-*` wnames") cannot distinguish *dead* from *filtered-out*. Needs a ledger
  cross-check (`<root>/.fleet/dispatch/<id>` exists ⇒ "elsewhere", not "gone").

---

## Attack 6 — doubly-hidden dropped workers (edge 7)

Edge 7 waves `pc_hidden_hidden` workers away as "pre-existing, out of scope". For
the flat list that is defensible — one missing row among many. **The card feature
makes it a visible lie.**

- §2.4's header advertises a worker **count**. A doubly-hidden worker is dropped
  by the filter (`:362`) — it is **live (has a pane)** yet absent from `ROWS[]`.
  So the count is wrong with no indication: the card claims "4 workers" and shows
  3, or claims a different number from `workers.tsv`. The feature elevates a
  low-stakes drop into an inconsistent headline number.
- §2.5's "pending decoration would surface it as `pending`" is actively
  **misleading**: the worker is running, not pending. The pending logic ("in
  `workers.tsv`, no live ROWS match") fires because the row was *filtered*, not
  *absent*, and paints a live worker as `pending: <branch>`. Worse than silent.
- Either fix the count to be honest (`N live shown` / annotate "+M hidden") or
  state the limitation in the header. "Out of scope" is not acceptable when the
  feature's headline number depends on the dropped rows.

---

## Attack 7 — clipping at small LINES with top/bottom rules

Beyond 1b: at `LINES=8` (the proof's own stress, §4.2) `slots = rows-2 = 6`. The
title is outside slots (`:715`), `PAD_Y` eats 1 (`:719-721`), the config/repo row
eats up to 2 (`:727-738`). That leaves ~3 `drawn` rows for content. One minimal
card needs top-rule + header + ≥1 worker + bottom-rule = **4** — it cannot even
fit, so it clips open (1b) every time at small height.

- The synthetic **`⌫ orphans`** and **`⚙ system`** rows (`:813-853`) — which
  surface reaped-worker and orchestrator/gate messages — live at the **tail**
  (`:813`, `:835`), drawn last. Card chrome overhead pushes them off-screen
  first. Those rows carry needs-human signal; card boxes make the
  human-attention rows the first casualties of clipping. Combined with Attack 4,
  there are now two independent paths to "blocked/needs-human signal clipped
  away".

---

## A correctness landmine the plan glosses: the decorate-sort (§2.3)

The "pure-bash, no external sort needed" parenthetical undersells it. `ROWS[]`
lines already contain 8 literal tabs (`:364`). The grouping is a **multi-pass
join**, not a one-liner:

1. Pass 1: scan all rows, assign each `so-<id>` an integer `groupRank` (by
   sub-orch urgency, then id).
2. Pass 2: for each worker, look up its owner's `groupRank` (bash assoc-array
   keyed by so-id).
3. Decorate `groupRank \t roleRank \t urgRank \t <original 8-field line>`,
   `sort -t$'\t' -k1,1n -k2,2n -k3,3n`, strip 3 cols.

Two concrete bugs the proof won't catch:

- **Lexical id sort.** §2.3 tie-breaks "by dispatch id ascending (`d1<d2<…`)".
  String sort puts `d10` before `d2`. The proof fixture (§4.1) only has
  `d1/d2/d3` — single digit — so it never exercises `d10`. Need numeric id
  extraction.
- Every pass is a **fail-silent-must-not-blank-the-dash** hazard (CLAUDE.md;
  §3 risk 4). A malformed `meta.tsv`/owner value must degrade to "unowned", never
  abort the reorder mid-array and leave `ROWS[]` half-rewritten (which would
  desync `N`/`sel`/`field`).

---

## The simpler, safer design (recommended)

The plan's own framing — "grouping is a SORT + DECORATION, not a navigation
rewrite" — is exactly right. **Keep the sort; drop the box.**

1. **Grouping reorder in `load_rows`** — keep it (the valuable, geometry-free
   half). Owned workers cluster under their sub-orch. Order cards by
   **max-severity-within** (Attack 4), tie-break by **numeric** dispatch id.
2. **Header = a normal row**, distinguished by a prefix glyph in its label
   (`▾ so-d7 · running · "title"`). It is already a selectable `ROWS[]` entry —
   **zero new geometry**.
3. **Worker rows = the existing row, label indented.** Prepend a tree prefix to
   the label and shrink `LW` by its width: `label="  └─ $orig"` (or `├─` for
   non-last). The print at `:801` is **unchanged**; `inner`/`slots`/`cw` are
   **unchanged**; only the filler shrinks. The `:692-694` scroll bug **cannot
   regress** because no rail column moves.
4. **Unowned bucket** = sort last under one dim labelled *content* line
   (`╶ unowned ╴` built with `fit_left`, not a structural `hrule`). No box.
5. **`sel`-follows-`window_id`** — mandatory (Attack 3).

What this kills outright:

- Attack 1a (gap rails), 1b (clip-open), 1c (proof blind spot), 1d (double
  height): **all gone** — there are no boxes to break, leave open, mis-measure,
  or pad. The alignment proof becomes trivial (every line still built to exactly
  `cw`).
- Attack 7's card-overhead-at-small-LINES: gone — a card now costs **1** extra
  row (the header), like any agent, so more agents stay visible and the synthetic
  rows survive clipping longer.

What's lost: the literal enclosing rectangle. A 2-space indent + `▾ so-dN`
header + `└─` tree glyphs reads as "nested" on any terminal, costs ~1 row/card
instead of 3, and fits more agents. The box buys aesthetics and pays in 5 of the
7 risks. **Not worth it.** If a visual "card" feel is still wanted later, it can
be layered on *after* the sort+indent ships and proves stable — additive, not a
prerequisite.

---

## If the box ships anyway — the non-negotiables

1. Make the ROW_GAP rows (`:805-807`), the bottom-fill loop (`:857-860`), and the
   bottom border (`:867`) **card-aware**, or cards clip open (1a/1b).
2. Card order by **max-severity-within**, not sub-orch state (Attack 4).
3. `sel`-follows-`window_id`, **mandatory and first**, not §5 step 5 (Attack 3).
4. `owner_of` cached **process-lifetime** by window_id, never per-load (Attack 2).
5. Header worker-count must not lie about filtered/doubly-hidden workers
   (Attack 6); distinguish "(gone)" from "(out of scope)" via a ledger-dir check
   (Attack 5).
6. Numeric dispatch-id sort; fail-silent reorder that never half-rewrites
   `ROWS[]` (landmine §).
7. Add a width-invariant proof that asserts against a **real captured render at a
   double-width-glyph terminal**, not only `${#s}` arithmetic (Attack 1c) — or
   accept that §4.2 proves nothing about the documented scroll failure.

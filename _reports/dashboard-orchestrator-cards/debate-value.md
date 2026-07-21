# Adviser debate — VALUE-ADD / UX lens

**Question:** beyond bare grouping, what ADDITIONS make the orchestrator-card
dashboard materially better for the user? What is worth it NOW vs later, and
what should we SKIP? Grounded in `bin/fleet-dash` render + `PLAN.md`.

**The user's actual goal:** *clear separation of which workers belong to which
orchestrator.* Every addition below is judged against that — does it sharpen the
ownership read, or is it decoration that competes with it?

---

## 0. The headline finding

**Grouping, on its own, REGRESSES the dashboard's reason to exist.** Today the
list is urgency-sorted (`load_rows` awk map `blocked<idle<working<other`,
`:365-368`): a blocked worker floats to the top where the human sees it. The
plan's group-first reorder (§2.3) deliberately drops that — a blocked worker now
sits *inside* its card, possibly below an idle card. The plan acknowledges this
(§2.3 "Note this trade-off") and proposes a card-level max-severity marker as the
mitigation, but files it as a sub-bullet.

It is not a sub-bullet. **It is the price of admission.** If we group without
re-surfacing per-card urgency, we trade the dashboard's one job (make the
human look at the thing that's stuck) for tidiness. So the #1 value-add is not an
*addition* at all — it's a *correction* that must ship in the same change as the
grouping. Everything else is genuinely optional.

---

## 1. Tier 1 — ship WITH the core grouping (load-bearing)

### 1.1 Card max-severity marker on the header — THE top addition
A buried blocked/stalled worker must flag its card. The machinery already
exists and is free to reuse:
- `state_pcol` (`:229`) and the stall test (`:778`, `working` + `age>STALL_SEC`
  → red `stalled`) already classify a row's severity.
- The header rule is drawn with `hrule` (`:667`), whose label is embedded in a
  `printf`. Wrapping that `printf` in the worst worker's state colour (red if any
  worker blocked/stalled, else neutral) costs one `max` accumulation over the
  group — the same pass that counts workers (§1.2).
- Precedent: the top title already carries a cross-agent `✉N ⚠M` roll-up
  (`:714`). A per-card roll-up is the same idea, scoped to the card.

Recommended marker: colour the header rule + append a glyph, e.g.
`┌─ so-d7 · running · 4 · ⚠1 ──┐` where `⚠1` = one blocked/stalled worker. Reuse
`sev_pcol`/`state_pcol` so the colour vocabulary matches the rest of the board.
**Do this or do not group.**

### 1.2 Worker count + dispatch state in the header
`so-d7 · running · 4 workers` (plan §2.4). Split the cost:
- **Count** is free — it's the size of the group you already assembled.
- **State** (`queued/planning/running/done`) needs one `meta.tsv` read per card,
  cached per load (plan §2.7 `suborch_meta`). One `awk -F'\t'` mirroring
  `meta_get` (`bin/fleet:1143`), fail-silent → bare `so-<id>` on miss. Cheap,
  same cost class as `harness_of`/`git_cached`. Worth it: state is what tells the
  human "this card is still planning" vs "running 4 in parallel".
- **Title** from `instruction.txt` first line — keep but DON'T invest. It is
  long, noisy, LLM-written. `hrule` already hard-truncates the label (`:673-674`)
  so it can't break the rule; lean on that and move on. Count+state carry the
  value; title is garnish.

### 1.3 Spacing: tight inside a card, loose between cards
The single cheapest legibility win, and it beats colour. `ROW_GAP=1` (`:213`)
currently spaces every agent equally. For grouping, the gestalt comes from
*differential* spacing: **0 rows between a header and its first worker** (binds
them), **≥1 row between cards** (separates them). This is pure render tuning in
the existing `drawn<slots` gap loop (`:805-807`) — no new state. It does more for
"which workers belong to which orchestrator" than any accent colour, for ~free.

### 1.4 Unowned bucket — present, but LESS chrome than a card
Correctness, not optional: main-spawned/legacy workers (no `@fleet_owner`) must
stay visible. But a full card box around them would imply they're an
orchestrator, which they aren't. Render them under a plain labelled rule
(`╶ unowned ╴`, no indent, no box) so they read as the loose pile — visually
*subordinate* to real cards. Plan §2.4 already says this; I'm reinforcing the
"deliberately less decorated" choice as the right one.

### 1.5 Zero-regression flat fallback — non-negotiable
No `so-*` rows ⇒ render exactly today's flat list, zero card chrome (plan edge
1). This is what makes the change safe to ship: anyone not using the dispatch
layer sees no difference. Must-have, must be the first assertion in the proof.

### 1.6 Empty-card placeholder `(no workers yet)`
A spawned sub-orch with no live workers (e.g. `so-d8` mid-planning) renders its
header + one dim `(no workers yet)` row (plan §2.5). Cheap (group has only a
role-0 row), and it answers "did the dispatch take?" at a glance. This is the
80/20 of the whole `workers.tsv` pending story (see §3.3) — keep it, skip the
rest.

---

## 2. Tier 2 — cheap fast-follow (same PR if time, else immediately after)

### 2.1 sel-follows-window_id on reload (edge 8) — elevate from "optional polish"
The plan files this as polish (§5.5). **Grouping promotes it to near-necessary.**
Today `sel` is positional; an urgency re-sort already moves it occasionally. With
cards, a single worker changing state can re-rank its whole card and shift *every
row below it* — so the cursor lands on a different agent between 1s refreshes,
and your next `d`/`s`/Enter (`:1564`/`:1575`/`:1520`, all `field sel …`) hits the
wrong agent. That's not cosmetic; it's a mis-action risk the grouping introduces.
Fix is contained to `load_rows`: stash `field sel 3` (window_id) before the
reload, find its new index after. No touch to the flat-index invariant. Do it
alongside grouping.

### 2.2 Orphan-owner: annotate in unowned, don't build a "gone" card (simplify)
Edge 4 (worker whose `@fleet_owner` sub-orch was reaped) — plan proposes a
distinct `so-d3 (gone)` synthetic card. **Cheaper and just as correct:** drop the
worker into the unowned bucket with an inline annotation `(owner so-d3 gone)`.
Same guarantee (worker never silently dropped), no second card-construction path,
no "is this header real or synthetic" branching. The ownership *fact* is
preserved in the annotation. Recommend the annotation over the synthetic card.

---

## 3. SKIP — gold-plating or high-cost / low-value

### 3.1 Collapse/expand a card — SKIP
Breaks the plan's central simplification. The whole low-risk thesis is "ROWS
pre-sorted = display order ⇒ flat `sel`/`field`/`arows` machinery unchanged"
(§1.5, `:515-519`). Collapsing means removing workers from the selectable set —
re-introducing exactly the index bookkeeping the plan eliminated, plus a new
keybind and per-card UI state. And it solves a problem we don't have: the pane
already clips cleanly at `slots` with no scroll (`:692-694`). With a handful of
workers per card on one screen, there's nothing to collapse. Revisit only if
cards routinely overflow — which is a different feature.

### 3.2 Per-card accent colour — SKIP (actively harmful)
The board's palette is **semantic**: red=blocked/behind, yellow=dirty/plan,
cyan=ahead/edit, green=idle/clean, magenta=done (`state_pcol`/`mode_pcol`/
`git_pcol`, `:229-238`). Assigning each card its own hue collides with that
vocabulary and dilutes the one colour that matters — severity (§1.1). The card
*box* (rule + indent + rail) already binds workers to their header without
spending colour. Reserve colour for state; let geometry do the grouping. At most,
a single neutral/dim rail for all cards — never per-card hues.

### 3.3 Pending workers from `workers.tsv` — SKIP for v1 (explicit second pass)
Render-only dim `pending: <branch>` lines (plan §2.5). Three strikes for *now*:
1. It depends on the **least reliable** signal — `workers.tsv` is LLM-written,
   best-effort, may be stale or missing (§1.7, risk list). Everything else in the
   design deliberately routes around it via the non-forgeable `@fleet_owner`.
2. Mapping a `(repo,branch)` to its expected window name is fiddly and duplicates
   `bin/fleet:719`/`:430` logic in the dash.
3. It's decoration that must NOT shift `sel`/`N` — extra care for a *preview*
   benefit.

The empty-card placeholder (§1.6) already answers "this card exists but nothing's
live yet," which is the real user question. Ship pending only if users later ask
"what's it *going* to spawn?" — and log it as deferred so it's not mistaken for
done.

### 3.4 Card count in the top title — SKIP (trivial, not worth the line)
`FLEET · pc · 9 agents · 3 orch` is near-free but adds noise to a title that's
already carrying the `✉N ⚠M` roll-up (`:713-714`). The cards are right there to
be counted. Leave it.

---

## 4. One under-sold win already in the design

The card header **is a real, actionable agent row** (plan §2.4): because it's a
normal `ROWS[]` entry, `Enter` jumps to the sub-orch pane, `s` sends it a message,
`m` cycles its mode — for free. Worth stating loudly in the UI/docs: the card
isn't passive chrome, its header is *the handle to the orchestrator*. That's a
genuine UX gain (one keystroke from "I see the card" to "I'm talking to its
orchestrator") that costs nothing and should be surfaced in the key hints
(`:865`).

---

## 5. Bottom line — priority order

| # | Addition | When | Why |
|---|---|---|---|
| 1 | Card max-severity marker on header | **NOW (with core)** | Without it, grouping buries the urgency the board exists to surface. Not optional. |
| 2 | Worker count + dispatch state in header | **NOW** | At-a-glance card identity; count free, state = 1 cached file read |
| 3 | Tight-in / loose-between spacing | **NOW** | Cheapest legibility win; beats colour for binding |
| 4 | Unowned bucket as plain rule (less chrome) | **NOW** | Correctness; keep subordinate to cards |
| 5 | Zero-suborch flat fallback | **NOW** | The safety guarantee; first proof assertion |
| 6 | Empty-card `(no workers yet)` | **NOW** | 80/20 of the pending story |
| 7 | sel-follows-window_id remap | **Fast-follow** | Grouping makes the cursor-jump mis-action frequent |
| 8 | Orphan-owner = annotate-in-unowned | **Fast-follow** | Simpler than a synthetic "gone" card, same guarantee |
| — | Collapse/expand | **SKIP** | Breaks flat-index nav; no overflow problem to solve |
| — | Per-card accent colour | **SKIP** | Collides with the semantic palette, dilutes severity |
| — | Pending from workers.tsv | **SKIP (v1)** | Least-reliable signal, fiddly; placeholder covers the need |
| — | Card count in title | **SKIP** | Trivial noise |

**The one thing to take away:** ship the **card max-severity marker** as part of
the grouping itself, not after. It is the difference between cards that organize
the board and cards that hide the very worker the human needs to see.

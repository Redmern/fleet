# Dashboard: group agents into per-orchestrator cards

Research + implementation plan. **No code written.** Target file:
`bin/fleet-dash` (~1604-line bash TUI). Dispatch `d8` / slug `cards-research`.

---

## 0. TL;DR

The dashboard is today a **flat, urgency-sorted list** of agent rows. We want
each sub-orchestrator (window `so-<id>`) to render as a **bounded card** that
visually *hosts* the worker rows it owns, separated from other cards and from a
trailing "unowned / main-spawned" bucket.

**The ownership signal already exists and is non-forgeable: the `@fleet_owner`
tmux window option.** `cmd_new` stamps every worker spawned by a sub-orch with
`@fleet_owner=so-<id>` (`bin/fleet:837`); a sub-orch's own window carries no
owner and is named `so-<id>` (`bin/fleet:1283`). Live proof on the running
session:

```
pc        so-d7           (owner empty)   ← sub-orch / card header
pc        so-d8           (owner empty)
pc        so-d9           (owner empty)
pc_hidden inbox-styling-research  so-d7   ← worker, owned by so-d7
pc_hidden inbox-styling-pro       so-d7
pc_hidden inbox-styling-con       so-d7
pc_hidden inbox-styling-value     so-d7
```

So grouping does **not** require parsing `workers.tsv` for the live mapping —
`@fleet_owner` gives it directly, per row, with no dependence on the sub-orch
LLM having remembered to append to the ledger. `workers.tsv` is used only as a
*secondary* signal: to render **pending** workers (declared but not yet live)
and **empty** sub-orchs, and to title the card from `meta.tsv`.

**Lowest-risk implementation strategy: grouping is a SORT + DECORATION, not a
navigation rewrite.** Reorder `ROWS[]` inside `load_rows` so each card's rows
are contiguous (header `so-<id>` first, then its workers, then the next card,
then the unowned bucket last). Because `sel`, `field()`, every nav/action key
and the synthetic orphans/system rows all index `ROWS[]`/`N` linearly, once
`ROWS[]` is in display order the existing flat-index machinery keeps working
**unchanged** — `render()` only has to draw a card top-border before each
group header and a card bottom-border after its last worker.

---

## 1. How the dashboard works today (cited)

### 1.1 Row pipeline — `load_rows` (`bin/fleet-dash:357-376`)

```
ROWS[] entry = state \t label \t window_id \t window_name \t since \t pane_id \t age \t ready   (8 fields, 1-indexed via field())
```

- Source: `"$FLEET_BIN" agents` (= `agents_tsv`, `bin/fleet:3914`).
- Filtered to this project: keeps rows whose session (field 3 of the raw TSV) is
  `$SESS` **or** `${SESS}_hidden` (`:362`); drops `wname == main` (`:363`).
- Sorted by **urgency**: an `awk` prefix maps `blocked=0 idle=1 working=2 other=3`,
  `sort -n`, `cut` (`:365-368`). This is the *only* ordering today — flat.
- `N=${#ROWS[@]}` (`:369`). Selectable total = `N + ORPHAN_ROW + SYSTEM_ROW`
  (`:372`), and `sel` is clamped into that range (`:373-375`).
- `field <rowidx> <col>` = `cut -f<col>` on `ROWS[$rowidx]` (`:378`).

### 1.2 The raw rows — `agents_tsv` (`bin/fleet:152-209`)

Emits `state \t label \t session \t window_id \t window_name \t since \t pane_id \t age \t ready`
(daemon path via `fleet.list` JSON → python, `:155-195`; tmux-option fallback
when the daemon is down, `:202-207`). **It does NOT currently emit
`@fleet_owner`.** `label` = last two cwd segments (`:164`). The fallback path
already reads `@`-options per pane, so it could emit owner cheaply; the daemon
path would need fleetd to surface the option (see §2.6 for why we instead query
it in the dash).

### 1.3 Worker window naming (the mapping back to `workers.tsv`)

- Repo worker window name = `<repo-basename>/<branchdir>` where `branchdir` is the
  branch with `/`→`_` (`bin/fleet:719`). So `workers.tsv` line
  `fleet<TAB>fleet/session-picker-fit-content` ⇒ window name
  `fleet/fleet_session-picker-fit-content`. The dedup grep in `FLEET_SUBORCH.md:63`
  is exactly `fleet ls | grep -F "<repo>/${branch//\//_}"`.
- Scratch worker window name = `scratch_wname` output = the label, suffixed
  `-2/-3…` on collision (`bin/fleet:430-435`). `workers.tsv` records these as
  `scratch<TAB><label>` (seen in `d5/workers.tsv`).

### 1.4 Render — `render` (`bin/fleet-dash:687-868`)

- Computes geometry: `inner = cols-3`, `slots = rows-2`, `cw = inner-2*PAD_X`
  (`:692-696`); `drawn` counts content rows against `slots`.
- Draws: top border w/ title (`hrule '╭' '╮'`, `:715`), `PAD_Y` pad rows, the
  config/repo-glance pill row (`:726-738`), then the **agent loop**
  (`for i in 0..N-1`, `:753-808`).
- Each agent row: `<state pill> <label> <git pill> <mode pill> <✉N pill> <cost>`,
  width-budgeted by progressively dropping cost→mode→✉→git as `cw` shrinks
  (`:769-775`). Selection marker bar `▌` drawn when `i==sel`, focus-coloured
  (`markc`, `:702-704`, `:797-802`). `ROW_GAP=1` blank row between agents
  (`:805-807`).
- **Synthetic rows** after the loop:
  - `⌫ orphans` at index `N` (`:813-831`) — unread msgs from reaped/gone senders.
  - `⚙ system` at index `N+ORPHAN_ROW` (`:835-853`) — orchestrator/gate notes.
  - Both are *selectable* (their indices feed `open_msgs`, `:547-557`).
- Box drawing primitives: `hrule <l> <r> <inner-w> [label]` (`:667-682`) draws a
  `─` rule with optional embedded ` label `; `PILL_L`/`PILL_R`/`PILL_W=7`
  rounded pills (`:208-227`); `pill <text> <color256>` (`:221-227`). Side rails
  are literal `│ … │` printed per line.

### 1.5 Navigation / selection / actions

- `arows() = N + ORPHAN_ROW + SYSTEM_ROW` (`:515`); `nav_up/down/top/bot`
  move `sel` within that (`:516-519`); `drain_nav` coalesces key bursts (`:1408`).
- Every action keys off `field "$sel" <col>`: Enter=jump (`:1520`, window_id col 3),
  `e`=msgs (`:1487`/`open_msgs`), `m`=mode (`:1564`), `s`=send (`:1575`),
  `d`=close (`:1588`), `v`=diff (`:1595`), `h`=hide (`:1535`). All guard
  `sel >= N` → "orphans row" (`:1538` etc).
- **Critical invariant:** every one of these treats `ROWS[]`/`sel` as a flat
  linear array. *Therefore if `ROWS[]` is pre-sorted into display order, none of
  them change.*

### 1.6 The DASH_LIB test seam (`bin/fleet-dash:80-89`, `:1431`)

`DASH_LIB=1 source bin/fleet-dash <sess>` loads every function but **does not**
grab the tty, the alternate screen, or enter the event loop (`:83`, `:1431`
`return 0`). This is the harness hook for the proof (see §4).

### 1.7 Dispatch ledger (the secondary signal)

`<root>/.fleet/dispatch/<id>/`:
- `meta.tsv` — `key<TAB>value`, append-with-last-wins (`meta_get`/`meta_set`
  `bin/fleet:1142-1150`). Keys seen: `created`, `window` (=`so-<id>`),
  `window_id`, `state` (queued→planning→running→…→done), optional `depends-on`.
- `workers.tsv` — `repo<TAB>branch` lines, **written by the sub-orch LLM** per
  `FLEET_SUBORCH.md:70-75` (`printf '%s\t%s\n' "<repo>" "$branch" >> …`). NOT
  written by any `bin/fleet` code — it is a convention, hence best-effort and
  possibly stale/missing. A key may appear in multiple dispatches' files (that
  IS the dedup, `FLEET_SUBORCH.md:68`).
- `instruction.txt` — the dispatched instruction; `STATUS.md` — human rollup.

---

## 2. Implementation plan

### 2.1 Ownership derivation at render time — primary signal `@fleet_owner`

Add a cached per-pane/per-window accessor mirroring `harness_of`
(`bin/fleet-dash:167-174`):

```
declare -A OWN_RAW                      # window_id -> @fleet_owner (so-<id> | "")
owner_of() { # window_id -> owning sub-orch window name, or "" (cached for the load cycle)
  local wid="$1"
  if [ -z "${OWN_RAW[$wid]+x}" ]; then
    OWN_RAW[$wid]=$(tmux show -wqv -t "$wid" @fleet_owner 2>/dev/null)
  fi
  printf '%s' "${OWN_RAW[$wid]}"
}
```

Clear `OWN_RAW=()` at the top of `load_rows` (it is rebuilt each load; owner is
immutable per window so a load-lifetime cache is correct and cheap — one
`tmux show` per row, same cost class as the existing `git_cached`/`harness_of`
queries, and bounded by `N`).

> Use `tmux show -wqv` (the worker windows live in `${SESS}_hidden`; the option
> is a *window* option set at spawn via `tmux set -w … @fleet_owner`, so it is
> readable by window_id regardless of which session currently hosts the window).

### 2.2 Classify each row

For row `i` with `wname=field i 4`, `wid=field i 3`:

| Test | Class | Group key |
|---|---|---|
| `wname` matches `^so-[A-Za-z0-9]+$` | **sub-orch / card header** | its own `wname` (`so-<id>`) |
| `owner_of wid` is non-empty (`so-<id>`) | **owned worker** | that `so-<id>` |
| else | **unowned / main-spawned** | `""` (sentinel "unowned" bucket) |

A `so-<id>` regex match is the header discriminator (cheap, no tmux call). The
owner lookup is only needed for non-`so-*` rows.

### 2.3 Reorder `ROWS[]` into display order (the core change, in `load_rows`)

After the existing urgency sort populates `ROWS[]`, run a **second, stable
grouping pass** that rewrites `ROWS[]` so rows are contiguous per card:

1. Build, for each row, `(group, role, urgency-rank)` where
   `role`: header=0, worker=1; `urgency-rank` = the same `blocked<idle<working<other`
   ranking already used (reuse the awk map or recompute from `field i 1`).
2. Determine **group display order**. Recommended: order cards by the sub-orch's
   *own* urgency (a blocked/working sub-orch surfaces above an idle one), tie-broken
   by dispatch id ascending (`d1<d2<…`, stable, matches ledger creation order).
   The **unowned bucket sorts last** (it is the "loose" pile; an explicit choice —
   keeps cards as the visual primary unit). *Alternative considered:* keep global
   urgency as the top-level sort and only cluster — rejected because it would
   interleave a card's idle worker below another card, breaking the "bounded
   card" goal. **Decision: group-first, urgency-within.** Note this trade-off in
   the card header so a blocked worker inside a low-urgency card is not missed —
   surface a card-level max-severity marker on the header (see §2.4).
3. Within a group: header (role 0) first, then workers by urgency-rank then name.
4. Emit the reordered array into a new `ROWS[]`. Keep the 8-field schema **exactly
   as-is** — grouping is positional only; no new ROWS field is required because
   owner is re-derivable via `owner_of` at render time (and cached).

Pure-bash implementation sketch (no external sort needed if done with an
index-decorate-sort-undecorate using `sort -t$'\t' -k…`):

```
# decorate: groupRank \t roleRank \t urgRank \t <original ROWS line>
# sort -t$'\t' -k1,1n -k2,2n -k3,3n -k4   (stable)
# strip the 3 decoration cols back into ROWS[]
```

`groupRank` is computed by first scanning all rows to assign each `so-<id>` an
integer (by sub-orch urgency then id); the unowned bucket gets `groupRank=∞`.
Workers inherit their owner's `groupRank`.

`N`, `field()`, `sel` clamping (`:372-375`) are untouched — `N` is still
`${#ROWS[@]}`.

### 2.4 Card visual design in `render` (within existing box style)

The agent loop (`:753-808`) gains a **group-boundary detector**. Track
`prev_group` across iterations; for each row, compute `cur_group` (via the §2.2
classification — re-derived in render, cheap & cached). Emit:

- **On entering a new card** (and the row is its `so-<id>` header):
  draw a nested card **top rule** spanning the inner content width, with the
  header label embedded — reuse `hrule` with a sub-box corner set, e.g.
  `┌`/`┐` (single-line, to read as *nested* inside the dashboard's `╭`/`╮`
  double-feel rails), or `├`…`┤` tee-style if we want the card to visually
  attach to the left rail. The label carries the card identity + ledger state:

  ```
  ┌─ so-d7 · running · "inbox styling" · 4 workers ───────────────────┐
  ```

  - `so-<id>` from `wname`.
  - state from `meta_get <led>/<id> state` (cheap file read, cache per load).
  - title: first line / a slug of `instruction.txt` (truncate hard via the
    existing `hrule` label-truncation, `:673-674`).
  - worker count = live workers in this group (+ ` (Np)` pending from
    `workers.tsv` not-yet-live, see §2.5).
  - **card max-severity marker**: if any worker in the card is blocked/stalled,
    colour the header rule / append a `⚠`/`●` so a buried-urgent worker in a
    low-urgency card is still flagged (mitigates the §2.3 group-first trade-off).

- **The header row itself** then renders as a normal selectable agent row
  (state/git/mode pills work — you *can* `m`/`s`/Enter a sub-orch), but
  **indented one level** and drawn *inside* the card rails so it reads as the
  card's own line. Reuse the existing pill render; just shift its left inset by
  a card-indent (e.g. `│ │ ` → content) and bound the right with the card's `│`.

- **Worker rows**: drawn indented under the header, each prefixed with the card's
  left rail `│` (and the dashboard's outer `│`), so they are visually *enclosed*:

  ```
  │ ┌─ so-d7 · running · "inbox styling" · 4 workers ──────────────┐ │
  │ │  ⏵ working   inbox-styling-pro    …pills…                    │ │
  │ │  ⏸ idle      inbox-styling-con    …pills…                    │ │
  │ └──────────────────────────────────────────────────────────────┘ │
  ```

- **On leaving a card** (next row's group differs, or last row): draw the card
  **bottom rule** `└…┘`, then the existing `ROW_GAP` blank as inter-card
  separation (bump to a 1-row gap minimum between cards for clear division).

- **Unowned bucket**: render under a plain labelled rule (no card box, or a
  distinct `╶ unowned ╴` style) so main-spawned/legacy workers stay visible but
  visually subordinate to the cards. (If there are zero sub-orchs, fall back to
  exactly today's flat list — pure additive, zero regression when dispatch
  layer is unused.)

**Width accounting (the real render risk).** The card adds **2 columns of
indent** (`│ ` left) and consumes **1 column** for the card's right `│`. So the
per-worker usable label width `cw` must be reduced by the card chrome
(`CARD_INDENT + 1`) **only for rows inside a card**. The existing budget math
(`LW = cw - np*PW - CF - (np+1)*G`, `:770`) must subtract the card chrome from
`cw` before computing `LW`. Header rules use `hrule` against `inner - card
chrome`. Get this wrong and the right rail misaligns / the line wraps and
scrolls (the bug `:692-694` warns about). **Reuse** `hrule`, `pill`, `fit_left`,
`PAD_X`/`ins`/`ins1` unchanged; introduce `CARD_PAD`/`card_ins` analogues.

All `drawn < slots` guards must wrap the new top-rule and bottom-rule prints too,
so a card that straddles the bottom of the pane still clips cleanly without
overscrolling.

### 2.5 Pending + empty cards (the `workers.tsv` secondary use)

- **Empty sub-orch** (header row exists, zero owned live workers, e.g. `so-d8`
  before it spawns anyone): render the card with a single dim placeholder row
  `(no workers yet)`. Detected purely from "this group has only a role-0 row".
- **Pending workers** (`workers.tsv` lists a `(repo,branch)` whose window is not
  yet live): optional enhancement — read `<led>/<id>/workers.tsv`, map each to
  its expected window name (`<repo>/<branch//\//_>` or the scratch label), and if
  no live ROWS row matches, draw a dim non-selectable `pending: <branch>` line
  inside the card. **These are NOT in `ROWS[]`** (they have no pane), so they
  must be drawn as render-only decoration and must NOT shift `sel`/`N`. Mark
  this lower-priority — it is the only place `workers.tsv` is consulted, and it
  can ship in a second pass.

### 2.6 Why query `@fleet_owner` in the dash rather than extend `agents_tsv`

- Keeps the entire change in `bin/fleet-dash` (the stated target) — no `bin/fleet`
  or `bin/fleetd` edits, no risk to the daemon JSON contract or the `fleet ls`
  static output that other callers depend on.
- The dash already does per-row tmux queries (`git_cached`, `harness_of`,
  `mode_label`), so one more `tmux show -wqv @fleet_owner` per row is idiomatic
  and within budget (≤1 `fleet agents` RPC/sec is the hot-path cost; the tmux
  option reads are local and fast).
- `agents_tsv`'s daemon path would otherwise need fleetd to surface
  `@fleet_owner`, which is a cross-process change for a display-only feature.
- *Future optimization (note, not now):* if per-row tmux calls ever bite, add
  `owner` as a 9th ROWS field sourced once in `load_rows` — the schema is the
  documented seam at `:356`.

### 2.7 Touch-points summary

| Area | Change | Reuse |
|---|---|---|
| `load_rows` (`:357`) | `OWN_RAW=()` reset; second grouping/reorder pass after the urgency sort | existing urgency awk map |
| new `owner_of` | cached `tmux show -wqv @fleet_owner` | pattern of `harness_of` `:167` |
| new `suborch_meta` cache | `meta_get` state/title per `so-<id>` | `bin/fleet` `meta_get` semantics (re-impl tiny awk in dash, or shell out `fleet`?) |
| `render` agent loop (`:753-808`) | group-boundary detector; card top/bottom rules; per-card indent + width re-budget; unowned bucket; empty/pending decoration | `hrule`, `pill`, `fit_left`, `ins`/`ins1`, `drawn<slots` guards |
| `render` synthetic rows (`:813-853`) | unchanged (still indices `N`, `N+ORPHAN_ROW`) | — |
| nav/selection/actions (`:515-519`, `:1453-1602`) | **unchanged** (ROWS pre-sorted = display order) | — |

> Reading `meta.tsv` from the dash: prefer a tiny local `awk -F'\t'` (mirroring
> `meta_get` `bin/fleet:1143`) over shelling `fleet` per card, to stay fail-silent
> and avoid N subprocesses. Cache per load. Root = `dash_root` (`:249`).

---

## 3. Edge cases & risks

**Edge cases**
1. **No sub-orchs at all** (dispatch layer unused / off) → no `so-*` rows, every
   row unowned → render exactly today's flat list. Zero-regression default.
2. **Empty sub-orch** (`so-d8` with no workers yet) → card header + `(no workers
   yet)` placeholder.
3. **Unowned/main-spawned worker** (`fleet new` straight from main) → no
   `@fleet_owner` → unowned bucket at the tail.
4. **Worker whose owner sub-orch is dead/gone** (sub-orch reaped, worker lingers):
   `@fleet_owner=so-d3` but no live `so-d3` header row. Render an **orphan-owner
   card** titled `so-d3 (gone)` so the worker is not silently dropped, OR fold
   into unowned with an annotation. Decision: orphan-owner card (preserves the
   ownership fact). Detect: owner value not in the set of live `so-*` wnames.
5. **Shared worker in 2 dispatches** (`workers.tsv` dedup, `FLEET_SUBORCH.md:68`):
   `@fleet_owner` is a *single* value (the spawner), so the live row groups under
   exactly one card — unambiguous. `workers.tsv` cross-listing only affects the
   optional pending-row decoration; render the pending line under each dispatch
   that lists it (harmless duplication of a *pending* hint, never of a live row).
6. **Sub-orch in visible `pc` but workers in `pc_hidden`** (observed live): both
   pass the `load_rows` session filter (`SESS` or `${SESS}_hidden`), so both
   appear and group correctly across the session boundary via `@fleet_owner`
   (which is window-id addressable regardless of host session).
7. **Doubly-hidden session** (`pc_hidden_hidden` observed — a worker owned by a
   sub-orch that was itself spawned from the hidden session): such a row is
   **dropped by the existing `load_rows` filter** (only `SESS`/`SESS_hidden`
   pass). Pre-existing behaviour, **out of scope**, but flagged as a risk: the
   card may show fewer workers than `workers.tsv` claims. The pending-row
   decoration (§2.5) would at least surface it as `pending`.
8. **Selection resting on a row that moves** after a regroup/reload: `sel` is a
   positional index; a reorder can land `sel` on a different agent between
   refreshes. Today the same risk exists on urgency re-sort, so it is not new —
   but grouping reorders more often. *Mitigation (optional):* after reorder, if
   feasible, remap `sel` to follow the previously-selected `window_id` (stash
   `field sel 3` before reload, find its new index after). Worth doing to avoid
   the cursor "jumping cards" when an agent changes state.
9. **`so-<id>` name collision with a real worker named `so-…`**: regex anchors on
   `^so-<id>$` and we cross-check against ledger dirs (`<root>/.fleet/dispatch/<id>`
   exists) to confirm it is a genuine sub-orch, not a worker that happens to be
   named `so-foo`. Cheap dir-existence test.

**Risks**
- **Width/alignment** is the dominant risk: card indent + rails must be subtracted
  from `cw` for in-card rows or the right rail misaligns and lines wrap→scroll
  (the documented `:692-694` failure). Mitigate with the proof's width assertions
  (§4) across narrow widths.
- **Per-row tmux calls**: bounded by `N`, cached per load, same class as existing
  queries — low risk, but the proof should time a synthetic 30-row session.
- **`workers.tsv` staleness**: it is LLM-written and may lag/miss. We deliberately
  do **not** depend on it for the live grouping (only optional pending hints), so
  staleness degrades gracefully (a live worker still groups via `@fleet_owner`).
- **Fail-silent discipline** (CLAUDE.md): every new `tmux`/`awk`/file read must
  `2>/dev/null` and fall back (missing owner → unowned; missing meta → bare
  `so-<id>` title). Never let a card-render error blank the dashboard.

---

## 4. Proof design (REQUIRED)

No test runner exists (CLAUDE.md "No build, no test suite"); `fleet doctor` is the
smoke test. We build **isolated scenario scripts** under a throwaway
`FLEET_SESSION` + fabricated ledger, never touching the live `pc` session. Two
layers + doctor.

### 4.1 Layer A — pure-function harness via the DASH_LIB seam (primary, deterministic)

The seam (`:80-89`, `:1431`) loads every function without tty/loop. We stub the
one external input (`fleet agents`) and fabricate a ledger, then drive
`load_rows` + the new grouping/classification functions directly and assert on
`ROWS[]` order and a captured `render`.

Harness skeleton (`_reports/dashboard-orchestrator-cards/proof/test_grouping.sh`):

```bash
#!/usr/bin/env bash
set -u
TMP=$(mktemp -d)                      # throwaway root + ledger; never the live root
export PC_TUNE_ROOT="$TMP"            # neutralise the live-map config row
SESS=testcards

# 1. Fabricate a ledger: 2 sub-orchs w/ workers, 1 unowned worker, 1 empty sub-orch
mkdir -p "$TMP/.fleet/dispatch"/{d1,d2,d3}
printf 'window\tso-d1\nstate\trunning\n' > "$TMP/.fleet/dispatch/d1/meta.tsv"
printf 'fleet\tfleet/aaa\nscratch\tadv-pro\n'      > "$TMP/.fleet/dispatch/d1/workers.tsv"
printf 'window\tso-d2\nstate\tplanning\n' > "$TMP/.fleet/dispatch/d2/meta.tsv"
printf 'fleet\tfleet/bbb\n'                         > "$TMP/.fleet/dispatch/d2/workers.tsv"
printf 'window\tso-d3\nstate\tqueued\n'   > "$TMP/.fleet/dispatch/d3/meta.tsv"  # empty
: > "$TMP/.fleet/dispatch/d3/workers.tsv"

# 2. Stub `fleet agents` -> canned 9-col TSV (state label sess wid wname since pane age ready)
#    Encode ownership via a parallel fixture the stubbed owner_of() reads (see below),
#    OR — preferred — stub tmux. Simplest: override owner_of after sourcing.
cat > "$TMP/fakefleet" <<'EOF'
#!/usr/bin/env bash
[ "$1" = agents ] && cat <<'TSV'
working	x/y	testcards	@101	so-d1	t	%101	5	
idle	x/y	testcards	@102	so-d2	t	%102	5	
working	r/a	testcards_hidden	@201	fleet/fleet_aaa	t	%201	5	
idle	r/a	testcards_hidden	@202	adv-pro	t	%202	5	
working	r/b	testcards_hidden	@203	fleet/fleet_bbb	t	%203	5	
idle	m/n	testcards	@301	loose-worker	t	%301	5	
TSV
EOF
chmod +x "$TMP/fakefleet"

# 3. Source the dash as a library; point it at the stub + fake root
DASH_LIB=1 FLEET_ROOT="$TMP" source bin/fleet-dash "$SESS"
FLEET_BIN="$TMP/fakefleet"
dash_root(){ printf '%s' "$TMP"; }     # force the fabricated root

# 4. Override owner_of to the fixture (avoids needing a real tmux):
#    @101/@102 = sub-orchs (empty), @201/@202 owned by so-d1, @203 by so-d2, @301 unowned
owner_of(){ case "$1" in @201|@202) echo so-d1;; @203) echo so-d2;; *) echo "";; esac; }

load_rows

# 5. ASSERTIONS on ROWS[] display order ----------------------------------------
#    Expected grouped order (group-first, header then workers, unowned last):
#      so-d1, fleet/fleet_aaa, adv-pro, so-d2, fleet/fleet_bbb, so-d3?, loose-worker
#    (so-d3 empty card has only its header row.)
order=(); for ((i=0;i<N;i++)); do order+=("$(field "$i" 4)"); done
expected="so-d1 fleet/fleet_aaa adv-pro so-d2 fleet/fleet_bbb so-d3 loose-worker"
[ "${order[*]}" = "$expected" ] || { echo "FAIL order: ${order[*]}"; exit 1; }
echo "PASS: grouping order"
```

**Success criteria (Layer A):**
- `ROWS[]` order is contiguous per card: every owned worker is immediately
  preceded (transitively) by its `so-<id>` header with no foreign row between.
- The empty sub-orch `so-d3` is present as a lone header (no workers after it).
- The unowned `loose-worker` sorts into the tail bucket, after all cards.
- `N` equals the live row count (6 here; `so-d3` header counts, pending workers
  do not inflate `N`).
- A second assertion captures `render` to a fixed `COLUMNS`/`LINES` (set
  `tput` via `COLUMNS=120 LINES=40`, or stub `tput`) and greps the output for:
  card top-rule containing `so-d1`, worker lines appearing **between** the
  `so-d1` top-rule and its `└` bottom-rule, and the right rail `│` aligned at a
  constant column on every line (width invariant — the alignment proof).

### 4.2 Layer A width invariant (the alignment proof)

Capture `render` at several widths (`COLUMNS` ∈ {60, 80, 120, 200}) and assert:
- Every printed content line, after stripping SGR escapes, has the **same
  display width** (the right rail column is constant) — this catches the §2.4
  card-chrome width-budget bug directly.
- No line exceeds `COLUMNS-1` (the no-scroll invariant, `:692-694`).
- Card bottom-rule appears for every card that had a header, even one straddling
  `slots` (run with a tiny `LINES=8` to force clipping; assert no overscroll =
  output line count ≤ `LINES`).

### 4.3 Layer B — real-tmux integration (exercises the live `@fleet_owner` path)

Layer A stubs `owner_of`; Layer B proves the **actual** `tmux show -wqv
@fleet_owner` query works. In a throwaway tmux server/session
(`tmux -L fleettest new-session -d -s testcards …`, a private socket so the live
server is untouched):

```bash
tmux -L fleettest new-session -d -s testcards -n so-d1
tmux -L fleettest new-window  -t testcards -n fleet/fleet_aaa
tmux -L fleettest set -w -t testcards:fleet/fleet_aaa @fleet_owner so-d1
tmux -L fleettest set -w -t … @agent_state working   # so agents_tsv fallback emits it
# … fabricate the 4-scenario set, then run owner_of / load_rows against this server
```

Then assert `owner_of` returns `so-d1` for the worker window and `""` for the
`so-d1` window itself. Tear down with `tmux -L fleettest kill-server`. This is
the only layer that needs tmux; gate it on `command -v tmux` and skip-with-note
otherwise (fail-silent CI parity).

### 4.4 Layer C — `fleet doctor` smoke

Run `fleet doctor` before/after to confirm the dash still loads (it sources
clean under `DASH_LIB`) and no dependency wiring regressed. Plus a live
**`fleet main --reload`** (CLAUDE.md) on a dev session as the manual visual
confirmation that real `so-d7`/`so-d8`/`so-d9` cards render with their actual
workers nested.

### 4.5 Overall success criteria (feature is proven when)

1. **Grouping order** (Layer A): owned workers are contiguous under their
   `so-<id>` header; unowned bucket last; empty sub-orch renders a lone card.
2. **Visual division** (Layer A render capture): each card is bounded by a
   top-rule (with `so-<id> · state · title · Nworkers`) and a bottom-rule, with
   ≥1 blank row between cards; workers visibly indented inside the rails.
3. **Width invariant** (Layer A §4.2): constant right-rail column across widths;
   no line > `COLUMNS-1`; clean clipping at small `LINES`.
4. **Live owner query** (Layer B): `owner_of` reads the real `@fleet_owner`.
5. **Navigation intact**: `sel`/`field`/`arows` still index `ROWS[]` linearly;
   `nav_down` from the last card lands on `⌫ orphans`/`⚙ system` exactly as
   today (assert `arows() == N + ORPHAN_ROW + SYSTEM_ROW`, synthetic indices
   unchanged). Add a Layer A assertion that selecting each row index and reading
   `field sel 3` (window_id) returns the expected window — i.e. actions still
   target the right agent post-regroup.
6. **Zero-regression default** (Layer A, no-suborch fixture): with no `so-*`
   rows, `ROWS[]` order == the pure urgency order (today's behaviour) and render
   == today's flat list (no card chrome emitted).
7. `fleet doctor` green; `fleet main --reload` shows real cards.

---

## 5. Recommended build order

1. `owner_of` + `^so-<id>$` classification + ledger-dir cross-check (§2.1–2.2).
2. `load_rows` grouping reorder (§2.3) + Layer A order/nav assertions (§4.1, 4.5#5,6).
3. `render` card chrome + width re-budget (§2.4) + Layer A width invariant (§4.2).
4. Empty/orphan-owner/unowned buckets (§2.4, edge 2/3/4) + assertions.
5. `sel`-follows-window_id remap (edge 8) — optional polish.
6. Pending-row decoration from `workers.tsv` (§2.5) — optional second pass.
7. Layer B tmux integration + `fleet doctor` + live `--reload` visual check.

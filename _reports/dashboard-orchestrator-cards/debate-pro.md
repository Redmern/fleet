# Debate — PRO: the `@fleet_owner`-driven sort+decoration plan is right

Lens: advocate. Verdict up front, then the grounded case.

**Verdict: YES — this is the best available design, and the plan is more
defensible than it lets on.** The core architectural bet ("grouping is a SORT +
DECORATION, not a navigation rewrite") is not merely *a* reasonable choice; given
how `bin/fleet-dash` is actually written, it is the *only* design that adds cards
without re-deriving the dashboard's entire interaction model. I verified the
load-bearing claims against the code. Below: why the bet is correct, why it is
low-risk, what it gets right, and three strengths the plan under-sells.

---

## 1. The central claim is true — I checked every action handler

The plan's whole risk profile rests on one sentence (PLAN §1.5, §2.3): *if
`ROWS[]` is pre-sorted into display order, none of the nav/selection/action code
changes.* This is the kind of claim that is easy to assert and fatal if wrong.
It is **correct**, and provably so by enumeration:

- `field()` is `cut -f<col>` on `ROWS[$1]` (`fleet-dash:378`) — purely positional,
  order-agnostic.
- `N=${#ROWS[@]}` and the `sel` clamp (`:369-375`) depend on count, not order.
- `arows() = N + ORPHAN_ROW + SYSTEM_ROW` (`:515`); `nav_up/down/top/bot`
  (`:516-519`) move `sel` within that range — they never inspect a row's content.
- Every action key resolves its target by `field "$sel" <col>` **at press time**:
  Enter/jump reads `field "$sel" 3` (`:1520`), `m`/`s`/`d`/`v`/`h` read
  cols 2/3/6 (`:1568`, `:1579`, `:1592`, `:1599`, `:1539`), `e`→`open_msgs` reads
  `field "$sel" 4` (`:554`). I read all of `:1453-1602`: there is **no** code
  path that assumes "row *i* is the same agent it was last refresh," and no code
  that assumes urgency order specifically.
- The synthetic `⌫ orphans` / `⚙ system` rows are addressed as `N` and
  `N+ORPHAN_ROW` (`:548-551`, `:816`, `:838`) — offsets from `N`, untouched by
  reordering the first `N` entries.

So reordering `ROWS[]` inside `load_rows` is **behaviour-preserving by
construction** for the entire control surface. That is a strong, code-grounded
guarantee, not optimism. The plan earns its "navigation/actions: **unchanged**"
row in the §2.7 touch-point table.

Crucially, this also means the design **rides an invariant the dashboard already
relies on every refresh.** The existing urgency sort (`:365-368`) *already*
reorders `ROWS[]` on every load — an idle agent that starts working jumps rank
today. The plan's grouping pass is the *same kind of operation* the code survives
1×/sec already. It is not introducing reordering; it is composing a second,
stable key onto an array that is sorted-then-consumed-positionally by design.

## 2. The ownership signal is the right one — non-forgeable and already set

The plan grounds grouping in the `@fleet_owner` tmux **window** option, stamped
at spawn by `cmd_new` (`bin/fleet:837`), with a sub-orch's own window named
`so-<id>` and carrying no owner (`bin/fleet:1283`). This is the correct primitive
for three reasons the plan states and one it under-sells:

1. **It is set by code, not by the LLM.** Contrast `workers.tsv`, which
   `FLEET_SUBORCH.md:70-75` has the sub-orch *LLM* append to — best-effort,
   possibly stale or missing. Deriving live grouping from `@fleet_owner` means the
   feature degrades *gracefully*: a worker with a missing ledger entry still
   groups correctly (PLAN §3 "risks"). Picking the machine-written signal over the
   model-written one as the source of truth is exactly the right instinct in a
   system whose own CLAUDE.md preaches fail-silent degradation.
2. **It is window-id addressable across sessions.** The observed live topology
   has sub-orchs in `pc` and workers in `pc_hidden` (PLAN §0). A window option read
   by `window_id` resolves regardless of host session, so `tmux show -wqv -t <wid>
   @fleet_owner` (PLAN §2.1) works across that boundary with no special-casing —
   and both rows already pass the existing `load_rows` session filter (`:362`).
3. **It collapses the shared-worker ambiguity for free.** `workers.tsv` can list
   one worker under multiple dispatches (the dedup convention,
   `FLEET_SUBORCH.md:68`); `@fleet_owner` is a *single* value — the spawner — so a
   live row groups under exactly one card, unambiguously (PLAN §3 edge 5). The
   plan treats this as an edge case; it is actually a *design win* — the chosen
   signal makes an otherwise-hard disambiguation a non-question.

## 3. Why "in the dash, not in `agents_tsv`" is the right seam

PLAN §2.6 keeps the entire change inside `bin/fleet-dash` rather than extending
the `agents_tsv` TSV contract. This is correct and the plan is right not to
agonise over it:

- The dashboard **already** does one tmux query per row for exactly this class of
  data — `harness_of` (`:167-174`) caches `@fleet_harness` per pane; `git_cached`
  / `cost_cached` / `mode_label` all shell out per row. The proposed `owner_of`
  (PLAN §2.1) is a verbatim clone of the `harness_of` cache pattern. One more
  `tmux show -wqv` per row is *idiomatic*, not novel — it costs nothing new
  architecturally.
- It avoids touching the `fleetd` JSON contract and the `fleet ls` static output
  that other callers depend on (CLAUDE.md lists `agents` as an internal consumed
  by the dashboard and watchers). A display-only feature should not perturb a
  cross-process data contract. The plan keeps the blast radius to one file.
- The cost gate is real but bounded: `load_rows` runs at most ~1×/sec
  (`:1443`, the `REFRESH` cap), the owner reads are local tmux option lookups, and
  the plan caches them per load cycle (`OWN_RAW`, reset at the top of `load_rows`).
  Owner is immutable per window, so a load-lifetime cache is provably correct, not
  just a heuristic.

And the plan leaves the door open without walking through it now: §2.6's "future
optimization" note (add `owner` as a 9th ROWS field) documents the escape hatch
*at the exact seam it would use* (`:356`), without paying for it speculatively.
That is good engineering discipline — name the option, don't take it.

## 4. The zero-regression default is the strongest part — and it's nearly free

PLAN §3 edge 1 / §4.5 #6: with no `so-*` rows present (dispatch layer off or
unused), every row classifies as "unowned," the grouping key is uniform, and the
render emits **no card chrome** — the dashboard is byte-for-byte today's flat
urgency list. This matters more than the plan stresses:

- The dispatch layer is **opt-in** (`fleet dispatch enable`, per CLAUDE.md). A
  large fraction of real sessions will have zero sub-orchs. A cards feature that
  imposed *any* visual or behavioural cost on the no-suborch case would be a net
  regression for the common path. This design has a true identity element: no
  sub-orchs ⇒ no change.
- It is **cheap to guarantee and cheap to test.** Because grouping is a stable
  secondary sort, "no `so-*` rows" naturally collapses to the existing order — the
  plan doesn't need a separate code path for the default case, it falls out of the
  general one. §4.5 #6 asserts exactly this (`ROWS[]` order == pure urgency order
  when no `so-*` present), which is a one-line fixture in the DASH_LIB harness.

That "no special-case for the common case" property is an under-sold elegance:
the safe default isn't bolted on, it's a consequence of choosing a *stable*
grouping sort.

## 5. The DASH_LIB seam makes the central risk *directly* falsifiable

The dominant real risk (the plan is honest about this — §2.4, §3) is **width /
alignment**: card indent + rails must be subtracted from `cw` for in-card rows or
the right rail misaligns and lines wrap→scroll (the documented `:692-694`
failure). What makes this risk *acceptable* rather than scary is that the plan
pairs it with a test seam that targets it head-on:

- `DASH_LIB=1 source fleet-dash <sess>` (`:80-89`, `:1431`) loads every function
  but returns before grabbing the tty / alt-screen / event loop (`:1431` `return
  0`). I confirmed the gate: `:1431` is the literal early return.
- This lets PLAN §4.1–4.2 drive `load_rows` + a captured `render` deterministically
  at `COLUMNS ∈ {60,80,120,200}` and assert the **right-rail column is constant on
  every content line** (strip SGR, compare display width) and **no line exceeds
  `COLUMNS-1`**. That assertion *is* the width-budget bug detector — it fails
  loudly the instant the card chrome isn't subtracted from `LW` (`:770`).
- The seam also lets the proof verify the no-regression default and the
  nav-intactness claim from §1 directly: select each index, read `field sel 3`,
  assert it targets the expected window post-regroup (§4.5 #5).

A feature whose scariest failure mode has a deterministic, no-tmux unit assertion
is a *low-risk* feature. The plan didn't just acknowledge the width risk — it
wired the harness that catches it. That is the difference between "we'll be
careful" and "the build breaks if we're wrong."

## 6. Edge-case coverage is genuinely thorough

The §3 edge table is not box-ticking — several entries show the design *holds up*:

- **Orphan-owner card** (edge 4): a worker whose `so-<id>` header is gone still
  carries `@fleet_owner`, so rather than silently dropping it the plan renders a
  `so-d3 (gone)` card — the ownership *fact* survives the sub-orch's death. Good
  call; the alternative (folding into unowned) would lose information.
- **`so-<id>` collision** (edge 9): anchored regex `^so-<id>$` *plus* a
  ledger-dir existence cross-check (`<root>/.fleet/dispatch/<id>`) means a worker
  coincidentally named `so-foo` can't masquerade as a card header. Cheap and
  correct.
- **`sel`-follows-window_id** (edge 8): the plan correctly notes this risk is
  *not new* (urgency re-sort already moves `sel`'s target today) and proposes the
  right mitigation (stash `field sel 3`, re-find after reorder) while marking it
  optional polish. Honest severity calibration.

## 7. The group-first ordering trade-off is made *with eyes open*

PLAN §2.3 chooses group-first / urgency-within over keep-global-urgency-and-merely-
cluster, and **explicitly rejects** the alternative with a reason (clustering
would interleave a card's idle worker below another card, breaking the bounded-card
goal). It then *mitigates the cost of its own choice* — a buried blocked worker in
a low-urgency card — with a card-level max-severity marker on the header (§2.4).
This is exactly how a design decision should be recorded: alternative named, chosen
option justified, downside surfaced, mitigation attached. An advocate's dream
section.

---

## Strengths the plan UNDER-SELLS

1. **The design composes onto an invariant the dashboard already exercises every
   second.** The plan frames "sort + decoration" as a clever low-risk choice. It is
   stronger than that: the urgency sort at `:365-368` *already* reorders `ROWS[]`
   on every refresh and the whole UI survives it. Grouping is not a new category of
   risk — it is a second sort key on an array that is, by existing design,
   sorted-then-indexed-positionally. The plan should lead with "we are not
   introducing reordering, the dashboard already reorders."

2. **The zero-regression default needs no dedicated code path.** The plan presents
   §3 edge 1 as one edge case among nine. It is the *load-bearing* property for
   adoption (dispatch is opt-in; most sessions have no sub-orchs) AND it is free —
   it falls out of using a *stable* grouping sort, not a separate branch. That
   deserves top billing, not edge-case #1.

3. **Every new read clones an existing, proven cache.** `owner_of` mirrors
   `harness_of` line-for-line; the meta read mirrors `meta_get`; the per-load reset
   mirrors the existing TTL caches. The plan calls these "idiomatic" in passing.
   The deeper point: there is **almost no genuinely new machinery** here — it is
   recombination of patterns already in the file, which is why the per-row-tmux and
   fail-silent risks are low. A reviewer can pattern-match every new function to an
   existing one.

---

## Is this the best way? — direct answer

Yes, with one concession that *strengthens* the recommendation rather than
weakening it. The two real alternatives are:

- **(a) Extend `agents_tsv` / fleetd to emit owner** — rejected correctly (§2.6):
  it perturbs a cross-process contract for a display-only feature. More surface,
  more callers at risk, no upside for the dashboard.
- **(b) A real nested-window/sub-pane navigation model** (cards as first-class
  containers with their own selection scope) — this is the "do it properly"
  temptation, and it is a trap: it would require rewriting `sel`, `arows`,
  `nav_*`, and every `field "$sel"` action site, throwing away the §1 guarantee
  entirely, for a TUI dashboard where flat-index nav already works fine and users
  already understand it.

The chosen design is the **minimal change that achieves the visual goal while
preserving a verified behavioural invariant.** In a fail-silent, no-test-runner,
1600-line bash TUI, "minimal change preserving a checkable invariant, with a
deterministic harness aimed at the one real risk" is not a compromise — it is the
definition of the right call. Build it in the §5 order; the only thing I'd
escalate is making the width-invariant assertion (§4.2) a *gating* check from step
3 onward, not a final-step verification, since it is the single failure mode that
can blank the dashboard.

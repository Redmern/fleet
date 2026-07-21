# DEBATE — PRO position: pill-ify the dashboard inbox/TRIAGE rows

**Adviser stance:** Champion the plan. Pill-ify the inbox severity column via the
existing `pill()` / `sev_pcol()` helpers. Grounded in the code below — every claim
cites `bin/fleet-dash` or `bin/fleet` at a line I read in full.

---

## 0. The one-sentence case

The dashboard already speaks one visual language — **fixed-width rounded
capsules** — for *every* status token in the agents view (state, git, mode, and
crucially the `✉N` unread pill at `fleet-dash:979`), and the inbox view is the
*only* surface still rendering status as a tinted bracket token `[warn]`
(`fleet-dash:1131`–`1132`). The plan closes that gap by **reusing the exact
helpers that already ship**, with no new colour vocabulary, no new width
primitive, and a width invariant that copies the agents view line-for-line. That
is the lowest-risk path to the stated goal, and it is the right one.

---

## 1. Is pills the best way to reach the goal? (vs aligned-token, vs a new badge)

**Yes — pills, via `pill()`/`sev_pcol()`. Here is why, against each alternative.**

### Alternative A — keep the tinted `[sev]` token but align the columns

This is the "do less" option: leave `sevf=$(printf '[%s]' "$sev")` and
`sev_color` (`fleet-dash:1131`–`1132`) in place, just fix any column wobble. Reject
it on three grounds:

1. **It does not reach the stated goal.** The goal (PLAN §1) is *the same
   pill-based visual language the agents view + cards use*. A tinted bracket is a
   different primitive from a capsule. After this change, a red `[blocked]` row
   would sit directly under a red `✉2` *capsule* on the same agent's row in the
   adjacent pane — same colour, **different shape**. That is the exact
   inconsistency the plan exists to kill. The `✉N` pill at `fleet-dash:979`
   already *proves the join is wanted* — it is literally
   `pill "✉$iunread" "$(sev_pcol …)"`, the same colour source the inbox rows will
   adopt.

2. **`sev_color` renders `info` as *dim text*, not a colour**
   (`fleet-dash:532`: `*) printf '\033[2m'`). So today the inbox's info rows have
   *no hue at all* — they are just dimmed brackets, visually identical to a
   structural element. The agents `✉` pill, by contrast, gives info a **cyan
   capsule** via `sev_pcol` (`:536`: `*) echo 6`). Keeping the token means the two
   panes disagree about what "info" even looks like. Pills unify it.

3. **The alignment work is the same either way.** Whether the badge is a token or
   a pill, you must capture it into a var and emit with `%s` (never `%-*s`)
   because of embedded SGR — the plan's R2 (PLAN §6). So "just align the token"
   buys you none of the consistency and saves you almost none of the work.

### Alternative B — a different/new badge (e.g. a coloured dot, a glyph)

Reject: it *adds* a primitive instead of reusing one. The dashboard's whole
identity is the capsule (`fleet-dash:243`–`263` comment: "rounded nerd-font
capsules, like the omarchy status bar"). A new badge means a new width to budget,
a new colour map to keep in sync, and a third shape on screen. Strictly worse than
reuse on every axis the plan cares about (consistency, code reuse, low risk).

### Why pills win concretely

- **Code reuse, zero new helpers.** `pill` (`:257`), `pill_center` (`:250`),
  `sev_pcol` (`:536`) all exist and are battle-tested by the agents view every
  refresh. The change at `fleet-dash:1131`–`1132` collapses to a single line
  (PLAN §2a): `sevtxt=$(pill "$sev" "$(sev_pcol "$sev")")`. `SEVW`/`sevf` are
  deleted. This is *less* code than today.

- **Width is a constant, glyph-safe.** Every pill is display-width `PILL_W+4 = 11`
  regardless of text (`:257` comment, `:246`). `pill_center` truncates on
  **chars not bytes** (`:252` comment "char-based (glyph-safe), not %.Ns
  bytes"), and `blocked`(7)/`warn`(4)/`info`(4) all fit in `PILL_W=7`. So the sev
  column's display width stops depending on the word length — it is *more* aligned
  than the old `SEVW=9`-padded token, not less.

- **The alignment invariant is the agents view's, verbatim.** The agents view
  keeps "Content width … exactly = cw" (`fleet-dash:881`, `957`) by treating each
  pill as a fixed `PW` and the label as the flexible filler (`LW`). The inbox row
  already follows the identical clamp-the-title pattern (`fleet-dash:1128`–`1130`,
  drop age then clamp `LW`). The plan's §2d just swaps the fixed cost from
  `base=33/18` to a pill-based `base` — same arithmetic, same place. The
  load-bearing rule (capture pill → emit `%s`) is *already* the pattern the row
  uses for the captured `sevtxt` at `:1152` (`%s` for `$sevtxt`, never `%-*s`), so
  the migration changes the *value* of `sevtxt`, not how it is emitted. Minimal
  surface, minimal risk.

**Verdict (Q-headline):** Pills are the best primitive. A is goal-missing and
saves nothing; B adds a primitive. Pills are pure reuse and the invariant is
copy-paste from a proven path.

---

## 2. Is there an even better way that still honours the goal?

Yes — **two reuse-extensions worth doing, one explicitly to defer.**

### 2a. (DO, low-risk) Unify `sev_pcol` usage — do NOT fork it

The single most important consistency lever is that the inbox `blocked` pill and
the agents `✉` pill are *literally the same red*. That is guaranteed **only if the
inbox row calls `sev_pcol` and `sev_pcol` is not forked** (PLAN R1/R4). I argue
**hard against** the R1 mitigation of branching a dash-inbox-local colour for
info: a second severity→colour map is exactly the kind of drift the codebase
already warns about for `sev_color`/`fmt_age` ("keep the two in sync",
`fleet:1749`, `:1755`; `fleet-dash:532` mirror note). One `sev_pcol`, one truth.
(See Q2 for the info-loudness tradeoff and my answer.)

### 2b. (CONSIDER, medium-value) Share a row-format helper between agents + inbox

The agents view (`fleet-dash:975`–`983`) and the proposed inbox row both do:
`pill → gap → fit_left(label,LW) → … → right-aligned trailer`, then both wrap in
the **identical** selection-bar print (compare `:986`–`990` to `:1154`–`1159` —
they are the same two `printf` templates with `markc`/`ins1`/`ins`/`content`).
There is a real shared seam here: a `row_line <content> <selected>` helper that
owns the `▌`/`ins1` selection chrome would remove a duplicated, alignment-critical
`printf` pair. **PRO position: worth a small extraction, but scope it tightly** —
*only* the outer selection-wrap (the part that is byte-identical), not the
content-assembly (which legitimately differs: agents has cost/mode/git, inbox has
from/age). Extracting the wrap kills the highest-consequence duplication (a typo
in one rail print misaligns a whole view) for ~5 lines. Extracting the
content-assembly would over-couple two views that *should* diverge. So: yes to a
shared selection-wrap helper, no to a shared full-row formatter.

> Honest caveat for the CON side: this extraction is *adjacent* to the plan, not
> required by it. If the debate wants the tightest possible diff (`git diff --stat`
> = only the sev-pill swap, PLAN §8c's strongest zero-regression signal), defer
> 2b to a follow-up. I'd take the unification, but I won't die on it — the sev
> pill is the deliverable; the wrap helper is a nice-to-have.

### 2c. (DEFER) Pill-ify the `from`/age columns too

Tempting for "more pills = more consistency", but **reject**. `from` is a
free-text sender of up to `FROMW=14` chars — capping it to `PILL_W=7` would
truncate worker names destructively, and a 14-wide pill breaks the fixed-`PW`
identity. Age is a 5-char measurement, not a status. Pills are for *status
tokens*; `from`/age/title are *data*. Keeping them as plain (dim where
appropriate) columns is the *correct* application of the language, not a
shortfall. The CLI agrees: it tints only `[sev]` and dims `from`/age
(`fleet:1805`, `:1812`, `:1821`), never boxes them.

---

## 3. ADDITIONS that genuinely help red (daily driver), high-value + low-risk only

Red runs this dashboard daily; the additions below mirror conventions already in
the CLI peek, so they read as "the dash finally matches the CLI" rather than new
surface. I recommend exactly these, with hook points:

### 3a. (RECOMMEND) Dim the age column — mirror the CLI

The CLI dims age (`fleet:1821`: `printf '%s%*s%s' "$dim" … "$age" "$reset"`); the
dash currently leaves it default (`fleet-dash:1150`:
`agetxt=$(printf ' %*s' "$AGEW" "$age")`). Age is metadata, not signal — it should
recede so the title and sev pill are the anchors. **Hook:** wrap `agetxt` at
`fleet-dash:1150` in `\033[2m…\033[0m`. Trivial, byte-safe (age is fixed-width
digits, no glyph risk), and brings the two surfaces into agreement. **High value,
near-zero risk.** Take it.

### 3b. (RECOMMEND) Tint the triage `N marked` counter green when `>0`

The triage header builds `%d marked` plain (`fleet-dash:725` in `triage_header`).
The select marker itself is bright-green `◉` (`fleet-dash:1137`:
`\033[1;32m◉`). Tinting the counter the **same** green when `nm>0` ties the
header number to the marks on screen — red sees at a glance "I have a batch
staged". **Critical hook discipline (PLAN §2e, and I strongly endorse it):**
`triage_header` is deliberately *render-free and unit-testable* (`:715`–`719`
comment). Do **not** put SGR inside it. Apply the tint at the **call site**
(`fleet-dash:1085` `htitle="$(triage_header)"` feeding the `hrule` at `:1093`) — or,
cleaner, have `triage_header` emit a plain marker the caller colourises. Keep the
function pure. **High value (it's the triage view's whole purpose — staging a
batch), low risk if the purity rule is respected.**

### 3c. (RECOMMEND, it's free) sev pill on the orphan/system synthetic rows — already covered

The `⌫ orphans` / `⚙ system` rows are *agents-view* rows
(`fleet-dash:1006`–onwards), and when opened they route through `render_inbox`
with `showfrom=1` (`fleet-dash:1118`: `(( IORPHAN || ISYSTEM || IALL )) &&
showfrom=1`). So the new sev pills apply to those scopes **automatically** — no
extra work (PLAN §5 row "⌫ orphans / ⚙ system buckets"). I flag it only to
confirm: the change is *uniform* across all three scopes, which is itself a PRO
point — one edit, every list view consistent.

### 3d. (RECOMMEND) Drop the constant `*` marker in non-triage views

In per-agent / orphan / system views, archive-as-truth means *every* listed msg
is unread (`load_inbox` comment `:615`–`616`, `fleet-dash:1114`), so the leading
`*` (`fleet-dash:1135` `local mk='*'`) is pure noise — and the agents view has no
such marker. Dropping it (set `mk=""`, reclaim the leading col) gives the title
more width and matches the agents view's clean left edge. **Keep `◉`/`·` for
triage** (`:1136`–`1138`) where it is a real multi-select state. This is squarely
in scope (PLAN §2b, §4.4) and I endorse it. *Note for CON:* this is the one
addition that is a behaviour change visible to muscle memory; but since the `*`
conveys zero information, removing it cannot mislead.

### Additions I explicitly DON'T recommend (keep the diff honest)

- Sev-coloured count in the non-triage `MSGS · scope · N` header (PLAN §2e) —
  "low value" by the plan's own admission; the scope word already orients. Skip.
- Tinting the `changed—r` flag yellow (PLAN §2e) — fine but marginal; it's
  already legible. Optional, not a hill.

---

## 4. PRO position on each of the 6 open questions (PLAN §7)

**Q1 — Gap width: `G=1` (density) vs `G=3` (agents identity)?**
**PRO: `G=2`** (the plan's parenthetical compromise). Rationale: the agents view
has at most 4 short fixed pills + a label (`fleet-dash:884` `G=$PILL_GAP`=3,
sparse rows), so `G=3` breathes. The inbox right pane has **four** columns —
pill·from·title·age — competing in a *narrower* pane, and the title is the payload.
`G=3` would steal 4–6 cols from the title for pure whitespace; `G=1` risks the
pill kissing the `from` column. `G=2` keeps columns distinct without starving the
title. "Visual identity" is carried by the **pill shape and colour** (the thing
the eye reads), not by inter-column whitespace — so diverging the gap costs no
real consistency. Pick `G=2`.

**Q2 — Info colour: cyan `6` (unified) vs grey `8` (calm/CLI-like)? Fork or not?**
**PRO: cyan `6`, do NOT fork `sev_pcol`.** This is the crux and I take the bold
side deliberately. The entire *point* (PLAN §1, §2a) is that the inbox sev badge
and the agents `✉` pill are the **same** — and the agents `✉` pill *already* shows
info as cyan today (`sev_pcol :536` → 6, consumed at `:979`). If we grey-out info
in the inbox, we *break* the consistency we set out to build, and we'd have to
either fork `sev_pcol` (new sync burden, R4) or also recolour every agent's `✉`
pill (a scope creep into the agents view). The "info is louder than the CLI's dim"
worry (R1) is real but minor: the CLI is a scrolling text peek where dim text is
right; the dash is a fixed grid where a *calm cyan capsule* among red/yellow
reads as "lowest of three severities" purely by hue ranking, not by being
shouty. Grey would actually *hurt* — grey `8` is the dashboard's "none/idle/empty"
colour (`state_pcol :265` `*) echo 8`, `git_pcol :268`), so a grey info pill would
read as "no severity / dead", which is wrong. Cyan, unforked.

**Q3 — Drop the `*` marker in non-triage views?**
**PRO: drop it.** As in 3d: archive-as-truth makes it a constant
(`fleet-dash:1114`), it carries zero bits, the agents view has none, and dropping
it reclaims title width. Keep `◉`/`·` for triage only (`:1136`).

**Q4 — Dim the age column to match the CLI?**
**PRO: dim it.** As in 3a: age is metadata; the CLI already dims it
(`fleet:1821`); the dash should agree (`fleet-dash:1150`). Fixed-width digits, so
no glyph/alignment risk. Take it.

**Q5 — Tint the triage `N marked` counter?**
**PRO: yes, green-when-`>0`, at the call site, keeping `triage_header` pure.** As
in 3b: ties the header to the on-screen `◉` marks, directly serving the triage
view's batch-staging purpose. Non-negotiable constraint: the tint goes at the
`hrule` call (`fleet-dash:1085`/`:1093`), never inside the render-free
`triage_header` (`:719`).

**Q6 — Is a pill even the right primitive for a dense *list* (vs a sparse agents
view)?**
**PRO: yes, decisively.** The objection assumes "pill = visually heavy", but the
sev pill is the *only* pill per inbox row — exactly the same count as the agents
view carries for its `✉N` pill. The row is not pill-saturated; it is one capsule +
plain data columns (from/title/age), which is *less* pill-dense than an agents row
(which can show state+git+mode+✉ = four pills, `fleet-dash:956`). And density
actually *strengthens* the case: in a dense list the eye needs a strong,
fixed-position, fixed-width colour anchor to scan severity down a column — a
capsule at a constant `PW` offset is a far better scanning target than a
variable-width tinted bracket (`[blocked]` 9 cols vs `[warn]` 6, jittering the
eye). The fixed `PILL_W` (`:246`) makes the severity column a clean vertical
stripe. Pill is right for the list *because* it is dense, not despite it.

---

## 5. Summary of the PRO recommendation

- **Do the plan.** Swap `[sev]` → `pill "$sev" "$(sev_pcol "$sev")"` at
  `fleet-dash:1131`–`1132`; recompute `base` per §2d copying the agents view's
  fixed-`PW`/flexible-`LW` invariant (`:881`,`:957`).
- **Reuse, don't fork:** one `sev_pcol`, cyan info, same red as the `✉` pill
  (`:536`,`:979`).
- **Take all four low-risk wins:** drop the non-triage `*` (Q3), dim age (Q4),
  tint the marked counter at the call site (Q5), `G=2` gap (Q1).
- **Optional stretch:** extract a shared *selection-wrap* helper for the
  byte-identical rail prints (`:986`–`990` ≡ `:1154`–`1159`) — high-leverage
  dedup, but defer if the debate wants the minimal `git diff --stat`.
- **Keep `triage_header` pure** and **touch no `bin/fleet` CLI code** — the
  strongest zero-regression signals (PLAN §8c).

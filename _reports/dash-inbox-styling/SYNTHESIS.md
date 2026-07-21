# SYNTHESIS — dash inbox/triage styling

**Verdict: BUILD** (pills), with five mandatory revisions folded in from CON and a
frame-gated checkpoint. Not REVISE (the goal — pill-language unification — is
explicit and PRO's defense of it survives CON's strongest attack); not REJECT.

The two advisers **agree** on more than they disagree: dim the age column, tint
the triage marked-counter at the call site, keep `triage_header` pure, touch no
`bin/fleet` CLI code, perf is a non-issue. The genuine fork is narrow: **(a)** is a
pill the right primitive for a *dense* list, and **(b)** info → cyan vs grey. On
both I side with PRO — but CON found **three real alignment defects in the plan's
own math** that must be fixed regardless of that decision, plus two honesty gaps.

---

## The decision on the real fork

**Pills: BUILD (PRO wins, but checkpointed).** CON's "dense list = wall of cyan
noise" is the one substantive objection and it deserves respect — but PRO's two
rebuttals hold:
1. The inbox row carries **exactly one** pill (the sev badge); from/title/age stay
   plain data columns. It is *less* pill-dense than an agents row (up to 4 pills,
   `fleet-dash:956`). So "pill-saturated list" overstates it.
2. A fixed-`PILL_W` capsule at a constant column offset is a **better vertical
   scan target** than a jittering `[blocked]`(9)/`[warn]`(6) bracket. Density
   *strengthens* the case for a fixed-width anchor.

But CON is right that this is ultimately a *visual-taste* call that should be
judged on a real frame, not asserted. So: **build the pills, and as the final
proof step capture a frame with ~20 info-dominated rows** (PROOF §8b, new frame
`07-info-wall.txt`) and eyeball it. If the cyan wall genuinely reads as noise at
review, the documented fallback is CON's local grey map (below) — but we ship
cyan first.

**Info colour: cyan `6`, do NOT fork `sev_pcol` (PRO wins).** Decisive reason CON
underweighted: **grey `8` is already the dashboard's "none / idle / dead / empty"
colour** (`state_pcol fleet-dash:265`, `git_pcol :268`). A grey info pill would
read as *"no severity / dead agent"*, which is semantically wrong. And the whole
goal is that the inbox `blocked` pill is the *same red* as the agents `✉` pill
(`:979`), which already shows info as cyan. Greying info in the list re-breaks the
consistency we set out to build. Keep one `sev_pcol`, info=cyan.
*Fallback only if the §8 info-wall frame fails review:* give the list a local
`info→8` map **without** forking `sev_pcol` (just don't route the list through it,
per CON R-B) — leaving the `✉`/orphan/system anchors cyan. Documented, not built.

---

## Mandatory revisions folded into the plan (from CON)

These are correctness fixes, independent of the pill taste-call. **All required.**

### REV-1 — One constant marker column in ALL scopes (CON R-C, supersedes PLAN §2b/§4.4)
The plan said "drop the `*` marker in non-triage views." CON correctly showed this
creates **three width regimes but only two `base` formulas** (CON §1c) and forces a
**two-format-string split** that silently drifts non-triage rows by one column
(CON §1b — the format at `fleet-dash:1152` hard-codes the leading marker space).

**Resolution:** keep the marker **column** in every scope (single format string,
single `base`), but change the *glyph*:
- triage (`IALL`): `◉` bright-green when marked / `·` dim when not — unchanged
  (`:1135`–`1138`).
- per-agent / orphan / system: a **dim `·`** (not `*`, not empty). Kills the `*`
  noise PRO objected to *without* deleting the column or branching the layout.

Cost: ~2 cols of title vs a full drop. Worth it — a silent 1-col misalignment is a
far worse outcome than 2 cols of title in a list. This collapses CON §1b+§1c to a
single code path with one provable `base = cw` invariant.

### REV-2 — Recompute `base` once, prove it sums to `cw` (CON §1c)
With REV-1's single marker column, one formula covers all scopes:
```
PW=$(( PILL_W + 4 ))           # 11 — sev pill
G=2                            # gap (Q1, below)
MARK=1                         # marker glyph + 1 trailing space = 2 cols
base = MARK + 1 + PW + G + (showfrom ? FROMW + G : 0) + (ageshow ? G + AGEW : 0)
LW   = cw - base
```
Assert in a capture-pane frame that the trailing `│` lands in the same column on
**every** row of the no-from e-view *and* the 70-col frame (CON R-E) — the wide
triage frame hides exactly the regimes that break.

### REV-3 — Add a "drop from" rung to the narrow ladder (CON R-D, §1d)
Current ladder is one rung (drop age, `:1128`–`1130`); the +2-col pill starves the
title to **empty while a 14-col `from` survives**. Add a rung that drops the `from`
column (reclaim `FROMW+G`) **before** clamping the title to 0 — mirroring the
agents view's 4-rung discipline (`:958`–`962`). Order: drop age → drop from →
clamp title.

### REV-4 — Doc the two NEWLY-true divergences (CON R-F, honesty)
Do not bury these under "already true":
- **NO_COLOR CLI↔TUI gap widens.** `fleet inbox list` honors `NO_COLOR`
  (`fleet:1772`); the dash never has and still won't. Pills *maximize* the visible
  gap for a NO_COLOR user. Fixing the dash's NO_COLOR story stays out of scope, but
  record it as a known divergence this change deepens.
- **Sev column ASCII → nerd-glyph.** Today the inbox sev is `[warn]` — plain ASCII,
  legible without a Nerd Font. Pills make the *severity badge itself* two nerd
  half-circles (`PILL_L/PILL_R :244`). The rest of the dash already needs a Nerd
  Font, so a non-nerd user's dash is already broken — but this removes the one
  ASCII-legible inbox column. Record it; do not claim "no new regression."

### REV-5 — Document the `pill_center` ≤7-char constraint (CON R-G, §1a)
`"blocked"` is exactly `PILL_W=7` → it takes the truncation branch (`:252`) with
zero slack. Any future sev token ≥8 chars silently clips. Add a one-line comment
next to `sev_pcol`/the sev-pill call: *"sev strings must stay ≤7 chars or the pill
clips."* Latent trap, not a today-bug.

---

## Settled open questions (PLAN §7)

| Q | Decision | Source |
|---|---|---|
| Q1 gap | **`G=2`** — PRO compromise; density-correct, REV-3 covers narrow risk. `G=1` acceptable if the 70-col frame still starves the title. | PRO, CON conceded |
| Q2 info colour | **cyan `6`, unforked `sev_pcol`** — grey=dead semantics + unify with `✉`. Local grey map only as a frame-gated fallback. | PRO (CON fallback retained) |
| Q3 `*` marker | **Keep the column, glyph→dim `·`** (REV-1) — gets PRO's de-noise without CON's 3-regime drift. | merged |
| Q4 dim age | **Yes** — both agree; mirrors CLI `fleet:1821`, color-only, zero width risk. | PRO + CON |
| Q5 marked counter | **Yes, green-when->0, at the `hrule` call site**, `triage_header` stays pure. | PRO + CON |
| Q6 pill for dense list | **Yes** — one pill/row, fixed-width scan anchor. Frame-gated by the info-wall check. | PRO (CON checkpoint) |

## Deferred (not in this change)
- **Shared selection-wrap helper** (`:986`–990 ≡ `:1154`–1159). Both advisers call
  it deferrable; keeping it out preserves the minimal `git diff --stat` that is
  PLAN §8c's strongest zero-regression signal. Follow-up.
- Sev-coloured count in the non-triage `MSGS · scope · N` header — low value, skip.
- Dash-level NO_COLOR support — out of scope (REV-4 records the gap).

---

## Final touch-point list (the build)

1. `fleet-dash:1117`–`1119` — drop `SEVW`; add `PW`/`G=2`/`MARK`; recompute `base`
   (REV-2), single formula.
2. `:1128`–`1130` — extend the drop ladder: age → from → clamp (REV-3).
3. `:1131`–`1132` — `sevtxt=$(pill "$sev" "$(sev_pcol "$sev")")`; delete `sevf`.
   Add the ≤7-char comment (REV-5).
4. `:1135`–`1138` — marker: `◉`/`·` in triage, **dim `·`** otherwise (REV-1) —
   one format string.
5. `:1150` — dim `agetxt` (Q4).
6. `:1152` — single content format string covering the constant marker column.
7. `:1085`/`:1093` — tint the marked counter green at the `hrule` call (Q5);
   `triage_header` untouched.
8. Comments — REV-4 divergence notes near the sev pill / render_inbox header.

## Proof additions (on top of PLAN §8)
- New frame `07-info-wall.txt`: ~20 info rows, judge the cyan-density question
  (gates Q2/Q6 fallback).
- Frame pass-criteria MUST assert the trailing `│` column on the **no-from e-view**
  and the **70-col** frame (REV-2/REV-3), not just the wide triage frame.
- Keep PLAN §8c CLI byte-identity diff + `git diff --stat` == only `bin/fleet-dash`.

**Net:** BUILD the pills (PRO core), fold REV-1…REV-5 (CON correctness + honesty),
ship cyan info with one frame-gated escape hatch. Diff stays inside `render_inbox`
+ its header call site; no CLI, no `triage_header` body, no helper extraction.

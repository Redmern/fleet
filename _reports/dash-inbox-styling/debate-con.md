# CON brief — restyling the dash inbox/triage view with pills

Adviser: CON (skeptic). Scope: attack `_reports/dash-inbox-styling/PLAN.md`.
All citations are `file:line` against the tree at read time.

> **One-line thesis.** The plan is *mechanically* sound (the alignment trick it
> reuses is the one already proven in the agents view), but it is **strategically
> wrong on two counts the plan itself half-admits**: (a) it pill-ifies a *dense
> list* where the agents view's pill language was designed for *sparse rows*, and
> (b) it deliberately discards the CLI's hard-won "info = dim, one bright anchor"
> discipline by turning every routine summary into a loud cyan capsule. The
> cheaper, lower-risk win — **align the existing tinted-token layout** — gets ~90%
> of the stated goal ("bring the list into the same visual language") for ~10% of
> the risk. I argue for that, and for narrow, reversible concessions if pills win.

---

## 1. ALIGNMENT BREAKAGE — where the right rail can actually wobble

The plan's core safety claim (§2d, R2) is: *capture the pill into a var, emit
with `%s`, never `%-*s`, because the display width is implicit in `pill_center`.*
That claim is **true and the existing code already obeys it** — `sevtxt` at
`:1132` is captured and emitted via `%s` at `:1152`, exactly like the agents
view's `content+=$(pill …)` at `:975`–`979`. So the *headline* failure mode (SGR
bytes entering a width count) does not regress. Good. But several **concrete**
edges remain, and the plan is too confident:

### 1a. `pill_center` truncates "blocked" to 7 — at the exact boundary

`PILL_W=7` (`:246`) and `pill_center` truncates with `${t:0:PILL_W}` when
`len >= PILL_W` (`:252`). `"blocked"` is **exactly 7 chars**, so `len(7) >= 7` is
true → it takes the `${t:0:7}` branch = `"blocked"` (no loss, but also **no
centering**, and zero internal slack). This *happens to* work today, but it means
the sev pill has **no margin**: any future sev string ≥7 chars (e.g. a
hypothetical `"blocked!"`, or a localized/renamed severity) is silently clipped.
The plan says "blocked(7)/warn(4)/info(4) all fit" (§2a) — that is only true for
*these three exact strings*. Not a bug today; a latent trap the synthesis should
**note as a constraint** ("sev tokens must stay ≤7 chars or the pill clips").

### 1b. The `%b` vs `%s` asymmetry the plan glosses over

The current row format (`:1152`) is `'%b %s %s%b%s\033[22m%s'`:
- `%b` for `$mk` — because `mk` may be the literal `$'\033[1;32m◉\033[0m'`
  (`:1137`) carrying **real** escape bytes that must be re-interpreted... no — it's
  already real bytes from `$'…'`, so `%b` is for the `\033` produced by `printf`
  inside `mk='*'`? Actually `mk='*'` is a plain char; the `%b` is load-bearing
  only for the `◉`/`·` ANSI case. **The plan's §4.4 changes `mk` to `""` in
  non-triage scopes.** If `mk=""` is emitted via `%b ` (note the trailing literal
  space in the format), you get a **leading stray space** where the marker used to
  be — the row shifts right by one column vs the agents view, which has **no**
  marker space at all (agents content starts at `pill` directly, `:975`). The plan
  says "no leading space when `!IALL`" (§4.4) but the format string at `:1152`
  hard-codes `'%b %s …'` with that space baked in. **This requires editing the
  format string, not just the variable** — and getting it wrong silently
  mis-aligns every non-triage row by one column. The plan's §4.5 acknowledges
  "adjust the content format string" but does not show the two *different* format
  strings now required (triage with marker+space, non-triage without). That is the
  single most likely place this lands a one-column drift.

### 1c. The §2d base-width arithmetic — recompute it, the plan's numbers don't reconcile

Current code: `SEVW=9`, `FROMW=14`, `AGEW=5`, and `base=33` (showfrom) /
`base=18` (no-from) at `:1119`. Let's verify the *current* `base=33`:
marker(1) + sp(1) + sevtxt(SEVW=9) + sp(1) + from(FROMW=14) + sp(1, the trailing
space baked into `fromtxt` at `:1146`) + title + sp(1) + age(AGEW=5). Fixed =
1+1+9+1+14+1 + (1+5) = **33**. ✓. No-from: 1+1+9+1 + (1+5) = **18**. ✓.

Now the plan's §2d proposes `PW=11, G=1, MARK=1` and:
`base = MARK + 1 + PW + G + (showfrom ? FROMW + G : 0) + G + AGEW`
= 1 + 1 + 11 + 1 + (14 + 1) + 1 + 5 = **35** (showfrom), or
1 + 1 + 11 + 1 + 1 + 5 = **20** (no-from).

But §4.4 *also* says to **drop the marker entirely in non-triage scopes**
(`mk=""`, no leading space). If the marker is dropped, the no-from base should be
`PW + G + G + AGEW = 11+1+1+5 = 18`, **not 20** — the `MARK + 1` term must be
**conditional on `IALL`**, which the §2d formula does not encode. So the plan has
**three** width regimes (triage: marker; orphan/system: showfrom *with* marker?;
agent-scoped: no marker, no from), but only **two** formulas. This is an
off-by-one-or-two waiting to happen. **The arithmetic in §2d is not actually
correct for the §4.4 marker-drop it recommends in the same document.** The
synthesis must pick one: either keep the marker col in all scopes (simpler math,
but contradicts §2b's "drop the noise `*`") or make `MARK` conditional and prove
all three regimes sum to `cw`.

### 1d. The narrow-pane drop ladder is *weaker* than the agents view's

Agents view has a **4-rung** ladder (`:958`–`962`): drop cost → drop mode → drop
✉ → state+label only. The inbox has a **1-rung** ladder (`:1128`–`1130`): drop
age, then clamp `LW` to 0. With pills now costing `PW=11` vs the old `SEVW=9`
(**+2 cols**, per R3), at the §8 narrow frame (70 cols) the title gets squeezed
**2 cols harder** *and* there is no further rung — once age is dropped, `LW`
clamps to 0 and `fit_left "" 0` returns empty (`:107` `(( w <= 0 )) && return`),
so you get **rail · marker · pill · from · (blank title) · rail**. A 14-col
`from` column survives while the title vanishes — that is a worse failure than the
agents view, which would drop pills to keep the label. **The plan does not add a
"drop from" rung.** At narrow widths the pill version is *less* readable than
today, because the +2 cols pushed the title over the cliff sooner. Concrete fix:
add a rung that drops the `from` column (reclaim `FROMW+G`) before clamping title
to 0.

**Verdict on (1):** no catastrophic rail break (the `%s` discipline holds), but
**two real one-/two-column drift risks** (1b marker space, 1c three-regime math)
and a **narrow-pane title-starvation regression** (1d). All three are exactly the
kind of thing the §8 capture-pane frames *should* catch — but only if the frames
assert the rail column **on the non-triage e-view and the 70-col frame**, which
§8b's pass criteria mention only loosely.

---

## 2. COLOR OVERUSE — the plan fights the CLI's own discipline

This is my strongest objection. The CLI was designed with explicit restraint that
the plan throws away:

- **info is deliberately DIM**, not a color: `sev_color` maps `*) printf
  '\033[2m'` (`fleet:1753`, mirrored `fleet-dash:532`). The comment at
  `fleet:1809`–`1810` is explicit: dim the noise so "a real plea stands out."
- **Only the `[sev]` token carries color** (`fleet:1804`–`1808`); from/title/age
  are structural. `inbox_read` has exactly **one bright anchor: the bold title**
  (`fleet:1856`, "the ONE bright anchor").

The plan (§2a) turns **info into a loud cyan capsule** (`sev_pcol *) echo 6`,
`:536`) and **pills EVERY row**. The plan's own R1 calls this out as a risk and
the §2a callout admits "it makes info rows louder than they are in the CLI peek."
**It is louder, and in a dense list that is actively worse**, for a reason the
plan underweights:

> The agents view can afford loud pills because it is **sparse** — one pill per
> agent, ROW_GAP=1 blank line between agents (`:248`, `:995`), often a handful of
> rows. The triage/inbox view is **dense**: it is a *list*, one row per message,
> up to `slots` rows packed with **no** inter-row gap (`:1158` prints rows
> back-to-back). Put a saturated cyan/yellow/red capsule on **every** line of a
> dense list and the eye has **no anchor** — everything shouts, so nothing does.
> This is the precise opposite of the CLI's "dim the routine, one bright anchor"
> design (`fleet:1856`).

The agents view gets away with "pill every row" because each row is a *different
kind* of thing (state/git/mode are heterogeneous). The inbox is **homogeneous**:
every row is "a message," and the only varying axis is severity — which in a
healthy inbox is **mostly info**. So the common case is a wall of identical cyan
capsules. That is noise, not language.

### 2b. The shared `sev_pcol` blast radius

`sev_pcol` is **shared** with the agents view's `✉N` pill (`:979`), the orphan
row (`:1015`/`:1018`), and the system row (`:1037`/`:1040`). The plan's R1
mitigation ("use grey `8` for info instead of cyan `6`") would change **all four
call sites at once** — the `✉` agent pill, orphan, system, *and* the list. The
plan flags this ("changing `sev_pcol` changes both," R1/§7.2) but treats it as a
binary "change both or fork." There is a **third option the plan misses**: the
list does not have to call `sev_pcol` at all. The list-row sev is a *different
semantic* (per-message severity, shown inline) than the `✉N` summary pill
(aggregate max-sev anchor on a sparse row). Coupling them via one function is
**false reuse** — it looks DRY but forces a single color policy onto two
different visual contexts. If pills win, the list should get its **own** color
map so info can be calm (grey/dim) while the `✉` anchor stays loud — *without*
forking `sev_pcol` (just don't route the list through it).

**Verdict on (2):** pill-ifying every row with `sev_pcol`'s cyan-info directly
contradicts the CLI discipline the plan claims (§3) to "mirror." The plan mirrors
the *color source* (severity) while inverting the *color policy* (dim→loud,
one-anchor→every-row). That is not mirroring; it is divergence dressed as unity.

---

## 3. NO_COLOR / non-TTY — "out of scope" is defensible but widens a real gap

The plan's §5 / R-table claim is: the dash is a full-screen alt-screen TUI that is
*already* unconditionally colored and never consults `NO_COLOR`, so pill-ifying
"does not regress that." **Narrowly true** — the dash genuinely has no NO_COLOR
path; `inbox_color_on` (`fleet:1771`) lives entirely in the CLI. I cannot cite a
single dash line that reads `NO_COLOR`. So the plan does not *introduce* a
regression.

But "no regression" is not "fine." Two real concerns:

- **It widens the CLI↔TUI gap for the NO_COLOR user.** A user who sets
  `NO_COLOR=1` (a deliberate accessibility / preference signal, honored *present
  at any value*, `fleet:1772`) gets a **plain, dim-free** inbox from `fleet inbox
  list` but a **pill-saturated** one in the dash for the *same messages*. Today
  that gap is small (the dash tints a `[sev]` token; the CLI dims info — already
  divergent but mild). Pills make the gap **maximal**: the NO_COLOR user's
  explicit "I don't want color" is honored in one surface and loudly ignored in
  the other. The plan is right that fixing the dash's NO_COLOR story is a bigger
  project — but it should at least be **named as a known divergence the change
  deepens**, not waved off as "out of scope."

- **Nerd-font tofu risk is real and the "already true" defense is weak.**
  `PILL_L`/`PILL_R` are raw nerd-font glyphs (`:244`–`245`). The plan (§5,
  R-table "Nerd Font absent") says tofu is "already true for the entire
  dashboard, so no new regression." **Partly false in spirit:** today the inbox
  list shows `[warn]` / `[info]` — **plain ASCII brackets, readable without a
  nerd font**. After the change, the *severity badge itself* becomes two nerd
  glyphs. So a user on a non-nerd-font terminal goes from "fully legible inbox" to
  "every severity is `  warn  ` with tofu half-circles." The dashboard's *chrome*
  (box rules, agents pills) already needs a nerd font, yes — but the **inbox
  severity** specifically did not, and this removes that island of legibility.
  Minor, but the "no new regression" claim is **wrong for this specific column**.

**Verdict on (3):** "out of scope" for the NO_COLOR *daemon-level* fix is fine;
but the brief should record that pills (a) maximize the CLI↔TUI NO_COLOR
divergence and (b) convert the one ASCII-legible inbox column into nerd-glyph
tofu. Don't let these be silently swallowed by "already true."

---

## 4. PERF ON REFRESH — the plan is right; this is a non-issue

I tried to find a cost and there basically isn't one. The plan's R5 is correct:

- Current code **already** does one `$()` subshell capture per row for `sevtxt`
  (`:1132`). The pill version replaces that with one `$()` capture of `pill`
  (`:257`) — `pill` is pure bash string-building (`printf` into a captured
  subshell, plus an inner `pill_center` call which is also pure bash). Net change:
  **same number of subshells** (one per row), with `pill` doing a hair more string
  work than `sev_color`. Same cost *class*.
- Per-row `$(sev_pcol "$sev")` adds **one more** subshell per row vs today (today
  `sev_color` is the only per-row sev subshell). And `pill_center` is invoked
  inside `pill`. So strictly it's ~**2 extra `$()` per row** (sev_pcol +
  pill_center) — but these are trivial `case`/string ops, and the dominant cost in
  `render_inbox` is the **per-row `sed`** inside `ibx_field` called **3×/row**
  (`:1124`, via `:521` `sed -n …`). Three `sed` forks per row already dwarf any
  pure-bash pill cost by orders of magnitude. The pills are **noise in the perf
  budget.**
- Row count is bounded by `slots` (drawn rows), not `IN` — the loop guards
  `drawn<slots` (`:1122`). So even a 200-message inbox only renders ~`slots` rows.

**The one thing I'd flag** is not the pills but that this whole function re-runs
every ~1s and already forks 3 `sed`s/row; if anyone ever worries about dash CPU,
the fix is caching `ibx_field` reads, *not* avoiding pills. Pills are free here.

**Verdict on (4):** perf objection withdrawn. The plan is right.

---

## 5. THE SIMPLER ALTERNATIVE — align the existing tinted-token layout (strongest CON case)

Here is the case for **not pill-ifying at all**, which I believe the synthesis
should seriously weigh as the default:

**The stated goal** (PLAN §1) is "bring the message list into the same *visual
language* the agents view uses." But the agents view's actual language is two
things: (a) **rounded pills** *and* (b) **aligned columns with a focus-bar
selection** (`▌`, `:986`) and dim-chrome rails. The inbox **already has (b)** —
the `▌` bar (`:1155`), the dim rails, the focus-colored `markc` (`:1079`), the
`fit_left` title, the right-aligned age. The *only* divergence is that severity is
a **tinted `[sev]` token** instead of a **pill**.

So a much smaller change reaches most of the goal:

1. **Keep the tinted `[sev]` token** (`:1131`–`1132`) exactly as-is — it already
   mirrors the CLI byte-for-byte (`fleet:1801`–`1808`), preserving info=dim.
2. **Fix only the genuine wart**: the plan's §2e header tinting (tint `N marked`
   green when >0, `changed—r` yellow) and §2c age-dimming — both **low-risk,
   color-only, no width change.** These are pure improvements that don't touch the
   load-bearing alignment math.
3. Optionally **adopt the agents-view selection bar conventions** more fully if
   any drift exists (it doesn't — `▌`/`markc` are already shared).

This gets you: same selection bar, same dim chrome, same dim-system-sender, same
right-aligned age, *and* preserves the CLI's info=dim discipline — **with no width
math change, no `%-*s`/`%s` risk (1b/1c above), no narrow-pane regression (1d), no
nerd-glyph tofu in the sev column (3), no NO_COLOR divergence widening (3), and no
`sev_pcol` blast radius (2b).** Every single risk in §6 of the plan (R1–R4)
**evaporates**, because they all stem from the pill, not from alignment.

**The honest counter** (steelmanning PRO): the *visual identity* with the agents
view is genuinely nicer with capsules — a `[blocked]` token and a red `✉` agent
pill being "the same red shape" is a real, if cosmetic, win (PLAN §1 end). But
that win is **purely aesthetic**, it is the *one* thing the tinted-token approach
doesn't deliver, and it costs **all** the risk above. **90% of the goal (a
consistent, aligned, dim-chrome list) is already shipped; the pill buys the last
10% of visual identity at 100% of the risk budget.** That is a bad trade for a
dense list whose dominant content is routine info.

**My recommendation:** ship the **token-alignment polish** (header tint + age
dim + verify rail alignment) as the primary change. Treat pills as a *separate,
opt-in follow-up* gated on the §8 frames *proving* the dense-list legibility
concern (2) is unfounded — i.e., capture a frame with **20 info rows** and judge
whether the cyan wall reads as noise. If it does, the pill is the wrong primitive
and the token wins.

---

## 6. CON positions on the six §7 open questions

1. **Gap width (G=1 vs G=3).** **CON: G=1**, *if* pills ship. G=3 wastes 2 cols
   ×2 gaps = 4 cols of a narrow right pane on whitespace, worsening the 1d
   title-starvation. "Visual identity" doesn't require identical gaps — the inbox
   is a denser context and density is correct here. But note: choosing G≠agents
   means the views are *not* actually identical, which undercuts the whole
   "unified language" premise — a small tell that the contexts genuinely differ
   (see §5).

2. **Info color (cyan 6 vs grey 8), fork `sev_pcol` or change globally.** **CON:
   grey 8, and do NOT fork `sev_pcol` — give the list its own map** (§2b). Cyan
   info is the core color-overuse mistake (§2). Changing `sev_pcol` globally to
   grey would *also* make the agents `✉N` info pill grey, which may be fine (an
   all-info inbox arguably *should* be a calm grey anchor) — but that's a
   **separate decision about the agents view** that should not be smuggled in via
   an inbox-styling PR. Cleanest: list gets a local `info→8` policy; `sev_pcol`
   stays untouched for the `✉`/orphan/system anchors. Avoids the R4 sync burden
   entirely.

3. **Drop the `*` marker in non-triage views.** **CON: keep a constant col, don't
   delete it — but make it a dim `·`, not `*`.** Deleting the column changes the
   row's start offset and forces the two-format-string split that creates the 1b
   drift risk. A constant dim `·` (or single space) in *all* scopes keeps **one**
   format string and **one** base formula (kills the 1c three-regime problem). The
   plan's "every msg is unread so `*` is noise" is true, but the *fix for noise is
   to dim it, not to delete the column* and pay in alignment complexity. Keeping
   the column also leaves room for a future per-row marker without a re-layout.

4. **Dim the age column.** **CON: yes, dim it** — this is the *one* unambiguous
   pro-CLI-mirror change (matches `fleet:1821`), it's color-only, zero width risk,
   and it correctly de-emphasizes a structural column so the title can be the
   anchor. Adopt regardless of the pill decision.

5. **Tint the triage `N marked` counter.** **CON: yes, but only the counter when
   >0 (green) and `changed—r` (yellow)** — small, reversible, mirrors the marker
   color (`markc` green, `:1079`/`:1137`), and the plan correctly keeps
   `triage_header` *pure* by doing the tint at the `hrule` call site (§2e). Low
   risk, real legibility gain. Adopt.

6. **Is a pill the right primitive for a dense list at all?** **CON: NO** — this
   is the crux (§2, §5). The pill is a *sparse-row* primitive borrowed into a
   *dense-list* context where its loudness becomes noise and its width cost
   (+2/row) starves the title. The aligned-tinted-token approach is the right
   primitive for a dense list and is **already 90% built.** If the team wants the
   visual-identity win anyway, gate it on a real 20-info-row frame (§5).

---

## 7. Concrete revisions the synthesis should fold in

Ordered by leverage:

- **R-A (biggest).** Default to the **token-alignment polish** path (§5): keep
  `[sev]` tinted (preserves info=dim), and ship only the **header counter/flag
  tint** (§2e) and **age dim** (§2c, Q4). This alone delivers "consistent,
  aligned, dim-chrome list" with *zero* width-math/pill risk. Make pills a
  separate, frame-gated follow-up.
- **R-B (if pills ship anyway).** Do **not** route list-row severity through
  `sev_pcol`; give the list a local color map with **info→grey/dim**, leaving
  `sev_pcol` (and thus the `✉`/orphan/system anchors) untouched. Kills R1+R4 and
  the §2b blast radius in one move.
- **R-C.** **Keep a constant marker column in all scopes** (dim `·`), do not
  delete it in non-triage views. This collapses the three width regimes to one,
  eliminating the 1b two-format-string drift and the 1c base-formula
  contradiction. Re-derive `base` once and assert it sums to `cw` in a frame.
- **R-D.** **Add a "drop from" rung** to the narrow-pane ladder (`:1128`–`1130`)
  *before* clamping the title to 0, so the title never vanishes while a 14-col
  `from` survives (1d). Mirror the agents view's multi-rung discipline
  (`:958`–`962`).
- **R-E.** Make the §8 pass criteria **assert the rail column on the e-view
  (no-from, no-marker) frame and the 70-col frame specifically** (1c/1d are
  invisible on the wide triage frame). Add a **20-info-row frame** to adjudicate
  the dense-list-noise question (§2/Q6) empirically before committing to pills.
- **R-F (doc honesty).** In §5/risks, **record** the two NO_COLOR/nerd-font
  divergences the change *deepens* (CLI↔TUI NO_COLOR gap; the sev column going
  from ASCII `[warn]` to nerd-glyph tofu) rather than dismissing them as "already
  true" — they are *newly* true for the severity column (§3).
- **R-G.** Document the **`pill_center` ≤7-char constraint** on sev tokens (1a)
  next to `sev_pcol`, so a future severity rename doesn't silently clip.

---

## 8. Where I concede the plan is right

- The `%s`-not-`%-*s` pill-capture discipline is correct and already in the tree
  (`:1132`/`:1152`, `:975`) — no catastrophic rail break from SGR bytes.
- Perf (§4) is a non-issue; R5 is accurate.
- The empty-state, sort logic, `MARKED`, and `load_inbox` are correctly left
  untouched; the CLI byte-identity zero-regression check (§8c) is the right
  safety net.
- Age-dim, header-counter-tint, and keeping `triage_header` pure (§2e) are
  genuinely good, low-risk changes — adopt them *whether or not* pills ship.

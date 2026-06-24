# PROOF — dash inbox/triage styling (GATE 1 = BUILD)

Implements SYNTHESIS `BUILD + REV-1..REV-5`, settled Q4/Q5, against the binding
spec in this directory's `PLAN.md` / `SYNTHESIS.md`. There is **no test runner**
(`CLAUDE.md`: "No build, no test suite"), so proof is by `tmux capture-pane -e`
frames of `render_inbox` driven against synthetic `.msg` fixtures, plus
rail-alignment asserts and a CLI byte-identity check.

## Scope delivered (diff confined to `render_inbox` + its header call site)

```
 bin/fleet-dash | 94 +++++++++++++++++++++++++++++++++++++++-------------------
 1 file changed, 64 insertions(+), 30 deletions(-)
```

- Only `bin/fleet-dash` changed. `git diff HEAD -- bin/fleet` = **0 lines**
  (the CLI `inbox_list`/`inbox_read` is byte-untouched). `triage_header` body
  untouched; no helper extraction (deferred per SYNTHESIS).

### What changed, mapped to the spec
- **Sev badge → fixed-width `pill()`** coloured by the **shared** `sev_pcol`
  (info=cyan 6 / warn=yellow 3 / blocked=red 1). `sev_pcol` is **not** forked, so
  the inbox `blocked` pill is the same red as the agents `✉` pill (`fleet-dash:979`).
- **REV-1** — one marker COLUMN in every scope, single format string + single base.
  Glyph = `◉` bright-green (marked) / `·` dim (unmarked) in triage; dim `·` in
  per-agent / orphan / system. Never `*`, never empty.
- **REV-2** — `base` recomputed once: `PW=PILL_W+4=11`, `G=2`, `MARK=1`. Invariant
  `base + LW == cw` proved by the rail asserts below.
- **REV-3** — drop ladder extended to 3 rungs: drop age → drop from → clamp title
  (mirrors the agents view discipline).
- **REV-4** — comments record the two newly-true divergences (NO_COLOR CLI↔TUI gap;
  sev ASCII `[warn]` → nerd-glyph pill) in `render_inbox`.
- **REV-5** — comment by the sev pill: sev strings must stay ≤7 chars (`pill_center`
  clips).
- **Q4** — age column dimmed. **Q5** — triage `N marked` counter tinted green
  (>0) at the `hrule` call site only; `triage_header` stays pure (the recolour is
  applied to hrule's *output* string so its byte-width math is untouched).

## How the frames were produced

`render_inbox` is driven directly via the script's `DASH_LIB=1 source` seam (loads
all functions, no event loop / no alt-screen), with the scope globals
(`IALL/IORPHAN/ISYSTEM/IFILTER/IROWS/IN/MARKED/isel`) set per frame, inside a
fixed-size detached tmux pane, then `capture-pane -p -e`. Harness + driver +
fixtures + raw/stripped frames live under `$FLEET_DOCS/proof/`. Excerpts below are
ANSI-stripped for readability; colour is verified separately by the canaries.

Fixtures: 5 messages covering all severities + a system sender (`main`) + a long
ellipsising title; plus a 20-row all-`info` set for the density check.

## Frame 01 — all-severities triage (120 cols)

```
╭─ MSGS · triage · oldest↑ · 5 msgs · 0 marked ───────────────────────────────────────────────────────────────────────╮
│                                                                                                                     │
│▌ ·  blocked   so-d11          agent blocked on human: need creds for deploy                                 952d  │
│  ·   warn     so-d11          tests failing on CI after rebase                                              952d  │
│  ·   info     worker-x        summary: refactor landed, 3 files touched                                     952d  │
│  ·   info     main            gate: phase 2 approved, proceeding                                            952d  │
│  ·   warn     worker-y        ….................. that must ellipsise cleanly at the title width boundary   952d  │
│                                                                                                                     │
```
red `blocked` / yellow `warn` / cyan `info` pills; `main` (system) sender dimmed;
age column dim and right-aligned; selected row (row 0) bold + `▌` bar; long title
ellipsised with a leading `…`.

**Colour canaries (raw frame 01):** blocked pill bg `ESC[48;5;1m` ×1, warn
`ESC[48;5;3m` ×2, info `ESC[48;5;6m` ×2 — matches the 1/2/2 fixture mix. Dim-age
token `ESC[2m 952d ESC[0m` ×5.

## Frame 02 — a marked row (triage)

```
╭─ MSGS · triage · oldest↑ · 5 msgs · 1 marked ───────────────────────────────────────────────────────────────────────╮
│▌ ◉   info     worker-x        summary: refactor landed, 3 files touched                                     952d  │
```
Header counter `1 marked` is tinted green at the call site; the marked row shows
`◉` bright-green (raw: green ◉ present in 02, **absent** in unmarked 01).

## Frame 04 — per-agent (no-from) e-view

```
│▌ ·  blocked   agent blocked on human: need creds for deploy                                                 952d  │
│  ·   warn     tests failing on CI after rebase                                                              952d  │
│  ·   info     summary: refactor landed, 3 files touched                                                     952d  │
│  ·   info     gate: phase 2 approved, proceeding                                                            952d  │
│  ·   warn     …title ............................ that must ellipsise cleanly at the title width boundary   952d  │
```
`showfrom=0`: the `from` column is gone and the title takes the reclaimed width;
marker is the constant dim `·`; pills + dim age unchanged.

## Frame 05 — empty state

```
│                                                                                                                     │
│                                                     inbox empty                                                     │
│                                                                                                                     │
```
Centred "inbox empty", no stray pills or rail breakage.

## Frames 04b/04c — orphan / system e-views (showfrom=1)
Captured (`04b-orphan.txt`, `04c-system.txt`): both show the `from` column with
sev pills; system-view senders are **not** dimmed (the dim is gated to triage only,
preserving the original `(( IALL )) && msg_from_is_system` intent).

## Frames 06/06b/06c — drop ladder (REV-3)

70 cols (06): wide enough that nothing drops (title clamps to 25). To exercise the
ladder, two tighter widths:

```
W=45 — age dropped, from kept:
│▌ ·  blocked   so-d11          …deploy  │
│  ·   warn     so-d11          …rebase  │

W=37 — from AND age dropped, title gets the width:
│▌ ·  blocked   …eds for deploy  │
│  ·   warn     …I after rebase  │
```
Confirms the rung order age → from → clamp.

## Frame 07 — info-wall density check (~20 info rows, gates Q2/Q6)

```
│▌ ·   info     worker-1        summary 1: routine status update from worker 1                                952d  │
│  ·   info     worker-2        summary 2: routine status update from worker 2                                952d  │
│  ·   info     worker-3        summary 3: routine status update from worker 3                                952d  │
│  ·   info     worker-4        summary 4: routine status update from worker 4                                952d  │
│  ·   info     worker-5        summary 5: routine status update from worker 5                                952d  │
│  ·   info     worker-6        summary 6: routine status update from worker 6                                952d  │
│  ·   info     worker-7        summary 7: routine status update from worker 7                                952d  │
```
20 cyan `info` pills (raw: `ESC[48;5;6m` ×20) sit at a constant left offset and read
as a clean vertical scan anchor, not a wall of noise — the cyan is the 8-col capsule
only, titles stay the brightest unselected element. **Verdict: cyan info ships** (no
fallback to the grey local map).

## Rail-alignment asserts (REV-2 / REV-3)

A Python asserter strips SGR and checks the rightmost box char (`│ ╮ ╯`) lands in a
single column across all 40 boxed lines of each frame — including the **no-from
e-view** and the **70-col** frames (not just the wide triage frame):

```
PASS 01-triage-all-sev.txt        rail col(s)=[118] over 40 boxed lines
PASS 02-triage-marked.txt         rail col(s)=[118] over 40 boxed lines
PASS 03-triage-newest.txt         rail col(s)=[118] over 40 boxed lines
PASS 04b-orphan.txt               rail col(s)=[118] over 40 boxed lines
PASS 04c-system.txt               rail col(s)=[118] over 40 boxed lines
PASS 04-eview-nofrom.txt          rail col(s)=[118] over 40 boxed lines
PASS 05-empty.txt                 rail col(s)=[118] over 40 boxed lines
PASS 06b-drop-age-45.txt          rail col(s)=[43] over 40 boxed lines
PASS 06c-drop-from-37.txt         rail col(s)=[35] over 40 boxed lines
PASS 06-narrow70.txt              rail col(s)=[68] over 40 boxed lines
PASS 07-info-wall.txt             rail col(s)=[118] over 40 boxed lines
PASS 08-eview-nofrom-70.txt       rail col(s)=[68] over 40 boxed lines
```
Every frame: exactly one rail column. 120-col frames → col 118; 70-col → col 68;
W=45 → 43; W=37 → 35. The `base + LW == cw` invariant holds in every scope and at
every drop-ladder rung.

## CLI byte-identity (`bin/fleet` untouched)

```
git diff HEAD -- bin/fleet        → 0 lines
git status --porcelain            →  M bin/fleet-dash      (only)
```
And running the CLI from the working tree vs `HEAD:bin/fleet` on the same fixture:

```
working-tree md5: 423584411f751bccab804d7e6d2d5c19
HEAD        md5: 423584411f751bccab804d7e6d2d5c19   → PASS, byte-identical
```

## Green criteria — all met
- Sev pills render in red/yellow/cyan via the shared `sev_pcol`; info=cyan ships.
- One marker column, glyph `◉`/`·` (triage) and dim `·` (other scopes); never `*`/empty.
- Single `base`; rail aligns in one column in **all** scopes, incl. no-from e-view + 70-col.
- 3-rung drop ladder (age → from → clamp) demonstrated at W=45 and W=37.
- Age dimmed (Q4); triage marked-counter green at the call site, `triage_header` pure (Q5).
- REV-4/REV-5 comments present in source.
- `git diff --stat` = only `bin/fleet-dash`; CLI `inbox list` byte-identical.

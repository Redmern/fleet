# dash-cards-polish — rendering proof

Three visual refinements to the orchestrator cards in `bin/fleet-dash`, all in the
row-render loop + the `unowned_rule` neighbourhood. Captured by driving `render()`
under the `DASH_LIB` sourcing seam with synthetic agent rows in a throwaway 100×24
tmux pane (`tmux capture-pane -p`). Driver: `scratchpad/drive.sh` (stubs the IO-bound
helpers `config_live_cached`/`git_cached`/`cost_cached`/`harness_*`/`mode_label`).

## Changes

1. **Spacing between same-card workers.** A `│ blank │` spacer is now printed
   between two consecutive workers of the SAME card (`crole==1` and previous row a
   worker of the same `cgid`), gated on `drawn < slots`. The `├─/└─` last-vs-not
   glyph keys off the NEXT row's `cgid`, so it stays correct after spacers.
2. **Card header keeps a state pill.** The `so-<id>` header row now renders ITS OWN
   live state pill (`field $i 1` → `state_pcol`), with the same stall override
   (`working` + age > `STALL_SEC` → red `stalled`) and ready/done override
   (`field $i 8` non-empty + non-live state → magenta `done`) the worker path uses.
   The `· state` text is dropped from the label (the pill carries it). The `hrule`
   label width shrinks by `PW` (sel: `inner-1-PW`, non-sel: `inner-PW`) so content
   stays exactly `inner` wide and the right `│` does not move.
3. **Unowned group closing rule.** A plain `─` divider (no label, full `inner`
   width, via `hrule '' '' inner`) is printed after the last unowned row. Unowned
   rows always sort last, so it is emitted once after the row loop, gated on
   `unowned_ruled && drawn < slots` (only when a top rule was drawn and a slot
   remains — budget-respecting).

## Alignment guarantee

Every box line measured at **exactly 99 display columns** (`cols=100` →
`inner = cols-3 = 97`, line = `│` + 97 + `│` = 99), via a wcwidth-aware check
across header, worker, spacer, unowned, and closing-rule rows — including the
selected-header marker+pill variant. No `│` drift.

## (a) Card with 3 workers — spacing + header pill

Header line shows the `working` pill (so-d8's own live state) then `so-d8 · 3 workers · ⚠1`.
Blank spacer lines now sit BETWEEN wk-a / wk-b / wk-c (none between header and first
worker — the header is itself a divider).

```
╭─ FLEET · proof · 4 agents ──────────────────────────────────────────────────────────────────────╮
│                                                                                                 │
│ working ─ so-d8 · 3 workers · ⚠1 ─────────────────────────────────────────────────────────────│
│   working      ├─ wk-a  fleet/feat-a                    -        default    $0.10 3k      │
│                                                                                                 │
│    idle        ├─ wk-b  fleet/feat-b                    -        default    $0.10 3k      │
│                                                                                                 │
│   blocked      └─ wk-c  fleet/feat-c                    -        default    $0.10 3k      │
│                                                                                                 │
...
╰─ Spc leader · j/k · Ent jump · e msgs · h hide · v diff · m mode · s send · n new · d close · r/╯
```

Selected header (sel=0) — marker bar `▌` + pill, still 99 wide:

```
│▌ working ─ so-d8 · 3 workers · ⚠1 ────────────────────────────────────────────────────────────│
│   working      ├─ wk-a  fleet/feat-a                    -        default    $0.10 3k      │
```

## (b) One card + 2 unowned — TOP and BOTTOM unowned rule

`╶ unowned ╴` top rule introduces the pile; a plain `─` closing rule follows the
last unowned row (loner-y). loner-y carries a `.fleet/ready` flag (`field 8`) and a
non-live `idle` state, so its pill is the magenta `done` override (same logic now
applied to header pills).

```
╭─ FLEET · proof · 4 agents ──────────────────────────────────────────────────────────────────────╮
│                                                                                                 │
│ working ─ so-d8 · 1 worker ───────────────────────────────────────────────────────────────────│
│    idle        └─ wk-a  fleet/feat-a                    -        default    $0.10 3k      │
│                                                                                                 │
│╶ unowned ╴──────────────────────────────────────────────────────────────────────────────────────│
│    idle      loner-x  fleet/loner-x                     -        default    $0.10 3k      │
│                                                                                                 │
│    done      loner-y  fleet/loner-y                     -        default    $0.10 3k      │
│─────────────────────────────────────────────────────────────────────────────────────────────────│
│                                                                                                 │
...
╰─ Spc leader · j/k · Ent jump · e msgs · h hide · v diff · m mode · s send · n new · d close · r/╯
```

## (c) Zero-card flat fallback — zero regression

`HAS_CARDS=0`: identity path, no header pill, no card chrome, no unowned rules;
flat-mode `ROW_GAP` spacers between agents unchanged. 99 wide throughout.

```
╭─ FLEET · proof · 2 agents ──────────────────────────────────────────────────────────────────────╮
│                                                                                                 │
│   working    wk-a  fleet/feat-a                         -        default    $0.10 3k      │
│                                                                                                 │
│    idle      wk-b  fleet/feat-b                         -        default    $0.10 3k      │
│                                                                                                 │
...
╰─ Spc leader · j/k · Ent jump · e msgs · h hide · v diff · m mode · s send · n new · d close · r/╯
```

`bash -n bin/fleet-dash` passes. Live dash picks up the change via `fleet main --reload`
(not triggered here to avoid disrupting the human).

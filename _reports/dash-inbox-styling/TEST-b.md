# TEST-b — independent verification of dash inbox/triage styling (`render_inbox`)

Tester B, own context, re-derived from source — did **not** trust `PROOF.md`.
fleet has no test runner; verified by **rendering** `render_inbox` via the
`DASH_LIB=1 source` seam inside isolated, fixed-size tmux panes (`-L` private
sockets, never the live pc/techweb2 server) and capturing frames with
`capture-pane -e/-p`. Synthetic `.msg` fixtures only.

Spec note: `PLAN.md` / `SYNTHESIS.md` are **absent** under
`_reports/dash-inbox-styling/` (only `PROOF.md` exists). Re-derived intent from
the code + REV-/Q- comments in `render_inbox` (`bin/fleet-dash:1070-1208`).

Harness: `driver.sh` (sources dash, sets scope globals + IROWS, calls
`render_inbox`), `cap.sh` (renders W×26 pane), `rail.py` (East-Asian-width-aware
rightmost-box-char column per line). All glyphs (`╭─│╮╯ · ◉ ▌ … →`  pill
semicircles `/`) measured width-1 (EAW ambiguous) — correct for a
Nerd-Font terminal.

---

## 1. ALIGNMENT — **PASS** (all scopes, all widths)

`rail.py` over every captured frame: the trailing rail (`│ ╮ ╯`) lands in
**exactly one column** = `W-2` on every boxed row (data rows share the column
with the header/footer/blank borders → `base + LW == cw` holds in every scope and
at every drop-ladder rung).

| frame | scope | boxed lines | rail col(s) |
|---|---|---|---|
| triage.120 | (a) wide triage all-sev | 14 | **[118]** |
| marked.120 | (b) marked row | 26 | **[118]** |
| empty.120 | (c) empty state | 26 | **[118]** |
| agent.120 | (d) per-agent (showfrom=0, 1 row) | 26 | **[118]** |
| orphan.120 | (d) orphan ⌫ view | 26 | **[118]** |
| system.120 | (d) system ⚙ view | 26 | **[118]** |
| eview-nofrom.120 | (e) no-from e-view (showfrom=0, 5 rows) | 26 | **[118]** |
| triage.70 | (f) narrow 70 | 26 | **[68]** |
| triage.45 | (f) drop-ladder rung 1 | 26 | **[43]** |
| triage.37 | (f) drop-ladder rung 2 | 26 | **[35]** |
| triage.30 | (f) narrower still | 26 | **[28]** |
| infowall.120 | (g) ~20-row info-wall | 26 | **[118]** |

Every frame: single rail column, no split. `W-2` checks out (120→118, 70→68,
45→43, 37→35, 30→28).

**Drop ladder (REV-3) confirmed** by inspecting narrow frames:
- W=70: full layout, age (`2d…`) + from + clamped title all present.
- W=45: **age dropped**, from kept (`worker-y`, `so-d11`), title clamped (`…undary`).
- W=37: **from + age dropped**, title gets the width (`…width boundary`).

Order = age → from → clamp, exactly as specified.

### Alignment caveat (latent, non-blocking) — the age column is the one unclamped field
The age cell renders via `printf '%s\033[2m%*s\033[0m' "$gs" "$AGEW" "$age"`
(`fleet-dash:1184`) — `%*s` **pads but does not clip**, unlike `from`
(`%-*.*s`, clips) and title (`fit_left`, clips). With AGEW=5, any age string ≥6
chars overflows by one column and **breaks the rail**. I hit this with an
unrealistic epoch (1970 → `20628d`, 6 chars): the info-wall rail split
`[118,119]` until I used realistic ages. In practice unreachable — `fmt_age` tops
out at `9999d` (27 years, 5 chars) for any plausible message — but it is a genuine
asymmetry (the only column without a precision/clip). Worth a one-char fix
(`%-*.*s` with `.AGEW`) for robustness; not a ship blocker.

## 2. SEV PILLS + MARKER — **PASS**

Raw-ANSI pill backgrounds via shared `sev_pcol` (`fleet-dash:536`, **not** forked):
- triage.120: `48;5;1`×1 (blocked=red), `48;5;3`×2 (warn=yellow), `48;5;6`×2
  (info=cyan) — matches the 1/2/2 fixture mix.
- infowall.120: `48;5;6`×20 (cyan info).
- `sev_pcol` is the **same** function the agents `✉` pill calls
  (`fleet-dash:979`), so a blocked inbox pill and the red `✉` pill are the same
  red 1. Confirmed by code identity + render.

Marker column (REV-1):
- marked.120: exactly **1** `◉` (raw SGR `^[[1m^[[32m◉` = bold green) on the
  marked worker-x row; all other rows dim `·` (`^[[2m·`). `N marked` counter shows
  `1 marked`, tinted green at the hrule call site (`fleet-dash:1100-1104`).
- triage (unmarked), agent, orphan, system, eview: marker is constant dim `·`.
- agent.120: `◉`=0 (no green marker outside marked-triage). ✓
- **No `*` glyph in any frame** (`grep '[*]'` → 0 files); never empty.
- Selected-row `▌` bar renders green (`^[[32m▌`) when the pane is active
  (markc `pa=="11"` branch exercised).

## 3. CLI BYTE-IDENTITY — **PASS** (verified the correct way)

The implementer's `PROOF.md` used `git diff HEAD -- bin/fleet` (working-tree vs
HEAD) — the **wrong** comparison (would miss a change in an earlier branch
commit). Re-did it correctly:

```
merge-base(HEAD,main) = df911e5
git diff df911e5..HEAD -- bin/fleet      → 0 lines
md5 base:bin/fleet  = c0a7a718686eb61e8cbea7de1dc8eef6
md5 HEAD:bin/fleet  = c0a7a718686eb61e8cbea7de1dc8eef6   → byte-identical
```

`bin/fleet` is byte-identical between merge-base and HEAD → the CLI
`inbox_list`/`inbox_read` is untouched, output unchanged for any input by
construction. Functional confirmation: ran `bin/fleet inbox list` from the branch
vs the extracted base binary on the same input → **IDENTICAL** output (read-only
`list` peek; non-destructive, no archive). The implementer's method was wrong but
the result genuinely holds.

## 4. CYAN INFO-WALL DENSITY — opinion: **fine, ships**

20 cyan `info` pills (infowall.120). The cyan is only the 8-col capsule at a
constant left offset; titles stay the brightest unselected element. The identical
low-arousal cyan capsules read as a **left gutter / vertical scan-anchor**, not a
wall of noise — cyan is calm next to the red/yellow it's reserving contrast for.
Mild redundancy at 20 identical pills, but not alarming or distracting. Agree with
the frame-gated decision to **ship cyan info** (no fallback to a grey local map).

## 5. ZERO-REGRESSION — **PASS**

```
git diff --name-only df911e5..HEAD
  _reports/dash-inbox-styling/PROOF.md
  bin/fleet-dash
```

Only `bin/fleet-dash` (+ the report) touched. Working tree clean
(`git status --porcelain` empty).

---

## Verdict: **DONE**

All five axes verified independently from re-derived intent: rail in exactly one
column across every scope/width (base+LW==cw), 3-rung drop ladder (age→from→clamp),
sev pills red/yellow/cyan via the shared `sev_pcol`, single `◉`/`·` marker column
(never `*`/empty), CLI `bin/fleet` byte-identical to merge-base (md5-confirmed),
diff confined to `bin/fleet-dash`. Cyan info-wall reads acceptably.

**Single most important gap (latent, non-blocking):** the age column uses
`%*s` (pad-no-clip) where every other column clips — an age string ≥6 chars
(≥10000 days) would break the rail. Unreachable with realistic ages, but it is the
one alignment field lacking a clip; a one-char `.AGEW` precision would close it.

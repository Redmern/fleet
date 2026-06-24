# TEST-a — independent verification: dash-inbox-styling (render_inbox)

Tester: independent agent A. Verdict reached from scratch; PROOF.md not trusted.

## Method

`fleet` has no test runner, so I verified by **rendering and measuring frames**.
Harness sources `bin/fleet-dash` through its built-in `DASH_LIB=1` test seam
(loads every function, skips the TUI loop / tty), stubs `tput`/`tmux`/`date`/
`inbox_root`, drives the `I*`/`MARKED`/`isel`/`PAD_*` globals from env, points
`IROWS` at synthetic `.msg` fixtures, and calls `render_inbox` directly.
Alignment measured by stripping ANSI and computing each row's **display width**
with a `wcwidth` (East-Asian ambiguous = 1, matching a Western terminal — which
is the code's own assumption for the box/pill/marker glyphs).

Throwaway only: synthetic fixtures + `FLEET_ROOT=$(mktemp -d)` /
`FLEET_SESSION=prooftest_$$`. Live pc/techweb2 sessions untouched.

Harness + fixtures: `/tmp/.../scratchpad/{harness.sh,measure.py,fix_*}`.

---

## 1. ALIGNMENT — **PASS** (the main risk)

Invariant `base + LW == cw` re-derived by hand and confirmed empirically: every
row (header rule, blank/PAD rows, data rows, footer rule) renders to exactly
`cols-1` display columns, so the trailing rail (`│`/`╮`/`╯`) lands in **one
column** on every row. `DISTINCT WIDTHS: [N]` (single value) on every scenario:

| Scenario | Frame | Result |
|---|---|---|
| (a) wide triage, all severities | cols=120 | widths `[119]` ALIGNED |
| (b) marked rows (◉) | cols=120, 2 marked | widths `[119]` ALIGNED; header w/ green "2 marked" still `[119]` |
| (c) empty state (`inbox empty`) | cols=120 | `[119]` ALIGNED |
| (d) per-agent / orphan(⌫) / system(⚙) | cols=120 | each `[119]` ALIGNED |
| (e) no-from e-view (per-agent, `from` dropped) | cols=100 | ALIGNED, no `from` column |
| (f) narrow 70 + drop-ladder 44/37/30/24/22 | each | `[69]`/`[43]`/`[36]`/`[29]`/`[23]`/`[21]` all ALIGNED |
| (g) 20-row info-wall | cols=110, lines=24 | `[109]` ALIGNED |

**Drop-ladder (f)** verified to fire in the documented order and never starve the
title while `from` survives:
- cols=44 → **age dropped**, `from` kept, title left-ellipsised.
- cols=37 → **from dropped**, title kept.
- cols=30 / 24 → title clamped (`…origin)` / `…)`), still aligned.

Math `PW=PILL_W+4=11`, `FIXED=MARK+1+PW+G=15`, `LW=cw-FIXED-fromc-(G+AGEW)` checks
out in all four branches (full / age-dropped / from-dropped / no-from).

**Edge (not a blocker):** at **cols ≤ 18** the sev pill alone (11 cols) exceeds
`cw`, so data rows overflow → misaligned. This is pathological (a ~18-col pane),
and the **merge-base version is strictly worse** — it already misaligns at
**cols=22** (widths `[21,33]`) because the old code force-showed a 33-col `from`
base in triage and only ever dropped age. So the new drop-ladder is an
improvement, not a regression. Also `fmt_age` can exceed `AGEW=5` for ages
>9999d, overflowing the age column by 1 — but that is pre-existing (old code used
the same un-truncated `%*s AGEW`) and not realistically reachable. Neither blocks.

---

## 2. SEV PILLS + MARKER — **PASS**

Pill bg-colour histogram on the mixed fixture (1 blocked / 2 warn / 2 info):
`1× 48;5;1` (blocked=**red**), `2× 48;5;3` (warn=**yellow**), `2× 48;5;6`
(info=**cyan**) — exactly `sev_pcol` (`fleet-dash:536` `blocked)1 warn)3 *)6`).
Confirmed the **agents ✉ pill** uses the *same* `sev_pcol` (`fleet-dash:979`:
`pill "✉$iunread" "$(sev_pcol …)"`), so a blocked inbox row and a red ✉ agent
pill are byte-for-byte the same red (`48;5;1`/`38;5;1`).

Marker column:
- triage marked → `\033[1;32m◉` (bold green ◉ = U+25C9), unmarked → `\033[2m·` (dim).
- per-agent / orphan / system → constant `\033[2m·` (dim).
- **Zero** literal `*` in any inbox output (old behaviour), never empty. Confirmed
  by grep (`0 stars`).

---

## 3. CLI BYTE-IDENTITY — **PASS** (done correctly)

Using the **merge-base** (not working-tree-vs-HEAD):
```
mb=$(git -C <wt> merge-base HEAD main)        # df911e5
git -C <wt> diff $mb..HEAD -- bin/fleet   →   0 lines
```
`bin/fleet` sha256 branch == base (`089b86e7…`). Ran the CLI inbox pager on an
isolated `FLEET_ROOT` fixture (info/warn/blocked) and diffed branch-`fleet`
output vs base-`fleet` output on the same root → **IDENTICAL**. CLI inbox stays
the plain `* [sev] from title age` ASCII format (no ANSI in a pipe) — the styling
feature is confined to the dashboard `render_inbox`, exactly as intended.

---

## 4. CYAN INFO-WALL density — judgment: **fine, not noise**

Frame (g), 20 info rows, `cols=110`: 20 cyan (`48;5;6`) pills stacked, and **only**
the pill is saturated per row — marker is dim `·`, `from` default, title dim
(`\033[2m`), age dim. Cyan is a cool/low-urgency colour, so a uniform column of it
reads as a calm "all routine / nothing needs you" band rather than an alarm wall;
the eye isn't pulled to any single row (correct — none is urgent). It is slightly
heavy but acceptable and *informative* (the left colour-edge instantly says "no
warn/blocked here"). I would ship it as-is. (Note: I found **no** frame-gated
escape hatch in this diff — pills always render; that's fine given the above.)

---

## 5. ZERO-REGRESSION — **PASS**

```
git diff --name-only $mb..HEAD
  → _reports/dash-inbox-styling/PROOF.md
    bin/fleet-dash
```
Only `bin/fleet-dash` (+ the report) touched. `bash -n` clean on both
`bin/fleet-dash` and `bin/fleet`.

---

## OVERALL: **DONE**

All five items verified independently with concrete frame/column evidence.
Alignment holds across every scope and the full narrow-width drop-ladder; pills
and marker match the spec and share `sev_pcol` with the agents ✉ pill; the CLI is
genuinely byte-identical at the merge-base; the change is scoped to `fleet-dash`.

**Single most important residual gap (non-blocking):** sev pills are now 11 cols
wide (vs the old 9-col `[sev]`), so the alignment floor rose — rows overflow at
**cols ≤ 18**. It's pathological and the old code was already worse (broke at
cols=22), so it does not block; flag only if sub-20-col panes are a real target.

# Test debate verdict — inbox-styling

## VERDICT: **NEEDS-WORK** (one tight iteration, then DONE)

Both testers returned WORKS; safety/machine story is genuinely solid (dash 0
lines, machine consumers byte-identical, `.msg` plain, gate parse / reap-guard /
pop intact, NO_COLOR-wins, 16/16 proof). The body-ANSI-bleed is correctly judged
**pre-existing / out of scope** (comment-only diff line). I adopt all of that.

But the NEEDS-WORK seat surfaced two real gaps the DONE seat never rebutted, both
on the feature's *headline visual payload*:

### BLOCKER 1 — title width pinned to 80 on every real terminal (common path)
`inbox_list` uses `COLS="${COLUMNS:-80}"`. `COLUMNS` is a bash shell var that is
**not exported to child processes**; `bin/fleet` runs as its own bash via shebang,
so `COLUMNS` is unset in the real invocation → `COLS=80` **always**, on a 120/160/
200-col terminal alike. Title is clamped to `LW = 80-5-9-14-5 = 47` chars
regardless of terminal width. The SYNTHESIS UX rationale ("shrink `from` to give
**slack to the title**", "mirror the dash") is defeated — the dash reads real
width via `tput cols`/`stty size` (`fleet-dash:689,874,994`); this feature copied
the dash's palette/`fmt_age` but **not** its width source. Both testers masked it
by setting `COLUMNS` explicitly; proof.sh sets/asserts nothing about width.
**Fix:** `COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"` (fail-silent),
mirroring the dash. Keep the existing invalid/`<8` guards.

### BLOCKER 2 — proof.sh certifies gating, not the visual feature
Zero assertions on the visual MUSTs: age column / buckets, bold title (`\033[1m`),
warn=yellow (`\033[33m`) & info=dim, dim-system-sender (and the system-sender
branch is **never seeded** — `seed()` puts only worker senders). A `warn→red` or
dropped-bold regression stays 16/16 green. For a TDD feature whose payload is
*visual*, the proof must guard the visuals.
**Fix:** add assertions (RED-first on current 86fc0eb): age token renders from a
backdated epoch; `\033[33m` on warn, `\033[2m` on info; `\033[1m` on a read title;
seed a `from=main` system sender → dimmed while a worker sender is not; and a
width assertion for BLOCKER 1 (in a wide pty, a >47-char title is NOT truncated).

## Fold in (cheap, same iteration — not separate blockers)
- **NO_COLOR='' (empty-but-set)** ignored — `[ -n "${NO_COLOR:-}" ]` should be
  `[ -n "${NO_COLOR+x}" ]` to honor no-color.org "present regardless of value".
- **Post-body `\033[0m`** when color is on — completes must-fix #3's stated
  invariant (they reset *before* the body but not *after*; the last msg's body
  bleeds into the shell prompt). One color-gated line. Contains misbehaving
  bodies without re-coloring them (body still printed verbatim).

## Not a blocker (document as known limitation; best-effort only)
- **Unicode title misalignment** — `%-*.*s` counts bytes, so multibyte titles
  shift the downstream age column. Full fix needs display-width counting (heavy
  for bash); the dash doesn't solve it perfectly either. Implementer: degrade
  gracefully for typical glyphs; if not cheaply fixable, note it as a known
  limitation. Do NOT block DONE on perfect unicode.
- sev>9 clip, `FLEET_INBOX_COLOR` case-sensitivity, empty-inbox dim
  inconsistency, huge-COLUMNS no upper clamp — cosmetic/edge, leave as-is.

## Loop plan (TDD, build on what's there — do NOT rewrite)
1. Extend proof.sh with the BLOCKER-2 visual assertions + the BLOCKER-1 width
   assertion; confirm they FAIL on 86fc0eb (RED) for the right reason.
2. Fix `inbox_list` width source + `inbox_color_on` NO_COLOR + post-body reset.
3. proof.sh → all green (old 16 + new). Re-verify; then DONE → GATE 2.

# Inbox styling — synthesis & verdict

## VERDICT: **BUILD**

All three advisers (pro / con / value) agree the *architecture* is sound: reuse
`fleet-dash`'s raw-SGR palette, TTY-gate it, never touch the on-disk `.msg` or
machine consumers, and use the consume-path `FLEET_INBOX_COLOR` override. Con
confirmed the two headline worries are NON-issues:
- **Dynamic scope survives the `|`** — `local FLEET_INBOX_COLOR=…; {inbox_list;}|$pager`
  works; the left of a pipe is a fork that inherits the function's locals. No
  `export`/`sh -c` needed (in fact `sh -c` would break it).
- **Machine-consumer safety is real** — nobody parses `inbox list`/`read` output;
  dash renders from `.msg` directly. Coloring the display printf is safe.

The work is **entirely in `bin/fleet`** — `bin/fleet-dash` is already styled.

> Side-note validated in practice: an adviser's proof run leaked a `from alpha`
> message into the **live** inbox — exactly con DEFECT 2 (cwd `cd` does NOT
> isolate the root). The proof-isolation fix below is load-bearing, not academic.

---

## Plan, REVISED — must-fixes folded in

Build PLAN.md as written, PLUS these mandatory corrections (con) and the top UX
adds (value):

### Correctness must-fixes (con — skip any and it ships SILENTLY broken)
1. **Materialize escapes as real bytes.** Every color constant emitted via `%s`
   (`reset`, `dim`, `bold`, `nbold`, any `sgr` helper) must be `$'\033[…m'` or
   `$(printf '\033[…m')` — NEVER literal `'\033[…m'` (prints the 7 chars
   `\033[2m`). `sev_color` captured via `col=$(sev_color …)` is the only one
   already safe.
2. **`set -u` safety.** `bin/fleet` runs `set -u`. Initialize EVERY color/reset
   var to `""` unconditionally at the top of `inbox_list`/`inbox_read`, before the
   `C` (color-on) test; overwrite only when `C=1`. A styling helper must never
   crash the command (fail-silent).
3. **No dangling SGR.** Every styled `printf` resets its SGR before the next
   token and — critically — before `inbox_body` runs. Body printed VERBATIM
   (worker text may contain its own escapes). State this as an invariant.
4. **Consume override is mandatory, plain-`local` form.** `cmd_inbox` sets
   `local FLEET_INBOX_COLOR=always|never` matched to the existing `less -R`/`cat`
   choice (`always` only when `[ -t 1 ] && less`). Do NOT use the `sh -c '…'`
   variant from PLAN line 177 — strike it.
5. **Proof root isolation.** Proof script must `export FLEET_ROOT="$ROOT"
   FLEET_SESSION=prooftest` before any `fleet` call (both EXPORTED so the
   `script`-spawned pty inherits them). Delete the "cd is enough / resolves from
   cwd" claim — `fleet_root` resolves tmux session → `@fleet_root`/`$FLEET_ROOT`,
   and `|| return 1` before `pwd`, so `cd` alone either fails to seed or mutates
   the REAL inbox.
6. **Fix two dud proof assertions.** `fleet doctor` (d) never calls the inbox
   display fns → not a color canary; keep it but lean on a/a2/b/b2/b3. The (e)
   field check is unrunnable as written (no `fleet inbox field` subcommand) — use
   `source bin/fleet; inbox_field …` or `grep '^sev=warn$'` on the `.msg`.

### UX adds (value)
- **MUST: relative age column** in `inbox_list` — biggest scannability win and
  nearly free (epoch is in the msg-id filename, `epoch="${id%%.*}"`). Mirror the
  dash's `fmt_age` (third "keep in sync" helper) → right-aligned, dim `5s/3m/2h/4d`.
- **MUST: one bright anchor per `inbox_read` header.** `title` bold; `[sev]` sev-
  colored; `──` rule, `(disp)`, `ts` all dim; `from` default weight. Bold exactly
  one token, never two.
- **MUST: column alignment** via pad-inside-color-span (`%-*.*s` inside the span)
  — both a correctness and a "looks intentional" item.
- **NICE (include if cheap):** shrink `inbox_list` `from` from `%-24s` toward the
  dash's ~14 (give slack to title); dim the `inbox empty` empty-state; one dim
  orientation header `inbox · N unread`; tint `[sev]` in the put-feedback echo.

### Open-question rulings (consensus)
- **Q1** dim `from` **only for system senders** (mirror `inbox_from_is_system`),
  worker senders default weight. Not blanket-dim.
- **Q2** keep `*` plain — SKIP (constant, double-encodes sev).
- **Q3** tint only the `[sev]` token in put feedback — NICE/low-priority.
- **Q4** honor **NO_COLOR**, and NO_COLOR **wins** over `FLEET_INBOX_COLOR=always`. MUST.
- **Q5** keep `FLEET_INBOX_COLOR` (`auto|always|never`), mention in one help line.
- **Q6** fixed basic SGR (31/33/2/1) — no truecolor/theme. SKIP.

### Explicit SKIPs (hold the line)
Sev-tint `*`; glyph-swap `*`→`✉` per row; truecolor/theming; severity re-sort
(keep newest-first); body previews / re-coloring bodies.

---

## Proof (how we prove it works — for GATE 1 approval)
Isolated tmp-root scenario (per PLAN §8, with must-fix #5/#6 applied): seed
info/warn/blocked msgs into a throwaway `FLEET_ROOT`, then assert —
(a) TTY shows ANSI incl. blocked=red; (b) piped/redirected shows NO raw ANSI;
(c) consume-pager path stays clean piped + still archives all live msgs;
(e) `.msg` files stay plain on disk (machine consumers safe); + `fleet doctor`
green as a syntax canary. TDD: tests written + shown RED first, then implement.

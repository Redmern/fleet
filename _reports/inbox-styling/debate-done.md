# Test debate — verdict: **DONE**

Branch `fleet/inbox-styling` @ `86fc0eb`. I argue the feature fully meets spec
with no regression. The diff is 105 lines, entirely in `bin/fleet`. Two
independent testers (A: correctness/rendering/edge; B: regression/machine-safety)
both returned **WORKS**, and `proof.sh` is 16/16 green with a machine-gated RED
set (`A1 A2 AL1 DIST` fail on the unstyled tree, all pass once styled). The case
for DONE rests on three pillars: (1) every SYNTHESIS MUST is implemented and
witnessed by code + test; (2) the only "real-looking" bleed is pre-existing and
out of scope; (3) machine-safety and no-regression are positively proven, not
merely asserted.

---

## 1. Every SYNTHESIS MUST → code + test evidence

### Correctness must-fixes (con — "skip any and it ships SILENTLY broken")

| # | MUST | Code evidence (diff) | Test evidence |
|---|------|----------------------|---------------|
| 1 | Escapes as **real bytes**, never literal `\033[…m` | `sev_color` captured via `$(sev_color …)`; resets are `$'\033[0m'`/`$'\033[2m'`/`$'\033[1m'`; the put-line reset is `$(printf '\033[0m')` | TEST-a inspected raw bytes via `script(1)`+`cat -v`: `blocked→\033[31m`, `warn→\033[33m`, `info→\033[2m`. No literal `\033` chars in display. proof `A1` (ANSI present), `A2` (red byte present) |
| 2 | `set -u` safety — every style var init `""` **before** the color test | `inbox_list`: `local C=0 reset="" dim="" sevtxt="" fromtxt="" titletxt="" agetxt="" sevf=""`; `inbox_read`: `local C=0 reset="" dim="" bold="" sevc="" disptag=""` — overwritten only when `C=1` | TEST-a "set -u clean": unset `COLUMNS/NO_COLOR/FLEET_INBOX_COLOR/TMUX_PANE/LINES` → list+read render with no unbound-variable error |
| 3 | No dangling SGR; **body printed verbatim** | Every styled span closes with `reset`/`\033[0m` on the same line; `inbox_body "$f"; printf '\n'` left intact | TEST-a + TEST-b both verified every span closes (`^[[2m[info]^[[0m`, `^[[33m[warn]^[[0m`, age `^[[2m  0s^[[0m`). "No dangling SGR" from the feature's own output |
| 4 | Consume override = plain `local`, **not** `sh -c` | `cmd_inbox`: `local FLEET_INBOX_COLOR=never` then `… { pager="less -R"; FLEET_INBOX_COLOR=always; }`. The struck `sh -c '…'` form is absent | TEST-b §4: consume archives 3→0 and stays plain piped; TEST-a confirmed `less -R` gets ANSI on a tty, `cat`/redirect get none |
| 5 | Proof root isolation — `export FLEET_ROOT` **and** `FLEET_SESSION` before any call | `proof.sh:38-39` exports both; `D5` asserts `inbox_dir` resolves under `$ROOT` *before seeding* | Both testers independently re-verified isolation (`isoA`/`isoB`): live `pc` inbox stayed at 0 msgs, never touched |
| 6 | Fix the two dud proof assertions | `doctor` demoted to a **syntax-only** canary (`SYN` = `bash -n`; doctor exit logged "informational only"); field check greps the header (`E2`: `grep -qx 'sev=warn'`) — no nonexistent `inbox field` verb | proof 16/16 green; `D5`/`E2` pass |

### UX adds marked MUST

- **Relative age column** — `fmt_age` mirrors `fleet-dash:fmt_age`; epoch parsed
  from the msg-id filename (`epoch="${id%%.*}"`), guarded `case … *[!0-9]*|'')
  epoch=$now`. TEST-a backdated epochs → `38s / 5m / 2h / 2d`, right-aligned in
  `AGEW=5`. Correct buckets. ✓
- **One bright anchor in `inbox_read`** — `title` bold; `[sev]` sev-colored; `──`
  rule, `(disp)`, `ts` dim; `from` default weight. Exactly one bold token.
  Witnessed in the diff's two header printfs and TEST-a. ✓
- **Column alignment via pad-inside-color-span** — `%-*.*s` / `%*s` sit *inside*
  the color span so ANSI bytes never enter the width count. Both testers
  confirmed alignment holds across long titles/senders and at `COLUMNS=40`. ✓

### Open-question rulings

- **Q1** dim `from` only for system senders — `[ "$C" = 1 ] && inbox_from_is_system
  "$from"`; worker senders keep default weight. TEST-a verified `{"", -, main}`→dim,
  workers default. ✓
- **Q4** NO_COLOR honored and **wins** over `FLEET_INBOX_COLOR=always` —
  `inbox_color_on` returns 1 on `NO_COLOR` *first*, before the override case.
  proof `NC1`/`NC2`/`DIST`; both testers' knob matrices confirm precedence. ✓
- **Q5** `FLEET_INBOX_COLOR=auto|always|never` kept. ✓ **Q2/Q3/Q6** skips honored
  (`*` plain; sev-tint only on the put echo; fixed basic SGR). ✓

**All explicit SKIPs held** — no sev-tint `*`, no glyph swap, no truecolor, no
re-sort, no body re-coloring. Scope discipline intact.

---

## 2. The body-ANSI bleed is PRE-EXISTING and out of scope — rebuttal to any NEEDS-WORK on it

TEST-a note #2 / TEST-b note #2 describe a `.msg` body holding a raw unterminated
`\033[…m` bleeding color into the next header / the shell prompt. **This is not a
regression and must not block.**

- **The body-print line is byte-identical to pre-feature code.** In the diff the
  only change to that line is an appended *comment*:
  ```
  -    inbox_body "$f"; printf '\n'
  +    inbox_body "$f"; printf '\n'   # body VERBATIM — never re-colored …
  ```
  The executable bytes are unchanged. The body was *always* printed verbatim with
  no trailing reset on `main`. TEST-b confirmed `inbox_body` is byte-identical to
  main (`git log -L` empty in range).
- **It requires a worker to store raw ESC bytes in a body** — not reachable via
  normal `put -t/-m` (plain text). It's a property of how bodies were always
  rendered, not of this styling change.
- **Scope:** this PR colors the *display chrome* (sev/from/title/age/headers) and
  is explicitly forbidden by SYNTHESIS from touching bodies ("body previews /
  re-coloring bodies" is an explicit SKIP). Demanding body sanitization here is
  scope creep that the spec rules out.
- A NEEDS-WORK that names this as a blocker is **over-reaching**: the feature's
  contract is "no *new* ANSI to non-tty sinks, no dangling SGR *in the feature's
  own spans*," and both hold. Pre-existing behavior unchanged ≠ regression.

**Concession (cheap NICE follow-up, not a blocker):** emitting one `\033[0m`
after `inbox_body` when color is on would *contain* a misbehaving body's escapes —
a one-line hardening. Worth a follow-up ticket; it neither blocks DONE nor is in
this PR's spec.

---

## 3. The minor notes are edge/cosmetic, not blockers

| Note | Why it does not block |
|------|------------------------|
| sev string >9 clipped (`[critical`) | Unreachable in practice: `inbox_put` forces `sev∈{info,warn,blocked}`, max `[blocked]`=9. Only a hand-corrupted `.msg` hits it. Cosmetic. |
| `NO_COLOR=""` (empty-but-set) → color ON | `[ -n "${NO_COLOR:-}" ]`. A *minor, common-in-the-wild* deviation from strict no-color.org; SYNTHESIS Q4 says "honor NO_COLOR" — empty-string-means-on is the prevalent reading and does not break the MUST (set `NO_COLOR=1` → off, proven). Cosmetic spec nuance. |
| `FLEET_INBOX_COLOR` case-sensitive | `Always`/`ALWAYS` fall to auto. Spec writes the values lowercase; documented surface is `auto|always|never`. Edge. |
| Empty-inbox dim inconsistency | The dir-missing / `inbox read` empty paths return before color setup → plain "inbox empty"; the normal list path dims it. Purely cosmetic on a zero-content edge. |
| Huge `COLUMNS` not clamped | `COLUMNS=999999999999` pads ~1e12 spaces. Not reachable in a real terminal; the *lower* bound (LW floor 8, invalid→80, `COLS=0`) **is** guarded and proven by TEST-a. |

None of these touch machine output, the on-disk format, or any orchestration
path. All are display-only, on inputs that normal usage cannot produce.

---

## 4. Machine-safety & no-regression — positively proven

- **`bin/fleet-dash`: 0 lines changed** (TEST-b diff). The dash renders from
  `.msg` directly and never parsed `inbox list` — untouched, still correct.
- **Machine consumers byte-identical to main** (TEST-b, via `git log -L` empty +
  diff): `inbox_field`, `inbox_body`, `inbox_pop_text`, `inbox_count`,
  `inbox_clear`, `inbox_has_needs_human_from`, `gate_parse`. None changed. The
  `.msg` **write path** in `inbox_put` is unchanged — only the tty-gated stdout
  "queued" line was wrapped.
- **`.msg` stays plain on disk** — `grep $'\033'` across every `*.msg` = 0 hits
  (TEST-b §2; proof `E1`). Display ANSI never reaches disk (TEST-a "disk purity").
- **Pipes/redirects carry 0 ANSI** — TEST-b §1 table (9 cases all PLAIN); proof
  `B1/B2/B3` green. `inbox count` stays a bare integer `^[0-9]+$`.
- **Gate parse intact** — TEST-b §3: sentinel detected via stdin (rc0) and via a
  body-fed file (rc0); realistic `inbox_body(gate) | fleet gate parse` chain rc0.
  Parsing a raw `.msg` directly returns rc1 **same as main** (line-1 is `id=`) —
  pre-existing, and the real pipeline feeds the body, which works.
- **Reap-guard intact** — `inbox_has_needs_human_from` rc0 for a `sev=blocked`
  sender (still blocks reap). **`inbox_pop_text` → no color** (TEST-b §3).
- **doctor green, `bash -n` clean** (TEST-b §6; proof `SYN`).

The RED→GREEN proof is the strongest single artifact: the four color assertions
(`A1 A2 AL1 DIST`) fail on the unstyled tree and *only* those four (machine-gated
via `PROOF_EXPECT_RED`), then all 16 pass once styled. That is exactly the
behavioral delta the spec asked for — added color on a tty, nothing else.

---

## Verdict

**DONE.** Every SYNTHESIS MUST is implemented with code + double-tester + proof
evidence. The one credible-sounding defect (body ANSI bleed) is byte-for-byte
pre-existing and explicitly out of this PR's scope; the remaining notes are
cosmetic/edge on inputs normal usage cannot produce. Machine-safety and
no-regression are positively demonstrated, not assumed. No code edits made.

**Strongest point:** the body-bleed "blocker" is a comment-only diff line —
executable bytes identical to main — so it is definitionally not a regression of
a styling change that the spec forbids from touching bodies. One optional
`\033[0m`-after-body NICE follow-up is the only thing worth a ticket.

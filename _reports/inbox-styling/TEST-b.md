# TEST-b — Independent Tester B (Phase 4) — inbox-styling

Angle: **regression + machine-safety**. Adversarial, isolated. No production code edited.
Binary under test: `bin/fleet` @ branch `fleet/inbox-styling`.

## Isolation
Every call: `export FLEET_ROOT=$(mktemp -d) FLEET_SESSION=isoB`.
- `FLEET_SESSION=isoB` → `session_name` returns `isoB` → no live tmux session named isoB → `tmux show -t isoB @fleet_root` empty → `fleet_root` falls back to `$FLEET_ROOT` (tmp). Verified `inbox_dir` resolves under tmp BEFORE any write.
- First put landed in `/tmp/…/.fleet/inbox/`; live project inbox `/home/red/proj/pc-tune/.fleet/inbox/` = 0 msgs, never touched.

## VERDICT: **WORKS** — safety claim holds. Color only on a tty; machine paths & on-disk format unaffected. Two informational (non-blocking) notes below.

---

## Regression oracle — `git diff main..HEAD`
- Files touched: **`bin/fleet` only** (+ `_reports/` docs). 105 lines.
- **`bin/fleet-dash`: 0 lines changed** ✓ (dash never parsed `fleet inbox list`; renders `.msg` directly — untouched, still correct).
- Machine consumers **byte-identical to main** (verified via `git log -L` empty in range + diff):
  `inbox_field`, `inbox_body`, `inbox_pop_text`, `inbox_count`, `inbox_clear`, `inbox_has_needs_human_from`, `gate_parse`. None changed.
- Only changed/added: `inbox_list` (rewrite), `inbox_read` (header lines), `cmd_inbox` consume block, new `sev_color`/`fmt_age`/`inbox_color_on`, and the **stdout "queued" line** in `inbox_put` (tty-gated). The `.msg` **write path in `inbox_put` is unchanged**.

## 1. No raw ANSI to pipes / redirects / cat  — **WORKS**
| case | result |
|---|---|
| `inbox list` (cmd-subst pipe) | PLAIN |
| `inbox read all` (pipe) | PLAIN |
| `inbox list \| cat` | PLAIN |
| `inbox list > file` | PLAIN |
| `inbox read all > file` | PLAIN |
| `inbox \| cat` (consume) | PLAIN (clean msgs) |
| `inbox > file` (consume) | PLAIN |
| `inbox put …` (queued line) piped | PLAIN; on tty = colored |
| `inbox count` | bare integer `^[0-9]+$` ✓ |

## 2. `.msg` on disk byte-plain + headers intact — **WORKS**
- `grep $'\033'` across every `*.msg` = **0 hits** (no escape bytes written).
- Gate msg headers all present & plain: `id= from= owner= dispatch= ts= sev= title=` then `--` separator then verbatim body. `sev=/from=/title=/dispatch=/ts=` confirmed.

## 3. Machine consumers unaffected — **WORKS**
Sourced via `FLEET_SOURCE_ONLY=1 source bin/fleet`, called directly:
- `inbox_field f sev` → `blocked` (clean, no ANSI); `title` clean.
- `inbox_body gatemsg` → `[FLEET-GATE:2 …]\nptr` clean.
- **`inbox_pop_text`** (text pasted into orchestrator) → `From <from>: <title>\n<body>` — **NO color** ✓.
- **`gate parse`**: detects sentinel via stdin (`gate=2 slug=zap action=test`, rc0) and via a file whose line-1 is the sentinel (rc0). Realistic chain `inbox_body(stored gate) | fleet gate parse` → rc0 ✓. (Parsing a raw `.msg` file directly returns rc1 because file line-1 is `id=` — **same as main**, pre-existing; pipeline feeds it the body, which works.)
- **Reap-guard** `inbox_has_needs_human_from <from>` → rc0 (blocks reap) for a sev=blocked sender ✓.
- `inbox count` → bare int after weird inputs too ✓.

## 4. Consume archives all live msgs — **WORKS**
`fleet inbox` (bare consume): live before=3 → after=0, archive=3. Re-run when empty → `inbox empty`. Output plain when piped (`FLEET_INBOX_COLOR=never` set in cmd_inbox for the cat path; `always` only when final sink is tty+`less -R`).

## 5. TTY gating + knobs — **WORKS** (tested with a real pty via `pty.fork`)
| env | sink | color? |
|---|---|---|
| (default) | tty | YES ✓ |
| (default) | pipe | no ✓ |
| `NO_COLOR=1` | tty | no ✓ |
| `FLEET_INBOX_COLOR=never` | tty | no ✓ |
| `FLEET_INBOX_COLOR=always` | pipe | YES ✓ |
| `NO_COLOR=1 FLEET_INBOX_COLOR=always` | pipe | no ✓ (NO_COLOR wins, correct precedence) |

## 6. doctor / syntax — **WORKS**
- `fleet doctor` → **rc 0**, all rows `ok` (incl. config-sync section).
- `bash -n bin/fleet` → clean.

## 7. Adversarial — **WORKS** (no styling leak; spans balanced)
- Styling's own SGR spans all close with `\033[0m` — verified on tty at `COLUMNS=40`: `^[[2m[info]^[[0m`, `^[[33m[warn]^[[0m`, age `^[[2m  0s^[[0m`. **No dangling SGR.** Padding is inside the color span (dash width trick), so alignment holds and ANSI bytes don't enter width math.
- Crafted title with embedded `\033[31m`: in a **pipe**, output shows the escape verbatim (`X^[[31mY`) — but this is the **user's own stored input echoed back**, and is **byte-identical to main's** `inbox list` (diff matches ignoring the new age column). NOT introduced by styling. inbox_field/body return exactly what was stored, as before.
- Odd sev / tab+newline in title: handled by `inbox_put` input layer (unchanged from main); count stays a bare int.

---

## Informational notes (non-blocking, NOT regressions)
1. **`from` column display-truncated to 14 chars** (`FROMW=14`): list shows `inbox-styling-`, but `inbox_field … from` returns full `inbox-styling-testB`. Cosmetic only; machine value intact.
2. **User-injected ANSI in a title/body reaches a pipe verbatim** (e.g. a malicious worker putting `\033[…` in its title). This is **pre-existing** — identical on main — because list/read print the title/body verbatim and `inbox_field/body` store/return raw bytes. The styling branch adds no new ANSI to non-tty sinks. Out of scope for this change; flag only if input sanitization is ever desired.

## Files
- Test harness: `$FLEET_DOCS/run-tests.sh` (scratch).
- Note: `mktemp -d` iso dirs left under `/tmp` (broad `rm -rf /tmp/tmp.*` correctly blocked as out-of-scope; harmless).

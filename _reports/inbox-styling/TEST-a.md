# TEST-a — inbox-styling (Independent Tester A, Phase 4)

**Under test:** `bin/fleet` @ branch `fleet/inbox-styling` (commit `86fc0eb`)
**Feature:** TTY color styling for `fleet inbox list` / `inbox read` — sev colors,
relative-age column, bold-title detail view, TTY-gated, `NO_COLOR` +
`FLEET_INBOX_COLOR=auto|always|never` knob.

**Angle:** correctness + RENDERING + edge cases. Adversarial. Total isolation.

## VERDICT: **WORKS**

Core feature is solid and correct across every rendering and gating path I
probed. Found **no functional break introduced by this feature**. Seven minor
notes below — all cosmetic, pre-existing, or edge-only; none break the feature.
The one real-looking bleed (unterminated ANSI in a body) is **pre-existing** —
the body-print line is byte-identical to the pre-feature code.

## Isolation (verified before any seeding)

Every fleet call ran with `FLEET_ROOT=$(mktemp -d …)` + `FLEET_SESSION=isoA`
both exported. Confirmed `session_name`→`isoA` (no such tmux session) →
`tmux show -t isoA @fleet_root` empty → falls through to `FLEET_ROOT`.
Verified `inbox_dir` resolves under the tmp root *before* seeding:
`/tmp/.../scratchpad/iso.XXXX/.fleet/inbox`. Live `pc` session + real project
inbox never touched. (Note: `inbox_put` reads the *live* tmux window name via
`$TMUX_PANE` for the `from=` default, but **writes only to the isolated inbox** —
inbox isolation intact.)

## Sanity: proof.sh → 16 passed, 0 failed (in isolation).

## What I verified WORKS (concrete)

Driven through a real pty with `script(1)` and inspected raw bytes (`cat -v`).

- **sev colors:** `blocked`→`\033[31m` (red), `warn`→`\033[33m` (yellow),
  `info`→`\033[2m` (dim). Unknown sev (`critical`) and empty sev → dim (the
  `*)` default). ✓
- **age column (fmt_age):** seeded backdated epochs in the msg-id filename
  (now−30 / −300 / −7200 / −200000) → rendered `38s / 5m / 2h / 2d`
  (right-aligned in AGEW=5). Computes from `id` epoch, correct buckets. ✓
- **system-from dimming:** `from` ∈ {``""``, `-`, `main`} → dim (mirrors
  `inbox_from_is_system`); worker senders keep default weight. ✓
- **alignment:** columns stay aligned (sev 9 / from 14 / title LW / age 5) for
  varying title+from widths, long titles, and long senders.
- **truncation:** title clipped to LW via `%-*.*s` (47 @ COLS 80); `from`
  longer than 14 (`this-is-a-really-long-sender-name`→`this-is-a-real`) clipped
  to FROMW. ✓
- **no dangling SGR (feature's own output):** every colored span in list +
  read closes with `\033[0m` on the same line. Header rule, `[sev]`, `(disp)`,
  `ts`, bold title all reset. ✓
- **COLUMNS robustness:** guard `case "$COLS" in *[!0-9]*|'') COLS=80` +
  `LW` floor at 8 verified standalone: `abc/""/-5/1e3/"80 "`→80; tiny COLS→LW=8;
  even `COLS=0` (what bash coerces invalid `COLUMNS` to) → LW floored to 8, **no
  crash, no negative-width**. ✓
- **color knob matrix (piped baseline):** `always|1|yes`→ANSI; `never|0|no|auto|
  bogus|""`→plain. **`NO_COLOR=1` beats `FLEET_INBOX_COLOR=always`** ✓.
  On a pty: `auto`→ANSI, `NO_COLOR`→plain, `never`→plain. ✓
- **consume path** (`fleet inbox`): on a tty, `less` invoked with `-R` and its
  stdin carries ANSI (verified via a `less` stub); piped-to-`cat` / redirected
  → 0 ANSI; both archive all live msgs after display. ✓
- **put confirmation line:** `inbox: queued … [sev] …` colors the `[sev]` token
  on a tty, plain when piped. ✓
- **set -u clean:** unset COLUMNS/NO_COLOR/FLEET_INBOX_COLOR/TMUX_PANE/LINES →
  list + read render fine, no unbound-variable error in the styling code (all
  reads use `${x:-…}` defaults; fmt_age uses `${1:-0}`).
- **printf-injection safe:** title `pct %s %d %%n end` renders literally (title
  is a printf *argument* to `%s`, never a format string).
- **disk purity:** every `put`-created `.msg` is plain text — display ANSI never
  reaches disk. The colored output is display-only.

## Minor notes (none break the feature)

1. **sev string >9 chars clipped.** `SEVW=9` with `%-*.*s` truncates `[critical]`
   (10 chars) to `[critical` — the closing `]` is dropped. Only reachable with a
   corrupt/hand-crafted sev value; `inbox_put` forces sev∈{info,warn,blocked}
   (max `[blocked]`=9). Cosmetic.
2. **Body verbatim → unterminated ANSI bleeds (PRE-EXISTING).** A `.msg` body
   containing a raw `\033[41;97m` with no reset bleeds its color into the next
   message's header and, for the last message, into the **shell prompt** after
   the command exits (verified: a post-command marker rendered with red bg).
   The fake gate sentinel (`FLEET_GATE_OK …`) prints verbatim and triggers
   nothing (read is pure display) ✓. **This is NOT a styling regression** — the
   body-print line `inbox_body "$f"; printf '\n'` is byte-identical to the
   pre-feature code; the body was always printed verbatim with no reset.
   *Hardening opportunity:* emit a `\033[0m` after `inbox_body` when color is on,
   to contain body escapes.
3. **title/from with embedded raw ESC unsanitized.** A `title=`/`from=` field
   holding raw ESC bytes renders them (color + the ESC bytes count against the
   `.*` width budget → can misalign the age column / bleed). The pre-feature
   list already printed title raw; the new age column now sits downstream of it.
   Edge — needs an odd/crafted field; normal `put -t` is plain text.
4. **`NO_COLOR=""` (empty but present) → color ON.** Code uses `[ -n "${NO_COLOR:-}" ]`,
   so an empty-but-set `NO_COLOR` is treated as unset. Strict no-color.org says
   honor when *present regardless of value*. Minor spec deviation (common in the
   wild).
5. **`FLEET_INBOX_COLOR` is case-sensitive.** `Always`/`ALWAYS` fall to the `*`
   (auto) branch. Minor.
6. **Empty-inbox dim inconsistency.** `inbox list`'s normal "inbox empty" is dim
   on a tty; the dir-missing early-return and `inbox read` on empty print plain
   (non-dim) "inbox empty" (they return before color setup). Cosmetic.
7. **Huge valid COLUMNS not clamped.** `COLUMNS=999999999999` → `LW` ~1e12 →
   printf pads ~a billion spaces (no upper clamp). Unrealistic in a real
   terminal. Minor.

## How to reproduce (isolated)

```sh
F=/home/red/proj/pc-tune/fleet/fleet_inbox-styling/bin/fleet
export FLEET_ROOT=$(mktemp -d); export FLEET_SESSION=isoA
# seed via put, or hand-craft .msg files with backdated epoch filenames + sev/from
script -qec "FLEET_ROOT='$FLEET_ROOT' FLEET_SESSION=isoA COLUMNS=80 '$F' inbox list" /dev/null | cat -v
script -qec "FLEET_ROOT='$FLEET_ROOT' FLEET_SESSION=isoA '$F' inbox read all"  /dev/null | cat -v
FLEET_ROOT="$FLEET_ROOT" FLEET_SESSION=isoA FLEET_INBOX_COLOR=always "$F" inbox list | cat -v   # forced ANSI
FLEET_ROOT="$FLEET_ROOT" FLEET_SESSION=isoA NO_COLOR=1 FLEET_INBOX_COLOR=always "$F" inbox list | cat -v  # plain (NO_COLOR wins)
```

No production code edited. Scratch under the session scratchpad; tmp roots
cleaned by mktemp residue under scratchpad only.

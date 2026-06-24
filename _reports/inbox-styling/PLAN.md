# Inbox styling — implementation plan (RESEARCH ONLY)

Goal: color/format the **`fleet` CLI** inbox output (`inbox_list`, `inbox_read`,
and put/redirect feedback) so it reads as nicely as the dashboard, **without**
ever leaking ANSI into pipes, machine consumers, or the pager when not on a tty.
Reuse the palette already living in `bin/fleet-dash` — invent nothing new.

---

## 1. Current state (cited)

### `bin/fleet` (bash) — the unstyled surfaces

- **`inbox_list`** `bin/fleet:1709-1720` — the one styled-output target. Row:
  ```sh
  printf '%s %-9s %-24s %s\n' '*' "[$sev]" "$from" "$title"   # :1717
  ```
  Plain. No color. `*` marker, `[sev]` padded 9, `from` padded 24, `title`.
- **`inbox_read`** `bin/fleet:1722-1739` — full-body display. Two header printfs:
  ```sh
  printf '── [%s] %s%s\n'  "$sev" "$from" ...(disp)        # :1735
  printf '   %s  %s\n\n'   "$ts"  "$title"                 # :1736
  inbox_body "$f"; printf '\n'                             # :1737
  ```
- **`cmd_inbox` bare/`view`** `bin/fleet:2072-2079` — the CONSUME pager path:
  ```sh
  local pager=cat
  [ -t 1 ] && command -v less >/dev/null 2>&1 && pager="less -R"   # :2076
  { inbox_list; echo; inbox_read all; } | $pager                   # :2077
  inbox_clear >/dev/null
  ```
  **Critical:** here `inbox_list`/`inbox_read` stdout is the `|` PIPE, never a
  tty, even when the user is on a terminal. Pager is `less -R` (handles ANSI)
  only when cmd_inbox's *own* stdout is a tty. This is the central design knot
  (see §4).
- **put feedback** `bin/fleet:1703` `echo "inbox: queued $id [$sev] — $title"`.
- **send→inbox redirect feedback** `bin/fleet:939-940` and `:986-987`
  (`echo "...redirecting to the inbox..." >&2`). Both go to **stderr**.

### Machine consumers / DO-NOT-COLOR surfaces

- **`inbox_field`** `:1577`, **`inbox_body`** `:1578` — raw value parsers. The
  reap-guard (`inbox_has_needs_human_from` `:1596-1608`), `inbox_route`,
  `inbox_pop_text` `:1848`, dash's own `ibx_field` `fleet-dash:386` all parse
  these. **Never** color inside the `.msg` file or these accessors — they read
  the on-disk header which stays plain text. We only color at the *display*
  printf in `inbox_list`/`inbox_read`.
- **`inbox_pop_text`** `bin/fleet:1848` — builds the text **pasted into the
  orchestrator input**. Must stay clean. Untouched.
- `inbox_count` `:1615` echoes a bare integer — untouched.

### `bin/fleet-dash` (bash) — the palette to REUSE

The dashboard is an always-on alt-screen TUI, so it colors unconditionally with
**raw SGR escapes** (`printf '\033[..m'`), **no `tput`**, no tty guard. The
canonical severity palette:

```sh
sev_color() { case "$1" in blocked) printf '\033[31m' ;;   # red       fleet-dash:397
                           warn)    printf '\033[33m' ;;   # yellow
                           *)       printf '\033[2m'  ;; esac }  # info = dim
```
Supporting: `sev_rank` `:398`, `sev_max` `:399-400`, `sev_pcol` `:401`
(256-color pill: blocked=1 warn=3 info=6). Other palette refs: `glyph_color`
`:96-101`, `mode_color` `:131-136`, `gitcolor` `:198-204`, the dim `\033[2m`
frame and `\033[1m`/`\033[22m` bold used throughout `render_inbox`
`fleet-dash:873-965`.

**Width trick already used by the dash** (`render_inbox:935`): apply color, then
the *padded* field, then reset — padding lives **inside** the color span so the
ANSI bytes never enter printf's width count:
```sh
sevtxt=$(printf '%s%-*.*s\033[0m' "$(sev_color "$sev")" "$SEVW" "$SEVW" "$sevf")
```
This is the exact pattern to mirror in `inbox_list` so columns stay aligned.

**Conclusion:** the dashboard inbox view is **already pretty**. The work is
entirely in `bin/fleet` — bringing the CLI peeks up to the dash's palette while
honoring the dash's "raw SGR, no tput" convention, but adding the tty gate the
dash doesn't need.

---

## 2. Color mechanism

- **Raw SGR escapes** via `printf '\033[..m'`, matching fleet-dash. **No
  `tput`** — it adds a fork per call, a `$TERM` dependency, and a failure mode;
  the dash deliberately avoids it. Raw `printf` of a constant escape cannot fail,
  which is itself the fail-silent property.
- **Single source of truth:** add a `sev_color()` to `bin/fleet` that is a
  byte-for-byte copy of `fleet-dash:397` (blocked=31 / warn=33 / info=dim). Add
  a `c_reset() { printf '\033[0m'; }` (or inline `\033[0m`). Optionally
  `c_dim='\033[2m'`, `c_bold='\033[1m'` locals. Keep the mapping identical so the
  two files never drift (the codebase already keeps `inbox_from_is_system`
  mirrored across both — same discipline, note it in a comment).

---

## 3. What to style (per surface)

All within the display printf only; on-disk `.msg` stays plain.

### `inbox_list` (`:1717`)
- `[sev]` bracket token → `sev_color` (red/yellow/dim), padded **inside** the
  span, reset after.
- `from` → dim (`\033[2m`) so the eye lands on sev+title (mirrors dash dimming of
  system senders); or leave default. Open Q1.
- `title` → default weight (the payload — keep it the brightest thing).
- `*` unread marker → keep, optionally sev-tinted. Low value; Open Q2.
- Keep current column widths (`%-9s`/`%-24s`) but move the pad inside the color
  span per §1's width trick.

### `inbox_read` (`:1735-1736`)
- `──` rule → dim.
- `[sev]` → `sev_color`.
- `from` → bold (`\033[1m…\033[22m`) — it's the sender headline.
- `(disp)` dispatch tag → dim.
- `ts` timestamp → dim.
- `title` → default/bold.
- Body (`inbox_body`) → **untouched** (it is arbitrary worker text; never
  re-color it — could contain its own escapes / code).

### put feedback (`:1703`) — optional, low priority
- Tint the `[sev]` in `inbox: queued … [$sev] — title`. Same tty gate. Open Q3.

### send→inbox redirect feedback (`:939-940`, `:986-987`) — **leave plain**
- These print to **stderr** and are operational notices, not the inbox render.
  Out of scope; do not gate-test them.

---

## 4. TTY detection — the core rule

**Color only when the destination is a terminal.** Three call shapes:

| Invocation | inbox_list/read stdout | want color? |
|---|---|---|
| `fleet inbox list` on a terminal | tty | **yes** |
| `fleet inbox list \| grep` / `> file` | pipe/file | **no** |
| `fleet inbox` (bare consume) on a terminal | **pipe** (into `less -R`) | **yes** |
| `fleet inbox \| cat` (bare, piped) | pipe (into `cat`) | **no** |

A naive `[ -t 1 ]` inside `inbox_list` gets rows 1-2 right but **fails rows 3-4**:
in the consume path stdout is always the `|`, so it would never color even though
`less -R` is rendering to a real terminal.

**Design — a color decision helper + an explicit override the consume path sets:**

```sh
# rc 0 = emit color. Honors an explicit override first (set by the consume pager
# path, where our stdout is a pipe but the FINAL sink is a tty), else auto-detects
# stdout being a tty. Fail-silent, respects NO_COLOR.
inbox_color_on() {
  [ -n "${NO_COLOR:-}" ] && return 1                 # https://no-color.org
  case "${FLEET_INBOX_COLOR:-auto}" in
    always|1|yes) return 0 ;;
    never|0|no)   return 1 ;;
    *)            [ -t 1 ] ;;                          # auto
  esac
}
```

Then in `inbox_list`/`inbox_read`, compute once at the top:
```sh
local C=0; inbox_color_on && C=1
```
and guard every escape: `[ "$C" = 1 ] && col=$(sev_color "$sev") || col=""`,
emit `printf '%s%-9s%s' "$col" "[$sev]" "$reset"` where `reset` is `\033[0m`
when `C=1` else empty. (Wrapping helper `sgr() { [ "$C" = 1 ] && printf '%s' "$1"; }`
keeps the printfs readable.)

**The consume path** (`cmd_inbox` bare, `:2075-2078`) sets the override so the
piped helpers still colorize, matched to the same condition that picks `less -R`:
```sh
local pager=cat color=never
if [ -t 1 ] && command -v less >/dev/null 2>&1; then pager="less -R"; color=always; fi
FLEET_INBOX_COLOR="$color" sh -c '...'   # or simply: local FLEET_INBOX_COLOR="$color"; { inbox_list; echo; inbox_read all; } | $pager
inbox_clear >/dev/null
```
Because `inbox_list`/`inbox_read` are shell functions in the same process, a
plain `local FLEET_INBOX_COLOR=…` in `cmd_inbox` is visible to them (dynamic
scope) — no `export`, no subshell needed. Set it to `always` only when we picked
`less -R` (tty), `never` otherwise. **Net:** color reaches `less -R`, never
reaches `cat`, never reaches a redirect/pipe.

Note: pager must be `less -R` (raw control chars), which the code already uses —
no change to the pager flag needed, only the `color=` companion.

---

## 5. Fail-silent compliance

- No new external process. Raw `printf` escapes can't fail. `[ -t 1 ]` is a shell
  builtin, never errors; no redirect needed but harmless to leave bare.
- `sev_color` is pure (a `case`), no externals.
- `NO_COLOR` honored (cheap correctness; the dash doesn't bother since it's a
  TUI, but a CLI should — see Open Q4).
- No `.msg` write-path change → `inbox_field`/`inbox_body`/`inbox_pop_text`/dash
  parsers all keep reading plain text. Gate-parse sentinels (`--` separator,
  `key=value`) untouched.

---

## 6. Touch-points summary

| File:line | Change |
|---|---|
| `bin/fleet` near `:1556` (inbox helpers block) | add `sev_color()` (copy of `fleet-dash:397`) + `inbox_color_on()` helper, comment "keep sev_color in sync with fleet-dash" |
| `bin/fleet:1709-1720` `inbox_list` | compute `C`, color `[sev]`/`from`/marker via the width-inside-span pattern |
| `bin/fleet:1722-1739` `inbox_read` | compute `C`, color rule/`[sev]`/`from`/`disp`/`ts`; body untouched |
| `bin/fleet:2075-2078` `cmd_inbox` bare | set `local FLEET_INBOX_COLOR=always\|never` alongside the existing `less -R`/`cat` choice |
| `bin/fleet:1703` put feedback (optional) | tint `[sev]` under the same gate |

No change to: `inbox_field`, `inbox_body`, `inbox_pop_text`, `inbox_count`,
`inbox_route`, reap-guard, send-redirect echoes, or **any** of `fleet-dash`
(already styled).

---

## 7. Edge cases & risks

- **Width/alignment:** ANSI bytes counted by printf `%-Ns` → misaligned columns.
  Mitigation: pad **inside** the color span (dash's proven pattern, §1).
- **Pager corruption:** the whole reason for the override design — never emit ANSI
  into `cat`/redirects/`grep`. The table in §4 is the spec; the proof (§8) asserts
  it.
- **`less` without `-R`:** would show raw `^[[33m`. Code already uses `-R`; keep it.
- **Body re-coloring:** worker bodies may contain escapes or code fences — never
  pass body through `sev_color`/wrapping. Print verbatim.
- **`NO_COLOR` vs `FLEET_INBOX_COLOR=always`:** decide precedence. Plan: `NO_COLOR`
  wins (hard off) — most conservative, matches the spec's intent. Open Q4.
- **Dash drift:** `sev_color` now exists in two files. Add the same "mirrored —
  keep in sync" comment the codebase already uses for `inbox_from_is_system`
  (`:1585`).
- **`TERM=dumb`/no-tty CI:** `[ -t 1 ]` already false there → no color. Covered.
- **8-color vs 256:** plan uses only basic SGR (31/33/2/1) like `sev_color`, the
  most portable; the dash's 256-color pills are not reused on the CLI.

---

## 8. Open questions (seed the adviser debate)

1. **Color `from` in `inbox_list`?** Dim it, or leave default? Dim de-emphasises
   the sender vs the title; but `from` is often the scannable key.
2. **Tint the `*` unread marker** by severity, or keep it plain `*`?
3. **Style put feedback (`:1703`)** too, or keep all feedback echoes plain for
   consistency with the stderr redirect notices?
4. **`NO_COLOR` support** — add it (correct, cheap) or stay minimal like the dash
   (which ignores it)? And precedence vs `FLEET_INBOX_COLOR=always`.
5. **Expose `FLEET_INBOX_COLOR` as a documented knob** (force color in pipes for
   e.g. `| less -R` by hand), or keep it an internal implementation detail used
   only by the consume path?
6. **Truecolor / Omarchy theme:** should sev colors pull from the live terminal
   theme (like other Omarchy-aware tooling) or stay fixed basic SGR? Fixed is
   simpler and matches the dash; theming is a stretch.

---

## PROOF DESIGN

fleet has **no test runner** (`CLAUDE.md`: "No build, no test suite"). Prove with
an **isolated scenario script** against a throwaway project root + fake
`FLEET_SESSION`, exercising the four §4 call shapes. The `.msg` files are written
directly by `inbox_put`, which only needs `inbox_dir` to resolve a root — so a
tmp root + `cd` is enough; no tmux session required for the put/list/read paths
(those never touch tmux). Driving a real tty uses `script(1)` to allocate a pty.

### Setup

```sh
set -e
FLEET=/home/red/proj/pc-tune/fleet/main/bin/fleet
ROOT=$(mktemp -d)
mkdir -p "$ROOT/.fleet"
cd "$ROOT"                       # inbox_dir resolves <root>/.fleet/inbox from cwd/git-top
# seed three severities
"$FLEET" inbox put --from alpha  --sev info    -t "info msg"    -m "body i"
"$FLEET" inbox put --from bravo  --sev warn    -t "warn msg"    -m "body w"
"$FLEET" inbox put --from charlie --sev blocked -t "blocked msg" -m "body b"
ESC=$'\033'                      # for grep
```
> If `inbox_dir` resolves via tmux session rather than cwd, wrap the whole script
> in a throwaway session: `tmux new-session -d -s prooftest -e FLEET_SESSION=prooftest`
> and run each command with `tmux send` / or set the env the helper reads. Confirm
> `inbox_dir`'s root resolution at implementation time and adjust; the assertions
> below are unchanged.

### (a) TTY → colors present

Allocate a pty with `script` so `[ -t 1 ]` is true:

```sh
out=$(script -qec "$FLEET inbox list" /dev/null)
printf '%s' "$out" | grep -q "$ESC\[" \
  && echo "PASS a: ANSI present on tty" \
  || { echo "FAIL a: no ANSI on tty"; exit 1; }
# sev-specific: blocked row carries red (31)
printf '%s' "$out" | grep -q "$ESC\[31m" \
  && echo "PASS a2: blocked=red present" || { echo "FAIL a2"; exit 1; }
```

### (b) Piped / non-tty → NO raw ANSI

```sh
out=$("$FLEET" inbox list | cat)              # stdout is a pipe
if printf '%s' "$out" | grep -q "$ESC\["; then
  echo "FAIL b: raw ANSI leaked into pipe"; exit 1
else echo "PASS b: clean in pipe"; fi
# redirect to file too
"$FLEET" inbox list > "$ROOT/out.txt"
grep -q "$ESC\[" "$ROOT/out.txt" \
  && { echo "FAIL b2: ANSI in file"; exit 1; } || echo "PASS b2: clean in file"
# read peek too
"$FLEET" inbox read all | cat | grep -q "$ESC\[" \
  && { echo "FAIL b3: ANSI in read pipe"; exit 1; } || echo "PASS b3: read clean in pipe"
```

### (c) Consume-pager path still works (and is clean when piped)

```sh
# piped consume: pager=cat, must be ANSI-clean AND must archive all live msgs
before=$("$FLEET" inbox count)
out=$("$FLEET" inbox | cat)
printf '%s' "$out" | grep -q "$ESC\[" \
  && { echo "FAIL c: ANSI into cat sink"; exit 1; } || echo "PASS c: consume-pipe clean"
after=$("$FLEET" inbox count)
[ "$before" -ge 3 ] && [ "$after" = 0 ] \
  && echo "PASS c2: consume archived all ($before -> $after)" \
  || { echo "FAIL c2: count $before -> $after"; exit 1; }
# tty consume: less -R receives color (re-seed first), drive non-interactively
"$FLEET" inbox put --sev blocked -t t -m b
script -qec "env PAGER='less -R' $FLEET inbox" /dev/null >/dev/null 2>&1 \
  && echo "PASS c3: tty consume exits clean" || echo "WARN c3: inspect manually"
```
> c3 is a smoke check (less may need `-F`/`-X` to auto-quit non-interactively, or
> drive it with `LESS=-FEX`); the load-bearing assertions are a/b/c/c2.

### (d) `fleet doctor` still green

```sh
"$FLEET" doctor && echo "PASS d: doctor green" || { echo "FAIL d"; exit 1; }
```

### (e) Machine-consumer regression — `.msg` files stay plain

Proves we colored only the display, not the on-disk header (reap-guard / pop /
dash parsers depend on this):

```sh
"$FLEET" inbox put --from delta --sev warn -t "plain check" -m body
msg=$(ls -1 "$ROOT/.fleet/inbox"/*.msg | head -1)
grep -q "$ESC\[" "$msg" \
  && { echo "FAIL e: ANSI written into .msg"; exit 1; } || echo "PASS e: .msg plain on disk"
# field parse still yields a clean value
val=$("$FLEET" inbox ... )  # or source the helper; assert inbox_field returns 'warn' with no escapes
```

### Green criteria

a, a2, b, b2, b3, c, c2, d, e all PASS → color shows on a real terminal and
through `less -R`, never leaks into pipes/files/`cat`, the consume path still
archives, the on-disk format is untouched, and `doctor` is green. c3 is a manual
smoke. Cleanup: `rm -rf "$ROOT"` (and kill the throwaway tmux session if used).

# TDD Phase 3b — GREEN (inbox color styling)

Implemented the styling in `bin/fleet` to turn the RED assertions (A1 A2 AL1
DIST) GREEN, without weakening, deleting, or relaxing any assertion in
`proof.sh`. Every previously-green assertion (B1/B2/B3 clean-piped, E1/E2 .msg
plain on disk, C1/C2/C3 consume, NC1/NC2 NO_COLOR, D5/SYN) stays green.

**16 / 16 green.**

## What changed in `bin/fleet` (display only)

| Location | Change |
|---|---|
| new helpers before `inbox_list` | `sev_color()` (byte-for-byte copy of `fleet-dash:397` + keep-in-sync comment), `fmt_age()` (mirror of `fleet-dash:fmt_age`), `inbox_color_on()` (NO_COLOR wins → `FLEET_INBOX_COLOR` auto/always/never → `[ -t 1 ]`) |
| `inbox_list` | color `[sev]` via `sev_color`, dim **system senders only** (`inbox_from_is_system`), right-aligned dim age column (epoch from msg-id), pad **inside** the color span; dim `inbox empty` |
| `inbox_read` | dim `──`/`(disp)`/`ts`, sev-colored `[sev]`, **one** bright anchor = bold `title`; body printed VERBATIM |
| `cmd_inbox` consume | plain `local FLEET_INBOX_COLOR=always\|never` matched to the `less -R`/`cat` choice (NOT the `sh -c` form) |
| `inbox_put` feedback | tint only the `[sev]` token under the same tty gate |

Untouched (machine paths / write path / gate sentinels): `inbox_field`,
`inbox_body`, `inbox_pop_text`, `inbox_count`, `inbox_route`, the reap-guard,
the `.msg` write path, send-redirect echoes, and all of `bin/fleet-dash`.

### Must-fixes honored
1. **Real bytes** — every escape is `$'\033[…m'` or `$(printf '\033[0m')`; sev via `col=$(sev_color …)`. No literal `'\033…'` through `%s`.
2. **set -u** — every style var (`C reset dim bold sevc disptag sevtxt fromtxt titletxt agetxt sevf`) initialized to `""`/`0` unconditionally before the color-on test; overwritten only when on.
3. **No dangling SGR** — every styled `printf` closes its span with `reset` before the next token and before `inbox_body`; body verbatim.
4. **Consume override** — plain-`local` form, `always` only when `[ -t 1 ] && less`, else `never`.

## Commands run

    bash -n bin/fleet                       # OK
    bash _reports/inbox-styling/proof.sh    # 16/16, exit 0
    bin/fleet doctor                        # all green, exit 0

## Full green proof output

    == fleet under test: /home/red/proj/pc-tune/fleet/fleet_inbox-styling/bin/fleet
    == isolated root:     /tmp/fleet-inbox-proof.JvMFgC

    PASS  D5   inbox_dir resolves to $ROOT/.fleet/inbox (root isolation)
    PASS  SYN  bin/fleet parses (bash -n) — syntax canary
    info  doctor exit=0 (informational canary only)

    PASS  A1   [TTY] inbox list emits ANSI
    PASS  A2   [TTY] inbox read all: blocked carries red \033[31m
    PASS  B1   [pipe] inbox list | cat has NO ANSI
    PASS  B2   [redirect] inbox read all > file has NO ANSI
    PASS  B3   [pipe] inbox read all | cat has NO ANSI
    PASS  E1   [disk] no *.msg carries ANSI
    PASS  E2   [disk] warn message header has '^sev=warn$'
    PASS  NC1  [TTY+NO_COLOR] inbox list has NO ANSI
    PASS  NC2  [TTY+NO_COLOR+always] NO_COLOR beats FLEET_INBOX_COLOR=always (no ANSI)
    PASS  AL1  [pipe+always] FLEET_INBOX_COLOR=always forces ANSI when piped
    PASS  DIST [distinction] always→ANSI, NO_COLOR+always→no ANSI
    PASS  C1   [consume] >=3 live msgs before consume (have 3)
    PASS  C2   [consume] fleet inbox | cat has NO ANSI
    PASS  C3   [consume] all live msgs archived after consume (now 0)

    == 16 passed, 0 failed
    exit=0

## fleet doctor (real session) — green

    ok   tmux / nvim / git / python3 / fzf / notify-send …
    ok   harness: claude / omp …
    ok   fleetd socket / hooks wired / fleetd.service enabled
    … (all `ok`, exit 0)

## Visual sample (TTY render, escapes shown as `ESC` via `cat -v`)

`inbox list` — blocked=red `[31m`, warn=yellow `[33m`, info=dim `[2m`; system
sender `main` dimmed, worker senders default weight; dim right-aligned age:

    * ESC[31m[blocked]ESC[0m ESC[2mmain          ESC[0m needs human: creds        ESC[2m   0sESC[0m
    * ESC[33m[warn]   ESC[0m worker-y       flaky test retry                       ESC[2m   0sESC[0m
    * ESC[2m[info]   ESC[0m worker-x       build finished                         ESC[2m   0sESC[0m

`inbox read all` — dim `──`/ts, sev-colored `[sev]`, bold title (one anchor),
body verbatim, every span closed with `ESC[0m`:

    ESC[2m──ESC[0m ESC[31m[blocked]ESC[0m main
       ESC[2m2026-06-24T09:39:36+02:00ESC[0m  ESC[1mneeds human: credsESC[0m

    paste token

    ESC[2m──ESC[0m ESC[33m[warn]ESC[0m worker-y
       ESC[2m2026-06-24T09:39:36+02:00ESC[0m  ESC[1mflaky test retryESC[0m

    retried twice

When piped / redirected / under `NO_COLOR` / not a tty: the exact same lines
print with **zero** escapes (proven by B1/B2/B3/E1/NC1/NC2/C2).

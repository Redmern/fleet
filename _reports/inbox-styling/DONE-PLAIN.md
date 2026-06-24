# Inbox styling — DONE (plain English)

## What got built
`fleet inbox list` and `fleet inbox read` are now styled on a terminal, matching
the dashboard:
- **Severity colors** — blocked = red, warn = yellow, info = dim.
- **Relative-age column** — `5s / 3m / 2h / 4d` per message (was: no time shown).
- **Detail view hierarchy** — bold title (the one bright anchor), dim
  separators / timestamps / dispatch-tags; system-origin senders dimmed so real
  worker messages stand out.
- **Honors your terminal's real width** so titles aren't clamped on wide screens.

When output is piped, redirected to a file, or read by a program, it stays plain
text — no color codes leak. `NO_COLOR` turns it off (any value, even empty);
`FLEET_INBOX_COLOR=auto|always|never` overrides. On-disk message files and
everything that parses them are untouched.

## How the tests prove it works
A self-contained script (`_reports/inbox-styling/proof.sh`) runs against a
throwaway, isolated inbox (`FLEET_ROOT` — never your real one) and checks **23
assertions, all green**:
- **Color shows on a real terminal** — blocked=red, warn=yellow, info=dim, bold
  title, age token, system-sender dimmed (worker not). *(A1/A2/W-WARN/W-INFO/
  W-BOLD/W-AGE/W-SYSDIM)*
- **Zero color leaks** when piped, redirected, or `cat`'d — and the message files
  on disk stay plain text. *(B1/B2/B3/E1/E2)*
- **The consume view** (`fleet inbox`) still shows everything and archives it,
  colored through `less -R` but clean when piped. *(C1/C2/C3)*
- **Real terminal width is used**, not a pinned 80 — a long title isn't truncated
  on a wide terminal. *(W-WIDTH)*
- **`NO_COLOR` wins** over a force-on, even when set empty. *(NC1/NC2/DIST/W-NOCOLOR)*

This was done test-first (red → green), then **two independent testers** both
returned WORKS, then an **adversarial debate** caught two real gaps (titles
pinned to 80 cols on real terminals; the proof didn't guard the visuals) — both
fixed in a second tight iteration, **verified RED-first on the pre-fix binary**
(W-WIDTH + W-NOCOLOR fail there, pass after the fix). `fleet doctor` green.

## Run the proof yourself
```sh
cd /home/red/proj/pc-tune/fleet/fleet_inbox-styling
bash _reports/inbox-styling/proof.sh        # → 23 passed, 0 failed
```
Or just look at it live (uses your real terminal):
```sh
./bin/fleet inbox list      # colored, with the age column
./bin/fleet inbox read all  # colored headers, bold titles
./bin/fleet inbox list | cat   # plain — no color codes
```

## Scope notes
- Pre-existing behavior left alone: a worker that stores raw escape codes *inside
  a message body* still prints them verbatim (now contained by a trailing reset);
  bodies are never re-colored (spec forbids it).
- Known limitation (documented in code, not a blocker): titles with wide unicode
  glyphs can shift the age column by a column or two — bash counts bytes, not
  display width; the dashboard has the same trade-off.

## Merge
Branch `fleet/inbox-styling` → `main` (3 commits: TDD-RED test, TDD-GREEN impl,
NEEDS-WORK-loop fix). `bin/fleet` only (+ `_reports/` artifacts); `bin/fleet-dash`
unchanged.

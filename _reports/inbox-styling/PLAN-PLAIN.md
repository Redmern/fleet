# Inbox styling — plain-English plan

## What we'll build
Make `fleet inbox` output **pretty on a terminal**, matching the dashboard's
look, without changing anything machines read.

Today `fleet inbox list` and `fleet inbox read` print plain grey text. We'll add
color and a cleaner layout:
- **Severity coloring** — `[blocked]` red, `[warn]` yellow, `[info]` dim (the
  exact same palette the dashboard already uses).
- **A relative-age column** — `5s / 3m / 2h / 4d` per message, so you can see at a
  glance what's fresh vs stale (the dashboard shows this; the CLI currently shows
  no time at all).
- **A clear hierarchy in the detail view** — the message *title* stands out
  (bold), separators / timestamps / dispatch tags recede (dim), system-origin
  senders dim so real worker messages pop.

## The one rule that makes it safe
Color **only when output goes to a real terminal**. When you pipe it
(`fleet inbox list | grep`), redirect it to a file, or a program reads it, the
output stays plain text — no color codes leak. The "consume" pager path
(`fleet inbox`) still gets color because it pages through `less -R`. Also honors
the standard `NO_COLOR` env var (off = no color, always wins).

## What we will NOT touch
The on-disk message files and everything that parses them (the dashboard, the
reap guard, the gate-approval popping). Those keep reading plain text exactly as
now — so nothing in the orchestration machinery changes.

## Where the work is
One file: `bin/fleet`. The dashboard (`bin/fleet-dash`) is already styled — we're
bringing the command-line view up to match it, reusing its color helpers.

## How we'll prove it works (no test runner in fleet)
A self-contained scenario script against a **throwaway inbox** (isolated via
`FLEET_ROOT`, so it never touches the real one):
1. Put one info, one warn, one blocked message.
2. On a real terminal → output has colors (blocked shows red). ✅
3. Piped / redirected to a file → output is clean, zero color codes. ✅
4. The `fleet inbox` consume view still archives all messages and stays clean
   when piped. ✅
5. The saved message files on disk are still plain text (machines unaffected). ✅
6. `fleet doctor` still green.

We write these checks as tests FIRST, watch them fail for the right reason, then
implement until they pass — and two independent testers re-verify before done.

## Risks (all mitigated in the build brief)
- Color codes must be **real escape bytes**, not literal text, or you'd see
  `\033[2m` garbage. (Handled.)
- Must not crash under `set -u` if a color is unset. (Every var pre-initialized.)
- Columns must stay aligned despite invisible color bytes. (Pad-inside-span.)
- The proof must isolate its inbox or it pollutes the live one. (Handled —
  this already bit us once during the debate.)

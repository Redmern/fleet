# TDD Phase 3a — RED (inbox color styling)

Tests authored FIRST, run against the **current unstyled** `bin/fleet`. No
production code touched. The color assertions fail (no color exists yet) — the
correct RED — while the "clean when piped / plain on disk / consume" assertions
already pass.

## Plan-doc note

`_reports/inbox-styling/SYNTHESIS.md` and `PLAN.md` do **not** exist on this
branch (`fleet/inbox-styling`) or any other branch, and there is no
`ls-menu-agent-navigate/ls_pick_test.sh` model script anywhere in the tree
(checked `git log --all` + `find`). The proof was authored from the self-contained
PROOF DESIGN in the task prompt, with all six must-fixes applied. Flag for the
orchestrator: the "authoritative" plan docs were never committed.

## Palette mirrored (from `bin/fleet-dash:sev_color`, ~397)

    blocked → \033[31m (red)   warn → \033[33m (yellow)   info/other → \033[2m (dim)

## Commands run

    chmod +x _reports/inbox-styling/proof.sh
    bash _reports/inbox-styling/proof.sh            # default: exit 1 (4 RED)
    PROOF_EXPECT_RED=1 bash _reports/inbox-styling/proof.sh   # gate: exit 0 (RED set == expected)

The proof exports `FLEET_ROOT="$ROOT"` **and** `FLEET_SESSION=prooftest` (must-fix
#5: both exported so the `script(1)` pty inherits them; no `cd` reliance), and
asserts `inbox_dir` resolves to `$ROOT/.fleet/inbox`.

## Captured RED output

    == fleet under test: /home/red/proj/pc-tune/fleet/fleet_inbox-styling/bin/fleet
    == isolated root:     /tmp/fleet-inbox-proof.oR5hqe

    PASS  D5   inbox_dir resolves to $ROOT/.fleet/inbox (root isolation)
    PASS  SYN  bin/fleet parses (bash -n) — syntax canary
    info  doctor exit=0 (informational canary only)

    FAIL  A1   [TTY] inbox list emits ANSI
    FAIL  A2   [TTY] inbox read all: blocked carries red \033[31m
    PASS  B1   [pipe] inbox list | cat has NO ANSI
    PASS  B2   [redirect] inbox read all > file has NO ANSI
    PASS  B3   [pipe] inbox read all | cat has NO ANSI
    PASS  E1   [disk] no *.msg carries ANSI
    PASS  E2   [disk] warn message header has '^sev=warn$'
    PASS  NC1  [TTY+NO_COLOR] inbox list has NO ANSI
    PASS  NC2  [TTY+NO_COLOR+always] NO_COLOR beats FLEET_INBOX_COLOR=always (no ANSI)
    FAIL  AL1  [pipe+always] FLEET_INBOX_COLOR=always forces ANSI when piped
    FAIL  DIST [distinction] always→ANSI, NO_COLOR+always→no ANSI
    PASS  C1   [consume] >=3 live msgs before consume (have 3)
    PASS  C2   [consume] fleet inbox | cat has NO ANSI
    PASS  C3   [consume] all live msgs archived after consume (now 0)

    == 12 passed, 4 failed
    == RED: A1 A2 AL1 DIST

    default exit=1 ; PROOF_EXPECT_RED=1 exit=0 (RED set == EXPECTED_RED "A1 A2 AL1 DIST")

## Per-assertion verdict (now, against unstyled tree)

- **D5  PASS** — `inbox_dir` → `$ROOT/.fleet/inbox`; root isolation works via the two exported vars. (Setup invariant; not color.)
- **SYN PASS** — `bash -n bin/fleet` parses. Syntax canary only (must-fix #6: NOT a color canary).
- **A1  RED (correct)** — TTY `inbox list` emits NO ANSI; styling not written yet → no ESC. Will go green when `inbox_list` colorizes on a tty.
- **A2  RED (correct)** — TTY `inbox read all` does not contain `\033[31m`; blocked-red not implemented yet.
- **B1/B2/B3 PASS** — piped / redirected / `read all | cat` are ANSI-free *because nothing colors anything yet*. These must STAY green once auto-detect lands (no color when not a tty).
- **E1  PASS** — `.msg` files are plain on disk; color must never be persisted. Stays green.
- **E2  PASS** — `^sev=warn$` present in the warn header; field read by grep (must-fix #6: there is NO `fleet inbox field` verb). Stays green.
- **NC1 PASS** — `NO_COLOR=1` on a tty → no ANSI. Trivially green now (no color anywhere); becomes a real test post-styling.
- **NC2 PASS** — `NO_COLOR=1 FLEET_INBOX_COLOR=always` on a tty → no ANSI; NO_COLOR must win. Trivially green now; real test post-styling.
- **AL1 RED (correct)** — `FLEET_INBOX_COLOR=always | cat` produces NO ANSI; the `always` override isn't implemented. Goes green when `always` forces color even off-tty.
- **DIST RED (correct)** — needs `always→ANSI` AND `NO_COLOR+always→no ANSI`; the first half is false now (no `always` support), so the distinction fails. Goes green only when both color logic and NO_COLOR-precedence exist.
- **C1/C2/C3 PASS** — consume path shows ≥3 msgs, clean output, archives all (0 left). Behavior independent of color; stays green.

## Why this is the *right* RED

The four reds are exactly the assertions that require color to exist: TTY color
(A1/A2), the `always` override on a pipe (AL1), and the combined
always-vs-NO_COLOR distinction (DIST). Every "must stay clean" assertion
(piped/redirected/on-disk/consume) is already green, so the upcoming change is
constrained to *add* color on a tty / under `always` and *suppress* it under
`NO_COLOR` and when not a tty — it cannot leak ANSI into pipes, files, `.msg`
storage, or the consume path without turning a currently-green assertion red.

`PROOF_EXPECT_RED=1` certifies the RED state machine-checkably: it exits 0 only
when the failing set is **exactly** `A1 A2 AL1 DIST`. If a color assertion ever
*passes* against the unstyled tree, the gate fails — proving the test isn't a
false-positive.

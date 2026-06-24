# Debate — NEEDS-WORK (Phase 5, adversarial)

**Role:** argue the feature is NOT done. Find the strongest *honest* reason for one more iteration.
**Under test:** `bin/fleet` @ `fleet/inbox-styling` (`86fc0eb`), diff `5fb4a26..86fc0eb`.
**Honesty up front:** Every literal SPEC MUST from SYNTHESIS is *implemented* and was *verified by two
independent testers* (age column, one-bold-anchor, dim-system-sender, NO_COLOR-wins, all 6 must-fixes,
pad-inside-span alignment, consume override). The safety claims (disk purity, machine consumers, tty
gating) hold and I could not break them. So this is **not** a "MUST is flatly missing" case. It is a
"the feature under-delivers its own charter on the common path, and the evidence overstates coverage"
case. I believe points 1 and 2 below are legitimate grounds for NEEDS-WORK; 3–5 are supporting.

---

## VERDICT (this seat): NEEDS-WORK — one tight iteration, then ship.

The blocker is not a crash or a safety hole. It is that **the headline UX silently does not happen on
the terminals the user actually runs**, and **the proof artifact does not test the visual feature it is
being used to certify**. For a change whose entire reason to exist is "pretty + aligned + scannable,"
those two together justify another pass.

---

## 1. PRIMARY: title width is pinned to 80 on every real terminal — `${COLUMNS:-80}` is unset in practice (NEW, common path)

`inbox_list` computes its layout from terminal width:

```sh
COLS="${COLUMNS:-80}"; case "$COLS" in *[!0-9]*|'') COLS=80 ;; esac
fixed=$((5 + SEVW + FROMW + AGEW)); LW=$((COLS - fixed)); [ "$LW" -lt 8 ] && LW=8   # LW = title width
```

`COLUMNS` is a shell parameter that bash/zsh **do not export to child processes** by default, and
`bin/fleet` runs as its own bash via shebang. I verified empirically (this branch):

```
$ bash -c 'echo COLUMNS=[${COLUMNS:-UNSET}]'                 -> COLUMNS=[UNSET]
$ script -qec 'bash -c '\''echo [${COLUMNS:-UNSET}]'\''' …    -> [UNSET]   (the pty path proof/testers used)
$ grep -nE 'COLUMNS|checkwinsize|tput cols|stty size' bin/fleet
  1759:  COLS="${COLUMNS:-80}"; …    # the ONLY hit — no fallback, no checkwinsize
```

So in the real `fleet inbox list` invocation, `COLUMNS` is unset → `COLS=80` **always**, regardless of
the actual terminal. On a normal wide terminal (120/160/200 cols) the title is truncated to
`LW = 80 - 5 - 9 - 14 - 5 = 47` characters even though there is plenty of room. The SYNTHESIS UX rationale
("shrink `from` toward 14 to **give slack to the title**") is defeated — the slack is computed against a
phantom 80-col terminal and never materializes.

**This is not a copy of the dash.** SYNTHESIS's directive is "mirror the dash" and `fmt_age`/`sev_color`
are byte-copied — but the *width source* was not. `bin/fleet-dash` reads the real width:

```
fleet-dash:689   local cols rows; cols=$(tput cols); rows=$(tput lines)
fleet-dash:874   local cols rows; cols=$(tput cols); rows=$(tput lines)
fleet-dash:994   tsize() { stty size </dev/tty 2>/dev/null || echo "24 80"; }
```

`inbox_list` reuses the dash's *palette* but not its *width detection*, so the CLI view it was meant to
"bring up to match the dash" diverges from the dash on the exact axis (column layout) the feature is about.

**Why both testers missed it:** TEST-a and TEST-b each set `COLUMNS` explicitly in their harnesses
("`COLUMNS=80`", "`COLUMNS=40`") to probe the width-clamp logic — which *masks* the fact that the
variable is absent in the unforced path. proof.sh sets nothing and asserts nothing about width, and runs
through `script` where COLUMNS is also unset, so it can't surface this either.

**Fix scope:** small — fall back to `tput cols` (matching the dash) when `COLUMNS` is unset/zero, e.g.
`COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"`, fail-silent. Until then the marquee "scannable,
slack-to-title" benefit is not delivered on the user's actual terminal.

---

## 2. PRIMARY: "16/16 green" certifies the *gating*, not the *visual feature*

proof.sh is the artifact being leaned on for the gate, and it is excellent at proving the **safety/gating**
contract: tty→ANSI, pipe/redirect/read-all→clean, disk `.msg` plain, NO_COLOR-wins, always-forces,
consume-archives. But it proves almost **none of the visual MUSTs** the feature exists to add. Grepping
proof.sh for the visual behavior returns zero assertions:

| Visual MUST (SYNTHESIS)            | proof.sh coverage |
|------------------------------------|-------------------|
| Relative **age column** (the "biggest scannability win") | **0 assertions** — `fmt_age`/age never checked; buckets (`5s/3m/2h/4d`) unproven |
| **One bold anchor** (bold title)   | **0 assertions** — `\033[1m` never asserted |
| sev **palette** warn=yellow / info=dim | **0** — only `blocked`=red (A2/`has_red`); a warn→red regression would stay 16/16 green |
| **dim system sender** (Q1, `inbox_from_is_system`) | **0 — and never even seeded**: `seed()` puts only worker senders (`tester-a/b/c`), so the new system-sender branch gets **zero** execution in the proof |

So "16/16" silently conflates *"gating is safe"* with *"the feature is correct."* If a future refactor
broke the age buckets, dropped the bold, or mis-wired the system-dim branch, proof.sh would remain fully
green. Every visual MUST currently rests **solely** on the two human-read tester reports — there is no
regression net for the actual styling. For a feature whose whole payload is the rendering, that is an
incomplete proof, and "tests-first, two testers re-verify" reads stronger than the artifact delivers.
A `done` here ships a green proof that doesn't guard the thing that was built.

**Fix scope:** add 3–4 assertions to proof.sh — seed a backdated epoch and assert an age token renders;
seed a `from=main` system sender and assert it is dimmed while a worker sender is not; assert `\033[33m`
on warn and `\033[1m` on a read title. Cheap, and it closes the gap between the claim and the coverage.

---

## 3. NEW alignment-break surface introduced by this change: unicode titles

`%-*.*s` in bash printf counts **bytes**, not display columns. Pre-feature, the list printed the title
**last and unpadded** (`printf '* %-9s %-24s %s'`) — nothing followed it, so multibyte titles could not
misalign anything. This change puts the title in a **fixed-width field with the age column after it**:

```sh
titletxt=$(printf '%-*.*s' "$LW" "$LW" "$title")
printf '* %s %s %s %s\n' "$sevtxt" "$fromtxt" "$titletxt" "$agetxt"   # age now downstream of title
```

Demonstrated on this branch:

```
$ printf '|%-10.10s|END\n' "asciiTitle"   -> |asciiTitle|END
$ printf '|%-10.10s|END\n' "✉⚠✓emoji"     -> |✉⚠✓emoji  |END   # shifted — bytes != columns
```

So a title containing multibyte glyphs shifts the age column out of alignment — and this is **reachable in
normal use, not a crafted edge**: fleet's own ecosystem puts glyphs in messages (the inbox pill is `✉N`,
needs-human is `⚠`, workers routinely use `✓`/arrows in titles). The feature's stated value is
"alignment … both a correctness and a 'looks intentional' item" — ordinary unicode breaks exactly the
property the feature promises, on a surface this change *introduced* (the age column placement). Both
testers tested ASCII titles only (TEST-a "long titles", "embedded ESC"; neither tried UTF-8), so both
missed it. Not a safety issue, but a real "not as pretty as advertised" regression of the new layout.

---

## 4. NO_COLOR deviates from the standard SYNTHESIS named (minor, real)

SYNTHESIS Q4: "honor the **standard** NO_COLOR env var." The cited standard (no-color.org) is explicit:
honor it *"when present, regardless of its value."* The implementation uses presence-**and**-non-empty:

```sh
inbox_color_on() { [ -n "${NO_COLOR:-}" ] && return 1; … }
```

`NO_COLOR=` (set but empty) is therefore **ignored** and color stays on — contrary to the letter of the
standard the spec invoked. TEST-a note 4 flagged the same. The concrete MUST ("NO_COLOR beats
`FLEET_INBOX_COLOR=always`") is satisfied for the usual `NO_COLOR=1`, so this is minor — but it is a
named-standard deviation, and the correct form is one token: `[ -n "${NO_COLOR+x}" ]`.

---

## 5. Body-ANSI bleed: should the post-body `\033[0m` be REQUIRED for "pretty & safe"? (scope argument)

I will be honest about this one because it's the question the prompt asks directly:

- **Is it a regression of THIS change? No.** The body-print line `inbox_body "$f"; printf '\n'` is
  byte-identical to pre-feature code; the body was always printed verbatim with no reset. Both testers
  are right that it's pre-existing.
- **Does the new colored context make it materially worse? Actually slightly *better* intra-list on a
  tty.** The old plain headers emitted *no* resets, so an unterminated body escape ran straight through
  the entire next header. The new header-1 starts `\033[2m──\033[0m …` — its first `\033[0m` *clears* the
  leftover state after only the 2-char rule, so colored mode contains the bleed sooner than plain mode
  did. So I cannot honestly call the color "materially worse" here.

**But here is the real argument for in-scope:** must-fix #3 explicitly reasons about the body boundary —
"every styled printf resets … **before `inbox_body` runs** … body may hold its own escapes, state as an
invariant." The implementation did the *before*-body reset (header-2 ends in `$reset` before the body)
but **not** the *after*-body reset. That asymmetry is the tell: they cared enough to protect the body
from the header, but left the last message's body bleeding into the **shell prompt** (TEST-a note 2
verified a red-bg marker after the command exited). For a feature whose own charter (PLAN-PLAIN:
"pretty **AND safe**") is half about safety, a 1-byte color-gated `printf '\033[0m'` after `inbox_body`
is the natural *completion* of the fix they already started — not new scope. Both independent testers
surfaced this as "the one real-looking bleed" and both suggested exactly this hardening. I'd argue it
belongs in this iteration to make must-fix #3 whole, while conceding it is not a literal-spec MUST and the
piped/non-tty path is unaffected.

---

## Bottom line

No catastrophe; the safety story is solid and the code is honest work. But for a feature whose entire
value is *visual*: it pins titles to 47 chars on every wide terminal (point 1, common path, doesn't mirror
the dash), and the green proof that's supposed to certify it tests none of the visual MUSTs (point 2),
with a new unicode-misalignment surface (point 3) and two standard/spec deviations (points 4–5) on top.

**Strongest single point:** `${COLUMNS:-80}` is unset in the real invocation → titles never use the
terminal's real width and the "give title slack / match the dash" UX silently never happens. That, plus a
proof that wouldn't catch it, is a legitimate one-iteration NEEDS-WORK before `done`.

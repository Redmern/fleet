# Inbox styling — adviser debate, CON / SKEPTIC lens

Verdict: **direction is sound, but the plan ships two genuine landmines** (one in
the proof, one in the styling idiom) that will produce a *silently wrong* result —
literal `\033[2m` garbage on screen, or a proof that tests the wrong inbox / can't
run at all. Both are easy to miss because the plan's prose is right while its
*example code* is wrong. Fix list at the bottom.

What I verified by reading the code and running bash, not by trusting the plan:

---

## What actually holds up (credit where due)

- **Dynamic scope DOES survive the `|` pipe.** This was the prompt's headline
  worry. The consume construct `local FLEET_INBOX_COLOR=…; { inbox_list; …; } | $pager`
  works: the left side of a pipe is a subshell forked from `cmd_inbox`, and that
  fork inherits the function's `local` vars. Proven:
  ```
  g(){ local V=DYNSCOPE; { f; } | cat; }   # f reads $V  →  prints [DYNSCOPE]
  ```
  So `inbox_list`/`inbox_read`, even though piped, see the `FLEET_INBOX_COLOR` that
  `cmd_inbox` set. **No `export`, no subshell trick, no `sh -c` needed.** The plan's
  "or simply: local …" path (line 177) is correct.

- **Machine-consumer safety is real.** I traced every consumer. `inbox_list` /
  `inbox_read` output is read by **nobody** programmatically: the dashboard renders
  the inbox from the `.msg` files directly via its own `ibx_field`/`render_inbox`
  (`fleet-dash:870+`), never by parsing `fleet inbox list`. The case-dispatch
  (`bin/fleet:2060-2081`) routes `list`/`read` only to human display and the pager.
  Coloring at the display `printf` cannot reach `inbox_field`, `inbox_body`,
  `inbox_pop_text`, the reap-guard, `inbox_route`, or the on-disk header. The `--`
  gate sentinel and `key=value` parse are untouched. **This part of the plan is
  correct and I could not break it.**

- **Alignment is fine** with the three-arg form `printf '%s%-9s%s' "$col" "[$sev]" "$reset"`:
  `%-9s` pads only the `[$sev]` argument; `$col`/`$reset` are zero-display-width
  and counted by no width spec. Columns stay put. (See M2 for the one caveat.)

So the *architecture* survives the skeptic. The *defects are in execution*.

---

## DEFECT 1 (MUST-FIX, blocks correctness) — escapes stored in a variable and emitted via `%s` print LITERALLY

`bin/fleet` runs under **`set -u`** and printf only interprets backslash escapes in
its **format string**, never in `%s` arguments. The plan's §2 and §4 repeatedly
store escapes as literal single-quoted strings and then emit them as data:

- §2: ``c_dim='\033[2m'``, ``c_bold='\033[1m'`` — "locals".
- §4: "emit `printf '%s%-9s%s' "$col" "[$sev]" "$reset"` where `reset` is `\033[0m`".
- §4: ``sgr() { [ "$C" = 1 ] && printf '%s' "$1"; }``.

Every one of those prints the literal seven characters `\033[2m` to the user's
terminal. Proven:
```
lit='\033[31m'
printf '%s' "$lit"        # ->  \033[31m   (literal backslash-zero-three-three)
printf '%b' "$lit"        # ->  ^[[31m     (real ESC)
printf '%s' "$'\033[31m'" # ->  ^[[31m     (ANSI-C quoting materializes the byte)
cap=$(printf '\033[31m'); printf '%s' "$cap"  # -> ^[[31m  (cmd-subst captures the byte)
```
Why `sev_color` happens to be safe: the plan captures it as `col=$(sev_color "$sev")`,
and `sev_color` does the `printf '\033[…m'` itself — so the command substitution
captures a **real ESC byte**. The bug is only in the *other* escapes (`reset`, `dim`,
`bold`, the `sgr` helper) which the plan writes as literal strings.

**Must-fix:** materialize every color constant as an actual byte. Use ANSI-C
quoting (cleanest, no fork): `local reset=$'\033[0m' dim=$'\033[2m' bold=$'\033[1m' nbold=$'\033[22m'`.
Or `reset=$(printf '\033[0m')`. If `sgr()` is kept, it must use `printf '%b'` **or**
be passed already-materialized bytes — `printf '%s'` is wrong. This single mistake
would make the *entire feature* render as garbage while passing a careless eyeball
check on a non-color terminal.

## DEFECT 2 (MUST-FIX, blocks the proof) — the proof's root isolation is fictional

The PROOF DESIGN §8 rests on: *"a tmp root + `cd` is enough; `inbox_dir` resolves
from cwd/git-top."* **It does not.** Trace:

```
inbox_dir()  -> fleet_root()
fleet_root() { local s; s=$(session_name) || return 1        # bin/fleet:94-100
               r=$(tmux show -t "$s" -v @fleet_root); [ -n "$r" ] && echo "$r"...
               [ -n "$FLEET_ROOT" ] && echo "$FLEET_ROOT"...
               pwd }
session_name(){ [ -n "$FLEET_SESSION" ] && echo... ; tmux display -p '#{session_name}'; }  # :89
```

Two failure modes, both fatal to the proof as written:

1. **Run outside tmux, no `FLEET_SESSION`** (a plain `sh proof.sh`): `session_name`
   fails → `fleet_root` hits `|| return 1` and **returns 1 before ever reaching the
   `pwd` fallback**. `inbox_dir` fails, `inbox put` prints "could not write entry".
   The `cd "$ROOT"` is irrelevant — `pwd` is unreachable. **Proof can't even seed.**

2. **Run inside the worker's real tmux session** (the likely case — the test agent
   *is* in a pane): `session_name` resolves to the live session, `@fleet_root`
   resolves to the **real project root**, and `cd "$ROOT"` is ignored entirely.
   Then `inbox put`/`inbox` (consume) operate on the **real fleet inbox** — the
   proof seeds three messages into it and step (c) *archives every live message in
   the real inbox*, including genuine worker needs-human posts. **The proof is
   destructive against production state and asserts nothing about the tmp root.**

The plan's §8 note ("If `inbox_dir` resolves via tmux session… wrap in a throwaway
session… confirm at implementation time") *acknowledges the uncertainty* but ships
the wrong script as the load-bearing one. That's not good enough.

**Must-fix:** the proof must force the root explicitly and not rely on `cd`:
`export FLEET_ROOT="$ROOT" FLEET_SESSION=prooftest` before any `fleet` call (both
exported, see Defect 4). With `FLEET_SESSION` set, `session_name` succeeds without
tmux; with `FLEET_ROOT` set, `fleet_root` returns `$ROOT` ahead of `pwd`. Drop the
"cd is enough" claim from the doc.

## DEFECT 3 (MUST-FIX) — `set -u` turns a forgotten color var into a hard crash, violating fail-silent

`bin/fleet:8` is `set -u`. CLAUDE.md's prime directive is fail-silent: a styling
helper must **never** take a command down. But under `set -u`, if the `C=0`
(no-color) branch forgets to initialize *any* escape var that a later `printf '%s'
"$reset"` references, fleet aborts with "unbound variable" — `fleet inbox list`
dies. The plan's pattern only guarantees `col` is set in both branches
(`… && col=$(…) || col=""`); `reset`/`dim`/`bold`/`mark`/`from_col` are not shown
being initialized on the no-color path.

**Must-fix:** initialize **every** color/reset variable to `""` unconditionally at
the top of `inbox_list`/`inbox_read` (before the `C` test), then overwrite when
`C=1`. And note: `fleet doctor` (proof step d) does **not** call `inbox_list`, so a
`set -u` crash in the color path would sail past "doctor green" — step (d) proves
nothing here (see Defect 6).

## DEFECT 4 (MUST-FIX, proof) — `script -qec` won't inherit shell-local proof vars

Proof steps (a)/(c3) drive a pty via `script -qec "$FLEET inbox list" /dev/null`.
`script` runs the command in a fresh `$SHELL -c`. It inherits **exported** env only.
If `FLEET_ROOT`/`FLEET_SESSION` are set as plain shell vars (as `ROOT=$(mktemp -d)`
is), the pty subshell won't see them → `fleet_root` falls back to whatever the real
environment gives it (the wrong root, or rc 1). Compounds Defect 2.

**Must-fix:** `export` `FLEET_ROOT` and `FLEET_SESSION` (and any seed env) so the
`script`-spawned shell inherits them.

## DEFECT 5 (SHOULD-FIX) — body color-bleed: a dangling open SGR leaks into arbitrary worker text and the terminal

`inbox_read` prints styled header lines and then `inbox_body "$f"; printf '\n'`
**verbatim**. ANSI is stateful: if the last header `printf` opens a color/bold
(e.g. bold `from`) and the reset is missing or misordered, the open SGR bleeds into
the body — which is *arbitrary worker text that may itself contain escapes/code
fences* — and then into everything the pager prints afterward, and on `cat`/no-`less`
into the user's live shell prompt. The plan says "body untouched" but doesn't state
the **invariant that makes that safe**: every styled line must close its SGR (reset)
*before* `inbox_body` runs, and no header `printf` may end with an unreset escape.

**Must-fix wording:** add an explicit invariant — "no `printf` in `inbox_read`/`inbox_list`
may terminate with an open SGR; reset immediately after each styled token, and in
particular before `inbox_body`." Cheap, but it's the difference between correct and
a corrupted scrollback.

## DEFECT 6 (MINOR, proof) — two proof assertions don't test what they claim

- **(d) `fleet doctor`** never invokes the inbox display functions, so it cannot
  catch a `set -u` crash, an escape-materialization bug, or a width regression. It's
  a top-level-syntax canary at best. The load-bearing assertions are (a)/(a2)/(b)/(b2)/(b3);
  say so and don't lean on (d).
- **(e) field-parse**, line 355 `val=$("$FLEET" inbox ...)` is a placeholder: there
  is **no `fleet inbox field` subcommand** (`inbox_field` is internal, absent from
  the case dispatch at `:2060-2081`). The assertion is unrunnable as written. To
  test it you must `source bin/fleet` and call `inbox_field` directly, or grep the
  `.msg` for `^sev=warn$`. The `.msg`-stays-plain check (the `grep -q "$ESC\["` on
  the file) is the real one and is fine; the field-value half needs a runnable form.

---

## Open-question rulings (CON stance — minimize surface, kill drift)

- **Q1 (dim `from` in list):** leave `from` **default**, do not dim. `from` is the
  scannable join key (it's how the dash attaches messages to agent rows). Dimming
  the one column the eye hunts for is a net loss. Color only `[sev]`. Less code,
  less to get wrong.
- **Q2 (tint `*`):** keep `*` plain. Tinting it duplicates the `[sev]` signal and
  adds another escape var to forget-and-crash under `set -u`. No.
- **Q3 (style put feedback :1703):** **no.** It prints once at enqueue, often into a
  worker's scrollback, and the send-redirect notices next to it stay plain. Styling
  one operational echo and not the others is the inconsistency the plan worries
  about. Out of scope.
- **Q4 (NO_COLOR):** **yes, honor it, and NO_COLOR wins over `FLEET_INBOX_COLOR=always`.**
  It's one `[ -n "${NO_COLOR:-}" ] && return 1` line, `set -u`-safe, and it's the
  conservative default. Confirmed consistent: consume path picks `less -R` but emits
  no ANSI when NO_COLOR is set — harmless.
- **Q5 (document `FLEET_INBOX_COLOR`):** keep it an **internal** knob for now (the
  consume path's override). Documenting it invites users to set `=always` and then
  be surprised when piping into a non-`-R` `less` shows raw `^[[`. Less promised
  surface = less to support.
- **Q6 (truecolor/Omarchy theme):** **no.** Fixed basic SGR (31/33/2/1), byte-for-byte
  with `fleet-dash:397`. Theming is scope creep against a feature whose whole point
  is "reuse the palette already there, invent nothing."

---

## MUST-FIX checklist (gate before implementation is accepted)

1. **Escape materialization:** all color constants (`reset`, `dim`, `bold`,
   `nbold`, any `sgr` helper) emitted via `%s` must hold **real ESC bytes** —
   `$'\033[…m'` or `$(printf …)`, never literal `'\033…'`. `sev_color` via `$()` is
   the only one currently safe. *(Defect 1)*
2. **`set -u` safety:** initialize **every** color var to `""` unconditionally
   before the `C` test, in both branches. A styling helper must not crash the
   command. *(Defect 3)*
3. **No dangling SGR:** every styled `printf` closes its SGR before the next token
   and before `inbox_body`; body printed verbatim. *(Defect 5)*
4. **Consume override is mandatory, not optional:** `cmd_inbox` must set
   `local FLEET_INBOX_COLOR=always|never` matched to the `less -R`/`cat` choice
   (`always` only when `[ -t 1 ] && less` picked). Use the plain-`local` form, **not**
   the `sh -c '...'` form shown on line 177 — `sh -c` is a fresh process with none
   of fleet's functions and would silently no-op the color. *(verified mechanism;
   strike the misleading line 177 variant from the plan)*
5. **Proof root isolation:** `export FLEET_ROOT="$ROOT" FLEET_SESSION=prooftest`;
   delete the "cd is enough / resolves from cwd" claim. Without this the proof
   either can't seed (no tmux) or mutates the **real** inbox (in tmux). *(Defect 2 + 4)*
6. **Fix the two dud assertions:** drop reliance on `fleet doctor` (d) as a color
   canary; make (e)'s field check runnable (`source` + `inbox_field`, or grep the
   `.msg`). *(Defect 6)*

If 1–5 land, the design is correct and safe; 1, 2, and 5 are the ones that will
*silently* ship broken if skipped.

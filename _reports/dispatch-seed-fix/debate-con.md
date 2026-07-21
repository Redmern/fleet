# Debate — CON (skeptic)

Verdict up front: **REVISE.** The diagnosis is solid and the pointer is the right
shape, but the plan as written **ships a regression**: it silently flips the seed
from *guaranteed-present* to *fetch-on-faith*, and the manual it points at is
written for the OLD world. Fix three things first, then ship.

---

## 1. The load-bearing risk: "does the seed still arrive?" — NO, not as written

The inline version put the manual *in the model's context window* unconditionally.
The pointer version puts a *200-byte instruction to go read a file*. Those are not
equivalent, and the plan treats them as if they were ("keep the seed content
actually reaching the sub-orch", PLAN.md:88). The new failure surface:

### 1a. The manual contradicts the pointer model — DECISIVE
`FLEET_SUBORCH.md:18` says, verbatim:

> That file — **NOT your seed prompt**, NOT chat history — is the authoritative
> instruction.

and `FLEET_SUBORCH.md:9`:

> Your seed prompt ends with a line `DISPATCH ID: <id>`.

The manual is written assuming **it itself WAS the seed** and the only thing to
fetch is `instruction.txt`. Under the pointer fix the seed is now "go read this
manual," so the very first instruction the agent has *is* a pointer it must
already have followed to learn it should follow it. If claude does NOT read the
manual first, it has *nothing* — not even the "read instruction.txt" guidance,
which now lives only inside the unread file. The inline version was robust to a
lazy agent precisely because the rules were already in-context. **The plan does
not update FLEET_SUBORCH.md, and it must:** the manual has to be rewritten to
open with "you were spawned with a pointer; your real manual is this file you are
now reading; now read instruction.txt." Without that edit the fix is internally
incoherent. (PLAN.md §2 "Edge cases" never mentions the manual's own wording.)

### 1b. The relative-path `cat` is a latent bug the pointer EXPOSES
The manual instructs `cat .fleet/dispatch/<id>/instruction.txt`
(`FLEET_SUBORCH.md:15`, and 6 more relative `.fleet/dispatch/...` paths at lines
25, 26, 34-35, 174, 180, 233, 258, 307). That only works if the agent's cwd is
`$root`. It *is* today (`cmd_new` scratch path sets `dir="$root"`, `bin/fleet:779`,
and spawns with `-c "$dir"`, `bin/fleet:917-925`) — but this was incidental
insurance when the manual was inlined. Now it is load-bearing on TWO cwd
assumptions stacked: claude must read `$FLEET_DIR/FLEET_SUBORCH.md` (absolute,
fine) AND then obey relative `cat .fleet/...` from whatever cwd it has drifted to
after reading. The plan's own pointer draft (PLAN.md:135) hands the agent an
**absolute** `$root/.fleet/dispatch/$id/instruction.txt` — good — but the manual it
points at then tells it to use **relative** paths for meta.tsv, workers.tsv,
role-phase writes, etc. Mixed absolute/relative guidance is exactly how a respawn
after a `cd` writes `meta.tsv` into the wrong place. If we touch this path, the
manual's paths should be made cwd-independent too.

### 1c. Permission mode can swallow the very first read
Sub-orchs spawn with `H_START_MODE="auto"` (`harness.d/claude.conf:12`), passed as
`--permission-mode` (`bin/fleet:884`). The whole fix now depends on the agent's
**first tool call** being a successful `Read`/`cat` of the manual. In `default`
mode a Read prompts for permission; an unattended hidden-session pane with nobody
to approve it stalls before it has ingested a single rule. The inline version had
zero tool calls on the critical path. The plan asserts "mitigate with an
unambiguous imperative prompt" (PLAN.md:108) — that is hope, not a mechanism. At
minimum the acceptance test (PROOF-DESIGN step 3) must assert the read actually
*succeeded*, not just that the agent "is acting on the manual."

---

## 2. FLEET_DIR scope — the plan's claim CHECKS OUT (steelman for the PRO side)

I tried to break this and could not. `FLEET_DIR` is set unconditionally at
`bin/fleet:10` at the top of the script, in global scope, before any subcommand
dispatch. Both spawn entry paths run **in-process** in that same `bin/fleet`:

- hook → `fleet dispatch <id>` → `cmd_dispatch` → `resolve_or_spawn_suborch`
  (`bin/fleet:1447`), and
- hook/timer → `fleet reconcile` → `cmd_reconcile` → `resolve_or_spawn_suborch`
  (`bin/fleet-dispatch.sh:79`, `bin/fleet:1632`).

Neither crosses a process boundary that would drop the var, and it does not need
`export` because `suborch_seed`/`resolve_or_spawn_suborch` are shell functions in
the same process, not child execs. So `$FLEET_DIR/FLEET_SUBORCH.md` in the pointer
is reliably resolvable at spawn time. **This part of the plan is correct.**
(`suborch_seed` already uses exactly this at `bin/fleet:1318`.)

One narrow caveat: the *resolution of the path string* is reliable, but the path
is only **embedded as text** into the pointer; whether the file is **readable by
the spawned agent** is a separate question (see §3 packaging).

---

## 3. Packaging / missing-manual failure modes

- **Relocation /usr/lib/fleet vs repo:** `$FLEET_DIR` correctly tracks the install
  root via `readlink -f` (`bin/fleet:10`, comment at 3957-3963 confirms the
  /usr/bin→/usr/lib intent). The pointer embeds the *current* install's absolute
  path. Risk: the pointer text is computed at **spawn time** and the agent reads
  the file **moments later** — a package upgrade mid-dispatch could move the file.
  Marginal, but it did not exist with the inline seed (frozen at dispatch).
- **Missing/old manual:** PLAN.md:148-151 claims "strictly better than today — the
  sub-orch reports a read failure instead of silently dying." That is optimistic.
  If the manual is missing, the agent has the 200-byte pointer and `instruction.txt`
  and **no operating rules at all** — it may freelance an interpretation of the
  instruction (spawn workers wrong, skip the role-phase ledger writes, never call
  `dispatch rename`) rather than cleanly erroring. A confidently-wrong sub-orch is
  arguably *worse* than a visible no-pane. The plan's "optional fallback to fleet
  help" (PLAN.md:151) should be non-optional, or the pointer should itself carry
  the 3-4 absolute survival rules so a missing manual still fails safe.
- **Old manual (version skew):** inline froze nothing useful, but it did guarantee
  the agent and the running `bin/fleet` were the *same vintage*. Pointer reads
  whatever is on disk now — fine when they match, a latent skew bug across a
  partial upgrade. Low probability; note it.

---

## 4. The empty-`win_id` "claim success" bug needs its OWN fix REGARDLESS

`bin/fleet:986` prints `spawned $wname ($H_NAME) in window $win_id` with **no check
that `$win_id` is non-empty**, after the scratch path swallows tmux stderr with
`2>/dev/null` (`bin/fleet:917-925`). This is the *actual* reason the original bug
was silent and churned. The size fix removes *today's* trigger (the 20 KB arg) but
leaves the **silent-success primitive fully armed** for any future over-cap,
tmux-down, or session-race failure. The plan correctly identifies this
(PLAN.md:153-157) but files it as "Hardening (recommended, secondary)" and
"optional." **CON position: this is not secondary.** It is cheap, it is the
defense that would have surfaced the original bug in seconds, and shipping the seed
fix *without* it means the next person to push the scratch prompt over 16 KB gets
the identical silent-no-pane / reconcile-churn experience this whole report is
about. Make line 986 return non-zero + emit a real error on empty `win_id` in the
**same** change. (It also closes the reconcile respawn-loop: `suborch_live`
false-dead → re-spawn at `bin/fleet:1631-1632` will at least be visible.)

---

## 5. Backward-compat — mostly fine, one note

- Only `resolve_or_spawn_suborch` changes; other `--scratch -p` callers untouched
  (`cmd_new` is not modified). Agreed, low blast radius (PLAN.md:144-147).
- `suborch_seed()` (`bin/fleet:1318`) becomes dead or gets repurposed — pure
  cleanup, fine.
- **But** the §4 line-986 hardening, if done, *does* touch every `cmd_new` caller
  (return value + stderr). That is the right change but it is a behavior change to
  a shared function; verify no caller treats a non-zero `cmd_new` as fatal in a way
  that breaks the fail-silent house style (CLAUDE.md "guard external calls /
  exit 0"). `resolve_or_spawn_suborch` reads `$widf` and only `meta_set`s on
  non-empty (`bin/fleet:1377-1378`), so it tolerates a failure return — good — but
  audit the other call sites before flipping the return contract.

---

## Steelman: the single strongest reason NOT to ship as-is

**The fix changes the seed-delivery contract from "guaranteed in context" to
"fetched by a tool call that can be skipped, denied, or mis-pathed — pointing at a
manual that still tells the agent its seed *was* the manual."** The mechanism
diagnosis is right and the pointer is the right direction, but shipping the
one-line `resolve_or_spawn_suborch` change **alone**, without (a) rewriting
FLEET_SUBORCH.md for the pointer world + making its internal paths cwd-safe,
(b) the line-986 empty-`win_id` failure-report, and (c) an acceptance check that
the manual read actually *succeeded* under the auto/default permission mode —
trades a loud-once, reproducible bug for a quieter, intermittent "sub-orch is up
but under-briefed" failure that is far harder to diagnose.

---

### Verdict
**REVISE** — biggest risk: the pointer makes seed delivery depend on the agent's
first tool call succeeding, while FLEET_SUBORCH.md (`:9`, `:18`) is still written
as if it WERE the seed, so a sub-orch that doesn't read it has *no* rules at all.

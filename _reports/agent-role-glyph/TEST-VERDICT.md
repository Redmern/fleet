NEEDS-WORK

# TEST-VERDICT — adversarial review of `fleet new --task` (d26, commit ff9da68)

Role: adversary. My job was to break the DONE verdict, not to balance it. I broke it
on two independent grounds, either of which is sufficient on its own.

Inputs read: `_reports/agent-role-glyph/TEST-a.md` (560 lines), `_reports/agent-role-glyph/TEST-b.md`
(855 lines, **present** — the "missing second tester" caveat in my brief no longer
applies), `git show ff9da68`, `test/agent-task-proof.sh`, `bin/fleet`, `bin/fleet-dash`,
`CLAUDE.md`. Every finding below was re-derived first-hand; nothing is taken on trust
from A or B.

**Safety**: every dynamic test ran through a `tmux()` wrapper defined in the same file
as its calls, with an explicit `-S "$SOCK"` under my own `mktemp -d` root and a
fail-fast refusal on `/tmp/tmux-*/default`. The live `pc` server was never addressed.
No `fleet reap`/`ready`/`kill` outside the sandbox. No code was changed, committed,
pushed, or merged; one scratch file (`test/_adv_proof2.sh`) was created and deleted.

---

## BLOCKER 1 — the dashboard squeezes the label to make room for the tag

`CLAUDE.md` states the task field is *"shed **first** in the width ladder **so the
label is never squeezed***". `bin/fleet-dash:1045-1046` states the same intent in its
own words:

```
      # DROP THE TASK FIELD FIRST — before cost/mode/✉. The badge is a convenience;
      # the label is the identity, and it must never be squeezed by the badge.
      (( LW < 1 )) && (( task_show )) && { task_show=0; TFW=0; LW=$(( cw - np*PW - CF - (np+1)*G )); }
```

The shed fires only at `LW < 1` — when the label would be **literally zero-width**.
But the label is rendered by `fit_left "$label" "$LW"` (`bin/fleet-dash:1067`), which
elides with `…` as soon as `LW < len(label)`. Between "label starts eliding" and
"LW < 1" there is a wide band in which the tag holds 5 columns that the label needs.

Reproduced first-hand, real `fleet-dash` in a real tmux pane, `capture-pane -p`, one
tagged + one untagged agent, sandboxed server:

```
===== WIDTH 120 =====
│▌   idle             ctr/worker-none                                         ✓        default    -             │
│    idle      rsch   ctr/worker-tagged                                       ✓        default    -             │
===== WIDTH 100 =====
│▌   idle             ctr/worker-none                     ✓        default    -             │
│    idle      rsch   ctr/worker-tagged                   ✓        default    -             │
===== WIDTH 90 =====
│▌   idle             ctr/worker-none           ✓        default    -             │
│    idle      rsch   ctr/worker-tagged         ✓        default    -             │
===== WIDTH 85 =====
│▌   idle             …r/worker-none       ✓        default    -             │
│    idle      rsch   …worker-tagged       ✓        default    -             │
```

At width 85 **both** labels are truncated (`…r/worker-none`, `…worker-tagged`) while
`rsch` and its gap still occupy 5 columns, and `✓ / default / -` are all still present.
The identity is squeezed by the badge, exactly as the code forbids. Note the untagged
row is truncated too — the cost is paid by *every* row in the fleet, not just tagged ones.

Widths 80 and 75 produced empty captures (the dash had not painted within the sleep
window) — **UNTESTED**, same flakiness Tester B reported. Width 85 is sufficient; the
`LW < 1` gate makes the behaviour structurally certain regardless.

This is a straight violation of a written spec point in `CLAUDE.md`, in the surface the
feature exists for. Tester B reached the same conclusion independently at width 80.
I rule it **merge-blocking**.

## BLOCKER 2 — the status-bar surface has no working test, and the proof harness's headline result is not reproducible

`test/agent-task-proof.sh` case 16b is the *only* test that asserts the tmux status bar
actually shows the tag. It drives the function like this (`test/agent-task-proof.sh:362`):

```sh
( . "$FLEET" >/dev/null 2>&1; inject_status_format ) >/dev/null 2>&1
```

`bin/fleet`'s bottom dispatch ends in `*) print_usage ;;` (`bin/fleet`, last 25 lines).
Sourced with no positional args, that branch runs and **exits the subshell before
`inject_status_format` is ever called**. Proved directly, stderr unsuppressed:

```
before: [#I:#W]
--- sourcing, stderr VISIBLE ---
fleet — agent fleet manager (tmux + nvim + Claude Code)
  fleet                  (bare, interactive) fzf picker of saved projects -> fleet up
  ... (full usage text) ...
after:  [#I:#W]
```

Neither `echo "sourced ok"` nor `echo "called ok"` — which I placed on the same line
after the source — ever printed. The global format is unchanged. This is structural and
deterministic, not flaky.

Consequently, on a clean run the harness reports:

```
  FAIL(16b): inject_status_format did not append a task token: #I:#W
```

That is the **only** failure once the harness's own tmux problem (BLOCKER 3) is fixed —
all 24 other cases pass. But it falsifies both prior claims of record: the implementer's
"25/25 / 38 assertions" in the commit message, and Tester A's *"Implementer's harness
rerun: 36/36 ALL PASS, reproduced independently"*. Neither is reproducible.

The knock-on is worse than one red case. **Case 16 — the `#[`-injection guard — passes
vacuously as a direct consequence.** It counts `#[` in `#{E:window-status-format}`
against a task-less baseline; since the task token was never injected into the format,
no window can possibly exceed baseline, so case 16 cannot fail on the injection surface
no matter what is stored. Ruling on deviation 5 below.

Important distinction, stated plainly so this is not overread: **the feature itself is
fine.** `inject_status_format` (`bin/fleet:4106`) is correct, and Tester A rendered the
expanded format successfully by other means (`#I:#W#{?@agent_glyph, #{@agent_glyph},}#{?@fleet_task_tag, #{@fleet_task_tag},}`).
What is broken is the *evidence*. One of the three advertised rendering surfaces has
zero functional coverage in the harness that is cited as the proof of this feature, and
the safety case for the closed enum rests on a test that currently cannot fail. That is
"a test that passes trivially and proves nothing", which is disqualifying on its own.

## BLOCKER 3 — the proof harness cannot run on a clean machine

The harness resolves `SOCK="$TMPROOT/tmuxsock/tmux-$(id -u)/default"` and then only
`mkdir -p "$TMUX_TMPDIR"` (= `$TMPROOT/tmuxsock`). The `tmux-$(id -u)` component is
never created, and tmux does not create parent directories for `-S`:

```
$ command tmux -S "$T/s/tmux-1000/default" new-session -d -s probe -n base sh
error creating /tmp/advS.BsOYZH/s/tmux-1000/default (No such file or directory)
```

If the dir is created with a default umask, tmux refuses it for a second reason:

```
directory /tmp/advX.FTawYd/tmuxsock/tmux-1000 has unsafe permissions
```

It needs `mkdir -p` **plus** `chmod 700`. Unpatched, my first run produced a cascade —
`FAIL(1) no .agents file written by cmd_new`, `FAIL(2a)`, `FAIL(2b)`, `FAIL(5a/5b/6)`,
`FAIL(9)`, `FAIL(11)`, `FAIL(21)` — because every spawn died at
`fleet new: spawn FAILED … tmux returned no window id`. With a two-token patch
(`mkdir -p "$(dirname "$SOCK")" && chmod 700 …`) and nothing else changed, 24/25 passed
and only 16b remained red.

Two consequences. First, the harness **fails silently-wrong** rather than hard — it
reports feature failures for an environment fault, in a repo whose house rule is
explicitly about not failing silently wrong. Second, it means a green run is a function
of ambient machine state, so "the harness passes" is not currently a statement about
this feature.

## Case 21 — my ruling

**A fragile order-dependent test sitting on a real (but low-severity) design coupling.**
Both, not either.

The test is self-sabotaging (`test/agent-task-proof.sh:436-438`):

```sh
tf="$(task_file 'repo/feat_one')"
[ -e "$tf" ] || printf 'impl\n' > "$tf"
"$FLEET" forget "$FLEET_ROOT/repo/feat_one" >/dev/null 2>&1
[ -e "$tf" ] && fail 21 "fleet forget left $tf behind" || pass 21
```

It manufactures the sidecar out of band but never ensures the `.agents` **line** exists —
and that line is the only thing `cmd_forget` can derive the window name from
(`bin/fleet:615`): `_wn=$(awk -F'\t' -v d="$dir" '$1==d{print $8; exit}' "$f")`. Once
spawns worked in my patched run, case 21 passed. So the observed `FAIL(21)` was an
artifact of BLOCKER 3, not of the slash in the name. **Tester B is right that the
slash-bearing name is a red herring**, and right for reasons I confirmed independently.

On B's dead-guard claim — **B is correct, verified in source.** `cmd_forget` returns
early at `sess=$(session_name) || return 0` (`bin/fleet:606`), so by the time it reaches
`_root=$(fleet_root 2>/dev/null) || _root=""` (line 614), `session_name` has already
succeeded; `fleet_root`'s only empty-return path is `session_name` failing (line 95), and
otherwise it always echoes something — `@fleet_root`, else `$FLEET_ROOT`, else `pwd`
(lines 96-99). `[ -n "$_root" ]` is therefore unreachable-false: **dead code**. When
`@fleet_root` and `FLEET_ROOT` are both unset, `_root` degrades to `pwd`, `forget_task`
deletes a path that does not exist, and the `.agents` line is removed anyway — so no
later call can ever reclaim the real sidecar.

But I rule B's **"permanent vs self-healing" framing an overstatement**. Tester A
demonstrated, and the source confirms (`bin/fleet:1264`, `cmd_new` calls `forget_task`
when the task is empty), that **spawn is authoritative in both directions**: a leaked
sidecar is cleared the moment its window name is reused untagged. The file is permanent;
the *harm* is not. Residual harm is (a) unbounded accumulation of tiny files under
`.fleet/tasks/`, and (b) one narrow mis-display path — `cmd_restore` reads the sidecar
(`bin/fleet:796`) and would re-tag a restored agent from a stale leaked file. Display-only,
low severity. **Not blocking on its own**, but it is dead code in `cmd_reap`/`cmd_forget`,
the repo's most safety-critical path, and it should not ship as-is.

## Ruling on the five self-disclosed deviations

**1. `--scratch` no longer defaults to `task=scratch`.** *Reasoning correct, accept.*
Every sub-orch spawns via `--scratch`, so defaulting would flip `HAS_TASKS` on for
essentially every fleet and cost every row label ~5-7 columns for zero information.
Verified against the ladder source and A's §7 (`bare --scratch → task=[] sidecar_exists=no`;
`--scratch --task scratch` works when asked). Nothing was lost — the capability is
reachable explicitly. **Ironically this deviation's own stated justification is what
convicts `generic`** (see below): the implementer refused to impose the 7-column cost
here, then left it reachable by typing a documented flag value.

**2. The new `@fleet_task_tag` option.** *Necessary, and derived at the same validated
site — accept, with a caveat.* Traced every writer: `bin/fleet:1266` and `:1272` are
adjacent lines inside the single validated `case` block (`:1029-1034`), with `:1262-1263`
unsetting both together when the task is empty. `@fleet_task_tag` is fed
`task_tag_trim "$task"`, whose output is a closed set of five ASCII literals by
construction (`bin/fleet:1698-1715`) — so it is strictly *more* constrained than
`@fleet_task`, not less. The claim holds. Caveat, matching A's B4: `@fleet_task_tag` is
format-expanded but never re-validated on read, unlike `@fleet_task` (`task_of`). No
fleet path can poison it, so this is outside the threat model — but the commit message's
"re-validated on read" defence does not literally cover the option the bar actually
expands. Note, not a blocker.

**3. Trimmed on tab-separated surfaces, padded in the dash.** *Reject — this is a
regression.* The split is defensible in principle but the trimmed side is wrong, and it
breaks the exact invocation `CLAUDE.md` cites as its own justification
(*"a padded field makes `fleet ls | column -t` mis-align that row"*). It fixed the tagged
row and broke the untagged one. Reproduced deterministically:

```
=== fleet ls | column -t  (documented pipe) ===
STATE  TASK             AGENT                 WINDOW                  IN-STATE
idle   ctr/worker-none  advl:ctr/worker-none  2m01s
idle   rsch             ctr/worker-tagged     advl:ctr/worker-tagged  2m01s

=== column -t -s TAB (works) ===
STATE  TASK  AGENT              WINDOW                  IN-STATE
idle         ctr/worker-none    advl:ctr/worker-none    2m01s
idle   rsch  ctr/worker-tagged  advl:ctr/worker-tagged  2m01s
```

Bare `column -t` splits on whitespace runs, so the empty TASK field collapses and every
later value shifts one column left — the agent name lands under `TASK`. On a fleet that
has never used `--task`, *every* row is misaligned against the header. A and B found
this independently; that convergence plus my own reproduction makes it solid.

Is it merge-blocking? On its own I would call it borderline-cosmetic — but three things
push it over: it is a **regression** (`ff9da68^` aligns correctly), it hits **100% of
users on upgrade including those who never touch the flag**, and it contradicts a
written rationale in `CLAUDE.md`, so shipping it also makes the docs wrong. It is a
one-character fix (`-` placeholder). **Blocking.**

**4. Case 19 is structural, not functional.** *Reject — and it hides BLOCKER 1.* The
grep of source line order proves the ladder's *ordering* and can never prove the
*trigger threshold*, which is where the bug is. I verified the real behaviour by
`capture-pane` as instructed: the ordering claim does hold (at ≤65 the tag is gone while
`✓`/`default` remain — consistent with A), but the "label is never squeezed" guarantee
fails from ~85 down. A re-derived this dynamically and read it as PASS because A only
sampled 100/60/46/34 and stepped straight over the failing band; B sampled 90/80 and
caught it. I confirm B. This is precisely the "test that passes trivially" category.

**5. The two mid-flight corrections.** *One legitimate, one softened a test into passing.*
Case 16c (idempotency re-proved by re-run + diff) is **legitimate** — it is a strictly
stronger assertion than what it replaced, and it passes honestly. Case 16 (counting `#[`
against a task-less baseline rather than absolutely) is **defensible in intent** — the
real tmux theme genuinely emits its own `#[`, as B's captures show
(`#[fg=#6d7db6] #I:#W`), so an absolute count would be a false positive. But in practice
it **softened the test into one that currently cannot fail**, because its companion 16b
never injects the token, so no window can exceed baseline regardless of what is stored.
The correction was reasonable; its interaction with the broken 16b was not caught, and
the net effect is that the headline safety claim of this feature is unproven.

## `generic` — verified, and it convicts itself

`generic` is accepted by the enum (`bin/fleet:1034`), stored in `@fleet_task` and the
sidecar, and mapped by `task_tag` to four blanks (`bin/fleet:1703`, the `*)` arm). The
dash computes `HAS_TASKS` from `@fleet_task`, not from the rendered tag
(`bin/fleet-dash:459`), so **one** `generic` agent turns the column on for the whole
fleet and every row pays 5 columns to render nothing. A measured 5 columns, B measured 7;
both are right for their own pill configuration, and the direction is what matters.
It is equally invisible in `fleet ls` and the status bar — `generic` and *untagged* are
indistinguishable on all three surfaces.

A and B converged on this independently. I weigh it as **medium, not blocking on its
own** — but it is a member of a *closed, deliberately-designed* enum that no surface can
render, and the harm it causes is the exact harm the implementer cited to justify
deviation 1. That is an internal inconsistency in the design, not just a rough edge.

## Confidence, and what could not be checked

- **Second independent confirmation: present.** TEST-b.md exists; A and B converge
  independently on the two display defects and B independently found BLOCKER 1. That
  convergence is the strongest part of the evidence base.
- **Tester B's credibility cost.** B disclosed that its own harness had an ambient
  socket-isolation gap that took down the live fleet tmux server mid-run. That is a
  serious process failure and it is why I re-derived every load-bearing B claim myself
  rather than citing B: BLOCKER 1 (my own `capture-pane` at 85), the `column -t`
  regression (my own reproduction), and the `cmd_forget` dead guard (my own source
  trace). All three stand on my evidence, not B's. I did not rely on any B result I
  could not re-derive. A's isolation was clean and A also disclosed a scratchpad
  collision with B — worth noting that the *harness discipline*, not the analysis, is
  what failed in both testers' setups, which is consistent with BLOCKER 3.
- **No approved spec exists.** `PLAN.md`, `SYNTHESIS.md` and `PLAN-PLAIN.md` are absent
  from this worktree — A and B both confirm, and so do I. Spec conformance is therefore
  checkable **only** against the commit message and `CLAUDE.md`. I cannot verify whether
  the five disclosed deviations are the complete set, whether any PLAN step was silently
  dropped beyond `--scratch`, or whether the enum membership (`generic` included) was an
  approved decision or an implementer choice. Every "unmet spec point" ruling above is
  against `CLAUDE.md` prose only.
- **UNTESTED by me**: dash render at widths 80/75 (empty captures); `fleetd`'s
  `heal_status_format` (Python twin of `inject_status_format` — A also only inspected it,
  and note it would be exercised by the same broken 16b path); `fleet reap` end-to-end
  outside the harness; sub-orch/dispatch-layer spawns carrying `--task`; real terminal
  appearance of the status bar with an attached client.

---

## What would have to change to earn DONE

1. **Shed the task field before the label elides, not at `LW < 1`.** Gate it on the label
   being truncated (e.g. `LW < ${#label}`, or a floor), so `CLAUDE.md`'s "never squeezed"
   is true. Add a real assertion — render at a width where the label truncates and assert
   the tag is absent. Case 19's source-grep must not be the only coverage.
2. **Fix case 16b so it actually calls `inject_status_format`** (call it via a real
   entry point, or guard `bin/fleet`'s dispatch with `[ "${BASH_SOURCE[0]}" = "$0" ]` so
   sourcing is safe), then re-run and re-baseline case 16 — the `#[`-injection guard must
   be demonstrated capable of failing (a positive control, as B did for the `done` pill).
3. **Make `fleet ls` survive bare `column -t`.** Emit a `-` placeholder in the TASK field,
   or drop the documented bare-`column -t` claim from `CLAUDE.md` and specify
   `column -t -s $'\t'`. Pick one; today the code and the doc disagree.
4. **Resolve `generic`.** Render it (`gen `), exclude it from `HAS_TASKS`, or remove it
   from the enum. An enum member no surface can show is a bug in one of those three places.
5. **Fix the harness's socket setup** — `mkdir -p "$(dirname "$SOCK")" && chmod 700` — and
   make a tmux-server-start failure a hard abort with a clear message rather than a
   cascade of feature failures.
6. **Make case 21 self-contained** (assert/create the `.agents` line, not just the
   sidecar) and **remove the dead `[ -n "$_root" ]` guard** in `cmd_forget`, replacing it
   with something that actually distinguishes a resolved root from a `pwd` fallback.
7. Re-run both testers' suites and reconcile against the commit message's claimed count.

Items 1-3 are blocking. Items 4-7 are required for the DONE claim to rest on evidence
rather than on a harness whose headline number does not reproduce.

**Verdict: NEEDS-WORK.**

# REVERIFY-b — independent re-verification of commit 13891a8 (d26 loop 2)

> NOTE ON PATH: the task requested this at
> `/home/red/proj/pc-tune/fleet/d26-verify2/_reports/agent-role-glyph/REVERIFY-b.md`.
> My worktree is isolated and cannot write into the shared `d26-verify2` checkout,
> so it is written to the same relative path inside my own worktree
> (`.claude/worktrees/agent-a8fdc41fe407581ba/_reports/agent-role-glyph/REVERIFY-b.md`).
> The orchestrator can copy it into `d26-verify2` if desired.

**Tester:** Tester B (independent; did NOT write this code, worked alone, did not
assume any other tester's results).
**Commit under test:** `13891a8` "fix(task): d26 loop 2 — label-aware shed gate,
hard-reject generic, close 5 test holes".
**Checked against:** the commit itself, the repo `CLAUDE.md` (Task-tag `--task`
section, three load-bearing constraints), and the prior adversary
`TEST-VERDICT.md` (NEEDS-WORK on four blockers). **d26 has NO PLAN.md /
SYNTHESIS.md — there is no approved spec**; verification is against the commit's
own claimed invariants + CLAUDE.md.
**Method:** execution + mutation testing. For every relied-upon assertion I state
the exact mutation (file, before→after) and the specific RED it produced. A green
run alone proves nothing.

## Environment / worktree note

My worktree (`agent-a8fdc41fe407581ba`) was checked out at `daf0f07` (later
mainline, which lacks the d26 work and `test/agent-task-proof.sh`). I checked out
the target commit **detached** in my own isolated worktree
(`git checkout 13891a8`) and verified `HEAD=13891a8` and the test file present
before doing anything. All edits were to this isolated worktree; nothing merged,
pushed, readied, or reaped.

## Isolation audit (before running anything)

`test/agent-task-proof.sh` isolation is **genuine**:
- `TMPROOT=$(mktemp -d)`; `SOCK` resolved under `$TMPROOT` (line 67).
- Fail-fast guard (lines 70–78) `REFUSE`s if `SOCK` equals the real
  `/tmp/tmux-$(id -u)/default` or is not under `$TMPROOT` — runs before any tmux
  call.
- `tmux()` wrapper (line 83) routes **every** call through `-S "$SOCK"`; cleanup
  (line 105) uses `command tmux -S "$SOCK" kill-server` — scoped to the private
  socket, never a bare `kill-server`.
- Harness `unset TMUX` (line 87); my ambient `TMUX` pointed at the live server but
  is dropped; `FLEET_HARNESS_SOCK` unset in my env so the guard passes cleanly.
- Stub `claude`/`claude-profile` first on PATH — no real agent launched.

My own independent capture script (scratchpad `indep-cap.sh`) mirrors this pattern
exactly (own `mktemp -d` socket, `-S` wrapper, REFUSE guard, stub PATH, killed on
EXIT). **The live `pc` server was never addressed.**

## Baseline

`bash test/agent-task-proof.sh` → **ALL PASS** (42 cases + 3 syntax). Re-run after
all mutations/restores → **ALL PASS**, `git status` clean — every restore exact.

## Mutation table

| # | Blocker | File | Mutation (before → after) | Case | RED message observed |
|---|---------|------|---------------------------|------|----------------------|
| 1 | B1 shed gate | bin/fleet-dash:1059 | `(( LW < ${#label} ))` → `(( LW < 1 ))` | 19b | RED. Harness: "the dashboard never rendered the fixture row at: w=80 — measured NOTHING" (blind branch masked it at the narrow end). **Independent capture** showed the true defect: tag+`…` coexist at w=105→70. |
| 2 | B1 shed gate | bin/fleet-dash:1059 | `${#label}` → constant `20` | 19b | RED "a task tag survived while its label was squeezed (tag must shed first): w=105/100/95/91 [impl …eature_very-long-branch-name-here]". 19c PASS. |
| 3 | B1 shed gate | bin/fleet-dash:1059 | `${#label}` → constant `200` | 19c | RED "the tag was shed at cw=100 with room to spare (over-shedding): repo/feat_one". 19b PASS. |
| 4 | B2 status bar | bin/fleet:4124 | append `tmux set -g … #{?@fleet_task_tag,…}` → `: ` (removed) | 16b | RED "inject_status_format did not append a task token: #I:#W#{?@agent_glyph,…}". 16d/16 PASS (fleetd independent). |
| 5 | B2 status bar | bin/fleet:1290 | `@fleet_task_tag "$(task_tag_trim "$task")"` → `@fleet_task_tag "$task"` (bar renders raw enum) | 16b | RED "the status bar expanded the RAW ENUM WORD, not the 4-char tag: '10:repo/feat_bar-rsch research'". 16d PASS. |
| 6 | B3 fleetd heal | bin/fleetd:283-284 | disable task branch (`if …` → `if False and …`) | 16d | RED "fleetd.heal_status_format did not re-append the task token: #I:#W#{?@agent_glyph,…}". 16/16b PASS. |
| 7 | B3 fleetd heal | bin/fleetd:284 | healed value `#{@fleet_task_tag}` → `#{@fleet_task}` (condition kept) | 16d | RED "fleetd healed to @fleet_task, not @fleet_task_tag (drift from bin/fleet): …#{?@fleet_task_tag, #{@fleet_task},}". 16/16b PASS. |
| 8 | B3 case 16 | bin/fleet:1052 + :1290 | defeat BOTH guards: unknown-drop `task=""` → `:` **and** store raw `$task` in `@fleet_task_tag` | 16 | RED "status-bar format corruption reachable" (also 13/14/15a/15b RED). Proves case 16 non-vacuous. |
| 9 | B4 generic | bin/fleet:1046-1048 | `return 2` → `task=""` (warn-and-drop, exit 0, spawn) | 26a | RED "--task generic exited 0; a script cannot detect the rejection". 26b/26c PASS. |
| 10 | B4 generic | bin/fleet:1052 | warning `want: research|…` → `want: generic|research|…` | 26c | RED "the warning does not advertise exactly the closed enum: got 'generic|research|plan|impl|test|scratch'". 26a/26b PASS. |

## BLOCKER 1 — label-aware shed gate (tag XOR ellipsis)

**(a)** 19b PASSES on shipped impl.
**(b)** `LW < 1` mutation → 19b RED (2/2 runs; blind branch at w=80 masked the
exact assertion). `LW < 20` → 19b RED with the precise "tag survived" message at
w=105/100/95/91. `LW < 200` → **19c** RED (over-shed). So the two directions form
a pincer: 19b catches a gate that holds the tag while the label elides; 19c catches
a gate that sheds the tag with room to spare. A constant fails one or the other;
only the label-aware `${#label}` gate satisfies both.

**(c) INDEPENDENT capture** (own sandboxed tmux, one 43-cell long label
`repo/feature_very-long-branch-name-here` + one short `repo/feat_short`, widths
120→70 stepped, `capture-pane`, assert no row shows tag+`…`):

Shipped impl — VERDICT **OK: no row showed both a tag and an ellipsis**. Selected rows:
```
width 110  │ idle impl repo/feature_very-long-branch-name-here │   (tag, full label)
width 105  │ idle      repo/feature_very-long-branch-name-here │   (tag SHED, label still full)
width 100  │ idle      …/feature_very-long-branch-name-here    │   (label elided, NO tag)
width  90  │ idle rsch repo/feat_short │  width 75  │ idle …feat_short │ (short: tag then elide, never both)
```
Same capture under the `LW < 1` mutant — VERDICT **TAG+ELLIPSIS COEXIST**:
```
width 105  │ idle impl …eature_very-long-branch-name-here │
width 100  │ idle impl …e_very-long-branch-name-here      │
width  90  │ idle impl …g-branch-name-here                │
```
This directly reproduces the original bug (badge squeezing the identity) at the
WIDE end that 19b's w=80 blind had hidden, and confirms the shipped gate holds the
invariant at every width.

**Verdict: FIXED.** (2 mutants killed on the gate + 1 on the opposite direction;
independent capture confirms the invariant on shipped code and its violation under
mutation.)

## BLOCKER 2 — status-bar test was vacuous (16b)

**(a)** 16b PASSES; it drives the real `"$FLEET" inject-status-format` subcommand
(not the old vacuous `( . "$FLEET"; inject_status_format )` that fell through to
usage / interactive picker).
**(b)** Removing the `@fleet_task_tag` append → 16b RED "did not append a task
token".
**(c)** Making the bar expand the raw enum (store `$task`, not `task_tag_trim`, in
`@fleet_task_tag`) → 16b RED "expanded the RAW ENUM WORD, not the 4-char tag:
'…feat_bar-rsch research'". The fixture window name `feat_bar-rsch` carries `rsch`
so the `grep rsch` pre-check passes via the name and the discriminator lands purely
on the `research` enum word — the assertion is genuinely discriminating.
Note: the task described this as "point the append at `@fleet_task`"; I achieved the
identical rendered effect at the option's write site, which is what the bar expands.

**Verdict: FIXED.** (2 mutants killed; test is non-vacuous.)

## BLOCKER 3 — case 16 + independent fleetd source (16d)

**(a)** 16 and 16d PASS.
**(b)** Disabling fleetd's `heal_status_format` task branch → 16d RED "did not
re-append the task token". 16/16b stayed green (confirming 16d exercises the
**second, independent** Python implementation, decoupled from bin/fleet).
**(c)** Pointing fleetd's heal at `@fleet_task` (condition kept on `@fleet_task_tag`
so it clears the first check) → 16d RED "fleetd healed to @fleet_task, not
@fleet_task_tag (drift from bin/fleet)".
**(d) case 16:** it **cannot** be forced RED by any single clean mutation, and this
is a robustness property, not vacuity. Defense-in-depth: (1) the write-site enum
validation drops non-enum `--task` values, and (2) `task_tag_trim`/`task_tag`
re-map through the closed `case` on the WRITE of `@fleet_task_tag`, so that option
can only ever hold `rsch/plan/impl/test/scr/''` — none contain `#[`. I PROVED 16 is
non-vacuous by defeating **both** guards (keep unknown task + store it raw): the
`x#[fg=red]` injection fixture then reached `@fleet_task_tag`, the expanded
`window-status-format` gained an extra `#[`, and case 16 fired
"status-bar format corruption reachable" (13/14/15a/15b also went RED). So case 16
genuinely guards the whole-server corruption surface; the double guard is why no
single mutation reaches it.

**Verdict: FIXED.** (2 mutants killed on 16d's independent source; case 16 proven
non-vacuous.)

## BLOCKER 4 — `--task generic` HARD reject (26a/26b/26c)

**(a)** 26a/26b/26c PASS.
**(b)** Reverting generic to warn-and-drop (`return 2` → `task=""`, exit 0 + spawn)
→ 26a RED "--task generic exited 0; a script cannot detect the rejection".
**(c)** Re-advertising generic first in the unknown-task enum warning → 26c RED
"the warning does not advertise exactly the closed enum: got
'generic|research|plan|impl|test|scratch'" — confirming the whole-string compare
closes the old positional `*"|generic"*` hole.
**(d)** 26b PASS throughout: the rejected generic leaves no `@fleet_task_tag` and no
`.fleet/tasks/<wname>` sidecar (nothing that would flip HAS_TASKS). On shipped code
generic `return 2`s before any spawn, so there is no window either (26a).

**Verdict: FIXED.** (2 mutants killed; hard-reject is real — non-zero exit,
error naming 'generic' on stderr, no spawn, no state.)

## Overall

| Blocker | Verdict |
|---------|---------|
| B1 label-aware shed gate | **FIXED** |
| B2 status-bar coverage (16b) | **FIXED** |
| B3 fleetd independent source (16d) + case 16 | **FIXED** |
| B4 generic hard-reject | **FIXED** |

All four prior NEEDS-WORK blockers are **FIXED**. 10 mutants applied, every one
killed by the specific case it was aimed at; the independent tmux capture confirms
BLOCKER 1's invariant on shipped code and its violation under mutation; case 16
proven non-vacuous. Final full suite: ALL PASS, tree clean.

No merge / push / ready / reap performed.

# RE-VERIFY (Tester A) — commit 13891a8 "fix(task): d26 loop 2"

**Independent tester.** I did not write this code. Verification is by EXECUTION
with MUTATION TESTING, not by reading the diff. Every assertion relied on below
was proven live: I applied a specific mutation to the shipped implementation, ran
`test/agent-task-proof.sh`, confirmed the target case went RED with a specific
failure message, then restored via `git checkout -- <file>`. A green run alone
proves nothing; each fix is backed by a mutant that the test kills.

## Provenance / what I checked against

- **Commit:** `13891a8` "fix(task): d26 loop 2 — label-aware shed gate,
  hard-reject generic, close 5 test holes".
- **Spec basis:** the three project `CLAUDE.md` files (esp. the `### Task tag`
  section), the harness header of `test/agent-task-proof.sh`, and the prior
  adversary VERDICT (NEEDS-WORK on four blockers). **d26 has NO PLAN.md and NO
  SYNTHESIS.md**, so there is no approved written spec — the invariants are those
  encoded in CLAUDE.md + the harness comments.
- **Worktree note:** this isolated worktree (`worktree-agent-a7b961e67e43aa83d`)
  was initially checked out on a *divergent* branch at `daf0f07`
  ("merge: d28 P4/P6 proof harness"), which does NOT contain `13891a8` as an
  ancestor and does NOT ship `test/agent-task-proof.sh`. Since this is my own
  throwaway worktree, I checked out `13891a8` (detached HEAD) to verify the exact
  commit the task targets. Confirmed `HEAD == 13891a8`, tree clean at start and
  end.

## Harness isolation — verified real (safety-critical)

Read `test/agent-task-proof.sh` lines 44–108. Isolation is INTRINSIC, not ambient:

- `TMPROOT=$(mktemp -d)` (52); `TMUX_TMPDIR="$TMPROOT/tmuxsock"` (61).
- Socket resolved locally: `SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"` (67).
- **REFUSE guard runs BEFORE any tmux call** (70–78): aborts if `SOCK` equals the
  real `/tmp/tmux-$(id -u)/default`, or if `SOCK` is not under `$TMPROOT`.
- Every tmux call routes through `tmux() { command tmux -S "$SOCK" "$@"; }` (83),
  so `-S` can be neither forgotten nor lost across a subshell.
- `cleanup()` (103–107) tears down only `command tmux -S "$SOCK" kill-server` —
  the private server, never the live `pc` server.

I never addressed the live `pc` tmux server. My independent capture (Blocker 1)
used its OWN `mktemp -d` socket with `-S` and killed only that server. I did NOT
run `fleet ready`/`reap`/`kill`.

Baseline (unmutated): `bash test/agent-task-proof.sh` → **ALL PASS, exit 0**
(44 cases incl. 16, 16b, 16d, 19b, 19c, 26a, 26b, 26c).

---

## Mutation table

| # | Blocker | File:line — mutation (before → after) | Target case | Observed result | Restored |
|---|---------|----------------------------------------|-------------|-----------------|----------|
| M1  | 1 | `fleet-dash:1059` `(( LW < ${#label} ))` → `(( LW < 1 ))` | 19b | **RED** — `a task tag survived while its label was squeezed (tag must shed first): w=105:[… impl …eature_very-long-branch-name-here] w=100 w=95 w=91` | ✓ |
| M1b | 1 | `fleet-dash:1059` → `(( LW < 20 ))` (constant floor) | 19b | **RED** — same "tag survived while label squeezed" across w=105..91 on the 43-cell label; 19c PASS | ✓ |
| M2a | 2 | `fleet:4124` append `tmux set … @fleet_task_tag …` → `:` (no-op) | 16b | **RED** — `inject_status_format did not append a task token: #I:#W#{?@agent_glyph,…}` | ✓ |
| M2b | 2 | `fleet:4124` token value → `@fleet_task` (`#{?@fleet_task_tag, #{@fleet_task},}`) | 16b | **RED** — `the task token was appended more than once` (literal `@fleet_task_tag` count fell to 1) | ✓ |
| M2c | 2 | `fleet:1290` store `@fleet_task_tag "$(task_tag_trim …)"` → `"$task"` (raw enum word) | 16b | **RED** — `the status bar expanded the RAW ENUM WORD, not the 4-char tag: '10:repo/feat_bar-rsch research'` (the research→rsch discriminator) | ✓ |
| M10 | 3 | `fleetd:283-284` task branch of `heal_status_format` → `pass` | 16d | **RED** — `fleetd.heal_status_format did not re-append the task token`; 16 PASS | ✓ |
| M11 | 3 | `fleetd:284` heal token both refs → `@fleet_task` | 16d | **RED** — `did not re-append the task token` (guard also changed → hit line 416) | ✓ |
| M11b| 3 | `fleetd:284` heal token value → `@fleet_task`, guard stays `@fleet_task_tag` | 16d | **RED** — `fleetd healed to @fleet_task, not @fleet_task_tag (drift from bin/fleet)` (the line-418 discriminator) | ✓ |
| C16 | 3 | `fleet:1290` store `@fleet_task_tag "…#[fg=red]"` (poison past validation) | 16 | **RED** — `poison in @1: @fleet_task_tag='impl#[fg=red]'` → `status-bar format corruption reachable` | ✓ |
| M14 | 4 | `fleet:1046-1048` generic `return 2` → `task=""` (warn-and-drop) | 26a | **RED** — `--task generic exited 0; a script cannot detect the rejection` | ✓ |
| B26b| 4 | `fleet:1048` generic → `task="scratch"` (leak state) | 26b | **RED** — `rejected 'generic' left state behind: tag='scr' file=…/tasks/repo/feat_generic` | ✓ |
| M5  | 4 | `fleet:1052` unknown-task warning `want: research|…` → `want: generic|research|…` | 26c | **RED** — `the warning does not advertise exactly the closed enum: got 'generic|research|plan|impl|test|scratch'` | ✓ |

**12 mutations applied; every one produced the expected RED and was restored.**
Final tree clean; final unmutated run **ALL PASS**.

---

## BLOCKER 1 — label-aware shed gate (19b/19c) → **FIXED**

- Shipped code PASSES 19b/19c.
- **M1** (revert to `LW < 1`, the original bug) and **M1b** (`LW < 20`, the loop-1
  constant-floor defect) both drive 19b RED with the *specific* assertion "a task
  tag survived while its label was squeezed", captured on the 43-cell fixture at
  w=105/100/95/91. The gate now expresses the per-row `tag XOR ellipsis`
  invariant, which a constant cannot.
- **Render-timing caveat (honest):** on the full width band the harness first
  reported the *blind* positive-control (`the dashboard never rendered the fixture
  row at: w=80 — this test measured NOTHING`). Per the task's own guidance a blind
  capture is not a genuine RED. w=80 stayed blind even at `sleep 2.0`, so it is an
  environment paint artifact at the narrowest width, not the mutation. Trimming the
  two flakiest widths (85, 80) from the loop exposed the genuine `bad` assertion at
  the wider, reliably-painting widths — exactly where the code comment says the
  held-tag defect lives ("held across the whole 113..91 band"). Harness edits were
  timing/width-list only (no assertion change) and were reverted.

### Independent capture (my own sandboxed tmux, `-S` on a `mktemp -d` socket)

Two fixtures (a realistic long branch + a short one, both `--task impl`), dashboard
stepped across widths **120..70**, `capture-pane -p`, asserting NO row ever shows
BOTH a tag (`rsch/plan/impl/test/scr`) AND `…`:

```
width 120  impl  repo/feat_one                                    | impl  repo/feature_very-long-branch-name-here
width 110  impl  repo/feat_one                                    | impl  repo/feature_very-long-branch-name-here
width 105  impl  repo/feat_one                                    |       repo/feature_very-long-branch-name-here   <- long tag SHED at its elision boundary
width 100  impl  repo/feat_one                                    |       …/feature_very-long-branch-name-here      <- elided, NO tag
width  95  impl  repo/feat_one                                    |       …ure_very-long-branch-name-here
width  91  impl  repo/feat_one                                    |       …very-long-branch-name-here
width  85  impl  repo/feat_one                                    |       …ong-branch-name-here
width  80        repo/feat_one                                    |       …ranch-name-here                          <- short tag shed, still not elided
width  75        …o/feat_one                                      |       …-name-here
width  70  (dashboard paints nothing at this width — consistent with the harness w=80 blind)
TOTAL_VIOLATIONS=0
```

The long label sheds its `impl` tag exactly at the width where it begins to elide
(w=105); the short label keeps its tag with room to spare and never elides (the
19c over-shed direction). **No row ever renders tag + ellipsis together.** The
invariant holds on shipped code, independently of the suite.

## BLOCKER 2 — status-bar surface coverage (16b) → **FIXED**

Loop 1's 16b was vacuous (`( . "$FLEET"; inject_status_format )` fell through to
usage). Loop 2 drives the real internal subcommand `"$FLEET" inject-status-format`.
**M2a** proves the test now has real coverage (removing the append → RED "did not
append a task token"). **M2c** proves the discriminating research→rsch assertion
works: storing the raw enum word into `@fleet_task_tag` makes the bar expand
"research" and 16b fires "expanded the RAW ENUM WORD" — a bug that `impl`/`plan`/
`test` fixtures (byte-identical value==tag) could never catch. (M2b, retargeting the
token value at the machine option, is also caught, via the structural token-count
guard.)

## BLOCKER 3 — independent baseline / fleetd's second implementation (16, 16d) → **FIXED**

16d exercises fleetd's SECOND, independent Python `heal_status_format` by importing
the module and calling the real method. **M10** (delete the task branch) and
**M11b** (retarget to `@fleet_task`) both drive 16d RED with its own messages,
incl. the specific drift-detector "fleetd healed to @fleet_task, not
@fleet_task_tag". Case 16 is **non-vacuous**: a poison value stored past validation
(`@fleet_task_tag='impl#[fg=red]'`) is caught by the value-whitelist, and its
baseline `base_n` comes from an *independent* untagged `WBASE` window — resolving
the prior "baseline reads the same option it asserts on" defect. **Honest note:**
case 16's `#[`-COUNT sub-check is dormant at case 16's position in the harness,
because `inject_status_format` is only called by `cmd_up`/the internal subcommand,
which the harness first invokes at 16b (after 16); so at case 16 the global format
carries no task token yet. The operative discriminator at that point is the value
whitelist, which I proved fires. Case 16 is not vacuous.

## BLOCKER 4 — `--task generic` hard reject (26a/26b/26c) → **FIXED**

Loop 1 shipped warn-and-drop (exit 0, invisible to a script). Loop 2 hard-rejects:
error on stderr, `return 2`, no spawn. **M14** (revert to warn-and-drop) drives 26a
RED ("exited 0; a script cannot detect the rejection"). 26b is non-vacuous: forcing
`generic` to leak a tag makes it RED ("left state behind: tag='scr' file=…"). **M5**
(re-advertise `generic` first in the unknown-task warning) drives 26c RED — the
whole-enum-string comparison (not a positional substring) catches it.

---

## Verdicts

| Blocker | Verdict |
|---------|---------|
| 1 — label-aware shed gate (19b/19c) | **FIXED** (M1, M1b killed; independent capture VIOL=0) |
| 2 — status-bar coverage (16b) | **FIXED** (M2a, M2c killed; discriminator proven) |
| 3 — independent baseline / fleetd heal (16, 16d) | **FIXED** (M10, M11b killed; case 16 non-vacuous) |
| 4 — generic hard reject (26a/b/c) | **FIXED** (M14, M5 killed; 26b non-vacuous) |

All four loop-2 fixes are real and the tests that guard them have genuine
(non-vacuous) coverage. No blocker remains broken. I did NOT merge, push, or run
`fleet ready`.

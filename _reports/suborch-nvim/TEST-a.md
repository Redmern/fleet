# TEST-a — d25 suborch-nvim, TESTER A (liveness / lifecycle)

Code under test: worktree `/home/red/proj/pc-tune/fleet/fleet_suborch-nvim`,
branch `fleet/suborch-nvim`, commit `22d733d`.

All runtime testing ran on **throwaway tmux servers** (`TMUX_TMPDIR` under a
`mktemp -d`), isolated `XDG_CONFIG_HOME`, isolated `XDG_RUNTIME_DIR` (so `rpc`
can never reach the real fleetd), a throwaway `FLEET_SESSION`, and a temp
`FLEET_ROOT`. The real ledger at `/home/red/proj/pc-tune/.fleet/dispatch` was
never read or written. No `fleet new` / `fleet dispatch` / `fleet reap` ever ran
against the live session. `fleetd` was never restarted.

My own harnesses (throwaway, kept in scratch, not added to the repo):

- `ta.sh` — runtime claim-1 checks, reconcile respawn/accumulation, gate park/pop
- `tb.sh` / `tb3.sh` — reap vs a viewer-bearing sub-orch, dirty/unmerged refusals
- `tc.sh` — adversarial edge probes (heal, pane-count guard, index-0 viewer, prune name guards)

## Verdict table

| # | Claim | Verdict |
|---|---|---|
| 1 | viewer is an ADDED pane, `@fleet_viewer` pane opt, no `@fleet_nvim_sock`, no `FLEET_AUTOCLAUDE`, harness spawn args unchanged | **PASS** |
| 2 | dead harness + surviving viewer ⇒ DEAD; `suborch_live` probes `suborch_harness_pane`; `window_pane_for`/`suborch_pane_for` skip viewers | **PASS** |
| 3 | `suborch_prune_orphan_window` drops the husk, keeps a healthy window | **PASS** |
| 4 | reconcile respawn; no double-viewer / pane accumulation | **PASS** |
| 5 | gate park / pop across a viewer-bearing sub-orch | **PASS** |
| 6 | reap of a viewer-bearing sub-orch window; refuses on dirty/unmerged | **PASS** |

No product bugs found. Two design observations are recorded under "Bugs found /
observations" — both are deliberate trade-offs, one worth a second look.

---

## Baseline — the shipped test suite

All five shipped scripts pass on a clean run:

```
########## suborch-viewer-liveness
  PASS(1 head -1 is the harness pane (%1	claude))
  PASS(2 viewer pane %2 runs nvim)
  PASS(3 suborch_live TRUE with a live harness)
  PASS(4 CRITICAL dead harness reads DEAD (panes left: %2	nvim	1))
  PASS(5 prune kills a viewer-only window)
  PASS(6 prune REFUSES a window with a live harness)
ALL PASS  (rc=0)

########## suborch-viewer-idempotent   ALL PASS (5 cases)
########## suborch-viewer-send         ALL PASS (4 cases)
########## suborch-viewer-focus        ALL PASS (7 cases incl. 4b/4c/4d)
########## dispatch-symlink-farm       ALL PASS (7 cases)
```

I re-derived every claim independently rather than relying on these.

---

## Claim 1 — viewer is an added, correctly-tagged pane; harness spawn unchanged

### 1.1 `cmd_new` is byte-identical to HEAD~1

The harness pane's spawn args live in `cmd_new`. Hashing the whole function at
both revisions:

```
$ for r in HEAD~1 HEAD; do git show $r:bin/fleet \
    | awk '/^cmd_new\(\)/{f=1} f{print} f&&/^}$/{exit}' | md5sum; done
f629801a19ae18bad89f182113e0092d  -
f629801a19ae18bad89f182113e0092d  -
```

Identical. The only spawn-shaped line the whole diff adds is the viewer's own
split:

```
$ git diff HEAD~1 HEAD -- bin/fleet \
    | grep -E "^[+-].*(split-window|new-window|new-session|FLEET_AUTOCLAUDE|fleet.lua)"
+#   * no --cmd nvim/fleet.lua and no FLEET_AUTOCLAUDE → the viewer must never
+  v=$(tmux split-window -d -P -F '#{pane_id}' -h -t "$harness" -l '40%' \
```

`split-window -d ... -h -t "$harness" -l '40%' -c "$dir" nvim .` — has `-d`, has
no `-b`, carries no `--cmd`, no `fleet.lua`, no `FLEET_AUTOCLAUDE`.

### 1.2 Runtime confirmation (`ta.sh`, section A)

```
  PASS(1a @fleet_nvim_sock unset on window)
  PASS(1b pane index 0 is the harness (%1))
  PASS(1c FLEET_AUTOCLAUDE absent from viewer proc env (pid 3803384))
  PASS(1d viewer cmdline is plain nvim (nvim . ))
```

- 1a reads `tmux show -wqv -t <wid> @fleet_nvim_sock` → empty. This is the
  load-bearing one: `cmd_send` keys on that window option and would route all
  delivery over nvim RPC with `die` and no fallback.
- 1c is a **process-level** check, not a code grep — it reads
  `/proc/<viewer_pid>/environ` and counts `^FLEET_AUTOCLAUDE=` → 0. This is
  stronger than the shipped suite, which does not check the viewer's env at all.
- 1d reads `/proc/<viewer_pid>/cmdline` → literally `nvim .`, confirming no
  `--cmd` / `fleet.lua` injection.

`@fleet_viewer` is confirmed set as a **pane** option (not window) by the fact
that `tmux list-panes -F '#{@fleet_viewer}'` returns `1` for exactly one pane and
empty for the harness in the same window — see the pane dumps throughout below,
e.g. `%1/claude/v= %2/nvim/v=1`. If it were a window option both panes would
read `1`.

---

## Claim 2 — LIVENESS: dead harness + live viewer must read DEAD

### 2.1 Independent repro (`ta.sh`, section B)

I built the exact scenario from scratch rather than reusing the shipped script:

```
    [husk d3] panes now: %6	nvim	1 
  PASS(2* husk reads DEAD (independent repro))
```

Sequence: window `so-d3` spawned with a fake `claude` on pane 0 → `attach-viewer`
→ harness pane killed → the **only** remaining pane is `%6`, running `nvim`,
flagged `@fleet_viewer=1` → `fleet suborch-live` returns non-zero.

This is the precise trap: `nvim` is allowlisted by `is_harness_cmd`, and the
viewer is now pane index 0, so the old `head -1` probe would have read ALIVE.

**Non-vacuity:** the probe could return DEAD for the wrong reason (window gone,
ledger `window_id` unresolvable). The printed pane dump proves the window still
exists and still has a live nvim pane at the moment of the probe, so DEAD came
from the harness-pane resolution, not from an absent window.

### 2.2 The stronger case the shipped suite does not cover — viewer at index 0 by position

`suborch_harness_pane` filters on the flag (`awk -F'\t' '$1!="1"'`), but the
shipped test only ever reaches the "viewer is index 0" state *by killing the
harness*. I forced a window where the viewer is genuinely first in index order
while the harness is still alive, via `tmux swap-pane` (`tc.sh`, E3):

```
    after swap (viewer first?): 1:%7:nvim:v=1 2:%6:claude:v= 
  PASS(E3 still ALIVE with viewer at index 0 (harness found by flag, not position))
  PASS(E3b DEAD after harness dies even with viewer at index 0)
```

E3 is the discriminating case: a `head -1`-based probe would report **nvim** as
the harness command here and still read ALIVE — but so would a correct probe,
which is why E3b matters. E3 proves the harness is located by flag rather than
position; E3b proves the DEAD verdict survives that reordering.

### 2.3 `window_pane_for` / `suborch_pane_for` skip viewers

Covered under Claim 5 below (5b / 5c), since those are the pop-router paths.

---

## Claim 3 — `suborch_prune_orphan_window`

Shipped cases 5 and 6 pass. I extended them with the guard cases that decide
whether prune can ever destroy something it shouldn't (`tc.sh`):

```
  PASS(E4 prune refuses a non-so-* window (name guard holds))
  PASS(E5 prune refuses when expected-name mismatches (stale ledger wid safe))
  PASS(E5b prune accepts the matching name)
  PASS(E6 prune is prefix-tolerant (so-d6 matches so-d6-my-slug))
```

- **E4** — a window named `repo/branch` reduced to a viewer-only husk is
  **refused**, because of the `case "$name" in so-*)` guard. This is the blast-radius
  guard: without it, a stale ledger `window_id` (tmux ids restart at `@0` after a
  server restart) could point prune at an unrelated worker window.
- **E5** — same husk, but pruned with `want=so-d99` while the window is `so-d5`:
  refused. Then `want=so-d5`: pruned. This proves the expected-name parameter is
  actually consulted, and E5b proves E5's refusal is not simply "prune never
  works" — the pair is non-vacuous only because both halves run on the *same*
  window.
- **E6** — `dispatch rename` turns `so-d6` into `so-d6-my-slug`; prune with
  `want=so-d6` still matches. Without this a renamed sub-orch's husk would never
  be collected.
- Healthy-window refusal (shipped case 6) re-confirmed independently at 6a below,
  where a live 2-pane sub-orch survives a full `fleet reap` untouched.

---

## Claim 4 — reconcile respawn, no double-viewer / pane accumulation

`ta.sh` section B, using the real `fleet reconcile` against a throwaway ledger.

### 4a — repeated reconcile on a LIVE sub-orch adds nothing

```
  PASS(4a 3x reconcile on a LIVE sub-orch: panes=2 viewers=1)
```

Three consecutive `fleet reconcile` sweeps: still exactly 2 panes, exactly 1
`@fleet_viewer`. This is the per-tick pane-leak scenario the double guard in
`suborch_attach_viewer` (flag guard + pane-count guard) exists for.

### 4b — a husk is pruned and the respawn does not leak a window

```
  PASS(4b reconcile pruned the husk window @3)
    [windows] before-kill=4 after-reconcile=4
  win @0 keep panes=1
  win @1 so-d1 panes=2
  win @2 so-d2 panes=2
  win @4 so-d3 panes=2
```

The husk `@3` is gone; `so-d3` came back as a **new** window `@4` with 2 panes
(harness + freshly attached viewer). Total window count is unchanged at 4 across
the death-and-respawn cycle — no husk leak, no duplicate `so-d3`, and the
respawned window has exactly one viewer, not two.

`suborch_find_wid` therefore has no decoy to match, which was the stated reason
for pruning before respawn.

### 4c — the "abandon" path

`cmd_reconcile`'s abandon branch (`state=failed` + prune) is exercised implicitly:
`FLEET_RECONCILE_CAP` defaults to 1, so the second death routes there. No husk
survived anywhere in any run — confirmed by the global husk sweep in `tb3.sh`:

```
  PASS(6h no viewer-only husk windows anywhere)
```

which enumerates every window on the server and fails on any 1-pane window whose
sole pane is flagged `@fleet_viewer=1`.

---

## Claim 5 — gate park / pop across a viewer-bearing sub-orch

`ta.sh` section C.

```
    parked d1 at gate1-wait
    gate waiting => 'so-d1'
  PASS(5a gate park registers so-d1 as waiting)
    suborch_pane_for(so-d1) => '%1'  (harness=%1 viewer=%2)
  PASS(5b suborch_pane_for resolves the harness, not the viewer)
    after harness death, suborch_pane_for(so-d1) => '' (viewer was %2)
  PASS(5c dead harness does not resolve onto the viewer (got ''))
```

- **5a** — `fleet gate park d1 1` then `fleet gate waiting` emits `so-d1`, on a
  window that has a viewer pane attached. The viewer does not perturb gate
  bookkeeping.
- **5b** — the pop router resolves `so-d1` to `%1`, the **claude** pane, while the
  nvim viewer `%2` sits in the same window. Asserted against the independently
  computed harness pane id, not against a hardcoded `%1`.
- **5c** is the critical one and is the reason the `[ "$v" = 1 ] && continue`
  line in `suborch_pane_for` exists. With the harness dead, the viewer is the
  only pane left in the window — a router without the filter would resolve onto
  `%2` and send-keys the human's gate pop into a file browser. It returns empty
  (rc 1) instead.

  **Non-vacuity check:** an empty return could mean "the function is broken and
  always returns empty". 5b, run on the same window minutes earlier, returns a
  correct non-empty pane id — so the empty at 5c is the viewer filter firing, not
  a dead function. My harness explicitly distinguishes these: the 5b branch fails
  with "returned EMPTY (could not source)" if sourcing had failed.

---

## Claim 6 — reap of a sub-orch window with a viewer pane

`tb3.sh`. Real git repo + three real linked worktrees (clean+merged, dirty,
unmerged), a real `main` command-center window with `@fleet_role main` and a role
registry file, and a gate-parked `so-d1` carrying a viewer.

```
  [setup] so-d1 panes: %1/claude/v= %2/nvim/v=1 
== claim 6: reap
    reaped repo/fleet/ok
    skip   repo/fleet/dirty: 1 uncommitted file(s) (use --force)
    skip   repo/fleet/unm: branch not merged into main (use --force)
  PASS(6a gate-parked sub-orch survives reap intact (panes=2 viewer=1))
  PASS(6b clean+merged worker worktree removed)
  PASS(6b2 clean worker window closed)
  PASS(6c dirty worktree REFUSED (still present))
  PASS(6c2 refusal names dirty)
  PASS(6d unmerged worktree REFUSED (still present))
  PASS(6e session survived reap)
  PASS(6f main window survived)
  [after] windows: main(1) so-d1(2) repo/fleet_dirty(1) repo/fleet_unm(1) 
== 6g: reap --force does not orphan a viewer husk
    so-d1 still: %1/claude %2/nvim 
  PASS(6g reap --force left the sub-orch window (no worktree to reap => no-op))
  PASS(6h no viewer-only husk windows anywhere)
```

- **6a** — the gate-parked sub-orch survives a full `fleet reap` with **both**
  panes and its viewer flag intact. The gate-wait skip guard is not confused by
  the extra pane.
- **6b/6b2** — the one genuinely reapable worker is removed, worktree and window.
  This proves the run was not a global no-op, which is what would make 6a/6c/6d
  vacuous.
- **6c/6d** — dirty and unmerged both refused, with the refusal reason printed,
  and both worktrees still on disk afterwards.
- **6e/6f** — session and `main` window survive (`safe_kill_window` brakes hold
  with a viewer in play).
- **6g/6h** — `fleet reap so-d1 --force` on the sub-orch's own name is a no-op
  (a sub-orch is `--scratch`, it owns no worktree), and critically leaves **no
  viewer-only husk** anywhere on the server.

### A harness bug of my own, disclosed

My first run of `tb.sh` reported FAIL on 6c and 6d. That was **my fixture's
fault, not the product's**: all three worktrees wrote the same file `f.txt` with
the same content, so after `fleet/ok` was merged into `main`, the later worktrees'
commits were empty. `git commit` then printed "nothing to commit" to stdout,
polluting my `WT_DIRTY`/`WT_UNM` path variables (so `[ -d "$WT_DIRTY" ]` tested a
multi-line string), and `fleet/unm` was *genuinely* merged (identical to main), so
reap was right to reap it. Evidence of the diagnosis:

```
WT_DIRTY=[On branch fleet/dirty
nothing to commit, working tree clean
/tmp/tmp.6sUpOCbiR5/root/repo/fleet_dirty]
```

Giving each worktree a distinct file fixed it and all six cases pass. I record
this because it is exactly the class of false signal I was asked to hunt — it
would have been easy to file "reap reaps unmerged branches" as a product bug.

---

## Supplementary — `fleetd` arity

CLAUDE.md flags the `fleetd` tuple arities as having crash-looped the daemon
twice during development, and `fleetd` has no try/except around method dispatch.
I verified the two widened format strings against their guards mechanically:

```
$ python3 -c "import ast;ast.parse(open('bin/fleetd').read());print('fleetd parses OK')"
fleetd parses OK

fields= 5  | #{pane_id}\t#{@fleet_state_src}\t#{@fleet_busy_re}\t#{pane_current_path}\t#{@fleet_viewer}
fields= 10 | #{pane_id}\t#{window_id}\t#{session_name}\t#{window_name}\t#{pane_current_path}\t#{pane_active}\t#{@fleet_harness}\t#{window_activity}\t#{@fleet_role}\t#{@fleet_viewer}
```

Matching `len(parts) != 5` and `len(parts) == 10` guards. `meta` stores
`parts[1:]` (9 elements), so `m[7]`=`@fleet_role`, `m[8]`=`@fleet_viewer` — the
reported-pane loop's `m[8]` index is correct, and the synth pass unpacks 9 names
from `m` and 10 from `(pane,) + tuple(m)`. Both correct. The live behaviour is
independently confirmed by shipped focus case 4b (daemon still alive after
serving `fleet.list`).

I did **not** restart the real `fleetd` at any point.

---

## Vacuous or weak tests

I read the assertions of every shipped script looking for trivial passes. The
suite is unusually well defended — several cases carry explicit anti-vacuity
guards written by the author. Findings, worst-first:

1. **`dispatch-symlink-farm.sh` leaks a real error into a PASS run.** The run
   prints:

   ```
   ./test/dispatch-symlink-farm.sh: line 106: /tmp/.../root/_reports/second-slug/PLAN.md: No such file or directory
   ```

   from `echo hi > "$rep2/PLAN.md" 2>/dev/null || { mkdir -p "$rep2"; echo hi > "$rep2/PLAN.md"; }`
   — the `2>/dev/null` does not suppress the *shell's* redirection error, only the
   command's. The `||` fallback then succeeds, so the case legitimately passes.
   **Cosmetic, not vacuous**, but it makes a green run look broken and should be
   `mkdir -p "$rep2"` unconditionally first.

2. **`dispatch-symlink-farm.sh` cases 4 and 5 are `grep`-on-a-markdown-file
   assertions.** They check that `FLEET_SUBORCH.md` *contains* `ln -sfn`,
   `dispatch/<id>/reports`, `$1=="reports"`. That is documentation linting, not
   behaviour — a doc could satisfy every grep and still be wrong. Mitigated well
   by case 6, which *extracts and `eval`s* the manual's own fenced blocks and
   asserts the resulting farm resolves; that is the real proof and it is a good
   one. I would not weight 4/5 as evidence of anything.

3. **`suborch-viewer-liveness.sh` case 1 is weaker than it reads.** "head -1 is
   the harness" is asserted while the harness is alive — the state in which
   `head -1` gives the right answer even in the *broken* design. The case that
   actually discriminates is 4. Case 1 is fine as a `-b`-regression canary but is
   not liveness evidence. The script's own header is honest about this.
   My E3 (`swap-pane`) closes the gap: it produces viewer-at-index-0 *with a live
   harness*, which case 1 cannot.

4. **`suborch-viewer-idempotent.sh` case 4 (bogus window id)** would be
   tautological on rc alone — the function ends in unconditional `return 0`. The
   author noticed and asserts on server-wide window/pane counts instead. Good.

5. **Anti-vacuity guards worth crediting** (these are the opposite of weak):
   - liveness `ABORT`s outright if no viewer attached, since cases 4–6 would
     otherwise pass with nothing to mask a dead harness.
   - focus **4b** asserts `kill -0 $DPID` — without it, a daemon that crashed
     mid-reply scores a PASS on case 4 because `agents_tsv` silently falls back
     to the tmux-option path and returns the same answer.
   - focus **4c** asserts the reply actually came over RPC, not the fallback.
   - symlink-farm case 7 asserts row/entry counts are *unchanged*, rather than
     asserting a dangling link merely exists.

6. **Not covered by any shipped script, now covered by mine:** the viewer's
   process environment (`FLEET_AUTOCLAUDE`) and cmdline; reconcile-driven pane
   accumulation; gate park/pop; reap interaction; prune's name/prefix guards;
   viewer-at-index-0 with a live harness.

---

## Bugs found

**No product bugs found.** Every claim in the brief reproduced as designed under
independent construction. Two observations, neither a defect:

### O1 — the pane-count guard means a non-bare sub-orch would never get a viewer (by design, worth confirming)

`tc.sh` E2:

```
  NOTE(E2): 2-pane window w/o a viewer gets NO viewer (count guard wins).
            panes=2 viewers=0
  PASS(E2 count guard prevents pane leak (no 3rd pane added))
```

`suborch_attach_viewer` bails when the window already has ≥2 panes, regardless of
whether either is a viewer. That is the correct call for the leak it guards
against (an unflagged nvim left behind by a kill between `split-window` and
`set -p` would otherwise be re-split on every reconcile tick, unboundedly).

The consequence: if a sub-orch were ever spawned **non-`--bare`** (editor + agent
= 2 panes), it would silently never receive a viewer, and the "runs on both
branches so a re-resolution heals a missing viewer" comment would not hold for it.
Today sub-orchs are always `--scratch`, which is bare, so this is unreachable —
but it is an invariant the code depends on without asserting. Cheap hardening
would be to gate on "≥2 panes **and** no unflagged nvim among them", or simply to
note the `--scratch`-only precondition in the function's comment.

### O2 — healing works for the case that matters

The complement of O1: when the human closes the viewer pane, the window drops to
1 pane and the next resolve **does** heal it (`tc.sh` E1):

```
    after viewer kill: %1	claude	 
  PASS(E1 viewer healed after manual kill (panes=2 viewer=1))
```

So the healing claim in the comment is true for the realistic path. Recorded only
to bound O1's scope.

---

## Coverage / UNTESTED

Nothing in the brief is left UNTESTED. Explicitly out of scope and not exercised:

- The real `fleetd` unit was never restarted, per the safety rules; daemon
  behaviour was tested only via the shipped focus harness's own throwaway daemon
  on a throwaway socket (which does exercise the widened tuple arities live).
- No test touched the live tmux session, the real ledger, or a real dispatch.
- `FLEET_SUBORCH.md`'s prose changes (the `$reports` / symlink-farm instructions)
  are agent-behaviour guidance; I verified only that the manual's own §3.0.6
  commands execute and build a resolving farm (shipped case 6 re-run), not that a
  live sub-orch follows them.

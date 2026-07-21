# REVERIFY — adversarial re-verification of commit 13891a8 ("fix(task): d26 loop 2")

Role: **adversary**. My only job was to BREAK the claim that all four d26 loop-2 blockers
are fixed. I did not balance. Every assertion I relied on was mutation-tested (the mutation
is named and its RED result recorded). Where I could not break a fix I say so and rate
confidence.

Checked against: **commit 13891a8** (the actual code, checked out — see "Provenance"),
`CLAUDE.md` (root + `d26-verify2/CLAUDE.md`), and the prior `TEST-VERDICT.md`
(NEEDS-WORK, against ff9da68). **d26 has no PLAN.md / SYNTHESIS.md** — spec conformance
is checkable only against the commit message and `CLAUDE.md` prose.

## Safety

Every dynamic test ran on a **throwaway tmux server** under its own `mktemp -d` root,
addressed with `-S "$SOCK"` via a wrapper, with the harness's REFUSE guard (socket must be
under TMPROOT, never `/tmp/tmux-$(id -u)/default`). My own capture rigs
(`scratchpad/rig.sh`, `rig2.sh`, `case16probe.sh`, `genprobe.sh`) replicate that isolation
byte-for-byte and kill only their own server on exit. The live `pc` tmux server was never
addressed. No `fleet reap`/`ready`/`kill` outside a sandbox. No commit, push, merge, or
`fleet ready`. All code mutations were reverted with `git checkout`; final `git status` is
clean at HEAD=13891a8.

## Provenance (important)

The worktree I was handed was **NOT at 13891a8** — it was at `daf0f07` (d28 mainline),
which does **not contain the d26 task-tag code at all** (`grep -c fleet_task` = 0 in all
three bins) and where **`test/agent-task-proof.sh` does not exist**. The d26 branch
(13891a8, c8eb395, ff9da68) was never merged into that line. To verify the commit under
review I `git checkout 13891a8` in my isolated worktree and attacked that tree. All results
below are against 13891a8. (This report was written to my worktree's
`_reports/agent-role-glyph/` because the harness confines writes to the worktree; copy it to
`d26-verify2/_reports/agent-role-glyph/REVERIFY-adversary.md` if that canonical location is
wanted.)

Baseline: a clean run of `test/agent-task-proof.sh` on 13891a8 is **46 PASS / ALL PASS**,
zero failures — the prior BLOCKER 3 (harness socket setup) is fixed (line 64 now
`mkdir -p … && chmod 700`).

---

## BLOCKER 1 — label-aware shed gate / tag-XOR-ellipsis — **HELD**

`bin/fleet-dash:1059`: `(( LW < ${#label} )) && (( task_show )) && { task_show=0; … }`.

**Structural argument.** `fit_left` (`bin/fleet-dash:105-111`) elides exactly when
`${#s} > w`, i.e. `LW < ${#label}`. The shed gate fires on the **identical** condition,
computed on the **same string** with the **same measure** (`${#…}`, codepoints in this
locale). So the gate is the exact negation of "fit_left will elide": whenever the label
would be truncated the tag has already been dropped, and LW recomputed larger. The later
cost/mode/✉ rungs fire only at `LW < 1`, which (for any non-empty label, `${#label} ≥ 1`)
implies the gate already fired — so they can never shrink LW while the tag is still shown.
The invariant is airtight by construction, not by tuning.

**Empirical attack (my own `capture-pane`, isolated server).** Swept **every integer
width** the suite skips:

- 60-cell ASCII label, widths **40..125** → **0 violations**.
- CJK **wide-char** label (`機能テスト…`, each glyph 2 cells / 1 codepoint), 65..125 →
  **0 violations**. (The byte-vs-cell worry does not break tag-XOR-ellipsis: the gate and
  fit_left both count codepoints, so they agree regardless of display width. A CJK label
  can overflow the card box — a pre-existing fit_left cosmetic property — but never yields
  tag+`…` on one row.)
- **Four tagged rows** of differing lengths at once (long / medium / `short` / `x`),
  65..125 → **0 violations**. The gate is per-row (inside the render loop), so rows do not
  interact.

**Mutation tests (all produced RED, proving the gate is load-bearing AND the tests are
non-vacuous):**

- **M2** gate → `LW < 1` (the original bug): my rig shows the `impl` tag coexisting with
  `…` at **every width 72-125** (`…repo/feature_this-is-a-very-long-branch-name-to`).
  Full suite: 19b RED.
- **M3** gate → constant `LW < 20` (the loop-1 fix): **19b's DEFECT branch fires directly** —
  `FAIL(19b): a task tag survived while its label was squeezed … w=105 … w=100 … w=95 …
  w=91`. This proves the `bad` assertion (not just the blind control) is reachable.
- **M15** gate → `LW < ${#label} + 25` (over-shed): **19c RED** ("tag was shed at cw=100
  with room to spare").

**Two minor test notes (not breaks):**
- 19a's `grep -n 'LW < ${#label}'` matches the **comment on line 1049** (via `head -1`),
  not the code on 1059 — so 19a alone cannot tell the code gate from its own comment. 19a
  is explicitly belt-and-suspenders ("must never again stand alone"); 19b carries the
  functional weight and is not fooled.
- Under M2 the *full-suite* 19b tripped its **blind control** (w=80, fixture tail not
  rendered) which masks the defect message — but M3 shows the defect branch is independently
  reachable, so 19b is not vacuous.

Confidence: **high**. The fix is correct at every width I could render, and correct *by
construction*.

## BLOCKER 2 — status-bar injection 16b — **HELD**

`bin/fleet:4124` appends `#{?@fleet_task_tag, #{@fleet_task_tag},}`. Mutations:

- **Drop the append** → `FAIL(16b): inject_status_format did not append a task token`.
- **Point the append at `@fleet_task`** (drift) → `FAIL(16b)` (16b greps for the literal
  `@fleet_task_tag` token). The `research→rsch` discriminator (line 387) is a secondary
  guard behind that; either way the drift is RED.

**Tested-path == real-path.** `inject_status_format` has exactly two callers: `cmd_up`
(`bin/fleet:4632`, the real `fleet up` path) and the internal `inject-status-format`
subcommand (`bin/fleet:5235`) that 16b drives. Both call the *same function* — no divergence
between what 16b exercises and what `fleet up`/fleetd run. Idempotency (16c) is a real
re-run+diff. Confidence: **high**.

## BLOCKER 3 — case 16 corruption guard + fleetd 16d twin — **HELD, with one residual**

**16d (Python twin) is non-vacuous.** Mutations:
- Delete the Python task branch (`bin/fleetd:283-284`) → `FAIL(16d): did not re-append`.
- Point Python at `@fleet_task` → `FAIL(16d)`.

**Twins agree byte-for-byte.** Extracted every `#{?@opt, #{@opt},}` literal from `bin/fleet`
and `bin/fleetd`; the sets are **identical** (`agent_glyph`, `fleet_dispatch`,
`fleet_task_tag`) — `diff` empty. No silent drift between the bash and Python injectors that
16b/16d could miss.

**Case 16 IS falsifiable.** My `case16probe.sh` hand-poisoned a window with
`@fleet_task='#[fg=red]evil'` and `@fleet_task_tag='#[bg=blue]#['`, with the token present in
the format. Case 16's logic flagged it **three independent ways**: stored `@fleet_task` not
in the enum, stored `@fleet_task_tag` not in `{rsch…scr}`, **and** the expanded `#[` count
(2) exceeded baseline (0). So case 16 is not the vacuous test the prior verdict found.

**RESIDUAL FINDING (a dormant sub-check, not a broken fix).** In the *actual harness run*,
at case-16 time the global `window-status-format` is `#[fg=#6d7db6] #I:#W` — the
`@fleet_task_tag` token is **NOT injected**. Reason: only `cmd_up` injects it in normal
operation, the harness never runs `fleet up`, and 16b's own `inject-status-format` call
(line 372) happens **after** case 16 (line 361). I confirmed this by printing the global
format immediately before case 16. Consequence: every window shares the same token-less
format, so no window can exceed baseline, so case 16's **`#[`-count dimension cannot fire
in-harness** — exactly the coverage the prior verdict's item 2 asked to be given a positive
control. Loop 2 instead added the **stored-value checks**, which *are* live and falsifiable
(proven above), so case 16 is non-vacuous overall. But the specific "demonstrate the
injection-count guard can fail" positive control was **not** added, and that sub-check is
still dormant in the shipped suite. My external probe fills the gap and shows the logic is
sound; the suite does not. **Note, not blocking** — the invariant is protected at the write
site + read-revalidation, so the poison case-16 guards against is unreachable anyway.

Confidence: **high** that the twin is real and byte-identical; **medium** that the shipped
case-16 fully closes the prior "can it fail at all" concern (the stored-value half does, the
count half doesn't fire in-harness).

## BLOCKER 4 — `--task generic` hard reject — **HELD**

Exact `--task generic` (`genprobe.sh`, isolated): **rc=2, window=NONE, @fleet_task='',
@fleet_task_tag='', no sidecar file, no `.agents` line**. The `return 2` sits at
`bin/fleet:1048`, before `fleet_root` / worktree creation / any tmux window / any persist —
nothing is written before it. **No leak of any kind.** Mutations:

- Remove the hard-reject (fall through to warn-drop) → `FAIL(26a): --task generic exited 0;
  a script cannot detect the rejection`.
- Re-advertise `generic` in the unknown-task warning → `FAIL(26c): does not advertise
  exactly the closed enum` (26c compares the whole `research|plan|impl|test|scratch` string,
  so re-adding generic in *any* position is caught).

**Adjacent inputs (`genprobe.sh`):** `Generic`, `GENERIC`, `" generic "`,
`"research,generic"`, `"generic\nmain"` all fall to **warn-and-drop** (rc=0, spawn an
**untagged** agent, `task=""`, no `@fleet_task_tag`, no sidecar). So the hard reject is
**exact-match only** — a case/whitespace/compound variant returns rc=0 instead of rc=2. This
is **not a leak**: those variants store *nothing*, so they never flip `HAS_TASKS` or cost a
column — the precise harm the reject exists to prevent does not occur. Only the literal
documented value (the one old docs/prompts actually emit) gets the loud rejection. Acceptable.
(`generic\n` alone hard-rejects, because command-substitution strips the trailing newline →
value is exactly `generic`.)

**`main` inconsistency persists, by design and by test-coupling.** `--task main` remains
**warn-and-drop** (rc=0, spawns untagged) — NOT hard-rejected. Case 14 **depends on this**:
it spawns `--task main`, requires the window to exist, and asserts the role file reads
`worker` (14b). So the generic-hard / main-soft divergence is *locked in* — hard-rejecting
main to "fix the inconsistency" would break case 14. Security is intact regardless: `main`
is dropped to `""`, never stored, so no self-promotion (14 verifies `@fleet_role`, the roles
file, and the sidecar are all clean). The inconsistency is a UX wart the commit message
defends explicitly, not a hole.

Minor: 26b's `@fleet_task_tag` check reads `-t "$WG"` where `WG` is empty (no window
spawned), so that half is trivially-empty; the sidecar-absence check is the meaningful part.
My independent probe confirmed no tag on any window. Confidence: **high**.

---

## Verdict

All four loop-2 fixes **HELD** under adversarial mutation + fuzzing. The suite is
substantially de-vacuumed relative to the prior review: 19b/19c catch the gate in both
directions with reachable defect branches, 16b/16d are load-bearing and the twins are
byte-identical, and 26a/26c genuinely fail when the reject or the enum message drifts.

Residuals found (none blocking):
1. **Case 16's `#[`-injection-count sub-check is dormant in-harness** — the token is never in
   the format when case 16 runs, so that dimension cannot fire; only the (live) stored-value
   checks carry it. The prior verdict's requested positive control for the count guard was
   not added.
2. **19a matches its own comment**, so it can't distinguish code from comment (mitigated
   fully by 19b).
3. **generic hard-reject is exact-match only** (`Generic`/` generic ` warn-drop instead) —
   no leak, since variants store nothing.
4. **main stays warn-and-drop while generic is hard-rejected** — deliberate, and case 14 is
   structurally coupled to main continuing to spawn.

These are test-coverage / consistency notes, not functional breaks. I could not produce a
single (width, label) with tag+`…` on clean code, could not make an injection reach the
status bar, and could not make `generic` leave state behind.

# VERIFY-adversary — refutation attempt against c8eb395

Role: adversary. Brief: refute the four claimed fixes by execution and capture; a failed
refutation is a valid result. Nothing below is inferred from the diff — every claim has a
command and raw captured output.

**Verdict: 2 of the 4 fixes REFUTED (fix 1 broken in both directions; fix 3's coverage
still has holes). Fixes 2 and 4 I could NOT break behaviourally — but both, plus fix 3,
carry assertions that survive their own mutation, i.e. tests that cannot fail.**

---

## Safety

Every tmux call went through a `tmux()` wrapper defined in the same file as its callers,
with explicit `-S "$SOCK"` under my own `mktemp -d`, `TMUX_TMPDIR` exported,
`mkdir -p "$(dirname "$SOCK")" && chmod 700`, and three fail-fast refusals (socket ==
real socket / socket not under `$TMPROOT` / socket matching `/tmp/tmux-*/default`).
The live `pc` server was never addressed. No `fleet reap`/`ready`/`kill` and no
`kill-server` outside the sandbox. Nothing committed. The only file written in the
worktree is this report.

## Environment note (NOT a defect of this commit — but it blocked testing)

The worktree `/home/red/proj/pc-tune/fleet/d26-verify` is currently in an **unresolved
merge**, and `bin/fleet` in the working tree **does not parse**:

```
$ git status --short
UU FLEET_SUBORCH.md
UU bin/fleet
UU bin/fleet-dash
$ bin/fleet agents
bin/fleet: line 5537: syntax error near unexpected token `<<<'
bin/fleet: line 5537: `<<<<<<< HEAD'
```

Per my brief ("attack c8eb395 as committed"), I tested a clean extraction:
`git archive c8eb395 | tar -x -C <scratch>/tree`. All results below are against that
tree, which parses and whose harness is green at baseline (`ALL PASS`, 8.7s).

---

# FIX 1 — "Dash sheds the task field before the label is ever squeezed"

## REFUTED. Broken in both directions, plus the test that guards it is blind.

The fix replaces the gate `LW < 1` with `LW < LBLMIN` where `LBLMIN=20` is a **fixed
constant** (`bin/fleet-dash:966`). But the elision point is `LW < ${#label}` — a function
of the *label*, which the fix does not read. So the fix is correct only for the single
label length band it happens to match, and wrong on both sides of it.

## C1 — BLOCKING — STILL BROKEN: tag held while the label is elided (labels ≥ 20 chars)

One tagged agent, real `fleet-dash` in a real tmux window, `capture-pane -p`, exhaustive
sweep 120→60. Agent: `longrepo/feature_very-long-branch-name-here` (43 cells).

Repro:
```sh
spawn longrepo feature/very-long-branch-name-here --task impl
tmux set -w -t "$WL" @agent_state idle
for W in $(seq 120 -1 60); do
  tmux kill-window   -t "=$S:dashw"
  tmux new-window -d -t "=$S" -n dashw -c "$FLEET_ROOT" "$DASH $S"
  tmux set -w -t "=$S:dashw" window-size manual
  tmux resize-window -t "=$S:dashw" -x "$W" -y 24
  sleep 0.7; tmux capture-pane -p -t "=$S:dashw" | grep -m1 'longrepo\|…'
done
```

Raw captured output (abridged to the band; full sweep was contiguous):
```
114 |│▌   idle      impl   longrepo/feature_very-long-branch-name-here       ✓        default    -             │
113 |│▌   idle      impl   …ngrepo/feature_very-long-branch-name-here       ✓        default    -             │
112 |│▌   idle      impl   …grepo/feature_very-long-branch-name-here       ✓        default    -             │
105 |│▌   idle      impl   …eature_very-long-branch-name-here       ✓        default    -             │
100 |│▌   idle      impl   …e_very-long-branch-name-here       ✓        default    -             │
 95 |│▌   idle      impl   …y-long-branch-name-here       ✓        default    -             │
 91 |│▌   idle      impl   …ng-branch-name-here       ✓        default    -             │
 90 |│▌   idle      …ery-long-branch-name-here       ✓        default    -             │
```

**A 23-column-wide band (113 → 91)** in which the `impl` tag holds its 4+G columns while
the identity is left-ellipsised, and `✓ / default / -` are all still present. The exact
violation the commit claims to close, at ordinary widths — 100 and 110 are unremarkable
pane sizes. Shed fires only at 90.

The commit's own invariant, quoted from its message — *"a row may show a tag or a
squeezed label, never both"* — is false at every width from 113 to 91.

Correct gate is label-aware, e.g. `(( LW < ${#label} ))` (optionally
`max(LBLMIN, ${#label})`). `LBLMIN=20` only works for labels ≤ 20 cells; `repo/branch`
labels routinely exceed that (`repo/feat_one`, the harness's own agent, is 13 — which is
exactly why the test misses this; see C3).

## C2 — MINOR — NEWLY BROKEN BY THIS FIX: tag shed with ~30 columns to spare

The opposite overcorrection. Same sweep, short label `r/a` (3 cells):

```
 95 |│▌   idle      impl   r/a                            ✓        default    -             │
 94 |│▌   idle      impl   r/a                           ✓        default    -             │
 92 |│▌   idle      impl   r/a                         ✓        default    -             │
 91 |│▌   idle      impl   r/a                        ✓        default    -             │
 90 |│▌   idle      r/a                              ✓        default    -             │
 89 |│▌   idle      r/a                             ✓        default    -             │
 88 |│▌   idle      r/a                            ✓        default    -             │
```

At `cw=90` the tag vanishes while the label needs 3 of its ~33 available columns — the
row is ~30 columns of trailing whitespace. Sweeping 80→45 confirms the tag never returns
at any width below 91 regardless of how short the label is. So on a fleet with short
agent names, `--task` renders nothing in the dashboard at any width under 91, even though
there is abundant room. Because `LW` is computed from pane width and pill count only, the
shed threshold is completely independent of the label it is protecting.

Pre-existing? No — this is new. Under the old `LW < 1` gate the tag was held here.
This fix trades a false-negative for a false-positive rather than making the gate correct.

## C3 — BLOCKING — TEST HOLE: 19b passes only because its own agent's name is short

19b is the new functional test and the commit's headline evidence. Its only tagged agent
is `repo/feat_one` (13 cells) — shorter than `LBLMIN=20`, so the shed always fires
*before* elision for that one label. The test therefore cannot observe the defect.

Proof by mutation. I added **one realistically-named agent** immediately before 19b's
sweep loop and changed **nothing else** — not the implementation, not the assertion:

```python
ins = ('spawn repo feature/very-long-branch-name-here --task impl >/dev/null 2>&1\n'
       'WLONG=$(wid_of "repo/feature_very-long-branch-name-here")\n'
       'tmux set -w -t "$WLONG" @agent_state idle 2>/dev/null\n')
s = s.replace('bad=""\nfor W in 120', ins + 'bad=""\nfor W in 120', 1)
```

The commit's own harness goes **RED against the shipped code**:
```
[M14-19b-long-label] killed:
    FAIL(19b): a task tag survived while its label was squeezed (tag must shed first):
      w=100:[│    idle      impl   …e_very-long-branch-name-here       ✓        default    -             │]
      w=95:[│    idle      impl   …y-long-branch-name-here       ✓        default    -             │]
```

This is the single strongest artifact in this report: the fix's own acceptance test
rejects the fix as soon as it is given a representative input.

## C4 — BLOCKING — TEST HOLE: 19b's threshold assertion and its vacuity

Three mutants, each run against the full harness (`mut.sh` copies the tree, mutates,
runs `test/agent-task-proof.sh`, reports `ALL PASS` = survived):

| Mutant | Mutation | Result |
|---|---|---|
| M6 | `LBLMIN=20` → `LBLMIN=13` | ***SURVIVED*** |
| M7 | `LBLMIN=20` → `LBLMIN=2` (≈ the shipped bug) | killed — FAIL(19b) |
| M12 | insert `exit 0` at `bin/fleet-dash` line 2 (dash never paints) | ***SURVIVED*** |
| M13 | 19b's `sleep 0.8` → `sleep 0` | ***SURVIVED*** |

- **M6** confirms 19b pins the threshold only to *its own* label length. Any `LBLMIN`
  from ~13 to 20 passes; the test cannot tell a correct gate from an arbitrary constant.
- **M12/M13** are the important ones: 19b builds `bad=""` and only appends on a matching
  captured line. **An empty capture is indistinguishable from a clean render.** With the
  dashboard replaced by `exit 0`, 19b reports PASS. The commit message itself records that
  19b "was vacuous on first write… and was only caught by that control" — but no positive
  control was added to prevent recurrence. I hit empty captures myself, unprompted, during
  this session's first sweep; on a loaded machine this test silently passes.

19b needs (a) a label-length-varying fixture and (b) an assertion that it captured a
non-empty row containing the expected agent at each width, before it may report PASS.

---

# FIX 2 — "`fleet ls | column -t` now aligns"

## NOT REFUTED behaviourally. I attacked the pipe hard and could not misalign it.

Matrix run, all through the sandbox, `fleet ls` piped every way in the brief:

```
=== raw (cat -A) ===
STATE^ITASK^IAGENT^IWINDOW^IIN-STATE$
idle^I-^Ictr/worker-none^Iadv_t:ctr/worker-none^I-$
idle^Irsch^Ictr/worker-tagged^Iadv_t:ctr/worker-tagged^I-$

=== bare column -t ===
STATE  TASK  AGENT              WINDOW                   IN-STATE
idle   -     ctr/worker-none    adv_t:ctr/worker-none    -
idle   rsch  ctr/worker-tagged  adv_t:ctr/worker-tagged  -

=== column -t -s TAB ===   (identical alignment)
=== --all | column -t ===  (identical alignment)
```

Also verified: zero agents (`no agents registered`, no header, degrades cleanly);
exactly one agent; all five task values in one fleet (`impl/plan/rsch/scr/test` — note
`scr` is correctly *trimmed*, not padded, so it does not widen the column); slash-bearing
names (`ctr/b-research`); a `--scratch` label containing a space; piping to `cat`, `head`
and `awk`; non-tty stdout. `awk -F'\t' '{print NF}'` returns 5 on every row including the
header in every case. **No counterexample found.**

## C5 — BLOCKING — TEST HOLE: the entire fix has zero test coverage

Mutant M1 deletes Blocker 2's fix in its entirety:
```sh
sed -i '/if (tg == "") tg = "-"/d' bin/fleet
```
```
[M1-revert-ls-placeholder] ***SURVIVED*** (harness still ALL PASS)
```

`grep -n 'column -t' test/agent-task-proof.sh` → **no matches**. The only `fleet ls`
assertions are 18a (header contains `TASK`) and 18b (row field count under `-F'\t'`),
and an *empty* tab-delimited field still counts, so both were already green before the
fix and stay green after reverting it. Per the coordinator's rule — a test that cannot
fail is a finding of the same severity as a broken feature — **BLOCKING**. A one-line
addition would close it: `"$FLEET" ls | column -t | awk 'NR==1{n=NF} NF!=n{bad=1} …'`.

## C6 — COSMETIC — pre-existing, out of scope

The `done`-row decoration still splits under bare `column -t`, because the reason text
contains spaces and is concatenated into the final field:
```
STATE  TASK  AGENT              WINDOW                   IN-STATE
done   -     ctr/worker-none    adv_t:ctr/worker-none    0m00s     (ready:  ready)
```
This affects only the trailing field, shifts no earlier column, and predates this commit
(`extra` is untouched by c8eb395). Noted for completeness; not attributable to this fix.

## C7 — COSMETIC — placeholder is not distinct from real data

`-` is also what the IN-STATE column prints when age is unknown, so a row can read
`idle   -   repo/x   s:repo/x   -` with `-` meaning two different things. Harmless in
practice; `·` or `--` would be unambiguous. Mentioned only because the brief asked.

---

# FIX 3 — "Case 16b now really calls inject_status_format"

## The vacuity IS genuinely fixed. But 16b is much weaker than it looks, and the Python twin is untested.

Positive controls first — the fix does what it claims:

| Mutant | Mutation | Result |
|---|---|---|
| M2 | `inject_status_format() { return 0; …}` | killed — `FAIL(16b): …did not append a task token: #I:#W` |
| M3 | token points at `@fleet_task` instead of `@fleet_task_tag` | killed — FAIL(16b), FAIL(16c) |
| M8 | write-site enum accepts anything (`…|scratch|*)`) | killed — FAIL(13,14,15a,15b,**16**,17a,17b,26a,26b,26c) |
| M9 | drop `record_task` (durable sidecar) | killed — FAIL(5b,22,24) |

M8 is the one that matters: `FAIL(16): status-bar format corruption reachable` proves
case 16's `#[`-injection guard is **now capable of failing**. The prior report's finding
that 16 passed vacuously is genuinely closed. Credit where due.

## C8 — BLOCKING — TEST HOLE: 16b cannot detect that the bar prints the raw enum word

Mutant M4 stamps the companion option with the **raw enum value** instead of the rendered
tag — the precise regression that `@fleet_task_tag` exists to prevent (CLAUDE.md:
*"a tmux format expands an option's value verbatim and cannot map `research`→`rsch`
itself, so pointing the token at `@fleet_task` would print the full enum word"*):

```sh
sed -i 's|@fleet_task_tag "$(task_tag_trim "$task")"|@fleet_task_tag "$task"|' bin/fleet
```
```
[M4-tag-holds-raw-enum] ***SURVIVED*** (harness still ALL PASS)
```

Why it survives: 16b's only tagged window is `W1` = `repo/feat_one`, spawned
`--task impl`. For `impl` — and for `plan` and `test` — the enum word and the 4-char tag
are **byte-identical**. The assertion is
`grep -qE 'rsch|impl|test|scr'`, so it matches either way. Only `research`→`rsch` and
`scratch`→`scr ` discriminate, and neither is used on the status-bar surface by any case.

Consequence: the status bar could render `research` (7 cells) instead of `rsch` (4) and
every test stays green — defeating the fixed-4-cell guarantee that CLAUDE.md gives as the
entire design rationale for the closed enum (`popup_fit_content`, `fit_left` and `hrule`
count codepoints, not cells, with no ASCII-fallback ladder). Fix: spawn the 16b fixture
with `--task research` and assert `rsch` present **and** `research` absent.

## C9 — MINOR — TEST HOLE: `fleetd`'s `heal_status_format` has no functional coverage

`bin/fleetd:269-284` is the Python twin that re-appends the same token on every sweep
(and is what actually keeps the bar healed after a theme switch). It is exercised by
nothing but `python3 -c compile` / `bash -n`:

| Mutant | Mutation | Result |
|---|---|---|
| M10 | delete the `@fleet_task_tag` heal branch outright (replace with `pass`) | ***SURVIVED*** |
| M11 | point fleetd's heal at `@fleet_task` (drift from the bash twin) | ***SURVIVED*** |

`grep -n 'heal_status_format' test/agent-task-proof.sh` → the string appears only in a
*comment* on line 386. The two implementations of the same injection can silently diverge.
MINOR rather than BLOCKING because the bash side is now covered and re-injects on every
`fleet up` — but it is the same defect class as the original 16b.

## C10 — MINOR — harness is not environment-hermetic

```sh
$ env -i PATH=/usr/bin:/bin HOME="$HOME" bash test/agent-task-proof.sh
  FAIL(11): fallback-path `fleet ls` did not show the impl tag:
  FAIL(18a): `fleet ls` header has no TASK column: no agents in this project
  FAIL(25): `fleet ls` printed a header and no rows
FAILURES
```
This is a false **RED**, not a false green, so it is much less dangerous than the
previously-reported socket fault — but "the harness passes" still depends on ambient
environment. Ordering/individual-case reordering: I found no order dependence; two
consecutive full runs were identical (`ALL PASS`).

---

# FIX 4 — "`--task generic` is hard-rejected and does not flip HAS_TASKS"

## NOT REFUTED. I could not get any rejected value stored through any path.

13-variant rejection sweep. For each, the window's `@fleet_task`, `@fleet_task_tag` and
the durable `<root>/.fleet/tasks/<wname>` sidecar were read back directly from tmux/disk:

```
--task generic               @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=1
-T generic                   @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=1
--task GENERIC               @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=1
--task Generic               @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=1
--task ' generic '           @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=1
--task 'impl '               @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=1
--task main                  @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=1
--task ''                    @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=0
--task '#[fg=red]'           @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=1
--task '#{q:#{pane_id}}'     @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=1
--task 'impl#[fg=red]'       @fleet_task=[] @fleet_task_tag=[] sidecar=no warn=1
--task research              @fleet_task=[research] @fleet_task_tag=[rsch] sidecar=YES:research
```

`--task=generic` (the `=` form) is hard-rejected earlier still, with a clear message and
**no spawn at all** — not silently swallowed:
```
$ fleet new repo e1 --bare --task=impl
fleet: unknown flag --task=impl
$ tmux list-windows -a -F '[#{window_name}]'
[base]
```

**Out-of-band poisoning, end to end.** Hand-crafted `<root>/.fleet/tasks/repo/p1`
sidecars, with the status bar already injected
(`#I:#W#{?@agent_glyph, #{@agent_glyph},}#{?@fleet_task_tag, #{@fleet_task_tag},}`):

```
### A. sidecar = '#[fg=red,bg=red]BOOM'
task-of  => []        ls TASK  => [-]        bar expn => [2:repo/p1]
### B. sidecar = 'generic'  (the just-removed enum member)
task-of  => []        ls TASK  => [-]
### C. fleet restore from a poisoned sidecar
after restore: @fleet_task=[] @fleet_task_tag=[]   bar expn => [2:repo/p1]
```

Every read path re-validates. `cmd_restore` launders the value through `task_of`
(validated) and then back through `cmd_new`'s write site (validated again). **A useful
side effect the commit does not claim: a stale `generic` sidecar left by the previous
version is now dropped on read, so there is no upgrade residue.** `HAS_TASKS` could not
be flipped by any rejected value on any surface.

A hand-set `@fleet_task_tag` tmux option *is* expanded without re-validation
(`bar expn on POISONED window => [2:repo/p1 #[fg=red,bg=blue]PWN]`), but (a) it is scoped
to that one window — the clean `base` window rendered `[1:base]`, so the "corrupts the
whole server" scenario does not materialise — and (b) setting it requires tmux write
access, which is already total control. **Not a finding.**

## C11 — MINOR — TEST HOLE: 26c's enum check is order-dependent

26c guards against the warning still advertising `generic` with
`case "$gmsg" in *"|generic"*) fail …`. That matches only when `generic` is *not first*
in the list. Mutant M5 re-advertises it in first position:

```sh
perl -pi -e 's/want: research/want: generic|research/' bin/fleet
```
```
[M5-warn-advertises-generic] ***SURVIVED*** (harness still ALL PASS)
```

The shipped message would read
`fleet: unknown --task X (ignored; want: generic|research|plan|impl|test|scratch)`
and 26c reports PASS. Same defect class as ac3af4d's unscoped grep. Fix: match the whole
enum string exactly rather than a positional substring.

---

# Summary table

| # | Finding | Fix | Class | Severity |
|---|---|---|---|---|
| C1 | Tag held while label elided, widths 113–91, labels ≥20 cells | 1 | **still broken** | **BLOCKING** |
| C2 | Tag shed at cw≤90 with ~30 columns to spare (short labels) | 1 | **newly broken by this fix** | MINOR |
| C3 | 19b goes RED on shipped code given one long agent name | 1 | test hole | **BLOCKING** |
| C4 | 19b survives `LBLMIN=13`; passes vacuously if dash never paints | 1 | test hole | **BLOCKING** |
| C5 | Deleting the `-` placeholder leaves harness ALL PASS | 2 | test hole | **BLOCKING** |
| C6 | done-row `(ready: …)` splits under bare `column -t` | 2 | pre-existing | COSMETIC |
| C7 | `-` placeholder collides with IN-STATE's `-` | 2 | new, trivial | COSMETIC |
| C8 | 16b cannot detect the bar printing the raw enum word | 3 | test hole | **BLOCKING** |
| C9 | `fleetd.heal_status_format` task branch deletable, still green | 3 | test hole | MINOR |
| C10 | Harness not hermetic under `env -i` (false RED) | 3 | pre-existing | MINOR |
| C11 | 26c's `*"\|generic"*` check is order-dependent | 4 | test hole | MINOR |

**Refutation succeeded** against fix 1 (behaviour, both directions) and against the
*coverage* of fixes 1, 2, 3 and 4.
**Refutation failed** — honestly and after real effort — against fix 2's alignment
behaviour, fix 3's core vacuity claim (case 16 is now genuinely capable of failing), and
fix 4's rejection surface, which held against 13 input variants and every out-of-band
storage path I could construct.

## What would close these

1. Make the shed gate label-aware: `(( LW < ${#label} ))`, or `max(LBLMIN, ${#label})` if
   a floor is still wanted. `LBLMIN=20` alone cannot be right for a variable-length label.
2. Give 19b a long-named fixture **and** a positive control asserting a non-empty captured
   row per width, so an unpainted dash is RED, not green.
3. Add one `fleet ls | column -t` alignment assertion (M1 must go red).
4. Spawn 16b's fixture with `--task research`; assert `rsch` present and `research` absent
   (M4 must go red).
5. Assert `fleetd.heal_status_format` functionally, or delete the duplicated logic in
   favour of shelling out to `fleet inject-status-format`.
6. Make 26c compare the whole enum list, not a positional substring.

# VERIFY-a — INDEPENDENT TESTER A, commit c8eb395

Verdict summary (detail per item below):

| # | Item | Verdict |
|---|------|---------|
| 1 | Dash label-vs-tag shed threshold | **PASS** (behaviour + new test is mutation-proven) |
| 2 | `fleet ls \| column -t` alignment | **PASS behaviour / FAIL coverage** — zero test guards it |
| 3 | Status-bar test 16b | **PARTIAL: 16b/16c PASS, case-16 `#[` guard STILL VACUOUS** |
| 4 | `--task generic` rejected | **PASS**, with a definitional caveat on "hard reject" |

Everything below was derived first-hand by execution. `TEST-a.md` / `TEST-b.md` were
not read. `TEST-VERDICT.md` was read only to enumerate the four defects.

---

## SAFETY

Every tmux invocation in every harness I wrote routes through a `tmux()` wrapper
defined in the same file as its call sites:

```sh
TMPROOT=$(mktemp -d /tmp/verifa-<kind>.XXXXXX)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"
mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"
[ "$SOCK" = "/tmp/tmux-$(id -u)/default" ] && { echo REFUSE >&2; exit 1; }
case "$SOCK" in "$TMPROOT"/*) ;; *) echo REFUSE >&2; exit 1;; esac
case "$SOCK" in /tmp/tmux-*/default) echo REFUSE >&2; exit 1;; esac
tmux(){ command tmux -S "$SOCK" "$@"; }
```

Three independent refusals: exact real-socket match, not-under-TMPROOT, and the
`/tmp/tmux-*/default` glob the brief mandates. `command tmux` prevents recursion.
Sandbox sockets used: `59224`–`59228` debug ports, sessions `vfa`/`vfl`/`vfg`/`vc16`/`vsc`.

No `fleet reap`, `fleet ready`, `fleet kill`, or `tmux kill-server` outside a sandbox
socket. Mid-run I verified the live server was untouched:

```
$ command tmux -S /tmp/tmux-1000/default list-sessions
pc: 6 windows (created Mon Jul 20 07:33:41 2026) (attached)
techweb2: 7 windows (created Mon Jul 20 09:15:09 2026) (attached)
techweb20: 3 windows (created Mon Jul 20 09:52:25 2026)
```

All scratch work under `/tmp/verifa.zx0Jqk/` (two `git clone`s of the worktree, at
`c8eb395` = `fix/` and `4edd86b` = `base/`). The `d26-verify` checkout was never
modified; `git worktree add` was deliberately avoided so the shared repo's worktree
list stayed untouched. Nothing committed. This report file is the only write into
the worktree.

---

## ITEM 1 — DASH LABEL-VS-TAG SHED THRESHOLD — **PASS**

Harness: `/tmp/verifa.zx0Jqk/sweep.sh`. Spawns one untagged (`ctr/worker-none`) and
one `--task research` (`ctr/worker-tagged`) agent in a sandboxed tmux, then for each
width creates a fresh `dashw` window running `bin/fleet-dash <session>`, sets
`window-size manual`, `resize-window -x $W -y 24`, settles, and `capture-pane -p`.

Readiness handling: up to 4 capture attempts per width, settle time doubling per
attempt, reset per width; a width is only reported once ≥2 agent rows have painted.
An all-whitespace capture would be reported `UNTESTED`. **No width in either sweep
required the UNTESTED path** — all 62 data points (31 widths × 2 trees) captured.

### (a) ORIGINAL BUG REPRODUCED on the pre-fix tree (4edd86b)

Reproduced, and across a far wider band than the one width `TEST-VERDICT` cited.
Raw captures:

```
===== WIDTH 72 =====
│▌   idle             …ctr/worker-none       ✓        default    -
│    idle      rsch   …ctr/worker-tagged       ✓        default 
===== WIDTH 80 =====
│▌   idle             …ker-none       ✓        default    -             │
│    idle      rsch   …r-tagged       ✓        default    -             │
===== WIDTH 85 =====
│▌   idle             …r/worker-none       ✓        default    -             │
│    idle      rsch   …worker-tagged       ✓        default    -             │
===== WIDTH 87 =====
│▌   idle             ctr/worker-none        ✓        default    -             │
│    idle      rsch   …r/worker-tagged       ✓        default    -             │
===== WIDTH 88 =====
│▌   idle             ctr/worker-none         ✓        default    -             │
│    idle      rsch   ctr/worker-tagged       ✓        default    -             │
```

Width 85 is byte-comparable to `TEST-VERDICT`'s capture (`…r/worker-none` /
`…worker-tagged` while `rsch` holds 5 columns). **The bug is reproducible and the fix
is falsifiable.** The failing band is widths **72–87 inclusive (16 consecutive
widths)**, not one sample point.

### (b) c8eb395 — label never elided while the tag is shown

```
===== WIDTH 80 =====   <- tag already shed; only the label elides
│▌   idle      ctr/worker-none        ✓        default    -             │
│    idle      …r/worker-tagged       ✓        default    -             │
===== WIDTH 81 =====   <- no tag, no elision
│▌   idle      ctr/worker-none         ✓        default    -             │
│    idle      ctr/worker-tagged       ✓        default    -             │
===== WIDTH 90 =====   <- last width with the tag shed
│▌   idle      ctr/worker-none                  ✓        default    -             │
│    idle      ctr/worker-tagged                ✓        default    -             │
===== WIDTH 91 =====   <- tag returns, label full
│▌   idle             ctr/worker-none            ✓        default    -             │
│    idle      rsch   ctr/worker-tagged          ✓        default    -             │
```

### (c) FULL BAND SWEEP, width 70–100, every width

A FAIL is any width where TAG-SHOWN=yes **and** LABEL-ELIDED=yes.

| Width | BASE tag | BASE elided | BASE | FIX tag | FIX elided | FIX |
|---|---|---|---|---|---|---|
| 70 | no | yes | ok | no | yes | ok |
| 71 | no | yes | ok | no | yes | ok |
| 72 | yes | yes | **FAIL** | no | yes | ok |
| 73 | yes | yes | **FAIL** | no | yes | ok |
| 74 | yes | yes | **FAIL** | no | yes | ok |
| 75 | yes | yes | **FAIL** | no | yes | ok |
| 76 | yes | yes | **FAIL** | no | yes | ok |
| 77 | yes | yes | **FAIL** | no | yes | ok |
| 78 | yes | yes | **FAIL** | no | yes | ok |
| 79 | yes | yes | **FAIL** | no | yes | ok |
| 80 | yes | yes | **FAIL** | no | yes | ok |
| 81 | yes | yes | **FAIL** | no | no | ok |
| 82 | yes | yes | **FAIL** | no | no | ok |
| 83 | yes | yes | **FAIL** | no | no | ok |
| 84 | yes | yes | **FAIL** | no | no | ok |
| 85 | yes | yes | **FAIL** | no | no | ok |
| 86 | yes | yes | **FAIL** | no | no | ok |
| 87 | yes | yes | **FAIL** | no | no | ok |
| 88 | yes | no | ok | no | no | ok |
| 89 | yes | no | ok | no | no | ok |
| 90 | yes | no | ok | no | no | ok |
| 91 | yes | no | ok | yes | no | ok |
| 92–100 | yes | no | ok | yes | no | ok |

**BASE: 16 failing widths (72–87). FIX: 0 failing widths. No UNTESTED widths.**

The fix also leaves a genuine safety margin rather than landing on the boundary: the
tag sheds at ≤90 while elision does not begin until ≤80, so widths 81–90 show neither
a tag nor a squeezed label — 10 widths of slack.

### (d) NEW TEST COVERAGE — is it a real render assertion?

**Yes.** c8eb395 splits old case 19 into:

- **19a** — the old source-grep, retained (grep string updated `LW < 1` → `LW < LBLMIN`).
  Still proves shed ORDER only; still structurally incapable of catching a threshold bug.
- **19b — NEW, and a genuine render + `capture-pane` assertion.** It spawns
  `bin/fleet-dash` in a real window, resizes across 120…80, captures, and fails if any
  captured line contains both `…` and one of `rsch|plan|impl|test|scr`.

**Can it catch a threshold regression? Proven yes, by two mutations:**

- **M5 — revert the gate** to `(( LW < 1 )) && (( task_show ))`:
  ```
  FAIL(19b): a task tag survived while its label was squeezed (tag must shed first):
    w=80:[│▌   idle      impl   …feat_one       ✓        default    -             │]
  ```
- **M5b — the decisive one.** Leave the source text `LW < LBLMIN` intact (so 19a's grep
  is still satisfied) and neuter only the value: `local LBLMIN=20` → `local LBLMIN=1`.
  This is behaviourally identical to the original bug while defeating the grep.
  ```
  FAIL(19b): a task tag survived while its label was squeezed (tag must shed first):
    w=80:[│▌   idle      impl   …feat_one       ✓        default    -             │]
  ```
  19a stayed green under M5b; **19b caught it alone.** 19b is therefore not parasitic on
  19a and does test the threshold, not the text.

**Minor residual note (not a defect):** 19b samples `120 110 100 95 90 85 80` — a coarse
grid, not every width. On the shipped code the shed point (90) and the elision point (80)
are both sample points, so it bites. A future change that narrowed the margin into a gap
between samples (e.g. failing only at 92–94) would slip through. Stepping the band by 1,
as my sweep does, would close that. Not blocking.

---

## ITEM 2 — `fleet ls | column -t` ALIGNMENT — **PASS behaviour, FAIL coverage**

Harness `/tmp/verifa.zx0Jqk/lstest.sh`, three fleet shapes, both trees.

### BASELINE 4edd86b — bug reproduced

**(i) no agent ever used `--task`** — every row misaligned:

```
--- raw (tabs shown as ->) ---
STATE->TASK->AGENT->WINDOW->IN-STATE
idle->->ctr/none-a->vfl:ctr/none-a->-
idle->->ctr/none-b->vfl:ctr/none-b->-
--- fleet ls | column -t   (the DOCUMENTED pipe) ---
STATE  TASK        AGENT           WINDOW  IN-STATE
idle   ctr/none-a  vfl:ctr/none-a  -       
idle   ctr/none-b  vfl:ctr/none-b  -       
```

Judged against the header: `ctr/none-a` lands under **TASK**, `vfl:ctr/none-a` under
**AGENT**, `-` under **WINDOW**, and **IN-STATE is empty**. Every field is one column
left of where it belongs, on 100% of rows.

**(ii) mixed** — the untagged rows shift, the tagged row does not, so the table is
internally inconsistent:

```
STATE  TASK        AGENT           WINDOW         IN-STATE
idle   ctr/none-a  vfl:ctr/none-a  -              
idle   ctr/none-b  vfl:ctr/none-b  -              
idle   rsch        ctr/tag-a       vfl:ctr/tag-a  -
```

**(iii) all tagged** — correct even pre-fix (no empty field to collapse):

```
STATE  TASK  AGENT      WINDOW         IN-STATE
idle   rsch  ctr/tag-a  vfl:ctr/tag-a  -
idle   impl  ctr/tag-b  vfl:ctr/tag-b  -
```

### FIX c8eb395 — all three shapes align

```
=== (i) NO agent ever used --task ===
raw:   idle->-->ctr/none-a->vfl:ctr/none-a->-
fleet ls | column -t:
STATE  TASK  AGENT       WINDOW          IN-STATE
idle   -     ctr/none-a  vfl:ctr/none-a  -
idle   -     ctr/none-b  vfl:ctr/none-b  -

=== (ii) MIXED ===
STATE  TASK  AGENT       WINDOW          IN-STATE
idle   -     ctr/none-a  vfl:ctr/none-a  -
idle   -     ctr/none-b  vfl:ctr/none-b  -
idle   rsch  ctr/tag-a   vfl:ctr/tag-a   -

=== (iii) ALL tagged ===
STATE  TASK  AGENT      WINDOW         IN-STATE
idle   rsch  ctr/tag-a  vfl:ctr/tag-a  -
idle   impl  ctr/tag-b  vfl:ctr/tag-b  -
```

Column-by-column against the header in all three: STATE=`idle`, TASK=`-`/`rsch`/`impl`,
AGENT=`ctr/…`, WINDOW=`vfl:ctr/…`, IN-STATE=`-`. Correct. The `column -t -s $'\t'`
control matches the bare pipe byte-for-byte on the fix tree — the two now agree, which
is the actual property `CLAUDE.md` claims.

### COVERAGE HOLE — this fix has NO test

Mutation **M8**: delete the fix line `if (tg == "") tg = "-"` from `cmd_ls`
(`bin/fleet:420`), reverting blocker 2 exactly. Mutation confirmed applied by diff.

```
----- MUTANT: M8-revert-ls-dash -----
  >>> STILL ALL GREEN <<<
```

**The entire proof harness passes against a tree with blocker 2 re-introduced.**
c8eb395 adds no assertion for it. The nearest case, 18b, is
`awk -F'\t' 'NF && NF!=n{c++}'` — a **tab**-delimited field count, which by construction
cannot observe whitespace-run collapsing, the actual failure mode. 18b passed pre-fix
and passes post-fix and is blind to the defect.

This is the same class the coordinator's expansion flags: an assertion whose subject
(bare `column -t`) is never actually invoked by the test.

---

## ITEM 3 — STATUS-BAR TEST 16b — **PARTIAL; case 16 remains vacuous**

### Baseline

`test/agent-task-proof.sh` on the fix tree reproduces the commit message's claim:
39 case labels, **ALL PASS** (1, 2a/b, 3a/b, 4, 5a/b, 6–12, 13, 14, 14b, 15a/b/c, 16,
16b, 16c, 17a/b, 18a/b, 19a, 19b, 20–25, 26a/b/c, syntax-fleet/dash/fleetd).

### (a) 16b now genuinely executes `inject_status_format` — CONFIRMED

The driver changed from `( . "$FLEET" >/dev/null 2>&1; inject_status_format )` to the
new internal subcommand `"$FLEET" inject-status-format` (dispatched at `bin/fleet:5223`).
Proved by observing the function's *effect* on a known-clean global format
(`/tmp/verifa.zx0Jqk/case16probe.sh`):

```
global window-status-format BEFORE : [#I:#W]
$ fleet inject-status-format
global window-status-format AFTER  : [#I:#W#{?@agent_glyph, #{@agent_glyph},}#{?@fleet_task_tag, #{@fleet_task_tag},}]

baseline window expanded = [3:baseline]
tagged   window expanded = [2:repo/feat_one impl]
```

The function body ran, both tokens landed, and the tagged window really renders `impl`
in the bar while the untagged one renders nothing. The old vacuity is gone.

### (b) MUTATION TESTS

| ID | Mutation | Expected | Result |
|---|---|---|---|
| M1 | `inject_status_format` → `{ return 0; …` (no-op) | 16b RED | **CAUGHT** |
| M3b | delete the `@fleet_task_tag` injection line, keep `@agent_glyph` | 16b RED | **CAUGHT** |
| M9b | remove the `case … *@fleet_task_tag*) ;;` idempotency guard (always append) | 16c RED | **CAUGHT** |
| M4b | append a literal `#[fg=red]` alongside the task token | **16 RED** | **SURVIVED — HOLE** |

Outputs:

```
----- MUTANT: M1-noop -----
  FAIL(16b): inject_status_format did not append a task token: #I:#W

----- MUTANT: M3b-drop-tasktag -----
  FAIL(16b): inject_status_format did not append a task token: #I:#W#{?@agent_glyph, #{@agent_glyph},}

----- MUTANT: M9b-nonidempotent -----
  FAIL(16c): inject_status_format is not idempotent across runs

----- MUTANT: M4b-hash-bracket -----
  >>> STILL ALL GREEN <<<
```

M4b's mutation was verified applied by diff (`bin/fleet:4112`), so the survival is real,
not a failed edit.

### Case 16's `#[`-injection guard is STILL VACUOUS — two independent proven causes

`TEST-VERDICT` item 2 required: *"re-run and re-baseline case 16 — the `#[`-injection
guard must be demonstrated capable of failing."* c8eb395 fixed 16b's driver but did not
touch case 16. It is still incapable of failing on the format-injection arm, for two
reasons I measured directly:

**Cause 1 — case 16 runs before anything injects.** Case 16 opens with
`"$FLEET" ls >/dev/null 2>&1   # force any status-format injection to have run`.
That comment is false — `fleet ls` does not call `inject_status_format`:

```
$ fleet ls >/dev/null 2>&1
global window-status-format after 'fleet ls': [#I:#W]
```

The first injection in the harness is 16b's `fleet inject-status-format`, ~10 lines
*later* in the file. So when case 16 counts `#[`, the format contains no fleet token at
all and there is nothing for the guard to find.

**Cause 2 — the baseline is derived from the broken path.** Even after injection, the
guard is structurally dead. `inject_status_format` writes the **global**
`window-status-format`, so any `#[` it adds is inherited by *every* window, the
`baseline` window included. Measured with the poison applied:

```
poisoned global: [#I:#W#{?@agent_glyph, #{@agent_glyph},}#[fg=red]#{?@fleet_task_tag, #{@fleet_task_tag},}]
baseline #[ count = 1
tagged   #[ count = 1
>>> case-16 verdict: tagged(1) > baseline(1) ?  NOT CAUGHT — baseline rose too
```

`n > base_n` can never hold for a global-format injection. This is precisely the
"baseline that is itself derived from the broken path" pattern in the coordinator's
brief. The relative-count design was adopted to avoid false positives from the user's
real theme, but it made the guard blind to the one attack it exists for.

**What case 16 *does* still test, and does test live:** its two per-window option
whitelists (`@fleet_task` and `@fleet_task_tag` must be in the enum). Those are real —
pre-existing case 15c catches removal of the read-side re-validation (mutation **M10**,
`task_of` short-circuited: `FAIL(15c): task_of must re-validate on read; a hand-edited
file yielded 'x#[fg=red]'`), and cases 15a/15b cover write-site `#[`/`#{` rejection.
So a poisoned *stored value* is still guarded. It is only the *rendered format* arm
that is dead.

**Stale enum in case 16.** Its whitelist still reads
`""|research|plan|impl|test|scratch|generic)` — `generic` was removed from the product
enum by this very commit but left in this test's accept-list. Case 16 would not flag a
stored `generic`. Cosmetic today (26a/b close that path) but it contradicts the commit.

---

## ITEM 4 — `--task generic` HARD-REJECTED — **PASS**, with a definitional caveat

Harness `/tmp/verifa.zx0Jqk/generic.sh`. Tested `generic`, `main`, and a control
`bogus`, on the fix tree.

### (a) What the code actually does

```
===== --task generic =====
exit code: 0
stderr: fleet: unknown --task generic (ignored; want: research|plan|impl|test|scratch)
window spawned: @1
@fleet_task     = ''
@fleet_task_tag = ''
sidecar .../tasks/ctr/w-generic : absent
task_of => ''

===== --task main =====
exit code: 0
stderr: fleet: unknown --task main (ignored; want: research|plan|impl|test|scratch)
window spawned: @2
@fleet_task     = ''
@fleet_task_tag = ''
sidecar .../tasks/ctr/w-main : absent
task_of => ''

===== --task bogus =====   (control)
exit code: 0  — identical warn-and-drop behaviour
@fleet_task = ''  @fleet_task_tag = ''  sidecar absent  task_of ''

===== sidecar tree =====
(no tasks dir)
```

**Reported exactly, since the brief asks:** this is **warn-and-drop, not a hard command
failure.** The spawn proceeds and `fleet new` exits **0**. `generic` is now treated
identically to `main` and to any unknown string.

Whether that satisfies "red's ruling was HARD reject" depends on what was meant:

- If "hard reject" = **the value must never be accepted or stored anywhere** — **met.**
  `@fleet_task`, `@fleet_task_tag`, the durable sidecar, and `task_of` are all empty; no
  `.fleet/tasks` directory is even created.
- If "hard reject" = **non-zero exit / refuse to spawn** — **not met.** It exits 0 and
  spawns.

I note the code's choice is internally consistent: it matches `--task main`'s long-standing
behaviour (pre-existing case 14), matches the repo's documented fail-silent house rule,
and matches case 13's explicit contract *"a bad `--task` must not prevent the spawn."*
Making `generic` alone exit non-zero would make it stricter than `main`, the
security-relevant value. **Flagging for the gate, not ruling it a defect.**

Usage text no longer advertises `generic`:
```
fleet new <repo> <br>  spawn agent … [--task|-T research|plan|impl|test|scratch]
```

### (b) HAS_TASKS is NOT flipped — captured, with a positive control

Dash at width 100 after all three rejected spawns. No task field on any row — the label
begins immediately after the state:

```
│▌   idle      ctr/w-bogus                                ✓        default    -             │
│    idle      ctr/w-generic                              ✓        default    -             │
│    idle      ctr/w-main                                 ✓        default    -             │
```

**Positive control** (essential — an absent column proves nothing if the detector is
broken): add one genuinely tagged agent and re-render. HAS_TASKS flips on, every row
gains the 4-char field, and the tag appears:

```
│▌   idle             ctr/w-bogus                         ✓        default    -             │
│    idle             ctr/w-generic                       ✓        default    -             │
│    idle             ctr/w-main                          ✓        default    -             │
│    idle      rsch   ctr/w-real                          ✓        default    -             │
```

Labels keep full width fleet-wide after the rejected attempts. Confirmed.

### Mutation tests on the new 26a/b/c

| ID | Mutation | Result |
|---|---|---|
| M6 | re-add `generic` to the write-site enum (`bin/fleet:1039`) | **CAUGHT** |
| M7 | re-add `generic` to the warning **text only** (write site still rejects) | **CAUGHT** |
| M11 | re-add `generic` to the **dash** read-side validation (`bin/fleet-dash:225`) | **SURVIVED — HOLE** |

```
----- MUTANT: M6-generic-writesite -----
  FAIL(26a): --task generic must be rejected; got 'generic'
  FAIL(26b): rejected 'generic' left state behind: tag='' file=…/tasks/repo/feat_generic
  FAIL(26c): no closed-enum warning for --task generic: ''

----- MUTANT: M7-generic-warntext -----
  FAIL(26c): the warning still advertises 'generic': fleet: unknown --task generic (ignored; want: research|plan|impl|test|scratch|generic)

----- MUTANT: M11-dash-generic -----
  >>> STILL ALL GREEN <<<
```

M6 and M7 are well-targeted — notably M7 shows 26c is scoped tightly enough to catch a
*documentation-only* regression, which is the good version of the pattern.

**M11 is a coverage hole, not a behaviour defect.** c8eb395 correctly removed `generic`
from `bin/fleet-dash`'s `prime_task` enum as well, but no test covers that arm. The path
is reachable: the sidecar is a plain file that `CLAUDE.md` documents as durable and
hand-editable, and the dash reads it directly. I verified the **shipped** code handles it
correctly — hand-writing `generic` into `<root>/.fleet/tasks/ctr/worker-two`:

```
fleet task-of  => ''
fleet ls:
STATE  TASK  AGENT            WINDOW               IN-STATE
idle   -     ctr/worker-none  vsc:ctr/worker-none  -
idle   -     ctr/worker-two   vsc:ctr/worker-two   -
DASH @ width 100:
│▌   idle      ctr/worker-none                            ✓        default    -             │
│    idle      ctr/worker-two                             ✓        default    -             │
```

Correct on both surfaces, HAS_TASKS stays off. But a regression in `bin/fleet-dash:225`
alone would ship silently — and its consequence is exactly the harm item 4 was raised to
close (HAS_TASKS flipped fleet-wide to render nothing).

---

## Mutation-coverage summary — every new/changed assertion in c8eb395

Per the coordinator's expansion, for each assertion: what *should* break it, and does it.

| Assertion | Mutation that should break it | Broke it? |
|---|---|---|
| 16b (bar shows the tag) | M1 no-op `inject_status_format` | **YES** |
| 16b | M3b drop the `@fleet_task_tag` token, keep glyph | **YES** |
| 16c (idempotency) | M9b remove the idempotency guard | **YES** |
| 16 (`#[` injection guard) | M4b inject a literal `#[` into the format | **NO — HOLE** |
| 19a (shed order grep) | M5 revert gate text | YES (grep-level only) |
| 19b (render invariant) | M5 revert gate to `LW < 1` | **YES** |
| 19b, independent of 19a | M5b `LBLMIN=20` → `1` (grep still satisfied) | **YES** |
| 26a/26b (generic not stored) | M6 re-add `generic` to write-site enum | **YES** |
| 26c (warning text) | M7 re-add `generic` to warning text only | **YES** |
| blocker-2 `ls` `-` placeholder | M8 delete `if (tg == "") tg = "-"` | **NO — HOLE (no assertion exists)** |
| dash read-side enum | M11 re-add `generic` to `fleet-dash:225` | **NO — HOLE** |
| (pre-existing) 15c read revalidation | M10 short-circuit `task_of` | YES |

**Three holes: M4b (case 16), M8 (no ls coverage at all), M11 (dash enum arm).**

### Methodology disclosure

My first mutation batch reported M3/M4/M9 as "STILL ALL GREEN". That was **my** bug, not
the harness's: `perl -0pi -e 's/…/…/'` exits 0 when the pattern does not match, so
`mutate.sh`'s `eval "$*" || exit 2` could not detect a no-op edit. I diffed every mutant
against the source, found M3/M4/M9 had not applied, and re-ran them as M3b/M4b/M9b with
line-anchored Python edits carrying an `assert` on the anchor text. Every mutation result
reported above was diff-verified as actually applied. M8's application was likewise
diff-confirmed before I called it a hole.

---

## What I could NOT test, and why

- **`fleetd`'s `heal_status_format`** (the Python twin of `inject_status_format`). Not
  exercised — it re-runs the same injection on the daemon sweep, so if the shipped
  injection is correct it heals correctly, but I did not drive the daemon path. Note it
  would be affected by the same dead case-16 guard.
- **Real terminal appearance with an attached client.** All status-bar evidence is via
  `#{E:window-status-format}` expansion and `capture-pane`, never a human-visible bar.
- **Widths outside 70–100** on the dash. The brief specified this band; base showed the
  tag correctly gone at 70–71, so the low end is bounded, but I did not sweep <70 or >100.
- **`fleet reap` / `fleet restore` end-to-end** outside the harness's own cases 21–25.
- **Sub-orch / dispatch-layer spawns carrying `--task`.**
- **Non-ASCII or multi-byte labels** interacting with `fit_left`'s codepoint counting.
- **`main` branch / ac3af4d.** Per the coordinator's instruction, c8eb395 was judged as
  committed; no merge was performed or considered.
- **No approved spec.** `PLAN.md` / `SYNTHESIS.md` remain absent from this worktree, so
  conformance is checkable only against `CLAUDE.md` prose and the commit message.

## Other material findings

1. **`CLAUDE.md` is now stale on two points.** It still documents the dash task field as
   *"shed **first** in the width ladder"* without mentioning the `LBLMIN=20` label floor
   that is the actual mechanism, and the `fleet ls` paragraph still explains
   `task_tag_trim` as emitting *"unset → **empty**, not 4 spaces"* — the shipped code now
   emits `-`, not empty. The rationale sentence about `column -t` mis-alignment now
   describes a fixed bug as if it were current behaviour. Worth a doc pass.
2. **Case 16's accept-list still contains `generic`**, contradicting the enum this commit
   closed (see item 3).
3. **19b's coarse sample grid** (120/110/100/95/90/85/80) rather than a unit step — noted
   under item 1(d).
4. The three blockers' *behaviour* fixes are all real and all reproduce. The weakness in
   this commit is concentrated in *evidence*, exactly as the previous round's was: two of
   the three blocker fixes (ls alignment, `#[` guard) ship without an assertion that can
   fail if they regress.

---

*Tester A, independent. Nothing committed. Sandbox roots `/tmp/verifa.zx0Jqk`,
`/tmp/verifa-{sweep,ls,gen,c16,sc}.*` — all disposable.*

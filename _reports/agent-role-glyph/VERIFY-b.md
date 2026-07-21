# VERIFY-b — independent verification of c8eb395

**Tester:** INDEPENDENT TESTER B. I did not write this code. I did not read `VERIFY-a.md`.
**Subject:** `c8eb395` "fix(task): d26 loop 1 — label-vs-tag threshold, ls alignment, real status-bar test"
**Method:** execution and capture only. Every claim below is backed by a command and its raw output.
Nothing is accepted because the diff "looks right".

---

## Verdict summary

| # | Item | Verdict |
|---|---|---|
| 1a | Reproduce ORIGINAL blocker-1 bug on pre-fix code | **PASS** (reproduced, deterministic, band 72–87) |
| 1b | Fixed on c8eb395 (short labels) | **PASS** |
| 1c | Sweep 70..100 + label-length axis | **FAIL** — fix is incomplete; long labels regress the identical defect at 91–110 |
| 1d | New test 19b quality | **PARTIAL** — a genuine render+capture assertion, but blind to the failing regime; 19a has a dead grep |
| 2 | `fleet ls \| column -t` alignment | **PASS** behaviourally / **FAIL** on coverage — the fix works and has zero tests |
| 3a | 16b genuinely runs `inject_status_format` | **PASS** |
| 3b | Mutation testing | **PARTIAL** — 16b/16c load-bearing; case 16's `#[` guard is doubly vacuous; `heal_status_format` has zero coverage |
| 4a | `--task generic` hard-rejected | **FAIL vs red's ruling** — it is warn-and-drop with exit 0, not a hard reject |
| 4b | HAS_TASKS not flipped after a rejected task | **PASS** (byte-identical dash) |

**Net: the commit fixes what it claims for the cases it tests, but blocker 1 is only
half-fixed, blocker 2's fix is untested, the status-bar injection guard still cannot
fail, and item 4 does not implement the ruling as stated.**

---

## Safety statement

Every tmux invocation in this verification went through a wrapper defined in the same
file as its calls:

```sh
TMPROOT=$(mktemp -d /tmp/vbrig.XXXXXX)
export TMUX_TMPDIR="$TMPROOT/tsock"
mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"
chmod 700 "$TMUX_TMPDIR" "$TMUX_TMPDIR/tmux-$(id -u)"
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"

if [ "$SOCK" = "/tmp/tmux-$(id -u)/default" ]; then echo "REFUSE: real socket"; exit 1; fi
case "$SOCK" in /tmp/tmux-*/default) echo "REFUSE: matches live pattern"; exit 1 ;; esac
case "$SOCK" in "$TMPROOT"/*) ;; *) echo "REFUSE: not under TMPROOT"; exit 1 ;; esac

tmux() { command tmux -S "$SOCK" "$@"; }
```

Three independent refusals: exact live-socket match, the `/tmp/tmux-*/default` glob, and
a containment check under `$TMPROOT`. `kill-server` in cleanup is always
`command tmux -S "$SOCK" kill-server` — never bare.

The live `pc` server (`/tmp/tmux-1000/default`, and `/tmp/tmux-1000/fltprobe`) was never
addressed. `fleet reap`, `fleet ready`, `fleet kill` were never run outside a sandbox.
All scratch work lived under `mktemp -d`; the only file written into the worktree is this
report. Nothing was committed.

Full rig: `scratchpad/vb/rig.sh`.

Three trees were extracted with `git archive` into scratch (the main checkout was never
disturbed):

```
git archive 4edd86b | tar -x -C $S/pre    # pre-fix (c8eb395's parent)
git archive c8eb395 | tar -x -C $S/post   # under test
git archive ff9da68^ | tar -x -C $S/base  # pre-feature baseline
```

---

## ITEM 1 — dash label-vs-tag shed threshold

### 1(a) Reproducing the ORIGINAL bug — **REPRODUCED**

The fix is falsifiable. On `4edd86b` (`bin/fleet-dash:1047`, gate `LW < 1`), one tagged
(`--task research`) + one untagged agent, sandboxed tmux, `capture-pane -p`:

```
===== WIDTH 120 =====
│▌   idle             ctr/worker-none                                         ✓        default    -             │
│    idle      rsch   ctr/worker-tagged                                       ✓        default    -             │
===== WIDTH 90 =====
│▌   idle             ctr/worker-none           ✓        default    -             │
│    idle      rsch   ctr/worker-tagged         ✓        default    -             │
===== WIDTH 85 =====
│▌   idle             …r/worker-none       ✓        default    -             │
│    idle      rsch   …worker-tagged       ✓        default    -             │
```

At width 85 both labels are left-ellipsised while `rsch` still holds its 5 columns —
exactly the documented violation. Confirmed against the brief's stated expectation.

### 1(b) / 1(c) Full sweep, widths 70..100 inclusive, EVERY width

Rule: **any width where a tag is present AND a `…` appears in a label is a FAIL.**

#### Axis 1 — short labels (`ctr/worker-none`, `ctr/worker-tagged` = 17 cells)

**PRE-FIX (4edd86b):**

| width | tag? | elided? | verdict |
|---|---|---|---|
| 70 | no | yes | ok |
| 71 | no | yes | ok |
| 72–87 | **yes** | **yes** | **FAIL** (16 consecutive widths) |
| 88–100 | yes | no | ok |

Representative raw rows:

```
w=85  │▌   idle             …r/worker-none       ✓        default    -             │
      │    idle      rsch   …worker-tagged       ✓        default    -             │
w=80  │▌   idle             …ker-none       ✓        default    -             │
      │    idle      rsch   …r-tagged       ✓        default    -             │
w=73  │▌   idle             …e       ✓        default    -             │
      │    idle      rsch   …d       ✓        default    -             │
```

**POST-FIX (c8eb395):** zero FAILs across all 31 widths. Tag sheds at ≤90, present ≥91,
and no width shows tag + ellipsis together.

```
w=90  │▌   idle      ctr/worker-none                  ✓        default    -             │
      │    idle      ctr/worker-tagged                ✓        default    -             │      <- tag shed
w=91  │▌   idle             ctr/worker-none            ✓        default    -             │
      │    idle      rsch   ctr/worker-tagged          ✓        default    -             │      <- tag held, no ellipsis
```

So on the short-label axis the fix is real and complete. **No capture failed; there are
no UNTESTED widths on this axis** (my rig retries up to 10× at 0.7s, which eliminated the
empty-capture flakiness earlier testers reported).

#### Axis 2 — LONG branch names — **THE FIX IS INCOMPLETE**

The brief asked me to probe agent-name length as a second axis because the elision
threshold depends on `len(label)`. It does, and `LBLMIN` does not.

Labels `ctr/very-long-feature-branch-name-none` / `-tagged` (40 cells), same rig,
**c8eb395**:

| width | tag? | elided? | verdict |
|---|---|---|---|
| 70–90 | no | yes | ok (tag already shed) |
| **91–110** | **yes** | **yes** | **FAIL — 20 consecutive widths** |
| 111–135 | yes | no | ok |

Raw rows inside the failing band, on the **shipped** code:

```
w=100 │▌   idle             …ong-feature-branch-name-none       ✓        default    -             │
      │    idle      rsch   …g-feature-branch-name-tagged       ✓        default    -             │
w=95  │▌   idle             …eature-branch-name-none       ✓        default    -             │
      │    idle      rsch   …ture-branch-name-tagged       ✓        default    -             │
w=91  │▌   idle             …re-branch-name-none       ✓        default    -             │
      │    idle      rsch   …-branch-name-tagged       ✓        default    -             │
```

This is the identical defect blocker 1 described — a 4-char badge held while the identity
it labels is truncated — merely relocated to a different width band.

**Mechanism, measured:** the failure band width is exactly `len(label) − LBLMIN`.

- 40-cell label, `LBLMIN=20` → band 91..110 = 20 widths. ✔
- 17-cell label, `LBLMIN=20` → `17 − 20 = −3` → no band. ✔ (this is why axis 1 is clean)

`fit_left` elides when `LW < len(label)`; the shed gate fires at `LW < LBLMIN` where
`LBLMIN` is the **constant 20**. Wherever `len(label) > LBLMIN` there is a band of width
`len(label) − LBLMIN` in which the tag is held and the label is already truncated. The
old gate was the degenerate case `LBLMIN = 1`.

The commit message's own reasoning ("Below ~20 cells the left-ellipsis eats the repo and
most of the branch") justifies 20 as a *floor for readability*, which is a legitimate but
**different** invariant from the one `CLAUDE.md` states and 19b asserts ("a row may show a
tag or a squeezed label, never both"). The code satisfies the floor; it does not satisfy
the stated invariant. A correct gate for the stated invariant is `LW < ${#label}` (with
`LBLMIN` retained only as an additional floor).

Real-world relevance: fleet's own window names are `<repo>/<branch>`. This worktree's own
agent label is `fleet/d26-verify` (16) — under the floor — but `fleet/agent-role-glyph`
(22) and any `repo/feat_something-descriptive` exceeds 20 routinely. This is not an exotic
input.

### 1(d) Is the new test case a real render+capture assertion, and can it catch a threshold regression?

**It is a real render+capture assertion — not a source-grep.** 19b spawns a real dash in a
real tmux window per width, resizes, `capture-pane -p`s, and asserts on rendered text
(`test/agent-task-proof.sh`, the `for W in 120 110 100 95 90 85 80` loop). That is a
genuine improvement over old case 19 and it does address the structural criticism.

**It can catch a threshold regression — for short labels.** Negative-controlled by
mutation (details in item 3):

```
### MUTANT: m5_gate_back_to_lw1     (revert to the shipped-buggy `LW < 1`)
    >>> RED: FAIL(19b): a task tag survived while its label was squeezed:
             w=80:[│▌   idle      impl   …feat_one       ✓        default    -             │]

### MUTANT: m6_lblmin_zero          (LBLMIN=0)
    >>> RED: FAIL(19b): ... w=80:[│▌   idle      impl   …feat_one ...]
```

So the implementer's claimed negative control is genuine — I reproduced it.

**But 19b is blind to the regime where the shipped code actually fails.** Its fixtures are
`repo/feat_one` and `repo/feat_two` — 13 cells, below `LBLMIN=20`. I instrumented 19b to
dump every capture and confirmed only these two rows ever render:

```
### 19b CAPTURE w=100 bytes=2399 ###
  19bCAP| │▌   idle      impl   repo/feat_one                       ✓        default    -             │
  19bCAP| │    idle             repo/feat_two                       ✓        default    -             │
```

I then added one realistically-named agent to the harness immediately before the 19b
block, on the **unmodified shipped `bin/fleet-dash`**:

```sh
spawn repo very-long-feature-branch-name --task impl
WLONG=$(wid_of "repo/very-long-feature-branch-name")
tmux set -w -t "$WLONG" @agent_state idle      # required, or the dash never lists it
```

Result — **the shipped code fails 19b's own invariant**:

```
  PASS(19a)
  [probe] long agent window=@11 label=repo/very-long-feature-branch-name (35 cells)
  FAIL(19b): a task tag survived while its label was squeezed (tag must shed first):
    w=100:[│    idle      impl   …ery-long-feature-branch-name       ✓        default    -             │]
    w=95:[│    idle      impl   …ong-feature-branch-name       ✓        default    -             │]
```

**19b passes only because its own fixture labels are shorter than the floor it gates on.**
That is a fixture-selection hole, not a logic hole — the assertion is correct, its inputs
are not adversarial. One long-named fixture converts 19b into a test that catches the
remaining defect.

(First attempt at this probe passed spuriously because the extra agent had no
`@agent_state` and so was invisible to the daemon-down dash fallback — worth recording,
because it is the same "the subject was never actually invoked" trap 19b itself fell into
on first write.)

### 1(d)-bis — case 19a contains a dead grep — **HOLE**

```sh
lad=$(grep -n 'LW < LBLMIN' "$DASH" | head -1 | cut -d: -f1)
tdrop=$(grep -n 'task_show=0' "$DASH" | head -1 | cut -d: -f1)
cdrop=$(grep -n 'cost_show=0' "$DASH" | head -1 | cut -d: -f1)
if [ -n "$tdrop" ] && [ -n "$cdrop" ] && [ "$tdrop" -lt "$cdrop" ]; then pass 19a
```

`$lad` is computed and used **only inside the failure message**. It is never asserted.
Proved by mutation m5: the gate was reverted to `LW < 1`, so the `LW < LBLMIN` grep
matched nothing and `lad` was empty — and **19a still passed**:

```
### MUTANT: m5_gate_back_to_lw1
    >>> RED:  FAIL(19b) ...        <- only 19b went red; 19a stayed GREEN
```

The grep that names the new gate proves nothing about the new gate.

---

## ITEM 2 — `fleet ls | column -t` alignment

Real piped output on `c8eb395`, compared against the same capture on `ff9da68^`.
Five scenarios, `--all` included.

### (i) A fleet that has NEVER used `--task` — the worst case

**`ff9da68^` (baseline):**
```
STATE  AGENT      WINDOW          IN-STATE
idle   ctr/alpha  vb_t:ctr/alpha  -
idle   ctr/beta   vb_t:ctr/beta   -
```
**`c8eb395`** — raw (tabs shown as `->`), then the documented pipe:
```
STATE->TASK->AGENT->WINDOW->IN-STATE
idle->-->ctr/alpha->vb_t:ctr/alpha->-
idle->-->ctr/beta->vb_t:ctr/beta->-

STATE  TASK  AGENT      WINDOW          IN-STATE
idle   -     ctr/alpha  vb_t:ctr/alpha  -
idle   -     ctr/beta   vb_t:ctr/beta   -
```
`idle`→STATE, `-`→TASK, `ctr/alpha`→AGENT, `vb_t:ctr/alpha`→WINDOW, `-`→IN-STATE. **Correct.**

### (ii) Mixed
```
STATE  TASK  AGENT      WINDOW          IN-STATE
idle   -     ctr/alpha  vb_t:ctr/alpha  -
idle   rsch  ctr/beta   vb_t:ctr/beta   -
idle   -     ctr/gamma  vb_t:ctr/gamma  -
```
**Correct** — tagged and untagged rows align with each other and with the header.

### (iii) All tagged
```
STATE  TASK  AGENT      WINDOW          IN-STATE
idle   impl  ctr/alpha  vb_t:ctr/alpha  -
idle   rsch  ctr/beta   vb_t:ctr/beta   -
```
**Correct.**

### Unusual inputs

Very long branch name:
```
STATE  TASK  AGENT                                     WINDOW                                         IN-STATE
idle   impl  ctr/a-very-long-feature-branch-name-here  vb_t:ctr/a-very-long-feature-branch-name-here  -
idle   -     ctr/short                                 vb_t:ctr/short                                 -
```

Branch name containing slashes (`feat/nested/deep` → `feat_nested_deep`):
```
STATE  TASK  AGENT                 WINDOW                     IN-STATE
idle   test  ctr/feat_nested_deep  vb_t:ctr/feat_nested_deep  -
idle   -     ctr/plain             vb_t:ctr/plain             -
```

`fleet ls --all | column -t` produced byte-identical column placement in every scenario.

**Item 2 behaviour: PASS.** The `-` placeholder resolves blocker 2 in all cases I could
construct, including the never-tagged fleet that was the worst case.

**Item 2 coverage: FAIL — see the m13/m14 holes in item 3.** The fix has no test.

---

## ITEM 3 — status-bar test case 16b

### 3(a) Does the test now genuinely run `inject_status_format`'s body? — **YES**

Instrumented `bin/fleet` by inserting a trace as the first statement of the function body,
then drove it exactly as the test now does:

```
$ $S/tr2/bin/fleet inject-status-format
  TRACE: BODY ENTERED (pid 3026175)
```

Confirmed by effect as well — the token reaches the global format:

```
[probe] GLOBAL fmt AFTER 16b =
  [#I:#W#{?@agent_glyph, #{@agent_glyph},}#{?@fleet_task_tag, #{@fleet_task_tag},}]
```

**The blocker-2 fix is real: the status-bar surface now has functional coverage.**

### 3(a)-bis — the committed *diagnosis* of the pre-fix failure is wrong (the fix is still correct)

The commit message and TEST-VERDICT both state that
`( . "$FLEET"; inject_status_format )` never called the function because `bin/fleet`'s
`*) print_usage` branch exited the subshell. **That is not what happens.** `print_usage`
is a plain `cat <<EOF` with no `exit`, so control returns and the function *is* called. I
traced it inside the real harness:

```
TRACE harness-side type-tmux: function
TRACE-ISF-BODY-ENTERED
  FAIL(16b): inject_status_format did not append a task token: #I:#W
```

Body entered, token still absent. The **actual** mechanism is a variable collision:

```
bin/fleet:17:  SOCK="$RUNTIME_DIR/fleet.sock"
```

Sourcing `bin/fleet` overwrites the harness's `SOCK`, so the harness's own
`tmux() { command tmux -S "$SOCK" ...; }` starts addressing the **fleetd** socket:

```
TRACE type-tmux: function | show-g=[error connecting to /tmp/.../run/fleet.sock (No such file or directory)]
```

Every tmux call inside the sourced subshell failed silently, so nothing was written.
I also tested the claimed tty hang under `script -qec ... /dev/null` with a 20s timeout:
it **exited** and entered the body — no hang reproduced in this environment.

Net: the conclusion ("16b proved nothing") was right, the fix (a separate process via an
internal subcommand) is right and immune to both mechanisms, but the recorded root cause
is inaccurate. Worth correcting in the record so nobody "fixes" `print_usage`.

### 3(b) MUTATION TESTING

Runner: `scratchpad/vb/mutate.sh` — each mutant is applied to a fresh copy of `c8eb395`,
the full harness runs, and every RED case is recorded. A mutant applied but leaving the
suite green is a **HOLE**. Every mutation was verified to actually change the file
(anchor-miss aborts).

Per the expanded brief, this covers **every new or changed assertion in c8eb395**, not
just the status-bar one, and for each I state what mutation *should* fail it and whether
it *did*.

| # | Mutation | Target assertion | Should fail? | Did fail? | Result |
|---|---|---|---|---|---|
| m1 | `inject_status_format` → immediate `return 0` (no-op) | 16b | yes | **yes** | caught |
| m2 | wrong token: `@fleet_task` instead of `@fleet_task_tag` | 16b | yes | **yes** (16b + 16c) | caught |
| m3 | drop `@fleet_task_tag` append, keep `@agent_glyph` | 16b | yes | **yes** | caught |
| m4 | emit a raw unvalidated `#[fg=red]` into the format | 16 (`#[` guard) | yes | **NO** | **HOLE** |
| m11 | append unconditionally (non-idempotent) | 16c | yes | **yes** | caught |
| m5 | revert gate to `LW < 1` | 19a + 19b | both | **19b only** | 19a is a **HOLE** |
| m6 | `LBLMIN=0` | 19b | yes | **yes** | caught |
| m7 | swap shed order (task after cost) | 19a | yes | **yes** | caught |
| m8 | re-accept `generic` at the write site | 26a/b/c | yes | **yes** (all three) | caught |
| m9 | warning text re-advertises `generic` | 26c | yes | **yes** | caught |
| m10 | re-accept `generic` in `task_of` read-side only | (none) | yes | **NO** | **HOLE** |
| m13 | delete the `-` placeholder (revert blocker-2 fix) | (none) | yes | **NO** | **HOLE** |
| m14 | placeholder is a space instead of `-` | (none) | yes | **NO** | **HOLE** |
| m15 | drop the TASK column from `cmd_ls` entirely | 11, 18b | yes | **yes** | caught |
| m16 | `fleetd.heal_status_format()` → `return` (disabled) | (none) | yes | **NO** | **HOLE** |

Raw output for the caught mutants (abridged):

```
### MUTANT: m1_isf_noop
    >>> RED: FAIL(16b): inject_status_format did not append a task token: #I:#W

### MUTANT: m2_isf_wrong_token
    >>> RED: FAIL(16b): ... #I:#W#{?@agent_glyph,...}#{?@fleet_task, #{@fleet_task},}
             FAIL(16c): inject_status_format is not idempotent across runs

### MUTANT: m3_isf_drop_tasktag_keep_glyph
    >>> RED: FAIL(16b): ... token: #I:#W#{?@agent_glyph, #{@agent_glyph},}

### MUTANT: m11_isf_nonidempotent
    >>> RED: FAIL(16c): inject_status_format is not idempotent across runs

### MUTANT: m7_shed_order_swapped
    >>> RED: FAIL(19a): task must be dropped before cost (task@1062 cost@1061)

### MUTANT: m8_generic_accepted_writesite
    >>> RED: FAIL(26a): --task generic must be rejected; got 'generic'
             FAIL(26b): rejected 'generic' left state behind: file=.../tasks/repo/feat_generic
             FAIL(26c): no closed-enum warning for --task generic: ''

### MUTANT: m9_generic_in_warning_text
    >>> RED: FAIL(26c): the warning still advertises 'generic'

### MUTANT: m15_drop_task_column_entirely
    >>> RED: FAIL(11): fallback-path `fleet ls` did not show the impl tag
             FAIL(18b): 2 row(s) do not match the header's 5 fields
```

**16b, 16c, 19b, 26a, 26b, 26c and 19a's order-check are all genuinely load-bearing.**
That is a real improvement and I want it on the record alongside the holes.

#### HOLE 1 — case 16's `#[`-injection guard still cannot fail (m4)

This is the load-bearing safety assertion of the entire feature: the closed enum exists
*because* a stray `#[` would corrupt `window-status-format` for the whole tmux server.
I made `inject_status_format` emit a raw, unvalidated `#[fg=red]` directly into the global
format. **The suite stayed ALL GREEN.**

Two independent causes, both instrumented:

**Cause A — ordering.** Case 16 runs *before* 16b performs the injection:
```
[probe16-pre]  GLOBAL fmt at case16 time = [#[fg=#6d7db6] #I:#W ]
[probe16-post] GLOBAL fmt AFTER 16b      = [#I:#W#{?@agent_glyph,...}#[fg=red]#{?@fleet_task_tag,...}]
```
At case-16 time the task token has never been appended. The test's own comment
(`"$FLEET" ls >/dev/null 2>&1  # force any status-format injection to have run`) is
factually wrong — `fleet ls` does **not** run `inject_status_format`. The guard measures a
format that has never been through the code path it claims to guard.

**Cause B — the baseline is derived from the poisoned path.** Even after the injection,
the counts cancel:
```
[probe16-post] W1 expands to 1 sharp-brackets; WBASE 1
```
`window-status-format` is a **global** option, so an injected `#[` appears in *every*
window including the baseline window. Case 16 compares each window's `#[` count against
that baseline, so a global-scope injection is invisible by construction. Only a
*per-window* poison (a bad `@fleet_task_tag` value) could ever move the delta.

This is exactly the defect class the coordinator flagged from `ac3af4d`: an assertion
whose baseline is computed from the broken path. The correction that introduced the
baseline (deviation 5 in TEST-VERDICT) was well-intentioned and remains uncaught.

Minor related staleness: case 16's own accepted set still reads
`""|research|plan|impl|test|scratch|generic)` — it would not flag a stored `generic` as
poison even though `generic` is now rejected everywhere else.

#### HOLE 2 — blocker 2's own fix is entirely untested (m13, m14)

Deleting `if (tg == "") tg = "-"` — i.e. **reverting the blocker-2 fix outright** — leaves
the harness ALL GREEN. So does replacing `-` with a space, which is precisely the
collapsing value the fix exists to avoid.

These are not no-op mutations. Both fully reproduce the original misalignment:

```
########## m13_drop_ls_placeholder ##########
=== [mixed] fleet ls | column -t ===
STATE  TASK       AGENT           WINDOW         IN-STATE
idle   ctr/alpha  vb_t:ctr/alpha  -                          <- agent name under TASK
idle   rsch       ctr/beta        vb_t:ctr/beta  -
idle   ctr/gamma  vb_t:ctr/gamma  -

########## m14_ls_placeholder_is_space ##########   (identical breakage)
```

Case 18b compares each row's field count to the header's, but `awk -F'\t'` counts an
**empty** field as a field, so 18b is satisfied by the broken output. **Nothing in the
suite exercises the `column -t` pipe that `CLAUDE.md` documents and that this commit
exists to fix.** A one-line regression would ship silently.

#### HOLE 3 — read-side `generic` re-validation is uncovered (m10)

`task_of`'s re-validation list is one of the two places the commit removed `generic` from.
Re-adding it there alone leaves the suite ALL GREEN. Cases 26a/b/c only exercise the write
site. The read side matters precisely because the sidecar is a plain file a human or a
stray script can edit — the stated reason the re-validation exists.

#### HOLE 4 — `fleetd.heal_status_format` has zero coverage (m16)

Disabling the Python twin entirely (`def heal_status_format(self): return`) leaves the
suite **ALL PASS**:

```
### MUTANT m16: fleetd.heal_status_format() -> return (fully disabled)
  PASS(syntax-fleetd)

ALL PASS
```

Confirmed by inspection: the only reference to it in `test/` is a *comment* on case 16c
("fleetd's heal_status_format re-runs this forever"). The harness starts `fleetd` at line
161 and kills it before case 16 ever runs, and healing is sweep-driven. `heal_status_format`
duplicates `inject_status_format`'s logic in a second language with no test tying the two
together — they can drift silently.

---

## ITEM 4 — `--task generic` rejection

### 4(a) What the code actually does — **warn-and-drop, exit 0. NOT a hard reject.**

Measured directly:

```
----- GENERIC : --task 'generic' -----
  exit code : 0
  stderr    : fleet: unknown --task generic (ignored; want: research|plan|impl|test|scratch)
  window spawned : @1                      <- the agent IS created
  @fleet_task    : ''
  @fleet_task_tag: ''
  sidecar .../tasks/ctr/g-one : absent

----- MAIN : --task 'main' -----
  exit code : 0
  stderr    : fleet: unknown --task main (ignored; want: research|plan|impl|test|scratch)
  window spawned : @2
  @fleet_task    : ''
  @fleet_task_tag: ''
  sidecar .../tasks/ctr/m-one : absent

----- RANDOM : --task 'zzzbogus' -----
  exit code : 0
  stderr    : fleet: unknown --task zzzbogus (ignored; want: research|plan|impl|test|scratch)
  window spawned : @3
  @fleet_task    : ''
  @fleet_task_tag: ''
  sidecar .../tasks/ctr/z-one : absent

----- VALID : --task 'impl' -----
  exit code : 0
  window spawned : @4
  @fleet_task    : 'impl'
  @fleet_task_tag: 'impl'
  sidecar .../tasks/ctr/v-one : EXISTS
```

`generic`, `main` and a random unknown value are handled **identically**: a warning on
stderr, the value dropped, the agent spawned anyway, **exit code 0**.

The brief states red's ruling is a **HARD reject** — hard error plus nonzero exit. The
code does not do that. It does what the source comment says ("Anything else: warn, drop,
continue (fail-silent house style, CLAUDE.md)"), and the commit message's word is
"REJECTED", which is true only in the sense that the *value* is discarded.

Two readings, and I report the facts rather than adjudicate:
- Against **red's ruling as stated in my brief** (hard error + nonzero exit): **FAIL**.
- Against **the fail-silent house rule in `CLAUDE.md`** and the treatment of `--task main`,
  which was never a hard error either: consistent, and arguably correct — a hard abort on a
  display-only tag would be the only place in `fleet` where a cosmetic flag kills a spawn.

Either way, `generic` is now *exactly as rejected as* `main`, which is the parity the brief
asked about — but neither is a hard reject. **If red's ruling is to be honoured literally,
this is unimplemented, and it is unimplemented for `main` too.** Note that case 26a asserts
only that `@fleet_task` ends up empty; it asserts nothing about exit status, so the harness
would not notice either way.

### 4(b) HAS_TASKS is NOT flipped — **PASS**

A fleet where **every** agent was spawned with the rejected `--task generic`, compared
against a fleet spawned with no `--task` at all:

```
[rejected] window options:
  base               task=[] tag=[]
  ctr/worker-none    task=[] tag=[]
  ctr/worker-tagged  task=[] tag=[]
[rejected] sidecars: 0

[none] window options:
  base               task=[] tag=[]
  ctr/worker-none    task=[] tag=[]
  ctr/worker-tagged  task=[] tag=[]
[none] sidecars: 0
```

Dash captured at width 100 in both cases and byte-compared with `cat -A`:

```
=== BYTE DIFF of the two dash renders (expect: identical) ===
  IDENTICAL — HAS_TASKS not flipped
```

Rendered rows (no task column, labels at full width):
```
│▌   idle    ctr/worker-none                        ✓    default    -             │
│    idle    ctr/worker-tagged                      ✓    default    -             │
```

Neither `@fleet_task` nor `@fleet_task_tag` was written; the
`<root>/.fleet/tasks/<wname>` sidecar was never created (0 files under `.fleet/tasks`).
A rejected value costs no columns fleet-wide. **This half is fully correct.**

---

## Other things I found

1. **`fleet ls` `TASK` placeholder is `-`, and `IN-STATE` also renders `-`.** Cosmetic, but
   in the never-tagged fleet every row reads `idle  -  ...  -`, which is mildly ambiguous
   to scan. Not a defect; noting it because a different placeholder (`·`, or `.`) would
   read better and cost nothing. (Any replacement must remain non-whitespace or blocker 2
   returns — see m14.)

2. **Case 16's enum list is stale**, still containing `generic` (detailed above).

3. **`19b`'s width list (`120 110 100 95 90 85 80`) samples, it does not sweep.** With the
   current 13-cell fixtures the shed point is ~w=79 and the list happens to bracket it. If
   `LBLMIN`, `PILL_W`, `PILL_GAP` or `CF` changes, the sampled points can step over the new
   trade band exactly as the old `100/60/46/34` sampling did. A `seq`-driven sweep over
   70..120 costs ~35s and removes the fragility permanently.

4. **19b has no positive control for "empty capture".** It captures once after
   `sleep 0.8` with no retry; an empty capture yields an empty `bad` and therefore a
   **pass**. My own rig needed up to 10 retries at 0.7s on this machine to get a stable
   paint at some widths, and earlier testers reported empty captures at exactly these
   widths. 19b should assert that each capture contains at least one agent row before
   evaluating the invariant, otherwise a slow machine turns it green.

5. **`bin/fleet:17 SOCK=` is a latent hazard for any test that sources `bin/fleet`.**
   It silently redirects a sourcing harness's tmux wrapper (root cause of the pre-fix 16b
   failure, above). This commit routes around it rather than fixing it, which is the right
   call for this commit, but the next person to write
   `( . "$FLEET"; some_function )` will hit it again. Renaming it to `FLEETD_SOCK` would
   close the class.

---

## What I could NOT test, and why

- **Real terminal appearance of the status bar with an attached client.** All status-bar
  verification used `#{E:window-status-format}` expansion via `display-message -p`, which
  proves the format and its expansion but not the glyph's on-screen cell width in a real
  terminal with the user's font. No attached client was available inside the sandbox.
- **`fleet reap` end-to-end outside the proof harness.** Deliberately not run — it is on
  the brief's prohibited list outside a sandbox, and constructing a full reap scenario in
  the sandbox was out of scope for these four items. `reap`'s interaction with
  `forget_task` is therefore covered only by harness cases 21/22.
- **Sub-orchestrator / dispatch-layer spawns carrying `--task`.** Not exercised; the rig
  spawns via `fleet new` directly.
- **`cmd_restore` re-passing `--task` after a real tmux server restart.** Harness case 9
  covers the respawn path; I did not independently restart a server.
- **`fleetd.heal_status_format` behaviour** (as opposed to its *coverage*, which I did
  measure via m16). I did not drive the daemon through a theme-change sweep to observe the
  Python twin actually healing the format. **UNTESTED**, and it is also untested by the
  harness.
- **Widths outside 70..135**, and label lengths other than 17 and 40 cells. The mechanism
  (`band = len(label) − LBLMIN`) is arithmetic and I verified it at both measured points,
  but I did not sweep a third length.
- **`--all` across genuinely multiple projects.** My sandbox has one project root, so
  `fleet ls --all` returned the same rows as `fleet ls`. Column placement was verified;
  multi-project aggregation was not.

No result in this report is reported as a pass on the basis of an empty or failed capture.
Every width in the item-1 sweeps produced a non-empty capture; there are no UNTESTED
widths in the 70..100 range on either axis.

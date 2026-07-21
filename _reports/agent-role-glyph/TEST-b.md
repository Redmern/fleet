# TEST-b — independent verification of `fleet new --task` (commit ff9da68)

Tester B. Independent re-derivation; the implementer's `test/agent-task-proof.sh`
was read for context but **no assertion of it was taken on trust** — every verdict
below rests on output I captured myself.

**Overall verdict: the feature WORKS as specified, but ships three real defects,
one of which is a user-visible regression in a documented command.**

---

## 0. Note on missing plan documents

The task brief pointed me at `_reports/agent-role-glyph/PLAN.md`, `SYNTHESIS.md`
and `PLAN-PLAIN.md`. **None of these exist** in the working tree at ff9da68:

```
$ ls _reports/agent-role-glyph/
ls: "_reports/agent-role-glyph/": No such file or directory (os error 2)
```

I therefore had no approved plan to check the implementation against, and all
"is this what was asked for?" judgements below are made against `CLAUDE.md`'s
"Task tag (`--task`, `@fleet_task`) — NOT `role`" section and the commit message
only. **Spec conformance is consequently only partially verifiable.**

---

## 1. Setup and isolation proof

Isolation used a dedicated tmux socket under a temp root, a temp `XDG_CONFIG_HOME`
(so the real `~/.config/fleet/sessions/*.agents` is never written), a temp
`XDG_RUNTIME_DIR` (own `fleetd` socket), a temp `FLEET_ROOT`, and stub
`claude`/`claude-profile`/`nvim` binaries first on `PATH` so no real agent ever
launches.

```
$ echo "TMUX_TMPDIR=$TMUX_TMPDIR"
TMUX_TMPDIR=/tmp/fltB.jDQNN6/sock
$ tmux ls
error connecting to /tmp/fltB.jDQNN6/sock/tmux-1000/default (No such file or directory)
$ tmux -S /tmp/tmux-1000/default ls        # read-only peek at the REAL server
211: 1 windows (created Sun Jul 19 15:35:32 2026)
pc: 17 windows (created Sun Jul 19 15:35:31 2026) (attached)
...
```

The isolated `fleetd` bound its own socket and the real one was untouched:

```
$ ls -la $XDG_RUNTIME_DIR/
srw------- red 20 Jul 07:02 fleet.sock
$ ls -la /run/user/1000/fleet.sock
srw------- red 19 Jul 15:34 /run/user/1000/fleet.sock     # mtime unchanged
```

### 1a. HARNESS INCIDENT — disclosed in full

Two things went wrong in **my harness**, not in the feature. Both are recorded
here because they bound the confidence of some results.

1. **Socket-isolation gap → the real fleet server was torn down.** My `env.sh`
   exported `TMUX_TMPDIR`, but any command run in a shell that had not sourced it
   fell back to the real default socket `/tmp/tmux-1000/default`. A
   `tmux kill-server` in that state took down the live fleet session. The harness
   has since been hardened (explicit `-S "$SOCK"` wrapper plus a fail-fast refusal
   if the socket resolves to the real one or outside `$TMPB`). **This is entirely
   my error and not a defect in the feature under test.**
2. **Stray keystrokes into a live dashboard.** I started `fleet-dash` with
   `send-keys` and then sent a further command line as keystrokes; the dash
   interpreted them as single-key actions, perturbing session state (a window was
   parked, one was killed). Anything captured after that point in that session was
   re-derived from a fresh server before being reported.
3. **`tmux new-session` segfaults / `window-size manual` kills the server.** With
   `window-size manual` set and **no attached client**, `fleet new` reliably killed
   my test server:

   ```
   $ tmux set -g window-size manual; echo "C alive: $(tmux ls)"
   C alive: tb: 1 windows
   $ fleet new ctr w-rsch --task research --bare
   fleet new: spawn FAILED for 'ctr/w-rsch' — tmux returned no window id
   $ echo "D alive: $(tmux ls)"
   D alive: no server running on .../default
   ```

   This is a pre-existing tmux/fleet interaction unrelated to `--task` (it
   reproduces on a task-less spawn). I worked around it with one session per
   width instead of `resize-window`.

**Environment caveat:** an early run of mine was contaminated — a set of sidecars
and repos (`repo/e_research`, `repo/seed`, `other/seed`) I never created appeared
in my temp root, and window `@0` had been renamed from `main` to `base`. I could
not attribute it to any live process. **Every result reported below was re-derived
on a freshly created root after that discovery**, and the clean re-run reproduced
identically, so I do not believe any conclusion here is contaminated. I flag it
only for honesty.

---

## 2. Coverage point 1 — the closed enum accepts six values, rejects everything else

**VERDICT: PASS.**

All six enum values, plus the `-T` short form, plus a no-flag spawn:

```
$ for t in research plan impl test scratch generic; do fleet new alpha "t-$t" --task "$t" --bare; done
$ fleet new alpha t-none --bare
$ fleet new alpha t-short -T impl --bare
$ tmux list-windows -a -F '#{window_name}|task=#{@fleet_task}|tag=#{@fleet_task_tag}'
main|task=|tag=
alpha/t-research|task=research|tag=rsch
alpha/t-plan|task=plan|tag=plan
alpha/t-impl|task=impl|tag=impl
alpha/t-test|task=test|tag=test
alpha/t-scratch|task=scratch|tag=scr
alpha/t-generic|task=generic|tag=
alpha/t-none|task=|tag=
alpha/t-short|task=impl|tag=impl
```

Sidecars written for exactly the tagged agents:

```
$ (cd "$FLEET_ROOT/.fleet/tasks" && grep -r . .)
alpha/t-generic:generic
alpha/t-short:impl
alpha/t-test:test
alpha/t-plan:plan
alpha/t-impl:impl
alpha/t-scratch:scratch
alpha/t-research:research
```

The tag renderer, exercised directly via the internal subcommand:

```
$ for t in research plan impl test scratch generic bogus ''; do printf '%-9s|' "$t"; fleet task-tag "$t"; echo "|"; done
research |rsch|
plan     |plan|
impl     |impl|
test     |test|
scratch  |scr |
generic  |    |
bogus    |    |
         |    |
```

All tags are exactly 4 pure-ASCII codepoints, as the width contract requires.

**Rejection — 14 hostile values, all warn+drop, agent still spawns, exit 0:**

```
--- reject case: [main]
    fleet: unknown --task main (ignored; want: research|plan|impl|test|scratch|generic)
    spawned alpha/r1 (claude) in window @9
    exit=0
--- reject case: [MAIN]           ... spawned alpha/r2  exit=0
--- reject case: [Research]       ... spawned alpha/r3  exit=0
--- reject case: [research1]      ... spawned alpha/r4  exit=0
--- reject case: [impl extra]     ... spawned alpha/r5  exit=0
--- reject case: [#[fg=red]]      ... spawned alpha/r6  exit=0
--- reject case: [#{session_name}]... spawned alpha/r7  exit=0
--- reject case: [#(id)]          ... spawned alpha/r8  exit=0
--- reject case: [`id`]           ... spawned alpha/r9  exit=0
--- reject case: [$(id)]          ... spawned alpha/r10 exit=0
--- reject case: ["; tmux kill-server; #] ... spawned alpha/r11 exit=0
--- reject case: [impl\nplan]     ... spawned alpha/r12 exit=0
--- reject case: [../../etc/passwd]       ... spawned alpha/r13 exit=0
--- reject case: [scratch/../../evil]     ... spawned alpha/r14 exit=0
```

Nothing leaked for any of them — no window option, no sidecar file:

```
$ tmux list-windows -a -F '#{window_name}|task=[#{@fleet_task}]|tag=[#{@fleet_task_tag}]' | grep -E '^alpha/r'
alpha/r1|task=[]|tag=[]
alpha/r2|task=[]|tag=[]
...  (all 14 identical)
$ ls "$FLEET_ROOT/.fleet/tasks/alpha/"
t-generic  t-impl  t-plan  t-research  t-scratch  t-short  t-test    # no r* files
```

Note the case-sensitivity: `MAIN` and `Research` are rejected. Good — the enum is
a literal `case` match, not a fuzzy one.

### 2a. Malformed flag forms

```
$ fleet new alpha br1 --task            # trailing flag, no value
bin/fleet: line 1006: $2: unbound variable
exit=1
$ fleet new alpha br3 -T                # short form, no value
bin/fleet: line 1006: $2: unbound variable
exit=1
$ fleet new alpha br2 --task=research   # equals form
fleet: unknown flag --task=research
```

The `$2: unbound variable` is a raw bash error rather than a clean `die`, but it
is **not a regression** — the pre-existing flags behave identically:

```
$ fleet new alpha brX --base
bin/fleet: line 1010: $2: unbound variable
$ fleet new alpha brX -p
bin/fleet: line 1005: $2: unbound variable
```

I checked specifically for an infinite loop (the `shift 2` with `$# == 1` hazard,
which would hang forever without `set -e`); `set -u` at `bin/fleet:8` catches it
first and exits 1. `--task=value` is unsupported, consistent with `--base=`.

---

## 3. Coverage point 2 — `--task main` hard-rejected; role namespace untouched

**VERDICT: PASS.**

`--task main` and `--task MAIN` are both dropped with a warning (evidence in §2).
Neither wrote `@fleet_task`, `@fleet_task_tag`, nor a sidecar.

The role namespace is genuinely a separate namespace and is untouched by the task
flag. Every `.fleet/roles/<pane>` entry across all 22 spawned agents — including
the ones spawned with `--task main` — reads `worker`:

```
$ cat "$FLEET_ROOT"/.fleet/roles/* | sort | uniq -c
     22 worker
```

`@fleet_role` is unset on all windows and `FLEET_ROLE` in a `--task research`
worker's own pane environment is `worker`:

```
$ tmux list-windows -a -F '#{window_name}|@fleet_role=[#{@fleet_role}]' | head -4
main|@fleet_role=[]
alpha/t-research|@fleet_role=[]
alpha/t-plan|@fleet_role=[]
alpha/t-impl|@fleet_role=[]

$ p=$(tmux list-panes -t alpha/t-research -F '#{pane_pid}')
$ tr '\0' '\n' < /proc/$p/environ | grep -E '^FLEET_(ROLE|TASK)'
FLEET_ROLE=worker
```

Note: **no `FLEET_TASK` env var is exported at all.** The task is display-only and
never reaches the agent's environment, so it cannot be read (or spoofed) by the
agent process. That is stronger than the spec required, and correct.

---

## 4. Coverage point 3 — `#[`-injection cannot corrupt the status bar

**VERDICT: PASS**, with a documented residual risk.

The test tmux server loaded my real theme, so `window-status-format` legitimately
contains its own `#[` — a naive "count the `#[`" assertion would be meaningless
here, and I did not use one. Baseline before injection:

```
$ tmux show -g -v window-status-format
#[fg=#6d7db6] #I:#W
$ tmux show -g -v window-status-current-format
#[fg=#7d82d9,bg=default]#[bg=#7d82d9,fg=#060B1E,bold] #I:#W #[fg=#7d82d9,bg=default]
```

After `inject_status_format tb` — the task token is appended **beside**, never
into, the glyph token:

```
$ tmux show -g -v window-status-format
#[fg=#6d7db6] #I:#W #{?@agent_glyph, #{@agent_glyph},}#{?@fleet_task_tag, #{@fleet_task_tag},}
$ tmux show -g -v window-status-current-format
#[fg=#7d82d9,bg=default]#[bg=#7d82d9,fg=#060B1E,bold] #I:#W #[fg=#7d82d9,bg=default]#{?@agent_glyph, #{@agent_glyph},}#{?@fleet_task_tag, #{@fleet_task_tag},}
```

Idempotent across repeated injection (this is the assertion that matters, and it
is independent of how many `#[` the theme emits):

```
$ a=$(tmux show -g -v window-status-format); inject_status_format tb; inject_status_format tb
$ b=$(tmux show -g -v window-status-format); [ "$a" = "$b" ] && echo IDEMPOTENT
IDEMPOTENT (identical)
```

**The rendered bar**, expanded per window (this is literally what tmux draws).
Tagged windows render their tag; `generic`, untagged, and all three injection
attempts (`r6`=`#[fg=red]`, `r7`=`#{session_name}`, `r8`=`#(id)`) render nothing:

```
$ for w in ...; do tmux display -p -t "$w" "#{E:window-status-format}"; done
alpha/t-research   => [#[fg=#6d7db6] 2:alpha/t-research  rsch]
alpha/t-plan       => [#[fg=#6d7db6] 3:alpha/t-plan  plan]
alpha/t-impl       => [#[fg=#6d7db6] 4:alpha/t-impl  impl]
alpha/t-test       => [#[fg=#6d7db6] 5:alpha/t-test  test]
alpha/t-scratch    => [#[fg=#6d7db6] 6:alpha/t-scratch  scr]
alpha/t-generic    => [#[fg=#6d7db6] 7:alpha/t-generic ]
alpha/t-none       => [#[fg=#6d7db6] 8:alpha/t-none ]
alpha/r6           => [#[fg=#6d7db6] 15:alpha/r6 ]
alpha/r7           => [#[fg=#6d7db6] 16:alpha/r7 ]
alpha/r8           => [#[fg=#6d7db6] 17:alpha/r8 ]
```

The server survived the `"; tmux kill-server; #` value:

```
$ tmux ls
tb: 23 windows
```

### 4a. Blast-radius probe — the "whole server" claim is overstated (in the good direction)

I hand-poisoned `@fleet_task_tag` directly, bypassing the flag, to measure what a
validation escape would actually cost:

```
$ tmux set -w -t alpha/t-none @fleet_task_tag '#[fg=red,bg=green]PWNED#(touch /tmp/fB_PWNED)'
poisoned window renders: [#[fg=#6d7db6] 8:alpha/t-none  #[fg=red,bg=green]PWNED#(touch /tmp/fB_PWNED)]
a DIFFERENT window still renders: [#[fg=#6d7db6] 4:alpha/t-impl  impl]
command-exec side effect?
"/tmp/fB_PWNED": No such file or directory
```

So the damage from a bad value is confined to **one window's** expansion; the
global format string is never mutated, and `#()` did not execute under
`#{E:...}`. The design's stated fear ("corrupt the status bar for the WHOLE tmux
server") does not materialise even with validation fully bypassed. The validation
is still correct defence-in-depth — but the justification in the comments is
stronger than the evidence supports.

### 4b. Re-validation on read of the hand-editable sidecar

**PASS.** The sidecar file is the one store a human can edit, and it is
re-validated:

```
$ printf '#[fg=red]evil\n' > "$FLEET_ROOT/.fleet/tasks/alpha/t-none"
$ fleet task-of '' "$FLEET_ROOT" 'alpha/t-none'
[]
$ fleet ls | grep t-none
(no TASK shown)
```

---

## 5. Coverage point 4 — a task-less agent behaves exactly as before

**VERDICT: PARTIAL / FAIL for `fleet ls`; PASS for the dashboard and status bar.**

**Baseline construction:** I extracted the parent commit's CLI and ran it against
the *same live test session*, so the only variable is the fleet binary:

```
$ git show ff9da68^:bin/fleet > $TMPB/base/fleet && chmod +x $TMPB/base/fleet
baseline = ff9da68^ (0ebfbd9) bin/fleet
```

**Status bar:** an untagged window renders identically to the pre-feature form
(`#{?@fleet_task_tag,...}` collapses to nothing) — see §4.

**Dashboard:** with no task anywhere, `HAS_TASKS=0` and the task field is not
reserved. Direct A/B on the same agent at the same width, capturing the column at
which the label begins:

```
with a --task generic peer : [│   startin           ctr/g2   ... ]
with NO tasks at all       : [│   startin    ctr/g2          ... ]
label starts at col: generic=25  none=18
```

The "no task anywhere" render is the pre-feature layout. **PASS.**

**`fleet ls`: NOT identical, and it misaligns.** With no task anywhere, the
feature still emits an always-present empty `TASK` column:

```
$ diff <(base/fleet ls) <(bin/fleet ls)     # times normalised to T
DIFFERS:
< STATE	AGENT	WINDOW	IN-STATE
> STATE	TASK	AGENT	WINDOW	IN-STATE
```

This is BUG 1 — see §9.

---

## 6. Coverage point 5 — 9-field TSV, and no false `done` pill

**VERDICT: PASS.** This is the highest-value regression and it holds.

```
$ fleet agents | awk -F'\t' '{print NF}' | sort -u
9
$ awk -F'\t' '{print NF}' "$XDG_CONFIG_HOME/fleet/sessions/tb.agents" | sort -u
9
$ head -1 "$AF" | tr '\t' '|'
/tmp/.../root/alpha|alpha|r14|1||claude|1|alpha/r14|
```

Field 9 (`ready`) is empty for every unflagged agent — the exact condition that,
if violated by a 10th column, would make the dash render `done` on every row:

```
$ fleet agents | awk -F'\t' '{printf "%s ready=[%s]\n",$5,$9}'
alpha/t-research ready=[]
alpha/t-plan ready=[]
alpha/t-impl ready=[]
alpha/t-test ready=[]
alpha/t-scratch ready=[]
alpha/t-generic ready=[]
```

**The dash actually rendered**, with tagged agents present, shows no `done`/`ready`
pill anywhere:

```
$ grep -c -iE 'done|ready' dash.capture
0
```

### 6a. Positive control — proving this test CAN fail

A negative result is worthless unless the mechanism can fire. I set a genuine
`.fleet/ready` marker on the tagged agent `ctr/p-tag` and left `ctr/p-none` clean:

```
=== POSITIVE CONTROL: p-tag IS ready, p-none is NOT ===
│▌  startin           ctr/p-none                    ✓   default  -  │
│    done      impl   ctr/p-tag                     ✓   default  -  │

=== fleet ls ===
STATE|TASK|AGENT|WINDOW|IN-STATE
starting||ctr/p-none|tb:ctr/p-none|0m05s
done|impl|ctr/p-tag|tb:ctr/p-tag|0m05s  (ready: ready)

=== 9-field check with a ready marker set ===
ctr/p-tag NF=9 ready=[ready]
ctr/p-none NF=9 ready=[]
```

The `done` pill appears on **exactly and only** the genuinely-ready agent, coexists
correctly with the `impl` tag, and `NF` stays 9 with a **non-empty** field 9. The
negative result in §6 is therefore meaningful.

---

## 7. Coverage point 6 — `fleet ls` / `ls --all` tag the right rows

**VERDICT: PASS for correctness of row→tag mapping; see BUG 1 for alignment.**

Tested with 27 agents including deliberately prefix-colliding names
(`feat_alpha` / `feat_alpha-one` / `feat_alpha-two`) and slash-bearing branches
(`feat/alpha-one`, `deep/a/b/c` → `_`):

```
$ fleet new ctr feat/alpha-one --task research --bare
spawned ctr/feat_alpha-one (claude) in window @23
$ fleet new ctr deep/a/b/c --task test --bare
spawned ctr/deep_a_b_c (claude) in window @27

$ tmux list-windows -a -F '#{window_id}|#{window_name}|#{@fleet_task}|#{@fleet_task_tag}' | grep ctr
@23|ctr/feat_alpha-one|research|rsch
@24|ctr/feat_alpha-two|impl|impl
@25|ctr/feat_alpha|plan|plan
@26|ctr/plain-none||
@27|ctr/deep_a_b_c|test|test
```

`fleet ls`, every row tagged correctly, no bleed between the colliding names:

```
$ fleet ls | column -t -s$'\t'
STATE     TASK  AGENT               WINDOW                 IN-STATE
stale     rsch  root/alpha          tb:alpha/t-research    2m09s
stale     plan  root/alpha          tb:alpha/t-plan        2m09s
stale     impl  root/alpha          tb:alpha/t-impl        2m09s
stale     test  root/alpha          tb:alpha/t-test        2m09s
stale     scr   root/alpha          tb:alpha/t-scratch     2m09s
stale           root/alpha          tb:alpha/t-generic     2m09s
stale           root/alpha          tb:alpha/t-none        2m09s
stale     impl  root/alpha          tb:alpha/t-short       2m09s
starting  test  ctr/deep_a_b_c      tb:ctr/deep_a_b_c      0m07s
starting  rsch  ctr/feat_alpha-one  tb:ctr/feat_alpha-one  0m07s
starting  plan  ctr/feat_alpha      tb:ctr/feat_alpha      0m07s
starting  impl  ctr/feat_alpha-two  tb:ctr/feat_alpha-two  0m07s
starting        ctr/plain-none      tb:ctr/plain-none      0m07s
```

Note `feat_alpha` (plan) and `feat_alpha-one` (rsch) are correctly distinguished —
window-ID keying works and a prefix collision does not bleed. The 14 rejected-value
agents all show a blank TASK.

`fleet ls --all` produced the same tagging with the correct 5-column header. I did
**not** get to test a genuine cross-project `--all` (two distinct project roots on
one server) before the harness incident — see §11 UNTESTED.

---

## 8. Coverage point 7 — restore/forget round-trip; recycled window names

**VERDICT: PASS.** This is the strongest part of the implementation.

### 8a. Stale-tag recycling (the documented residual risk) — self-heals

```
=== 1. spawned tagged ===
ctr/recy|research
research                                   # sidecar contents

=== 2. window destroyed OUTSIDE fleet (plain tmux kill-window) ===
$ tmux kill-window -t tb:ctr/recy
sidecar still there?  recy                 # LEAKED, as disclosed

=== 3. RECYCLE the same window name with NO --task ===
$ fleet new ctr recy --bare
opt=[] tag=[]
sidecar now:                               # actively cleared
fleet ls row: starting||ctr/recy|tb:ctr/recy|0m00s
```

The leak is real but **cannot produce a wrong tag**: spawn is authoritative in both
directions and an empty `--task` actively clears both stores. The new agent shows
blank, not the dead agent's `research`. The residual risk is a stale *file*, not a
stale *display*.

### 8b. Restore across a full tmux server restart

```
=== before restart ===
ctr/rr-plan|plan
ctr/rr-none|
sidecars: rr-plan

=== SIMULATE TMUX SERVER RESTART ===
$ tmux kill-server; tmux new-session -d -s tb ...
windows after restart: main

$ fleet restore
restoring ctr/recy...
restoring ctr/rr-plan...
restoring ctr/rr-none...
restored 3 agent(s)

=== after restore: task options re-stamped? ===
main|task=|tag=
ctr/recy|task=|tag=
ctr/rr-plan|task=plan|tag=plan
ctr/rr-none|task=|tag=

=== fleet ls ===
STATE|TASK|AGENT|WINDOW|IN-STATE
starting||ctr/recy|tb:ctr/recy|0m02s
starting||ctr/rr-none|tb:ctr/rr-none|0m02s
starting|plan|ctr/rr-plan|tb:ctr/rr-plan|0m02s
```

The tag survived a full server restart via the durable sidecar, the window option
was re-stamped, and untagged agents stayed untagged. **PASS.**

### 8c. `fleet forget` drops the sidecar — PASSES for a plain branch name

```
$ D=$(awk -F'\t' '$8=="ctr/rr-plan"{print $1}' "$AF")
dir=/tmp/.../root/ctr/rr-plan ; sidecar before: rr-plan
$ fleet forget "$D"
sidecar after forget:                      # removed
ledger line gone? 0 occurrences
```

**However**, see BUG 3: this is reported to fail for a **slash-bearing** branch
name. My own reproduction attempt is recorded in §9.

---

## 9. Dashboard width ladder

**VERDICT: FAIL against the stated intent; PASS against the literal code.**

The code comment claims: *"DROP THE TASK FIELD FIRST — before cost/mode/✉. The
badge is a convenience; the label is the identity, and it must never be squeezed
by the badge."*

Measured behaviour, one session per width (`resize-window` was unusable — see §1a),
one tagged and one untagged agent:

```
===== WIDTH 120 =====
│▌  startin           ctr/w-none      ✓   default  -  │
│   startin    rsch   ctr/w-rsch      ✓   default  -  │
===== WIDTH 100 =====
│▌  startin           ctr/w-none      ✓   default  -  │
│   startin    rsch   ctr/w-rsch      ✓   default  -  │
===== WIDTH 90 =====
│▌  startin           ctr/w-none      ✓   default  -  │
│   startin    rsch   ctr/w-rsch      ✓   default  -  │
===== WIDTH 80 =====
│▌  startin           …r/w-none       ✓   default  -  │
│   startin    rsch   …r/w-rsch       ✓   default  -  │
===== WIDTH 65 =====
│▌  startin    …ctr/w-none            ✓   default  -  │
│   startin    …ctr/w-rsch            ✓   default  -  │
===== WIDTH 60 =====
│▌  startin    ctr/w-none             ✓   default  -  │
│   startin    ctr/w-rsch             ✓   default  -  │
```

The task field **is** shed before cost/mode/✉ (at ≤65 it is gone while `default`
and `✓` remain), so the *ordering* claim holds. But at **width 80 the label is
already truncated to `…r/w-none` while the `rsch` field is still occupying its 5
columns** — the label *is* squeezed by the badge, at every width from ~80 down to
the shed point. The ladder only sheds the task when `LW < 1`, i.e. when the label
would be literally zero-width, not when it starts eliding.

This matters because the implementer's own structural test (grepping source line
order) can only prove the *order* of the ladder, never this. Widths 75 and 70
produced empty captures (dash had not painted within the sleep window) — those two
points are UNTESTED.

---

## 10. Bugs and doubts

### BUG 1 (real, user-visible regression) — `fleet ls | column -t` misaligns every task-less row

`CLAUDE.md` documents `fleet ls | column -t` as a supported pipe, and
`task_tag_trim`'s comment explicitly claims to exist *to protect it*: *"a padded
field makes `fleet ls | column -t` mis-align that row"*. Trimming fixes the tagged
row and **breaks the untagged one**, which is the far more common case: bare
`column -t` splits on whitespace, so an empty TASK field collapses and every
subsequent column shifts one position left.

Reproduction (feature vs. `ff9da68^` baseline, same live session):

```
=== BASELINE (pre-feature) fleet ls | column -t ===
STATE     AGENT           WINDOW               IN-STATE
stale     root/alpha      tb:alpha/t-research  2m38s
stale     root/alpha      tb:alpha/t-none      2m38s
starting  ctr/plain-none  tb:ctr/plain-none    0m36s

=== FEATURE fleet ls | column -t (same rows) ===
STATE     TASK            AGENT              WINDOW               IN-STATE
stale     rsch            root/alpha         tb:alpha/t-research  2m38s
stale     root/alpha      tb:alpha/t-none    2m38s
starting  ctr/plain-none  tb:ctr/plain-none  0m36s
                ^ AGENT has slid into the TASK column
```

**Worst case — a fleet that has never used `--task` at all**, where *every* row is
misaligned relative to the header:

```
$ fleet ls | column -t
STATE  TASK                AGENT                  WINDOW  IN-STATE
stale  ctr/deep_a_b_c      tb:ctr/deep_a_b_c      T
stale  ctr/feat_alpha-one  tb:ctr/feat_alpha-one  T
stale  ctr/feat_alpha      tb:ctr/feat_alpha      T
stale  ctr/feat_alpha-two  tb:ctr/feat_alpha-two  T
stale  ctr/plain-none      tb:ctr/plain-none      T
   ^ header has 5 columns, every data row has 4; IN-STATE lands under WINDOW
```

This directly contradicts the dashboard's carefully-honoured "a task-less fleet
renders exactly as before" invariant — that invariant was upheld in the dash and
the status bar but **dropped in `fleet ls`**. `column -t -s$'\t'` is fine; the
documented bare form is not.

**Severity:** cosmetic, but it affects 100% of users the moment they upgrade, even
those who never use the flag.

### BUG 2 (real, design) — `--task generic` costs 7 columns of every label to display nothing

`generic` is a valid enum member accepted by `cmd_new` and stored in `@fleet_task`,
but `task_tag` maps it to four blanks. The dashboard's `HAS_TASKS` is computed from
`@fleet_task` (not from the rendered tag), so a single `generic` agent turns the
column on for the **whole fleet** and every row loses label width to render nothing.

Reproduction — same agent `ctr/g2`, same width, only the *peer* agent's tag differs:

```
with a --task generic peer : [│   startin           ctr/g2   ... ]
with NO tasks at all       : [│   startin    ctr/g2          ... ]
label starts at col: generic=25  none=18
```

7 columns lost per row. This is *precisely* the harm the implementer cited when
deliberately declining to default `--scratch` to `task=scratch` ("shrink every
label by 7 columns"). The same harm is reachable by simply typing the documented
`--task generic`. Either `generic` should render a tag (`gen `), or it should not
set `HAS_TASKS`, or it should not be in the enum.

### BUG 3 (CONFIRMED — root cause found) — `cmd_forget` orphans the sidecar permanently when `fleet_root` degrades

An independent run of the implementer's own `test/agent-task-proof.sh` reportedly
produced `FAIL(21): fleet forget left <root>/.fleet/tasks/repo/feat_one behind`,
against a claim of 25/25 passing. **It reproduces, and the slash in the name is a
red herring.** I found the actual mechanism.

**First, what is NOT the cause.** Path handling is fine. Driven tmux-free (no tmux
server exists at all — `fleet_root` falls back to `$FLEET_ROOT`), `cmd_forget`
removes the sidecar correctly for **both** a slash-bearing and a plain window name:

```
=== NO tmux server exists (proof) ===
error connecting to /tmp/fbNT.OKPUjL/nosock/tmux-1000/default (No such file or directory)
=== sidecars before ===
feat_one  plain
=== forget the SLASH-branch agent ===
$ fleet forget "$FLEET_ROOT/repo/feat_one"
sidecars after: plain
=== forget the plain agent ===
$ fleet forget "$FLEET_ROOT/repo/plain"
sidecars after:
```

**The actual cause is `fleet_root()` degrading, combined with a guard that cannot
fire.** `cmd_forget` does:

```sh
_root=$(fleet_root 2>/dev/null) || _root=""
_wn=$(awk -F'\t' -v d="$dir" '$1==d{print $8; exit}' "$f" 2>/dev/null)
[ -n "$_root" ] && [ -n "$_wn" ] && forget_task "$_root" "$_wn"
awk -F'\t' -v d="$dir" '$1!=d' "$f" >"$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
```

`fleet_root()` **never returns empty and never fails** — its last resort is
`pwd`. So the `[ -n "$_root" ]` guard is dead code: it always passes, even when
`_root` is a completely unrelated directory. `forget_task` then `rm -f`s a path
that does not exist, succeeds silently, and **the ledger line is deleted anyway**.

Reproduction — identical call, the only difference being whether the root resolves:

```
=== H1: FLEET_ROOT UNSET -> fleet_root() falls back to pwd() ===
$ cd /tmp                       # pwd is NOT the project root
$ fleet forget "$R/repo/feat_one"
sidecar still there? -> feat_one
ledger line removed anyway? -> 0 lines left

=== H2: same call WITH FLEET_ROOT set correctly ===
$ export FLEET_ROOT="$R"; fleet forget "$R/repo/feat_one"
sidecar -> []
```

**Why this is worse than the disclosed "sidecar leaks when a window dies outside
fleet" residual risk.** That leak self-heals: the window name is recycled and
`cmd_new` actively clears both stores (§8a). *This* leak does not, because the
ledger line — the only record that maps `dir` → window name — is deleted in the
same call. Nothing remains that could ever resolve the key again. The sidecar is
orphaned permanently.

**Blast radius.** `cmd_forget` runs at the tail of `cmd_reap`'s MUTATE phase. It
cannot cause a refusal, so the atomic-reap contract holds and no worktree is
endangered — the damage is confined to accumulating dead files under
`<root>/.fleet/tasks/`. Those files are then read by `task_of`'s file fallback, so
a future agent that reuses the window name in a context where the window option is
absent could display a dead agent's tag. Low severity, but it is a real
fail-silent-wrong in the one code path this repo is most careful about, and the
guard written to prevent it does not work.

**Suggested direction (not applied — I do not fix code):** have `fleet_root` signal
degradation distinctly from success, or resolve the sidecar path *before* the
ledger line is deleted and verify the removal, rather than relying on a
`[ -n "$_root" ]` test that can never be false.

### DOUBT 1 — the `#[`-injection justification is overstated

§4a shows a fully-bypassed validation confines damage to one window and does not
execute `#()`. The validation is right; the comments claiming whole-server
corruption should be toned down, or someone should demonstrate the server-wide
case. As written, a future maintainer may over-weight this constraint.

### DOUBT 2 — the dash's process-lifetime task cache

`prime_task` caches `TASK_RAW[wid]` for the dashboard's whole process lifetime on
the stated grounds that "the tag is stamped once at spawn and never mutates". That
is true today. It means any future "retag a running agent" feature will silently
not appear until the dash restarts. Not a bug now; a documented trap for later.

### DOUBT 3 — `fleet ls --all` file fallback can cross project boundaries

`cmd_ls` resolves one `_lsroot` (the *current* project) and passes it to `task_of`
for **every** row, including rows from other projects under `--all`. The window
option wins for live windows so this is nearly unreachable, but a window with no
`@fleet_task` whose *name* collides with a sidecar in *my* root would show my
project's tag. Narrow, and it is the reason the awk map was keyed by window ID —
but the *file fallback inside the loop* is still keyed by name. UNTESTED
dynamically (needs two project roots on one server).

### NOT A BUG — malformed flag values

`--task` with no value produces a raw `$2: unbound variable` rather than a clean
`die`. Ugly, but identical to `-p`, `--base` and `--harness`; pre-existing house
behaviour, not introduced here.

---

## 11. UNTESTED / source-inspection-only

| Point | Status | Why |
|---|---|---|
| `fleet ls --all` across two genuinely distinct project roots | UNTESTED | Requires two roots on one server; harness incident ended dynamic testing. Source-inspected — see DOUBT 3. |
| Dash width ladder at 75 and 70 columns | UNTESTED | Dash had not painted within the capture window; adjacent points (80 shown, 65 shed) bracket the behaviour. |
| BUG 3 `forget` sidecar leak | **CONFIRMED, root-caused** | Reproduced tmux-free; the slash in the name is a red herring — see §10 BUG 3. |
| `--scratch` + `--task` interaction | UNTESTED | Source-inspected: `cmd_new`'s scratch branch deliberately sets no default task; the validated write site is shared, so a `--scratch --task impl` spawn takes the same path. Not exercised live. |
| `fleetd`'s `heal_status_format` on a live theme switch | SOURCE-ONLY | Read the diff; it mirrors `inject_status_format` correctly (`fmt` is reassigned before the second check, so both tokens append). Not exercised — needs a theme-switch event. |
| Concurrent spawns racing on the sidecar dir | UNTESTED | `record_task` is a single `printf >` to a unique per-window path; no shared file, so a race is implausible, but unproven. |
| Unicode / non-UTF-8 locale rendering | UNTESTED | Tags are pure ASCII by construction (verified in §2), so locale should be irrelevant. |

---

## 12. Overall assessment

The core engineering is **sound and the hard parts are right**. The three
load-bearing constraints from `CLAUDE.md` all hold under independent test:

- the 9-field TSV shape is preserved in both readers, **and I proved the `done`-pill
  detector can actually fire** (§6a), which is what makes that result mean anything;
- the enum is genuinely closed, case-sensitive, re-validated on read, and `main` is
  unreachable — the role namespace is provably untouched, and the task never even
  enters the agent's environment;
- injection is blocked, and the blast radius is smaller than feared even without
  the block.

Restore/forget round-tripping and stale-tag recycling — the parts I expected to
break — were the most solid areas tested.

Against that, three defects stand out, all confirmed with reproductions.

- **BUG 1 should block.** It is a regression in a documented command
  (`fleet ls | column -t`) that hits every user on upgrade, including those who
  never touch the flag, and it breaks the very "task-less fleets are unchanged"
  invariant the rest of the design defends so carefully in the dash and the bar.
- **BUG 2** makes a documented enum value (`--task generic`) actively harmful:
  it costs 7 columns of every label across the whole fleet to display nothing —
  precisely the harm the implementer avoided by declining to default `--scratch`.
- **BUG 3 is confirmed and root-caused.** `cmd_forget`'s `[ -n "$_root" ]` guard
  is dead code because `fleet_root()` falls back to `pwd` and can never return
  empty; when the root degrades, the sidecar is skipped while the ledger line is
  deleted anyway, orphaning the file permanently. It does not endanger the atomic
  -reap contract, but it is a fail-silent-wrong in the repo's most safety-critical
  path, and the guard written to prevent exactly this does not work.

I would call this **NEEDS-WORK**. The design is right and the hard constraints all
hold; the three defects are each small and locally fixable, but BUG 1 is visible to
every user on day one and BUG 3 is a broken guard rather than a missing one.

A note on the implementer's suite: `test/agent-task-proof.sh` is a genuinely good
harness and its isolation model is sound. Its case 19, though, greps source line
order to prove the width-ladder shed order — that assertion cannot fail for the
right reason, and §9 shows the behavioural claim it stands in for ("the label is
never squeezed") does **not** hold. That is exactly the class of test that should
be distrusted.

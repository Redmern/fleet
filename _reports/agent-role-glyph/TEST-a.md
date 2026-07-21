# TEST-a — independent verification of `fleet new --task` (commit ff9da68)

Tester A. Branch `fleet/agent-role-glyph`, repo
`/home/red/proj/pc-tune/fleet/fleet_agent-role-glyph`, commit `ff9da68` (not merged).

**Overall verdict: PASS with one real user-visible regression and two design
defects.** Every load-bearing safety constraint (9-field TSV shapes, no false
`done` pill, closed enum, `main` rejection, `#[` injection, role-namespace
isolation, byte-identical no-task rendering) held under independent dynamic
testing. The regression is in a *documented* usage: `fleet ls | column -t`.

> Note on inputs: `_reports/agent-role-glyph/PLAN.md`, `SYNTHESIS.md` and
> `PLAN-PLAIN.md` **do not exist** in this worktree (nor under
> `/home/red/proj/pc-tune/.fleet/notes/scratch/agent-role-glyph-research`, which
> is empty). I verified against the commit, `CLAUDE.md`, and the source only.

---

## 0. Setup and isolation proof

Everything ran on a private tmux server, private config dir, private runtime dir
and private project roots. `bin/fleet` resolves these from `TMUX_TMPDIR`
(socket), `XDG_CONFIG_HOME` (→ `CONF_DIR`, so `~/.config/fleet/sessions/*.agents`
is never written), `FLEET_SESSION` and `FLEET_ROOT` (`bin/fleet:18,89-99,584`).
Stub `claude`/`claude-profile`/`omp` binaries were placed first on `PATH` so no
real agent ever launched.

```
$ cat /tmp/fltA-b31672/env.sh
MY=/tmp/fltA-b31672
export TMUX_TMPDIR="$MY/sock" XDG_CONFIG_HOME="$MY/config" XDG_RUNTIME_DIR="$MY/run"
export FLEET_SESSION="ta" FLEET_ROOT="$MY/root"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null FLEET_DEBUG_PORT=59777
unset TMUX
export PATH="$MY/bin:$PATH"
```

Isolation verified **before** the first mutating command:

```
== my server:
ta: 1 windows (created Mon Jul 20 06:59:20 2026)
== socket:
/tmp/fltA-b31672/sock/tmux-1000/default
== real server untouched:
7
```

The real fleet server (`/tmp/tmux-1000/default`, 7 sessions) was re-checked
throughout and never changed. No `fleet reap` / `fleet ready` / `fleet kill` was
ever run outside the sandbox; `fleetd` ran against `$XDG_RUNTIME_DIR/fleet.sock`
inside the sandbox only.

**Incident disclosure (no impact on the live fleet):** the scratchpad directory
handed to me is *shared with Tester B* — B overwrote my `env.sh` mid-run, and
before I noticed, one `tmux kill-server` + `rm -rf /tmp/fltA` of mine landed on
B's throwaway sandbox (session `tb`), not on anything real. I moved all my state
to `/tmp/fltA-b31672/` immediately and re-ran every test from scratch there. The
live `pc` session and `~/.config/fleet` were never touched.

---

## 1. The closed enum — all six accepted, everything else warn+dropped

**Verdict: PASS.**

All six values store and render:

```
wname            | @fleet_task | @fleet_task_tag | tasks-file
repo/e_research  | research    | [rsch] | [research]
repo/e_plan      | plan        | [plan] | [plan]
repo/e_impl      | impl        | [impl] | [impl]
repo/e_test      | test        | [test] | [test]
repo/e_scratch   | scratch     | [scr]  | [scratch]
repo/e_generic   | generic     | []     | [generic]
```

Tag widths (fixed 4 bytes, pure ASCII, `|` delimits):

```
research  -> |rsch| (4 bytes)     test      -> |test| (4 bytes)
plan      -> |plan| (4 bytes)     scratch   -> |scr | (4 bytes)
impl      -> |impl| (4 bytes)     generic   -> |    | (4 bytes)
<unset>   -> |    | (4 bytes)     bogus     -> |    | (4 bytes)
```

Rejection: 13 hostile/invalid values, each spawning a real worker. Every one
warned on stderr, dropped the tag, **still spawned**, wrote neither option nor
sidecar file. Representative capture:

```
--- case: bogus
exit=0 stderr/out: fleet: unknown --task bogus (ignored; want: research|plan|impl|test|scratch|generic)
creating worktree /tmp/fltA-b31672/root/repo/r_c1 (r/c1)...
spawned repo/r_c1 (claude) in window @7
spawned=@7 @fleet_task=[] @tag=[] file=[] file_exists=no
```

Same result (`spawned=@N`, `@fleet_task=[]`, `file_exists=no`) for: `MAIN`,
`main`, `Impl` (case-sensitivity confirmed — the enum is exact-match),
`x#[fg=red]`, `#{pane_id}`, `#(touch …)`, backticks, mixed quotes,
`impl\nmain`, `impl\tx`, `--bare`. The empty string `--task ""` is silently
accepted as "no task" (no warning) — correct.

---

## 2. `--task main` is hard-rejected; the role namespace is untouched

**Verdict: PASS.**

```
--- case: main
exit=0 stderr/out: fleet: unknown --task main (ignored; want: research|plan|impl|test|scratch|generic)
spawned=@9 @fleet_task=[] @tag=[] file=[] file_exists=no
```

The three role brakes for that exact pane:

```
=== ROLE NAMESPACE after --task main ===
window=@9 pane=%9
@fleet_role        = []
.fleet/roles/%9    = [worker]
FLEET_ROLE in pane env:
  (none at session level)
```

And no window anywhere on the test server carries a `main` role:

```
@0  base            role= task=
@1  repo/e_research role= task=research
...
@9  repo/r_c3       role= task=          <- the --task main spawn
@20 repo/n_short    role= task=plan
```

All 20 `.fleet/roles/%N` files read `worker`. Source-side, `cmd_new`'s enum
`case` (`bin/fleet:1030-1033`) is the single write site and `main` is not a
member; nothing in the task code path writes `@fleet_role`, `.fleet/roles/` or
`FLEET_ROLE` (verified by reading the diff).

---

## 3. `#[` injection cannot corrupt the status bar

**Verdict: PASS (CLI path). One residual noted.**

Injection payloads (`x#[fg=red]`, `#{pane_id}`, `#(touch …)`, backticks) were all
rejected at the write site (section 1). No side effects on disk:

```
=== injection side effects:
(eval):23: no matches found: /tmp/fltA-b31672/PWNED*
```

Status-bar wiring after `inject_status_format`:

```
=== global window-status-format after injection ===
#I:#W#{?@agent_glyph, #{@agent_glyph},}#{?@fleet_task_tag, #{@fleet_task_tag},}

=== expanded per window ===
repo/e_impl      -> [4:repo/e_impl #[fg=colour2,bg=default]●#[default] impl]
repo/e_research  -> [2:repo/e_research #[fg=colour2,bg=default]●#[default] rsch]
repo/e_scratch   -> [6:repo/e_scratch scr]
repo/e_generic   -> [7:repo/e_generic #[fg=colour2,bg=default]●#[default]]
repo/r_c6        -> [13:repo/r_c6]
base             -> [1:base]

=== idempotency: run inject twice ===
IDEMPOTENT
```

The glyph token is untouched and the task token is separate, as specified.
Untagged windows (`repo/r_c6`, `base`) expand to exactly what they did before.
No stored `@fleet_task`/`@fleet_task_tag` was outside the enum. Server survived
every payload (`server_sessions` still reported normally afterwards).

**Residual (low severity, source + dynamic):** `@fleet_task_tag` is expanded
verbatim by the status format and is **not** re-validated at render time —
`task_of`'s re-validation (`bin/fleet:1700-1708`) protects the file/CLI path, but
nothing protects a direct `tmux set -w @fleet_task_tag`. Demonstrated:

```
=== attempt to poison the option DIRECTLY (simulating a stray script) ===
poisoned window expands to: [8:repo/r_c1 #[fg=colour2,bg=default]●#[default] #[fg=red,bg=blue]PWN]
a DIFFERENT window still: [4:repo/e_impl #[fg=colour2,bg=default]●#[default] impl]
```

Note the injected SGR is **unterminated**, so it would bleed into the rest of the
status line. This is outside the stated threat model (requires a same-uid writer
that could equally rewrite `window-status-format` directly), and no fleet code
path can produce it. Recorded for completeness, not as a blocker.

---

## 4. No `--task` behaves exactly as before — byte-for-byte baseline

**Verdict: PASS.** Baseline established by extracting the *pre-feature* binaries
from `ff9da68^` and running them against an identical fleet:

```
$ git show ff9da68^:bin/fleet      > /tmp/fltA-b31672/old/fleet
$ git show ff9da68^:bin/fleet-dash > /tmp/fltA-b31672/old/fleet-dash
old dash sha: c13e6b23cd2d  new: e95858ba202d
```

A fresh session (`tz`) with three untagged agents, both dashboards rendered in a
real tmux pane and captured:

```
=== diff old(pre-feature) vs new dash, NO tasks anywhere ===
IDENTICAL (byte-for-byte)
=== md5 ===
7b83cd5daab14d1f03f02df88be0e010  /tmp/fltA-b31672/olddash.txt
7b83cd5daab14d1f03f02df88be0e010  /tmp/fltA-b31672/newdash.txt
```

And again including ANSI escapes (`capture-pane -pe`):

```
=== WITH ANSI: old vs new dash, untagged fleet ===
IDENTICAL incl. escape sequences
```

**Version skew both directions.** The pre-feature dash driven against a *tagged*
fleet (session `ta`, 20 agents, 6 tagged) renders correctly and shows no false
pill:

```
╭─ FLEET · ta · 20 agents · d:sigil ──────────────────────────────────────────╮
│▌   idle      repo/e_generic         ✓        default    -             │
│    idle      repo/e_impl            ✓        default    -             │
│    idle      repo/e_plan            ✓        default    -             │
...
--- any false done pill? ---
0
```

Untagged windows also render identically in the status bar (`repo/r_c6 -> [13:repo/r_c6]`,
section 3).

`fleet ls`'s *output shape* does change (a new TASK column) — intended, but it is
a breaking change for anything parsing `fleet ls` positionally, and it is the
source of the bug in section 6.

---

## 5. 9-field TSV shapes and the `done`-pill regression

**Verdict: PASS.** This is the highest-value guard and it holds on all three
readers.

`.agents` file (20 lines, every one written by the new `cmd_new`):

```
=== .agents file: field count per line ===
1: NF=9 ... 20: NF=9
distinct NF: 9

=== raw line 1 (tabs as |) ===
/tmp/fltA-b31672/root/repo/e_research|repo|e/research|1||claude|1|repo/e_research|
```

`fleet agents`, **daemon path** (isolated `fleetd` on the sandbox socket, panes
reported via `agent.report`):

```
=== daemon-path fleet agents NF ===
distinct: 9
=== sample rows (| = tab) ===
idle|repo/e_research|ta|@1|repo/e_research|0m00s|%1|0|
idle|repo/e_plan|ta|@2|repo/e_plan|0m00s|%2|0|
=== col9 (ready) non-empty rows: ===
0
```

`fleet agents`, **daemon-down fallback path**:

```
distinct NF: 7
col8 nonempty: 0
idle|fltA-b31672/root|ta|@0|base|-|%0
idle|repo/e_research|ta|@1|repo/e_research|-|%1
```

**The pill, proven by rendering, not by grep.** `bin/fleet-dash` launched in a
real 100×40 tmux window against 20 agents (6 tagged, `.fleet/ready` on none):

```
╭─ FLEET · ta · 20 agents · d:sigil ──────────────────────────────────────────────────────────────╮
│  repos   other       repo                                                                   │
│▌   idle             repo/e_generic                      ✓        default    -             │
│    idle      impl   repo/e_impl                         ✓        default    -             │
│    idle      plan   repo/e_plan                         ✓        default    -             │
│    idle      rsch   repo/e_research                     ✓        default    -             │
│    idle      plan   repo/n_short                        ✓        default    -             │
│    idle             repo/r_c1                           ✓        default    -             │
│    stale     scr    repo/e_scratch                      ✓        default    -             │
│    stale     test   repo/e_test                         ✓        default    -             │
```

No `done` pill on any row, state column intact, task column populated correctly
per row. `fleet ls` likewise reports no `done`/`ready` anywhere.

**Width-degradation ladder — dynamically verified** (the implementer's case 19 is
a source `grep` of line numbers and would pass even if the ladder were dead code;
this re-derives it by rendering):

```
===== pane width 100 =====   → task column shown, labels full
│    idle      impl   repo/e_impl                         ✓        default    -
===== pane width 60 =====    → task column SHED, label kept
│    idle      repo/e_impl       ✓        default   │
===== pane width 46 =====    → task still shed, cost dropped
│    idle      repo/e_impl       ✓      │
===== pane width 34 =====    → only state + label
│    idle      repo/e_impl    │
```

Task field is shed first, before cost/mode/✉, and the label is never squeezed by
it. PASS.

---

## 6. `fleet ls` / `ls --all` tagging — correct rows, but `column -t` breaks

**Verdict: PASS on tagging, FAIL on alignment.**

Two projects (`ta` @ root, `tz` @ rootz), each containing a window named
`repo/e_impl`, tagged **differently** (`impl` in `ta`, `research` in `tz`), plus
a slash-bearing branch `feat/deep/nest` → `repo/feat_deep_nest`:

```
=== fleet ls --all ===
STATE	TASK	AGENT	WINDOW	IN-STATE
idle	impl	repo/e_impl	ta:repo/e_impl	2m33s
idle	plan	repo/e_plan	ta:repo/e_plan	2m34s
idle	rsch	repo/e_research	ta:repo/e_research	2m34s
stale		repo/u_a	tz:repo/u_a	1m24s
starting	rsch	repo/e_impl	tz:repo/e_impl	0m06s
```

The two same-named `repo/e_impl` windows keep their own tags across projects —
the window-**id** keying works. Slash-bearing branches tag correctly:

```
starting	test	repo/feat_deep_nest	tz:repo/feat_deep_nest	0m00s
```

and their sidecars nest as directories:

```
ROOT/.fleet/tasks/repo/feat_deep_nest
ROOT/.fleet/tasks/repo/e_impl
```

**BUG — `fleet ls | column -t` mis-aligns every untagged row.** `CLAUDE.md`
states `task_tag_trim` emits empty (not 4 spaces) *specifically* so that
"`fleet ls | column -t`" does not mis-align. It does the opposite: `column -t`
without `-s` splits on whitespace runs, so an empty TASK field collapses and every
later value shifts one column left.

```
=== plain 'fleet ls | column -t' (post-feature) ===
STATE     TASK      AGENT                WINDOW                  IN-STATE
stale     repo/u_a  tz:repo/u_a          1m33s
stale     repo/u_b  tz:repo/u_b          1m33s
starting  rsch      repo/e_impl          tz:repo/e_impl          0m15s
starting  test      repo/feat_deep_nest  tz:repo/feat_deep_nest  0m15s

=== same on the PRE-FEATURE fleet (ff9da68^) ===
STATE     AGENT                WINDOW                  IN-STATE
stale     repo/u_a             tz:repo/u_a             1m33s
starting  repo/e_impl          tz:repo/e_impl          0m15s
```

The agent name lands under `TASK` and the window under `AGENT` for every untagged
row, while tagged rows are correct — the worst kind of table, half-right.
`column -t -s $'\t'` renders correctly, so the raw TSV is sound; only the
documented pipeline is broken. A single-char placeholder (`-`) in the TASK field
would fix it. The implementer's case 18b (`NF` equals header `NF`) cannot catch
this, because the empty field *is* present in the TSV.

---

## 7. restore / forget / recycled window names

**Verdict: PASS.**

Full tmux server kill → new session → `fleet restore`:

```
before: e_research=research e_impl=impl e_scratch=scratch
restoring repo/r_c13... restoring repo/n_short... restored 20 agent(s)
after restore:
  e_research   win=@1   task=[research] tag=[rsch]
  e_impl       win=@3   task=[impl] tag=[impl]
  e_scratch    win=@5   task=[scratch] tag=[scr]
  e_generic    win=@6   task=[generic] tag=[]
  r_c1         win=@7   task=[] tag=[]
```

Both the option and the rendered companion round-trip; untagged agents stay
untagged. `forget` removes the sidecar:

```
=== 7b. forget drops the sidecar ===
/tmp/fltA-b31672/root/.fleet/tasks/repo/e_impl
sidecar removed OK
```

**Recycled window name** — the case the design calls out. A tagged window killed
by hand (never routes through `cmd_forget`) leaks its sidecar; a later untagged
agent reusing the name must not inherit it:

```
kill repo/e_test (tagged test) by hand, outside fleet
sidecar after external kill: [test]      <- leaked, as expected
respawn with NO --task: task=[] tag=[] sidecar=[]
fleet ls row:
starting		repo/e_test	ta:repo/e_test	0m00s
```

Spawn is authoritative in both directions; the stale tag is cleared, not
inherited. PASS.

`--scratch` does not default a task, and accepts one when asked:

```
win=@22 task=[] sidecar_exists=no                       # bare --scratch
win=@23 task=[scratch] tag=[scr] sidecar=[scratch]      # --scratch --task scratch
```

---

## 8. Additional probes

| Probe | Result |
|---|---|
| `-T` short form | **PASS** — `-T plan` → `task=[plan] tag=[plan] file=[plan]` |
| `--task=impl` equals form | Rejected: `fleet: unknown flag --task=impl`, no spawn. Consistent with every other fleet flag (`--base=main` behaves identically) — **not a new defect**, but undiscoverable. |
| `--task` with no value | `bin/fleet: line 1006: $2: unbound variable`, exit 1, no spawn. Fail-closed but a raw bash error. **Pre-existing pattern** — `-p` with no value produces the identical error at line 1005. |
| Sidecar leak on external kill | Leaks (see 7c). Harmless: cleared on reuse, invisible otherwise; unbounded growth only. |
| **Window rename orphans the sidecar** | Renaming a window keeps the option but strands the file under the old key; after a server restart the tag is lost. See Bugs. |
| Concurrent spawns | Flaky (`create window failed: index N in use`) — **reproduces on `ff9da68^` too** (0/3 old vs 3/3 new in a fair head-to-head), so pre-existing and unrelated. When spawns succeed, all tags/sidecars are correct. |
| Implementer's harness rerun | 36/36 **ALL PASS**, reproduced independently. |

---

## Bugs and doubts

### B1 — `fleet ls | column -t` mis-aligns untagged rows (real regression, user-visible)
Severity: **medium**. The exact invocation `CLAUDE.md` names as the reason for
`task_tag_trim` is the one it breaks. Repro:
```sh
fleet ls | column -t     # untagged rows: AGENT under TASK, WINDOW under AGENT
```
Evidence and pre-feature comparison in section 6. Suggested fix: emit a
placeholder (`-`) instead of an empty field, or document `column -t -s $'\t'`.

### B2 — `--task generic` is invisible but costs 5 columns on every dashboard row
Severity: **medium**. `generic` is a valid enum member, stored in the option and
the sidecar, and it flips `HAS_TASKS` on — so every row reserves the 4-char field
+ gap — while rendering four spaces. One generic-tagged agent silently shrinks
every label by 5 cells for zero information. Repro (single agent tagged
`generic`, others untagged):
```
=== no tags ===
│▌  startin    repo/n_1               ✓        default    -             │
=== one 'generic' agent ===
│▌  startin           repo/n_1        ✓        default    -             │
```
It is equally invisible in `fleet ls` and the status bar — `generic` and
"untagged" are indistinguishable on every surface:
```
STATE^ITASK^IAGENT^IWINDOW^IIN-STATE
idle^I^Irepo/e_generic^Ita:repo/e_generic^I5m26s
idle^I^Irepo/r_c1^Ita:repo/r_c1^I5m26s
```
Either render it (`gen `), drop it from the enum, or exclude it from `HAS_TASKS`.

### B3 — a window rename strands the durable sidecar
Severity: **low**. The sidecar is keyed by window name; `tmux rename-window` (and
`fleet dispatch rename`, which renames sub-orch windows) leaves the file under
the old key. The option carries the tag until the tmux server restarts, after
which the tag is silently lost. Repro:
```
task_of via option: [plan]
task_of with option unset (simulating server restart):
  -> [] (old sidecar key 'repo/e_plan' still on disk: yes)
```
`cmd_restore` re-keys by the *persisted* wname, so a fleet-managed restore
recovers; a hand-renamed window does not.

### B4 — `@fleet_task_tag` is not re-validated at render time
Severity: **low / out of threat model**. `task_of` re-validates, but the status
format expands `@fleet_task_tag` directly, and no fleet path re-checks it. A
direct `tmux set -w @fleet_task_tag '#[fg=red,bg=blue]PWN'` injects unterminated
SGR into that window's status format (evidence in section 3). Unreachable through
the CLI; noted only because the commit message claims read-side revalidation is
the defence and this surface is not covered by it.

### Doubts about the implementer's harness (tests that cannot fail)
- **Case 4** parses a hand-written literal with bash `read`. It tests bash's
  IFS semantics, not `cmd_restore`; it passes on any implementation.
- **Case 19** greps line numbers out of `bin/fleet-dash` to assert shed order. It
  would pass even if the ladder never executed. I re-derived it by rendering at
  five widths (section 5) and it does in fact hold.
- **Case 18b** (`NF` equals header `NF`) cannot detect B1 — the empty TASK field
  is present in the TSV; the breakage is downstream in `column`.
- **Case 8** asserts the *padded* tag is 4 spaces, which is the dashboard form;
  nothing asserts anything about the *trimmed* form's effect on `fleet ls`
  consumers, which is exactly where B1 lives.

### Not tested / source-inspection only
- **fleetd's `heal_status_format`** (the `bin/fleetd` half of the diff) was
  exercised only indirectly: `inject_status_format` (the bash twin) was driven
  directly and proven idempotent, and the daemon ran, but I did not force a
  theme-switch heal cycle. The Python is a line-for-line mirror of the bash and
  parses (`syntax-fleetd` PASS).
- **`fleet reap` interaction** — never run outside the implementer's own harness
  (its case 22 covers the refused-reap-leaves-the-sidecar contract, and it
  passes); I did not run `reap` myself, since I judged the blast radius not worth
  it beyond the sandbox coverage already present.
- **Real terminal appearance of the status bar** — verified by
  `#{E:window-status-format}` expansion, not by attaching a client and reading
  pixels.
- **Sub-orch / dispatch-layer spawns with `--task`** — not exercised; the
  `--scratch` path (which every sub-orch uses) was, and correctly defaults to no
  task.

---

## Overall assessment

The three constraints this feature was built around all hold under independent
testing, and they hold for the right reasons, not by accident: the TSVs are
untouched at 9/9/7 fields on every path, the dash renders no false `done` pill
even when driven by the *pre-feature* binary against tagged agents, the enum is
exact-match closed at a single write site with a genuine re-validation on read,
`main` cannot be smuggled in, and a task-less fleet is byte-identical to
`ff9da68^` down to the escape sequences. That is a stronger result than the
harness alone claims, because the two weakest cases in the harness (19 structural,
4 vacuous) were re-derived dynamically here.

What is not finished is the *display* half. `fleet ls | column -t` is worse than
before the change (B1), and `generic` is a member of the enum that no surface can
show (B2). Neither threatens data or the live fleet; both are exactly the kind of
thing a human notices on day two. I would merge this only with B1 fixed — it is a
one-character change and it is a regression on a usage the design document itself
cites.

---

*Sandbox torn down after this report: tmux server killed on
`/tmp/fltA-b31672/sock`, `/tmp/fltA-b31672` removed. Real server verified at 7
sessions, unchanged, throughout.*

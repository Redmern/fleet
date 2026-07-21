# TEST-b — d25 `suborch-nvim`, independent tester B (ROUTING / DISPLAY)

Code under test: worktree `/home/red/proj/pc-tune/fleet/fleet_suborch-nvim`, branch
`fleet/suborch-nvim`, commit `22d733d`.
Diff reviewed: `bin/fleet` (+158), `bin/fleetd` (+34), `FLEET_SUBORCH.md` (+84).

I did not write this code and I changed nothing in the worktree. All tests ran on a
throwaway tmux server (`TMUX_TMPDIR` under a private `mktemp -d`), a throwaway
`FLEET_SESSION`, a private `FLEET_ROOT`, and a redirected `XDG_RUNTIME_DIR`. The live
session, the real ledger at `/home/red/proj/pc-tune/.fleet/dispatch`, and the systemd
`fleetd` were never touched. Every temp server/dir is removed by an `EXIT` trap.

My own harnesses (kept outside the repo, in scratch):
`tb-focus-down.sh`, `tb-focus-up.sh`, `tb-synth.sh`, `tb-farm.sh`, `tb-synth-broken.sh`.

---

## Verdict table

| # | Claim | Verdict |
|---|---|---|
| 1 | `fleet send` / `fleet mode` hit the HARNESS pane with the VIEWER pane ACTIVE | **PASS** (down, up, and synth paths) |
| 2 | Dashboard rows / HIDDEN_N not inflated by the viewer pane | **PASS** |
| 3 | Both daemon-UP (proven live) and daemon-DOWN paths | **PASS** |
| 4 | `scrape_harnesses` does not pick up the viewer as a harness | **PASS** (verified against a live daemon) |
| 5 | §3.0.6 symlink farm resolves; P1 `reports` key absolute | **PASS** for the mechanism; farm creation itself is **UNENFORCED** (see 5c) |
| 6 | Human can see the produced files in the viewer pane | **CONDITIONAL PASS** — see verdict section |

---

## Claim 1 — send/mode routing with the viewer FOCUSED (highest value)

This is the case the repo's own `suborch-viewer-send.sh` does **not** construct: that
script never calls `select-pane`, so the harness stays active throughout and the
"viewer is focused" scenario is untested by it. I constructed it explicitly.

### 1a. Daemon DOWN, viewer active (`tb-focus-down.sh`)

Precondition actually built (not assumed):

```
-- pane table after select-pane (the state under test) --
  %0 active=0 viewer= cmd=claude
  %1 active=1 viewer=1 cmd=nvim
  PASS(0 viewer IS the active pane (precondition constructed))
```

```
-- fleet agents (agents_tsv) --
idle^I…/scratchpad^Itbdown_s^I@0^Iso-d1^I-^I%0
  PASS(2a exactly 1 agent row for the window (got 1))
  PASS(2b agent row pane == HARNESS (%0) despite viewer being active)
  $ fleet send so-d1 TBMARKER_DOWN
  -> delivered to so-d1 via pane send-keys
  PASS(1a send landed in HARNESS not viewer (viewer focused))
  $ fleet mode so-d1
  -> cycled mode via send-keys (focus-dependent for nvim agents)
  PASS(1b mode BTab echoed in HARNESS pane (\e[Z present))
  PASS(1c viewer buffer shows no injected text)
```

`fleet mode` was verified by the harness process being `cat`, which echoes the BTab
escape `ESC [ Z` back into its own pane — so `^[[Z` appearing in the *harness* capture
is direct proof the keys were delivered there and not to nvim.

### 1b. Daemon UP, viewer active (`tb-focus-up.sh`)

```
  PASS(2b row pane == HARNESS (%0) with viewer ACTIVE)
  $ fleet send so-d1 TBMARKER_UP
  -> delivered to so-d1 via pane send-keys
  PASS(1a send -> HARNESS (daemon up, viewer focused))
  $ fleet mode so-d1
  PASS(1b mode BTab -> HARNESS)
```

### 1c. The fleetd SYNTH branch — the actual danger zone (`tb-synth.sh`)

In 1b the harness reported a scrape state, so `list_agents` returned it from the
*reported* path and the `synth` branch never ran. The synth branch is where the
`prefer the active pane` rule lives — the exact rule that would hand `fleet send` the
nvim pane. I forced it by stamping only `@fleet_harness` (no `@fleet_state_src`), so
`scrape_harnesses` reports nothing and `list_agents` must synthesize:

```
  %0 active=0 viewer= harness=claude cmd=claude
  %1 active=1 viewer=1 harness=claude cmd=nvim
  PASS(0 viewer active)
  NB @fleet_harness is a WINDOW option -> inherited by the viewer pane too (that is the trap)
-- fleet agents (synth path) --
  starting  …  @0  so-d1  0m04s  %0  4
  PASS(S1 synth emitted exactly 1 row)
  PASS(S2 synth row pane == HARNESS (%0) even though the ACTIVE pane is the viewer)
  -> delivered to so-d1 via pane send-keys
  PASS(S3 send -> harness)
```

Note the pane table confirms `@fleet_harness=claude` **is** inherited onto the viewer
pane — the trap the code documents is real, and the `@fleet_viewer` pane-option filter
is what defuses it.

### 1d. NEGATIVE CONTROL — these tests are not vacuous

I copied `bin/fleetd` and removed **only** the synth-loop guard
(`if viewer == "1": continue`), then re-ran the identical test:

```
-- fleet agents (synth path) --
  starting  dispatch/d1  tbsy_s  @0  so-d1  0m04s  %1  4
  FAIL(S2): synth chose %1 (viewer=%1) — send/mode would type into nvim
  FAIL(S3): h=0 v=0
SORT(1)  User Commands  SORT(1)
NAME
     sort  - sort lines of text
…
" ============================== Netrw Directory Listing
```

Without the fix the row resolves to `%1` (nvim), the message never reaches the harness
(`h=0`), and the text is swallowed by nvim as normal-mode commands — the capture shows
nvim having opened a man page and netrw. This is precisely the "silently lost" failure
the brief anticipated. The fix prevents it; my test detects its absence. **PASS, with a
proven-sensitive assertion.**

---

## Claim 2 — rows / HIDDEN_N

`HIDDEN_N` is incremented once per `agents_tsv` row whose session is `<sess>_hidden`
(`bin/fleet-dash:416`), so a duplicate viewer row would inflate it by exactly one. I
parked the sub-orch window into the hidden session and counted:

Daemon down:
```
  rows in hidden session: 1
  idle  …  tbdown_s_hidden  @0  so-d1  -  %0
  PASS(2c HIDDEN_N contribution is 1, not 2 (viewer not counted))
```
Daemon up: `PASS(2c HIDDEN_N contribution 1 (daemon up))`.

Row count is 1 (not 2) in every configuration tested: daemon-down fallback,
daemon-up reported path, daemon-up synth path, and hidden-session parked.

---

## Claim 3 — daemon UP vs DOWN, with liveness proven

The brief flagged that one focus test had passed against a crashed daemon. I refused to
assume liveness. `tb-focus-up.sh` proves it three ways — socket present, PID alive, and
an actual RPC round-trip — *before* asserting anything, and re-checks the PID at the end:

```
-- daemon liveness proof (NOT assumed) --
  socket: srw------- 1 red red 0 Jul 20 06:59 /tmp/tbup.rBOugQ/run/fleet.sock
  fleetd pid 3904690 alive
  fleet.ping -> {"id": "t", "ok": true, "result": {"pong": true}}
  PASS(D daemon is LIVE and responding)
…
  (daemon still alive at end of run — assertions were NOT against a corpse)
```

Daemon-down isolation was likewise proven, not assumed:
`no fleet.sock in XDG_RUNTIME_DIR=/tmp/tbdown.wouTFy/run (daemon down confirmed)`.

This was my own `fleetd` instance on a throwaway socket. The systemd unit was never
restarted or contacted.

---

## Claim 4 — `scrape_harnesses` must not pick up the viewer

Two levels of evidence.

Weak level (daemon-down script): I replicated the filter's awk logic against the real
tmux server. This is a *replica*, not the code — reported here only as corroboration:
```
  %0  scrape  esc to interrupt  …/scratchpad
  %1  scrape  esc to interrupt  …/dispatch/d1   1
  panes surviving scrape filter: [%0]
```
Note `@fleet_state_src` and `@fleet_busy_re` **are** inherited onto the viewer (`%1`) —
confirming the stated hazard.

Strong level (`tb-focus-up.sh`): queried the **live daemon** directly:
```
-- fleet.list straight from the LIVE daemon --
  "agents": [ { "pane_id": "%0", "window_id": "@0", "session": "tbup_s",
                "window_name": "so-d1", "state": "idle", … } ]
  agent entries: 1
  PASS(4a live daemon reports exactly 1 agent (viewer not an agent))
  PASS(4b viewer pane absent from live fleet.list)
  PASS(4c harness pane IS the reported agent)
```
**PASS.**

---

## Claim 5 — the §3.0.6 symlink farm and P1

### 5a. P1 — `cmd_dispatch_rename` writes an absolute `reports` key

```
$ fleet dispatch rename d7 'Suborch Nvim'
  renamed d7 → so-d7-suborch-nvim
  meta.tsv:
    window_id  @0
    window     so-d7-suborch-nvim
    reports    /tmp/tbfarm.eam3bS/root/_reports/suborch-nvim
  PASS(P1a reports key ABSOLUTE: /tmp/tbfarm.eam3bS/root/_reports/suborch-nvim)
  PASS(P1b == $root/_reports/suborch-nvim)
```
The repo's `dispatch-symlink-farm.sh` additionally proves last-wins on a second rename.

### 5b. Links RESOLVE (not merely exist)

I built the farm by extracting and `eval`ing the manual's own §3.0.6 fenced blocks
verbatim — so a quoting bug or a broken `${branch//\//_}` in the doc would surface —
then checked each link with `readlink -f` + `test -e`, and read real files through it:

```
  lrwxrwxrwx notes-impl       -> /tmp/tbfarm.eam3bS/root/repo/fleet_thing/.fleet/notes
  lrwxrwxrwx repo-fleet_thing -> /tmp/tbfarm.eam3bS/root/repo/fleet_thing
  lrwxrwxrwx reports          -> /tmp/tbfarm.eam3bS/root/_reports/suborch-nvim
  PASS(R:reports resolves -> …/_reports/suborch-nvim)
  PASS(R:repo-fleet_thing resolves -> …/repo/fleet_thing)
  PASS(R:notes-impl resolves -> …/repo/fleet_thing/.fleet/notes)
  PASS(H1 PLAN.md readable THROUGH the farm: # the plan)
  PASS(H2 SYNTHESIS.md visible through farm)
  PASS(H3 worker notes readable through farm: worker note)
  PASS(H4 worker worktree reachable through farm)
```
No dangling links. Content is genuinely readable through the farm.

### 5c. "the sub-orch reads `$reports` back and passes it ABSOLUTELY" — **UNTESTED as behavior**

The brief asks me to check that the prompt text actually contains an absolute path.
I can only report what is verifiable:

- **No bash anywhere creates the farm or writes `$reports` into a prompt.**
  `grep -n 'ln -sfn' bin/fleet bin/fleetd bin/fleet-dispatch.sh` → *no matches*.
- The manual instructs it clearly (§3.0.1a lines 92–104: "Never write `_reports/<slug>/`
  into a prompt", plus the `awk -F'\t' '$1=="reports"'` read-back recipe), and the repo
  test asserts the manual *says* so (cases 4 and 5).

So P1 (the ledger key) is real, enforced code. P2 (the farm, and passing `$reports`
absolutely into prompts) is **documentation the sub-orch LLM must choose to follow** —
there is no mechanism that makes it true. Verifying a live sub-orch actually emits an
absolute path in its prompts would require running a real dispatch, which the safety
rules forbid. **Reported as UNTESTED, not as passing.**

---

## Vacuous or weak tests

1. **`test/dispatch-symlink-farm.sh` case 7 — one third of the assertion is vacuous.**
   It asserts `after_rows == before_rows` from `fleet agents`, but that harness's only
   window runs `sleep 9999` with no `@agent_state`, so both sides are **0**. The test's
   own output admits it: `PASS(7 … farm entries 5, rows 0)`. `0 == 0` proves nothing
   about a dangling link perturbing `fleet agents`. The other two legs (entry count
   unchanged, `reports/PLAN.md` still readable) are real, so the case is weak, not
   worthless.

2. **`test/suborch-viewer-send.sh` never focuses the viewer.** It has no `select-pane`,
   so the harness is active for all four of its cases. Its cases are valid but they do
   **not** cover the brief's highest-value scenario. That gap is why I wrote
   `tb-focus-down/up/synth.sh`. (The repo's `suborch-viewer-focus.sh` case 4 does focus
   the viewer, so the suite as a whole is not blind here — but the send-routing script
   alone would give false confidence.)

3. **My own claim-4 check in `tb-focus-down.sh` is a replica**, not the shipped code. I
   flag it as such above; the authoritative evidence is the live-daemon `fleet.list`.

4. Guarded against elsewhere: both repo viewer scripts abort loudly if no viewer pane
   attaches (`ABORT … remaining cases would be vacuous`), which is the right instinct —
   without it every "did not land in nvim" assertion would pass for want of an nvim. My
   scripts do the same.

---

## Bugs found

No functional bugs. Two minor defects:

1. **Doc cross-reference is wrong.** `FLEET_SUBORCH.md:123` reads
   `(§3.0.1 — never a relative \`_reports/<slug>/\`)`, but the `$reports` contract is
   defined in **§3.0.1a** ("Name your window after the feature", line 75). §3.0.1 is
   "Classify the instruction" and says nothing about reports. A sub-orch following the
   pointer lands in the wrong section. Cosmetic, but this manual is the sub-orch's only
   instruction set, so a wrong pointer has real cost.

2. **The farm has no enforcement and no fallback.** See 5c. If the sub-orch skips
   §3.0.6 — or takes the §3 fall-through path, which never renames and therefore never
   gets a `reports` key at all — the viewer pane shows only `meta.tsv`,
   `instruction.txt` and `workers.tsv`. The feature then silently degrades to an empty
   folder view with no error and no visible signal that anything is missing. Not a bug
   in the shipped code; a robustness gap in the design.

Robustness checks that held up (repo suites, all re-run by me at `22d733d`):
`suborch-viewer-liveness.sh` 6/6 (incl. the critical "dead harness reads DEAD" — nvim
being an allowlisted harness command does *not* produce a false-ALIVE),
`suborch-viewer-idempotent.sh` 5/5 (double attach adds no pane; bogus window id creates
nothing; no stderr noise), `suborch-viewer-focus.sh` 7/7, `suborch-viewer-send.sh` 4/4,
`dispatch-symlink-farm.sh` 7/7.

---

## Does it meet the human's need?

The need: *"a sub-orchestrator opened with nvim so the produced files are viewable … in
the folder where all its created files are visible."*

**Mechanically, yes — and the routing is safe.** The viewer is a genuine added pane
(`suborch_attach_viewer`), rooted via `-c "$dir"` at `.fleet/dispatch/<id>/`, which is
also the ledger dir the farm links into. When the farm is populated, that directory is
exactly the "one folder where everything is visible":

```
-- what nvim is rooted at (attach-viewer dir) = …/root/.fleet/dispatch/d7 --
    meta.tsv
    notes-impl          -> worker's .fleet/notes
    repo-fleet_thing    -> worker's worktree
    reports             -> $root/_reports/suborch-nvim  (PLAN.md, SYNTHESIS.md, …)
    workers.tsv
```

I read `PLAN.md`, `SYNTHESIS.md` and a worker note *through* that directory. A human
sitting in that pane can see and open the produced files. The pane is added beside the
harness rather than replacing it, focus stays on the harness, and — proven above under
three code paths plus a negative control — focusing the viewer does **not** misroute
`fleet send` or `fleet mode` into nvim. The silent-message-loss failure mode the brief
worried about does not occur.

**The caveat is honest and material: the folder is only full if the sub-orch fills it.**
Every link is created by an LLM following prose in `FLEET_SUBORCH.md`; zero lines of
bash create or verify them. P1 (the absolute `reports` key) is real code and will always
be right. P2 is a convention. On a run where the sub-orch skips §3.0.6, or on any §3
fall-through dispatch (no rename ⇒ no `reports` key), the human opens the pane to a
near-empty directory with no indication that anything went wrong.

**Verdict: the need is met on the happy path, with correct and well-defended routing,
but it rests on sub-orch compliance rather than on a mechanism.** The highest-value
follow-up would be to have `resolve_or_spawn_suborch` (or `cmd_dispatch_rename`) create
the `reports` symlink itself the moment the key is written — that is three lines of bash
and would make the single most important link in the farm unconditional.

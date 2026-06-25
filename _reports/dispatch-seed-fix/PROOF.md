# PROOF — dispatch sub-orch seed fix (GATE 1 = BUILD)

Bug: the ~20KB `FLEET_SUBORCH.md` seed, inlined as a positional `claude` arg inside
one `tmux new-window/new-session`, exceeds tmux `MAX_IMSGSIZE` (16384) → "command
too long" (rc=1), swallowed by `2>/dev/null` → empty `win_id` → no pane → reconcile
respawns forever. Three co-shipping items + cleanup.

## What shipped

1. **CORE FIX** — `bin/fleet` `resolve_or_spawn_suborch`: the inlined `$(suborch_seed)`
   seed replaced by a compact (~200B) **imperative pointer** that makes reading the
   manual the sub-orch's FIRST action and reading `instruction.txt` its second; ends
   with the dispatch id. Uses `$FLEET_DIR` (global, in scope on both spawn paths) for
   the manual path; declares CWD = project root so the relative `.fleet/dispatch/<id>/…`
   refs stay valid.
2. **LOUD FAILURE on empty `win_id`** — `bin/fleet` `cmd_new` (after the spawn block,
   before `@fleet_harness`): empty `win_id` with **tmux present** now prints a real
   STDERR error and `return 1`; never prints `spawned … in window ` with a blank id.
   Fail-silent kept ONLY for genuine tmux-missing (`command -v tmux` false → silent
   `return 0`). A successful spawn always yields a non-empty id, so worker/scratch/nvim
   spawns are unaffected.
3. **DOC COHERENCE** — `FLEET_SUBORCH.md` `:9` and `:18` reworded for the pointer world:
   "seed prompt" → "pointer prompt"; instruction.txt is the authoritative **task**, the
   manual is operating **rules**; CWD = project root stated so relative refs stay valid
   (not switched to absolute).
4. **CLEANUP** — `suborch_seed()` deleted (its only caller was the replaced inline). No
   remaining references (`grep -rn suborch_seed` → none).

`bash -n bin/fleet` → SYNTAX OK.

## Proof method

Per PROOF-DESIGN §B, run in a **throwaway** tmux session `seedproof` pinned to a
throwaway root under the scratchpad — the live `pc` session was never touched
(verified before/after: `pc`, `pc_hidden_hidden`, `techweb2` unchanged; `seedproof*`
created and killed). `bin/fleet` invoked by absolute path so `$FLEET_DIR` resolves to
**this** worktree (the installed `fleet` symlink points at the `main` worktree).

### TEST 1 — normal worker spawn UNAFFECTED (no regression) — PASS
`fleet new --scratch t1worker -p "tiny"` →
```
rc=0
stdout: spawned t1worker (claude) in window @140
stderr: (empty)
t1worker win_id in seedproof_hidden: '@140'
```
Non-empty id, `spawned` line printed, rc=0 — item 2's guard does not touch the success path.

### TEST 2 — over-cap spawn FAILS LOUDLY (item 2) — PASS
`fleet new --scratch t2big -p "<40KB>"` (real over-cap, > MAX_IMSGSIZE) →
```
rc=1
stdout: (empty — NO "spawned" line)
stderr: fleet new: spawn FAILED for 't2big' — tmux returned no window id (over-cap seed prompt? look for 'command too long'). NOT spawned.
t2big windows created: 0
```
Loud STDERR error, non-zero rc, no phantom "spawned … in window ", no orphan window.
This is exactly the failure mode that was previously silent.

### TEST 3 — `<sess>_hidden` recreated when ABSENT — PASS
Killed `seedproof_hidden`, then `fleet new --scratch t3recover -p "tiny"` →
```
hidden present after kill: no
rc=0  stdout: spawned t3recover (claude) in window @141
hidden present after spawn: yes ; t3recover win_id: '@141'
```
Hidden sibling session recreated by the spawn; non-empty id.

### TEST 4 (DECISIVE — §B step 3) — end-to-end dispatch, sub-orch READS manual+instruction before acting — PASS
Ledger `d1/instruction.txt` (435 B, bounded "PROOF RUN — no workers") written; then
`FLEET_SESSION=seedproof FLEET_ROOT=<root> fleet dispatch d1`:
```
spawned so-d1 (claude) in window @142
dispatched d1 → so-d1
```
Ledger `meta.tsv` pinned the spawned id: `window_id  @142`; pane `%145 claude` exists in
`seedproof_hidden` → **the sub-orch ACTUALLY SPAWNS now** (vs the old over-cap → no pane).

Decisive capture-pane of `@142` (the sub-orch booted from the **compact pointer**, then
its first actions are file reads):
```
❯ You are a fleet dispatch sub-orchestrator (so-d1). Your project root is your CWD (…/proofroot).
  FIRST, read and follow your operating manual: /home/red/proj/pc-tune/fleet/dispatch-seed-fix/FLEET_SUBORCH.md
  THEN handle DISPATCH ID: d1 — read your instruction at .fleet/dispatch/d1/instruction.txt
● Reading manual + instruction.
  Read 2 files (ctrl+o to expand)
● First H1 of manual = "Fleet — ephemeral sub-orchestrator manual".
● Write(PROOF_MARKER.txt)
  ⎿ 1 MANUAL_FIRST_HEADING=Fleet — ephemeral sub-orchestrator manual
     2 INSTRUCTION_ID=d1
```
`PROOF_MARKER.txt`:
```
MANUAL_FIRST_HEADING=Fleet — ephemeral sub-orchestrator manual
INSTRUCTION_ID=d1
```
The sub-orch **read the manual** (`Read 2 files`; it reproduced the manual's true first
H1 — content it could only know by reading `FLEET_SUBORCH.md`, the full ~20KB manual
being available) **and the instruction** (`INSTRUCTION_ID=d1` from `instruction.txt`)
**before any other action**, then obeyed the instruction (no workers spawned). The
full manual is reachable; the boot is a single small tmux command that no longer
over-caps.

(Note: the sub-orch first hit claude's one-time "trust this folder" prompt because the
throwaway root was a fresh dir — accepted once in-session; irrelevant to a real project
root that is already trusted.)

## Verdict

GATE 1 = BUILD: **PASS**. All three co-shipping items + cleanup land; the sub-orch now
spawns with the manual available and reads manual+instruction before acting (decisive);
over-cap fails loudly; hidden session recreates; normal spawns unaffected. Throwaway
session torn down; live `pc` untouched.

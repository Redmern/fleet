# TEST-b — independent tester, dispatch-seed-fix

Tester B. Own context, own verdict. Re-derived from source + live exercise; the
implementer `PROOF.md` was **not** trusted (re-ran everything independently).

**Code under test:** `fleet/dispatch-seed-fix/bin/fleet` @ `c4376dd`,
`fleet/dispatch-seed-fix/FLEET_SUBORCH.md`.
**Isolation:** throwaway tmux session `dsf-b-sess` (+ its `dsf-b-sess_hidden`
sibling), throwaway root under the scratchpad. Feature binary invoked by absolute
path (installed `fleet` symlink points at the `main` worktree, not this one).
Live `pc` / `pc_hidden` / `pc_hidden_hidden` / `techweb2` verified untouched
before and after; both throwaway sessions torn down at the end.

> Note: spec said `_reports/dispatch-seed-fix/SYNTHESIS.md` — that file does **not
> exist** (only `PROOF.md`). Re-derived the intent from the fix commit message +
> diff instead.

---

## Item 1 — ROOT FIX: sub-orch actually spawns; boot is a small command — **PASS**

Real e2e dispatch in `dsf-b-sess` with a bounded `instruction.txt` (no workers):

```
$ FLEET_SESSION=dsf-b-sess FLEET_ROOT=$ROOT fleet dispatch d1
rc=0
spawned so-d1 (claude) in window @156
dispatched d1 → so-d1
```

- **Pane exists:** `dsf-b-sess_hidden` window `@156 so-d1`, pane running `claude`.
- **Ledger pinned the window id** (`bin/fleet:1397-1398`):
  `$ROOT/.fleet/dispatch/d1/meta.tsv` → `window_id<TAB>@156`, `state<TAB>planning`.
- **Boot command is well under cap.** Reconstructed pointer prompt = **381 bytes**
  vs the old inlined manual `FLEET_SUBORCH.md` = **20318 bytes** (`MAX_IMSGSIZE`
  16384). The pointer (`bin/fleet:1394-1396`) names `$FLEET_DIR/FLEET_SUBORCH.md`
  + `.fleet/dispatch/$id/instruction.txt`; the full 20KB manual stays on disk and
  is reachable (the sub-orch read it — Item 2).

Decisive: the spawn that previously over-capped → empty `win_id` → no pane now
produces a live pane with the id recorded.

## Item 2 — DECISIVE GATE: sub-orch READ manual + instruction before acting — **PASS**

`capture-pane` of `@156` after the queued pointer prompt processed (one trust
prompt on the fresh throwaway dir was accepted — irrelevant to a real, already
trusted project root):

```
❯ You are a fleet dispatch sub-orchestrator (so-d1). Your project root is your CWD (…/proofroot).
  FIRST, read and follow your operating manual: /home/red/proj/pc-tune/fleet/dispatch-seed-fix/FLEET_SUBORCH.md
  THEN handle DISPATCH ID: d1 — read your instruction at .fleet/dispatch/d1/instruction.txt
● Read manual + instruction.
  Read 2 files (ctrl+o to expand)
● Write(TESTB_MARKER.txt)
● Done. Marker written, no workers spawned.
```

`TESTB_MARKER.txt` (written by the sub-orch into its CWD):

```
MANUAL_H1=Fleet — ephemeral sub-orchestrator manual
DISPATCH_ID=d1
```

`MANUAL_H1` is the manual's true first H1 — content the sub-orch could only know
by **reading `FLEET_SUBORCH.md`** (the full manual, on disk, reachable).
`DISPATCH_ID=d1` came from **`instruction.txt`**. Both reads happened **before**
any other action, and it obeyed the instruction (no `fleet new`, no workers). The
compact pointer + on-disk manual mechanism works end-to-end.

## Item 3 — LOUD FAILURE on empty win_id (the silent-bug fix) — **PASS**

`bin/fleet:960-966`.

**3a — over-cap prompt, tmux PRESENT** (40000-byte `-p`, real `MAX_IMSGSIZE`
overflow):
```
$ fleet new --scratch t3big -p "<40000 x>"
rc=1
stdout: []     # no phantom "spawned … in window " line
stderr: [fleet new: spawn FAILED for 't3big' — tmux returned no window id (over-cap seed prompt? look for 'command too long'). NOT spawned.]
t3big windows created: 0
```
Real STDERR error, non-zero rc, no orphan window, no blank-id "spawned" line —
exactly the previously-silent path, now loud.

**3b — genuine tmux MISSING stays fail-silent** (PATH stripped of `tmux`):
```
$ PATH=<no-tmux> fleet new --scratch t3missing -p "tiny"
rc=0   stdout: []   stderr: []
```
`command -v tmux` false → silent `return 0` (the documented degrade-to-subset).
Fail-silent contract preserved.

## Item 4 — NO REGRESSION: normal spawns unaffected by the new guard — **PASS**

The guard sits on the shared `cmd_new` path (all spawns). Both succeed:

```
$ fleet new --scratch t4scratch -p "tiny"
rc=0   spawned t4scratch (claude) in window @152   stderr empty   (pane @152 in *_hidden)

$ fleet new myrepo fleet/test1 -p "tiny worker"
rc=0   spawned myrepo/fleet_test1 (claude) in window @153   stderr empty   (pane @153 visible)
```
Non-empty id ⇒ guard's `if [ -z "$win_id" ]` never fires; success path untouched
for scratch **and** repo/branch workers.

## Item 5 — hidden session recreated when absent (secondary bug) — **PASS**

```
$ tmux kill-session -t =dsf-b-sess_hidden     # hidden present after kill: no
$ fleet new --scratch t5recover -p "tiny"
rc=0   spawned t5recover (claude) in window @155
hidden present after spawn: yes
@fleet_root on recreated hidden: …/proofroot
```
The `has-session ? new-window : new-session` race-tolerant block
(`bin/fleet:916-926`) recreated `dsf-b-sess_hidden` via the new-session branch
and mirrored `@fleet_root`.

## Item 6 — cleanup + doc coherence + relative refs — **PASS**

- **`suborch_seed` deleted, no dangling caller:** `grep -rn suborch_seed bin/ FLEET_SUBORCH.md` → **NONE**. `bash -n bin/fleet` → SYNTAX OK.
- **`FLEET_SUBORCH.md:9` / `:18` reworded for the pointer model** (coherent):
  - :9 — "Your **pointer prompt** (which sent you here to read this manual) ends with `DISPATCH ID: <id>` plus the path to your instruction … Your CWD is the project root `<root>`, so every relative `.fleet/dispatch/<id>/…` path below resolves directly — no `cd` needed."
  - :18 (body line 21) — "That file — NOT your **pointer prompt**, NOT **this manual**, NOT chat history — is the authoritative **task**. This manual gives only your operating *rules*; `instruction.txt` is *what to actually do*."
  - Matches the actual pointer (last line: `… DISPATCH ID: d1 — read your instruction at .fleet/dispatch/d1/instruction.txt`).
- **Relative refs valid:** scratch spawns with `dir="$root"` (`bin/fleet:778`);
  confirmed the live so-d1 pane's `pane_current_path` = the project root, so the
  manual's `cat .fleet/dispatch/<id>/instruction.txt` resolves from CWD. The
  sub-orch in fact read `.fleet/dispatch/d1/instruction.txt` successfully (Item 2).

---

## Non-blocking observation (code smell, NOT a failure)

`resolve_or_spawn_suborch` (`bin/fleet:1386-1396`) places a **6-line comment block
between the `\`-continued env-var prefix and the `cmd_new` call**:

```
FLEET_NEW_WID_FILE="$widf" FLEET_SESSION="$sess" FLEET_ROOT="$root" \
FLEET_NEW_SUBORCH_ID="$wname" \
  # Compact IMPERATIVE pointer …        <- comment severs the prefix
  …
  cmd_new --scratch "$wname" -p "…"
```

The line-continuation joins the prefix into the **first comment line**, so it
parses as an **assignment-only command** (the four `FLEET_*` vars become plain
shell assignments that **leak** into the function/global scope), and `cmd_new`
runs as a **separate** command — no longer a scoped, exported command-prefix.
Verified with a minimal repro (`A=… \` + comment + `func` ⇒ vars leak past the
call and overwrite the caller's globals).

**Why it still works (and why I do not fail it):** `cmd_new` is a same-process
bash function, so it reads the leaked vars as shell globals via
`session_name`/`fleet_root`/`${FLEET_NEW_WID_FILE:-}`/`${FLEET_NEW_SUBORCH_ID:-}`;
and every caller (`cmd_dispatch`, the `cmd_reconcile` loop) re-assigns all four
immediately before each `cmd_new`, so the leak is overwritten per call and the
process is short-lived per CLI invocation. The full e2e (Items 1–2) confirms
correct behavior. **Latent fragility, not a live bug:** the vars are no longer
`export`ed, so if `cmd_new` were ever invoked as an external command / in a
subshell, or the prefix reused without re-assignment, they would silently fail to
propagate. Recommend collapsing to a clean prefix (move the comment above the
prefix) so the env stays a scoped, exported command-prefix.

---

## Verdict: **DONE**

All six required items independently verified with concrete evidence (live spawn,
ledger pin, decisive capture-pane + marker, loud/silent failure paths, no-
regression spawns, hidden-session recreate, cleanup/doc/relative-ref checks). The
root cause (over-cap inlined seed → silent empty-win_id → respawn loop) is fixed:
the boot is a 381-byte pointer (vs 20318-byte manual), the sub-orch spawns and
reads the on-disk manual + instruction before acting, empty-win_id now fails loud
(non-zero, STDERR) while genuine tmux-missing stays silent, and normal worker
spawns are unaffected.

**Single most important gap (non-blocking):** the env-prefix in
`resolve_or_spawn_suborch:1386-1396` is severed by an intervening comment, so the
`FLEET_*` vars leak as un-exported globals instead of a scoped command-prefix.
Benign today (same-process function + per-call re-assignment), but fragile —
collapse it to a clean prefix.

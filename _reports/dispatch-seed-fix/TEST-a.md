# TEST-a — dispatch-seed-fix (INDEPENDENT TESTER A)

Re-derived from source + live exercise of the real `bin/fleet`. PROOF.md was NOT trusted;
every claim below is my own evidence. Code under test: worktree
`fleet/dispatch-seed-fix`, commit `c4376dd`. All spawn work ran in a throwaway session
`dsf-a-sess` (+ its `_hidden` sibling), torn down at the end. Live `pc` / `pc_hidden` /
`techweb2` never touched (verified before + after).

Note: the spec path I was given (`_reports/dispatch-seed-fix/SYNTHESIS.md`) does **not
exist** — only `PROOF.md` is present in that dir. I worked from PROOF.md's "What shipped"
list + the commit diff + the actual source as the spec.

---

## Item 1 — ROOT FIX: sub-orch actually spawns; ledger gets window_id; full manual on disk — **PASS**

Real end-to-end dispatch (one sub-orch, killed after):
- Wrote ledger `proofroot/.fleet/dispatch/da1/instruction.txt` (bounded "TEST RUN — no
  workers; read manual+instruction, write a marker").
- `FLEET_SESSION=dsf-a-sess FLEET_ROOT=<root> bin/fleet dispatch da1`:
  ```
  rc=0
  spawned so-da1 (claude) in window @154
  dispatched da1 → so-da1
  ```
- Ledger `meta.tsv` after dispatch pinned the real id:
  ```
  window_id	@154
  window	so-da1
  state	planning
  ```
- Pane present: `tmux list-windows -t =dsf-a-sess_hidden` → `@154 so-da1`. The sub-orch
  **actually spawns** now (vs the old over-cap → no pane → respawn loop).

Boot command is small, not the over-cap inline seed (`bin/fleet:1394-1396`):
- pointer prompt actually sent = **386 bytes**.
- old inline seed = full `FLEET_SUBORCH.md` = **20318 bytes** > tmux `MAX_IMSGSIZE` 16384.
  → 386 B is comfortably under the cap; 20318 B was the exact overflow. The full ~20 KB
  manual remains available on disk at `$FLEET_DIR/FLEET_SUBORCH.md` (the pointer names it
  by absolute path).

## Item 2 — DECISIVE GATE: sub-orch READ manual + instruction before acting — **PASS**

`capture-pane @154` showed the boot prompt is verbatim the compact pointer:
```
You are a fleet dispatch sub-orchestrator (so-da1). Your project root is your CWD (…/proofroot).
FIRST, read and follow your operating manual: /home/red/proj/pc-tune/fleet/dispatch-seed-fix/FLEET_SUBORCH.md
THEN handle DISPATCH ID: da1 — read your instruction at .fleet/dispatch/da1/instruction.txt
● Reading manual + instruction.
  Reading 2 files…  (.fleet/dispatch/da1/instruction.txt …)
```
It then wrote `PROOF_MARKER_A.txt` at the project root:
```
MANUAL_H1=# Fleet — ephemeral sub-orchestrator manual
DISPATCH_ID=da1
```
`MANUAL_H1` is the manual's true first H1 — content it could only know by **reading the
full manual on disk**; `DISPATCH_ID=da1` came from reading `instruction.txt` (relatively,
proving CWD=project root). Both files read **before** any other action. (Fresh throwaway
dir hit claude's one-time trust prompt; accepted once, irrelevant to a trusted real root.)

## Item 3 — LOUD FAILURE on empty win_id; tmux-missing still silent — **PASS**

Over-cap scratch spawn (`bin/fleet new --scratch t2big -p "<40 KB>"`):
```
rc=1
stdout: []   (NO "spawned … in window" line)
stderr: fleet new: spawn FAILED for 't2big' — tmux returned no window id (over-cap seed prompt? look for 'command too long'). NOT spawned.
t2big windows created: 0
```
Loud STDERR, non-zero rc, no phantom "spawned" line, no orphan window — exactly the
previously-silent failure mode now made visible (guard at `bin/fleet:960-966`).

Genuine tmux-MISSING stays fail-silent: ran `fleet new --scratch` under a curated PATH
containing claude/git/coreutils but **no tmux** (`command -v tmux` false):
```
rc=0   stdout: []   stderr: []   ('spawn FAILED' count: 0)
```
Degrades silently per the documented fail-silent contract — the guard's `return 0` branch.

## Item 4 — NO REGRESSION on normal spawns — **PASS**

- Plain scratch: `fleet new --scratch t1worker -p "tiny"` → `rc=0`, `spawned t1worker
  (claude) in window @147`, empty stderr, real id `@147`.
- Real worker (non-scratch repo+branch): `fleet new testrepo fleet/wk1 -p "…" --bare`
  → `rc=0`, `spawned testrepo/fleet_wk1 (claude) in window @149`, real id, no error.
Both yield non-empty win_id, so the new loud-fail guard never fires on the success path —
all spawns (the path used by every `fleet new`) are unaffected.

## Item 5 — hidden `<sess>_hidden` recreated when absent — **PASS**

Killed `dsf-a-sess_hidden`, then `fleet new --scratch t3recover -p "tiny"`:
```
hidden present after kill:  no
rc=0   spawned t3recover (claude) in window @150
hidden present after spawn: yes
```
The has-session||new-session fallback recreates the detached sibling; non-empty id.

## Item 6 — cleanup / doc coherence — **PASS**

- `suborch_seed`: deleted from `bin/fleet` (diff confirms). `grep -rn suborch_seed .`
  hits **only** `_reports/dispatch-seed-fix/PROOF.md` prose — **no code caller, no
  dangling reference**.
- `FLEET_SUBORCH.md` reworded coherently for the pointer model: line 9 now
  "Your pointer prompt (which sent you here to read this manual)…"; the manual=rules /
  instruction.txt=authoritative-task reword is present (lines 11-13, 21-23). NB: PROOF's
  "line 18" cites the **pre-edit** line number — the substantive reword sits at lines
  21-23 now (the line-9 edit added 2 lines); content is correct, only the cited number
  drifted.
- Relative `.fleet/dispatch/<id>/…` refs still valid: the manual states CWD=project root
  (lines 11-13), and the live sub-orch **read `.fleet/dispatch/da1/instruction.txt`
  relatively and succeeded** — empirically valid given the scratch pane's cwd is the root
  (confirmed: trust prompt "Accessing workspace: …/proofroot"; boot prompt CWD = root).

---

## NON-BLOCKING finding (code wart, not a functional defect)

`resolve_or_spawn_suborch` (`bin/fleet:1386-1396`) places the multi-line `#` comment
block **between** the env-var assignment continuation and the `cmd_new` call:
```
FLEET_NEW_WID_FILE="$widf" FLEET_SESSION="$sess" FLEET_ROOT="$root" \
FLEET_NEW_SUBORCH_ID="$wname" \
  # Compact IMPERATIVE pointer …            <- trailing "\" joins the assignment to THIS comment
  # … (5 more comment lines) …
  cmd_new --scratch "$wname" -p "…"          <- runs WITHOUT the env prefix
```
The `\` on the `FLEET_NEW_SUBORCH_ID=…` line joins it to the first comment, so the four
`VAR=…` tokens form a **standalone assignment statement** (terminated by `#`), not an
env-prefix on `cmd_new`. The vars become **leaked global shell variables** instead of a
scoped command environment.

It **functionally works anyway** — proven, not assumed — because `cmd_new` is a same-shell
function that reads `${FLEET_NEW_WID_FILE:-}` / `${FLEET_NEW_SUBORCH_ID:-}` / etc. as
shell variables, and globals are visible to it (minimal repro confirmed: a function called
after `A=1 B=2 \ #comment` sees `A`/`B`, and they leak afterward). The decisive dispatch
above is the live proof: `window_id` reached the ledger (so `FLEET_NEW_WID_FILE` reached
`cmd_new`) and the spawn succeeded. The leak is contained — the spawn branch always
re-sets all four vars before `cmd_new`, and the process exits shortly after.

Still worth a follow-up tidy: move the comment **above** the assignment block (or below the
call) so it uses the real `VAR=x cmd` idiom and stops leaking globals. Cosmetic /
maintainability only — does **not** block.

---

## Verdict

**DONE.** All six required items PASS on independent re-derivation + live exercise: the
sub-orch now actually spawns from a 386 B pointer (full manual on disk), reads manual +
instruction before acting (decisive marker), over-cap fails loudly (rc=1 + STDERR) while
genuine tmux-missing stays silent, normal worker/scratch spawns are unaffected, the hidden
session recreates, and the cleanup/doc reword is coherent with no dangling `suborch_seed`
caller.

**Single most important gap:** none blocking. The one real finding is a cosmetic env-prefix
wart (comment block breaks the `VAR=x cmd` idiom → leaked globals); it is proven harmless
to behavior and deserves only a follow-up tidy.

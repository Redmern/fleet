# SYNTHESIS — dispatch sub-orch seed fix

**Verdict: BUILD (with two co-shipping revisions).**

Debate: PRO = BUILD, CON = REVISE, ALTERNATIVES = pointer-wins + add the
empty-`win_id` guard. All three agree the **diagnosis is correct** and the
**pointer direction is right**; the only disagreement is *what must ship alongside
the one-line change*. Their union is the plan below.

## Confirmed mechanism (unanimous)
Sub-orch seed = entire ~20 KB `FLEET_SUBORCH.md`, inlined as a **positional claude
arg** (`H_PROMPT_FLAG=""`, `claude.conf:6` → `argv+=("$prompt")`, `bin/fleet:885-888`)
inside ONE `tmux new-window/new-session` command (`bin/fleet:917-926`). That command's
total length exceeds tmux's **imsg `MAX_IMSGSIZE` 16384 (~16 KB) cap** → `command too
long`, rc=1 → `2>/dev/null` swallows it → `win_id=""` → `bin/fleet:986` prints
`…in window ` (blank), no pane → ledger gets no `window_id` → `suborch_live` false →
reconcile respawns the same over-cap command forever. NOT ARG_MAX (4 MB), NOT
newlines, NOT metachars — reproduced cleanly (PROOF-DESIGN §A). `pc_hidden`
"not recreated" is the **same** failure on the `new-session` branch, fixed for free.

## What to BUILD (the merged plan)

### 1. Core fix — pointer prompt (Option 2/3)  [bin/fleet:1375-1376]
Replace the inlined `suborch_seed` with a compact **imperative** pointer naming the
on-disk manual + the dispatch instruction. `$FLEET_DIR` is a global set at
`bin/fleet:10`, in-scope on both spawn entry paths (`cmd_dispatch:1447`,
`cmd_reconcile:1632`) — no export needed (verified, PRO §2 / CON §2). Keep the
prompt phrased so the manual is read **as the first action**:
```
You are a fleet dispatch sub-orchestrator (so-$id). Your project root is your CWD ($root).
FIRST, read and follow your operating manual: $FLEET_DIR/FLEET_SUBORCH.md
THEN handle DISPATCH ID: $id — read your instruction at .fleet/dispatch/$id/instruction.txt
```
~200 B → far under the cap (PROOF-DESIGN §A4 proved a 180 B pointer spawns + recreates
`pc_hidden`). De-risked further: sub-orchs start in `H_START_MODE="auto"`
(`claude.conf:12`) so the first Read runs unattended (answers CON §1c).

### 2. Co-ship — loud failure on empty win_id  [bin/fleet:986]  (CON §4, ALT Alt-5 slice)
This is **why the original bug was silent** and must ship in the same change, not as
"optional". When `win_id` is empty after the spawn, print a real error to stderr and
return non-zero (keep fail-silent for *tmux missing*, but never print
`spawned … in window ` with a blank id). Converts any *future* over-cap/tmux failure
from a silent no-pane into a visible, debuggable error. Both CON and ALTERNATIVES
insisted on this; PRO does not object.

### 3. Co-ship — reconcile the manual's own wording  [FLEET_SUBORCH.md]  (CON §1a/§1b)
Today the manual IS the seed, and its text reflects that:
- `FLEET_SUBORCH.md:9` "Your seed prompt ends with `DISPATCH ID: <id>`" — still true
  (the pointer ends with the id), keep.
- `FLEET_SUBORCH.md:18` "That file — NOT your seed prompt … is the authoritative
  instruction" — now mildly incoherent (the manual is no longer the seed). Reword so
  it's correct in the pointer world: the *manual* is your operating rules, the
  *instruction.txt* is the authoritative task.
- Relative `cat .fleet/dispatch/<id>/...` refs (`:15,:25,:26,:180,:233,:258,:307`)
  work **only because** scratch cwd=`$root` (`bin/fleet:779`). The pointer states
  "your CWD is the project root" so the manual's relative paths stay valid — do NOT
  mix in absolute paths that would drift if cwd ever changes. (This is a doc-coherence
  pass, low risk, but ship it together so the change is internally consistent.)

## Rejected / not needed (ALTERNATIVES)
- **FLEET_PROMPT_FILE / stdin** — target the nvim/`--print` paths the bug doesn't
  live on (`nvim/fleet.lua:20`; `claude.conf` is interactive positional). Lose.
- **Post-spawn send-keys / set-buffer+paste-buffer** — do deliver 20 KB and dodge the
  cap, but add a silent two-phase boot race for content already on disk at
  `$FLEET_DIR`. Worse for fail-silent style. Lose.
- **Generalised auto file-fallback in cmd_new** — wide blast radius + prompt-rewrite
  magic; only its empty-`win_id` slice (item 2) is worth keeping.

## Residual risk (accepted, with mitigation)
The pointer changes seed delivery from *guaranteed-in-context* to *fetch-on-faith*
(CON's headline). Mitigated by: (a) imperative "FIRST, read …" phrasing; (b) `auto`
start mode → unattended read; (c) item 2 makes any spawn failure loud; (d) item 3
keeps the manual coherent so a freelancing sub-orch is far less likely. Acceptance is
gated on PROOF-DESIGN §B step 3 — capture the sub-orch pane and confirm it actually
read the manual + instruction before acting.

## Touch-points summary
| # | File:line | Change | Priority |
|---|---|---|---|
| 1 | `bin/fleet:1375-1376` (`resolve_or_spawn_suborch`) | inline seed → pointer prompt | MUST |
| 2 | `bin/fleet:986` (+ `917-926`) (`cmd_new`) | empty `win_id` → loud non-zero failure | MUST (co-ship) |
| 3 | `FLEET_SUBORCH.md:9,18` (+ relative-path/cwd note) | reword for pointer model | SHOULD (co-ship) |
| — | `bin/fleet:1318` (`suborch_seed`) | unused by this path → delete or repurpose to emit the pointer | cleanup |

Acceptance: PROOF-DESIGN §B (end-to-end dispatch in a throwaway FLEET_SESSION), with
step 3 (seed content reached the agent) as the decisive gate.

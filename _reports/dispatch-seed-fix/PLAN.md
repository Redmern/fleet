# Dispatch sub-orch spawn fix — PLAN

Status: RESEARCH ONLY (no code written). Mechanism reproduced + confirmed.

## TL;DR

The `,`-dispatch sub-orch spawns **silently fail** because `resolve_or_spawn_suborch`
inlines the **entire ~20 KB `FLEET_SUBORCH.md`** as the agent's first prompt, and that
20 KB is passed as a positional argument inside a single `tmux new-window`/`new-session`
command. tmux rejects any command whose total length exceeds its internal
**~16 KB imsg cap** with `command too long` (rc=1). `cmd_new` swallows stderr
(`2>/dev/null`), so `win_id` comes back **empty**, and line 986 prints
`spawned so-d<N> (claude) in window ` with a blank id and **no pane is created**.

Recommended fix: **stop inlining the manual.** Seed the sub-orch with a short
**pointer prompt** that names the on-disk `$FLEET_DIR/FLEET_SUBORCH.md` plus the
dispatch id; the sub-orch reads the manual + its `instruction.txt` itself.

---

## 1. Confirmed mechanism (the KNOWN DIAGNOSIS was partly wrong)

### What the prompt's diagnosis got RIGHT
- The trigger is the ~20 KB `FLEET_SUBORCH.md` seed (now **19998 bytes**, `wc -c`).
- A `fleet new --scratch` with a SMALL prompt works; a compact pointer recovery worked.
- The visible symptom is `spawned so-d<N> (claude) in window ` with a blank window id.

### What it got WRONG — the channel
The diagnosis said the seed is passed to **`tmux new-window -e FLEET_PROMPT=<19KB>`**.
It is **not**. Two distinct prompt channels exist in `cmd_new`:

- **nvim path** (`bin/fleet:943-949`): non-bare workers — prompt rides
  `-e FLEET_PROMPT="$prompt"`, consumed by `nvim/fleet.lua:20` →
  `FleetSend()` (terminal channel). **Sub-orchs never take this path.**
- **bare/scratch path** (`bin/fleet:878-937`): scratch agents (and therefore
  every sub-orch) — the prompt is appended as a **positional argv element to the
  harness** (`argv+=("$prompt")`, `bin/fleet:885-888`; claude's
  `H_PROMPT_FLAG=""` → positional, `harness.d/claude.conf:6`) and passed inside
  `tmux new-window/new-session … "${argv[@]}"` (`bin/fleet:917-926`).

So the 20 KB is a **command argument to claude**, not an `-e` env value. (An `-e`
value would *also* count toward the cap — it is in the same command — but that is
not the channel in play for sub-orchs.)

### The exact failure — mechanism (b): tmux imsg command-length cap
Ruled out by reproduction (throwaway `tmux -L seedtest`, tmux **3.6b**):

| Candidate | Verdict | Evidence |
|---|---|---|
| (a) ARG_MAX / E2BIG | **NO** | `getconf ARG_MAX` = 4194304 (4 MB); 20 KB is 0.5% of it |
| (b) tmux command-length cap | **YES** | `new-window … stub <20KB>` → `command too long`, rc=1 |
| (c) newlines / shell metachars | **NO** | failure reproduces with a plain run of `a`s (no newlines); a 14 KB arg *with* newlines succeeds |
| (d) other | **NO** | clean threshold purely on byte count |

**Threshold (measured, single command):**
- ≤ ~16200 bytes total command → **OK**
- ~16220 bytes → `failed to send command`
- ≥ ~16240 bytes → `command too long`

The cap is **total command length** (all argv elements + option args + window
name + cwd), **not per-arg**: two 8190-byte args (16380 total) also fail, while
`-e VAR=<8000>` + `<8000>` arg (≈16 KB) passes. This is tmux's libevent
**imsg `MAX_IMSGSIZE` = 16384** ceiling (16 KB incl. header/protocol overhead),
the limit on a single command the client sends to the server. The real spawn adds
claude's path + `-e FLEET_ROLE/FLEET_DOCS/FLEET_SELF_MERGE[/FLEET_SUBORCH_ID]` +
window name + cwd on top of the 20 KB seed, so it is always far over.

### Symptom chain (matches the report exactly)
1. `resolve_or_spawn_suborch` (`bin/fleet:1375-1376`) calls
   `cmd_new --scratch "$wname" -p "$(suborch_seed)\nDISPATCH ID: $id"`;
   `suborch_seed` (`bin/fleet:1318`) = `cat "$FLEET_DIR/FLEET_SUBORCH.md"` (~20 KB).
2. `cmd_new` bare/scratch path builds `argv=(claude … "<20KB seed>")` and runs
   `tmux new-window … "${argv[@]}" 2>/dev/null` (or `new-session`, lines 916-926).
3. tmux refuses: `command too long`, rc=1. `2>/dev/null` hides it; `win_id=""`.
   *(Reproduced: with `2>/dev/null`, `win_id=[]`.)*
4. `bin/fleet:957` writes the empty id to `FLEET_NEW_WID_FILE`; `bin/fleet:986`
   prints `spawned so-d<N> (claude) in window ` (blank). No pane exists.
5. `resolve_or_spawn_suborch:1377-1378` reads `wid=""` → `meta_set window_id`
   **skipped** → ledger has no `window_id`.
6. `suborch_live` (`bin/fleet:1339-1349`) can't resolve a window → returns dead →
   every `reconcile` (`bin/fleet:1631-1632`) re-attempts the **same** 20 KB spawn →
   re-fails. Silent respawn churn; the sub-orch never appears.

---

## 2. The fix — options compared

The fix must (i) keep the seed *content* actually reaching the sub-orch, (ii) not
regress other `--scratch -p` callers, (iii) be robust to future manual growth.

### Option 1 — seed-via-file + `FLEET_PROMPT_FILE`
Write the seed to a temp file; pass only its path; the consumer reads it.
- **Problem:** the sub-orch is a **bare** pane — it has **no** `FLEET_PROMPT`
  consumer. `FLEET_PROMPT`/`fleet.lua` is the **nvim** path only; sub-orchs never
  run nvim. To make a bare claude read a file you must still hand claude a (short)
  prompt telling it to read the file — which *is* Option 2/3. Adapting the nvim
  plugin to `FLEET_PROMPT_FILE` is real work that does **not** touch the sub-orch
  path at all. **Rejected as primary** (solves a path the bug doesn't live on).

### Option 2 — point at on-disk `FLEET_SUBORCH.md` by path + short inline  ✅ RECOMMENDED
Seed the sub-orch with a compact imperative prompt naming `$FLEET_DIR/FLEET_SUBORCH.md`
(always installed; `FLEET_DIR` = install root, `bin/fleet:10`) and the dispatch id.
This is exactly what the **manual so-d11 recovery did**, and it is proven.
- **Pros:** tiny command (~200 B, far under cap); robust to *any* future manual
  size; one-line change at the single call site; no change to `cmd_new`, no change
  to other `--scratch` callers; backward-compatible.
- **Cons:** relies on the sub-orch actually reading the file as its first action
  (mitigate with an unambiguous imperative prompt). The manual is read at
  agent-start, not frozen at dispatch time — acceptable/desirable (always current).

### Option 3 — shrink/stop inlining; sub-orch reads manual + instruction itself
Superset of Option 2: the pointer prompt also tells the sub-orch to read
`.fleet/dispatch/<id>/instruction.txt` itself (it already keys off `DISPATCH ID`).
This is the recommended *content* of the Option 2 pointer — they are the same fix.

**Recommendation: Option 2 ≡ 3.** Replace the inlined `suborch_seed` with a short
pointer prompt.

### Exact touch-point
`bin/fleet:1375-1376`, inside `resolve_or_spawn_suborch`:

```
    FLEET_NEW_WID_FILE="$widf" FLEET_SESSION="$sess" FLEET_ROOT="$root" \
    FLEET_NEW_SUBORCH_ID="$wname" \
      cmd_new --scratch "$wname" -p "$(suborch_seed)
DISPATCH ID: $id"
```

becomes a compact pointer, e.g.:

```
      cmd_new --scratch "$wname" -p "You are a fleet dispatch sub-orchestrator (so-$id).
Read and follow your operating manual now: $FLEET_DIR/FLEET_SUBORCH.md
Then handle DISPATCH ID: $id — your instruction is at:
$root/.fleet/dispatch/$id/instruction.txt"
```

`suborch_seed()` (`bin/fleet:1318`) is then unused by this path; either delete it
or repurpose it to *emit the pointer string* (keeps the seam named/testable).
`$FLEET_DIR` is in scope inside `bin/fleet` (set at line 10); `$root` is the
function arg. Both are absolute → safe regardless of the sub-orch's cwd.

### Edge cases / backward-compat
- **Other `--scratch -p` callers** (interactive `fleet new --scratch`, manual
  helpers): untouched — only `resolve_or_spawn_suborch` changes. Any caller who
  *deliberately* passes a >16 KB scratch prompt would already be broken today;
  out of scope.
- **Degraded install** (`$FLEET_DIR/FLEET_SUBORCH.md` missing): the pointer still
  names the path; the sub-orch reports a read failure instead of silently dying.
  Strictly better than today (silent no-pane). Optional: have the sub-orch fall
  back to `fleet` help if the file is absent.
- **Fail-silent house style preserved** — no new error propagation.
- **Hardening (recommended, secondary):** make `cmd_new` not *claim success* on an
  empty `win_id`. At `bin/fleet:986`, when `win_id` is empty, print a real failure
  (`spawn failed: <reason>`) to stderr and return non-zero so callers/reconcile see
  it. This is defence-in-depth that converts any *future* over-cap or tmux failure
  from a silent blank into a visible error. (Does not replace the size fix.)

---

## 3. Secondary finding — pc_hidden destroyed on last-window kill

Reported: killing the last window in `<sess>_hidden` destroys the hidden session,
and reconcile's spawn "did not recreate it the way `fleet new --scratch` does."

**Finding: this is a downstream symptom of the SAME root cause, not a separate bug.**
- `cmd_reconcile` (`bin/fleet:1631-1632`) calls `resolve_or_spawn_suborch` →
  `cmd_new --scratch` — the **identical** path as a fresh dispatch. The TOCTOU-safe
  `has-session || new-session` dual-primitive (`bin/fleet:916-926`) already
  recreates `<sess>_hidden` correctly *when the spawn command is valid*.
- When the hidden session is gone, `cmd_new` falls to the `new-session` branch
  (`bin/fleet:922`). With the 20 KB seed that `new-session` *also* exceeds the cap →
  `command too long` → no session, no pane. So "not recreated" was the **20 KB
  failure**, not a recreate-logic gap.
- **The size fix resolves this too:** with a ~200 B pointer, `new-session` succeeds
  and recreates `pc_hidden`. *Proven* in the PROOF DESIGN (hidden session absent →
  short-pointer `new-session` → session recreated, pane seeded).

No separate hardening is strictly required. The optional `cmd_new` empty-`win_id`
failure-reporting above would additionally make any *future* recreate failure
visible instead of silent.

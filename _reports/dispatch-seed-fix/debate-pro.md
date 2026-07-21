# Debate — PRO (argue FOR the recommended pointer-prompt fix)

**Position:** BUILD. The recommended fix (Option 2/3 — replace the inlined
~20 KB `suborch_seed` with a short pointer prompt) is correct, minimal, robust,
and lands exactly on the one defective line. Every load-bearing claim in the
PLAN is verifiable in the code as shipped.

## 1. The mechanism is real and the fix targets its exact cause

The bug is a single-command length overflow, confirmed end-to-end in the code:

- `suborch_seed()` is `cat "$FLEET_DIR/FLEET_SUBORCH.md"` — the whole manual
  (`bin/fleet:1318`). `wc -c` = 19998 bytes (PLAN §1).
- `resolve_or_spawn_suborch` passes `"$(suborch_seed)\nDISPATCH ID: $id"` as the
  `-p` prompt to `cmd_new --scratch` (`bin/fleet:1375-1376`).
- For a `--scratch` agent, `bare=1` (`bin/fleet:778`), so the prompt is appended
  as a **positional argv element** to the harness (`argv+=("$prompt")`,
  `bin/fleet:885-888`) — confirmed positional because claude's
  `H_PROMPT_FLAG=""` (`harness.d/claude.conf:6`).
- That argv is then handed to a **single** `tmux new-window`/`new-session`
  command (`bin/fleet:917-925`), with stderr swallowed by `2>/dev/null` on every
  spawn primitive.

So the ~20 KB lands inside one tmux client→server command, which overflows
tmux's imsg `MAX_IMSGSIZE` (16384) cap → `command too long`, rc=1, hidden by
`2>/dev/null` → `win_id=""`. The fix removes precisely the thing that overflows
the cap. It is causal, not cosmetic.

**The PLAN even *corrected* the original diagnosis** (it is not the `-e
FLEET_PROMPT` nvim channel — sub-orchs are bare and never run nvim;
`bin/fleet:885-888` vs `943-949`). A fix built on the right channel is far safer
than one built on the wrong one; this is a strength the PLAN undersells.

## 2. `$FLEET_DIR` is in scope and resolves to the installed manual

Verified: `FLEET_DIR` is set at top of the script
(`bin/fleet:10`, `cd "$(dirname "$(readlink -f …)")/.." && pwd`) as a global, so
it is in scope inside `resolve_or_spawn_suborch` with no extra plumbing. It is
the same path `suborch_seed` already `cat`s today (`bin/fleet:1318`) — meaning
the manual is *guaranteed* to live at `$FLEET_DIR/FLEET_SUBORCH.md` exactly where
the pointer names it. The pointer can never name a path the old code wouldn't
have read. `$root` is the 4th function arg (`bin/fleet:1354-1355`); both paths
are absolute, so the sub-orch resolves them regardless of its cwd.

## 3. Blast radius is exactly one function — no collateral

`cmd_new`'s `--scratch` path is **shared** by other callers (interactive
`fleet new --scratch`, helper agents), so a fix inside `cmd_new` would risk
regressions. The recommended fix touches **only the `-p` argument at
`bin/fleet:1375-1376`** inside `resolve_or_spawn_suborch`. `cmd_new`,
`harness.d/claude.conf`, the nvim path, and every other `--scratch` caller are
**unchanged**. Any other scratch caller passing a >16 KB prompt is already broken
today and is out of scope. This is the minimal possible surface.

## 4. The fix is already proven, twice

This is the PLAN's most-undersold strength:

- The **manual so-d11 recovery** (per MEMORY and PLAN §1) used exactly this
  compact pointer prompt and succeeded — the fix is not theoretical, it has run
  in production.
- The PROOF-DESIGN A4 reproduces it in a throwaway tmux: a 180-byte pointer via
  `new-session` spawns the pane *and* recreates `pc_hidden` when absent
  (PROOF-DESIGN:43-54). So the fix is demonstrated positive before a line of real
  code ships.

## 5. It fixes the secondary `pc_hidden` bug for free

`cmd_reconcile` (`bin/fleet:1631-1632`) calls the same
`resolve_or_spawn_suborch` → `cmd_new --scratch`. When `pc_hidden` is gone,
`cmd_new` falls to the `new-session` branch (`bin/fleet:922`) — which *also*
exceeds the cap with the 20 KB seed. So "reconcile didn't recreate the hidden
session" was never a recreate-logic gap; the dual `has-session || new-session`
primitive (`bin/fleet:916-926`) is already correct. Shrinking the command makes
`new-session` succeed and recreate `pc_hidden`. One fix, two bugs — strictly a
point in its favour. No second code path needs touching.

## 6. Robust to the future, and a behavioural improvement

- **Future-proof:** the command is now ~200 B regardless of how large the manual
  grows. The current design re-breaks silently the moment the manual crosses
  16 KB; the pointer never does.
- **Always-current seed:** the manual is read at agent start, not frozen at
  dispatch time — the sub-orch always follows the live manual. Desirable, not a
  regression.
- **Degraded install is *better*, not worse:** if the manual were missing, the
  sub-orch reports a read failure instead of dying as a silent no-pane. Today's
  behaviour is the worst case (invisible churn); the pointer strictly improves it.
- **Fail-silent house style preserved** — no new error propagation; the optional
  `cmd_new` empty-`win_id` hardening (PLAN §2) is defence-in-depth, not required
  for this fix.

## Addressing the one real risk

The only genuine "con" is that the sub-orch must actually *read* the named file
as its first action rather than have the content pre-injected. This is mitigated
by an unambiguous imperative prompt ("Read and follow your operating manual now:
…"), and it is the *same* contract every fleet worker already operates under (the
`-p` prompt tells the worker to read `$FLEET_DOCS`, manuals, instruction files,
etc.). The so-d11 recovery confirms a claude agent reliably obeys a
read-this-file-first imperative. Acceptance step 3 (PROOF-DESIGN:68-72) gates
exactly on this, so it cannot regress unnoticed.

---

**Verdict: BUILD.** Strongest point: the fix removes the precise input that
overflows tmux's 16 KB imsg cap, lives entirely on the single defective line
(`bin/fleet:1375-1376`) with zero collateral on other `--scratch` callers, and is
*already proven to work* (the so-d11 recovery + PROOF-DESIGN A4) — it also fixes
the secondary `pc_hidden` recreate bug for free via the shared
`resolve_or_spawn_suborch`/`cmd_new` path.

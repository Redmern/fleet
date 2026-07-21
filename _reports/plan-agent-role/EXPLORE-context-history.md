# EXPLORE — context / seed-bloat history (digest recovered from read-only explorer)

## PREMISE CORRECTION (load-bearing)
**The seed-bloat bug was NOT a context-window bug.**
- Commits: `c4376dd` (merged `ae61c81`; GATE-2 verdict `14117d9`; scoping follow-up `630a43a`)
- Root cause: **tmux `MAX_IMSGSIZE` = 16384 bytes.** The ~20KB `FLEET_SUBORCH.md` was inlined as a
  positional `claude -p` arg in one `tmux new-window` → `"command too long"` (rc=1) → swallowed by
  `2>/dev/null` → empty `win_id` → no pane → reconcile respawn loop.
- Fix: `suborch_seed()` deleted (`bin/fleet:1330`), replaced by ~200B pointer (`bin/fleet:1385`);
  `cmd_new` errors loudly on empty `win_id` (`bin/fleet:949-965`); manual reworded `FLEET_SUBORCH.md:9,18`.
- **An IPC/argv limit, not a token limit.** It says nothing about how much a sub-orch may think.
  (Line numbers here are as of the fix commit; current `bin/fleet` has the pointer at :1669-1671.)

## Recorded context-exhaustion failures: NONE
Grep across `_reports/`, `.fleet/notes/`, `.fleet/inbox/`, docs and all commit messages: **zero**
instances of a sub-orch or role agent exhausting its window, compacting, or being lost to context.
Every "parked"/"stranded" hit is the **tmux** sense (window in `<sess>_hidden`, ledger
`state=gate{1,2}-wait`) or a dead-owner ledger zombie. Only doc reasoning about context windows at
all: `_reports/dispatch-seed-fix/debate-con.md:12` (pointer removes a guaranteed-present in-context
manual — a *compliance* risk, not a capacity one).
⇒ **Empirical record is empty in BOTH directions: no evidence of harm, no evidence of safety.**

## Existing guidance: repo already sanctions sub-orch in-context work, but narrowly
- `FLEET_SUBORCH.md:5-6` — "you are NOT a thin router — **you do the work**: decompose the
  instruction, spawn fleet workers (**or do small work yourself**)"
- `:69` — "Classify it in your own context … Keep it to **one sentence of reasoning**"
- `:205` — "Decompose … **in your own context** — do NOT use Workflow/heavy orchestration on the
  critical path; a few lines of reasoning is enough."
- `:63` — trivial → "Do it yourself."
Pattern: **classification + decomposition in-context; anything with breadth gets delegated.**
Explicit counter-rationale to the proposal:
- `:98-100` — the three-role wrapper buys "**context-protection** (each sub-agent's bulk stays in
  its own context; the role agent keeps only digests)"
- `:154` — "Very large scope where one role agent's context cannot hold all sub-agent digests" is a
  MANDATORY escalation trigger.
Research-in-sub-orch-context inverts exactly this design intent.

## Crash recovery HAS been exercised — and was broken twice
- §3.0.5 `role-phase` cursor (added `85a29b1`) shipped **unrunnable**: told agents to call `meta_set`,
  an internal `bin/fleet` function with no CLI verb → `command not found`. Caught by BOTH independent
  testers at GATE 2; fixed `0677bdc` (plain `printf` append).
- `de0ab22` fixed `meta_get` returning the FIRST not LAST state line → resurrected finished
  dispatches every prompt.
- `FLEET_SUBORCH.md:193-198` mandates on-disk artifact cross-check because "without the cursor a
  mid-pipeline crash re-runs completed roles."

## Bottom line
**Recovery granularity is the real risk, not token capacity.** `fleet reconcile` re-animates
sub-orchs but knows nothing about in-flight Task sub-agents (`FLEET_SUBORCH.md:177-179`), and the
cursor's checkpoints are role boundaries. Research done *inside* the sub-orch's own context sits in
the gap between `research` and `gate1-wait`: a crash there is **unrecoverable work with no artifact
to cross-check**, whereas a RESEARCH role agent leaves `SYNTHESIS.md` on disk as the documented
recovery signal.
⇒ Any accepted form of this change MUST make the sub-orch's own research land on disk as a
checkpointed artifact before it spawns anything.

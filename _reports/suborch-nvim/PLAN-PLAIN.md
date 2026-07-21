# d25 suborch-nvim — plain English

## What you asked for

"A fleet sub-orchestrator should be opened with nvim open so that the produced
files are viewable. This means it should be opened in the folder where all its
created files are visible."

## What we found

The need is real. The sub-orchestrator is the one agent whose entire product is
*files* — STATUS.md, the ledger, and the curated reports you approve at gates —
and it's the only agent type with no file view. The impl and test workers, whose
product is a git diff, *do* get an editor. That's backwards.

But two things about the ask don't survive contact with the code.

**1. That folder doesn't exist.** The sub-orch's own cwd is the project root.
Opening nvim there shows you 50+ report folders and 20 ledger folders from every
dispatch ever run — and still *doesn't* show the impl/test reports, because those
live inside each worker's own worktree. There is no directory today from which one
dispatch's files are all visible. Reports land wherever the writing agent happened
to be standing; they only look co-located because prompts carry absolute paths.

That's not just an annoyance. Crash recovery reads `_reports/<slug>/SYNTHESIS.md`
relative to the sub-orch's cwd, so a scattered write makes the sub-orch silently
mis-read which phase it's in.

**2. "Open it with nvim" the literal way would break the dispatch.** Fleet decides
whether a sub-orch is alive by asking tmux what program its pane is running. `nvim`
already counts as alive. So if nvim becomes the pane's program, the pane reads
"alive" forever — including after the agent inside it has died. Auto-recovery would
never fire again, and a dead dispatch would sit there showing green. On top of that,
the nvim path delivers the startup prompt via a timing guess (wait 300ms, then wait
3 seconds, then type) instead of passing it directly, in a pane parked in a detached
session nobody is looking at. Those two failures compound into exactly the silent
stall we already fixed once.

## What we propose instead

Same outcome, different mechanism. Three steps.

**Step 1 — write down where the reports are.** One line, so the ledger records the
absolute reports path for each dispatch. Right now nothing connects dispatch `d25`
to slug `suborch-nvim`. This also fixes the crash-recovery bug above, on its own.

**Step 2 — make the folder real.** Have the sub-orch drop symlinks into its own
`.fleet/dispatch/<id>/` folder as it spawns each worker: one to the reports dir, one
to each worker's worktree, one to each worker's notes. It already writes a row per
worker there with exactly the information needed. This is a documentation change —
zero lines of bash. Afterwards `.fleet/dispatch/d25/` genuinely *is* "the folder
where all its created files are visible."

**Step 3 — put nvim next to the agent, not on top of it.** Instead of turning the
sub-orch's pane into nvim, add a *second* pane beside it running nvim rooted at that
folder. The agent's pane is left byte-for-byte identical, so every failure mode above
disappears by construction — liveness still probes the agent, the prompt is still
delivered directly, the owner link to workers is untouched. Fleet already does exactly
this trick for the dashboard pane in your main window, so it's a known-good pattern.

Net: the ask, satisfied literally, at ~10 lines of bash and one line of ledger.

## What we are not doing

- Not adding an `--editor` flag — the nvim spawn path hardcodes the *visible* session,
  so a scratch agent using it would pop out of its hidden parking spot. Costs more than
  it buys.
- Not giving every scratch agent an editor — a 6-way research fan-out would open six
  nvims.

---

## Proof design

This repo has no test runner. Proofs are standalone scripts under `test/`, in the
style of `test/reap-teardown-safety.sh`. Each must run against a throwaway tmux
session and an isolated `FLEET_ROOT` — **never** the real `.fleet/` ledger (a naked
`fleet dispatch` from a fleet pane mutates the real one).

**`test/suborch-viewer-liveness.sh`** — the critical one, guards the B1 regression.
Spawn a sub-orch with the viewer pane. Assert `tmux list-panes | head -1` is the
harness, not nvim. Then kill the harness process while leaving nvim running, and
assert `suborch_live` returns *false*. If this passes, we've proven the viewer can't
mask a dead agent — the single failure this design exists to avoid.

**`test/suborch-viewer-send.sh`** — guards footgun 3. After adding the viewer,
assert `tmux show -w @fleet_nvim_sock` on the sub-orch window is empty, then run
`fleet send so-<id> "ping"` and assert it took the plain send-keys path and landed
in the harness pane, not nvim.

**`test/suborch-viewer-focus.sh`** — guards footgun 2. Immediately after the split,
assert `#{pane_active}` is the harness pane, so `fleet send` / `fleet mode` can't
transiently target the viewer.

**`test/suborch-viewer-idempotent.sh`** — call `resolve_or_spawn_suborch` twice for
the same id; assert exactly one pane carries `@fleet_viewer 1`.

**`test/dispatch-symlink-farm.sh`** — after a dispatch spawns two workers, assert
`.fleet/dispatch/<id>/reports` resolves to a real directory and each worker's
worktree link resolves. Then simulate `fleet reap` deleting a worktree and assert
the dangling link doesn't crash the sub-orch or the dashboard.

**Manual check, once, by hand** — nothing automated covers this: open the viewer
pane and confirm oil.nvim renders the farm and that following a symlink opens the
real file. Also confirm the sub-orch window still tears down cleanly with two panes
(`safe_kill_window` already iterates all panes, so this should pass — but confirm,
given the whole-session-teardown incident).

**One thing to settle before merging:** two of our researchers disagreed about
whether dashboard rows are derived per-pane or reported by the hook. If per-pane, the
viewer pane will add a spurious dashboard row and skew the hidden-window count, and
needs a filter. Check empirically rather than trusting either report.

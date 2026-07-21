# ADVISE — CONTEXT BUDGET AND FAILURE MODES (sub-orch pane)

Lens: the sub-orch is the **only long-lived, non-disposable context in a dispatch**. Every other
pane in the pipeline is throwaway. The proposal moves work INTO the one context that cannot be
recreated. That is the whole risk, and it is quantifiable.

---

## 1. What is actually in a sub-orch's context at spawn

Measured (`wc -c`), against a claude harness spawned by `resolve_or_spawn_suborch`
(`bin/fleet:1639-1676`):

| Item | Source | Bytes | ≈tokens | Loaded when |
|---|---|---|---|---|
| Pointer seed prompt (3 lines) | `bin/fleet:1669-1671` | ~250 | ~70 | at spawn, via `cmd_new --scratch -p` |
| `FLEET_SUBORCH.md` (the manual) | `FLEET_SUBORCH.md:1-385` | **21,655** | **~5.4k** | first action, ordered by seed `bin/fleet:1670` |
| `<root>/CLAUDE.md` | `/home/red/proj/pc-tune/CLAUDE.md` | 3,765 | ~0.95k | auto, harness startup (CWD=root, `bin/fleet:1669`) |
| `~/CLAUDE.md` | `/home/red/CLAUDE.md` | 5,613 | ~1.4k | auto, harness startup |
| `instruction.txt` + `meta.tsv` + `workers.tsv` | `FLEET_SUBORCH.md:15-32` | ~0.5–2k | ~0.5k | first action |
| SIP `SKILL.md` (when a feature) | `.claude_personal/skills/fleet-implementation-pipeline/SKILL.md` | 12,623 | ~3.2k | on `Skill` invoke, `FLEET_SUBORCH.md:332` |
| harness system prompt + tool schemas | — | — | ~10–15k | always |

**Baseline ≈ 22–27k tokens before the sub-orch has done one useful thing.** On a 200k window that
is ~12%; headroom ≈ 175k. Note `AGENTS.md` (12,463 B) is *additional* on the omp/opencode path —
those harnesses start ~3k heavier.

The seed itself is deliberately tiny: `bin/fleet:1658-1663` documents that inlining the ~20KB
manual overflowed tmux `MAX_IMSGSIZE` (16384), `new-window` died with "command too long", rc
swallowed by `2>/dev/null`, and **the sub-orch never spawned**. That is the ae61c81 class of bug.
Guard now at `bin/fleet:1180-1192` (blank-wid → loud FAIL). This proposal does **not** re-open the
seed-size bug (research is runtime, not seed) — it opens a *different* one: runtime context
exhaustion, which has **no** equivalent loud failure.

## 2. Marginal cost of "sub-orch does the research itself"

For a realistic feature in *this* repo:

- `bin/fleet` = **271,604 B ≈ 68k tokens**. One naive full `Read` of it is **~35% of a 200k
  window** and ~2.5× the sub-orch's entire baseline. `bin/fleet-dash` = 98,782 B ≈ 25k.
- A disciplined manual read pass (8–12 files, ranged reads, 10–15 greps with capped output):
  **15–30k tokens.**
- An undisciplined pass (2–3 full source reads + unbounded greps + `git log -p`): **80–120k tokens.**
- If the sub-orch *also* fans out its own Task sub-agents: each digest is 0.5–2k, and the fan-out
  bookkeeping/tool results add more. 5 explorers ≈ **5–12k**, and critically the digests land in
  the context that must survive to gate 2 — the exact opposite of the "context-protection"
  rationale in `FLEET_SUBORCH.md:96-98`.

Compare the status quo: today's RESEARCH role (`FLEET_SUBORCH.md:108-118`) burns all of that in a
**disposable scratch pane** that is dead before impl starts. The sub-orch pays ~0 for it and gets a
file path. The proposal converts a free externality into a permanent tax on the critical context.

**Realistic post-research sub-orch state:** disciplined ≈ 45–55k used (≈75% headroom) — survivable.
Undisciplined ≈ 110–150k used (≈25% headroom) — dead by gate 2.

## 3. What happens when the sub-orch runs low MID-PIPELINE

This is the load-bearing finding. **There is no recovery for a context-exhausted sub-orch, only for
a dead one — and they are different events.**

Trace: `cmd_reconcile` (`bin/fleet:1979-2018`) is the only re-animation path.
- It skips terminal states only: `case "$state" in done|failed|cancelled) continue ;;`
  (`bin/fleet:1990`) — so `gate1-wait` *is* eligible (the known parked-revival footgun).
- It acts **only if `! suborch_live "$d" "$sess" "$wn"`** (`bin/fleet:1995`), and `suborch_live`
  (`bin/fleet:1605-1616`) tests *window exists + harness in foreground*.

Therefore:

- **Auto-compaction does not kill the pane.** The harness stays live, `suborch_live` is true,
  reconcile is a **no-op**. §3.0.5's role-phase recovery (`FLEET_SUBORCH.md:174-197`) is written for
  *respawn*, and a compacted sub-orch **never respawns** — it keeps running on a lossy summary.
  §3.0.5 does **not** survive a compaction; it is bypassed by it.
- Post-compaction the sub-orch has: no manual text, no instruction text, only whatever the summary
  preserved. Nothing re-injects `FLEET_SUBORCH.md`. The rules most likely to be summarized away are
  precisely the load-bearing ones: §7's "post gate, **END YOUR TURN**, never proceed"
  (`FLEET_SUBORCH.md:336-351`) and §3.0.2's "Task tool only, never `fleet new`"
  (`FLEET_SUBORCH.md:100-106`).
- **At gate1 park** the sub-orch is idle for a human-scale interval, then un-parked by a **pop whose
  entire body is 5 short lines** (`gate_post`, `bin/fleet:1927-1931`) — sentinel + a path + two
  bullets. It carries **no pointer back to the manual and no role-phase reminder**. A compacted
  sub-orch popped at gate 1 is asked to run Phase 3 on the strength of a summary.
- **At gate2** the sub-orch must *review a diff, merge, push* (`FLEET_SUBORCH.md:376`) — the
  highest-consequence action in the pipeline, executed at the point of minimum remaining context.
- **If it does die**, respawn is actually the *clean* path (fresh pointer prompt → clean context →
  re-read manual + instruction + cursor). But `FLEET_RECONCILE_CAP` defaults to **1**
  (`bin/fleet:2007`): the **second** death with no live workers sets `state failed`
  (`bin/fleet:2010`) and abandons the dispatch. Context-driven instability that kills the pane twice
  therefore **hard-fails a real pipeline**.

Net: the failure is **silent and un-instrumented**. Nothing in `bin/fleet` observes sub-orch context
usage; there is no health signal between "working" and "window gone".

## 4. HARD, checkable budget rules for the sub-orch research step

State these as a numbered block in the manual. Every one is countable from the pane transcript, so a
human can audit a run after the fact.

**R1 — No whole-file reads over 400 lines.** Use ranged `Read` (`offset`/`limit`) or `sed -n
'A,Bp'`. Rationale in one clause the manual should carry verbatim: *`bin/fleet` alone is ~68k
tokens; one careless read costs a third of your window and you cannot get it back.*

**R2 — ≤ 10 file reads, ≤ 200 lines each.** Ceiling ≈ 2,000 lines ≈ 25k tokens.

**R3 — ≤ 15 search invocations, every one output-capped** (`| head -40`). No uncapped `grep -r`,
no `git log -p`, no `git log` beyond `--oneline -20`.

**R4 — Write-through, never hold.** Every finding is appended to `_reports/<slug>/RESEARCH.md`
**as it is found**. Forbidden: "I'll synthesize at the end." The file, not the context, is the
artifact; a compaction must be able to destroy the context without destroying the research.

**R5 — Handoff is a PATH, never a payload.** The PLAN agent's `-p` prompt cites
`_reports/<slug>/RESEARCH.md` and must not inline its content — inlining re-imports the whole cost
into the seed (the ae61c81 failure mode, `bin/fleet:1658-1663`) *and* into the sub-orch's context.
Cap `RESEARCH.md` at **150 lines**.

**R6 — The sub-orch spawns NO Task sub-agents for research.** Digests land in the one context that
must survive to gate 2. Needing breadth is not a reason to fan out — it is the **signal that the
research step is over**: write what you have, spawn the PLAN agent, and let *it* fan out (that is
its charter, and its context is disposable).

**R7 — Hard step box: ≤ 25 tool calls.** On hitting 25, **stop unconditionally** and spawn the PLAN
agent with whatever `RESEARCH.md` contains, plus an explicit `## OPEN QUESTIONS` section. Incomplete
sub-orch research is *by design* — completeness is the PLAN agent's job.

**R8 — Forbidden actions:** running the test suite; reading `_reports/` of unrelated slugs; reading
the SIP `SKILL.md` more than once; reading `FLEET_SUBORCH.md` more than once; any `cat` of a file
> 400 lines; any recursive directory dump.

**R9 — Record the spend (auditable).** Before spawning PLAN:
`printf 'research-toolcalls\t%s\n' "$n" >> .fleet/dispatch/<id>/meta.tsv`. A human greps this across
dispatches; sustained values near 25 mean the budget is mis-set, not that the sub-orch is lazy.

**R10 — Headroom floor.** The sub-orch must reach gate-1 park with **≥ 60% of its window free**. If
its harness surfaces usage, check it; if not, R1–R8 are the proxy that enforces it.

## 5. The tripwire

**Observable symptoms (any ONE of these means this change went wrong):**

1. A compaction/"context low" banner appears in a `so-*` pane **before gate 1** — the single
   clearest signal. Under the status quo this essentially never happened, because the sub-orch only
   ever spawned and watched.
2. The sub-orch **proceeds to impl without posting/parking GATE 1** (`fleet gate waiting` shows
   nothing, ledger state jumps past `gate1-wait`). Classic post-compaction loss of §7's END-TURN
   rule (`FLEET_SUBORCH.md:336-351`).
3. The sub-orch calls **`fleet new` from inside a role agent's role**, or a *role agent* calls
   `fleet new` — the §3.0.2:100-106 rule is another summarization casualty.
4. A **duplicate role run**: two `<slug>-research`/`<slug>-plan` windows, or `RESEARCH.md` rewritten
   after the PLAN agent started — the role-phase cursor was lost.
5. `respawns` ≥ 1 in `meta.tsv`, or a `reconcile: abandoned <id> (state=failed)` dashboard alert
   (`bin/fleet:2011`) on a pipeline that still had real work.
6. `research-toolcalls` (R9) ≥ 25 on more than ~1 dispatch in 5.

**What the manual must tell the sub-orch to do at that point — escalate per §3.0.3
(`FLEET_SUBORCH.md:143-160`).** Add the sub-orch itself as a named escalation trigger, extending the
existing "very large scope where one role agent's context cannot hold all sub-agent digests"
(`FLEET_SUBORCH.md:155`):

> **If your own research exceeds the budget (R1–R8), or you see a compaction warning at any point:
> STOP researching immediately.** Append what you have to `_reports/<slug>/RESEARCH.md` under
> `## INCOMPLETE — escalated`, write the role-phase cursor (§3.0.5), then **escalate the research to
> a sibling fleet agent** — `fleet new --scratch <slug>-research -p "…"` — i.e. fall back to the
> pre-change shape. Record the escalation in `STATUS.md`, watch it on your own pane, end your turn.
> Your context is the only one in this dispatch that cannot be rebuilt; protect it in preference to
> finishing the research yourself.

**Design consequence:** this escalation must be a **first-class, always-available path**, not an
exception — which means the RESEARCH-role spawn machinery must be **kept**, not deleted, when
RESEARCH is renamed to PLAN. Removing it removes the only safety valve.

**One additional hardening, cheap and independent of the rest:** make the gate-1/gate-2 pop body
carry a manual pointer. `gate_post` (`bin/fleet:1927-1941`) has room for one line —
`Re-read your manual if unsure: <FLEET_DIR>/FLEET_SUBORCH.md` — which makes an un-parking
compacted sub-orch self-healing at the two moments it matters most. Today it gets a sentinel and a
path and nothing else.

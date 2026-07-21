# SYNTHESIS — plan-agent-role

## VERDICT: **BUILD** — but build the *revised* mechanism (design G), not the ask as literally stated.

Four adviser lenses (pro / con / alternatives / context-budget) plus three explorer passes.
The debate converged hard. Where it converged, I state it as settled; where it split, I rule.

---

## What the human is actually right about (PRO's defect case, unrefuted by CON)

The ask names a real, currently-unfixed defect — three of them, in fact:

1. **The sub-orch classifies and names the work blind.** It decides question/trivial/feature
   (`FLEET_SUBORCH.md:51-73`) and picks the slug (`:75-88`) having read *nothing*. That slug is then
   baked into six downstream contracts: `_reports/<slug>/`, the branch `fleet/<slug>`, the GATE 1
   sentinel (`bin/fleet:1925`), the loop key (`:141`), the window name, and the worker dedup key.
2. **The Role 1 `-p` prompt is authored by someone who has read nothing** (`:108`). The single most
   leveraged prompt in the pipeline is written from the instruction text alone.
3. **The role named RESEARCH emits no findings artifact.** Its outputs are `PLAN.md`,
   `SYNTHESIS.md`, `PLAN-PLAIN.md` (`:116-118`) — all *planning* artifacts. There is nowhere in the
   pipeline that says "here is what is true about this codebase." That naming incoherence is exactly
   what the human noticed.

CON did not dispute any of these. It disputed only the *remedy*.

## What the human is wrong about (CON's strongest hit, accepted)

**Part of the ask is already shipped.** "The plan agent may spawn more research sub-agents inside
itself" is the status quo — `FLEET_SUBORCH.md:110` already has Role 1 fanning out 1–N explorer
sub-agents, and `SKILL.md:67` is literally titled "Research → implementation plan". This part of the
ask is a **no-op**; implementing it changes nothing. It is kept in the plan only as *wording* work
(making it harness-neutral), not as behaviour.

## The ruling on the disputed part: sub-orch-does-research

CON's rejection of unbounded sub-orch research is **upheld**. Three independent arguments, none
rebutted by PRO:

- **It saves zero windows.** 3 fleet agents before (research/impl/test), 3 after
  (plan/impl/test). The context cost is paid for nothing.
- **It inverts the stated purpose of the role wrapper.** `FLEET_SUBORCH.md:96-98` says the wrapper
  exists for "context-protection (each sub-agent's bulk stays in its own context)". `:154` makes
  "context cannot hold all the digests" a *mandatory escalation trigger*. The proposal moves the
  most context-hungry phase into the one pane that is immortal by design (`:310`) and can never be
  thrown away.
- **Crash asymmetry (S1).** Today a research crash costs one disposable scratch pane. Under the
  literal ask, research crash *is* sub-orch crash: no artifact on disk, `fleet reconcile` respawns,
  restart from zero, second crash hits `FLEET_RECONCILE_CAP` (default 1, `bin/fleet:2007`) →
  `state failed`, **dispatch abandoned**.

**But the remedy survives in bounded form.** Every lens — including CON — independently proposed the
same shape: a small, hard-capped, write-to-disk orientation pass. CON said ≤5 calls / ≤15 lines /
`ORIENT.md`; PRO said ≤12 calls / ≤3 files / ≤40 lines / `RECON.md`; ALTERNATIVES said do it with
**one orientation sub-agent** so the cap is structural rather than behavioural. That convergence
from four adversarial directions is the strongest signal in this research.

**Ruling:** ALTERNATIVES wins the mechanism. A behavioural budget ("read at most 3 files") is a rule
the model must obey under pressure, at the exact moment it feels under-informed. A sub-agent digest
contract is a cap it *cannot* violate, because the bulk physically never enters the sub-orch's
context. Where the harness has no sub-agent facility, CON's inline numeric cap is the fallback.

## Settled unanimously (all four lenses, independently)

- **The adviser debate stays in the role agent.** Three separate arguments reached this: a single
  context cannot debate itself; adviser digests are precisely the bulk the wrapper exists to
  exclude (`:97-98`); and the sub-orch owns dispatch success, making it a conflicted adjudicator of
  a possible REJECT — the same conflict `§3.0.4:162-172` eliminated on the test side.
- **The handoff is a PATH, never an inlined payload.** BRIEF.md's "inline in the -p prompt" option
  is the literal mechanism of the `ae61c81` outage (`bin/fleet:1658-1663`, tmux `MAX_IMSGSIZE`).
  Rejected outright.
- **Artifact names stay byte-identical.** `bin/fleet:1925` hardcodes `_reports/$slug/PLAN-PLAIN.md`
  into the GATE 1 body the human pops. Rename it and the gate posts a dead pointer, silently.
- **The `<slug>-research` sibling-spawn machinery is KEPT** when the role is renamed. It is the only
  escape valve when the sub-orch's own recon overruns (`§3.0.3`).

## The correction that reframed everything

**The seed-bloat bug was never a context bug.** It was tmux `MAX_IMSGSIZE` = 16384 killing an
inlined 20KB manual — an argv/IPC limit, rc=1 swallowed by `2>/dev/null` → empty `win_id` → respawn
loop. The brief (and my own framing) treated it as evidence about sub-orch context capacity. It is
not. Grep across `_reports/`, `.fleet/notes/`, `.fleet/inbox/` and all commit messages found **zero**
recorded context-exhaustion incidents. The empirical record is empty in *both* directions.

So this decision is made on architecture and crash-asymmetry, not on precedent. Stated plainly
because the plan should not borrow false authority from a bug that was about something else.

## The pre-existing hole this research surfaced (not caused by the change)

**No recovery exists for context exhaustion, only for pane death.** `cmd_reconcile`
(`bin/fleet:1979-2018`) acts only when `!suborch_live` (`:1995`). A compaction leaves the pane
*alive* — so reconcile is a no-op, and `§3.0.5`'s role-phase recovery, written for respawn, is
**bypassed rather than protected against**. The GATE 1 unpark body is 5 lines
(`bin/fleet:1927-1931`) with no manual pointer, so a compacted sub-orch proceeds to Phase 3 and then
**merges and pushes at GATE 2 off a lossy summary**.

This is true today, independent of this change. It is filed as a separate work item (W6), and it is
arguably more urgent than the change that found it.

## Verdict summary

| Part of the ask | Ruling |
|---|---|
| Sub-orch does research itself | **REVISED** → hard-capped RECON via one orientation sub-agent, output to `RECON.md` |
| Rename RESEARCH → PLAN | **BUILD**, prose-only; `role-phase` value and artifact names unchanged |
| PLAN agent spawns research sub-agents | **NO-OP** — already shipped; kept as harness-neutral rewording only |
| Research + planning "work together" | **BUILD** — delivered by the RECON.md handoff contract + mandatory `## Corrections` section |
| Adviser debate | **UNCHANGED** — stays in the PLAN agent |

**BUILD.** Doc-only change, zero required `bin/fleet` edits, GATE 1 contract byte-identical.
Full plan in `PLAN.md`; plain-English version and proof design in `PLAN-PLAIN.md`.

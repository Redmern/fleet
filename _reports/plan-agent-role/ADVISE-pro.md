# ADVISE-pro — the strongest honest case FOR sub-orch recon + RESEARCH→PLAN

Verdict: **BUILD, with the sub-orch's own research renamed and hard-capped as RECON.**
The human's instinct is right and identifies a real defect. The naive form of it
(sub-orch "does the research") would kill the dispatch layer. The engineered form
below gets the benefit at ~12 tool calls of sub-orch context.

---

## 0. Why this change is right (the affirmative case)

Three concrete defects in today's design that the change fixes:

**(a) The sub-orch classifies and slugs BLIND.** `FLEET_SUBORCH.md:51-73` makes the
sub-orch decide question/trivial/feature — the single highest-leverage decision in the
pipeline, since it chooses between 0 agents and 3 role agents + 2 human gates — from
`instruction.txt` prose alone, with **no oracle** (:70) and an explicit instruction not
to over-think (:72). Then `:75-88` has it pick a slug, also blind, and that slug becomes
the `_reports/<slug>/` path, the branch `fleet/<slug>` (:120), the gate sentinel
(`bin/fleet:1925`), and the loop key `<slug>-research-2` (:141). A blind slug is baked
into six downstream contracts. Ten minutes of looking at the repo makes both decisions
evidence-based. This alone justifies the change.

**(b) The current handoff is a prompt written by someone who has not looked.** Role 1 is
spawned `-p "<prompt>"` (:108) by a sub-orch that has read nothing. The research agent
then burns its first turns re-deriving which repo, which subsystem, and whether prior
loop reports exist — work the sub-orch is better placed to do once, and which the sub-orch
needs anyway to review the returned plan competently (§4's "review between phases").

**(c) RESEARCH/PLAN really are two jobs, and today's role does both badly.** The role is
named RESEARCH but its output contract (`PLAN.md`, `SYNTHESIS.md`, `PLAN-PLAIN.md`,
:116-117) is entirely planning artifacts. There is no artifact that holds *findings*. The
rename is not cosmetic: it lets the sub-orch own orientation (cheap, single-context,
non-adversarial) and the plan agent own analysis + debate (expensive, needs many contexts).

**The honest limit:** the sub-orch is the sole fleet-agent spawner, must survive both
gates and N loop iterations, and its context dying strands the whole dispatch (BRIEF:37-40,
the ae61c81 seed-bloat class). So the *only* safe version of this is a hard-capped recon.
Everything below is that cap.

---

## Q1 — What the sub-orch researches itself: scope + budget

**Call it RECON, not research.** The name is load-bearing: "research" invites the sub-orch
to keep pulling the thread; "recon" means *find the territory, then get out*.

### MAY (allowlist)
- `cat .fleet/dispatch/<id>/instruction.txt` (already mandatory, §1)
- `ls` / `fleet ls` / `git log --oneline -10` on the candidate repo — orientation
- `grep -rn` with **≤5 keyword terms** drawn from the instruction
- **Read at most 3 files**, and prefer bounded reads (a function, a section) over whole files
- Read any existing `_reports/<slug>*/` from a prior loop iteration

### MUST NOT (denylist — each maps to a specific failure)
- **No harness sub-agents.** Their digests are the biggest context load in the pipeline
  (:97-98); that is precisely what the role-agent wrapper exists to keep out of you.
- **No implementation plan.** No "change function X", no file-by-file design. That is the
  plan agent's deliverable and you would be pre-empting the debate with an un-attacked design.
- **No adviser lens, no verdict, no BUILD/REVISE/REJECT.** See Q4.
- **No `_reports/<slug>/PLAN.md`, `SYNTHESIS.md`, or `PLAN-PLAIN.md`.** Those three names
  are the GATE 1 contract (`bin/fleet:1925`) and belong to the plan agent, always.
- **No reading a 4th file "just to be sure".** The budget is the mechanism.

### Hard budget
**One turn. ≤12 tool calls. RECON.md ≤40 lines.** If recon cannot orient inside that, the
instruction is under-specified — post it to the inbox at `--sev blocked` (§5) rather than
spending more context; a vague instruction is a human problem, not a research problem.
Recon runs *between* §3.0.1 classify and §3.0.1a rename, and **may revise the
classification** — a feature that recon reveals as a one-liner drops to the flat path (:57).

### Artifact form: FILE, never inline
`_reports/<slug>/RECON.md`, and the plan agent's `-p` carries a **pointer** only.
- Inline re-creates the exact seed-bloat failure that ae61c81 fixed (BRIEF:37-38); the
  proven remedy in this codebase is already "compact pointer prompt".
- A file survives sub-orch crash + `fleet reconcile` respawn. Inline does not.
- It is the cross-check artifact for the new cursor phase (Q2) — inline has no crash marker.

---

## Q2 — Cursor sequence + artifact cross-check

**New sequence** (replaces `FLEET_SUBORCH.md:183`):

```
recon → plan → gate1-wait → impl → test → gate2-wait → done
```

**Zero code change.** Verified: nothing in `bin/fleet`, `bin/fleet-dash`, `bin/fleetd`
reads `role-phase` — it is a purely model-facing convention. The `state` field is the one
with code semantics (`gate1-wait`/`gate2-wait` at `bin/fleet:1972` drive `gate_waiting` →
reap-skip; `done|failed|cancelled` at `bin/fleet:1986` drive reconcile-skip) and this
change **does not touch `state` at all**.

| role-phase | Artifact proving it complete | Resume action on respawn |
|---|---|---|
| `recon` | `_reports/<slug>/RECON.md` | absent → do recon; present → **do not re-run it**, go spawn the plan agent |
| `plan` | `_reports/<slug>/SYNTHESIS.md` | absent → respawn plan agent seeded with RECON.md; present → read verdict, §7 |
| `gate1-wait` | `state=gate1-wait` **and** `fleet inbox list \| grep "GATE 1"` | end turn, stay parked; re-post the gate only if the message is missing (:348) |
| `impl` | branch `fleet/<slug>` exists with commits | absent → respawn impl seeded with PLAN.md+SYNTHESIS.md |
| `test` | `_reports/<slug>/TEST-VERDICT.md` | absent → respawn test role on the impl branch |
| `gate2-wait` | `state=gate2-wait` + GATE 2 in inbox | end turn, parked |
| `done` | `fleet dispatch done <id>` written | nothing |

**RECON.md is the change's crash-recovery bonus, not its cost.** Today a sub-orch that dies
between classify and spawn loses its classification *and* its slug silently, and the respawn
re-derives both — possibly differently, forking `_reports/` paths. RECON.md pins slug +
classification to disk before any agent is spawned. This is a net improvement to §3.0.5.

**Legacy mapping (one line in the manual):** a respawn reading the old vocabulary
`role-phase research` treats it as `plan`; if `PLAN.md` exists and `RECON.md` does not, it
is a pre-change dispatch — skip recon entirely and resume at the old cursor.

---

## Q3 — Handoff contract (anti-duplication without a bottleneck)

### `_reports/<slug>/RECON.md` — required sections, ≤40 lines total

```markdown
## TASK
One paragraph restating instruction.txt in the codebase's own vocabulary.

## SLUG
<slug>  (from: fleet slug "<canonical intent phrase>")   # reproducible on respawn/loop

## TERRITORY
repo: <repo>   base: <branch>
- path/file.sh:120-141 — why this is relevant (one line, no analysis)
- ... 3-8 entries, each with file:line

## PRIOR ART
Earlier loop reports under _reports/<slug>*/, or "none".

## OPEN QUESTIONS
2-5 things recon deliberately did NOT resolve.  <-- this is the plan agent's agenda

## RECON BUDGET SPENT
<n> tool calls, <m> files read.   # honesty marker; makes overruns visible in review
```

### The trust asymmetry (the actual contract)

Put this verbatim in the plan agent's `-p`:

> `_reports/<slug>/RECON.md` is a **starting map, not findings.** Treat **TERRITORY** as
> already verified — do not re-derive which repo/subsystem this is. Treat **OPEN QUESTIONS**
> as your research agenda, not your ceiling: fan out explorer sub-agents there and anywhere
> RECON.md is silent. **You are expected to contradict it** where the code disagrees — if
> TERRITORY is wrong, say so in a `## Corrections` section of `PLAN.md` and proceed from
> what you found. RECON.md is never authoritative over the code.

Three properties, deliberately: facts are **trusted** (kills duplication), questions are
**owned** (guarantees real research still happens), contradiction is **licensed** (kills the
bottleneck). The mandatory `## Corrections` section matters because the sub-orch is a single
un-adversaried reader — without an explicit falsification path, one bad recon read poisons a
pipeline that has no lens positioned to catch it.

---

## Q4 — Debate stays in the PLAN agent. Not negotiable.

1. **Adversarial ⇒ plural contexts.** §3.0.4 (:162-172) is explicit that a single point of
   judgment is weaker than the gate it replaces. The sub-orch is one context and cannot
   debate itself; moving lenses there would degrade the property to self-certification —
   the exact thing the manual forbids on the test side.
2. **Adviser digests are the heaviest context load** in the pipeline. The wrapper's stated
   purpose (:97-98) is keeping that bulk out. Moving it into the *sole fleet-agent spawner*
   inverts the design.
3. **Survival.** The sub-orch must live across GATE 1, GATE 2, and N loop iterations (§6,
   :309-321). Putting the most token-hungry phase on its critical path threatens the whole
   dispatch, not one role (BRIEF:39-40).

Recon is safe in the sub-orch **precisely because it is pre-adversarial**: it produces no
plan, no verdict, no lens — nothing that needs attacking. That is the clean line between
what the sub-orch may do and what it may not, and it is why this change is safe while
"sub-orch does the research" would not be.

---

## Q5 — Harness-neutral wording

The manual already says "harness Task sub-agents" (:91, :101). Tighten to the FLEET.md
house style ("where your harness supports them") at first use:

> **harness sub-agents** (claude: the `Task` tool; omp / opencode: their equivalent
> agent/sub-agent verb — see `fleet harnesses`)

**Plus a degradation clause that is missing today** — a latent hole this change should close:

> If your harness has **no** sub-agent facility, you **must not** run all lenses in your own
> single context — that silently collapses the debate to one point of judgment (§3.0.4).
> Escalate to sibling fleet agents via §3.0.3 instead, posting the request to the sub-orch.

---

## Q6 — Backward compatibility

- **GATE 1 contract is byte-identical.** The plan agent's outputs stay `PLAN.md`,
  `SYNTHESIS.md`, `PLAN-PLAIN.md` — `gate_post` defaults to `_reports/$slug/PLAN-PLAIN.md`
  (`bin/fleet:1925`) and is untouched. `gate_park`, `gate_waiting`, reap-skip, and
  `cmd_reconcile` all key off `state`, never `role-phase`. **No bin/fleet change required.**
- **RECON.md is purely additive** — no code references it; an in-flight dispatch that never
  produces one still works.
- **In-flight dispatches** are covered by the Q2 legacy line (`research` → `plan`; missing
  RECON.md ⇒ pre-change dispatch, skip recon).
- **Required companion edit:** `SKILL.md` Phase 1 (:67-76) and the gated-mode bullet
  (:162-164) must change in the same commit. The sub-orch reads both documents; if the skill
  still says "spawn a research agent" while the manual says recon-then-plan, the sub-orch
  gets contradictory instructions — the worst possible outcome for a doc-only change.
- **Window naming:** `<slug>-research` → `<slug>-plan`, loop key `<slug>-research-2` →
  `<slug>-plan-2` (:141). Display + dedup only; an in-flight `-research` window cannot
  collide with a new `-plan` one.
- **Rollback** is deleting two doc sections. No migration, no state, no schema.

---

## Proposed replacement markdown

### NEW — insert as §3.0.1b, between rename (:75-88) and the roles (:90)

```markdown
### 3.0.1b RECON — orient yourself BEFORE you spawn (hard-capped)

You classified and slugged from prose alone. Ground both in the code **once**, cheaply,
before spawning anything. This is **recon, not research**: find the territory, then stop.

**You MAY:** `fleet ls`; `ls` / `git log --oneline -10` on the candidate repo; `grep -rn`
with ≤5 terms from the instruction; **read at most 3 files** (prefer bounded reads); read
any prior-loop `_reports/<slug>*/`.

**You MUST NOT:** spawn harness sub-agents; write an implementation plan or name the
functions to change; run any adviser lens or produce a verdict; write `PLAN.md`,
`SYNTHESIS.md`, or `PLAN-PLAIN.md` (those three are the GATE 1 contract and belong to the
plan agent). No 4th file.

**Budget: ONE turn, ≤12 tool calls, ≤40 lines of output.** You are the sole fleet-agent
spawner and must survive both gates and every loop iteration — context you spend here is
context the pipeline never gets back. If recon can't orient inside the budget, the
instruction is under-specified: post it `--sev blocked` (§5) instead of spending more.

Recon may **revise your classification** — a "feature" that turns out to be a one-liner
drops to the flat path (§3.0.1). Write the result to `_reports/<slug>/RECON.md`:

    ## TASK             one paragraph, in the codebase's vocabulary
    ## SLUG             <slug> (from: fleet slug "<canonical intent phrase>")
    ## TERRITORY        repo, base branch, 3-8 `file:line` entry points + one line each
    ## PRIOR ART        prior-loop reports under _reports/<slug>*/, or "none"
    ## OPEN QUESTIONS   2-5 things you deliberately did NOT resolve — the plan agent's agenda
    ## RECON BUDGET SPENT   <n> tool calls, <m> files read

Then set the cursor (§3.0.5) and spawn Role 1. **A file, never inline in `-p`** — a fat
prompt is what once stopped sub-orchs spawning at all, and the file is what a respawned
you reads to know recon is already paid for.
```

### REPLACEMENT — §3.0.2 Role 1 (replaces :108-118 verbatim)

```markdown
**Role 1 — PLAN** — `fleet new --scratch <slug>-plan -p "<prompt>"` (repo-less, reads code
in place). **Research *and* planning live here**: your RECON.md is a map, not findings.
The role agent fans out via harness sub-agents (claude: the `Task` tool; omp / opencode:
their equivalent agent verb — see `fleet harnesses`):
- 1–N **explorer** sub-agents (scope-scaled), each mapping a subsystem and citing
  `file:line`, aimed **first at RECON.md's OPEN QUESTIONS** and then anywhere the plan
  still rests on an assumption.
- **≥2 adviser** sub-agents with distinct lenses — minimum **pro / con**; bigger scope adds
  alternatives, security/abuse, UX, cost. This IS the debate. It stays **here**, never in
  the sub-orch: a single context cannot debate itself (§3.0.4), and adviser digests are the
  bulk this wrapper exists to keep out of the sole fleet-agent spawner.
- a **synthesis** pass producing the verdict.

Its `-p` MUST carry the recon handoff verbatim:

> Read `_reports/<slug>/RECON.md` first. It is a **starting map, not findings.** Treat
> **TERRITORY** as verified — don't re-derive which repo/subsystem this is. Treat **OPEN
> QUESTIONS** as your research agenda, not your ceiling. **You are expected to contradict
> it** where the code disagrees: if TERRITORY is wrong, record it under `## Corrections` in
> `PLAN.md` and proceed from what you found. RECON.md is never authoritative over the code.

  Outputs (**unchanged** — this is the artifact contract the gates expect):
  `_reports/<slug>/PLAN.md`, `SYNTHESIS.md` (**BUILD / REVISE / REJECT**), `PLAN-PLAIN.md`
  (plain-English plan + **PROOF DESIGN**). **Plan only — no code.** On idle, read
  `SYNTHESIS.md`: REJECT/REVISE → handle per §7; **BUILD → GATE 1** (§7).
```

### PATCH — §3.0.5 cursor (replaces :183 and extends :194)

```markdown
recon → plan → gate1-wait → impl → test → gate2-wait → done
```

Cross-check line to add after :194:
`_reports/<slug>/RECON.md` present ⇒ recon done (**do not re-spend the recon budget**);
`SYNTHESIS.md` present ⇒ plan done; `TEST-VERDICT.md` present ⇒ test done.
**Legacy:** a cursor reading `research` is the old vocabulary — treat it as `plan`; if
`PLAN.md` exists and `RECON.md` does not, that dispatch predates recon — skip recon and
resume at the old cursor.

### PATCH — §3.0.2 loop key (:141)

`<slug>-research-2` → `<slug>-plan-2`.

---

## Risks I accept, and their mitigations

| Risk | Mitigation |
|---|---|
| Recon creeps into research; sub-orch context dies mid-pipeline | Numeric caps (12 calls / 3 files / 40 lines) + the `RECON BUDGET SPENT` self-report make overruns visible |
| Un-adversaried recon poisons the plan | Explicit falsification licence + mandatory `## Corrections` in PLAN.md |
| Plan agent treats RECON.md as complete and under-researches | OPEN QUESTIONS is a *required* section and is framed as agenda-not-ceiling |
| Manual and SKILL.md disagree | Ship both edits in one commit — this is a hard requirement, not a nicety |
| Doc-only change is unprovable | Proof = a real dispatch reaching GATE 1 with RECON.md present, PLAN.md containing a Corrections section, and `role-phase` walking `recon → plan → gate1-wait` |

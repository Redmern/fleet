---
name: fleet-implementation-pipeline
description: >
  USE as the fleet command-center orchestrator when the user asks to build a
  non-trivial implementation / feature / substantial change and wants it done
  rigorously. Runs a delegated, looped pipeline across fleet agents: recon → plan →
  implementation plan → adviser debate (2+ advisers, scaled to scope) → decision
  gate → implement → two INDEPENDENT test agents → test debate → done-or-loop
  (a re-implementation plan that builds on what's already there). Triggers on
  "implement / build / add this feature / rework X" requests inside a fleet
  session. Skip it for trivial mechanical edits and pure questions.
---

# Fleet implementation pipeline

A rigorous, delegated playbook the **orchestrator** follows for any non-trivial
implementation task. Each phase is **one** fleet agent; **breadth inside a phase fans out
via harness Task sub-agents by default**, not via N sibling fleet agents. The orchestrator
sequences the phase agents with `fleet watch`, reviews between phases, and never does the
implementation itself. Artifacts land under `_reports/<feature-slug>/`.

> Core fleet verbs (see FLEET.md): `fleet new <repo> <branch> [-p "…"] [--scratch] [--no-self-merge]`,
> `fleet watch <agents>… -m "<resume note>"` (then **end your turn**), `fleet ready`, `fleet reap`.
> Tell every dispatched agent to write scratch notes/plans to **`$FLEET_DOCS`**, not the repo.

## Fan-out mechanism — sub-agents by default, fleet agents by escape hatch

This is **one** pipeline shared by both the human's main pane and the dispatched
sub-orchestrator. The phase semantics + gate choreography below are identical for both;
only the spawn primitive for intra-phase breadth differs, and it has a **default** and an
**escape hatch**:

- **Default = Task sub-agents.** A phase is one fleet agent that fans out its advisers /
  testers / explorers via the **Task tool**. Fewer windows and worktrees, identical rigor,
  and each sub-agent's bulk stays in its own context (the phase agent keeps only digests).
  Sub-agents are **leaves** (no nested sub-agents) and **do not share context** — have each
  write detail to `$FLEET_DOCS` / `_reports/<slug>/` and return a short digest.
- **Escape hatch (mandatory option) = sibling fleet agents.** Any phase **may** escalate a
  unit of work to a real `fleet new` worktree-isolated agent when sub-agents are the wrong
  tool: **parallel-mutating implementation** (writers on overlapping files — Task
  sub-agents share one cwd and would corrupt each other), **stateful/destructive e2e** that
  needs genuine isolation, or **very large scope** that won't fit one context. On the
  dispatched path the phase agent posts the request to the sub-orch (the sole fleet-agent
  spawner); on the main pane the orchestrator spawns it directly. **Default = sub-agent;
  impl and stateful e2e are the sanctioned opt-ups.**
- The human at the main pane who wants **dashboard-visible, individually-message-able**
  advisers/testers just flips the same escape hatch on — it is a per-phase knob, not a
  second pipeline.

## When to run the full pipeline (scope gate)

Scale the rigor to the scope — don't carpet-bomb a one-liner with 5 agents. Counts below
are **Task sub-agents** spawned inside the one phase agent (the default fan-out); escalate
any of them to a sibling fleet agent only per the escape hatch above.

| Scope | Plan | Advisers | Implement | Test | Test debate |
|---|---|---|---|---|---|
| Trivial mechanical edit | skip — just do/delegate it | — | 1 worker | spot-check | — |
| Small feature / fix | 1 agent | **2** (pro / con) | 1 agent | **2** testers | adversary |
| Medium feature | 1 agent | **3** (pro / con / value-add) | 1 agent | 2 testers | adversary |
| Large / risky / cross-cutting | 1 agent | **4+** (add: alternatives, security/abuse, UX) | 1 agent (impl writers → escape hatch) | 2 testers | adversary |

"More advisers when the scope is bigger" — that's the user's rule. When unsure, lean to one
more adviser, not fewer. **Bias the classification toward the cheaper path** when unsure:
`question < trivial < feature`; only a clear feature earns the full pipeline.

## Phase 0 — RECON (one cheap read-only look, before Phase 1)

Before you write the Phase 1 prompt, take **one** cheap read-only look so you aren't
pointing an expensive agent at the wrong subsystem. Spawn **exactly one** read-only
sub-agent (claude: the Task tool) for a **≤15-line digest** — where the feature lives with
`file:line` anchors, what already exists that it would touch. **The sub-agent writes
`_reports/<slug>/RECON.md` itself, ≤25 lines**, and returns only the digest; you do not
write that file from the digest afterwards. The cap has to sit at the sub-agent's own
output boundary — applied to your own writing it is a rule you must remember exactly when
you feel under-informed, and measured, that broke twice out of two (33 and 35 lines).
`RECON.md` ends with a **`## BUDGET SPENT`** line — read-only calls and files actually
used — which is what makes the cap checkable from the artifact instead of the transcript.
No sub-agent mechanism in your harness? Do it inline, capped at **≤8 read-only calls**.

RECON must **not**: write an implementation plan, take a lens or emit a verdict, write
`PLAN.md` / `SYNTHESIS.md` / `PLAN-PLAIN.md`, write code, or spawn a second sub-agent.
**Tripwire:** if it blows the budget, write what you have, name what stayed unknown, and
move to Phase 1 anyway — do not loop. On the dispatched path this folds into the
`research` rung; it is **not** a new `role-phase` value (`FLEET_SUBORCH.md` §3.0.1b/§3.0.5).

## Phase 1 — PLAN → implementation plan

Spawn a **PLAN agent** (usually `--scratch`, repo-less, reads the code in place) — named
for what it produces, not for the reading it does on the way there:
- Read the relevant subsystem and **cite files/lines**. Produce a concrete implementation
  plan: storage/data model, the touch-points, what to reuse, what to remove, edge cases,
  migration, risks, and **open questions to seed the debate**.
- Write it to `_reports/<feature-slug>/PLAN.md`. **Planning only — no code.**

**The RECON handoff contract.** Seed the prompt with `RECON.md`, framed as *cheap and
**unverified** — treat every claim as a lead to verify, not a fact*. The trust runs one way:
**the PLAN agent overrules RECON, never the reverse.** So `PLAN.md` **MUST** carry a
`## Corrections` section listing each RECON claim it found wrong or misleading with the
`file:line` that settles it — required even when the recon was right, in which case it
reads `None — RECON verified accurate.` An absent section means nobody checked.

`fleet new --scratch <slug>-plan -p "PLAN ONLY … write _reports/<slug>/PLAN.md …"`
→ `fleet watch <slug>-plan -m "review the plan, then start the adviser debate"` → end turn.

## Phase 2 — Adviser debate

The PLAN phase agent fans out **2+ adviser sub-agents** (Task tool, per the scope
table). Give each the PLAN and a distinct lens. The minimum is **pro vs con**; bigger
scope adds lenses (alternatives, value-add additions for the user, security/abuse, UX,
cost/complexity). Each adviser:
- Argues its position grounded in the plan + code, and writes `_reports/<slug>/debate-<lens>.md`.
- Explicitly answers: **is this the best way? is there a better way? what additions would
  improve it for the user?**

Then **synthesize** (a synthesis sub-agent for large scope, or the phase agent itself):
a single verdict at `_reports/<slug>/SYNTHESIS.md` — **BUILD** (with the revisions/additions
the debate surfaced folded into the plan), **REVISE** (loop the plan), or **REJECT** (stop,
report to the user).

Sub-agents run concurrently; on the main pane you may instead escalate advisers to sibling
fleet agents (escape hatch) when you want them dashboard-visible.

### Decision gate
- **BUILD** → Phase 3 with the debate-revised plan.
- **REVISE** → loop Phase 1 with the debate's notes.
- **REJECT** → stop; report the reasoning to the user and ask how to proceed.

## Phase 3 — Implement

Spawn an **implementer** on a feature branch, seeded with the **debate-revised** plan
(reference `_reports/<slug>/PLAN.md` + `SYNTHESIS.md`). Tell it to write notes to `$FLEET_DOCS`.
- Default `--self-merge` per the project setting; use `--no-self-merge` for safety-critical
  paths (anything destructive, guard/keybind/teardown logic) so the orchestrator reviews first.
- Implement **directly** by default. Parallel writers are **NOT** a Task-sub-agent job —
  sub-agents share one cwd and would race the same tree. If large scope genuinely needs >1
  implementer, use the **escape hatch**: sibling fleet agents on **separate worktrees**,
  disjoint file regions. A single reviewer sub-agent is fine.

The orchestrator **reviews the returned diff** against the plan before/at integration.

## Phase 4 — Two INDEPENDENT testers

The test phase agent fans out **two independent tester sub-agents** (Task tool) that do NOT
share context. Each independently exercises the implementation end-to-end:
- **Isolate destructive/stateful fleet behavior** in a throwaway `/tmp` session via
  `FLEET_SESSION`; never touch the live `pc`/`techweb2`/`webshop` sessions or the orchestrator.
- Capture concrete evidence (commands run + observed output), mark WORKS / BROKEN / PARTIAL.
- Each writes `_reports/<slug>/TEST-<a|b>.md`.

Two independent testers (not one) so a single blind spot doesn't pass a broken feature. If
the e2e is stateful enough that two testers in one cwd would trample each other's repo
state, **escalate the testers to sibling fleet agents** (escape hatch) for real isolation.

## Phase 5 — Adversarial test verdict

The DONE verdict is **never** self-certified by the testers, and **never** "the phase agent
reconciles the two reports" — a single point of judgment is weaker than the adversarial
gate it replaces. Spawn a dedicated **adversary sub-agent** whose **sole job is to attack
the DONE verdict** given **both** tester reports (`TEST-a.md` + `TEST-b.md`): it hunts for
any way the feature is NOT done — missing edge case, regression, unmet spec point, a
trivially-passing test that proves nothing. It writes `_reports/<slug>/TEST-VERDICT.md`:
**DONE only if it fails to break the case**, otherwise **NEEDS-WORK** (with specifics).

### Decision gate
- **DONE** → integrate (review + merge + push as policy), reap worktrees, report to the user. **Finished.**
- **NEEDS-WORK** → **loop back to Phase 1**, but framed as a **RE-implementation plan**: research
  how to *build further on the already-implemented feature* (not from scratch) to close the gaps
  the test debate found. Then debate → implement → test → debate again. Repeat until DONE.

## Orchestrator discipline (every phase)

- **Never busy-poll.** Dispatch, run ONE `fleet watch <agents> -m "<what to do on wake>"`, and
  end your turn. Resume when pinged; read the phase's report + diffs; advance.
- **Review between phases** — you are the gate; don't rubber-stamp an agent's "done".
- Keep all artifacts under `_reports/<feature-slug>/` so each loop iteration is traceable.
- **You** integrate (review → merge → push → reap); workers don't decide "ship it".
- Tell the user which phase you're in and end the turn while agents run.

## Gated mode (dispatch-everything front door)

When this pipeline runs behind the **dispatch-everything** front door (`fleet dispatch mode all`),
the actor is a **sub-orchestrator** (`so-d<N>`), not the human's main pane, and two **human gates**
interrupt the auto-advance. **Rule: never advance past a gate on your own** — finishing the PLAN role or
finishing tests does NOT trigger the next phase; only the human **popping** your gate message does.
CLI primitives ship in fleet: `fleet gate post|parse|park`, `fleet integration-branch`,
`fleet dispatch mode all|sigil`; sub-orch turn discipline in `FLEET_SUBORCH.md §7`. The
sub-orch's **default decomposition** — the conservative question/trivial/feature classifier
(bias `trivial → flat`), the three-role pipeline, and the **REQUIRED `meta.tsv role-phase`
crash-recovery cursor** — lives in `FLEET_SUBORCH.md §3.0`. On this dispatched path each
phase here = one role agent (plan / impl / test); the adviser & tester fan-out is the
Task-sub-agent default above.

- **Phase 1 (PLAN) must output a PROOF DESIGN** — the explicit tests/checks that, if green, prove
  the feature works (success criteria + edge cases). For fleet itself (no runner): isolated scenario
  scripts in a throwaway `FLEET_SESSION` + `fleet doctor`, never "I ran it once". The human approves
  *how it will be proven* at GATE 1.
- **Phase 2 conclusion agent** → `SYNTHESIS.md` (BUILD/REVISE/REJECT — gate REVISE/REJECT before the
  human) + `PLAN-PLAIN.md` (plain-English plan + proof design). On BUILD: `fleet gate post 1 --slug
  <s> --summary "<what + how proven>" -d <id>`, verify it landed (`fleet inbox list | grep "GATE 1"`,
  re-post if not), `fleet gate park <id> 1`, **END THE TURN** (don't spawn implementers).
- **Phase 3 (after the human pops GATE 1)** — confirm: `printf '%s' "$PROMPT" | fleet gate parse` →
  `gate=1 action=implement`. Then **TDD**: 3a a test-author writes the proving tests FIRST and
  confirms they FAIL for the right reason (`TDD-RED.md`); 3b an implementer makes them pass **without
  weakening a test**.
- **Phases 4–5 unchanged in semantics** — two independent tester sub-agents + a dedicated
  **adversary sub-agent** that attacks the DONE verdict given both reports (catch trivially-passing
  tests). On DONE a completion agent writes `DONE-PLAIN.md` (how tests prove it + a
  runnable manual-test script); then `fleet gate post 2 --slug <s> --summary "<how tests prove it>"
  -d <id>` (target auto-resolves from `fleet integration-branch`, default main; `--target` overrides),
  `fleet gate park <id> 2`, **END THE TURN**.
- **On the GATE 2 pop** — `fleet gate parse` → `gate=2 action=merge target=T`. Review the diff, merge
  S→T, push T, `fleet ready`. A typed *defect* (not a pop) → loop and build further (don't restart). A
  typed "ship it" with no sentinel → treat as merge approval but **echo the target branch to confirm**
  before pushing.
- **Gate hygiene** — posts go at sev `warn` (notify fires); body = sentinel (first line) + pointer +
  short digest (the body is what's pasted on pop); act ONLY on a prompt carrying the sentinel. Spawn
  code workers `--no-self-merge` — the human gate authorises the merge and YOU (the sub-orch) execute
  it after review.

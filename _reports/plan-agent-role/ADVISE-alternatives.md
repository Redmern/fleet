# ADVISE — ALTERNATIVES lens

The human named one mechanism. The underlying **goal** it serves, stated mechanism-free:

> G1 The planner is grounded in context it did not have to rediscover.
> G2 The sub-orch is not blindly delegating a task it does not itself understand.
> G3 Research and planning are one collaborating activity, not a handoff over a wall.

Six designs satisfy some or all of G1–G3. They are not all mutually exclusive — A is
literally F+B with a fatter orientation step, and the ranking below is mostly a question
of *how much of the research runs in the sub-orch's own irreplaceable context*.

## The constraint every option is scored against

Three facts from the current system dominate the whole design space:

1. **The sub-orch's context is the dispatch's single point of failure.** It is the sole
   fleet-agent spawner (`FLEET_SUBORCH.md:103`, `:157-159`), and it must stay alive
   *across both gates* (park/unpark, `:349`, `:357`, `§6:309-316`). Every other pane is
   disposable; this one is not. The three-role wrapper exists explicitly to buy
   "**context-protection** — each sub-agent's bulk stays in its own context, the role
   agent keeps only digests" (`:96-98`). Moving research INTO the sub-orch inverts the
   one property §3.0.2 was written to provide.
2. **Sub-orch context is not crash-durable; artifacts are.** `fleet reconcile`
   re-animates a crashed sub-orch but restores no context (`:176-178`, `§6:323-329`), and
   §3.0.5 makes disk artifacts the truth for recovery (`:194-197`). Research held only in
   the sub-orch's head is *the one kind of research that cannot survive a respawn* —
   strictly worse than a role agent's, whose `SYNTHESIS.md` persists.
3. **The gate artifact contract is partly in code, not docs.** `bin/fleet:1925` hardcodes
   `plan="_reports/$slug/PLAN-PLAIN.md"`; `:1972` keys parking on `gate1-wait|gate2-wait`.
   Renaming *roles* is free; renaming *artifacts* or *cursor values* is a code change plus
   an in-flight-dispatch migration. **Every option below should keep `PLAN-PLAIN.md` +
   `SYNTHESIS.md` and the `gate1-wait` cursor value exactly as they are.**

There is also the seed-bloat precedent: sub-orchs once failed to spawn outright because
the seed was too big (`bin/fleet:1658-1663` documents the fix). The class of bug "the
sub-orch got too heavy" has already bitten this system once, in its most catastrophic
form. That is not proof A is wrong, but it means the burden of proof is on any design
that adds weight to that pane.

---

## A) The human's design as stated — sub-orch researches, then spawns a PLAN agent

**Mechanism.** Sub-orch classifies (`§3.0.1:51`), renames (`§3.0.1a:75`), then reads the
codebase itself — greps, file reads, enough to understand the task. It writes
`_reports/<slug>/RESEARCH.md`, then `fleet new --scratch <slug>-plan -p "<task> + read
RESEARCH.md"`. The plan agent fans out its own explorer/adviser/synthesis sub-agents and
produces `PLAN.md` / `SYNTHESIS.md` / `PLAN-PLAIN.md` unchanged.

**Artifact flow.** `RESEARCH.md` (new, sub-orch-authored) → plan agent → existing trio.
Writing `RESEARCH.md` to disk rather than inlining into `-p` is **not optional** under
constraint 2: an inline-only handoff means a sub-orch respawn loses the research with no
way to tell it ever happened, and a large inline prompt walks back toward the
16384-byte `MAX_IMSGSIZE` cliff (`bin/fleet:1659`). File + short pointer in `-p`.

**Role-phase.** `research → plan → gate1-wait → impl → test → gate2-wait → done`, or —
better — keep the cursor at `research` for the sub-orch's own pass and add `plan`, so an
in-flight dispatch parked at `research` still resumes coherently. Cross-check gains a
rung: `RESEARCH.md` present ⇒ orientation done; `SYNTHESIS.md` present ⇒ planning done.

**Gate/backcompat.** GATE 1 unchanged — same two artifacts, same sentinel, same park.
This is the option's real strength: it is invasive to §3.0.2/§3.0.5 and to nothing else.

**Context cost.** Unbounded and permanent. This is the whole objection. "Does the
research itself" has no natural stopping rule — the sub-orch reads until it feels
oriented, and every byte stays resident through impl, test, and *both* gate parks. A
research pass that would cost a disposable role agent 40% of its window costs the sub-orch
40% of the context that must still sequence two more roles and survive two human gates.

**Failure modes.** (i) Sub-orch context exhaustion mid-dispatch → the only pane that can
spawn workers degrades or dies, taking the dispatch with it, and reconcile brings back an
amnesiac. (ii) Ambiguity about *how much* research invites the sub-orch to over-read.
(iii) Duplication: a sub-orch that has read deeply is tempted to write the plan itself,
collapsing the PLAN role back into itself. (iv) Harness-neutrality is fine here — plain
reads/greps exist everywhere.

**Right pick when.** The orientation genuinely must be *interactive and adaptive* — the
sub-orch cannot even tell what to ask for until it has looked around — and the dispatch is
short enough that context exhaustion is not credible. Small-to-medium single-repo features
where the sub-orch is going to read three files and stop.

---

## B) Keep one agent; rename RESEARCH → PLAN and expand its charter

**Mechanism.** No new pane, no sub-orch reading. Role 1 becomes **PLAN**, chartered to do
both: explorers first (research), then advisers, then synthesis, then the plan. Effectively
a documentation change to `§3.0.2:108-118` plus the window slug `<slug>-plan`.

**Artifact flow.** Unchanged trio. Optionally `RESEARCH.md` as an intermediate the plan
agent writes for itself.

**Role-phase / gates.** Zero change if the cursor value stays `research`. The cheapest
option on the board by a wide margin.

**Context cost.** Zero marginal cost to the sub-orch. All the reading stays where the
architecture already puts it.

**Failure modes.** Satisfies G1 and G3 fully — research and planning genuinely collaborate
inside one agent, and the planner never rediscovers anything because it *is* the
researcher. But it does **nothing** for G2: the sub-orch still delegates a task it has not
looked at, which is precisely the complaint the human raised. Low fidelity to the ask.

**Right pick when.** You conclude on reflection that G2 is not actually a problem worth
paying context for — i.e. that a well-written instruction is sufficient briefing for a
delegation. Defensible, but it is arguing with the human rather than serving them.

---

## C) Strictly-bounded orientation pass only; everything else unchanged

**Mechanism.** Sub-orch gets a hard-budgeted orientation step written as an enforceable
recipe, not a vibe: *"≤3 greps, ≤5 file reads, no sub-agents, produce ONE paragraph
naming the subsystem, the likely touch-points with `file:line`, and the single biggest
unknown. If you cannot do it in that budget, write what you have and stop."* That
paragraph goes into the research agent's `-p` prompt. Role names unchanged.

**Artifact flow.** One paragraph, inline in `-p` (small enough that the durability and
IMSGSIZE concerns both vanish) and echoed into `STATUS.md` for the recovery trail.

**Role-phase / gates.** No change at all. The orientation is part of the pre-spawn work
the sub-orch already does alongside classify and rename.

**Context cost.** Bounded and small by construction — the budget *is* the design.

**Failure modes.** The budget must be numeric to hold; "briefly orient yourself" will be
read as licence to read the whole subsystem, and then you have A with extra steps. Serves
G2 partially (the sub-orch understands the *shape* of the task, not its details) and G1
weakly. Does nothing for G3.

**Right pick when.** You want the G2 benefit at near-zero risk and are content to leave
the research/plan relationship alone. The safest non-trivial move available.

---

## D) Two fleet agents in sequence — RESEARCH agent, then PLAN agent

**Mechanism.** Four role agents total. Research agent produces `RESEARCH.md`; sub-orch
watches, spawns the plan agent seeded with it; plan agent debates and produces the trio.

**Artifact flow.** `RESEARCH.md` → plan agent → trio. Clean, fully durable, fully
inspectable.

**Role-phase.** `research → plan → gate1-wait → …`. Both rungs artifact-backed, so §3.0.5
recovery is *better* than today's.

**Context cost.** Zero to the sub-orch (one extra watch + spawn). Best-in-class on
constraint 1.

**Failure modes.** Directly contradicts the human's sentence "it does not spawn a research
agent anymore" — it spawns *more* of them. Adds a window, a watch cycle, and wall-clock
latency to every feature. Worst of all, it re-erects the wall G3 asks to remove: the plan
agent reads a research document written by an agent it cannot interrogate, which is
exactly the handoff-over-a-wall problem, now with a mandatory extra hop.

**Right pick when.** Very large scope — this is already sanctioned as the §3.0.3 escape
hatch, "very large scope where one role agent's context cannot hold all sub-agent digests"
(`:155`). Do not promote an escape hatch to the default; leave it available.

---

## E) Plan agent spawns its own research sub-agents; sub-orch does nothing new

**Mechanism.** The status quo, near-verbatim. §3.0.2:109-113 *already* has the research
role fanning out "1–N explorer sub-agents (scope-scaled), each maps a subsystem and cites
`file:line`" before the advisers.

**Everything else.** Unchanged. Zero cost, zero churn, zero risk.

**Failure modes.** Serves G1 and G3 (as B does) and G2 not at all. Its real value is
diagnostic: E is the honest baseline, and B is E plus a rename. If the reviewer cannot
articulate what B buys over E beyond the name, the naming problem may be the *entire* real
problem — worth checking before spending context on A.

**Right pick when.** As the null hypothesis you must beat, not as a proposal.

---

## F) Orientation via ONE sub-agent inside the sub-orch, plus the B rename ★

**Mechanism.** The sub-orch does its own research — but delegates the *reading* to a
single harness Task sub-agent in its own pane, chartered: *"Orient on this task. Read
what you need. Write `_reports/<slug>/ORIENTATION.md`: subsystem map with `file:line`,
touch-points, prior art, the open questions a planner must answer. Return ≤15 lines."*
The sub-orch keeps only the digest. Role 1 is then renamed **PLAN** per B, seeded with
`ORIENTATION.md`, and keeps its explorers, its ≥2 advisers, and its synthesis.

**Why this is the right shape.** It is the human's flow — sub-orch researches, *then*
spawns a PLAN agent that builds on that research and may fan out further — implemented
with the mechanism the codebase already uses everywhere else to keep bulk out of a pane
that matters (`§3.0.2:96-98`). The sub-orch ends up genuinely oriented (G2), the plan
agent starts from a `file:line` map it did not produce (G1), and the two are one
continuous activity across a durable artifact (G3). Nothing about "the sub-orch does the
research itself" requires that the *bytes* land in the sub-orch's context — only that the
sub-orch owns and directs the activity, which it does here.

**Artifact flow.** `ORIENTATION.md` (durable, survives respawn) + a ≤15-line digest
resident in the sub-orch. Plan agent reads the file, not the digest.

**Role-phase.** Add `orient` before `research`, or fold it into `research` and rely on
`ORIENTATION.md` as the cross-check rung. Either is compatible with `:183`; folding it in
means **zero cursor change and zero in-flight migration**, which is the better trade.

**Gate/backcompat.** GATE 1 untouched — same artifacts, same sentinel, same park, same
`bin/fleet:1925` pointer.

**Context cost.** ~15 lines, bounded by the digest contract, not by the sub-orch's
self-restraint. This is the decisive difference from A: A's budget is a *behavioural* rule
the model must obey under pressure, F's is a *structural* one it cannot violate.

**Failure modes.** (i) **Harness neutrality is the real weak point** — omp/opencode
sub-orchs may lack a sub-agent primitive. Required fallback, stated in the doc: *"If your
harness has no sub-agent tool, do C's bounded pass instead (≤3 greps, ≤5 reads, one
paragraph)."* F and C are then one design with two implementations, which is also a nice
simplification of the doc. (ii) A sub-orch that has a sub-agent tool may be tempted to use
it for more than orientation; the "ONE orientation sub-agent, then spawn the PLAN agent"
rule needs to be as load-bearing as `:102`'s "Task tool only, never `fleet new`".
(iii) Mild: two spawn mechanisms now live in the sub-orch's head.

**Right pick when.** Default, for claude-harness sub-orchs, at any scope where the
pipeline runs at all.

---

## Where the adversarial property must live (design question 4)

Independent of A–F: **the ≥2 pro/con advisers + synthesis stay in the role agent**
(`§3.0.2:110-114`), never in the sub-orch. Three reasons. The debate is the single most
context-hungry step in Phase 1 — it is N adviser digests plus a synthesis pass, and it is
the *last* thing that should run in the pane that must survive two gates. The sub-orch is
also structurally the wrong adjudicator: it owns the dispatch's success, so asking it to
host a debate that may return REJECT gives the verdict a conflict of interest that
`§3.0.4:162-172` is at pains to avoid for the test verdict. And GATE 1 fires on
`SYNTHESIS.md` (`:345-349`) — leaving the debate where the artifact is written keeps the
gate contract single-authored. Any option that moves the debate up should be rejected on
this ground alone, regardless of its other merits.

## Scoring

5 = best. "Doc churn" scores *low churn* high. "Fidelity" = to the human's stated ask.

| | ctx safety | crash recov | adversarial rigor | doc churn | fidelity | **Σ** |
|---|---|---|---|---|---|---|
| A human's design | 1 | 2 | 4 | 3 | **5** | 15 |
| B rename+expand | 5 | 5 | 4 | **5** | 2 | 21 |
| C bounded orientation | 4 | 4 | 5 | 4 | 3 | 20 |
| D two fleet agents | **5** | **5** | 4 | 2 | 1 | 17 |
| E status quo | 5 | 5 | 5 | 5 | 1 | 21 |
| **F orientation sub-agent + PLAN rename** | 4 | **5** | **5** | 4 | 4 | **22** |

E's 21 is a warning flag, not a recommendation: it scores well by changing nothing and
serving G2 not at all. Read the fidelity column as the tiebreak it is.

Notes on the scores. A's crash-recovery 2 assumes `RESEARCH.md` is written to disk; inline
handoff drops it to 1. A's rigor 4 (not 5) reflects the temptation for a deeply-read
sub-orch to pre-empt the plan agent's judgment. F's context-safety 4 rather than 5 is the
honest residual — 15 lines is not zero, and the harness fallback is a real branch.

## Recommendation

**F, with C as the harness fallback.** It delivers the human's flow — sub-orch researches,
plan agent builds on it and may research further — at ~15 lines of permanent sub-orch
context instead of an unbounded read, keeps the GATE 1 artifact contract and the
`bin/fleet:1925` pointer untouched, and leaves the adversarial debate exactly where
§3.0.4's reasoning says it belongs. It is the human's design with the one substitution
the codebase's own §3.0.2 principle demands.

If F is rejected as too clever, take **C+B** (bounded orientation paragraph *and* the
RESEARCH→PLAN rename): lower fidelity on G3, but it serves G2 at near-zero risk and is
the smallest change that answers the actual complaint.

Take **A as stated** only with a written, numeric read budget and a mandatory
`RESEARCH.md` — and note that a numeric budget plus a mandatory artifact is F with a
weaker enforcement mechanism, which is an argument for F rather than for A.

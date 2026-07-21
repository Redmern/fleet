# ADVISE-con — the case AGAINST "sub-orch does its own research; RESEARCH → PLAN"

Lens: strongest honest case against. I read FLEET_SUBORCH.md, the SIP SKILL.md, and
`bin/fleet` myself. Two of the ask's three parts are actively harmful; one is already
implemented and the rename is churn against a **code-level** contract.

---

## 0. Headline

The ask has three separable parts. They are not equally good:

| Part | Verdict |
|---|---|
| A. Sub-orch performs the research itself | **REJECT** — attacks the sub-orch's core duties |
| B. Rename RESEARCH role → PLAN role | **CHURN** — breaks a hardcoded artifact contract for no behaviour change |
| C. PLAN agent may spawn research sub-agents | **ALREADY TRUE** — FLEET_SUBORCH.md:110 |

Part C is the load-bearing justification in the human's speech ("give planning agents the
ability to do both research and planning") and it is **already the shipped design**. Role 1
today fans out "1–N **explorer** sub-agents (scope-scaled), each maps a subsystem and cites
`file:line`" (FLEET_SUBORCH.md:110) and its synthesis produces `PLAN.md` — and SKILL.md's
Phase 1 is literally titled **"Research → implementation plan"** (SKILL.md:67). The stated
grievance, *"research and planning need to work together"*, describes the **status quo**.
Strip C out as a no-op and what remains is A (all the downside) plus B (all the churn).

---

## 1. Part A breaks the sub-orch's core duties

The sub-orch is not just another agent. It is the pane with four unique, non-delegable
obligations, and each one is degraded by loading research into it.

### 1.1 It is the sole fleet-agent spawner — and it is immortal by design

> "you are a worker, not an orchestrator; **the sub-orch is the sole fleet-agent spawner**"
> — FLEET_SUBORCH.md:101-102

> "Your lifetime = max(your own workers finishing, any depends-on target you watch). Do
> **not** exit-then-respawn." — FLEET_SUBORCH.md:310-311

Its context is a **shared, long-lived resource** spanning research → GATE 1 → impl → test →
GATE 2 → merge → `fleet dispatch done`. Every other agent in the pipeline is disposable.
Research is the single most context-hungry activity in the whole pipeline (read subsystems,
cite `file:line`, hold N explorer digests). Part A moves the most expensive phase into the
one context that can never be thrown away.

### 1.2 It deletes the stated purpose of the role-agent wrapper

FLEET_SUBORCH.md:96-98 states the design rationale verbatim:

> "The wrapper buys you two real things: **turn-discipline** (one watchable pane per phase,
> gates land cleanly) and **context-protection** (each sub-agent's bulk stays in its own
> context; the role agent keeps only digests) — *not* merely 'fewer windows.'"

Part A removes context-protection for the phase that needs it most, and deposits the bulk in
the pane where the doc says it hurts most. It is a direct contradiction of :96-98, not a
tension with it.

**And it saves nothing.** Count the windows. Today: research, impl, test = 3 spawned agents.
Under the ask: plan, impl, test = 3 spawned agents. Window count is **3 → 3**. Sub-orch
context is **+1 full phase**. The change is pure cost with no window saving whatsoever.

### 1.3 It breaks turn-discipline and the watch/wake machinery

The sub-orch's operating mode is: arm a watch, **end your turn**, sit idle
(FLEET_SUBORCH.md:252-254, :336-341). Research is the opposite — a long, many-tool-call,
single-turn generation. While researching, the sub-orch is `working` and cannot service:

- dependency waits on `depends-on` (§2, :34-42)
- periodic self-reconcile / re-arming dropped watches (§4, :262-264)
- escalation requests posted by role agents to the sole spawner (§3.0.3, :157-159)
- **its own wake path**, which is explicitly conditioned on pane state: *"the watcher retries
  the wake into your pane and **confirms it landed** (your pane must go `working`)"*
  (FLEET_SUBORCH.md:266-268). A sub-orch already `working` on research muddies the exact
  signal the escalation path uses to decide whether the wake was delivered.
- **gate pops**, which **auto-submit** into the sub-orch pane (§7, :382-385). A pop landing
  mid-research generation is the precise "mid-generation" hazard the rest of the system takes
  pains to gate against.

### 1.4 It converts a cheap crash into a dispatch-killing one

> "`fleet reconcile` re-animates crashed **sub-orchs** but knows nothing about in-flight Task
> sub-agents, so a role-agent crash loses its sub-agents' accumulated context."
> — FLEET_SUBORCH.md:176-178

Today the blast radius of a research crash is **one scratch pane**; the sub-orch survives and
re-spawns Role 1. Under Part A the researcher **is** the sub-orch, so a research crash is a
sub-orch crash — and the recovery path has a hard cap. See scenario S1 below.

---

## 2. Part B: the rename is churn, and it breaks a contract that lives in CODE

The BRIEF treats the artifact contract as a doc concern. It is not.

**Finding (grep of `bin/fleet`): `role-phase` appears NOWHERE in the codebase.** The cursor
in FLEET_SUBORCH.md:183 is a doc-only convention read by the sub-orch off its own `meta.tsv`.
`cmd_reconcile` (bin/fleet:1979-2018) reads only `state`, `window`, `respawns`. So:

- Renaming the cursor value is **free in code** — and therefore invisibly breaks **in-flight
  ledgers**. A respawned new-manual sub-orch reading `role-phase research` off a meta.tsv
  written by an old sub-orch has **no case arm for it**. It falls through to "restart the
  pipeline" — precisely what §3.0.5:195-197 exists to prevent.

**Meanwhile the artifact paths ARE hardcoded in the CLI:**

```
bin/fleet:1925    [ -n "$plan" ] || plan="_reports/$slug/PLAN-PLAIN.md"
bin/fleet:1935    [ -n "$plan" ] || plan="_reports/$slug/DONE-PLAIN.md"
```

`fleet gate post 1` bakes `PLAN-PLAIN.md` into the message body the **human reads and pops**.
Rename or relocate that artifact and GATE 1 posts a **dead pointer to the human** — a silent,
human-facing failure with no error anywhere.

**The cross-check gets a hole.** §3.0.5:194 keys crash recovery on
`_reports/<slug>/SYNTHESIS.md present ⇒ research done`. Splitting research from planning
creates a **new intermediate state** — sub-orch research finished, PLAN agent not yet spawned
— with **no artifact to cross-check**. Fixing that means mandating a `RESEARCH.md` the
sub-orch must write, which is *more* sub-orch work and *more* sub-orch context, not less. The
fix for the hole makes Part A's cost worse.

**And the phase count contradicts the section it edits.** §3.0.2 is built on "**exactly three
fleet agents**" and "You spawn **three windows total**" (:91, :96). The ask makes it four
*phases* over three windows, so the section's central claim has to be rewritten to say
something weaker while describing the same three spawns.

---

## 3. Part A weakens the adversarial property — the sharpest objection

Today's debate has a structural virtue that is easy to lose and hard to notice missing: **the
advisers critique an artifact whose premises sit in the same context as the advisers.** Role 1
holds the explorers, the advisers, and the synthesis (FLEET_SUBORCH.md:108-118). An adviser
can attack an **explorer's finding**, not merely the plan built on top of it.

Under the ask, the research premises are produced **one level up**, by the sub-orch, and
handed down as given. The adviser sub-agents are **leaves** (FLEET_SUBORCH.md:104) reading a
plan their parent wrote, resting on research their parent's parent supplied. A con-adviser
that discovers the *premise* is wrong has no route to overturn it: it reports to the plan
agent (the author, holding the pen), which reports to the sub-orch (the author of the
premise), which is also the party that reads the verdict and decides whether to post GATE 1.
**Research becomes effectively unfalsifiable by the debate.**

This is not a hypothetical anti-pattern — it is the **exact one the test side was hardened
against**, spelled out at FLEET_SUBORCH.md:162-172:

> "The DONE verdict is **never** self-certified by the testers, and **never** 'the role agent
> reconciles the two reports' — **a single point of judgment is weaker than the adversarial
> gate it replaces.**"

The ask reproduces on the *plan* side the precise failure the *test* side spent a dedicated
adversary sub-agent (§3.0.4) to eliminate. If the argument at :162-172 is right — and it is —
then concentrating authorship of research **and** plan **and** synthesis into one chain, with
the chain's own head reading the verdict, is a regression in the system's single most
valuable property.

---

## 4. Concrete failure scenarios, in order

### S1 — Dispatch death by research crash (the worst one)

1. `,build X` → `so-d42` spawns, classifies **feature**, renames its window (§3.0.1a).
2. Writes `role-phase so-research`, begins reading the subsystem — dozens of tool calls,
   large resident context. **No artifact on disk yet.**
3. Pane dies (tmux server restart, OOM, harness crash).
4. Next prompt triggers `cmd_reconcile`. State is non-terminal, so it is **not** skipped
   (bin/fleet:1990 skips only `done|failed|cancelled`); window is dead → `respawns=1` →
   respawn (bin/fleet:2015-2016).
5. Respawned `so-d42` reads `role-phase so-research`, cross-checks `_reports/<slug>/` → **empty**
   → restarts the research from zero. All context lost.
6. Crash again → `n=1 >= FLEET_RECONCILE_CAP` (default **1**), tmux responsive, no live workers
   → `meta_set state failed` + dashboard alert (bin/fleet:2007-2012). **Dispatch abandoned
   with zero work product.**

Today step 3 kills a disposable scratch pane. The sub-orch survives, sees no `SYNTHESIS.md`,
and re-spawns Role 1 — cost: one pane. Part A turns a cheap, recoverable, single-pane failure
into a **two-crash dispatch kill**.

### S2 — Context exhaustion at the far end of the pipeline

1. Context-heavy (post-research) sub-orch posts GATE 1 and parks (§7:345-350).
2. Human pops; the approval **auto-submits** into the sub-orch pane (§7:382-385).
3. Sub-orch resumes carrying research bulk + plan + synthesis, and must still run impl, watch
   it, run test, run GATE 2, review the diff, **merge and push**, and `fleet dispatch done`.
4. Compaction mid-impl-watch drops the slug / dispatch id / merge target it needs for
   `fleet gate post 2 --slug … -d <id>` and the `gate=2 action=merge target=T` handling.

The pane that can never be cheaply re-created is now the pane holding the most state, at the
point in the pipeline furthest from any checkpoint.

### S3 — Seed-cap regression (documented history, replayed one layer down)

The BRIEF's design question 1 explicitly floats *"inline in the `-p` prompt"* (BRIEF.md:44-45).
That is the **exact mechanism of the 2026-06-25 outage**:

> "a small seed avoids overflowing tmux's MAX_IMSGSIZE (16384) — the inlined manual would blow
> the cap, the new-window cmd would fail with 'command too long' (rc=1, swallowed by
> `2>/dev/null`), and the sub-orch would never spawn" — bin/fleet:1658-1663

Steps:
1. Sub-orch finishes research, holds a substantial digest.
2. `fleet new --scratch <slug>-plan -p "<8KB research digest>"` → the prompt rides tmux
   `new-window` argv (bin/fleet:1144-1170) → over cap → rc 1, **empty `win_id`**.
3. It now fails **loudly** (bin/fleet:1187-1193, the ae61c81 hardening) — but the PLAN agent
   is still **NOT SPAWNED**, and the naive retry is the same oversized prompt.

The only safe handoff is a **file artifact** — at which point the sub-orch has re-invented
`_reports/<slug>/` as the research agent's output contract, while having paid the full context
cost to produce it in the wrong pane. The ask's one novel mechanism collapses back into the
design it replaces.

### S4 — Debate captured by the author

1. Sub-orch researches, concludes approach A, writes premises asserting A.
2. PLAN agent is handed A, plans A, spawns a con-adviser sub-agent.
3. Con-adviser finds the **premise** wrong (subsystem misread, constraint missed).
4. The PLAN agent — author, and parent of a leaf that cannot escalate — synthesizes the
   verdict on its own plan. §7:346 gates the human only on **BUILD**; a REVISE loops back to
   the sub-orch's own research, which the sub-orch must now contradict itself to fix.
5. GATE 1 posts a summary authored end-to-end by the chain that produced the error. The human
   sees a confident one-liner and pops.

---

## 5. Minimum-viable counter-proposal

Keep the smallest thing that delivers the human's *actual* want — a better-aimed Role 1 — at
fixed, auditable cost.

**REJECT — sub-orch performs the research.** Non-negotiable. It is the immortal, sole-spawner,
gate-parking pane; §3.0.2:96-98 exists specifically to keep bulk out of it, and S1 shows the
crash-recovery cost is a dispatch kill inside two crashes.

**KEEP (cheap, real) — a bounded ORIENTATION pass, explicitly not research.** Before spawning
Role 1, allow the sub-orch a hard budget of **≤5 read-only tool calls** (`cat instruction.txt`,
one or two greps, a repo/dir listing) for the sole purpose of picking the slug, confirming the
classification, and naming the likely repo + subsystem. It writes **≤15 lines** to
`_reports/<slug>/ORIENT.md` and passes the **path** (never inline text — S3) in Role 1's
prompt. Mark it **explicitly non-authoritative and overridable by Role 1**, so it aims the
research without becoming an unfalsifiable premise (§3). This is what "the sub-orch does
research on the task itself" actually buys, at a cost you can state in one sentence.

**KEEP (free) — rename Role 1's label to PLAN in prose only, conditional on two invariants:**
1. The `role-phase` **value string stays `research`** (in-flight ledgers depend on it; §2), or
   the manual explicitly documents `research`/`plan` as the same cursor with a compat arm.
2. The artifact contract is **byte-identical**: `PLAN.md`, `SYNTHESIS.md`, `PLAN-PLAIN.md`,
   because **bin/fleet:1925 hardcodes the last one** into the human-facing GATE 1 body.

If either invariant cannot hold, **do not rename** — it is pure churn against a code-level
contract with a silent human-facing failure mode.

**REJECT — "PLAN agent may spawn research sub-agents" as a new capability.** Already shipped
(FLEET_SUBORCH.md:110). Writing it up as new invites a future editor to "implement" it and
disturb a working fan-out.

**If anything at all is built, two guardrails are mandatory:**
- The **debate stays in the same agent that holds the explorers**, so an adviser can attack a
  *finding*, not merely a plan built on one (§3).
- If `ORIENT.md` (or any sub-orch-authored premise) is introduced, add it to the §3.0.5
  artifact cross-check set, or the new intermediate state has no crash-recovery signal (§2).

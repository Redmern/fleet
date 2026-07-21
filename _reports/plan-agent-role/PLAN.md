# PLAN — plan-agent-role (design G)

Verdict context: see `SYNTHESIS.md` (**BUILD**, revised mechanism). Evidence: `EXPLORE-*.md`,
`ADVISE-*.md`. This plan is **doc-only**: zero required `bin/fleet` edits, GATE 1 contract
byte-identical.

## The design in one paragraph

Insert a new, hard-capped **RECON** step into the sub-orchestrator between classification (§3.0.1)
and the window rename (§3.0.1a). Its preferred mechanism is **one orientation sub-agent** whose
digest contract structurally caps what enters the sub-orch's context; its fallback (harnesses with
no sub-agent facility) is a numeric read-only budget. It writes `_reports/<slug>/RECON.md` and
passes it **by path**. Role 1 is then renamed **RESEARCH → PLAN** *in prose only* — cursor value and
artifact filenames stay byte-identical — and its charter is widened to say explicitly that it owns
both research (via its own explorer sub-agents) and planning, grounded in but free to contradict
RECON.md.

---

## W1 — New §3.0.1b: the RECON step

Insert between §3.0.1 (classify) and §3.0.1a (rename window). Applies to the **feature** path only —
question and trivial classifications skip it entirely (the classifier's cheap-bias at `:53-57`
is untouched, and RECON may *downgrade* a classification but never upgrade it).

**Preferred mechanism — one orientation sub-agent.** The sub-orch spawns exactly **one** sub-agent
via its harness fan-out facility, tasked to orient on the instruction and write
`_reports/<slug>/RECON.md`, returning **≤15 lines** of digest. The bulk never enters the sub-orch's
context. This is the cap, and it is structural.

**Fallback — inline numeric budget** (only when the harness has no sub-agent facility):
`≤8 read-only tool calls`, `≤3 files` at `≤200 lines` each, searches output-capped, **write-through
to RECON.md, never held in context**. Exceeding the budget is not a licence to continue — see W5.

**RECON.md** — `≤25 lines`, sections fixed:

```
## TASK        — one sentence: what the instruction actually asks for
## SLUG        — the chosen slug + why (this is the artifact that makes the choice reviewable)
## TERRITORY   — the files/subsystems this will touch, file:line, no interpretation
## PRIOR ART   — does this already exist / was it tried? prior _reports/ dirs, recent commits
## OPEN QUESTIONS — what the PLAN agent must resolve. An agenda, NOT a ceiling.
## BUDGET SPENT — mechanism used + tool calls consumed (auditable)
```

**Hard denylist**, stated in the manual: no implementation plan, no lens/verdict, no
`PLAN.md`/`SYNTHESIS.md`/`PLAN-PLAIN.md` (those are the PLAN agent's, and writing them here would
fake the GATE 1 cross-check), no code, no second sub-agent.

## W2 — Rename Role 1: RESEARCH → PLAN (prose only)

Rewrite `FLEET_SUBORCH.md:108-118`. The role is **PLAN**: it owns research *and* planning. It fans
out 1–N explorer sub-agents, **≥2 adviser sub-agents** (pro/con minimum, scope-scaled), and a
synthesis pass — all unchanged from today.

**What must NOT change** (three independent code/recovery contracts):

| Thing | Stays | Why |
|---|---|---|
| `role-phase` value | `research` | Doc-only field (absent from `bin/fleet` entirely), so a new value has no case arm — an in-flight ledger written by the old manual would silently restart, the exact failure `§3.0.5:195` exists to prevent |
| Cursor sequence | `research → gate1-wait → impl → test → gate2-wait → done` | unchanged; RECON folds into the `research` rung |
| `PLAN.md` / `SYNTHESIS.md` / `PLAN-PLAIN.md` | byte-identical | `bin/fleet:1925` hardcodes `_reports/$slug/PLAN-PLAIN.md` into the GATE 1 body the human pops |
| Sibling `fleet new --scratch <slug>-research` machinery | kept | the only escape valve (W5) |

**Window/dedup suffix — `<slug>-research` → `<slug>-plan`:** recommended but **decide explicitly**.
No code reads it; the risk is a dispatch mid-flight under the old manual spawning a second agent
under the new name. Mitigation: the artifact cross-check (`SYNTHESIS.md` present ⇒ role done) catches
it before real work is duplicated. Loop key `<slug>-research-2` → `<slug>-plan-2` (`:141`) moves with it.

**Cross-check table for §3.0.5** — extend with one row:

| Artifact present | Means |
|---|---|
| `RECON.md` | recon done — do NOT redo it; hand it to the PLAN agent |
| `SYNTHESIS.md` | PLAN role done |
| `TEST-VERDICT.md` | test role done |

RECON.md is a **net improvement** to crash recovery: today a crash between classify and spawn
silently loses the slug and the classification, with nothing on disk to recover from.

## W3 — The handoff contract (the "research and planning work together" part)

State in the PLAN role prompt boilerplate, with an explicit trust asymmetry:

- **TERRITORY / PRIOR ART are trusted** — do not re-derive them. This is the anti-duplication rule.
- **OPEN QUESTIONS is an agenda, not a ceiling** — spawn explorers for anything else you need.
- **Contradiction is licensed and must be recorded.** `PLAN.md` carries a mandatory `## Corrections`
  section: anything in RECON.md the PLAN agent found to be wrong, or "none". This matters because
  the sub-orch is a **single, un-adversaried reader** — RECON.md is the one artifact in the pipeline
  that no adversary reviews, so the correction channel is its only check.
- RECON.md is explicitly **non-authoritative**: on conflict, the PLAN agent's findings win.

## W4 — Harness neutrality

`FLEET_SUBORCH.md` and `SKILL.md` both hardcode "Task tool" while `FLEET.md:166-169` claims the docs
are agent-neutral. Reword the load-bearing boilerplate (`:100-106`) to "your harness's sub-agent
fan-out facility (claude: the Task tool; other harnesses: their equivalent)".

Add the **degradation clause** — this closes a latent hole, not just wording: a harness with **no**
sub-agent facility must escalate per §3.0.3, and must **never run all adviser lenses in one
context**. Collapsing pro and con into one context destroys the adversarial property silently.

Note for scoping: only `claude.conf` and `omp.conf` adapters exist — **there is no `opencode`
adapter**. The ask names opencode; it is not currently spawnable.

## W5 — Tripwire and escape valve (mandatory, not optional)

Add the sub-orch itself as a named §3.0.3 escalation trigger.

**Tripwires:** a compaction banner in a `so-*` pane before GATE 1; RECON budget exceeded; GATE 1
skipped or not parked; a role agent calling `fleet new`; a duplicate role run; `respawns>=1` or a
"reconcile: abandoned" alert (`bin/fleet:2011`).

**Response, in order:** stop; flush whatever is known to `RECON.md`; write the cursor; spawn the
sibling `<slug>-research` scratch agent (the pre-change shape, which is exactly why W2 keeps that
machinery); end turn.

**Target:** reach GATE 1 park with the sub-orch's window still mostly free. It must survive both
gates plus N done-or-loop iterations (§6) — its context is a resource with a *lifetime*, not a
per-phase allowance.

## W6 — Separate work item: compaction-blind recovery (pre-existing bug)

Not caused by this change; surfaced by it. `cmd_reconcile` (`:1979-2018`) acts only on
`!suborch_live` (`:1995`), so a **compacted-but-alive** sub-orch is invisible to recovery, and the
5-line GATE 1 unpark body (`:1927-1931`) carries no manual pointer — a compacted sub-orch proceeds
to Phase 3 and then merges and pushes at GATE 2 off a lossy summary.

**Cheap independent fix:** add a `FLEET_SUBORCH.md` pointer line to the gate post body
(`bin/fleet:1927-1941`) so unparking is self-healing. This is a `bin/fleet` change and should be its
own dispatch — **do not smuggle it into this doc-only commit.** Argument for doing it *first*: it
de-risks every dispatch, including this one.

## W7 — Ship both docs in one commit

`SKILL.md:67-76` and `:162-164` must change with `FLEET_SUBORCH.md`. The sub-orch reads **both**; a
split commit hands it contradictory instructions. Also sync `FLEET.md` ≡ bottom half of `CLAUDE.md`
(verbatim copy pair, `CLAUDE.md:5-9`) if any orchestrator-facing wording moves.

## Order

W6 (separate dispatch, optional but recommended first) → W1 + W2 + W3 + W4 + W5 + W7 as **one
commit** → proof run per `PLAN-PLAIN.md`.

## Open decisions for the human

1. **Window suffix rename** `<slug>-research` → `<slug>-plan`? (recommended; small in-flight risk)
2. **W6 first, or deferred?** (recommended first)
3. **RECON budget numbers** — ≤15-line digest / ≤8 calls fallback / ≤25-line RECON.md. Advisers
   proposed ranges from ≤5 calls to ≤25; these are the conservative middle.

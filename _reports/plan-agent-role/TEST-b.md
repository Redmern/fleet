# TEST-b — plan-agent-role (TESTER B: P2, P3, P5)

Doc-only change under test: commit `536b72f` (branch `fleet/plan-agent-role`) — RECON pre-step
added to the sub-orchestrator manual, Role 1 renamed RESEARCH → PLAN.

**Docs under test**
- `/home/red/proj/pc-tune/fleet/fleet_plan-agent-role-test/FLEET_SUBORCH.md` (§3.0.1b at `:90-143`)
- `/home/red/.claude_personal/skills/fleet-implementation-pipeline/SKILL.md` (Phase 0 at `:67-96`)

**Method.** Verified entirely from the two real dispatches already on disk in the isolated root
`/tmp/tb28`, read against their session transcripts. **No new live dispatch was run**, so no
isolation was required and none of the live state was touched. Confirmed after all work:
`pc` and `techweb2` tmux sessions both alive and attached; `/home/red/proj/pc-tune/.fleet/inbox/`
unmodified by me.

## Transcript paths (the evidence)

All under `/home/red/.claude_personal/projects/-tmp-tb28-root/`:

| Session JSONL | Role | cwd | tool calls |
|---|---|---|---|
| `3a342513-e33b-4797-a0a6-c3914f12ede0.jsonl` | **so-p3** sub-orch (VAGUE fixture) | `/tmp/tb28/root` | 29 |
| `b87d8941-5dc6-4f0d-be5b-be45f8395caf.jsonl` | **so-p1** sub-orch (normal feature) | `/tmp/tb28/root` | 29 |
| `8f17f81b-56e2-4e7a-9c66-7ba3e89a5ec2.jsonl` | **PLAN agent**, completion-reporting | `/tmp/tb28/root/fleetcopy` | 13 |
| `85810ab4-776e-4f59-9e1f-087942a66f4b.jsonl` | **PLAN agent**, fleet-lock-unlock | `/tmp/tb28/root` | 22 |

Artifacts: `/tmp/tb28/root/_reports/{completion-reporting,fleet-lock-unlock}/`.
Ledgers: `/tmp/tb28/root/.fleet/dispatch/{p3,p1}/`.

---

## P2 — ANTI-DUPLICATION — **FAIL**

### Root cause: the anti-duplication rule was never shipped

`PLAN.md` W3 (`:85`) specified the property P2 tests:

> **TERRITORY / PRIOR ART are trusted** — do not re-derive them. This is the anti-duplication rule.

That sentence, and any equivalent, is **absent from both shipped docs.** Exhaustive grep for
`re-derive|rederive|do not redo|trusted|duplicat` over `FLEET_SUBORCH.md` returns exactly **one**
hit — and it states the **opposite** contract:

- `FLEET_SUBORCH.md:133` — "**The handoff contract — RECON is the untrusted side.**"
- `FLEET_SUBORCH.md:135-137` — "*here is a cheap orientation; treat every claim in it as a lead to
  verify, not as a fact*" … "**the PLAN role overrules RECON, never the reverse.**"
- `SKILL.md:91-93` — same inversion, verbatim in substance.

The shipped design therefore **mandates re-derivation** rather than forbidding it. The property P2
exists to check was not implemented, so it cannot pass.

### Confirmed behaviourally in both transcripts

Both PLAN agents fanned their explorers out over a partition of RECON's own territory list, and
each explorer prompt **explicitly instructs re-verification of the RECON anchors**:

`8f17f81b…` (completion-reporting), explorer prompts at tool calls 3-6:
> "A prior shallow RECON pass made these claims. **TREAT AS LEADS TO VERIFY, NOT FACTS.** Go to the …"

`85810ab4…` (fleet-lock-unlock), explorer prompts at tool calls 3-6:
> "A cheap unverified RECON claims (**VERIFY EACH, cite real file:line, correct anything wrong**): …"

Subsystem mapping — the four explorers reproduce RECON's bullet groups 1:1:

| Explorer | Subsystem | Already listed in RECON.md |
|---|---|---|
| EXPLORER-1 | `fleet ready`, `.fleet/ready`, `fleet ls` done rendering, agents table, `fleet reap` | yes — bullets 1-5 |
| EXPLORER-2 | `deliver_wake`, `wake_escalate`, `cmd_notify`, `append_dashboard_alert`, `inbox_put`, `cmd_inbox`, `inbox_list`, `inbox_pop`, `fleet send main`, gate post/park | yes — bullets 6-16 |
| EXPLORER-3 | `fleetd`, `fleet watch`, pane-text scraping, state model | yes |
| EXPLORER-4 | `bin/fleet-dash`, CLAUDE.md/FLEET.md/FLEET_SUBORCH.md/README, `test/`, `_reports/` | yes |

Every `file:line` anchor RECON produced was re-walked. This is full re-derivation of the RECON
territory, by explicit instruction. **P2 FAIL.**

### Mitigating evidence — reported, not used to soften the verdict

The inversion appears to have been a *deliberate and correct* design change, not an oversight.
RECON was wrong at scale, and the mandatory `## Corrections` section caught it:

- **completion-reporting** — 12 numbered corrections. Correction 1: the channel count was both
  over- and under-stated (7 producers, not 4; `fleet watch` is a trigger, not a channel).
  Correction 2, the sub-orch's own words: *"Acting on RECON's framing would have rebuilt an
  existing mechanism."*
- **fleet-lock-unlock** — an 18-row table of **wrong line numbers** (`:3197`→`:3196`,
  `:3222`→`:3223`, `:3251`→`:3252`, `:3256`→`:3259`, `:3275-3281`→`:3279-3282`, `:390`→`:389`,
  `:394-402`→`:393-398`, `load_rows :397`→`:398`, …) plus a "Wrong claims" section.

Had `PLAN.md` W3's "TERRITORY / PRIOR ART are trusted" rule shipped as written, **both plans would
have been built on systematically wrong anchors and, in the p3 case, on a framing that would have
rebuilt an existing mechanism.**

**What RECON did buy** (a real but *different* benefit from the one P2 tests): it **partitioned the
explorer fan-out** — the four explorer subsystems were derived from RECON's bullet groups rather
than guessed — and it seeded a verification agenda. That is not anti-duplication; it is scoping,
and it costs one extra sub-agent plus a full re-verification pass.

Per instruction, this is **not** grounds to loosen the test. **P2 = FAIL as specified.**

---

## P3 — CAP UNDER PRESSURE — **PASS** (with numeric-cap caveat)

Fixture: dispatch **p3**, instruction verbatim — *"Something feels off about the way agents come
back to me when they are finished. It is not quite right and I keep losing track. Make it better."*
Exactly the vague case P3 calls for. Transcript `3a342513…`.

**Caps per the shipped doc** (`FLEET_SUBORCH.md:101-110`): preferred mechanism = **exactly one**
read-only sub-agent returning a **≤15-line digest**; `RECON.md` **≤25 lines**; inline fallback
(only when the harness lacks sub-agents) = **≤8 read-only calls**.

### Exact recon-phase call counts, so-p3 (calls 1-10 of 29)

| # | Call | Counts against budget? |
|---|---|---|
| 1 | `Read` FLEET_SUBORCH.md | no — manual bootstrap |
| 2 | `Read` `.fleet/dispatch/p3/instruction.txt` | no — ledger bootstrap |
| 3 | `Bash` cat meta.tsv/workers.tsv, ls dispatch | **1** |
| 4 | `Bash` ls root, cat p1 instruction, ls fleet dir | **2** |
| 5 | `Bash` ls fleetcopy, `git log --oneline -3` | **3** |
| 6 | `Bash` `which fleet`, `ls fleetcopy` | **4** |
| 7 | `Bash` write `role-phase research`, `fleet dispatch rename` | no — mutation |
| 8 | **`Agent` (Explore) — the one recon sub-agent** | the structural mechanism |
| 9 | `Bash` `mkdir -p _reports/completion-reporting` | no — mutation |
| 10 | `Write` `RECON.md` | no — the artifact |

- **Read-only calls in the sub-orch's own context: 4** (all `ls`/`cat` of dirs and the ledger;
  **zero** file-body `Read`s of the repo). Cap is 8 and only applies to the fallback path anyway.
- **Recon sub-agents: exactly 1** — the preferred structural mechanism, as specified.
- **Repo reads after recon, before spawning PLAN: 0.** Calls 11-12 are `fleet new --help` /
  `fleet | grep new`; call 13 spawns the PLAN role.
- **No escalation** to the `§3.0.3` sibling research agent was needed.

The failure mode P3 exists to catch — *"quietly reading twenty files"* — **did not happen**. Under
maximum vagueness the sub-orch took one look and stopped. so-p1 is identical in shape (4 read-only
calls at 3-6, mutation at 7, exactly 1 `Agent` at 8, `RECON.md` written at 10).

### Caveat — both numeric caps overshot on the vague dispatch

| Measure | Cap | so-p3 (vague) | so-p1 |
|---|---|---|---|
| digest returned into sub-orch context | ≤15 lines | **22 lines** (3270 chars) — over | 12 lines (2492 chars) — ok |
| `RECON.md` | ≤25 lines | **33 lines** (25 non-blank) — over | **35 lines** (32 non-blank) — over |

The tripwire at `FLEET_SUBORCH.md:123-127` was nonetheless honoured behaviourally: so-p3 did not
loop, wrote what it had, and named what it did not know — `RECON.md` ends with a `## Stayed unknown`
section ("Which of these the user actually means … Resolving that is GATE 1's job, not RECON's"),
then spawned the PLAN role. Overshoot is ~40% on a soft line count, not a context blow-out.

**Auditability gap (flagging for P1's owner).** `PLAN.md` W1 specified a six-section `RECON.md`
including a mandatory **`## BUDGET SPENT`** line as "the audit, and it is the reason that section
exists". **Neither shipped doc requires those sections, and neither `RECON.md` on disk has one.**
The budget is therefore **unauditable from artifacts alone** — I could only count it because the
transcripts survived. That is spec drift between `PLAN.md` and the shipped doc.

**P3 = PASS.** The structural cap held under the worst case; numeric caps are advisory and overshot.

---

## P5 — ADVERSARIAL INTEGRITY — **PASS**

Counted **structurally** — distinct `Agent` (Task) tool invocations in the transcript, not files on
disk. Requirement: **≥2 adviser lenses in separate sub-agent contexts** inside the PLAN agent.

**completion-reporting** — `8f17f81b…`, 8 `Agent` invocations total:

| Call | Invocation | Type |
|---|---|---|
| 3-6 | EXPLORER-1 … EXPLORER-4 | explorers |
| 7 | **ADVISER-PRO** | adviser ctx 1 |
| 8 | **ADVISER-CON** | adviser ctx 2 |
| 9 | **ADVISER-MINIMAL-FIX** | adviser ctx 3 |
| 10 | **ADVISER-NO-FIFTH-CHANNEL** | adviser ctx 4 |

Synthesis then ran in the PLAN agent's own context (Writes 11-13: `SYNTHESIS.md`, `PLAN.md`,
`PLAN-PLAIN.md`).

**fleet-lock-unlock** — `85810ab4…`, 8 `Agent` invocations total:

| Call | Invocation | Type |
|---|---|---|
| 3-6 | EXPLORER-A … EXPLORER-D (`subagent_type=Explore`) | explorers |
| 9 | **ADVISER-PRO** | adviser ctx 1 |
| 10 | **ADVISER-CON** | adviser ctx 2 |
| 11 | **ADVISER-ALTERNATIVES** | adviser ctx 3 |
| 12 | **ADVISER-UX/CLI consistency** | adviser ctx 4 |

**4 separate adviser contexts per dispatch, against a minimum of 2, in both.** Each is a distinct
`Agent` call carrying its own lens prompt; no context emitted more than one adviser lens. The silent
failure mode — one context producing several adviser sections — **did not occur**. The four
`ADVISER-*.md` / `ADVISE-*.md` files in each `_reports/` dir are backed 1:1 by four real contexts.

**P5 = PASS.**

---

## Verdict

| Proof | Result |
|---|---|
| P2 anti-duplication | **FAIL** — rule never shipped; docs mandate the opposite; explorers re-derive RECON's territory in full in both dispatches |
| P3 cap under pressure | **PASS** — 1 recon sub-agent + 4 read-only calls on the vague fixture; no ballooning. Digest 22 lines vs ≤15 and RECON.md 33/35 vs ≤25 overshot; no `## BUDGET SPENT` shipped, so unauditable from artifacts |
| P5 adversarial integrity | **PASS** — 4 distinct adviser Task contexts per dispatch (≥2 required), both dispatches |

### The honest failure condition — **TRIGGERED**

`PLAN-PLAIN.md:161-166`: *"If P2 fails … **or** P3 fails … then this change is pure added context
cost with no benefit, and the correct response is to revert to the status quo and keep only the
rename."*

P2 fails. **The trigger fires. Reported plainly, not repaired by loosening the test.**

One qualification the human should weigh before acting, offered as fact rather than as a softening:
the P2 failure is **not** the failure mode `PLAN-PLAIN.md` predicted. It predicted the PLAN agent
would ignore the contract and re-research anyway. What actually happened is that the shipped doc
**deliberately inverted** `PLAN.md` W3's contract — and the `## Corrections` evidence (12 substantive
corrections in one dispatch, 18 wrong line anchors in the other) indicates the inversion was the
**correct engineering call**: a trusted RECON would have poisoned both plans. So the choice in front
of the human is not "revert vs. keep as designed" but "revert vs. **re-justify the shipped design on
its actual merits**", since the shipped design is not the one the proof was written against. Deciding
that is outside my remit; the criterion as written says REVERT.

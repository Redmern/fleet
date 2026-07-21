# EXPLORE — SIP skill + docs (digest recovered from read-only explorer)

SKILL.md = /home/red/.claude_personal/skills/fleet-implementation-pipeline/SKILL.md
SUBORCH  = /home/red/proj/pc-tune/fleet/main/FLEET_SUBORCH.md

## 1. Role descriptions
- SKILL.md:16-20 orchestrator, "each phase is one fleet agent"; :56-61 scope table (Research/Advisers/Implement/Test/Test debate); :67-76 research; :78-94 advisers+synthesis; :101-112 implementer; :114-125 testers; :127-135 adversary; :170-173 "Phase 2 conclusion agent"; :180-183 "completion agent"
- Exact RESEARCH spawn template SKILL.md:75-76:
  `fleet new --scratch <slug>-research -p "RESEARCH ONLY … write _reports/<slug>/PLAN.md …"`
  then `fleet watch <slug>-research -m "review the plan, then start the adviser debate"`
- SUBORCH:108 same spawn form. SUBORCH:100-106 = mandatory boilerplate every role prompt MUST carry ("Fan out with the Task tool only. Never `fleet new` …")
- SUBORCH:90-141 = canonical three-role def (Role 1 RESEARCH, Role 2 IMPL :120-128, Role 3 TEST :130-141)

## 2. Adviser debate spec
- Counts scale by scope: 2 (pro/con) small, 3 (+value-add) medium, 4+ (+alternatives, security/abuse, UX) large — SKILL.md:56-61, :63-65
- Lenses SKILL.md:79-83; SUBORCH:111-113 ("This IS the debate, now in-agent")
- **Spawner = the research/phase AGENT via Task tool, not the orchestrator** (SKILL.md:79,:88; SUBORCH:91-98,:102). Sole `fleet new` spawner = sub-orch (SUBORCH:102-103,:157-160)
- Artifacts: `_reports/<slug>/debate-<lens>.md` (SKILL.md:84) → `SYNTHESIS.md` (SKILL.md:88-91)

## 3. Artifact contract `_reports/<slug>/`
| file | producer | ref |
|---|---|---|
| PLAN.md | research role | SKILL.md:73 |
| debate-<lens>.md | adviser sub-agents | SKILL.md:84 |
| SYNTHESIS.md (BUILD/REVISE/REJECT) | synthesis pass | SKILL.md:88-91, SUBORCH:116-118 |
| PLAN-PLAIN.md (plain plan + PROOF DESIGN) | research role | SKILL.md:166-173 |
| TDD-RED.md | impl role | SKILL.md:175-177 |
| TEST-a.md / TEST-b.md | 2 tester sub-agents | SKILL.md:122, SUBORCH:135 |
| TEST-VERDICT.md (DONE/NEEDS-WORK) | adversary sub-agent | SKILL.md:134-135, SUBORCH:136-137,:162-172 |
| DONE-PLAIN.md | completion agent | SKILL.md:180-183 |
- GATE 1 fires on BUILD after PLAN-PLAIN.md + SYNTHESIS.md (SKILL.md:170-173; SUBORCH:345-351)
- GATE 2 fires on DONE after TEST-VERDICT.md + DONE-PLAIN.md (SKILL.md:180-183; SUBORCH:353-359)
- Crash cross-check: SYNTHESIS.md present ⇒ research done; TEST-VERDICT.md present ⇒ test done (SUBORCH:193-197)

## 4. Who may spawn what
Default = Task sub-agents; escape hatch = sibling `fleet new` for parallel-mutating impl / stateful e2e / very large scope (SKILL.md:26-48,:101-110,:123-125; SUBORCH:143-160). Role agents never `fleet new`; they post to the sub-orch to request escalation (SUBORCH:102-103,:157-159; SKILL.md:43-45).
Harness-neutral wording already exists in FLEET.md:166-169 ≡ AGENTS.md:130-133, FLEET.md:12,:27 (`--harness|-h`), FLEET.md:149-150 / ~/CLAUDE.md:54-55 ("Harness sub-agents — where your harness supports them").
**SKILL.md and FLEET_SUBORCH.md are NOT harness-neutral — both hardcode "Task tool".**

## 5. Overlap — a rename must change BOTH files
Near-verbatim duplicated blocks:
- fan-out default + escape hatch: SKILL.md:26-48 ↔ SUBORCH:143-160
- adviser lenses/counts: SKILL.md:78-94 ↔ SUBORCH:111-113
- tester pair: SKILL.md:114-125 ↔ SUBORCH:130-135
- adversary para (near word-for-word): SKILL.md:127-135 ↔ SUBORCH:162-172
- gate choreography: SKILL.md:152-192 ↔ SUBORCH:331-386 (+ FLEET.md:201-222 ≡ AGENTS.md:165-186)
- classifier bias: SKILL.md:63-65 ↔ SUBORCH:51-73
Role names surface as: window/key suffix `<slug>-research`, `<slug>-research-2` (SKILL.md:75, SUBORCH:108,:140); role-phase cursor values (SUBORCH:183-185); "three-role pipeline" (SKILL.md:160-164).
`FLEET.md` ≡ bottom half of `CLAUDE.md` — verbatim copy pair, must stay in sync (CLAUDE.md:5-9).

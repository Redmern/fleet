# BRIEF — proposed change: sub-orch does its own research; RESEARCH role becomes PLAN role

## The ask (verbatim, human speech transcribed)
"When a SIP orchestrator is spawned and it needs to do research, it does not spawn a research agent
anymore, but does the research in the SIP (sub-)orchestrator itself. Also we need to distinguish
research vs plan agents: a RESEARCH agent gathers all information needed to make a sufficient plan;
a PLAN agent makes an implementation plan, on top of what already exists, for the task at hand.
Research and planning need to work together. So: change research agents into PLAN agents and give
planning agents the ability to do both research and planning. Flow: sub-orchestrator is spawned ->
sub-orch does research on the task itself -> then spawns a PLAN agent -> plan agent builds a plan
based on the sub-orch research + the task -> the plan agent may spawn more research sub-agents
inside itself (via its harness Task/agent tool, whichever harness: claude, omp, opencode) -> based
on that research it produces the implementation plan."

## Current system (cite these; read them yourself)
- /home/red/proj/pc-tune/fleet/main/FLEET_SUBORCH.md
  - §3.0.1 classify (question/trivial/feature, bias cheap)  :51
  - §3.0.1a rename window                                   :75
  - §3.0.2 THE THREE ROLES (research -> impl -> test), one fleet agent each; breadth via harness
    Task sub-agents INSIDE each role; load-bearing "Task tool only, never fleet new" rule :90-141
    - Role 1 RESEARCH = `fleet new --scratch <slug>-research -p ...`; fans out 1-N explorers +
      >=2 advisers (pro/con min) + a synthesis pass; outputs _reports/<slug>/{PLAN.md,SYNTHESIS.md
      (BUILD/REVISE/REJECT),PLAN-PLAIN.md (plain plan + PROOF DESIGN)}  :108-118
  - §3.0.3 escape hatch: escalate a role to sibling fleet agent (incl. "very large scope where one
    role agent's context cannot hold all sub-agent digests")   :143
  - §3.0.4 test adversary is an explicit sub-agent             :162
  - §3.0.5 role-phase cursor in .fleet/dispatch/<id>/meta.tsv, REQUIRED for crash recovery:
    `research -> gate1-wait -> impl -> test -> gate2-wait -> done`, artifacts are the cross-check
    (SYNTHESIS.md present => research done)                    :174-197
  - §6 lifetime / terminal verbs                               :309
  - §7 GATES: GATE 1 fires after research+debate on a BUILD verdict, needs PLAN-PLAIN.md +
    SYNTHESIS.md; `fleet gate post 1 / park <id> 1`; sentinel `gate=1 action=implement slug=S` :331-385
- /home/red/.claude_personal/skills/fleet-implementation-pipeline/SKILL.md (the SIP skill)
- /home/red/proj/pc-tune/fleet/main/bin/fleet (dispatch spawn/seed, gate verbs, reconcile)

## Known history that constrains the design
Sub-orchs once FAILED TO SPAWN because the FLEET_SUBORCH.md seed was too large; fixed by a compact
pointer prompt (fleet main ~ae61c81). There is a real seed-bloat / sub-orch-context class of bug.
The sub-orch is also the ONLY fleet-agent spawner and must stay alive across gates (park/unpark),
so anything that eats its context threatens the whole dispatch, not just one role.

## Design questions to settle
1. What exactly does the sub-orch research ITSELF, and how much? Hard budget/scope. What artifact
   goes to the plan agent — _reports/<slug>/RESEARCH.md file, or inline in the -p prompt?
2. Does the role-phase cursor change (e.g. `so-research -> plan -> gate1-wait -> impl -> test`)?
   Crash recovery (§3.0.5) must still work, incl. artifact cross-check.
3. How does the PLAN agent avoid redoing the sub-orch research while still being free to spawn its
   own research sub-agents? Handoff contract.
4. Does the adviser debate (>=2 lenses pro/con) stay in the plan agent or move to the sub-orch?
   The adversarial property must survive.
5. Harness-neutral wording (claude Task tool, omp/opencode equivalents).
6. Backward compat: in-flight dispatches; GATE 1's artifact contract (PLAN-PLAIN.md, SYNTHESIS.md).

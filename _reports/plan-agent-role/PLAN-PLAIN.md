# PLAN-PLAIN — plan-agent-role

Plain English. Full detail in `PLAN.md`, reasoning and verdict in `SYNTHESIS.md`.

## What you asked for, and what I found

You asked for three things. One of them is already true, one is a real fix, and one needs to be
built smaller than you described.

**Already true:** "the plan agent may spawn its own research sub-agents." That is the current
behaviour — the research role already fans out explorer sub-agents. Nothing to build.

**A real fix, and a good catch:** the sub-orchestrator currently picks the slug and decides whether
something is a feature *having read nothing at all*. That slug then gets baked into the branch name,
the reports directory, the gate message, and the loop key. And the role called RESEARCH never
actually writes down what it *found* — only what it plans to do. Your instinct that research and
planning are muddled is correct.

**Needs to be smaller:** "the sub-orch does the research itself." Four independent reviewers
rejected the unbounded version, and the reason is not the one I expected.

## Why not the unbounded version

Two hard facts.

The first is **it buys you nothing**. You spawn three agents today (research, implement, test) and
three under your design (plan, implement, test). The window count is identical. All you have moved
is the context cost — onto the one pane that can never be replaced.

The second is **crash asymmetry**. Right now, if research blows up, you lose a throwaway pane and
re-run it. Under the unbounded version, research crashing *is the sub-orchestrator* crashing: nothing
on disk, recovery restarts from zero, and a second crash hits the retry cap and marks the whole
dispatch failed. Same accident, much bigger crater.

**One thing I should flag, because it cuts against my own argument.** I originally believed there
was a documented history of sub-orchestrators dying from too much context — the "seed-bloat" bug.
That is wrong. That bug was a tmux message-size limit killing an oversized command line; it was
never about thinking capacity. I searched every report, note, inbox message and commit: there are
**zero** recorded cases of a sub-orch running out of context. So the record is empty in both
directions. This recommendation rests on architecture and blast radius, not on precedent, and you
should weigh it as such.

## What I recommend building instead

**A RECON step.** Before the sub-orchestrator names anything or spawns anything, it orients itself —
but through **one orientation sub-agent** that reports back at most fifteen lines. That is the whole
trick: the cap is structural, not a rule the model has to remember to obey at the exact moment it
feels under-informed. The detail lands in a file, `RECON.md`; only the digest reaches the
sub-orchestrator. Where a harness has no sub-agents, it falls back to a counted budget (≤8 read-only
calls, ≤3 files).

`RECON.md` records: what the task actually is, the chosen slug **and why**, the territory it touches,
whether this was already tried, and the open questions. Then the PLAN agent gets handed **the path
to that file** — never the contents pasted into its prompt. Pasting it is the literal mechanism of
the outage mentioned above.

**Then the rename.** Role 1 becomes PLAN and its charter says out loud that it owns research *and*
planning. But this is a **prose-only** rename. The recovery cursor keeps the value `research`, and
the three output filenames stay byte-identical — because `bin/fleet:1925` hardcodes `PLAN-PLAIN.md`
into the gate message you personally pop, and renaming it would post you a dead link with no error
anywhere.

**The handoff has a deliberate asymmetry.** The PLAN agent trusts the territory and prior-art
sections (that is what stops it redoing the work), treats the open questions as a starting agenda
rather than a limit, and is **explicitly licensed to contradict** the recon — recording any
correction in `PLAN.md`. That last part matters more than it sounds: `RECON.md` is the only artifact
in the pipeline no adversary ever reviews, so the correction channel is its sole check.

**The debate does not move.** All four reviewers landed on this independently: the pro/con advisers
stay inside the PLAN agent. A single context cannot debate itself, and the sub-orchestrator has a
stake in its own dispatch succeeding — which makes it exactly the wrong party to adjudicate a
REJECT.

## One thing I found that is worse than what you asked about

While tracing recovery I found a live hole, unrelated to this change.

Recovery only fires when a sub-orchestrator's pane is **dead**. If it merely runs out of context and
compacts, the pane is still alive, so recovery is a no-op and the crash-recovery cursor is bypassed
rather than protected. Meanwhile the gate-1 unpark message is five lines with no pointer back to the
manual. So a compacted sub-orchestrator will happily proceed to implementation and then **merge and
push at gate 2 off a lossy summary of what it was supposed to be doing.**

The fix is cheap — add a manual pointer to the gate message body. I have kept it out of this plan
because this plan touches no code and that one does. My recommendation is to do it **first**, as its
own dispatch: it de-risks every dispatch you run, including this one.

## Cost

Doc-only. Two files (`FLEET_SUBORCH.md`, the pipeline skill), shipped in **one commit** — they are
read by the same agent, and a split leaves it holding contradictory instructions. No `bin/fleet`
change. Gate 1 keeps working exactly as it does today.

## Three decisions I need from you

1. **Rename the window suffix** `<slug>-research` → `<slug>-plan`? Recommended. No code reads it;
   small risk that a dispatch already in flight spawns a second agent under the new name (the
   artifact check catches it).
2. **Do the compaction fix first?** Recommended.
3. **The budget numbers** — 15-line digest, 8-call fallback, 25-line `RECON.md`. Reviewers proposed
   anywhere from 5 to 25 calls; these are the conservative middle. Yours to tighten or loosen.

---

# PROOF DESIGN

How we will know this worked — and, more importantly, how we would know if it didn't.

## What counts as proof

Not "the docs read nicely." The claim is behavioural: **a real dispatch runs end to end, the
sub-orchestrator arrives at gate 1 better-informed and not fatter, and every existing contract still
holds.** Nothing below is satisfiable by reading the diff.

## P1 — Live dispatch to gate 1 (the primary proof)

Run a genuine feature dispatch. Required observations:

- `_reports/<slug>/RECON.md` exists, is within the line cap, and has all six sections.
- Its `## BUDGET SPENT` line matches what the transcript actually shows — this is the audit, and it
  is the reason that section exists.
- `PLAN.md` contains a `## Corrections` section (even if "none").
- Gate 1 posts, and the `PLAN-PLAIN.md` path in the popped message **resolves to a real file**.
  This is the regression that a careless rename would cause, so it gets checked explicitly.
- The cursor walked `research → gate1-wait`, unchanged from today.

## P2 — Anti-duplication (the point of the whole change)

Read the PLAN agent's transcript. Its explorer sub-agents must **not** be re-deriving the territory
already listed in `RECON.md`. If they are, the handoff contract failed and the change bought nothing
but overhead. This is the test most likely to quietly fail, so it is checked by reading the
transcript, not by asking the agent whether it complied.

## P3 — The cap is real under pressure

Dispatch something deliberately vague, where the honest response is "I don't know enough." The
sub-orchestrator must either stay inside the recon budget or **escalate** — spawning the sibling
research agent per the escape valve. What must not happen is quietly reading twenty files. This is
the test of whether the cap is structural or merely aspirational, and a failure here means the
mechanism should be reverted, not tuned.

## P4 — Backward compatibility with in-flight work

Take a dispatch whose ledger was written under the **old** manual (cursor `research`, no
`RECON.md`), and resume it under the new one. It must continue, not restart. This is precisely the
failure mode a cursor-value rename would have introduced, which is why the value does not change.

## P5 — Adversarial integrity

Confirm from artifacts that ≥2 adviser lenses ran **in separate sub-agent contexts** inside the PLAN
agent. One context producing both a pro and a con section is a silent failure of the property, and
it looks fine in the output — so it is verified structurally, by counting contexts, not by reading
the debate.

## P6 — Negative control

Dispatch a trivial one-liner. It must **skip recon entirely** and stay on the flat path. If recon
starts firing on trivia, the change has carpet-bombed the cheap path — the exact failure the
classifier's cheap-bias exists to prevent.

## The honest failure condition

If P2 fails (the PLAN agent re-researches anyway) **or** P3 fails (the budget does not hold under
vagueness), then this change is pure added context cost with no benefit, and the correct response is
to revert to the status quo and keep only the rename. That verdict should be reported plainly rather
than repaired by loosening the test.

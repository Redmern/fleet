# Plain-English plan — group dashboard agents into orchestrator cards

## What you asked for

In the fleet dashboard, each sub-orchestrator (the `so-d7`, `so-d8` … helper
agents) should visually **host** the worker agents it spawned, clearly separated
from other orchestrators' workers — so at a glance you know which workers belong
to which orchestrator, instead of one flat mixed list.

## What we'll build

- **Group the rows.** We figure out which worker belongs to which orchestrator
  from a tmux marker (`@fleet_owner`) that fleet already stamps on every worker
  window when an orchestrator spawns it — so it's reliable, not dependent on any
  notes file. Workers get reordered to sit directly under their orchestrator.
- **Draw a divider per orchestrator.** Each card starts with a labelled rule line
  like `── so-d7 · running · 4 workers · ⚠1 ──`, and its workers appear indented
  beneath it with a little `└─` tree branch, with a blank line between one card
  and the next. Clear separation, no risk of breaking the dashboard's column
  alignment.
- **Keep urgency visible.** The dashboard's whole job is to float a *stuck* agent
  to the top. Grouping could bury one inside a card, so: cards are ordered by the
  most-urgent worker inside them, and a blocked/stalled worker lights up its
  card's header (`⚠`). The board still pulls your eye to what's stuck.
- **Loose pile for the rest.** Workers you started directly (not via an
  orchestrator) go in a plain "unowned" section at the bottom. An orchestrator
  with no workers yet shows `(no workers yet)`.
- **No mis-clicks.** When the list refreshes every second and a card re-sorts,
  the cursor follows the agent it was on (so a keypress like "close window" never
  lands on the wrong agent).

### A deliberate design call to flag

The debate strongly recommended a **labelled divider + indent** rather than a
full four-sided box `┌─┐ │ │ └─┘` around each card. A full box looks more like a
literal "card" but it forces fragile width math on a layout that already has a
documented line-wrap/scroll bug, doubles vertical space (fewer agents fit), and
breaks in several edge cases. The divider+indent reads as nested on any terminal,
costs one extra row per card, and can't regress the alignment bug. **If you
specifically want the enclosing box look, say so at the gate and we'll do the box
with the extra hardening — otherwise we ship the lighter divider design.**

## How we'll prove it works (no test runner in fleet, so:)

1. **Pure-function test** — load the dashboard's functions in library mode, feed
   a fabricated fleet with 2 orchestrators (one with workers, one empty), an
   unowned worker, and assert the rows come out grouped in the right order, the
   empty card shows its placeholder, the unowned worker lands last, and — with no
   orchestrators at all — the output is byte-identical to today's flat list.
2. **Alignment test** — capture the rendered screen at several widths and assert
   every line is the same width (right edge lines up) and nothing overflows; and
   at a tiny height, that it clips cleanly with no garbage.
3. **Real-marker test** — a throwaway private tmux server where we set the real
   `@fleet_owner` option and confirm the dashboard reads it (not just a stub).
4. **Smoke** — `fleet doctor` stays green, and a live `fleet main --reload` shows
   your actual `so-d7/d8/d9` cards with their real workers nested.

## After your approval

We do it test-first: write the proving tests, confirm they fail for the right
reason, then implement until they pass — then two independent testers try to
break it before it merges to `main`.

# agent-role-glyph — plain English (d26)

## What you asked for

You want to look at the fleet and immediately see *what kind of work* each agent is
doing — research, planning, implementing, testing — instead of just a state dot and
a branch name.

## What we found

Two surprises shaped the answer.

**1. The word "role" is already taken — three times, and all three are safety.**
`FLEET_ROLE`, `.fleet/roles/<pane>`, and `@fleet_role` all mean "is this pane the
orchestrator or a worker", and they gate the fork-bomb guard, the worker
merge/push block, and the brake in front of every window kill. If a display label
ever wandered into any of them, a worker could promote itself to orchestrator. So
the new thing is called **task**, not role, and it lives in its own namespace.
Costs nothing, removes a whole class of future accident.

**2. The obvious implementation is a silent-corruption bomb.** Everyone's first
instinct is "add a role column to the agents table". Fleet has two tab-separated
tables and three readers that all assume exactly nine columns — and because this
repo is fail-silent by design, none of them would error. They'd just be wrong:

- the dashboard would paint the **"done" pill on every single agent** while
  `fleet ls` stayed correct — so the dash would tell you work is finished when it
  isn't, and you'd reap live work;
- the daemon has a hard `== 9` check that would empty every row and give you a
  **blank dashboard**;
- restoring after a tmux restart would glue the new column onto the sub-orch owner
  field and mangle window names — and there is no version or migration mechanism
  anywhere in fleet, while this machine deliberately runs both a packaged copy and
  a dev symlink of the binary.

So: **we do not touch either table.** That is the single most important decision
here.

## What we'll build

A new `--task` flag on `fleet new`, taking one of six fixed words:
`research`, `plan`, `impl`, `test`, `scratch`, `generic`.

It gets stamped in two places at spawn: a tmux window option (fast, live) and a
small file `<root>/.fleet/tasks/<window-name>` (durable). Keyed by **window name**,
not pane id — pane ids get reshuffled by a tmux restart, which is why the existing
`.fleet/roles/` directory silently accumulates dead entries today.

Then it shows up in three places as a 4-character tag — `rsch`, `plan`, `impl`,
`test`, `scr`:

1. **the tmux window status bar** — the one you see without running any command;
2. **the dashboard row**, left of the label, dropped first if the pane gets narrow
   so it never squeezes the agent name;
3. **`fleet ls`**, as a new TASK column.

An agent with no task set shows **blank**, not "generic". A missing tag is honest;
a *wrong* tag is worse than none, because you'd use it to decide who to interrupt.

Plain ASCII letters, not symbols. Fleet measures popup and box widths by counting
characters rather than display cells, and there's a comment in the dashboard source
that already warns about exactly this. Six roles also can't be made mnemonic in
one character each — you'd need a legend. `impl` needs no legend.

Finally the sub-orchestrator's three spawn lines get `--task research`,
`--task impl`, `--task test`. That closes the actual gap: today the implementation
worker's window looks *identical* to a plain hand-spawned worker, which is the one
distinction you most wanted.

Roughly 55 lines in `bin/fleet`, 20 in the dashboard, 3 in the daemon, 3 doc lines.

## What we deliberately left out

- **An "orchestrator" tag.** The main pane and the dashboard are filtered out of the
  agent list on purpose. Un-filtering them so they could show a tag would make
  `main` a selectable, *closable* dashboard row — that's the whole-session-teardown
  bug you already hit and fixed.
- **The fzf pickers.** Three near-duplicate row formatters with hand-maintained
  column padding, feeding the popup sizer that miscounts widths. Triple the risk for
  a badge nobody reads while teleporting.
- **Unicode glyphs.** See above.

---

# PROOF DESIGN

No test runner exists — proofs are shell harnesses, house style set by
`test/reap-teardown-safety.sh`, `test/reap-tracked-notes-proof.sh`,
`test/suborch-wake-proof.sh`, `test/worktree-secrets-proof.sh`: a numbered `case`
per assertion, `ok`/`fail` counters, isolated temp `HOME`/`XDG_*`/tmux socket,
`trap` cleanup, non-zero exit on any failure.

New harness: **`test/agent-task-proof.sh`**, run against a dedicated tmux server
(`tmux -L fleet-task-proof`) with `CONF_DIR` and the project root under `mktemp -d`,
so it can never touch the real fleet. Every case ends in a real assertion on real
output, not a mock.

### A. The regression guard — the tables did not change (highest value)

1. `persist_agent` still writes exactly **9** tab-separated fields
   (`awk -F'\t' '{print NF}'` on the `.agents` line == 9).
2. `fleet agents` still emits exactly **9** fields on the daemon path and **7** on
   the fallback path (kill the daemon socket, re-check).
3. **The `done`-pill regression:** spawn two agents, set a task on one, mark
   *neither* ready, then assert that neither `fleet ls` nor the dashboard's row
   builder reports `ready`/`done` for either. This is the exact bug a 10th column
   would cause, and it must stay caught forever.
4. A **legacy 9-column** `.agents` file written by hand still restores cleanly and
   the restored agent's `owner` field is intact (no glued-on task).

### B. Storage and read precedence

5. `fleet new … --task impl` → `tmux show -wqv @fleet_task` == `impl` **and**
   `<root>/.fleet/tasks/<wname>` contains `impl`.
6. Window option wins over the file: hand-write `test` into the file while the
   option says `impl`; the rendered tag is `impl`.
7. File is the fallback: `tmux set -w -u @fleet_task`; the tag becomes `test`.
8. Neither present → tag renders **blank** (4 spaces), and the row still aligns.

### C. Durability

9. **tmux restart:** `tmux -L … kill-server`, restart, `fleet restore` → the agent
   comes back with its task intact (proves the window-name-keyed file works, and
   that `cmd_restore` re-passes `--task`).
10. **fleetd restart:** `systemctl --user restart fleetd` equivalent (or kill the
    test daemon) → task survives, because it never lived in the daemon.
11. **Daemon down entirely:** `fleet ls` still prints the correct tag from the
    7-field fallback path.
12. **Synthetic starting/stale row:** stamp a window with `@fleet_harness` and
    `@fleet_task` but never report agent state; assert the synthetic row still
    carries the tag.

### D. Validation, injection, security (fail-closed cases)

13. `--task bogus` → warning on stderr, agent still spawns, task empty. (fail-silent)
14. `--task main` → **rejected**; assert `FLEET_ROLE` in the pane is still `worker`,
    `.fleet/roles/<pane>` is still `worker[:so-…]`, and `is_main_pane` is false for
    it. This is the self-promotion guard.
15. `--task 'x#[fg=red]'` and `--task 'x#{q:…}'` → rejected; then, separately,
    hand-write that string into `.fleet/tasks/<wname>` and assert `task_of`
    re-validates and returns empty — a hand-edited file cannot inject.
16. After 15, assert the tmux **status bar still renders** (`tmux display -p
    '#{W:#{window-status-format}}'` produces sane output for every window, and no
    window's format contains a stray `#[`). This is the whole-server corruption case.
17. A task containing a literal tab or newline is rejected at the write site.

### E. Rendering

18. `fleet ls` header contains `TASK` and the row's field 2 is the tag; total field
    count of each row is stable.
19. Dashboard row at a **narrow** width (drive the width ladder): the task field is
    dropped **before** the cost/mode/✉ pills are affected, and the label is never
    truncated harder than it is today at the same width (compare against a
    task-less baseline row of identical width).
20. Every tag is exactly 4 ASCII bytes and 4 display cells — assert with
    `LC_ALL=C` byte length == character length == 4 for all six values. This is the
    codepoint-vs-cell guard.

### F. Lifecycle

21. `fleet forget` / `fleet reap` removes `<root>/.fleet/tasks/<wname>`.
22. A **refused** reap (dirty worktree) leaves the task file intact — the atomicity
    contract: any refusal leaves everything as it was, so a plain re-run is the
    retry.

### Manual smoke (not automatable)

Spawn one agent per role in a real session and eyeball: the status bar tags are
legible at a glance next to the state dot; the dashboard stays aligned at 80, 100
and 120 columns; `fleet ls` columns line up in the terminal. Confirm `fleet doctor`
is still clean.

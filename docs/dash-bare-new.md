# Dashboard: bare + harness on the "new agent" form

## TL;DR

**Already shipped.** The dashboard's `n` → "New fleet agent" form already exposes
both a **Harness** picker (enumerated live from `fleet harnesses`) and a **Bare**
yes/no toggle, and passes `--harness`/`--bare` to `fleet new`. No code change is
required. This doc records the design and the seams in case the flow is extended.

The original task brief ("the dashboard's new flow gives no bare option and no
harness picker") is out of date: both fields were added in commit `2f0a73e`
(`feat(harness): pluggable agent harness — claude + omp`) and are present on
`main`. This branch (`dash-bare-new`) is 0 commits ahead of `main`.

## How the flow works today

Trigger: the `n` key in the dashboard main loop calls `new_agent_form`
(`bin/fleet-dash:746-747`).

`new_agent_form` (`bin/fleet-dash:503-635`) is a self-drawn, centred in-box form
— **not** fzf or `tmux display-popup`. It owns its own raw-key read loop
(`read -rsN1 </dev/tty`, `bin/fleet-dash:591`) and renders rows with the
`mtop`/`mrow`/`mbot` box helpers. This is the same idiom as `confirm_teardown`
and the `list_pick` dropdown used for Repo/Base. (`display-popup` is used only for
the read-only diff pager, `bin/fleet-dash:708`.) Any extension must match this
idiom — no new dependency.

Seven fields, index `0..6` (`nitems=7`, `bin/fleet-dash:509`):

| idx | field   | type     | source / default                                            |
|-----|---------|----------|-------------------------------------------------------------|
| 0   | Repo    | select   | `fleet repos` (`:512`)                                      |
| 1   | Branch  | select/text | `fleet worktrees <repo>` + `+ new branch` sentinel (`:522`) |
| 2   | Base    | select   | `fleet branches <repo>` (`:525`); hidden unless new branch  |
| 3   | Prompt  | text     | optional, seeds `-p`                                        |
| 4   | **Bare**    | toggle   | `no` default (`:508`); space or ←/→ flips (`:571,620`)     |
| 5   | **Harness** | select   | `fleet harnesses` (`:516`), default `claude` (`:519`)      |
| 6   | Create  | button   | runs `_spawn`                                              |

Navigation: `j`/`k` or ↑/↓ move between fields; ←/→ (`_cyc`) or space cycle the
active select/toggle; Enter on a select opens a `list_pick` dropdown
(`:605-612`); Enter on Create spawns; Esc / 300s timeout cancels at any step
(`:591,600`).

### The harness picker

- Populated live: `fleet harnesses` (`bin/fleet-dash:516`), whose source is
  `harness_list` → `harness.d/*.conf` basenames (`bin/fleet:37`, exposed as
  `cmd_harnesses`, `bin/fleet:185`). Currently yields `claude`, `omp`.
- Default selection is `claude` if present, else the first entry
  (`bin/fleet-dash:519`).
- Empty-list guard: falls back to `HARN=(claude)` (`bin/fleet-dash:517`).
- Rendered as field 5; cycled by `_cyc` case `5` (`:572`); Enter opens a
  `list_pick` dropdown (`:611-612`).

### The bare toggle

- Field 4, `bare="no"` default (`bin/fleet-dash:508`).
- Flipped by space (`:620`) or ←/→ via `_cyc` case `4` (`:571`).
- `bare=yes` appends `--bare` to the spawn args (`:581`).

### The spawn

`_spawn` (`bin/fleet-dash:575-587`) builds the argv and shells out:

```
fleet new <repo> <branch> [-p <prompt>] [--bare] [--base <branch>] --harness <name>
```

(`bin/fleet-dash:579-584`). All output is swallowed (`>/dev/null 2>&1`) and the
result is reported via the dashboard `status` line — fail-silent, matching house
style.

On the `fleet new` side (`bin/fleet:400-478`) the flags are already supported:
`--bare` (`:405`), `--harness|-h` (`:407`). `bare=1` makes `cmd_new` open a plain
agent pane running the harness binary directly with the prompt via
`$H_PROMPT_FLAG` (`bin/fleet:457-466`); non-bare opens the nvim + agent split
(`:467+`). The chosen harness is loaded (`harness_load`, `bin/fleet:414`) and
stamped onto the window as `@fleet_harness` (`:478`) so fleetd/`pane_harness` can
recover it.

## Edge cases (all already handled)

- **Empty harness list** → `HARN=(claude)` fallback, picker still usable
  (`bin/fleet-dash:517`).
- **Single harness** → picker shows the one entry; cycling is a no-op modulo-1.
  Harmless. *Optional polish below.*
- **Default behaviour unchanged** → hitting Create with no edits gives
  `bare=no` + `--harness claude`, i.e. the pre-feature default flow.
- **Cancel at any step** → Esc or the 300s read timeout returns from the form
  without spawning (`bin/fleet-dash:591,600`).

## Reloading after edits

Per `CLAUDE.md`: edit `bin/fleet-dash`, then reload in place with `R` in the
dashboard (`exec "$SELF" "$SESS"`, `bin/fleet-dash:731`) or `fleet main --reload`
(`bin/fleet:671-673`) — no session/orchestrator restart needed.

## Optional polish (not implemented; low value)

1. **Skip the harness field when only one harness exists.** When
   `${#HARN[@]} == 1`, the field adds a navigation step with no choice. Could
   conditionally drop field 5 and renumber. Cost: index churn across `_field`,
   `_cyc`, the Enter `case`, and `nitems`. Not worth it for one saved keypress;
   leaving the field visible also signals which harness will launch.
2. **Surface the harness/bare choice in the launching message.** `_spawn`'s
   `msg_box` (`bin/fleet-dash:578`) says only `launching <repo> / <branch>`.
   Could append `(<harness>, bare)` for confirmation. Cosmetic.

Neither is required; the feature is complete and correct as-is.

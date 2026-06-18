# Dashboard: bare + harness on the "new agent" form, plus repo-less `--scratch`

## Two different meanings of "bare"

There are two orthogonal ideas that both got called "bare":

1. **`--bare` (pre-existing)** — *pane style*: a plain agent pane instead of the
   default nvim + agent split. It still needs a repo + branch and still builds a
   worktree. `cmd_new` required both positionals (`bin/fleet:435`) and ran the
   agent in the worktree dir (`bin/fleet:419-448`).
2. **`--scratch` (new)** — *repo-less*: **no repo, no branch, no worktree**. A
   plain agent pane launched at the project root. This is the "bare means nothing
   is checked out" sense.

They are kept as separate flags so neither overloads the other:

```
fleet new myrepo feat --bare     # plain pane on a worktree (unchanged)
fleet new --scratch              # repo-less agent at the project root (new)
fleet new --scratch dbg -h omp   # repo-less, window labelled "dbg", omp harness
```

## What `--scratch` does (`bin/fleet:400-497`)

- Arg parse: `--scratch) scratch=1` (`bin/fleet:406`). Repo/branch are **not**
  required in scratch mode; the usage `die` is gated behind `else`
  (`bin/fleet:435`).
- Forces `bare=1` — a repo-less agent has nothing to edit in nvim, so it uses the
  plain-pane spawn path (`bin/fleet:419-424`).
- `dir = $(fleet_root)` — runs at the project root (`bin/fleet:421`). Verified:
  spawns at `/home/red/proj/pc-tune`.
- Window name comes from `scratch_wname` (`bin/fleet:229-234`): the optional
  first positional as a label (default `scratch`), auto-suffixed `-2`, `-3`… if
  that name is already an open window in the session, so `fleet send` stays
  unambiguous. Fail-silent (tmux errors → empty open list → base name).
- **Not persisted**: `persist_agent` is skipped for scratch (`bin/fleet:495`) —
  repo-less agents are ephemeral, there is nothing to anchor a `fleet restore`
  to. `cmd_restore` already skips lines missing repo/branch (`bin/fleet:386`), so
  this is consistent and needs no restore change.
- Everything else (harness load, `@fleet_harness` / state-source tagging, the
  spawn) is shared with the normal path.

## What the dashboard form does (`bin/fleet-dash:503-669`)

Trigger unchanged: `n` → `new_agent_form` (`bin/fleet-dash:746`). The form is a
self-drawn in-box modal (same idiom as `confirm_teardown` / `list_pick`, not fzf
or `display-popup`).

A **Scratch** toggle was inserted. Field indices are now (`nitems=8`):

| idx | field   | type   | notes                                             |
|-----|---------|--------|---------------------------------------------------|
| 0   | Repo    | select | disabled in scratch mode                          |
| 1   | Branch  | select/text | disabled in scratch mode                     |
| 2   | Base    | select | disabled in scratch mode                          |
| 3   | Prompt  | text   | always active                                     |
| 4   | **Scratch** | toggle | the new repo-less switch                      |
| 5   | Bare    | toggle | shown as `(forced)` info when scratch=yes         |
| 6   | Harness | select | `fleet harnesses`, default claude                 |
| 7   | Create  | button |                                                   |

Mechanics:

- `_active idx` (`bin/fleet-dash:534`) returns non-navigable for fields 0/1/2/5
  when `scratch=yes`. `_step dir` (`:538`) moves the cursor skipping inactive
  fields; Tab wraps while skipping (`:636`). Up/down/j/k all route through
  `_step`.
- Disabled fields render dimmed with `(scratch — repo-less)` / `(forced)`
  placeholders (`bin/fleet-dash:_draw`), so the mode is visible.
- `_toggle_scratch` (`:545`) flips the toggle (space, or ←/→ via `_cyc` case 4).
- `_spawn` (`bin/fleet-dash:600`): in scratch mode builds `fleet new --scratch
  [-p prompt] --harness <h>` and skips repo/branch/base entirely; otherwise the
  original `fleet new <repo> <branch> …` path.

### Edge cases handled

- **No repos under the project root**: the form no longer aborts. It defaults
  `scratch=yes`, parks the cursor on the Scratch toggle (`ai=4`), and
  `_toggle_scratch` refuses to turn scratch off while `REPOS` is empty
  (`bin/fleet-dash:546`). So a repo-less agent is still launchable on an empty
  project.
- **Empty harness list** → `HARN=(claude)` fallback (`bin/fleet-dash:517`).
- **Cancel** at any step: Esc / 300s timeout returns without spawning.
- **Default flow unchanged**: open form, leave Scratch=no → identical to before
  (Repo/Branch/Base/Prompt/Bare/Harness/Create).

## Reload / test

Per `CLAUDE.md`: `R` in the dashboard (`bin/fleet-dash:744`, `exec "$SELF"`) or
`fleet main --reload` (`bin/fleet:671-673`) reloads the dash in place. Note these
act on the **installed** symlink (`~/.local/bin`), so to test this branch's dash
either run it from the worktree or re-`install.sh` from here first.

CLI verified end-to-end from inside the live session: `fleet new --scratch`
spawned `pc-tune:6` named `scratch`, cwd `/home/red/proj/pc-tune`. `fleet new`
(no scratch, no positionals) still dies with the repo/branch usage message.

## Status

Implemented on branch `dash-bare-new`: `bin/fleet` (`--scratch`, `scratch_wname`,
persist gate, usage) and `bin/fleet-dash` (Scratch toggle + skip-navigation +
repo-less spawn). Syntax-checked (`bash -n`) and CLI-tested. The dashboard TUI
flow needs an interactive reload-test in a session running this branch's code.

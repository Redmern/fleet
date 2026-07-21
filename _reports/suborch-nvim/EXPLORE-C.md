# EXPLORE-C — where pipeline artifacts land on disk + nvim autostart mechanics

Dispatch d25 (`suborch-nvim`). Research only; no code written to `bin/` or `lib/`.

Repo under study: `/home/red/proj/pc-tune/fleet/main`
Live project root: `/home/red/proj/pc-tune` (this IS a git repo; `git rev-parse
--show-toplevel` → `/home/red/proj/pc-tune`)

---

## 1. What a sub-orchestrator itself writes, and where

Everything the **sub-orch qua sub-orch** writes goes to the durable ledger
`<root>/.fleet/dispatch/<id>/`.

`/home/red/proj/pc-tune/fleet/main/FLEET_SUBORCH.md:11-12`:

> the durable ledger under `<root>/.fleet/dispatch/<id>/`. Your CWD is the project root
> `<root>`, so every relative `.fleet/dispatch/<id>/...` path below resolves directly —

That CWD claim is guaranteed by the spawn: the sub-orch is a **scratch** agent, and
`cmd_new` sets `dir="$root"` for scratch (`bin/fleet:999`, inside the `if [ "$scratch"
= 1 ]` block), and tmux is invoked with `-c "$dir"` (`bin/fleet:1140`, `1143`, `1146`).

### Files in `.fleet/dispatch/<id>/`

| file | written by | citation |
|---|---|---|
| `instruction.txt` | the **dispatch hook**, before the sub-orch exists | `bin/fleet-dispatch.sh` (hook writes instruction + allocates id); read at `FLEET_SUBORCH.md:18` (`cat .fleet/dispatch/<id>/instruction.txt`) |
| `meta.tsv` | `fleet dispatch` verbs via `meta_set` — **never hand-edited** | `FLEET_SUBORCH.md:30`, `:174-185`, `:255-257`; `bin/fleet:1669` (`meta_set "$d" window_id "$wid"`) |
| `workers.tsv` | the sub-orch, append-only, one row per worker it owns | `FLEET_SUBORCH.md:31`, `:232-238` — `printf '%s\t%s\n' "<repo>" "$branch" >> .fleet/dispatch/<id>/workers.tsv` |
| `STATUS.md` | the sub-orch, free-form human-readable progress | `FLEET_SUBORCH.md:257-260` — "``# in .fleet/dispatch/<id>/STATUS.md — what's spawned, what's pending, blockers``"; also `:159` (record escalations here) |
| ad-hoc extras | occasionally a sub-orch drops a bespoke doc here | **observed**: `/home/red/proj/pc-tune/.fleet/dispatch/d9/DIAGNOSIS.md` (2.3k) |

`meta.tsv` fields seen live — `/home/red/proj/pc-tune/.fleet/dispatch/d25/meta.tsv`:

```
created	2026-07-19T18:31:33+02:00
window_id	@37
state	running(1)
window	so-d25-suborch-nvim
role-phase	research
```

`role-phase` is the crash-recovery cursor, REQUIRED, written **before** entering each
phase (`FLEET_SUBORCH.md:174-185`):

```
printf 'role-phase\t%s\n' impl >> .fleet/dispatch/<id>/meta.tsv
```

Note the recovery cross-check at `FLEET_SUBORCH.md:194` explicitly treats the
`_reports/` tree as ground truth over `meta.tsv`:

> truth (`_reports/<slug>/SYNTHESIS.md` present ⇒ research done; `TEST-VERDICT.md` present ⇒ …)

— i.e. the ledger and the reports tree are **two halves of one state machine**, and
they live in two different directories. That is the crux of the problem in §4.

### Ledger-level (not per-dispatch) files

- `/home/red/proj/pc-tune/.fleet/dispatch/seq` — the id allocator.
- `/home/red/proj/pc-tune/.fleet/dispatch/alerts.log` — 30k, out-of-band alerts strip.
- `.spawnlock-<id>` / `.wid-<wname>.$$` — transient, `bin/fleet:1641`, `1647-1668`.

Live ledger today: `d1, d7..d26` under `/home/red/proj/pc-tune/.fleet/dispatch/`.

### The sub-orch's own seed prompt

`bin/fleet:1660-1668` — a **compact pointer**, deliberately not the inlined ~20KB manual
(tmux `MAX_IMSGSIZE` 16384 would blow up the `new-window` with "command too long"):

```sh
FLEET_NEW_WID_FILE="$widf" FLEET_SESSION="$sess" FLEET_ROOT="$root" \
FLEET_NEW_SUBORCH_ID="$wname" \
  cmd_new --scratch "$wname" -p "You are a fleet dispatch sub-orchestrator (so-$id). Your project root is your CWD ($root).
FIRST, read and follow your operating manual: $FLEET_DIR/FLEET_SUBORCH.md
THEN handle DISPATCH ID: $id — read your instruction at .fleet/dispatch/$id/instruction.txt"
```

---

## 2. `$FLEET_DOCS` — definition, default, and what writes there

### Documented contract

`/home/red/proj/pc-tune/fleet/main/FLEET.md:31-36` (identical text at `CLAUDE.md:196-201`):

> - **`$FLEET_DOCS`** — every spawned worker gets this env var: an absolute,
>   per-branch scratch-docs dir (`<worktree>/.fleet/notes`, git-ignored so it never
>   dirties or clutters the repo; archived to `<root>/.fleet/notes/archive/…` on
>   `fleet reap`). When you dispatch, **instruct the worker in its `-p` prompt** to
>   write research/plans/architecture/scratch markdown to `$FLEET_DOCS` instead of
>   the repo root — keeps returned diffs clean.

### Actual assignment in `bin/fleet`

Two distinct values depending on spawn kind, both computed in `cmd_new`:

**Scratch (repo-less) agents** — `bin/fleet:1000-1003`:

```sh
    # Repo-less, so no worktree/info-exclude — give it a sane scratch-docs dir
    # under the shared root anyway, so $FLEET_DOCS is always a real dir.
    docs="$root/.fleet/notes/scratch/${repo:-scratch}"
    mkdir -p "$docs" 2>/dev/null || true
```

→ `/home/red/proj/pc-tune/.fleet/notes/scratch/<label>/`

**Worktree workers** — `bin/fleet` (end of the non-scratch branch, ~`:1058-1060`):

```sh
    # Per-branch scratch-docs dir, present before the agent starts. mkdir is
    # idempotent across reuse of an existing worktree.
    docs="$dir/.fleet/notes"
    mkdir -p "$docs" 2>/dev/null || true
```

→ `/home/red/proj/pc-tune/fleet/<branchdir>/.fleet/notes/`

Followed immediately by the git-invisibility trick (comment at the same site):
"Git-invisibility WITHOUT a tracked .gitignore or any commit: append an anchored
'/.fleet/' to the repo's COMMON exclude (shared by every worktree…)".

### Injection into the pane

Three call sites, all `tmux -e`:

- `bin/fleet:1129` — hidden-session scratch spawn:
  `local _eargs=(-e FLEET_ROLE=worker -e FLEET_DOCS="$docs" -e FLEET_SELF_MERGE="$self_merge")`
- `bin/fleet:1159` — visible bare worker:
  `-e FLEET_ROLE=worker -e FLEET_DOCS="$docs" -e FLEET_SELF_MERGE="$self_merge" "${argv[@]}"`
- `bin/fleet:1167` — the **nvim** pane (see §5/§6).

### What actually writes there

Nothing in `bin/fleet` writes files into `$FLEET_DOCS` beyond `mkdir -p`. It is a
**convention enforced by prompt text**, not by code:

- `FLEET_SUBORCH.md:105` — "write full detail to `$FLEET_DOCS` / `_reports/<slug>/` and return a digest"
- `SKILL.md:24` — "Tell every dispatched agent to write scratch notes/plans to **`$FLEET_DOCS`**, not the repo."
- `SKILL.md:104` — "Tell it to write notes to `$FLEET_DOCS`."

Empirically it *is* used heavily. `/home/red/proj/pc-tune/.fleet/notes/scratch/` holds
one dir per scratch agent — 30+ entries including `adv-pro`, `adv-con`, `adv-alt`,
`adv-ux`, `cards-research`, `cards-test-a`, `cards-test-b`, `dist-synthesis`,
`dispatch-seed-research`, `agent-role-glyph-research`, `blockinbox-research`, …

Note the naming: these are **per-agent**, not per-dispatch and not per-slug. A single
dispatch's docs are smeared across many sibling dirs (`cards-research`, `cards-pro`,
`cards-con`, `cards-value`, `cards-test-a`, `cards-test-b` are all one feature).

Archive path on reap: `<root>/.fleet/notes/archive/…` — `/home/red/proj/pc-tune/.fleet/notes/archive/` exists.

---

## 3. Where pipeline worker artifacts actually get written

### The contract (skill + manual)

Skill: `/home/red/.claude_personal/skills/fleet-implementation-pipeline/SKILL.md`.

- `:20` — "Artifacts land under `_reports/<feature-slug>/`."
- `:73` — "Write it to `_reports/<feature-slug>/PLAN.md`. **Research only — no code.**"
- `:75` — `fleet new --scratch <slug>-research -p "RESEARCH ONLY … write _reports/<slug>/PLAN.md …"`
- `:84` — each adviser writes `_reports/<slug>/debate-<lens>.md`
- `:89` — synthesis verdict at `_reports/<slug>/SYNTHESIS.md`
- `:121` — each tester writes `_reports/<slug>/TEST-<a|b>.md`
- `:134` — adversary writes `_reports/<slug>/TEST-VERDICT.md`
- `:148` — "Keep all artifacts under `_reports/<feature-slug>/` so each loop iteration is traceable."

Mirrored in `FLEET_SUBORCH.md:115` (role-1 outputs `PLAN.md`, `SYNTHESIS.md`,
`PLAN-PLAIN.md`) and `:135-136` (`TEST-a.md`, `TEST-b.md`, `TEST-VERDICT.md`).

**Every one of these paths is RELATIVE.** There is no `$FLEET_REPORTS` variable and no
code anywhere that resolves `_reports` to a fixed location. The path therefore resolves
against **whatever the writing agent's cwd happens to be** — which differs by role:

| role | spawn form | cwd | `_reports/<slug>/` resolves to |
|---|---|---|---|
| sub-orch | `--scratch` (`bin/fleet:999`) | `$root` | `/home/red/proj/pc-tune/_reports/<slug>/` |
| RESEARCH (role 1) | `fleet new --scratch <slug>-research` (`SKILL.md:75`) | `$root` | `/home/red/proj/pc-tune/_reports/<slug>/` |
| IMPL (role 2) | `fleet new <repo> fleet/<slug>` (`FLEET_SUBORCH.md:118`) | worktree | `/home/red/proj/pc-tune/fleet/fleet_<slug>/_reports/<slug>/` |
| TEST (role 3) | fleet agent **on the impl branch** (`FLEET_SUBORCH.md:130`) | that worktree | same worktree as impl |

So the contract says "keep all artifacts under `_reports/<slug>/` so each loop is
traceable", but the mechanism **splits a single slug's artifacts across two filesystem
locations by role** — research on one side of the boundary, impl+test on the other.

### Empirical verification

Four distinct `_reports` trees exist right now:

```
/home/red/proj/pc-tune/_reports                             <- project root (53 slug dirs)
/home/red/proj/pc-tune/fleet/main/_reports                  <- fleet main worktree (17 dirs)
/home/red/proj/pc-tune/fleet/runaway-suborch-spawn/_reports
/home/red/proj/pc-tune/fleet/fleet_worktree-secrets/_reports
```

**Root tree is untracked scratch; the fleet-repo tree is committed.**

```
$ git -C /home/red/proj/pc-tune ls-files _reports      # (nothing)
$ git -C /home/red/proj/pc-tune/fleet/main ls-files _reports | wc -l
39
```

That asymmetry explains the third and fourth trees: `fleet/runaway-suborch-spawn/_reports`
and `fleet/fleet_worktree-secrets/_reports` contain the *same* slug dirs as
`fleet/main/_reports` (`dash-cards-polish`, `dash-inbox-styling`,
`dashboard-orchestrator-cards`, `dispatch-seed-fix`, …) because they are **git checkouts
of the tracked files**, not independent writes. Every new fleet worktree gets a full
copy of every historical report — pure noise in each worker's tree.

Per-slug comparison (root vs `fleet/main`):

| slug | in root `_reports` | in `fleet/main/_reports` |
|---|---|---|
| `dash-inbox-styling` | — | `PLAN.md SYNTHESIS.md debate-pro.md debate-con.md PROOF.md TEST-a.md TEST-b.md TEST-VERDICT.md` |
| `dispatch-seed-fix` | — | `PLAN.md PROOF-DESIGN.md SYNTHESIS.md debate-{pro,con,alternatives}.md PROOF.md TEST-{a,b}.md TEST-VERDICT.md` |
| `agent-role-glyph` | — | (empty dir) |
| `suborch-nvim` (d25, live) | — | `EXPLORE-A.md EXPLORE-B.md` |
| `blocked-inbox` | `PLAN.md debate-pro.md debate-con.md` | — |
| `runaway-suborch-spawn`, `reap-teardown`, `parked-suborch-revival`, `worktree-secrets` | present | (some also in main) |

Two observations that matter:

1. **The split is real and historically inconsistent.** Older dispatches
   (`blocked-inbox`, `orch-layer`, `dist-*`, `claude-ctrlh`) left their full artifact set
   at the **root**; newer ones (`dash-inbox-styling`, `dispatch-seed-fix`) have the full
   set — research artifacts included — inside **`fleet/main/_reports`**. Nothing in the
   tooling forces either; it is entirely a function of what cwd the writing agent had and
   whether the prompt happened to carry an absolute path.

2. **Absolute paths in a prompt override the cwd default.** The live d25 case proves it:
   the research role is a `--scratch` agent (cwd = `$root`), yet `EXPLORE-A.md` and
   `EXPLORE-B.md` landed in `/home/red/proj/pc-tune/fleet/main/_reports/suborch-nvim/`,
   because each explorer's prompt named that absolute path. This is the *only* mechanism
   currently keeping a dispatch's artifacts co-located, and it is a per-prompt human/LLM
   discipline with no enforcement — one forgotten absolute path silently scatters a file.

Root `_reports` also contains loose non-slug files at top level:
`SYNTHESIS.md`, `csharp-port-feasibility.md`, `menu-audit.md`,
`fleet.{adviser,researcher,debate-pro,debate-con,feature-research}.md`,
`nvim.*`, `tmux.*`, `tmuxinator.*` — an older, flatter convention (18–22 Jun) that
predates the `<slug>/` layout.

---

## 4. Is there a single directory from which a dispatch's whole output is visible?

**No. There is no such directory today, and no candidate is even close.**

A single dispatch `d<N>` with slug `<slug>` produces up to five disjoint file sets:

- **(L) ledger** — `/home/red/proj/pc-tune/.fleet/dispatch/d<N>/`
  → `instruction.txt`, `meta.tsv`, `workers.tsv`, `STATUS.md`
- **(Rr) research reports** — `/home/red/proj/pc-tune/_reports/<slug>/`
  → `PLAN.md`, `SYNTHESIS.md`, `PLAN-PLAIN.md`, `debate-*.md` (when the research role used its default cwd)
- **(Rw) impl/test reports** — `/home/red/proj/pc-tune/fleet/fleet_<slug>/_reports/<slug>/`
  → `TEST-a.md`, `TEST-b.md`, `TEST-VERDICT.md`, `PROOF.md`
- **(Ds) scratch docs** — `/home/red/proj/pc-tune/.fleet/notes/scratch/<agent-label>/`
  → one dir **per agent**, several per dispatch
- **(Dw) worktree docs** — `/home/red/proj/pc-tune/fleet/fleet_<slug>/.fleet/notes/`
- **(C) the code itself** — the branch `fleet/<slug>` in `/home/red/proj/pc-tune/fleet/fleet_<slug>/`

Candidate roots, concretely:

| candidate (real path) | shows | misses |
|---|---|---|
| `/home/red/proj/pc-tune` | everything, transitively — it is the common ancestor | useless as a *view*: 53 root report slugs + 20 ledger dirs + N worktrees × full tracked `_reports` copies. No dispatch-scoped subtree; you cannot `ls` a dispatch. |
| `/home/red/proj/pc-tune/.fleet/dispatch/d25/` | L (4 files) | Rr, Rw, Ds, Dw, C — i.e. all substantive output. Contains only status *about* the work. |
| `/home/red/proj/pc-tune/_reports/<slug>/` | Rr | L, Rw, Ds, Dw, C. For `suborch-nvim` this dir **does not even exist**. |
| `/home/red/proj/pc-tune/fleet/main/_reports/<slug>/` | whatever was addressed by absolute path (for d25: `EXPLORE-A/B.md`) | L, Ds, Dw; and it is the **wrong repo/branch** for the impl worktree's own outputs |
| `/home/red/proj/pc-tune/fleet/fleet_<slug>/` | Rw + Dw + C | L, Rr, Ds. Also polluted with the tracked `_reports/` of every *past* dispatch. |
| `/home/red/proj/pc-tune/.fleet/notes/scratch/` | Ds, but fanned across per-agent dirs with no dispatch key | everything else; you must already know each agent's label to find its notes |

Three structural reasons no single directory can work as things stand:

1. **The reports path is relative and the roles have different cwds** (§3). Two cwds ⇒
   at minimum two report roots, before any worktree multiplicity.
2. **`_reports` is git-tracked in the fleet repo** (39 files). Anything committed there
   is replicated into *every* future worktree checkout, so "the reports dir" is inherently
   many-instanced, and a worktree deleted by `fleet reap` takes its uncommitted reports
   with it.
3. **The ledger key is `d<N>`, the reports key is `<slug>`, and the docs key is the
   per-agent label.** Three different naming schemes, no join column on disk. Only
   `workers.tsv` (repo+branch rows) and the window name `so-d25-suborch-nvim` carry any
   link, and `_reports/<slug>` is never recorded in `meta.tsv`.

Worth noting for the design phase: `FLEET_SUBORCH.md:194` already makes recovery depend
on reading `_reports/<slug>/SYNTHESIS.md` and `TEST-VERDICT.md` from the sub-orch's cwd
(`$root`). If the research role wrote them anywhere other than `$root/_reports/<slug>/`,
that crash-recovery cross-check silently fails to find them and mis-reads the phase — a
live correctness consequence of the scatter, not just an ergonomic one.

---

## 5. `nvim/fleet.lua` — autostart mechanics

File: `/home/red/proj/pc-tune/fleet/main/nvim/fleet.lua` (160 lines).

### How nvim is launched — `bin/fleet:1162-1173`

```sh
    # nvim pane: claude autostarts via claudecode.nvim; other harnesses open in a
    # generic :terminal. Both seed the prompt + take FleetSend over the nvim RPC.
    local nsock="$RUNTIME_DIR/fleet/nvim-$(date +%s%N).sock"
    mkdir -p "$RUNTIME_DIR/fleet"
    win_id=$(tmux new-window -d -P -F '#{window_id}' -t "$sess" -n "$wname" -c "$dir" \
      -e FLEET_ROLE=worker -e FLEET_DOCS="$docs" -e FLEET_SELF_MERGE="$self_merge" \
      -e FLEET_AUTOCLAUDE="$([ "$H_NVIM_PLUGIN" = 1 ] && echo 1 || echo 0)" \
      -e FLEET_HARNESS="$H_NAME" -e FLEET_HARNESS_BIN="$hbin${H_ARGS:+ $H_ARGS}" \
      -e FLEET_TERM_MATCH="$H_TERM_MATCH" -e FLEET_PROMPT="$prompt" \
      -e FLEET_START_MODE="$H_START_MODE" \
      nvim . --cmd "lua pcall(dofile, '$FLEET_DIR/nvim/fleet.lua')" --listen "$nsock")
    tmux set -w -t "$win_id" @fleet_nvim_sock "$nsock"
```

Key points:

- **cwd**: `tmux new-window -c "$dir"` — for a worktree worker `$dir` is the worktree;
  for scratch, `$dir="$root"`. **But scratch always sets `bare=1` (`bin/fleet:997`), so
  the nvim path is never taken for scratch agents.** Today a sub-orch has no editor at
  all — that is precisely what d25 is about.
- **`nvim .`** — nvim opens with cwd = `$dir` and the argument `.` (a directory).
- **`--cmd "lua pcall(dofile, …)"`** — the fleet lua is `dofile`d, never installed into
  the user's config. `pcall` so a broken/missing file cannot block nvim
  (`nvim/fleet.lua:4-6`: "wrapped so a missing claudecode.nvim just means 'no autostart',
  never an error that blocks nvim").
- **`--listen "$nsock"`** — the RPC socket, stashed on the window option
  `@fleet_nvim_sock`; that option's presence is how fleet distinguishes nvim agents from
  bare panes (`bin/fleet:1385`).

### The autostart itself — `nvim/fleet.lua:18-62`

```lua
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local prompt = vim.env.FLEET_PROMPT
    if vim.env.FLEET_AUTOCLAUDE == "1" then
      -- Claude via claudecode.nvim.
      vim.defer_fn(function()
        local ok, terminal = pcall(require, "claudecode.terminal")
        if not ok then
          vim.notify("fleet: claudecode.nvim not available, open claude manually", vim.log.levels.WARN)
          return
        end
        -- Fleet-scoped permission mode: only this autostart path passes it, so
        -- manual <leader>cc launches keep claudecode's configured default.
        local sm = vim.env.FLEET_START_MODE
        local cmd_args = (sm and sm ~= "") and ("--permission-mode " .. sm) or nil
        pcall(terminal.open, {}, cmd_args)
        -- Seed the prompt through the terminal channel (same path as FleetSend)
        -- — passing it as a CLI arg through terminal.open proved unreliable.
        if prompt and prompt ~= "" then
          vim.defer_fn(function() FleetSend(prompt) end, 3000)
        end
      end, 300)
    elseif vim.env.FLEET_HARNESS_BIN and vim.env.FLEET_HARNESS_BIN ~= "" then
      -- Generic harness (omp, …): open it in a plain :terminal split so
      -- FleetSend can chan_send into it just like the claude terminal.
      vim.defer_fn(function()
        pcall(function()
          vim.cmd("botright vsplit")
          vim.cmd("terminal " .. vim.env.FLEET_HARNESS_BIN)
          vim.cmd("startinsert")
        end)
        ...
```

- Everything is deferred to `VimEnter` + a further 300ms so plugins are loaded
  (`:17` "Defer everything until plugins are loaded").
- **Plugin**: `claudecode.nvim` (`require("claudecode.terminal")`), gated on
  `FLEET_AUTOCLAUDE == "1"`, which `bin/fleet:1168` derives from the harness's
  `H_NVIM_PLUGIN` flag. Non-claude harnesses fall back to a raw `botright vsplit` +
  `:terminal $FLEET_HARNESS_BIN`.
- **Prompt seeding is a 3s-deferred `FleetSend`, not a CLI arg** — the comment records
  that arg-passing "proved unreliable". `FleetSend` writes to the terminal channel and
  sends a **separate** `\r` 80ms later (`:82-96`), because a combined write reads as a
  bracketed paste and the TUI swallows the trailing CR.
- `FLEET_TERM_MATCH` (default `"claude"`, `:10-14`) selects which terminal buffer counts
  as "the agent" for `FleetSend` / `FleetCycleMode`.

### Does it open a picker? — **No, not directly**

`nvim/fleet.lua` contains **no** picker code: no `oil`, no `netrw`, no `telescope`, no
`neo-tree` reference anywhere in the file. Confirmed by grep over `bin/fleet` too (the
only hits for `oil|netrw|telescope` are none).

The directory listing comes for free from `nvim .` plus the **user's own config**:

- `/home/red/.config/nvim/lua/config/options.lua:46-49`:
  ```lua
  -- Disable netrw so oil.nvim handles directory paths (e.g. `nvim .`).
  vim.g.loaded_netrw               = 1
  vim.g.loaded_netrwPlugin         = 1
  ```
- `/home/red/.config/nvim/lua/plugins/specs.lua:17` — `{ src = "https://github.com/stevearc/oil.nvim" }`
- `/home/red/.config/nvim/lua/plugins/mini.lua:17` — "oil owns `nvim <dir>` / `-`; without this mini.files hijacks directory buffers"
- `/home/red/.config/nvim/lua/plugins/neo-tree.lua:1` — "Complements oil.nvim (buffer-as-dir on `<leader>e`)"

So: **`nvim .` → oil.nvim buffer showing `$dir`**. netrw is explicitly dead; mini.files is
explicitly prevented from hijacking. This is a property of the user's config, not of
fleet — a machine without oil would get a plain empty/netrw-less directory buffer.

For d25 this is the load-bearing fact: give a sub-orch an nvim pane at `$root` and the
editor opens an **oil buffer on `/home/red/proj/pc-tune`**, which shows `.fleet/`,
`_reports/`, and the repo containers side by side — the closest thing to the "single
directory" §4 says doesn't exist, though still only as a browsing root, not a
dispatch-scoped view.

---

## 6. Does nvim inherit and pass the pane env to the terminal job?

**Yes, on both paths.**

### Pane → nvim

`tmux new-window -e VAR=val …` sets the variable in the new pane's environment, and nvim
is the pane's direct process (`bin/fleet:1167-1172`). So `FLEET_DOCS`, `FLEET_ROLE`,
`FLEET_PROMPT`, `FLEET_START_MODE`, `FLEET_TERM_MATCH`, `FLEET_HARNESS_BIN`,
`FLEET_SELF_MERGE` are all in nvim's own env. `nvim/fleet.lua` reads them via `vim.env.*`
(`:11`, `:21-22`, `:31`, `:39`, `:44`) — direct evidence they arrive.

### nvim → terminal job

**Generic-harness path** — `nvim/fleet.lua:45`: `vim.cmd("terminal " .. vim.env.FLEET_HARNESS_BIN)`.
Ex-`:terminal` spawns via `termopen` with no `env`/`clear_env`, so the job inherits
nvim's environment wholesale.

**claudecode path** — `terminal.open` ends at the native provider,
`/home/red/.local/share/nvim/site/pack/core/opt/claudecode.nvim/lua/claudecode/terminal/native.lua:89-92`:

```lua
  jobid = vim.fn.termopen(term_cmd_arg, {
    env = env_table,
    cwd = effective_config.cwd,
```

`env_table` is built at
`/home/red/.local/share/nvim/site/pack/core/opt/claudecode.nvim/lua/claudecode/terminal.lua:310-324`
and holds only claudecode's own additions (`CLAUDE_CODE_SSE_PORT` etc. — `:316`, `:321`).
Crucially there is **no `clear_env = true`** anywhere in the provider; in Neovim,
`termopen`'s `env` *extends* the inherited parent environment unless `clear_env` is set.
So the claude job gets nvim's full env **plus** the SSE vars — the `FLEET_*` vars survive
into the agent process.

**cwd**: `effective_config.cwd` comes from the user's config,
`/home/red/.config/nvim/lua/plugins/claudecode.lua:5-8`:

```lua
  -- Spawn Claude in nvim's project cwd so the wrapper sees the right folder.
  cwd_provider = function(ctx)
    return ctx.cwd
  end,
```

i.e. the harness process's cwd is deliberately pinned to **nvim's cwd**, which is `$dir`
from `tmux -c` — the worktree (or, for a hypothetical scratch-nvim sub-orch, `$root`).
That closes the loop with §3: the agent's `_reports/<slug>/` relative writes resolve
against exactly this directory.

Also relevant: `terminal_cmd` is `$HOME/.local/bin/claude-profile`
(`claudecode.lua:4`), a wrapper — one more process in the chain, but it too inherits.

Caveat: `claudecode.lua:65` notes "claudecode opens via snacks.terminal", so the snacks
provider may be selected rather than native. `terminal.lua:131-136` tries snacks first
and falls back to native. Snacks' terminal likewise uses `termopen` without `clear_env`,
so the inheritance conclusion is unchanged either way; only the window chrome differs.

---

## Summary of the load-bearing facts for the d25 design

1. Sub-orch writes **only** to `.fleet/dispatch/<id>/` (4 files + occasional extras);
   its cwd is `$root` and it is spawned `--scratch` ⇒ `bare=1` ⇒ **no nvim today**.
2. `$FLEET_DOCS` = `<worktree>/.fleet/notes` for workers, `<root>/.fleet/notes/scratch/<label>`
   for scratch agents (`bin/fleet:1002`, `~:1058`). Populated by prompt convention only.
3. `_reports/<slug>/` is a **relative** path with no env var behind it; research (cwd=root)
   and impl/test (cwd=worktree) therefore land in different trees, and `_reports` being
   git-tracked in the fleet repo replicates old reports into every new worktree.
4. **No single directory shows a dispatch's whole output.** `$root` is the only common
   ancestor and it has no dispatch-scoped subtree. Recovery logic at `FLEET_SUBORCH.md:194`
   already depends on this scatter resolving correctly, so this is a correctness issue.
5. Autostart = `VimEnter` → `claudecode.terminal.open` (or raw `:terminal`) → 3s-deferred
   `FleetSend(FLEET_PROMPT)`; `nvim .` yields an **oil.nvim** buffer on the pane's cwd.
6. Pane env flows tmux `-e` → nvim → `termopen` (no `clear_env`) → harness; cwd is pinned
   to nvim's cwd by `cwd_provider` in the user's claudecode config.

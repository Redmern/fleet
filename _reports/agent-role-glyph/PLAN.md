# agent-role-glyph — implementation plan (d26)

Feature: every agent pane carries a **task role** (research / plan / impl / test /
scratch / generic) that is **visible** in `fleet ls`, the dashboard, and the tmux
window status bar.

Verdict: **BUILD** (see SYNTHESIS.md).

---

## 0. Naming — non-negotiable

`role` is already four different things in this repo, one of them a security gate:

| existing name | meaning | anchor |
|---|---|---|
| `FLEET_ROLE` env | `main` / `worker`; fork-bomb gate + merge/push gate | `bin/fleet-dispatch.sh:18`, `bin/fleet-guard:33` |
| `.fleet/roles/<pane-id>` | `main` / `worker` / `worker:so-<id>`; `is_main_pane` | `bin/fleet:163-172`, writer `bin/fleet:1569-1573` |
| `@fleet_role` window opt | mirror of the above; orchestrator filter | `bin/fleet:3661`, `:4456`; read `bin/fleetd:329,344,352`, `bin/fleet-dash:413` |
| `ROW_ROLE` (dash) | card header (0) vs worker (1) | `bin/fleet-dash:186,925,970` |

The new concept is therefore called **task role**, with the identifiers:

- CLI flag: `--task <name>`
- window option: `@fleet_task`
- durable file: `<root>/.fleet/tasks/<window-name>`
- dash array: `TASK_RAW[]`
- env: **none** (do not add a new `FLEET_*` env — nothing needs it in-pane)

Enum (fixed, validated at the single write site):

```
research | plan | impl | test | scratch | generic
```

Display tags (4 chars, pure ASCII, always width-1):

```
research -> rsch    plan -> plan    impl -> impl
test     -> test    scratch -> scr    generic -> (blank)
```

`generic` renders as **nothing**. A missing/unknown role renders as nothing too —
a wrong badge misroutes human attention worse than no badge (Adviser 2 (f)).

---

## 1. Store: window option + window-name-keyed file. **Zero TSV changes.**

### 1a. Why not the TSVs (hard blocker, three independent readers)

- `.agents` file: `persist_agent` `bin/fleet:569-578` writes 9 cols; reader
  `cmd_restore` `bin/fleet:745` is
  `IFS=$'\037' read -r dir repo branch bare base harness self_merge wname owner`
  — the **last var absorbs every extra column**. A new fleet writing col 10 and an
  old fleet (pacman `/usr/bin/fleet` vs the dev symlink — this project ships both
  on purpose) reading it yields `owner="so-d7<US>impl"`, which is re-exported as
  `FLEET_SUBORCH_ID` at `bin/fleet:764` and sliced into the `d<N>-` window prefix
  at `:1084-1088`. Silent corruption. There is **no version/migration mechanism
  anywhere** in `bin/` (grep for `schema|version|migrat` = 0 hits).
- `fleet agents` TSV: `bin/fleet-dash:409` is a positional
  `while IFS=$'\t' read -r state label sess win wname since pane age ready`. Tab is
  IFS-whitespace, so an empty col 9 collapses and a new col 10 lands in `$ready`
  → **every** row renders the `done` pill (`bin/fleet-dash:1002-1005`), while
  `fleet ls` (`bin/fleet:343,391`) stays correct. ls and dash disagree; a human
  trusting the dash reaps live work.
- `bin/fleetd:333` is a hard `if len(parts) == 9:` on the `list-panes -F` split, and
  the synth pass `bin/fleetd:365-410` unpacks a fixed 8-tuple. A 10th field empties
  every row's metadata → dash session filter `bin/fleet-dash:398` drops everything
  → blank dashboard, fail-silent.

**Conclusion: do not touch `agents_tsv` (`bin/fleet:202-278`), `persist_agent`,
`cmd_restore`, or `bin/fleetd` at all** (except the one status-bar line, §3c).

### 1b. What we do instead

Two writes at spawn time, both in `cmd_new`:

1. **`tmux set -w -t "$win_id" @fleet_task "$task"`** — live, fast, read by the dash
   the same way it already reads `@fleet_role` at `bin/fleet-dash:413`.
2. **`<root>/.fleet/tasks/<window-name>`** containing the bare role word — the
   durable copy.

Keyed by **window name, not pane id.** `.fleet/roles/<pane-id>` is poisoned today
because tmux reassigns pane ids across a server restart and the entries are never
GC'd. Window name is the key `cmd_restore` already round-trips (persisted col 8,
`bin/fleet:749-751`) and the key every target resolver already matches on
(`index($2,t)||index($5,t)`, e.g. `bin/fleet:707,3038,3361,3432`).

Durability matrix:

| event | `@fleet_task` | `.fleet/tasks/<wname>` |
|---|---|---|
| fleetd restart | survives | survives |
| tmux server restart | lost | **survives** |
| `fleet restore` | re-stamped from the file | survives |
| `fleet reap` / `forget` | gone with the window | must be removed — see §2d |
| scratch / sub-orch pane | survives while the server lives | survives (root-level dir, no worktree needed) |

Read precedence (one helper, §2b): `@fleet_task` → file → **blank**. No inference
from branch names: `scratch_wname` `bin/fleet:562` appends `-2`/`-3` on collision,
and the impl-role branch (`fleet/<slug>`, `FLEET_SUBORCH.md:120`) has no marker at
all and is byte-identical to a flat human worker — inference cannot see the one
role the human most needs distinguished.

---

## 2. `bin/fleet` changes

### 2a. `cmd_new` — the flag (`bin/fleet:962-1240`)

- `bin/fleet:963` — add `task` to the `local` list.
- `bin/fleet:971` (beside `--harness|-h`) —
  `--task|-T) task="$2"; shift 2;;`
- after `harness_load` (`bin/fleet:981`) — validate:
  ```sh
  case "$task" in
    ""|research|plan|impl|test|scratch|generic) ;;
    *) printf 'fleet: unknown --task %s (ignored)\n' "$task" >&2; task="" ;;
  esac
  ```
  Fail-silent per CLAUDE.md:16-19 — warn, drop, continue. **Hard-reject anything
  outside the enum**; this is what makes §3c injection-safe and keeps the badge
  exactly 4 cells forever.
- `--scratch` path (`bin/fleet:994-1006`) — default `task="${task:-scratch}"`.

### 2b. Two new helpers (near `record_pane_role`, `bin/fleet:1569`)

```sh
task_file() { printf '%s/.fleet/tasks/%s' "$1" "$2"; }   # root, wname

record_task() {                                          # root wname task
  [ -n "$3" ] || return 0
  mkdir -p "$1/.fleet/tasks" 2>/dev/null || return 0
  printf '%s\n' "$3" >"$(task_file "$1" "$2")" 2>/dev/null || true
}

task_of() {                                              # win_id root wname -> role|""
  local t; t=$(tmux show -wqv -t "$1" @fleet_task 2>/dev/null)
  [ -n "$t" ] || t=$(cat "$(task_file "$2" "$3")" 2>/dev/null)
  case "$t" in research|plan|impl|test|scratch|generic) printf '%s' "$t" ;; esac
}

task_tag() {                                             # role -> 4-char tag
  case "$1" in research) printf rsch;; plan) printf plan;; impl) printf impl;;
                test) printf test;; scratch) printf 'scr ';; *) printf '    ';; esac
}
```

`task_of` re-validates on **read** as well — a hand-edited file can never inject.

### 2c. `cmd_new` — the stamps

- window option: after the `win_id` guard, beside `@fleet_harness`
  (`bin/fleet:1186`) — `tmux set -w -t "$win_id" @fleet_task "$task" 2>/dev/null || true`
- durable file: beside `record_pane_role` (`bin/fleet:1203-1209`) —
  `record_task "$root" "$wname" "$task"`.
  **Do not write into `.fleet/roles/`** — that vocabulary is the fork-bomb gate.

### 2d. Cleanup

- `cmd_forget` (`bin/fleet:580-585`) — also `rm -f "$(task_file "$root" "$wname")"`.
  `cmd_forget` runs at the tail of `cmd_reap`'s MUTATE phase, after
  `git worktree remove` has succeeded, so this stays inside the atomic contract
  (CLAUDE.md:96-112) and can never cause a refusal.

### 2e. `cmd_restore` (`bin/fleet:734-770`) — **no signature change**

`cmd_restore` re-invokes `cmd_new`; add `--task "$(task_of '' "$root" "$matchname")"`
to the rebuilt arg list at `bin/fleet:753-761` (empty → flag omitted). The role
comes back from the file; nothing is read from the `.agents` line. Old `.agents`
files work untouched.

### 2f. `fleet ls` — the static path (`bin/fleet:385-394`)

Pure tab-separated, **no padding math** — a free insert:

```
printf 'STATE\tTASK\tAGENT\tWINDOW\tIN-STATE\n'
printf "%s\t%s\t%s\t%s:%s\t%s%s\n", st, task, $2, $3, $5, $6, extra
```

The role is not in the TSV, so the awk pipeline can't supply it. Resolve it in the
shell before awk: build a `wname<TAB>tag` sidecar (one `tmux show -wqv` per window,
already the pattern the dash uses) and pass it with `awk -v`/a first `FILENAME`
block, or drop to a `while read` loop. Cheapest concrete form: pre-render a
`declare -A` and post-process. Whichever — **the TSV shape does not change.**

### 2g. Leave the pickers alone (deliberate)

The fzf jumper (`bin/fleet:334-346`) and `cmd_pick` (`bin/fleet:411`) are two
near-duplicate formatters with **hand-maintained** column math and a hand-padded
`hdr` string, and their rows feed `popup_fit_content` (`bin/fleet:4166-4189`) whose
`${#line}` counts codepoints, not display cells. Adding a column there triples the
blast radius for a badge nobody reads mid-teleport. Out of scope for v1;
`pick_project` (`:439-441`) likewise.

---

## 3. `bin/fleet-dash` changes

### 3a. Cache the option (`bin/fleet-dash:187-198`)

Clone the existing `OWN_RAW[$wid]=$(tmux show -wqv ...)` block into
`TASK_RAW[$wid]`, with the same file fallback. One extra `tmux show` per window per
refresh — the same cost profile as `OWN_RAW`.

### 3b. Render (`bin/fleet-dash:911-1036`)

Prefer a **4-char text field** immediately left of the label, not a pill: pills cost
`PILL_W+4 = 11` columns each and the width ladder at `:993-999` already sheds
cost/mode/✉ on the narrow panes where a fleet actually runs.

- add `task_show` to the `np` chain (`:993`) as a `+4` term, not a `+PW` term;
- emit at `:1013`, before `fit_left "$label"`;
- **drop it first** in the degradation ladder (before cost) — the label must never
  be squeezed by the badge;
- do **not** name anything `ROW_ROLE` (taken, `:186`).

Blank tag = 4 spaces, so column alignment is stable whether or not a role is set.

### 3c. tmux status bar — the surface the human sees without running anything

This is the actual ask. `@agent_glyph` is fleetd-owned and rewritten on every state
transition (`bin/fleetd:151,155-159`), so **do not write into it**. Append a second,
independent token in the two places that already do the injection:

- `bin/fleet:3954` — the idempotency `case` currently keys on `*@agent_glyph*`; add
  a sibling `case` on `*@fleet_task*` appending `#{?@fleet_task,#{@fleet_task} ,}`.
- `bin/fleetd:274-278` `heal_status_format` — the same append, so a theme switch
  re-heals both.

Safe **only because** §2a hard-validates the enum: the option's contents are
format-expanded by tmux, so an unvalidated string carrying `#[` or an unbalanced
`#{` would corrupt the status bar for the whole server, not one window. Enum in,
nothing else possible. Wide glyphs are safe here (tmux measures display width
correctly) — but we're using ASCII anyway.

This is the only `bin/fleetd` edit in the whole feature (3 lines), and it does not
touch `list_agents`, the 9-field format string, or `refresh_pane`.

---

## 4. Producers — `FLEET_SUBORCH.md`

Doc-only, 3 lines, and it closes the real gap: the impl worker currently has no
marker at all.

- `FLEET_SUBORCH.md:108` — `fleet new --scratch <slug>-research --task research -p …`
- `FLEET_SUBORCH.md:120` — `fleet new <repo> fleet/<slug> --no-self-merge --task impl`
- `FLEET_SUBORCH.md:130` — spell out the literal test spawn with `--task test`
  (today it is prose only).

Optionally add a 3rd `role` column to the ledger's `workers.tsv`
(`FLEET_SUBORCH.md:238`, today `<repo>\t<branch>`) — append-only, legacy 2-col rows
read as empty. **Not** a source of truth; the window option/file is. Nice-to-have,
not required for v1.

---

## 5. Explicitly out of scope

- **`orchestrator` as a role.** The main pane and the dashboard are filtered out of
  the agent TSV by design (`bin/fleetd:344,352`; `bin/fleet:273-275`). Un-filtering
  to display a role would make `main` a resolvable `fleet send`/`mode`/close target
  and re-open the whole-session-teardown class of bug fixed at f63c3d8. Sub-orchs
  are already visually distinct as `so-<id>` **card headers** in the dash — the card
  header *is* the role display for them.
- Any `.agents` or `fleet agents` column. Any change to `fleetd`'s `list_agents`,
  the `len(parts)==9` check, or the synth pass.
- Any new `FLEET_*` env var.
- Unicode glyphs. `popup_fit_content` (`bin/fleet:4166-4189`), `fit_left`
  (`bin/fleet-dash:105-111`) and `hrule` (`:826-840`, `:1132-1134`) all measure
  codepoints; the documented house rule is `bin/fleet-dash:866-868` (width-1 only);
  the width-1 pool is already picked over (`● ✉ ⚠ ⚙ ⌫ ◉ ▌ ✓ ↑ ↓ ↵ ⏎ ⏵ ⏸`, plus a
  latent fullwidth `＋` bug at `bin/fleet:432`); and there is **no ASCII fallback
  ladder anywhere** in the codebase to hide behind. ASCII tags are correct under
  every terminal and locale by construction.

---

## 6. Diff budget

| file | ~lines | what |
|---|---|---|
| `bin/fleet` | ~55 | flag + validation + 4 helpers + 2 stamps + forget cleanup + restore arg + `ls` column + status-format token |
| `bin/fleet-dash` | ~20 | `TASK_RAW` cache + 4-char field + ladder entry |
| `bin/fleetd` | 3 | `heal_status_format` sibling append |
| `FLEET_SUBORCH.md` | 3 | `--task` on the three spawn lines |
| `CLAUDE.md` / `FLEET.md` | ~8 | document `--task` on `fleet new` (both copies — they are kept in sync, CLAUDE.md:5-9) |
| `test/agent-task-proof.sh` | new | see PLAN-PLAIN.md PROOF DESIGN |

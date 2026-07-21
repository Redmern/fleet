# ADVISE-CON — the case against giving sub-orchestrators an nvim pane

Dispatch d25. Lens: strongest case that "open the sub-orch with nvim" is the WRONG FIX.
Sources: `EXPLORE-A.md` (spawn/tmux), `EXPLORE-B.md` (lifecycle), `EXPLORE-C.md` (artifacts).
Fresh verification this pass is marked **[v]**.

---

## 0. The ask, and the two claims inside it

> "A fleet sub-orchestrator should be opened with nvim open so that the produced files
> are viewable. **This means it should be opened in the folder where all its created
> files are visible**"

Two claims, joined by "this means":

- **(i)** an editor should be attached to the sub-orch pane, and
- **(ii)** there exists a folder from which all its created files are visible.

The second sentence is not a decoration — it is the human's own statement of the success
condition. **(ii) is false today.** And because (i) is only useful *given* (ii), the
proposal as stated cannot be implemented: you would be pointing an editor at a directory
that does not contain the thing you want to look at. Everything below follows from that.

---

## 1. Premise attack — there is no such folder, and $root is the worst candidate

The sub-orch's cwd is `$root` (`bin/fleet:999`, scratch ⇒ `dir="$root"`) and must stay
`$root` (every relative `.fleet/dispatch/<id>/…` ref in `FLEET_SUBORCH.md` resolves
against it). So "open nvim on the sub-orch" concretely means **an oil.nvim buffer on
`/home/red/proj/pc-tune`**. What that shows, measured **[v]**:

| at `$root` | count | relevance to dispatch d25 |
|---|---|---|
| `_reports/` slug dirs | **54** | 53 belong to *other* dispatches; `suborch-nvim/` is **not among them** |
| `.fleet/dispatch/` ledger dirs | **20** (`d1`, `d7`…`d26`) | 19 belong to other dispatches |
| repo containers under `fleet/` | 3 (`main`, `runaway-suborch-spawn`, `fleet_worktree-secrets`) | each carries a *full git-tracked copy* of all 17 historical `_reports` slugs |

The four files this dispatch has actually produced —
`EXPLORE-A.md`, `EXPLORE-B.md`, `EXPLORE-C.md`, and this file — live at
`/home/red/proj/pc-tune/fleet/main/_reports/suborch-nvim/`, i.e. **three directory
levels down, inside a worktree, in a tree whose other 16 slug-dirs are noise**. An oil
buffer at `$root` does not show them. It shows 74 sibling directories, of which exactly
**one** (`.fleet/dispatch/d25/`, 4 small status files **[v]**) is scoped to this dispatch,
and that one contains none of the substantive output.

So the proposal delivers: an editor rooted at the *maximum-noise* node of the tree, from
which the actual artifacts require the human to already know the path — at which point
they did not need the editor to be pre-opened there.

### 1.1 Why no single folder can exist as things stand (EXPLORE-C §4, restated as a defect)

Three independent structural reasons, each of which must be fixed *before* an editor
location is even well-defined:

1. **`_reports/<slug>/` is a bare relative path with no env var behind it.** Research
   agents (cwd `$root`) and impl/test workers (cwd = their worktree) therefore write to
   two different trees *by construction*. Two cwds ⇒ ≥2 report roots, before worktree
   multiplicity.
2. **`_reports` is git-tracked in the fleet repo** (39 files). Every new worktree
   checkout replicates every historical report — "the reports dir" is inherently
   many-instanced.
3. **Three keyspaces, no join column on disk:** ledger key `d<N>`, reports key `<slug>`,
   scratch-docs key `<agent-label>`. `meta.tsv` **[v]** records
   `created / window_id / state / window / role-phase` — and *not* the reports path.

An nvim pane addresses none of these three. It is a UI gesture at a data-layout problem.

### 1.2 The current co-location is an accident, not a mechanism

d25's artifacts are together only because each explorer's prompt happened to carry the
absolute path `/home/red/proj/pc-tune/fleet/main/_reports/suborch-nvim/`. That is
per-prompt LLM discipline with zero enforcement. Contrast older dispatches
(`blocked-inbox`, `orch-layer`, `dist-*`) which left everything at `$root/_reports/`.
Whatever folder you hard-code the editor to, roughly half of historical dispatches would
have put their files somewhere else.

### 1.3 There is already a live correctness bug here, and nvim does not touch it

`FLEET_SUBORCH.md:194` makes **crash recovery** depend on reading
`_reports/<slug>/SYNTHESIS.md` and `TEST-VERDICT.md` **from the sub-orch's cwd (`$root`)**.
For d25 those files are in `fleet/main/_reports/suborch-nvim/`, so the cross-check finds
nothing and mis-reads the phase. This is the *same* scatter, showing up as a correctness
failure rather than an ergonomic one. It is the real bug behind the human's complaint,
and an editor pane fixes exactly 0% of it.

---

## 2. Concrete breakage the nvim path introduces

Ordered by severity. B1+B3 compose into the headline risk.

### B1 — CRITICAL: `nvim` in `is_harness_cmd` converts recoverable failure into permanent silent hang

`is_harness_cmd` (`bin/fleet:1593`) allowlists `nvim`. `suborch_live` (1601-1611) probes
`#{pane_current_command}` of `head -1` of the window. Therefore:

- **Today** (bare pane): claude dies ⇒ `pane_current_command` is no longer a harness ⇒
  `suborch_live` false ⇒ `cmd_reconcile` (1988-1991) re-animates the sub-orch. Recovery
  works.
- **With nvim**: claude dies *inside* nvim ⇒ the pane is still topped by `nvim` ⇒
  `suborch_live` **true forever**. `cmd_reconcile` never enters the `! suborch_live`
  branch. The Layer-3 respawn cap (1996-2010) is never reached. The ledger never reaches
  a terminal state. **The dispatch stalls silently and permanently, and the pane is parked
  in a detached session where nobody is looking.**

This is a strict regression in the exact subsystem whose past failures produced the
respawn-loop bug (`ae61c81`) and the still-unfixed parked-sub-orch revival bug. We would
be trading a loud loop for a silent freeze.

### B2 — CRITICAL: seed delivery becomes asynchronous and unwitnessed

| | bare (today) | nvim (proposed) |
|---|---|---|
| delivery | prompt is a **positional argv element** of `claude` (1108-1109), synchronous, atomic with process start | `-e FLEET_PROMPT` → `VimEnter` → `defer_fn 300ms` → `terminal.open` → `defer_fn 3000ms` → `FleetSend` chan_send → separate `\r` 80 ms later |
| failure mode | claude either starts with the prompt or does not start | the write can land before the TUI is ready and be **silently swallowed** |

`nvim/fleet.lua:34-35` already records that CLI-arg delivery through `terminal.open`
"proved unreliable" — i.e. this path is *known* to be timing-sensitive, and the current
design is a 3-second guess.

For a **worker** a lost seed is survivable: it sits in a visible window and a human
notices an idle pane. For a **sub-orch** it is not: the pane is parked in the detached
`<sess>_hidden` session, invisible on the window bar and unreachable by
`next-window`/`prev-window`. It sits idle with an empty prompt — **and by B1 it reads as
ALIVE, so reconcile will never respawn it.** B1 ∘ B2 = a dispatch that is permanently,
silently dead with a green light next to it. This is the single strongest argument in this
document.

### B3 — HIGH: `FLEET_SUBORCH_ID` is not set on the nvim path, and its propagation is unproven

`FLEET_SUBORCH_ID` is passed in exactly one place: `bin/fleet:1130`, inside the *scratch*
`_eargs`. The nvim spawn (1166-1173) passes eight `-e` pairs and **not that one**. Without
it in the sub-orch's pane env, the entire ownership edge collapses:

- no `d<N>-` window prefix on spawned workers (1086-1087)
- no `@fleet_owner` stamp (1205) ⇒ `inbox_put` (2408) cannot attribute a worker's message
- `record_pane_role` degrades from `worker:so-<id>` to plain `worker` (1206→1208)
- `suborch_has_live_workers` (1627) and `suborch_pane_for` (1285) lose their key
- `cmd_watch`'s wake-escalation (1440, 1466-1469) loses its sub-orch id

So the nvim path requires new plumbing, and that plumbing rests on an inference:
**tmux `-e` → nvim → `termopen` → claude env propagation is argued from code
(`termopen` has no `clear_env`), never observed.** EXPLORE-A §5 and EXPLORE-C §6 both
reason it out; neither ran it, because no live nvim-path pane exists to test against.
Worse, `claudecode.lua:65` notes claudecode may select the **snacks** terminal provider
rather than the audited **native** one — so the code that was read may not be the code
that runs. Betting a non-forgeable ownership/routing invariant on an unverified inference
about a third-party plugin's provider selection is not a trade worth making for an editor
pane.

### B4 — MEDIUM: resumption of a parked sub-orch changes mechanism

`suborch_pane_for` (1285-1296) returns the first listed pane of the matched window; the
gate-pop / wake path `send-keys` into it. On the nvim path that pane's foreground process
is **nvim**, not claude. A `send-keys` resume would type into nvim's normal mode.
Resumption would have to route through the `@fleet_nvim_sock` RPC (1385-1386) instead —
i.e. the mechanism by which a gate-parked sub-orch is woken becomes dependent on an nvim
RPC socket file under `$RUNTIME_DIR` surviving for the lifetime of a dispatch that may
span hours and two human gates. Today it is a plain `send-keys` with no such dependency.

(Honest scoping: the claudecode terminal and the generic `botright vsplit` are **nvim**
windows, not tmux panes, so the window stays single-pane. The `head -1` picks at 1607 /
1203 and the dash's per-pane `HIDDEN_N` over-count at `fleet-dash:416` therefore do **not**
break. I am not claiming them.)

### B5 — MEDIUM: MAX_IMSGSIZE headroom moves the wrong way

The 16384 cap is **total per command**, not per arg (bisected in
`_reports/dispatch-seed-fix/PROOF-DESIGN.md:33-40`). The nvim path spends strictly more of
it than bare: 8 `-e` pairs including the whole `FLEET_PROMPT`, plus
`nvim . --cmd "lua pcall(dofile, '$FLEET_DIR/nvim/fleet.lua')" --listen "$nsock"`. The
current pointer seed is ~200 B so there is slack today — but the *entire reason* that seed
is a pointer is that a 20318-byte seed once blew the cap, `2>/dev/null` ate the error, and
sub-orchs silently never spawned. Moving the sub-orch onto the path with less headroom,
protected only by the empty-`win_id` guard, re-arms a gun we deliberately unloaded.

### B6 — MEDIUM: two concurrent sub-orchs both `nvim .` the same root

Concurrent dispatches are normal (20 ledger entries **[v]**). Two nvim instances rooted at
`$root`, both eventually opening `.fleet/dispatch/<id>/STATUS.md`-shaped files or the same
report tree, hit nvim's **E325 ATTENTION swapfile modal**. A modal prompt in a pane in a
detached session stalls that pane indefinitely — and again reads ALIVE under B1. New
failure mode with no analogue in the bare design.

### B7 — LOW but real: paying for an editor nobody opens

Every sub-orch would pay full nvim + plugin + LSP startup, and hold a long-lived stateful
editor process, in a window that by construction lives off the window bar and is reachable
only via a dashboard `Enter`. The sub-orch itself never edits a file — it writes 4 small
ledger files via its harness. This is cost with no consumer.

### B8 — the artifacts the human wants to read do not outlive the worktree

Impl/test reports (`TEST-a.md`, `TEST-b.md`, `TEST-VERDICT.md`, `PROOF.md`) live inside
`fleet/fleet_<slug>/`, which **`fleet reap` deletes**. An editor pointed anywhere at spawn
time cannot show files that are removed before the human browses. The underlying need is
partly *durability*, and an nvim pane has nothing to say about it.

---

## 3. The rhetorical core

The request presupposes a dispatch-scoped artifact directory. That directory does not
exist. So:

- If you build it, the human's stated need ("the produced files are viewable") is
  **already met** — they can open it in their own editor from the main pane, which is
  where they actually read things.
- If you don't build it, attaching nvim to the sub-orch points it at `$root` and shows
  them 74 directories of other people's work.

Either way, **the nvim pane is not the load-bearing part of the fix.** It is at best a
convenience layer on top of work that has to happen first, and at worst (B1∘B2) it trades
a working recovery path for a silent permanent hang in the dispatch layer.

---

## 4. Alternatives, ranked

### A1 — Record the artifact root in `meta.tsv`, and make it absolute *(do this first)*

`cmd_dispatch_rename` (`bin/fleet:1820-1834`) **[v]** already computes the slug and writes
`meta_set "$d" window "so-$id-$slug"`. Adding one adjacent line —
`meta_set "$d" reports "<abs>/_reports/$slug"` — creates the missing join column between
the `d<N>` and `<slug>` keyspaces. Then mandate in `FLEET_SUBORCH.md` that every worker
prompt carries that **absolute** path.

- Fixes the §1.3 **correctness** bug (recovery cross-check finding nothing) — the only
  actual defect in this area.
- Fixes the §1.2 accident (co-location becomes mechanism, not prompt discipline).
- ~2 lines. Zero lifecycle risk. Touches no spawn path.
- **Prerequisite for every other option, including the nvim one.**

### A2 — `fleet dispatch view <id>` *(the thing the ask actually asks for)*

Read `meta.tsv` (`reports` from A1, `window`) and `workers.tsv` — which **[v]** already
carries `<repo>\t<branch>` rows (d25: `scratch  suborch-nvim-research`), enough to derive
every worktree path and every `$FLEET_DOCS` dir. Materialize
`<root>/.fleet/dispatch/<id>/view/` as a tree of **symlinks** to: the ledger files, the
research reports, each worker's `_reports/<slug>/`, each `$FLEET_DOCS`, and the branch
worktree. Then `exec ${EDITOR:-nvim} <viewdir>`.

- This **literally creates** "the folder where all its created files are visible."
- Read-only, off the spawn path, no lifecycle coupling, no B1-B7 exposure.
- Serves the human from the main pane, where they are.
- Symlinks degrade visibly (dangling) after `fleet reap` rather than silently vanishing.

### A3 — `MANIFEST.md` in the ledger dir

The sub-orch (or `dispatch view --no-open`) appends one line per artifact: absolute path +
one-line description. Open it and use `gf`.

- Cheaper than A2 and **survives reap** — the record persists even when the worktree is
  gone, which A2's symlinks do not.
- Best combined with A2 (manifest = durable index, view dir = live browsing).

### A4 — Dashboard drill-in

A key on a `so-*` row that opens the A2 view dir (or A3 manifest) in a popup / new window.
`fleet-dash` already resolves `is_suborch_name` from `#{window_name}` (1645-1653), so the
id is in hand. Pure UX polish on top of A2; not standalone.

### A5 — nvim for sub-orchs, opt-in, and only after A1+A2

If still wanted after the above: an explicit `--editor` opt-in on the scratch path
(never the default), with **B1 fixed first** — `suborch_live` must stop trusting
`pane_current_command` and instead probe the pane's process tree for the harness (or ping
the `@fleet_nvim_sock` RPC). And the correct cwd for that editor is the **A2 view dir**,
not `$root` — which is another way of saying A2 is a hard prerequisite of the original
request, not an alternative to it.

**Ranking: A1 > A2 > A3 > A4 >> A5.**

---

## 5. Recommendation

**Reject the proposal as stated.** Its own success condition ("the folder where all its
created files are visible") names a directory that does not exist, and building that
directory (A1+A2) satisfies the underlying need without touching the spawn path. The nvim
variant additionally re-arms the `MAX_IMSGSIZE` failure (B5), replaces synchronous seed
delivery with a 3-second timing guess in an unwatched detached pane (B2), and — via the
pre-existing `nvim` entry in `is_harness_cmd` (B1) — removes the dispatch layer's only
automatic recovery path for a dead sub-orch. Do A1 and A2. Revisit A5 only afterwards, as
an opt-in, with B1 fixed.

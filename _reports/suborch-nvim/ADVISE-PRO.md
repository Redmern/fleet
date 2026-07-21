# ADVISE-PRO — the case FOR giving the sub-orchestrator an nvim split (d25)

Lens: strongest possible case in favour. Citations `bin/fleet:<line>` in
`/home/red/proj/pc-tune/fleet/main` unless marked otherwise.

---

## 1. The real problem this solves

**The sub-orchestrator is the one agent in the fleet whose entire work product is
files, and it is the only agent type with no file view.**

Look at what each role actually produces:

| role | product | how the human inspects it today |
|---|---|---|
| impl worker | a git diff on a branch | `git diff` — and it *already gets nvim* (bin/fleet:1161-1173) |
| test worker | `TEST-a.md`, `TEST-b.md`, `TEST-VERDICT.md` | files — also gets nvim |
| **sub-orch** | `STATUS.md`, `meta.tsv`, `workers.tsv`, and the *curation* of `PLAN.md` / `SYNTHESIS.md` / `debate-*.md` / `TEST-VERDICT.md` | **nothing.** A bare pane in a detached session (bin/fleet:994-998, 1139-1148) |

The allocation is exactly inverted. The agent whose output is most reviewable by
`git` has an editor; the agent whose output is a scattered markdown tree has a
scrollback buffer. When the human surfaces a sub-orch from the dashboard (Enter,
bin/fleet-dash:1806-1820) they land on a wall of transcript with no way to open
the artifact under discussion without leaving the pane.

That is precisely the human's ask, and it is not a cosmetic one. Three concrete
failures it fixes:

1. **Mid-flight inspection.** The pipeline is long (research → debate → gate →
   impl → test → debate → loop). Between gates the human wants to read
   `SYNTHESIS.md` *while* the sub-orch is parked at `gate1-wait`
   (bin/fleet:1945-1954). Today: surface the pane, read a digest the sub-orch
   chose to echo, or drop to a shell elsewhere. With nvim: the file is two
   keystrokes away in the same window, and oil re-lists on focus so new artifacts
   appear as the pipeline writes them.
2. **Gate decisions are made on documents.** A gate message is a *pointer* to
   `_reports/<slug>/SYNTHESIS.md`. Asking the human to approve a gate without an
   editor in the pane is asking them to approve a document they cannot open from
   where the decision is being made.
3. **Post-mortem.** `FLEET_SUBORCH.md:194` makes crash recovery depend on reading
   `_reports/<slug>/SYNTHESIS.md` and `TEST-VERDICT.md` **relative to the
   sub-orch's cwd**. When that cross-check goes wrong (EXPLORE-C §4 shows it
   silently can), the human debugging it needs to see the tree from exactly the
   sub-orch's vantage point. An nvim rooted at the sub-orch's cwd *is* that
   vantage point, rendered.

There is also a cheap structural win: the nvim path carries `--listen "$nsock"`
and stamps `@fleet_nvim_sock` (bin/fleet:1164, 1173), which is the sole
discriminator fleet uses to prefer **headless nvim RPC** over focus-dependent
`send-keys` (bin/fleet:1385-1386). `fleet send` into a sub-orch — the wake path
that `cmd_watch`'s escalation machinery exists to make reliable — becomes an RPC
call instead of a keystroke injection into a pane that may not have focus. The
sub-orch is the *most* send-into'd agent in the system. Upgrading its delivery
channel is a durability win that falls out of this change for free.

---

## 2. Why `$root` is the right nvim root, despite the artifact scatter

EXPLORE-C §4 concludes "no single directory shows a dispatch's whole output."
True — and it does not damage this case. Three reasons.

### 2.1 The objection assumes a static view; oil is a navigator

The counter-argument is really "the nvim root won't be a dispatch-scoped
dashboard." Correct, and irrelevant. `nvim .` at `$root` yields an **oil.nvim
directory buffer** (EXPLORE-C §5; netrw is dead per
`/home/red/.config/nvim/lua/config/options.lua:46-49`, mini.files explicitly
prevented from hijacking per `/home/red/.config/nvim/lua/plugins/mini.lua:17`).
Oil is a *browser*, not a report. A browser is exactly the correct tool for a
scattered tree — the scatter is an argument FOR a file navigator, not against
one. From `$root`, all five artifact sets are reachable as siblings:

```
/home/red/proj/pc-tune/          <- the nvim root
├── .fleet/dispatch/<id>/        <- (L) ledger: instruction, meta.tsv, STATUS.md
├── .fleet/notes/scratch/<agent> <- (Ds) per-agent scratch docs
├── _reports/<slug>/             <- (Rr) research artifacts
└── fleet/<branchdir>/           <- (Rw)+(Dw)+(C) impl worktree: reports, notes, code
```

That is one keystroke into any of four subtrees. The alternative on offer today
is zero.

### 2.2 `$root` is the sub-orch's own coordinate system — the nvim root must match it

This is the load-bearing point and it is not negotiable-away. The sub-orch's
manual addresses everything relatively: `.fleet/dispatch/<id>/instruction.txt`,
`_reports/<slug>/SYNTHESIS.md`. That works because `cmd_new --scratch` sets
`dir="$root"` (bin/fleet:999) and tmux launches with `-c "$dir"` (1140/1143/1146).

Any nvim root **other than `$root`** would create a split-brain: the human
browsing tree A while the agent writes to tree B, with relative paths in the
transcript that don't resolve to what is on screen. Rooting at `$root` makes the
editor's view and the agent's path vocabulary **the same namespace** — every
relative path the sub-orch prints in its transcript is directly openable in the
pane beside it. That property is worth more than a tidier but non-matching root.

And it is preserved for free: the user's claudecode config pins the harness
process cwd to nvim's cwd (`/home/red/.config/nvim/lua/plugins/claudecode.lua:5-8`,
`cwd_provider = function(ctx) return ctx.cwd end`), and nvim's cwd comes from
tmux `-c "$dir"` = `$root`. So the sub-orch's cwd is **unchanged** by this
proposal — the constraint the task statement flags as inviolable is satisfied by
construction, not by care.

### 2.3 A dispatch-scoped view is a *separate*, later idea

If someone later wants `.fleet/dispatch/<id>/` to gain symlinks into
`_reports/<slug>/` and the impl worktree, that is a strictly additive change that
makes the *same* oil root better. Nothing here forecloses it. Rejecting the nvim
split because the root isn't yet dispatch-scoped is refusing the window because
the view could be nicer.

---

## 3. Every named risk is cheap to contain — and one of them is already void

### 3.1 The multi-pane fears are void: nvim's split is not a tmux pane

EXPLORE-B lists five cross-cutting risks; **three of them dissolve on inspection.**
`cmd_new` contains **no `split-window`** (EXPLORE-A §1.5d). The "editor + agent
split" is produced *inside nvim* — `claudecode.terminal.open` (nvim/fleet.lua:33)
or `botright vsplit` + `:terminal` (nvim/fleet.lua:45-46). Those are **nvim
windows, not tmux panes.** An nvim-layout fleet window therefore has exactly
**one** tmux pane, the same as a bare one. Consequently:

- `suborch_live`'s `list-panes … | head -1` (bin/fleet:1607) — still exact.
- `cmd_new`'s `_wpane` owner/role stamp `head -1` (bin/fleet:1203) — still exact.
- `suborch_pane_for`'s first-match return (bin/fleet:1285-1296) — still exact;
  a gate-pop `send-keys` cannot "land in the editor pane" because there is no
  editor pane.
- fleet-dash's per-pane rows and `HIDDEN_N` (bin/fleet-dash:416) — no
  double-listing, no skew.

That is EXPLORE-B risks 2, 3 and 5 gone at zero cost. Verifiable in one command
against any existing nvim worker window: `tmux list-panes -t <win> | wc -l` → 1.

### 3.2 `suborch_live` false-alive — bounded, and *strictly better* than today

`is_harness_cmd` already allowlists `nvim` (bin/fleet:1593), present since the
original dispatch commit. So there is **no false-dead risk at all**: an
nvim-topped sub-orch can never be mistaken for gone and respawned.

The residual is the inverse: a sub-orch whose claude died but whose nvim survives
reads as live forever. Two reasons this is a small price:

**(a) It trades a silent, destructive failure for a loud, visible one.** Today's
bare sub-orch, when its claude dies, drops to a shell → `is_harness_cmd` returns
false → `cmd_reconcile` (bin/fleet:1988, which treats `gate1-wait` as
non-terminal) **respawns it**. That is the documented "parked sub-orch revival"
bug in the project's own memory index — a *live, unfixed* footgun where one new
dispatch resurrects an old parked sub-orch. An nvim-hosted sub-orch is
**structurally immune** to that resurrection, because the window never reads
dead. The failure mode we would be adopting — a stalled, *visible*, *surfaced-able*
nvim window the human can see in the dashboard and re-drive with `fleet send`
(over RPC, §1) — is categorically less bad than a wrong automatic respawn.

**(b) If we want it tighter, it is ~4 lines.** `@fleet_nvim_sock` already
distinguishes nvim windows (bin/fleet:1385-1386). A liveness probe can, for those
windows only, additionally ask nvim over the socket whether the
`FLEET_TERM_MATCH` terminal job is alive — the same channel `FleetSend` already
uses (nvim/fleet.lua:10-14, 82-96). That is an optional hardening, not a
prerequisite.

Note also the allowlist already accepts `node` and `*claude*` (bin/fleet:1593), so
a stray foreground `node` already reads as "harness alive". The false-alive
surface is pre-existing; this change widens it marginally, it does not open it.

### 3.3 Dashboard move-in / move-out — zero change required

fleet-dash is **window-granular throughout** (EXPLORE-B §6): `field "$sel" 3` is a
`window_id`; Enter does `move-window -s "$win" -t "$SESS:"` (bin/fleet-dash:1816),
`h` delegates to `fleet hide` (bin/fleet-dash:1833 → bin/fleet:3508). A window
moves as a unit regardless of its contents. Combined with §3.1 (one tmux pane
anyway), the dashboard needs **no modification whatsoever**. The same holds for
`cmd_hide`/`cmd_unhide` (bin/fleet:3508-3552) and `--switch` (bin/fleet:1228-1234).

### 3.4 `reap` — not in the blast radius at all

EXPLORE-B §5 establishes that `cmd_reap` **never touches sub-orch panes**: scratch
agents are not persisted (`[ "$scratch" = 1 ] || persist_agent`, bin/fleet:1236),
so a `so-<id>` window never appears in the agents file reap iterates; and even if
it did, the sub-orch cwd is `$root`, which the not-a-linked-worktree guard
(bin/fleet:3132) skips. `safe_kill_window` (bin/fleet:186-202) is the one function
that already iterates **all** panes correctly. Nothing to contain.

### 3.5 Seed size / MAX_IMSGSIZE — >15KB of headroom remains

The cap is 16384 bytes **total per tmux command** (measured, `_reports/dispatch-seed-fix/PROOF-DESIGN.md:33-40`).
The nvim path spends more of that budget than bare: five extra `-e` pairs plus the
nvim argv and `--listen` socket path — call it ~350 bytes with a long socket path.
The sub-orch seed is the **compact ~200-byte pointer** (bin/fleet:1662-1667), not
the 20318-byte manual that caused the original failure. Total nvim-path command
for a sub-orch is well under 1KB against a 16384 cap. And the failure is no longer
silent: the loud empty-`win_id` guard (bin/fleet:1183-1189) prints to stderr and
returns 1. This risk was real for the *old* inlined seed; against the pointer seed
it is not a risk, it is rounding error.

---

## 4. Minimal viable change (file:line anchored)

The change is genuinely small because `--scratch` and `--bare` are conflated at a
**single line**, and the post-spawn tail is already path-agnostic.

### Variant A — smallest possible cut (~8 lines, no restructure) — RECOMMENDED FIRST

1. **bin/fleet:963** — add `nvim_opt=0` to the locals.
2. **bin/fleet:967-968** — add an opt-in flag beside `--bare`:
   ```
   --nvim) nvim_opt=1; shift ;;
   ```
3. **bin/fleet:998** — the one load-bearing line. Change
   ```
   bare=1
   ```
   to
   ```
   [ "$nvim_opt" = 1 ] || bare=1     # --scratch is bare UNLESS an editor was asked for
   ```
   and reword the comment at 995-997 (it currently asserts "nothing to edit in
   nvim", which is exactly the claim d25 overturns).
4. **bin/fleet:1116** — the scratch/hidden spawn branch currently lives inside
   `if [ "$bare" = 1 ]`. With `bare=0` a scratch spawn would fall to the visible
   nvim branch at 1161 and **lose its hidden-session parking**. Fix by making the
   scratch test the outer one. Smallest form: inside the scratch block
   (1116-1156), when `nvim_opt=1`, extend `_eargs` (1129) with the five nvim `-e`
   pairs from 1167-1171 and replace `"${argv[@]}"` in all four spawn primitives
   (1140-1148) with the nvim argv from 1172. Then set `@fleet_nvim_sock` after
   the spawn (mirroring 1173) guarded on `$nvim_opt`.
5. **bin/fleet:1663** — flip the sub-orch spawn to use it:
   ```
   cmd_new --scratch --nvim "$wname" -p "…"
   ```

Nothing else changes. Specifically **unchanged**: `dir="$root"` (999), the
`@fleet_owner` / `record_pane_role` tail (1202-1209, already path-agnostic per
EXPLORE-A §6.2), `@fleet_hidden 1` (1222), the non-persist rule (1236), all of
fleet-dash, all of reap.

Step 5 is the entire behavioural commitment, and it is **one word**. Ship steps
1-4 first, exercise `fleet new --scratch --nvim probe` by hand, and only then add
`--nvim` at 1663. If anything misbehaves, deleting one word at 1663 reverts the
system to today's behaviour with the mechanism left in place.

### Variant B — the clean version (~25 lines, do this second)

Hoist argv construction above the fork so **argv choice (harness vs nvim)** and
**target choice (hidden vs visible session)** become orthogonal:

- Build `_eargs` and `spawn_argv` once, before bin/fleet:1101.
- Replace the `if [ "$bare" = 1 ]` fork at 1101 with `if [ "$scratch" = 1 ]`
  selecting only the *target*, using the four TOCTOU-tolerant primitives at
  1139-1148 unchanged, versus the single `new-window -t "$sess"` at 1158.
- Set `@fleet_nvim_sock` once in the post-spawn tail.

This also fixes a latent asymmetry worth naming: a **non-scratch `--bare`** worker
is spawned with **no `2>/dev/null`** (1158) while scratch spawns suppress stderr
(1141/1143/1146/1148) — the exact suppression that hid "command too long" for
months. Unifying the spawn call is a small hygiene dividend.

### Rollout knob

Keep `--nvim` opt-in on `cmd_new` permanently (a user may want a scratch agent
with or without an editor), and make the *sub-orch default* the only policy
question. That gives a per-spawn escape hatch and a one-token global revert.

---

## 5. The single weakest point of my own case

**Prompt seeding on the nvim path is timing-dependent, and for a sub-orch a
dropped seed fails silently and permanently.**

On the bare path the seed is delivered synchronously as an argv element of the
harness process (bin/fleet:1108-1111) — it either runs or the spawn visibly
fails. On the nvim path it is `VimEnter` → `defer_fn(300ms)` → `terminal.open` →
`defer_fn(3000ms)` → `FleetSend(prompt)` → a `chan_send` plus a separate `\r`
80ms later (nvim/fleet.lua:20-38, 82-96). The code's own comment concedes that
passing the prompt as a CLI arg through `terminal.open` "proved unreliable" — this
is the fallback for a path that already failed once. It is a fixed 3-second bet
that claudecode's terminal has booted and is accepting input.

For a worker, losing that bet is a nuisance: the human sees an idle agent and
re-sends. For a **sub-orch** it compounds badly with §3.2: the pane runs nvim, so
`is_harness_cmd` (bin/fleet:1593) reports it **live**, `cmd_reconcile` never
re-animates it, the ledger sits at `planning` (set at bin/fleet:1785), and the
dispatch stalls with no alert. A seedless sub-orch is indistinguishable from a
thinking one. That is the one place where my "false-alive is strictly better than
false-dead" argument (§3.2a) turns against me — it is better only when the
sub-orch actually received its instruction.

I do not think argument disposes of this; it needs a mechanism. The honest
mitigation is a **delivery receipt**: after spawning a sub-orch, confirm the
ledger leaves its initial state (or that the pane reports `working` to fleetd)
within a bounded window, and escalate loudly if it does not — reusing the
confirm-and-escalate pattern `cmd_watch` already implements for sub-orch wakes.
Any adviser arguing against this proposal should attack here, and any plan that
adopts it should carry that check as a hard requirement rather than a nice-to-have.

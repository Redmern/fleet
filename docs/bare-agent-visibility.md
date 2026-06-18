# Bare agent not shown in the dashboard — root cause

## Symptom

A **bare** Claude agent (`fleet new --bare`) was spawned in the `techweb20`
session (repo under `~/work`, cwd `~/work/rib/repos/techweb2.0`). It ran fine and
produced output, but the dashboard pane showed `0 agents · no agents yet`. The
agent should have appeared.

## How the list is built (the relevant path)

1. Dashboard and `fleet ls` both read the agent list from `agents_tsv`
   (`bin/fleet:131`).
2. `agents_tsv` has two paths:
   - **daemon up** (`bin/fleet:133`): it uses **only** what `fleetd` returns from
     `fleet.list`. The tmux window-option scan is *not* consulted.
   - **daemon down** (`bin/fleet:157`): it falls back to a tmux scan that keys on
     `@agent_state` — a value set by *fleetd*, never by `fleet new`.
3. `fleetd.list_agents` (`bin/fleetd:224`) builds its result by iterating
   **`self.panes`** — i.e. only panes that have *reported state at least once*
   (via a Claude hook, or via the scrape path for hookless harnesses). It then
   joins those panes against `tmux list-panes` for window metadata.

The state for a pane only enters `self.panes` when `fleet-hook` delivers an
`agent.report` to the daemon (`bin/fleetd:55`, fed by `bin/fleet-hook`).

`cmd_new` stamps `@fleet_harness` + `@fleet_state_src` on the window for **both**
bare and non-bare (`bin/fleet:516`), but **nothing reads `@fleet_harness` for the
listing.** It is only used by the *scrape* path, and only for `src=scrape`
(hookless) harnesses (`bin/fleetd:192`). A `src=hook` harness whose hook never
reaches the daemon is therefore in **no** list and **no** fallback.

## Root cause (the durable bug — confirmed)

**An agent only appears once a hook report has reached `fleetd`. A window that is
fully stamped by `fleet new` but whose hook never fired (or never reached the
daemon) is invisible while the daemon is up — there is no fallback that surfaces
a stamped `@fleet_harness` window on its own.**

Reproduced cleanly in the current container (`pc-tune/fleet/main`), daemon up:

```
$ wid=$(tmux new-window -d -P -F '#{window_id}' -n REPRO-bare -c "$PWD" 'sleep 600')
$ tmux set -w -t "$wid" @fleet_harness claude
$ tmux set -w -t "$wid" @fleet_state_src hook
$ fleet ls | grep -i repro || echo NOT SHOWN
NOT SHOWN            # stamped harness window, no hook report -> invisible
```

This is *exactly* the failure mode: a spawned agent that fleetd never heard a
hook from is dropped on the floor by both the daemon list and the
daemon-down fallback.

### Why the hook didn't reach fleetd in the techweb20 incident

The stamp-but-no-report condition is reached whenever the hook path is broken for
that launch. At the time of the incident the most likely trigger was
**environmental, not bare-specific**:

- The `techweb20` session was running its dashboard from a now-**deleted** clone
  (`/home/red/proj/fleet`). When that clone was the install source,
  `~/.local/bin/fleet-hook` was a symlink into it; once deleted it dangles and
  every `bash '<dangling>' working` hook silently fails (`exit 127`) — so *no*
  agent in that session reports, and the dashboard shows `0 agents`. (The
  symlinks now point at the live `pc-tune/fleet/main` clone, so this specific
  trigger is already gone.)
- Any other launch where the hook can't reach the daemon (wrong
  `CLAUDE_CONFIG_DIR` without the hook wired, daemon socket absent at launch,
  hook timeout) produces the same invisible-agent outcome.

The point is the **fragility**, not the one trigger: the listing has *no net*
for a hook-harness window. The robust fix removes that fragility regardless of
which trigger fires.

## Hypotheses evaluated

### H1 — work profile uses an unwired `CLAUDE_CONFIG_DIR` (PARTIAL / not the current cause)

`claude-profile` (`~/.local/bin/claude-profile`) selects the config dir purely by
cwd:

```
under $HOME/work/  -> $HOME/.claude            (work / Trivium account)
elsewhere          -> $HOME/.claude_personal   (personal account)
```

`install.sh` wires the hook into exactly those two dirs (`PROFILES`,
`install.sh:9`). Both currently contain the fleet hook:

```
$ grep -c fleet-hook ~/.claude/settings.json ~/.claude_personal/settings.json
7
7
```

So the two dirs `claude-profile` can pick are **both** wired today, and H1 does
**not** explain the *current* state. It remains a latent risk: the profile list
in `install.sh` is hand-maintained and duplicated from `claude-profile`; if
`claude-profile` ever adds a third config dir, install would silently miss it.
Worth hardening (see plan §A), but it is not the durable root cause.

### H2 — bare panes report a pane id fleetd can't map (REJECTED)

No bare-vs-nvim pane-id mismatch exists. `fleet-hook` reports `pane_id =
$TMUX_PANE`, and `fleetd.list_agents` joins that against `tmux list-panes`:

- **bare**: claude runs *as* the tmux pane process; `$TMUX_PANE` is that pane id.
- **non-bare**: claude runs in a `:terminal` *inside* nvim, but that terminal job
  **inherits** `$TMUX_PANE` from the nvim pane — the same id tmux lists.

Both report the same pane id tmux knows. The reproduction confirms the failure is
about *whether a report arrives at all*, not about the pane id when it does. Bare
was incidental to the symptom — it was simply the agent the user spawned.

## Conclusion

The durable root cause is **H-arch**: the agent list is gated entirely on a hook
report having reached `fleetd`, with no fallback that surfaces a stamped
`@fleet_harness` window. Any agent whose first hook is lost — for any reason —
never appears. H1 is a latent secondary risk; H2 is rejected. The fix must make a
stamped window visible independent of hook delivery (plan §C), with §A as cheap
hardening.

---

# Implementation plan

Three candidate fixes; recommendation below.

## §C (PRIMARY, recommended) — fleetd surfaces stamped windows without a hook

Make `fleetd.list_agents` (`bin/fleetd:224`) include any window stamped
`@fleet_harness` that has no live state in `self.panes`, with a synthetic
placeholder state. Both consumers (`fleet ls`, dashboard) go through `fleet.list`,
so one change covers both.

- Extend the single `list-panes` format already fetched in `list_agents` to also
  emit `@fleet_harness` and `#{window_activity}` — no extra tmux round-trips.
- First pass: build agents from `self.panes` as today; record covered
  `window_id`s.
- Second pass: for panes whose window has `@fleet_harness` set and whose
  `window_id` is **not** already covered, add **one** synthetic entry per window
  (dedup by `window_id`, so a multi-pane window is added once), state =
  `"starting"`, `since` = `window_activity` (fallback: now).
- `"starting"` needs no `SEVERITY`/`GLYPH` entry: synthetic rows never go through
  `report()`/tmux mirroring. Both consumers already render unknown states safely —
  dashboard `state_pcol` → grey pill, sorts last (`bin/fleet-dash:184,207`);
  `cmd_ls` prints raw and sorts by state.

Result: a spawned agent appears **immediately** (before its first hook) and stays
visible even if its hooks never reach the daemon. Once a real report arrives, the
pane is in `self.panes`, its window is "covered", and the synthetic row is
replaced by the real working/idle/blocked state. Self-healing.

Tradeoffs: a permanently hook-broken agent shows `starting` forever — misleading,
but **visible**, which is strictly better than invisible and is a loud signal that
something is wrong. Scope is intentionally cross-session (matches existing
`list-panes -a` behavior).

## §A (SUPERSEDED → replaced by a `fleet doctor` check; see Adviser review) — keep install profile list from drifting

`install.sh` hand-duplicates `claude-profile`'s config-dir list. Harden so they
can't drift: derive extra dirs by grepping `claude-profile` for
`$HOME/.claude*` cfg assignments, union with the existing `PROFILES`, dedup, wire
each that exists. Idempotent, fail-silent (skip if `claude-profile` absent).
Does not fix the current symptom (both dirs already wired) but closes H1 as a
future regression.

## §B (rejected) — bare-pane reporting fix

No change: H2 is rejected, there is no bare-specific pane-id bug.

## Why not "fix it in agents_tsv instead"

A bash-side merge in `agents_tsv` would only patch `fleet ls`/dashboard while the
daemon is up, duplicate the dedup logic, and add a second tmux scan. fleetd is the
single source of truth for `fleet.list`; fixing it there is one change, DRY, and
covers every consumer. The daemon-down branch of `agents_tsv` already has a tmux
fallback; §C complements it for the daemon-up case.

## Verification plan

- `bash -n bin/fleet install.sh`, `python3 -c 'import ast; ...'` compile checks.
- Repro before/after: stamp a window `@fleet_harness=claude` with no hook →
  `fleet ls` must now show it as `starting`; once a real agent reports, the row
  flips to its live state and is not duplicated.
- Confirm existing real agents still show exactly once (no dup rows).

---

# Adviser review — critiques and how they were addressed

A skeptical reviewer critiqued the plan before implementation. Changes made:

- **BLOCKER B1 — synthetic row needs a real pane_id.** The dashboard drops rows
  with an empty pane (`bin/fleet-dash:202`), and `fleet send`/mode key off the
  pane id. *Fix:* each synthetic row is keyed to a concrete agent pane — the
  window's **active pane** (`pane_active==1`), falling back to the first stamped
  pane. Verified non-empty in the test.
- **BLOCKER B2 — orchestrator lists itself.** The `main` window is stamped
  `@fleet_harness=claude` too, so it would appear as a phantom `starting` agent in
  `fleet ls`. *Fix:* the synthetic pass skips `window_name == "main"` (in fleetd,
  so `fleet ls` is clean too, not just the dashboard).
- **SHOULD-FIX S3 — "starting" forever is a weak signal.** *Fix:* the state ages —
  `starting` while `window_activity` is within `SYNTH_STALE_AFTER` (45s), then
  `stale` (a loud "no hook ever arrived" signal). Both render as a grey pill and
  sort last; no `SEVERITY`/`GLYPH` entry needed (synthetic rows never mirror to
  tmux).
- **SHOULD-FIX S2 — mode popup pokes a not-ready pane.** *Fix:* the dashboard `m`
  handler now no-ops on `starting`/`stale` rows with a status message instead of
  sending Shift+Tab into a pane whose harness may not be ready.
- **§A dropped in favor of the real trigger.** The reviewer flagged grepping
  `claude-profile` for config dirs as fragile over-engineering that doesn't fix
  the incident (both dirs are already wired). *Replaced with* a `fleet doctor`
  check that `fleet-hook` resolves to an existing executable — directly catching
  the **dangling-symlink-from-a-deleted-clone** condition that was the incident's
  actual trigger (a dangling hook makes every Claude hook exit non-zero, so no
  agent reports and the dashboard shows 0).

Documented follow-ups (not implemented, low risk):

- **S1** — `fleet watch` treats only `idle` as done, so watching an agent stuck
  `starting`/`stale` would spin to the loop cap. Pre-existing (such an agent was
  previously invisible, also never idle); noted so a future change can treat a
  long-`stale` target as a soft error.
- **S4** — `fleet ls` is global (all sessions), so it now lists stamped-unreported
  windows from every project session. This matches `fleet ls`'s existing
  cross-session behavior (the dashboard remains session-scoped); kept intentional.

## How the fix was verified

Throwaway `fleetd` on a temp socket (live daemon untouched):
1. A window stamped `@fleet_harness=claude` with no hook → appears as `starting`
   with a non-empty pane id. ✅
2. A second window named `main`, stamped → **excluded**. ✅
3. Sending a real `agent.report` for the stamped window's pane → the row flips to
   `working`, and there is exactly **one** row (no synthetic + real duplicate). ✅

`bash -n` (fleet, fleet-dash, install.sh) and `python3 ast.parse` (fleetd) all
pass.

> Deploy note: the running daemon must be restarted to pick up the new `fleetd`
> (`systemctl --user restart fleetd`, or re-run `install.sh`). Not done here to
> avoid disrupting other live sessions.

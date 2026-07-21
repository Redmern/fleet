# Debate — ALTERNATIVES adviser

Bug recap: `resolve_or_spawn_suborch` (`bin/fleet:1373-1376`) seeds the sub-orch
with the **entire ~20 KB** `FLEET_SUBORCH.md` (`suborch_seed`, `bin/fleet:1318`)
as a positional claude argv element. `cmd_new`'s bare/scratch path packs that into
a single `tmux new-window`/`new-session` command (`bin/fleet:917-925`), which
exceeds tmux's imsg `MAX_IMSGSIZE`=16384 total-command cap → `command too long`,
rc=1, swallowed by `2>/dev/null` → empty `win_id` → "spawned … in window " (blank,
`bin/fleet:986`) → no pane → reconcile respawn churn (`bin/fleet:1631-1632`).

Recommended (pointer) fix: replace the inlined seed with a ~200 B prompt naming
`$FLEET_DIR/FLEET_SUBORCH.md` + the dispatch id; the sub-orch reads the manual and
`.fleet/dispatch/<id>/instruction.txt` itself.

The constant I judge every option against: **does the 20 KB get OUT of the single
tmux spawn command?** The cap is on that one command; any fix that keeps the seed
inside `new-window … "${argv[@]}"` (`bin/fleet:918`) does not solve the bug.

---

## Alt 1 — temp file + `FLEET_PROMPT_FILE` env, pane cats it into a first prompt

- **Reliability:** would arrive — but there is **no consumer**. The only thing
  that reads `FLEET_PROMPT` is the **nvim** plugin (`nvim/fleet.lua:20`,
  `FleetSend`), and sub-orchs are **bare** panes (`scratch=1 → bare=1`,
  `bin/fleet:778`) that launch claude **directly** (`argv=("$hbin" …)`,
  `bin/fleet:881-888`). No nvim, no `FleetSend`, nothing reads an env-named file.
- **Complexity:** to make a bare claude read a file you must wrap the harness
  launch in the bare/scratch path (`bin/fleet:881-925`) with a shell that does
  `claude "$(cat "$FLEET_PROMPT_FILE")"` — which **re-inflates the argv** at exec
  time and *re-hits the same cap is avoided only because it's now the pane's own
  shell, not the tmux command*. So it can work, but it means a new launcher
  shim + a new env contract across **all** bare spawns, not just the sub-orch.
- **Backward-compat:** touches the shared bare path → risk to every scratch/worker
  spawn. The pointer fix touches one call site.
- **Verdict:** **loses.** It is strictly more machinery to deliver the *same bytes*
  the pointer avoids needing at all. Note: telling claude to read a path *is* the
  pointer fix — Alt 1 only differs by materialising a temp file no one needs.

## Alt 2 — pipe the seed to claude via stdin instead of argv

- **Does claude read a prompt from stdin?** Only in `--print`/non-interactive mode
  (`claude --help`: stdin/`--input-format` are gated "only works with --print").
  Sub-orchs are **interactive** panes (no `-p`/`--print`; `H_PROMPT_FLAG=""`,
  positional, `harness.d/claude.conf:6`). Interactive claude does **not** consume
  an initial prompt from stdin.
- **Mechanics:** even if it did, tmux `new-window` has no stdin-pipe primitive; you
  would spawn `sh -c 'claude < seedfile'`, which again is a launcher shim (cf. Alt
  1) and would put interactive claude into a non-TTY stdin — breaking the REPL.
- **Verdict:** **loses / not viable.** Wrong mode; would break interactivity.

## Alt 3 — minimal spawn, then deliver the full seed post-spawn (send-keys / inbox)

- **Reliability of arrival:** This is the only alt that delivers the *full 20 KB*
  and the fleet codebase **already has the primitive**: inbox pop uses
  `tmux set-buffer` + `paste-buffer` (`bin/fleet:2185-2197`) precisely to push
  large text into a bare pane without an argv. `fleet send`/`cmd_send` also
  send-keys into a bare pane (`bin/fleet:1167`).
- **But:** a post-spawn paste is **racy** — claude must be booted and at its prompt
  before the paste lands; the existing inbox paste papers over this with a deferred
  Enter (`bin/fleet:2190-2197`) and still notes the race. Seeding the agent's
  *first* instruction this way means an extra step that can no-op silently if claude
  isn't ready — re-introducing a fail-silent gap of the same flavour as the bug.
- **Complexity / house style:** two-phase spawn (create blank pane, then inject)
  adds an ordering dependency and a second failure surface. Against fleet's
  fail-silent style this is *worse* — the blank-pane phase succeeds, the inject can
  silently miss, and you are back to a sub-orch with no instructions.
- **Verdict:** **loses to the pointer, but is the best fallback** if the seed ever
  *must* be delivered verbatim (e.g. content not available on disk to the pane).
  Could **complement** the pointer as a belt-and-suspenders re-send, but adds race
  surface for zero benefit when the manual is already on disk at `$FLEET_DIR`.

## Alt 4 — `tmux set-buffer` + `paste-buffer` to load the big text

- This is the **mechanism** behind Alt 3, not an independent option: `set-buffer`
  loads text into a tmux paste buffer (server-side, **not** subject to the imsg
  command-length cap the same way an argv is — it's a different call), then
  `paste-buffer -t <pane>` injects it. Already proven in-tree at
  `bin/fleet:2185-2186`.
- **Reliability:** the buffer load avoids the cap, but you still need a live pane to
  paste *into* and the agent ready to receive — i.e. it inherits Alt 3's two-phase
  race. It does **not** let you seed at `new-window` time (paste targets an existing
  pane).
- **Verdict:** **loses as a standalone fix** (can't seed at spawn), **viable as the
  transport for Alt 3** if post-spawn injection is ever chosen.

## Alt 5 — general guard in `cmd_new`: detect oversize, auto file-fallback/chunk

- **Idea:** at `bin/fleet:885-888`, if `$prompt` length approaches the cap, write it
  to a temp file and substitute a short "read this file" prompt automatically
  (auto-pointer), or chunk it.
- **Reliability:** the **auto file-fallback** variant is sound and reliable — it is
  the pointer fix generalised, and would also protect *any* future oversize
  `--scratch -p` caller. **Chunking** is not viable (you cannot chunk a single argv
  into one command; you'd need post-spawn paste = Alt 3/4).
- **Complexity / scope:** larger blast radius (every bare/scratch spawn) and it must
  invent the same "agent, go read this file" prompt the pointer writes by hand —
  but generically, for arbitrary callers, so it can't tailor the wording to "read
  the sub-orch manual + instruction.txt". The result is a *less specific* pointer
  applied indiscriminately.
- **Backward-compat / house style:** a silent auto-rewrite of the user's prompt is
  the kind of magic that bites later (a caller passing a genuinely-large literal
  prompt suddenly gets it replaced by a file path). Better as **defence-in-depth**,
  not the primary fix.
- **Verdict:** **complements** the pointer. The right slice of Alt 5 is the PLAN's
  already-listed secondary hardening: make `cmd_new` **not claim success on an empty
  `win_id`** (`bin/fleet:986`) — print a real failure + return non-zero so reconcile
  sees it. That converts any *future* over-cap from silent-blank to visible, without
  silently rewriting prompts. Adopt that; skip auto-chunk/auto-rewrite.

---

## Decision

| Option | Seed arrives? | Avoids cap | Blast radius | Race-free | Fits fail-silent |
|---|---|---|---|---|---|
| Pointer (recommended) | yes (agent reads disk) | yes | 1 call site | yes | yes |
| 1 FLEET_PROMPT_FILE | yes, via shim | yes | all bare spawns | yes | weaker |
| 2 stdin | no (interactive) | n/a | — | — | breaks REPL |
| 3 post-spawn inject | yes (full text) | yes | new 2-phase | **no** | weaker |
| 4 set-buffer/paste | only post-spawn | yes | (= Alt 3) | **no** | weaker |
| 5 cmd_new guard | yes (auto-pointer) | yes | all spawns | yes | magic-prompt risk |

**No alternative beats the pointer fix.** Alts 1/2 solve a path the bug doesn't
live on (nvim/`--print`); Alts 3/4 deliver the full bytes but re-introduce a
silent two-phase race for content that is already on disk at `$FLEET_DIR`; Alt 5's
auto-rewrite is magic with a wide blast radius. The pointer keeps the spawn command
tiny, is robust to any future manual growth, touches one call site
(`bin/fleet:1375-1376`), and is already proven by the manual so-d11 recovery and
the PROOF-DESIGN A4 short-pointer spawn.

**Adopt:** the pointer fix as primary, **plus** the narrow slice of Alt 5 —
`cmd_new` must fail loudly on empty `win_id` (`bin/fleet:986`) and return non-zero
— as defence-in-depth. Reject Alts 1, 2, 3, 4 and Alt 5's auto-rewrite/chunk.

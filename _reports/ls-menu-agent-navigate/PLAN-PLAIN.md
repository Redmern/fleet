# Plan in plain English — making the `fleet ls` popup clickable

## What you'll get

Today, opening the leader menu and pressing `l` shows a popup listing this
project's agents — but it's read-only: you look, press a key, it closes. After
this change that popup becomes a **picker**: arrow/type to filter, press **Enter**
to jump straight to that agent's tmux window. Esc cancels and changes nothing.

It keeps everything that makes `ls` useful (this-project scope, the full
STATE / AGENT / WINDOW / IN-STATE columns, the done/ready markers) and just adds
"select one and go there" — the same jump that leader `a` (pick) already does.

## How it's built

We're **not inventing anything**. Fleet already has a popup that lists things in a
fit-to-size box, runs an fzf picker, and jumps you to your choice — that's the
`sessions` action (`o`). We point `ls` at the same machinery: two new internal
modes on `fleet ls` (`--pick` = the interactive picker, `--measure` = silently
size the box), and a two-word edit to the line that opens the leader `ls` popup.
The jump itself is the exact two lines pick already uses (`switch-client` +
`select-window`).

**One file changes: `bin/fleet`.** Plus a couple of doc lines. No daemon, hook,
dashboard, or editor changes.

## The safety promise

Plain `fleet ls`, piped `fleet ls | …`, the internal sizing call, and
`fleet ls --hold` must behave **exactly as today** — never pop an fzf picker,
never hang. We guarantee this two ways: the picker only runs behind the new
`--pick` flag (those callers never pass it) **and** only when attached to a real
terminal. Anything non-interactive falls back to today's plain printout.

## What the debate changed

- **Add, don't refactor.** Leave the existing print code byte-for-byte; write a
  small separate builder for the picker. (Protects the safety promise.)
- **Single clean border** (`--border=none`) so the picker box doesn't draw a
  border inside the popup's border and clip a column.
- **Sizing matches what you see** — the measure mode is the picker minus the fzf
  launch, so the box is never sized for hidden/different rows.
- **Four cases handled explicitly:** terminal+agents → pick; terminal+empty →
  show "no agents" and wait (don't flash); piped/no-terminal → plain print and
  exit (don't hang).
- **Nice touches:** a header row labelling the columns + an `Enter jump · Esc
  cancel` hint; attention-needing agents (blocked) sorted to the top of the
  picker; scratch/`_hidden` agents excluded from the jump list (jumping into them
  is a known trap).
- **Rejected as scope-creep:** preview pane, per-row send/mode actions,
  multi-select (those belong on the dashboard, not the leader popup).

## How we'll PROVE it works (no test runner in fleet — isolated scenarios + `fleet doctor`)

Everything runs in a **throwaway tmux server** (`tmux -L lsnavtest` /
`FLEET_SESSION`), never your live `pc` session.

1. **Nothing else breaks (the hard promise):** capture `fleet ls` output before
   and after — diff must be empty. `fleet ls | cat`, `fleet ls --measure`,
   `fleet ls --hold` each print and behave exactly as today; none launches fzf;
   none hangs.
2. **Picking jumps you there:** register ≥2 fake agents, drive fzf to auto-select
   a known one, assert the client's current window id now equals that agent's.
   Repeat for the other agent (proves it's the selection, not a fixed target),
   and across two sessions (proves switch-client + select-window together).
3. **BLOCKING live check:** bind the *real* `popup-fit ls` to a key in the
   throwaway server, open it with two agents, filter, press Enter — confirm the
   client actually moved and the popup closed. (This is the one thing neither
   existing feature proves end-to-end, so it must pass live.)
4. **Graceful degrade:** empty project shows the message and holds (no flash);
   with `fzf` removed from PATH the picker falls back to the plain print instead
   of erroring.
5. **`*_hidden` excluded** from the picker but still shown in plain `ls`; Esc
   leaves session/window unchanged; `fleet doctor` reports `ok fzf`.

**Success = all of the above green, and your live `pc` session never touched.**

# Plan: make the `fleet ls` leader popup interactive (select + navigate)

**Goal.** Today the leader menu's `ls` action opens a *static* fit-to-content
popup that prints the project's agent table and waits for any key. Make it
**interactive**: let the user pick a listed agent and jump to it
(`tmux switch-client` + `select-window`), exactly as the leader `a`=pick action
already does — without breaking the non-interactive uses of `fleet ls` (plain CLI,
piped, and the `--measure`/`--hold` popup-sizing paths).

All line numbers refer to `bin/fleet` at this worktree
(`/home/red/proj/pc-tune/fleet/main/bin/fleet`, 3683 lines).

---

## 1. What the `ls` leader action runs today (traced end-to-end)

The leader menu is which-key style: open it (`menu`, prefix+F), it prints a grid
and reads one key (`cmd_menu`, `bin/fleet:2869`). On a key it **closes itself
first**, then dispatches the action detached:

```
tmux run-shell -b "sleep 0.12; '$FLEET_DIR/bin/fleet' menu --dispatch '$action'"   # :2883
```

`menu --dispatch <action>` evals `tmux <action_tmux_command>` (`:2870-2874`). For
`ls`:

```
ls)  echo "run-shell -b '$self popup-fit ls'" ;;    # :2730
```

So pressing `l` in the leader runs `fleet popup-fit ls` → `cmd_popup_fit ls`
(`:2853`), which calls the generic sizer:

```
ls)  popup_fit_content "$self ls"  "$self ls --hold"  70% 60% ;;    # :2862
```

`popup_fit_content <measure_cmd> <run_cmd> <fb_w> <fb_h>` (`:2820-2851`):

1. **measure** — runs `fleet ls` (bare, `:2862` arg 1), strips SGR, counts the
   longest visible line (width) and line count (height) (`:2830-2838`).
2. clamps to client size, +4 cols / +2 rows border padding (`:2844-2849`).
3. **run** — opens `tmux display-popup -E -b rounded -w <cols> -h <rows>
   "$run_cmd"` where `run_cmd = fleet ls --hold` (`:2850`). On any measurement
   hiccup it falls back to the proportional `-w 70% -h 60%` frame (`:2840-2842`).

`cmd_ls` itself (`:221-259`):

- parses `--all|-a` (server-wide vs current-project scope) and `--hold` (`:228-235`).
- builds rows from `agents_tsv` (`:237`), scopes to the current session +
  its `<sess>_hidden` sibling unless `--all` (`:243-246`), prints the
  `STATE / AGENT / WINDOW / IN-STATE` table with the done/ready decoration
  (`:248-257`), then — **only with `--hold`** — calls `hold_wait` (`:258`).
- `hold_wait` (`:216-219`) prints "press any key…" and blocks on `read`. It lives
  in `bin/fleet` (bash) on purpose: an inline `read -n1` in the tmux command
  string runs under the user's default shell and a zsh `read -n1` errors instantly
  (the "flash" bug) — see the comment at `:211-215`. **Any interactive key-read we
  add must stay inside `bin/fleet` for the same reason.**

`cmd_ls` is dispatched three ways (all must keep working):

- **CLI**: `ls) shift; cmd_ls "$@"` (`:3623`) — a human running `fleet ls` in a
  shell; output is often piped.
- **measure**: `fleet ls` invoked by `popup_fit_content` to size the popup
  (`:2862` arg 1) — captured, **not a TTY**.
- **run/--hold**: `fleet ls --hold` inside the popup (`:2862` arg 2).

Field order from `agents_tsv` (the print at `:192-194`) — needed below:
`1 state · 2 agent-label · 3 session · 4 window_id · 5 window_name · 6 age-str ·
7 pane_id · 8 age-secs · 9 ready`.

---

## 2. How `cmd_pick` navigates, and how leader `a`=pick is wired

`cmd_pick` (`:263-285`):

```
rows=$(agents_tsv | sort … | awk -F'\t' '
  $3 ~ /_hidden$/{next}                # DROP parked scratch (see below)
  … {printf "%d\t%s\t%s\t%s● …", o, $3, $4, c, … }')   # col1 sortkey, col2 session, col3 window_id, col4+ display
choice=$(echo "$rows" | fzf --ansi --delimiter='\t' --with-nth=3 --no-sort …)   # :278
sess=$(echo "$choice" | cut -f1); win=$(echo "$choice" | cut -f2)               # :281-282  (after cut -f2- at :275, col1=session col2=window_id)
tmux switch-client -t "$sess"  2>/dev/null                                       # :283
tmux select-window -t "$win"   2>/dev/null                                       # :284
```

The **navigation primitive is two lines**: `switch-client -t <session>` then
`select-window -t <window_id>`. Because tmux **window ids (`@N`) are
server-global**, `select-window -t @N` lands on the right window regardless of
which session is current — no session qualifier needed.

`cmd_pick` deliberately **drops `*_hidden` rows** (`:269-270`, comment
`:266-268`): switching a client into the bare `<sess>_hidden` scratch session
teleports it into a session with no `main`/dashboard window — a trap. Scratch
agents are reached from the dashboard instead.

Leader `a`=pick wiring — pick is **not** routed through `popup-fit`; it opens its
own interactive popup directly:

```
pick)  echo "display-popup -E -b rounded -w 80% -h 60% '$self pick'" ;;    # :2709
```

**`cmd_sessions` is the second, even closer precedent** (`:2583-2608`): an fzf
picker that ends in `tmux switch-client -t "$chosen"` (`:2607`), and it is wired
*through the same fit-content sizer as ls*:

```
sessions)  echo "run-shell -b '$self popup-fit sessions'" ;;                       # :2732
sessions)  popup_fit_content "$self sessions --measure" "$self sessions" 70% 60% ;; # :2863
```

with a fzf-free `--measure` dump (display rows + 2 fzf-chrome placeholder lines)
for sizing (`:2591-2596`). So fleet already has a working "**fit-content popup
running interactive fzf that ends in switch-client**" — which is exactly what we
want for ls.

### Design options weighed

- **(a) Point leader `ls` at the pick picker** (`ls) … '$self pick'`). One-line
  change, but it just **duplicates leader `a`** — same server-wide view, same
  columns — and throws away ls's distinct value (current-project scope + the
  richer `STATE/AGENT/WINDOW/IN-STATE` table + done/ready decoration). Rejected:
  redundant, loses the ls view.

- **(b) Keep the static grid, add single-key row selection** (render `1..9/a..`
  hotkeys, raw `read` one key, map to a window, navigate). Preserves the exact
  static aesthetic and needs no fzf, but it **reinvents what fzf gives free**
  (filter, scroll, arrows, mouse, >9 rows, paging), adds the most new code, and
  re-enters the zsh `read` minefield (`:211-215`). More surface, more risk.

- **(c) New interactive ls that keeps the ls view AND navigates** — implement it
  as the **`cmd_sessions` pattern applied to ls**: a `--pick` mode that renders
  the same pretty ls rows as fzf rows (hidden `session` + `window_id` columns),
  Enter → `switch-client` + `select-window` (cmd_pick's two lines verbatim), plus
  a `--measure` mode for the sizer. **Recommended.** Maximal reuse (sizer, fzf
  styling, navigation primitive all already exist and are proven), minimal new
  code, fit-to-content sizing preserved, and every non-interactive path is left
  byte-for-byte unchanged because interactivity lives behind a new flag.

**Recommendation: option (c).** It is literally "do for `ls` what `sessions`
already does," so it inherits a known-good, in-tree pattern rather than inventing
one.

---

## 3. CRITICAL tmux concern — does navigation work from inside a popup?

**Yes — verified by precedent, and the correct pattern is already in use.**

`tmux switch-client` / `select-window` issued from a command running inside
`display-popup` operate on the **client that spawned the popup** (the popup is a
client overlay; tmux resolves the target client from that). Two shipping leader
actions already do exactly this from inside a popup and navigate correctly:

- **pick**: `display-popup -E … '$self pick'` (`:2709`) → fzf →
  `switch-client`+`select-window` (`:283-284`).
- **sessions**: `popup-fit sessions` → `display-popup -E … '$self sessions'`
  (`:2850`) → fzf → `switch-client` (`:2607`).

The enabling detail is **`-E`**: every fleet popup is opened with
`display-popup -E` (pick `:2709`; the sizer `:2841`, `:2850`). `-E` makes the
popup **close as soon as its command exits**. So the working sequence is:

```
(inside popup)  switch-client -t <sess>   →   select-window -t <window_id>   →   command returns   →   -E tears the popup down
```

The client is retargeted *while the popup is still open*, then the popup closes
and reveals the now-current window. No explicit "close popup first" is needed —
`-E` provides it. (And the leader menu that launched this is already gone: it
closed itself at `:2880-2883` before dispatching, with a `sleep 0.12` so its own
popup is fully torn down before the new ls popup opens.)

**Correct pattern to copy, unchanged:** keep cmd_pick's exact two-line navigation
(`switch-client -t <session>`; `select-window -t <window_id>`) and let the popup
be the standard `display-popup -E` the sizer already opens (`:2850`). Do **not**
background the tmux calls or try to close the popup manually — that would diverge
from the two precedents that work.

**Isolated runtime check (in the proof section) confirms this live** rather than
relying on precedent alone.

---

## 4. Scope, edge cases, reuse-vs-add

### Files touched (one file)

- **`bin/fleet` only.** No daemon, hook, dash, or nvim change. Blast radius of
  `cmd_ls` is tiny: CLI dispatch (`:3623`) + the popup-fit sizer (`:2862`).
  `bin/fleet-dash` consumes `fleet agents` (raw TSV), **not** `fleet ls`, so it is
  unaffected.

### Changes

1. **`cmd_ls` — add two non-default modes, leave the default path untouched**
   (`:221-259`). Extend the arg loop (`:229-234`) to recognise `--pick` and
   `--measure`. The existing print (header `:248`, the awk table `:252-257`) and
   the `--hold` behaviour stay exactly as-is for every current caller.

   - Refactor the row-building so the **awk that produces the display string is
     shared** between the static print, `--measure`, and `--pick` (analogous to
     `sessions_rows` `:2554-2581` feeding both `cmd_sessions` faces). Each `--pick`
     fzf row is `session<TAB>window_id<TAB><pretty ls row>` (col1/col2 hidden, the
     rest shown via `--with-nth=3`), mirroring `cmd_pick`'s tab layout
     (`:274-282`).
   - **`--measure`**: print just the visible display rows + 2 placeholder lines
     for fzf's prompt+info chrome, then return — copy `cmd_sessions --measure`
     verbatim in spirit (`:2591-2596`). No fzf launched.
   - **`--pick`**: build rows, launch fzf identically to `cmd_pick`
     (`--ansi --delimiter='\t' --with-nth=3 --no-sort --prompt='agent> '
     --height=100% --border=rounded`, `:278-279`); on a choice run the two
     navigation lines (`:283-284`). On no choice (fzf cancelled / Esc) return 0.

2. **Repoint the leader sizer** (`:2862`) to the sessions shape:

   ```
   ls)  popup_fit_content "$self ls --measure"  "$self ls --pick"  70% 60% ;;
   ```

   `--measure` sizes the popup to the fzf row set (matches what the user sees);
   `--pick` is the interactive run. The proportional `70% 60%` fallback is
   unchanged.

3. **Usage/help & docs**: update the `fleet ls` one-liner in `print_usage` and the
   leader-menu blurb in `CLAUDE.md`/`FLEET.md` to say the `ls` popup is now
   selectable (Enter jumps). Keep `--all`/`-a` semantics documented.

### Edge cases

- **Non-TTY / piped / measure**: gate interactivity on the flag *and* a TTY.
  `--pick` with no fzf, or `! -t 0 || ! -t 1`, falls back to the **static print**
  (and `hold_wait` if it was the popup) — copy `cmd_sessions`'s no-fzf/no-tty
  fallback (`:2598-2602`). Bare `fleet ls`, the `--measure` capture, and
  `fleet ls --hold` never enter fzf because they don't pass `--pick`. This is the
  hard guarantee the task requires.
- **No agents / empty project**: today `cmd_ls` prints "no agents registered" /
  "no agents in this project" and holds (`:238`, `:245`). `--pick` must do the
  same — print the message and `hold_wait` so the `-E` popup doesn't flash shut.
  (Note `cmd_pick`'s `echo "no agents to pick"; return 0` at `:276` *does* flash
  under `-E`; the ls `--pick` empty path should hold instead — a small
  improvement, documented.)
- **`*_hidden` scratch rows**: the static ls intentionally **shows** them (scope
  keeps `$3==s"_hidden"`, `:244`). But navigating into a hidden session is the
  teleport trap cmd_pick guards against (`:266-270`). So `--pick` **drops
  `*_hidden` from the selectable set** (reuse `$3 ~ /_hidden$/{next}`, `:270`).
  Consequence: the interactive picker lists one fewer category than the static
  print — justified and matching pick; document it. (Reaching scratch stays a
  dashboard job.)
- **`done`/ready-decorated rows**: keep the `:252-257` decoration in the fzf
  display string. A done agent's window still exists, so `select-window` still
  works — navigating to a done agent is fine.
- **Daemon down**: `agents_tsv` already falls back to tmux `@agent_state` window
  options (`:196-207`), still yielding session + window_id, so `--pick` keeps
  working (possibly staler). No special handling.
- **`--all` + `--pick`**: server-wide selectable list is harmless (it's what pick
  is). Allow the flags to combine; default leader stays project-scoped.

### Reuse vs add

- **Reuse:** `popup_fit_content` sizer (`:2820`), the `display-popup -E` it opens
  (`:2850`), fzf invocation + tab-column convention (`:274-282`), the
  `switch-client`+`select-window` primitive (`:283-284`), the `*_hidden` drop
  (`:270`), the no-fzf/no-tty fallback (`:2598-2602`), `hold_wait` (`:216`),
  session scoping (`:243-246`), the table awk (`:252-257`).
- **Add:** `--pick` and `--measure` arms in `cmd_ls`; a shared row-builder; the
  two-char edit at `:2862`; usage/doc text. **No new commands, no new dispatch
  entries, no new files.**

---

## 5. PROOF DESIGN — explicit checks that prove it works

Fleet has no test runner (`CLAUDE.md`: "No build, no test suite"); the smoke test
is `fleet doctor` plus isolated runtime scenarios. **All runtime checks run in a
throwaway tmux session via `FLEET_SESSION` / a dedicated `tmux -L` socket —
never the live `pc` session.** `session_name()` honours `$FLEET_SESSION`
(`:89-92`), and `fleet_root()` reads it through (`:94-100`), so scoping can be
driven without touching the real session.

Setup (scratch only — keep under `$FLEET_DOCS`):

```sh
export FLEET_DOCS=/home/red/proj/pc-tune/.fleet/notes/scratch/ls-nav-research
tmux -L lsnavtest new-session -d -s sbx          # isolated server+session, NOT pc
SELF=/home/red/proj/pc-tune/fleet/main/bin/fleet
```

### A. Non-interactive paths unchanged (the hard guarantee)

1. **CLI/static unchanged** — capture `"$SELF" ls` before and after the patch
   (same daemon state); diff must be **empty**. Proves the default print path is
   byte-for-byte identical (header, table, scoping, done decoration).
2. **Piped is non-interactive** — `"$SELF" ls | cat` exits promptly, prints the
   table, **never** launches fzf and **never** blocks. (`! -t 1` ⇒ fallback.)
3. **`--measure` is pure text** — `"$SELF" ls --measure` prints only display rows
   + the 2 chrome placeholders, launches no fzf, exits 0; `popup_fit_content`'s
   width/height come out as positive integers (instrument the sizer or eyeball
   the resulting `-w/-h`).
4. **`--hold` still just holds** — `"$SELF" ls --hold` prints the table then waits
   on a single keypress (no fzf), exactly as today.
5. **Empty project graceful** — in a session with zero agents,
   `"$SELF" ls` prints "no agents in this project" and (`--hold`/`--pick`) holds;
   the `-E` popup does **not** flash shut. `"$SELF" ls --pick </dev/null`
   (non-tty) falls back to the static message, exit 0.

### B. Interactive selection navigates (the new behaviour)

Drive fzf non-interactively to assert the navigation without a human:

6. **Selecting an agent jumps to its window** — register ≥2 fake agents in the
   sbx session (spawn two throwaway windows and set their `@agent_state` so
   `agents_tsv`'s daemon-down fallback `:196-207` lists them, or point at a
   scratch fleetd). Run `"$SELF" ls --pick` with fzf forced to auto-pick a known
   row (`fzf --filter=<unique-substring> | head -1`, or `FZF_DEFAULT_OPTS`
   `--select-1 --query=<substr>`). Assert afterward that
   `tmux -L lsnavtest display -p '#{window_id}'` equals the picked row's
   `window_id` — i.e. `select-window` landed on the target. Repeat picking the
   *other* agent to prove it's the selection, not a fixed target.
7. **Cross-session jump** — give a second sbx-family session an agent; pick it;
   assert both `#{session_name}` switched (`switch-client`) **and** `#{window_id}`
   matches (`select-window`). This exercises the two-line primitive together.
8. **Popup-real check (proves §3 live)** — bind a throwaway key in the sbx server
   to the *actual* `popup-fit ls` command and, with two agents present, open it,
   type a filter, press Enter; confirm the client moved to the selected window and
   the popup closed. This is the only check that exercises a genuine
   `display-popup -E`; do it once to validate the precedent empirically.
9. **`*_hidden` excluded** — add an agent in a `sbx_hidden` session; assert it
   **appears** in `"$SELF" ls` (static) but is **absent** from the `--pick` fzf
   row set (no teleport trap).
10. **Cancel is a no-op** — `--pick` with fzf aborted (Esc / exit 130) leaves the
    current `#{session_name}`/`#{window_id}` unchanged.

### C. Dependency / health

11. **`fleet doctor`** (`:3182`) reports `ok fzf` (and tmux/git/etc.); confirms
    the fzf dependency the `--pick` path needs is present.
12. **No-fzf degrade** — with `fzf` masked off `PATH`, `"$SELF" ls --pick` (in a
    TTY) falls back to the static print instead of `die`-ing, so the leader popup
    still shows the table.

### Teardown

```sh
tmux -L lsnavtest kill-server 2>/dev/null
```

### Success criteria (all must hold)

- **S1** Static/CLI/piped/`--measure`/`--hold` outputs are unchanged vs. main
  (checks 1–4).
- **S2** From the popup, picking an agent navigates to its window — same session
  (check 6) and cross-session (check 7), verified live through a real
  `display-popup -E` (check 8).
- **S3** Empty/no-agent and no-fzf cases degrade gracefully (print + hold /
  static fallback, no flash, no `die`) — checks 5, 12.
- **S4** `*_hidden` scratch never becomes a navigation target (check 9); cancel is
  inert (check 10).
- **S5** `fleet doctor` green for fzf (check 11).
- **S6** The live `pc` session is never touched — every runtime check ran under
  `tmux -L lsnavtest` / `FLEET_SESSION=sbx`.

---

## Recommendation (one line)

Implement option (c): clone the `cmd_sessions` fit-content+fzf+`switch-client`
pattern into `cmd_ls` behind new `--pick`/`--measure` flags and repoint the leader
sizer (`:2862`) to `"$self ls --measure"` / `"$self ls --pick"`; navigation from
inside `display-popup -E` is already proven by pick (`:2709`) and sessions
(`:2850`), so reuse cmd_pick's two-line `switch-client`+`select-window` verbatim
(`:283-284`) and leave every non-interactive path untouched.

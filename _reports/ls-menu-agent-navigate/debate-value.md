# Adviser debate — VALUE-ADD / UX lens

**Dispatch:** d5. **Scope:** what additions make the interactive `ls` popup
materially better for the user *without* bloating scope. Recommend only what is
cheap given the existing code; flag scope-creep. No code written.

Verified against `bin/fleet`: `cmd_ls` (:221-259), `cmd_pick` (:263-285),
`cmd_sessions` / `sessions_rows` (:2554-2608), `popup_fit_content` /
`cmd_popup_fit` (:2820-2865), leader-menu wiring (:2869-2884), and the
`CLAUDE.md` leader-menu spec.

---

## Verdict in one line

The plan's core (option c — keep the rich ls view, Enter jumps) is the right UX
call; endorse it. Add **three cheap things** (fzf header/hint line, attention-first
sort, empty-state hold — two are one-liners, one is already in the plan). Treat
**preview pane** and **`--all` toggle** as optional cheap follow-ups, not v1.
**Reject** per-row action verbs and multi-select as scope-creep that also
contradicts fleet's stated "per-agent verbs live on the dashboard" design. The
one strategic issue worth a decision: after this change leader **`a`=pick and
`l`=ls overlap heavily** — make that distinction intentional and documented.

---

## Q1 — Rich ls view + jump, vs just reusing `pick`? → Keep the rich view. Endorse.

Reusing `pick` (option a) was correctly rejected. From the user's seat the ls
view earns its keep:

- **Project scope by default.** `pick` is server-wide (:269); `ls` scopes to the
  current session + its `_hidden` sibling (:243-246). When you press the *info*
  key to see "what's in this project," a project-scoped jump list is what you
  expect. Server-wide already has a home on `a`.
- **`STATE / AGENT / WINDOW / IN-STATE` columns + `done`/`ready` decoration**
  (:248-257) carry real signal `pick`'s single coloured line drops: *which agent
  is done and why* (the `(ready: …)` text), and the in-state age. Choosing which
  agent to jump to is exactly when that context matters.

So: keep the columns, Enter jumps. This is the high-value half of the feature and
it costs little — the awk that builds the display string already exists; the plan
just shares it three ways (matching `sessions_rows`).

---

## Cheap additions worth doing in v1

### 1. fzf `--header` with the column labels + a one-line hint (≈1 flag)

The static print emits a `STATE AGENT WINDOW IN-STATE` header (:248). In `--pick`
that header must NOT become a selectable fzf row. Put it in fzf's pinned header
instead:

```
fzf … --header='STATE  AGENT  WINDOW  IN-STATE        ↵ jump · esc cancel'
```

Cost: one flag, no new logic. Value: the rich columns are the whole point of
keeping the ls view — unlabelled they lose half their value, and a first-time user
has no idea Enter now does something (the popup used to be press-any-key-to-close).
This single line is the difference between "looks like the old static popup" and
"obviously a picker." Strongly recommend.

### 2. Attention-first sort in `--pick` (reuse pick's awk, ≈0 new code)

Static `ls` sorts alphabetically by state (`sort -k1,1`, :252) → blocked, done,
idle, working. `pick` deliberately sorts by *priority* — `blocked=0, idle=1,
working=2` (:271-275) — so the agent that needs you floats to the top. For a
*jump* picker, priority-first is the better default: you open it because something
needs attention. Reuse pick's `o`-mapping in the `--pick` branch only; leave the
static print's alphabetical sort byte-for-byte unchanged (the plan's hard
guarantee). Near-zero cost (the mapping is copy-paste from :271-274), real value.

### 3. Hold on the empty/no-agent path (already in the plan — endorse)

The plan already specifies that `--pick` with zero agents should print the message
and `hold_wait` rather than flash shut under `-E` (§4 edge cases; note that
`cmd_pick`'s `:276` flashes). Endorse explicitly — flashing an empty `-E` popup is
a genuine papercut, and fixing it makes the new ls path strictly nicer than the
old `pick`. Cost is one `hold_wait` call already in the codebase (:216).

---

## Optional — cheap-ish, defensible, but fine to defer past v1

### A. Live preview pane (`tmux capture-pane`)

`agents_tsv` already carries `pane_id` (field 7, :194). fzf could show a live
glance of the selected agent's pane:

```
fzf … --preview 'tmux capture-pane -p -t {7} 2>/dev/null | tail -n 40'
```

Value is real: when two agents are "working," a glance at what each is actually
doing is the best possible disambiguator before you jump. **But** it is the most
expensive add here: the preview window changes the popup's effective dimensions,
so the fit-to-content sizer (`popup_fit_content` measures *rows/cols of text*,
:2836-2849) would under-size — you'd likely have to drop ls's preview popup to a
fixed frame like `pick`'s `80% 60%`, losing fit-to-content. That's a real
trade-off, not a free win. Recommend: **defer to a follow-up**, and if taken,
accept a fixed-size popup for the `--pick` face (measure path stays for the
non-preview callers). Flag as borderline, not v1.

### B. `ctrl-a` to toggle `--all` (server-wide) inside the popup via fzf `reload`

The plan factors a shared row-builder; once `fleet ls --pick`'s rows are
producible standalone, fzf's `reload` action makes scope a live toggle:

```
fzf … --bind 'ctrl-a:reload(<row-builder> --all)'
```

So a user who opened the project-scoped list can widen to server-wide without
backing out and pressing `a`. Cheap *if* the row-builder is already a callable
sub-mode (which the plan's shared builder enables). **But** server-wide is already
one keystroke away on leader `a`, so this is a convenience, not a gap. Recommend:
optional; only worth it if the shared row-builder lands as a clean callable anyway.
Do **not** expand scope just to enable it.

---

## Reject as scope-creep

### Per-row action verbs (send / mode) via `--expect`

fzf could capture a second key (`--expect=ctrl-s,ctrl-m`) to act on the row
instead of jumping. **Reject**, for two reasons:

1. **Contradicts fleet's stated design.** `CLAUDE.md` is explicit: *"Per-agent
   verbs (msgs `e`, send, mode, diff, close) stay on the dashboard's selected row,
   not in the leader."* Bolting send/mode onto the leader ls popup is exactly the
   thing that line forbids. The leader is for *navigation*; the dashboard row is
   for *acting*. Keep that seam clean.
2. **`send` needs a message body** — there's no good inline-from-fzf way to compose
   it; you'd half-build a feature that the dashboard already does properly.

This is the classic "while we're here" creep. The whole value of this task is that
it's a clone of an existing proven pattern; adding a verb layer throws that away.

### Multi-select

No coherent meaning for a *jump* picker (you land on one window). Reject.

---

## The strategic UX issue: `a`=pick and `l`=ls now overlap

This is the one thing worth a deliberate decision rather than a code tweak. After
this change:

| Key | Action | Scope | View | Ends in |
|-----|--------|-------|------|---------|
| `a` | pick | server-wide | one coloured line/row | switch+select-window |
| `l` | ls (new) | project (＋`--all`) | rich STATE/AGENT/WINDOW/IN-STATE + done | switch+select-window |

`ls --pick` is essentially a **richer superset of `pick`**: same navigation
primitive (:283-284), strictly more context, plus the empty-state and `_hidden`
handling come out *better* (per the plan). Two leader keys now do "pick an agent
and jump," which is mild redundancy a user has to learn.

Cheap resolutions, in order of preference:

1. **Document the split and make it intentional** (cheapest, recommended for this
   task): `a` = fast server-wide jump (flat list, fewest keystrokes); `l` =
   this-project jump with full status. Update the leader-menu blurb in `CLAUDE.md`
   so both keys read as deliberate, not accidental twins. Zero code.
2. **Later (out of scope here): consider folding `pick` into `ls --pick --all`**
   and freeing the `a` key, since ls is the superset. Flag for a future cleanup;
   do **not** do it in this PR — it widens blast radius past the "clone sessions
   into ls" promise.

Consistency with `o`=sessions is *good* and should be stated as the mental model:
**`o` switches project (session level) → `a`/`l` switch agent (window level).** The
new ls slots cleanly into that hierarchy. Two trivial cosmetic nits while you're in
the fzf call: `pick` uses `--border=rounded` *inside* an already-rounded popup
(double border), `sessions` uses `--border=none` (:2605). Match ls to `sessions`
(`--border=none`) so the popup has one clean frame — one flag.

---

## `--all` from the popup (the asked question)

`--all` *should be reachable*, but it already is — via leader `a` (server-wide) and
via `fleet ls --all` on the CLI. So in the popup it's a nice-to-have toggle (option
B above), not a requirement. Recommend: allow `--all` + `--pick` to combine on the
CLI (the plan already does, §4), keep the **default leader `l` project-scoped**, and
only wire the in-popup `ctrl-a` toggle if the shared row-builder makes it nearly
free. Don't grow scope for it.

---

## Summary — recommendation to the implementer

**Do in v1 (cheap, high value):**
- Keep the rich ls view + Enter-jumps (plan's option c). ✓
- Add fzf `--header` with column labels + `↵ jump · esc cancel` hint. (1 flag)
- Sort `--pick` attention-first (blocked→idle→working), reusing pick's awk; leave
  static sort untouched. (copy-paste)
- Hold on empty/no-agent under `-E` (already planned). ✓
- `--border=none` to match `sessions`, avoid double frame. (1 flag)
- Document the `a` vs `l` split + the `o→a/l` hierarchy in `CLAUDE.md`. (prose)

**Optional follow-ups (defer; only if near-free):**
- `tmux capture-pane` preview — real value, but forfeits fit-to-content sizing;
  separate PR.
- `ctrl-a` `--all` toggle via fzf `reload` — only if the shared row-builder lands
  as a callable sub-mode anyway.

**Reject (scope-creep / against stated design):**
- Per-row send/mode verbs in the leader popup (belongs on the dashboard row).
- Multi-select.

Net: the plan is already lean and correct. The single most valuable addition is
the **header/hint line** — without it the "richer columns" you fought to keep are
unlabelled and the new interactivity is invisible. Everything else is polish or a
conscious-redundancy note.

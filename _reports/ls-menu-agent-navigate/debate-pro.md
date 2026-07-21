# Adviser debate — PRO (option c)

**Position:** Implement option (c) — clone the `cmd_sessions`
fit-content + fzf + `switch-client` pattern into `cmd_ls` behind new
`--pick`/`--measure` flags. This is the best approach, and every reuse claim in
the plan holds against the actual code. Verified live against
`bin/fleet` @ `fleet/main`.

---

## 1. The core argument: this isn't "design a feature," it's "copy a shipping one"

The decisive fact is that fleet **already runs** the exact mechanism this task
needs — "a fit-to-content popup running interactive fzf that ends in
`switch-client`" — for the `sessions` action. Option (c) is not inventing a
pattern; it is pointing `ls` at the same rails `sessions` rides today. Look at
the two sizer rows side by side (`bin/fleet:2862-2863`):

```
ls)       popup_fit_content "$self ls"            "$self ls --hold"   70% 60% ;;   # static today
sessions) popup_fit_content "$self sessions --measure" "$self sessions" 70% 60% ;; # interactive today
```

The change is to make the `ls` row *the shape of the `sessions` row*. That is
the whole structural delta. When a codebase already contains a working instance
of the thing you're asked to build, cloning that instance is almost definitionally
the lowest-risk, highest-confidence path — you inherit a known-good design plus
its already-debugged edge handling, rather than re-deriving both. The other two
options throw that gift away (see §6).

---

## 2. Every reuse claim verified against the code

I checked each cited primitive. They all hold.

**Sizer (`popup_fit_content`) and the `-E` popup it opens — `:2820-2851`.**
Confirmed. The helper evals `<measure_cmd>`, strips SGR (`:2838`), sets width
from the longest visible line and height from line count (`:2837`), pads
+4 cols/+2 rows (`:2844`), clamps to client (`:2848-2849`), and opens
`tmux display-popup -E -b rounded -w <cols> -h <rows> "$run_cmd"` (`:2850`), with
a proportional `-w/-h` fallback on any measurement hiccup (`:2840-2842`). It is
generic by construction — its own comment says it is "Used by the leader menu,
`keys`, and `ls`" (`:2826`). Feeding it `ls --measure`/`ls --pick` is exactly
the contract it already exposes. **Reuse holds.**

**The `display-popup -E` navigation precedent — pick `:2709`, sessions `:2850`.**
Confirmed both.
- pick: `display-popup -E -b rounded -w 80% -h 60% '$self pick'` (`:2709`) — a
  popup whose command ends in navigation.
- sessions: routed through the sizer (`:2732` → `:2863`), whose run arm is the
  bare interactive `$self sessions`, opened by the same `display-popup -E` at
  `:2850`, and `cmd_sessions` ends in `tmux switch-client` (`:2607`).

So there are **two** shipping leader actions that navigate from inside a
`display-popup -E`, one of them through the very sizer ls uses. The plan's §3
claim — that `switch-client`/`select-window` issued inside an `-E` popup retarget
the spawning client and the `-E` then tears the popup down to reveal it — is
backed by these two live precedents, not by assertion. **Precedent holds.**

**cmd_pick's two-line navigation — `:283-284`.** Confirmed verbatim:

```
283	tmux switch-client -t "$sess" 2>/dev/null
284	tmux select-window -t "$win" 2>/dev/null
```

with `$sess`/`$win` cut from the chosen fzf row (`:281-282`). The plan proposes
copying these two lines unchanged. Because tmux window ids (`@N`) are
server-global, `select-window -t @N` is unambiguous regardless of current
session — the plan's reasoning is sound. **Primitive holds.**

**The `_hidden` drop — `:270`.** Confirmed: `cmd_pick` opens its awk with
`$3 ~ /_hidden$/{next}` (`:270`), with the rationale spelled out at `:266-268`
(switching a client into a bare `*_hidden` session is a teleport trap — no
main/dash window). Reusing this guard in `ls --pick` is a one-line lift of an
existing, commented decision. **Guard holds.**

**The shared row-builder precedent — `sessions_rows` `:2554-2581`.** Confirmed.
`sessions_rows` emits `session<TAB>display` rows once, and both faces consume it:
`--measure` does `cut -f2-` plus two chrome placeholder lines (`:2592-2594`), and
the interactive run feeds the same rows to fzf `--with-nth=2` (`:2604`). This is
precisely the "one builder, two faces" structure the plan wants to mirror in
`cmd_ls` (its proposed rows are `session<TAB>window_id<TAB>pretty`, shown via
`--with-nth=3` like cmd_pick at `:274/:278`). **Refactor pattern holds.**

**The no-fzf / no-tty fallback — `:2599-2602`.** Confirmed:

```
2599	if ! command -v fzf >/dev/null || [ ! -t 0 ] || [ ! -t 1 ]; then
2600	  printf '%s\n' "$rows" | cut -f2-
2601	  return 0
2602	fi
```

This is the exact degrade the plan copies so piped/non-tty/fzf-missing `ls --pick`
prints the static list instead of hanging or `die`-ing. **Fallback holds.**

**`hold_wait` and the zsh-`read` minefield — `:211-219`.** Confirmed. The comment
(`:211-215`) documents *why* the key-wait must live in `bin/fleet` (bash): an
inline `read -n1` in the tmux command string runs under the user's default shell,
and zsh `read -n1` errors instantly — the flash bug. `hold_wait` (`:216-219`)
uses `read -rsn1 … || read -r … || true`. This is load-bearing for the plan's
empty-`--pick` path (print message + `hold_wait` so the `-E` popup doesn't flash
shut), and option (c) keeps the key-read inside bash, honoring the constraint.
**Constraint respected.**

**The non-interactive `cmd_ls` surface left untouched — `:221-259`.** Confirmed.
The default path parses only `--all`/`--hold` (`:229-235`), scopes to
`$3==s || $3==s"_hidden"` (`:244`), prints the `STATE/AGENT/WINDOW/IN-STATE`
table with done/ready decoration (`:248-257`), and calls `hold_wait` only under
`--hold` (`:258`). Because (c) gates all new behaviour behind `--pick`/`--measure`
*and* a TTY, the three current callers — CLI (`:3623`), the measure capture, and
`ls --hold` — never enter fzf. The byte-for-byte-unchanged guarantee is
structurally true, not merely promised. **Isolation holds.**

Every reuse claim in the plan is backed by code I read. None overstated.

---

## 3. Is this the best way? Yes.

Three independent reasons, in order of weight:

1. **Maximum proven reuse, minimum new surface.** Sizer, `-E` popup, fzf
   invocation + tab-column convention, the `switch-client`+`select-window`
   primitive, the `_hidden` drop, the no-fzf/no-tty fallback, `hold_wait`, the
   session scoping, and the table awk are **all already in the tree and already
   exercised in production paths**. The genuinely new code is two arg-arms in
   `cmd_ls`, a shared row-builder, and a two-token edit at `:2862`. Less new code
   over more reused-proven code is the lowest-defect path.

2. **The non-interactive guarantee falls out of the architecture for free.**
   The task's hard requirement is "don't break plain CLI / piped / measure /
   `--hold`." Option (c) satisfies it *by construction*: interactivity lives
   behind a flag that those callers never pass, and is additionally TTY-gated.
   No caller-by-caller auditing needed — the new behaviour is unreachable from
   the old entry points.

3. **It preserves ls's distinct value while adding navigation.** ls is
   project-scoped (`:243-246`) with the richer `STATE/AGENT/WINDOW/IN-STATE`
   table and done/ready decoration (`:252-257`); pick is server-wide with a
   different column set. Option (c) keeps the ls view *and* makes it navigable —
   the user gets selection without losing the scoped, decorated table they
   already rely on.

---

## 4. The two improvements (c) lands as a bonus

Option (c) isn't just neutral-preserving; it fixes two rough edges:

- **Empty-list flash.** `cmd_pick` does `echo "no agents to pick"; return 0`
  (`:276`), which under `-E` flashes shut. ls `--pick` instead prints the message
  and `hold_wait`s (mirroring cmd_ls's existing empty paths at `:238`/`:245`), so
  the empty popup is readable. Strictly better than the precedent it copies.
- **Sizing matches what the user sees.** Pointing the measure arm at
  `ls --measure` (fzf rows + 2 chrome placeholders, like sessions `:2592-2594`)
  sizes the popup to the fzf row set rather than to the old static table —
  fit-content stays honest.

---

## 5. Honest scope checks (PRO, not blind)

I confirmed the few places a naive reading could trip, so the recommendation is
not hand-waving:

- **Measure must not launch fzf.** sessions solves this with a dedicated
  `--measure` arm (`:2591-2596`) that returns before fzf. ls must do the same;
  the plan specifies exactly this. If `--measure` ever fell through to fzf, the
  sizer's `eval "$measure_cmd"` (`:2830`) would hang the popup launch — so this
  arm is mandatory, and the plan has it.
- **`--pick` shows one category fewer than static ls.** Static ls intentionally
  lists `*_hidden` (`:244`); `--pick` drops them (`:270`) to avoid the teleport
  trap. This is a deliberate, documented divergence matching cmd_pick — correct,
  and worth the one-line note the plan calls for.
- **`done` rows remain navigable.** A done agent's window still exists, so
  `select-window` works; keeping the decoration in the fzf display string is
  fine. Confirmed against the decoration logic at `:252-257`.

None of these is a blocker; each is already addressed in the plan.

---

## 6. Why (c) beats (a) and (b)

- **(a) point leader `ls` at `cmd_pick`** is a one-liner but *deletes ls's value*:
  it swaps the project-scoped, richer-table, decorated ls view for pick's
  server-wide columns. The user asked to make *ls* navigable, not to alias ls to
  pick. Rejected: redundant, loses the view.
- **(b) static grid + single-key row selection** reinvents — for free-from-fzf —
  filter/scroll/arrows/mouse/>9-rows/paging that fzf already gives, adds the most
  new code, and re-enters the zsh `read` minefield the `:211-215` comment warns
  about. Most surface, most risk, worst fit.

Both lose to (c) on the one metric that matters here: new-risk per unit of
delivered behaviour.

---

## Verdict

**FOR option (c), unreserved.** It is the best approach because it is the only
one that is mostly *not new code* — it reroutes `ls` onto the sessions pattern
that already ships, reuses seven-plus verified primitives verbatim, satisfies the
non-interactive guarantee structurally rather than by audit, and even repairs two
edges of the precedent it copies. Every reuse claim the plan makes checks out
against the actual `bin/fleet`. Ship it.

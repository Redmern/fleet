# Adviser debate — CON / RISK lens on option (c)

**Scope.** Adversarial review of PLAN.md's recommended option (c): add `--pick`
and `--measure` arms to `cmd_ls`, share the row-building awk across
static/measure/pick, repoint the leader sizer (`:2862`) to
`"$self ls --measure"` / `"$self ls --pick"`. All line refs are `bin/fleet` at
this worktree.

**Verdict up front.** Option (c) is sound *in principle* — `cmd_sessions`
(`:2583-2608`, wired through the same sizer at `:2863`) genuinely proves a
fit-content `display-popup -E` running fzf that ends in `switch-client` works.
But the plan **as written** contains four concrete defects that each break, or
risk breaking, the hard guarantee or the popup UX. The fix is not a different
option — it is a **stricter implementation of (c)** with required guards. Details
below, strongest first.

---

## R1 (HIGH, concrete bug). `--border=rounded` double-border + truncation

The plan (§4, change 1) says copy cmd_pick's fzf invocation *verbatim*, and
explicitly lists `--border=rounded` (`:279`). But cmd_pick (`:279`) is opened in
a **plain, fixed-size** popup (`display-popup -E -b rounded -w 80% -h 60%`,
`:2709`) — fzf's own border is the only sizing concern there.

The leader `ls` path is different: it goes through `popup_fit_content`, which
opens **its own** `display-popup -E -b rounded` (`:2850`) sized to the measured
content **+4 cols / +2 rows** (`:2844`). The closer precedent — `cmd_sessions`,
which is the one the plan claims to be cloning — deliberately uses
**`--border=none`** (`:2605`) precisely *because the popup already draws a
rounded border*. cmd_pick uses `--border=rounded` only because its popup is sized
generously at 80%/60%.

Copying cmd_pick's `--border=rounded` into the fit-content popup ⇒ **two nested
rounded borders** consuming 2 extra cols + 2 extra rows that the `+4/+2` budget
(`:2844`) never accounted for, plus fzf's left pointer/gutter (~2 cols). Net:
the fitted popup is **too narrow**, fzf truncates the rightmost column (the
age/IN-STATE field) and/or shows a scrollbar. This is a real, shipped-on-day-one
cosmetic regression baked into the plan's own text.

**Required guard:** use **`--border=none`** (follow `cmd_sessions :2605`, NOT
cmd_pick), or widen the `+4` width budget specifically for the fzf face. Do not
copy cmd_pick's border flag.

---

## R2 (HIGH, hard-guarantee risk). "Share the awk" endangers byte-identical static output

S1 demands the static/CLI `fleet ls` output stay **byte-for-byte** identical to
main. The plan's change 1 proposes to **refactor the row-builder so the awk is
shared** between the static print, `--measure`, and `--pick`. That means the
static path (`:252-257`) stops being the existing code and starts flowing through
a new shared builder — directly putting the hard guarantee at the mercy of a
refactor.

Worse, the three faces are **genuinely different renderings**, so "sharing" is a
false economy that fights the data:

- **Static face** (`:252-257`): TAB-separated `state\tlabel\tsess:win\tage` with
  the ready/done decoration (`(ready: …)` / `(ready? … — but …)`), sorted
  `sort -k1,1` (alphabetical state).
- **fzf face** (cmd_pick `:269-275`): space-padded `●  %-8s  %-40s  sess:win
  age`, **no** ready decoration, sorted by a numeric **state-priority** key
  (blocked=0/idle=1/working=2, `:271-275`).

Forcing one builder to emit both means either the static bytes change (sort
order, spacing, decoration) — **violating S1** — or the fzf rows drift from what
`--measure` sized for. The proof check #1 ("diff must be empty") would catch a
regression, but only if someone runs it; the plan invites the regression by
design.

There is also a **field-count asymmetry** the shared builder must survive:
daemon-up rows have **9 fields** (`:192-194`), daemon-**down** rows have only
**7** (`:202-207` printf emits st/label/sess/wid/wname/since/pane — no age-secs,
no ready `$9`). The static awk tolerates this (a missing `$9` reads as `""`); a
"clever" shared builder that assumes 9 fields breaks the daemon-down path.

**Required guard:** **ADD, do not REFACTOR.** Leave `:248-257` 100% untouched.
Write a *separate*, small builder for `--pick`/`--measure` (it only needs
`$3` session, `$4` window_id, and a display string). Reuse cmd_pick's awk shape,
not the static awk. Less DRY, zero risk to S1, robust to the 7/9-field split.

---

## R3 (HIGH). The tty × agents fallback matrix is under-specified — flash *or* hang

`--pick` has four states to handle correctly; the plan conflates them:

| | agents present | empty project |
|---|---|---|
| **tty (popup)** | fzf → navigate | print msg + **hold_wait** (else `-E` flashes, §4 edge case) |
| **non-tty (piped/measure)** | print static + **return** (no hold) | print msg + **return** |

The plan says two contradictory things: "copy `cmd_sessions`'s no-fzf/no-tty
fallback" (`:2599-2602`, which **prints and returns, never holds**) AND "the
empty `--pick` path should **hold** so the `-E` popup doesn't flash"
(`:2598-2602` is the sessions fallback that does NOT hold). These are different
cells of the matrix. Get the empty-tty cell wrong → **flash** (the exact bug
cmd_pick has at `:276`). Get the non-tty cell wrong (e.g. always `hold_wait`) →
`fleet ls --pick | cat` **blocks on a key read from the controlling tty** — a
hang on a non-interactive invocation, which is the precise class of breakage the
task forbids.

The static path today has a *single* boolean (`--hold`). `--pick` quadruples the
decision surface, and every cell has a distinct failure mode (flash / hang /
fzf-into-a-pipe).

**Required guard:** implement the matrix explicitly: gate fzf on
`--pick && [ -t 0 ] && [ -t 1 ]`; on empty **inside a tty** print + `hold_wait`;
on **non-tty** print static + plain `return 0` (never hold). Add proof checks for
all four cells, not just the two the plan lists.

---

## R4 (MEDIUM). measure ↔ pick divergence ⇒ mis-sized popup

`popup_fit_content` sizes the popup from `--measure`'s output, then runs
`--pick`. If the two faces apply **different filters/scope/sort**, the popup is
sized for a row set the user never sees:

- **`*_hidden` filter:** static ls **keeps** `$3==s"_hidden"` (`:244`); `--pick`
  must **drop** `_hidden` (the teleport trap, `:270`). If `--measure` forgets to
  drop `_hidden`, it counts rows `--pick` won't show → popup too tall (harmless)
  or, with a wide hidden label, too wide.
- **scope:** the measure runs via `run-shell -b` (`:2730`) in the tmux **server**
  context; the `--pick` run executes inside the popup attached to the **client**.
  `session_name()` (`:89-92`) resolves `#{session_name}` differently in those two
  contexts. On a multi-project server they can scope to **different sessions** →
  measure counts N agents, pick shows M. (This latent divergence exists today for
  `ls` vs `ls --hold`, but a static popup that's slightly mis-sized is forgiving;
  an fzf popup truncates or scrolls.)
- **sort:** if measure uses the static `sort -k1,1` but pick uses the
  state-priority sort, counts match so sizing survives — but only by luck.

**Required guard:** `--measure` must be `--pick` minus the fzf launch — *same*
builder, *same* `_hidden` drop, *same* scope, *same* sort — plus the chrome
placeholder lines (mirror `cmd_sessions --measure` `:2591-2596`). Verify measure
and pick resolve the **same session** under `run-shell -b` (the §3 live check is
the only place this surfaces).

---

## R5 (MEDIUM). The §3 navigation claim is proven only *partially* — make check #8 blocking

The plan's §3 asserts navigation-from-inside-`-E` "just works, proven by pick and
sessions." Scrutinised:

- `cmd_sessions` proves **`switch-client`** from a **sizer-launched** popup
  (`:2863` → `:2850` → `:2607`). ✓ — but it does **not** call `select-window`.
- `cmd_pick` proves **`switch-client` + `select-window`** (`:283-284`) — but from
  the **direct** `display-popup -E` (`:2709`), not the sizer.

So the *exact* combination ls needs — `switch-client` **and** `select-window`
from a **sizer-launched** (`run-shell -b` → `popup_fit_content` → `display-popup
-E`) popup — is proven by **neither precedent end-to-end**, only by composition.
The launch contexts are equivalent enough that it very likely works, and
`select-window -t @N` on a global window-id is order-independent of the
`switch-client`. But "very likely" is not "verified" for the feature's whole
point.

**Required guard:** the plan files this as proof check #8 ("do it once"). Elevate
it to a **blocking** acceptance gate — a real `display-popup -E` opened through
the actual `popup-fit ls` binding, with two agents, Enter, assert client moved +
window selected. If #8 fails, the feature is dead regardless of the unit checks.

---

## R6 (LOW). New public CLI surface + orphaned `--hold`

- `fleet ls --pick` / `fleet ls --measure` become **typeable CLI verbs**. In a
  plain shell pane `fleet ls --pick` (tty) will launch fzf and `switch-client`
  the whole client — a new, surprising side effect for a command historically
  pure-print. Low harm, but document it; the arg loop (`:229-234`) must also not
  choke (today unknown flags are silently ignored — adding cases is fine).
- After repointing `:2862`, **`fleet ls --hold` is orphaned** from the leader
  path (only `keys` still uses `--hold`, `:2861`). Keep it working (it's cheap),
  but note it is now dead weight for `ls` and a future reader may "clean it up"
  and break the `--pick` empty-cell fallback that reuses `hold_wait`.

---

## Is there a better way?

Not a different *option* — (c) is the right shape — but a **safer
implementation**, plus two fallbacks worth keeping on the table:

1. **(c′) Minimal-delta (recommended).** ADD separate small `--pick`/`--measure`
   builders; **never touch** the static awk (`:248-257`); use **`--border=none`**
   (sessions, `:2605`); make `--measure` literally `--pick`-minus-fzf so they can
   never diverge; implement the full 4-cell tty×agents matrix; make the live
   `-E` test (#8) a blocking gate. This neutralises R1–R5 with *more* code than
   the plan's "share the awk" but far less *risk*. The plan's DRY instinct is the
   single biggest source of danger here.

2. **(c″) Conservative reuse fallback.** If the ls-table-inside-fzf rendering
   proves fiddly, scope **`cmd_pick` itself** to the current project
   (`cmd_pick --project`) and wire that through the sizer. Maximal reuse (one
   picker, one renderer, one proven nav path); the only loss is ls's distinct
   STATE/AGENT/WINDOW/IN-STATE table + ready decoration inside the popup. The
   plan rejected this as "duplicates pick," but it is the lowest-risk path to the
   *navigation* goal.

3. **Question the premise (do-nothing).** Leader **`a`=pick already navigates**
   (`:2709`, `:283-284`). The marginal value of *also* making `ls` navigate (vs.
   the new risk surface: 4-cell fallback, double-border, byte-regression,
   measure/pick sync, `_hidden` filter parity) is modest. If appetite for risk is
   low, "accept pick for navigation, leave ls a pure read-only view" is a
   defensible call. At minimum, weigh it before committing.

**Bottom line:** do (c), but as **(c′)** — ADD don't REFACTOR, `--border=none`,
measure≡pick, full fallback matrix, blocking live nav test. The plan as written
ships a double-border, invites an S1 byte-regression, and under-specifies the
non-interactive fallback — all avoidable with the guards above.

# SYNTHESIS — d5 / ls-popup-navigate

**Verdict: BUILD** option (c), implemented as **(c′)** — the stricter "ADD, don't
REFACTOR" variant the CON adviser argued for, with the three cheap VALUE additions
folded in. All three advisers agree (c) is the right shape; the debate's real output
is a set of **required implementation guards** and a short list of **cheap wins**.

PRO verified every reuse claim in PLAN.md against `bin/fleet` — sizer
(`popup_fit_content` :2820), the `display-popup -E` nav precedent (pick :2709,
sessions :2850), cmd_pick's `switch-client`+`select-window` (:283-284), the
`_hidden` drop (:270), `sessions_rows` one-builder-two-faces (:2554-2581), the
no-fzf/no-tty fallback (:2599-2602), `hold_wait`/zsh-read minefield (:211-219).
None overstated. The feature is "reroute `ls` onto rails `sessions` already rides."

## Required guards (fold into the plan — these are blocking)

1. **ADD, don't REFACTOR (CON R2 — protects the S1 byte-for-byte guarantee).**
   Leave the static print path (`:248-257`) and its `sort -k1,1` **100% untouched**.
   Write a *separate* small row-builder for `--pick`/`--measure` (it needs only
   `$3` session, `$4` window_id, a display string). Do NOT force one awk to emit
   both faces — they differ in sort, spacing, decoration, and field count
   (daemon-up 9 fields vs daemon-down 7). Less DRY, zero risk to S1.

2. **`--border=none`, not cmd_pick's `--border=rounded` (CON R1 + VALUE).** The
   leader `ls` popup is sized by `popup_fit_content` which already draws a rounded
   border (:2850) with only +4col/+2row budget. Copy **cmd_sessions** (`--border=none`,
   :2605), NOT cmd_pick — otherwise a double border truncates the rightmost column.

3. **`--measure` ≡ `--pick` minus fzf (CON R4).** Same builder, same `_hidden`
   drop, same scope, same sort, + 2 chrome placeholder lines (mirror cmd_sessions
   --measure :2591-2596). If the two faces diverge, the popup is sized for rows the
   user never sees → truncation/scroll.

4. **Full 4-cell tty×agents fallback matrix (CON R3 — the hard guarantee).**
   Gate fzf on `--pick && [ -t 0 ] && [ -t 1 ]`.
   - tty + agents → fzf → navigate
   - tty + empty → print msg + **hold_wait** (don't flash under -E)
   - non-tty + anything → print static + **plain `return 0`** (NEVER hold — else
     `fleet ls --pick | cat` hangs on a tty read, the exact forbidden breakage)

## Cheap value-adds folded into v1 (VALUE adviser)

5. **fzf `--header`** with the column labels + `↵ jump · esc cancel` hint. One
   flag. Without it the richer columns are unlabelled and the new interactivity is
   invisible (popup used to be press-any-key-to-close). Highest value/cost ratio.

6. **Attention-first sort in `--pick` only** — reuse pick's priority key
   (blocked=0/idle=1/working=2, :271-275). Leave the static print's alphabetical
   sort byte-for-byte unchanged. Copy-paste, ~0 new code.

7. **Hold on empty/no-agent** under -E (already in PLAN; both PRO & VALUE endorse).

8. **Doc the `a` vs `l` split** in CLAUDE.md/FLEET.md: `a`=pick = fast server-wide
   jump (flat); `l`=ls = this-project jump with full STATE/AGENT/WINDOW/IN-STATE +
   done/ready status; mental model `o`(session)→`a`/`l`(window). Prose only.

## Deferred / rejected

- **Preview pane** (`tmux capture-pane`): real value but forfeits fit-content
  sizing (preview window breaks the row/col measure) → would force a fixed-size
  popup. **Defer to a separate PR.**
- **`ctrl-a` --all toggle** via fzf `reload`: optional; server-wide is already one
  key away on `a`. Only if near-free. Not v1.
- **Per-row send/mode verbs, multi-select**: **REJECT** — contradicts fleet's
  stated design ("per-agent verbs live on the dashboard row, not the leader") and
  multi-select has no meaning for a single-jump picker.

## Proof design (from PLAN §5, with CON's elevation)

Keep all of PLAN §5's checks. **Elevate live check #8 to a BLOCKING gate**: the
exact combination ls needs — `switch-client` **and** `select-window` from a
*sizer-launched* `display-popup -E` — is proven by neither precedent end-to-end,
only by composition (sessions proves switch-client-from-sizer; pick proves
switch+select from a direct popup). Must verify live in a throwaway `tmux -L`
socket. All runtime checks under `FLEET_SESSION`/dedicated socket — never `pc`.

**Scope:** Small→medium feature, **one file** (`bin/fleet`) + doc prose. No daemon/
hook/dash/nvim change. Merge target: `main`.

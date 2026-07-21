# PLAN — style the dashboard MSGS / inbox TRIAGE view (pill language)

**Scope:** `bin/fleet-dash` only — the `render_inbox()` function and its header
helper. Bring the message list (triage `IALL`, per-agent `e`-view, orphan/system
scopes) into the same pill-based visual language the agents view + orchestrator
cards already use. **No change to `bin/fleet`'s CLI inbox** (`inbox_list` /
`inbox_read`) — that styling already shipped and must stay byte-identical.

---

## 1. Where the code lives (cite)

| Thing | Location |
|---|---|
| Triage/msg/e-view renderer (ALL three scopes) | `bin/fleet-dash:1070` `render_inbox()` |
| Row format string (the plain `[sev]` row) | `bin/fleet-dash:1122`–`1161` |
| Triage header string | `bin/fleet-dash:719` `triage_header()` |
| Non-triage header (`MSGS · scope · N`) | `bin/fleet-dash:1083`–`1092` |
| Empty-state ("inbox empty", centred) | `bin/fleet-dash:1101`–`1112` |
| Bottom hint line | `bin/fleet-dash:1168`–`1173` |
| `IROWS` / `IN` / `isel` data | `bin/fleet-dash:614`–`645` `load_inbox()` |
| `MARKED` set (triage marks) | `bin/fleet-dash:50`, `730`–`735` |

### Helpers to REUSE (already in tree — do not reinvent)

| Helper | Line | Use |
|---|---|---|
| `pill <text> <col256>` | `bin/fleet-dash:257` | the rounded capsule (display width `PILL_W+4`=11) |
| `pill_center` | `:250` | centres/truncates text to `PILL_W`=7 chars (glyph-safe) |
| `sev_pcol <sev>` | `:536` | sev → pill colour: **blocked=1 (red), warn=3 (yellow), info/`*`=6 (cyan)** |
| `sev_max` | `:534` | fold severities (already used by index) |
| `fit_left <s> <w>` | `:105` | char-aware left-fit/ellipsis for the title |
| `fmt_age` | `:606` | seconds → `5s/3m/2h/4d` |
| `PILL_W=7 / PILL_GAP=3` | `:246`–`248` | the fixed pill width + inter-item gap the agents view uses |
| `ibx_field` | `:521` | read `sev`/`from`/`title` from a `.msg` |

The agents view's own `✉N` pill already proves the join: `bin/fleet-dash:979`
`pill "✉$iunread" "$(sev_pcol "${MAXSEV[$wname]:-}")"`. The inbox rows should use
the **same** `sev_pcol` mapping so a `[blocked]` row and a red `✉` agent pill are
the same red.

---

## 2. The exact change

### 2a. Severity: text token → pill badge

**Today** (`:1131`–`1132`):
```
sevf=$(printf '[%s]' "$sev")
sevtxt=$(printf '%s%-*.*s\033[0m' "$(sev_color "$sev")" "$SEVW" "$SEVW" "$sevf")
```
`sev_color` tints the literal text `[warn]` (and renders **info as dim**, not a
colour). Replace with a fixed-width pill:
```
sevtxt=$(pill "$sev" "$(sev_pcol "$sev")")     # display width PW = PILL_W+4 = 11
```
`pill_center` already truncates to 7 chars — `blocked`(7)/`warn`(4)/`info`(4) all
fit; the capsule is a constant 11 cols regardless. Drop `SEVW`, `sevf`.

> **Consequence to flag for debate:** `info` flips from *dim grey text* to a
> *cyan capsule*. This is the whole point (unify with the agents `✉` pill), but
> it makes info rows louder than they are in the CLI peek. Mitigation option in
> §6.

### 2b. Marker column — keep, but align with the agents-view marker bar

The leading slot stays a single display col **outside** the pill:
- per-agent / orphan / system view: constant `*` (dim) — or drop it entirely,
  since archive-as-truth means *every* listed msg is unread (the `*` is pure
  noise; the agents view has no such marker). **Recommend: drop `*` in the
  non-triage views**, keep the col only for triage's select marker.
- triage (`IALL`): `◉` bright-green when marked (`MARKED[$f]`), `·` dim when not
  — already at `:1135`–`1138`. Keep verbatim.

The focus-coloured `▌` selection bar (`markc`, `:1154`–`1156`) is already shared
with the agents view — leave it.

### 2c. Sender + age columns (already present, keep aligned)

`from` (only in `showfrom` scopes: triage/orphan/system, `:1118`) and the
right-aligned `age` (`:1150`) stay. System senders stay dimmed (`:1143`–`1144`),
mirroring the CLI peek (`fleet:1811`). Title stays default-weight via `fit_left`,
bold only on the selected row (`lblsgr`, `:1151`).

### 2d. Alignment math (the load-bearing part)

Content width must stay **exactly `cw`** so the right rail (`│`) never wobbles —
same invariant as the agents view (`:957`, "Content width is kept exactly = cw").

Define, mirroring the agents view's `PW`/`G`:
```
PW=$(( PILL_W + 4 ))      # 11 — the sev pill
G=1                       # inbox gap (denser than agents' PILL_GAP=3; see debate)
MARK=1                    # leading marker/select col + its trailing space
FROMW=14  AGEW=5          # unchanged
```
Row = `mark(1) sp(1)` + `pill(PW)` + `sp(G)` + `[from(FROMW) sp(G)]` + `title(LW)`
+ `sp(G) age(AGEW)`.

Fixed cost:
- `base = MARK + 1 + PW + G + (showfrom ? FROMW + G : 0) + G + AGEW`
- `LW = cw - base`; clamp as today: if `LW < 1` drop age (`ageshow=0`, reclaim
  `AGEW + G`), then clamp `LW` to ≥0 (`:1128`–`1130`).

Because the pill carries embedded SGR of variable **byte** length but fixed
**display** width, it must be captured into `sevtxt` and emitted with plain `%s`
(never `%-*s`), exactly as the agents view does — the width is implicit in
`pill_center`. This is already the pattern at `:1132`/`:1152`; we keep it.

> The agents view uses `G=PILL_GAP=3`. The inbox has four columns
> (pill·from·title·age) competing for a narrow right pane, so `G=1` keeps the
> title readable. **Open question for debate:** match `G=3` for visual identity
> vs `G=1` for density. Recommend `G=1` (or `G=2`) — flagged.

### 2e. Header polish (`triage_header` + non-triage header)

- Keep `triage_header()` text-only **but** the surrounding `hrule` is already dim
  (`:1093`). Optionally tint the `N marked` counter green when `>0` and the
  `changed—r` flag yellow — small, low-risk, mirrors the marker colour. Header is
  built render-free + unit-testable, so do tinting in `render_inbox` at the
  `hrule` call, not inside `triage_header` (keep it pure).
- Non-triage header `MSGS · scope · N` (`:1091`): leave as-is; it already names
  the scope. Could add a sev-coloured count, but low value.

---

## 3. What the CLI inbox styling did that we mirror

From `bin/fleet:1744`–`1861`:
1. **Only the `[sev]` token carries colour**, rest is structural (CLI). In the
   dash we go further — a *pill* not a tinted token — but the **colour source is
   the same severity**.
2. **System/orchestrator senders dimmed** (`inbox_from_is_system`) so worker
   pleas stand out — dash already does this (`:1143`). Keep.
3. **Age as a dim right-aligned column** — dash already right-aligns (`:1150`);
   it is not dimmed today. Optionally dim it to match the CLI (`fleet:1821`).
4. **Bold title as the one bright anchor** (`inbox_read`, `fleet:1856`) — dash
   bolds the *selected* title only; that's the TUI-correct analogue (selection is
   the anchor, not every title). Keep.
5. `sev_color`/`fmt_age` are explicitly "byte-for-byte mirror, keep in sync"
   (`fleet:1749`, `:1755`). We are NOT touching `sev_color` — we switch the dash
   to `sev_pcol` (pills), which has no CLI counterpart, so no sync burden is
   added. `sev_color` stays defined in the dash (`:532`) for any other caller.

---

## 4. Touch-points (precise)

1. `render_inbox` `:1117` — drop `SEVW=9`; add `PW`, `G`, `MARK` locals.
2. `render_inbox` `:1119` — recompute `base` (33/18 → new pill-based values).
3. `render_inbox` `:1131`–`1132` — replace `sevf`/`sevtxt` with the `pill` call.
4. `render_inbox` `:1133`–`1138` — marker: drop `*` in non-triage scopes (set
   `mk=""` + no leading space when `!IALL`), keep `◉`/`·` for triage.
5. `render_inbox` `:1152` — adjust the `content` format string for the (possibly
   absent) marker + pill spacing.
6. *(optional)* `:1150` — dim age; `:1093` — tint marked-counter in header.

No changes to `load_inbox`, `triage_header` body, `MARKED`, key handling, or any
`bin/fleet` code.

---

## 5. Edge cases

| Case | Handling |
|---|---|
| **Long body/title** | `fit_left` already ellipsises to `LW` (char-aware). Unchanged. |
| **0 msgs** | centred "inbox empty" (`:1101`). Unchanged — no pills drawn. |
| **Marked rows** | `◉` (bright green) vs `·` (dim) at `:1137`. Selected+marked = `▌` bar + `◉` + bold title. Verify the two greens (markc `1;32` vs `◉` `1;32`) don't clash — same code, fine. |
| **Empty `sev`** | `.msg` always has `sev=info\|warn\|blocked` (normalised at `fleet:1682`). If somehow empty: `sev_pcol ""` → 6 (cyan), `pill_center ""` → 7 spaces = blank cyan capsule. Acceptable; note it. |
| **⌫ orphans / ⚙ system buckets** | These are *agents-view* rows (`:1010`–`1050`), already pill-styled. They open render_inbox with `IORPHAN`/`ISYSTEM` → `showfrom=1`; the new sev pills apply uniformly. |
| **oldest↑/newest↓ header** | `triage_header` (`:719`) unchanged; only optional counter tint added at call site. Sort logic (`load_inbox:623`) untouched. |
| **blocked vs warn vs info colour** | `sev_pcol`: 1/3/6. Identical to the agents `✉` pill — visual consistency guaranteed by reuse. |
| **NO_COLOR / non-TTY** | The **dash is a full-screen TUI on the alternate screen** — it is *already* unconditionally coloured (agents view, cards, pills all assume colour + a Nerd Font). It does **not** consult NO_COLOR today, and this change does not regress that. NO_COLOR / non-TTY correctness lives entirely in the **CLI** path (`fleet:inbox_color_on`), which we do not touch. The only "fallback" the dash has is **width-driven column dropping** (§2d), not colour. |
| **Narrow pane** | Existing drop ladder: age → (already minimal). Pill is wider than the old 9-col token by 2 cols, so the title gets 2 fewer cols at a given width — acceptable; `LW` clamp prevents rail breakage. |
| **Nerd Font absent** | `PILL_L`/`PILL_R` (`:244`) render as tofu — but this is *already true* for the entire dashboard, so no new regression. Out of scope. |

---

## 6. Risks

- **R1 — info loudness.** Info pills (cyan) are visually heavy for routine
  summaries that the CLI shows as dim. *Mitigation:* use pill colour `8` (grey,
  same as default/idle pills `state_pcol :265`) for info instead of cyan `6`,
  reserving cyan/yellow/red for warn+. Decide in debate. (Note `sev_pcol` is
  *shared with the agents `✉` pill*, so changing it changes both — either change
  both intentionally or branch a dash-inbox-local colour.)
- **R2 — alignment drift.** The pill's variable byte length must never reach a
  `%-*s` width count. Guard: capture pill into a var, emit with `%s`. Covered by
  proof frames (right rail column-check).
- **R3 — width budget.** +2 cols vs the old token in an already-narrow right
  pane. Covered by the narrow-pane proof frame.
- **R4 — `sev_pcol` sync.** It currently has only one caller pattern; reusing it
  in the list is fine, but if R1 forks a colour we add a second mapping to keep
  straight. Prefer not to fork.
- **R5 — perf on refresh.** `render_inbox` runs every refresh (1s idle). `pill`
  is pure bash string-building (no subshell beyond the existing `$()` capture) —
  same cost class as the current `sev_color` capture. `IN` is bounded by the live
  inbox (≤ `INBOX_KEEP`=200, and only `slots` rows are drawn). Negligible. The
  expensive sweep is gated elsewhere (`load_inbox_index` THE GATE, `:557`).

---

## 7. Open questions for the debate

1. **Gap width:** `G=1` (density) vs `G=3` (identity with agents view)?
2. **Info colour:** cyan `6` (loud, unified) vs grey `8` (calm, CLI-like)?
   Fork `sev_pcol` or change it globally (agents `✉` too)?
3. **Drop the `*` marker** in non-triage views (recommended) or keep it?
4. **Dim the age column** to match the CLI peek, or leave default?
5. **Tint the triage `N marked` counter** in the header, or keep plain?
6. Is a pill the right primitive at all for a dense *list* (vs the agents view's
   *sparse* rows), or does a tinted-token-but-aligned approach read better here?

---

## 8. PROOF DESIGN — how to prove it with NO test runner

There is no test runner (`CLAUDE.md` "No build, no test suite"). Proof is by
**tmux `capture-pane` frames** of the dash driven with synthetic `.msg` files,
plus a byte-diff of the untouched CLI path.

### 8a. Synthetic fixtures

Write fake messages into a throwaway inbox and point the dash at it (the dash
resolves the inbox via `dash_root` → `@fleet_root`/`FLEET_ROOT`, `:285`). Each
`.msg` is `key=value` header, `--`, body (`fleet:1700`-ish format). Cover every
severity + a system sender + a long title:

```sh
ID=$(date +%s); D=$FLEET_DOCS/proof-inbox/.fleet/inbox; mkdir -p "$D"
mk(){ printf 'from=%s\nsev=%s\ndispatch=-\nts=%s\ntitle=%s\n--\n%s\n' \
      "$2" "$3" "$(date -Is)" "$4" "$5" > "$D/$ID.$RANDOM.%pane.msg"; }
mk 1 so-d11   blocked "agent blocked on human: need creds"  "body"
mk 2 so-d11   warn    "tests failing on CI after rebase"     "body"
mk 3 worker-x info    "summary: refactor landed, 3 files"    "body"
mk 4 main     info    "gate: phase 2 approved"               "body"   # system → dim
mk 5 worker-y warn    "VERY long title ........................ that must ellipsise cleanly at the title width boundary" "body"
```
(Use distinct epoch.nanos so the sort is stable; vary the `%pane` suffix.)

### 8b. Frames to capture (the actual proof)

Launch the dash against the proof root in a detached tmux session, drive keys,
`capture-pane -p -e` (with `-e` to keep SGR so colour is verifiable), save each
frame to `$FLEET_DOCS/frames/`:

```sh
S=proofdash
tmux new-session -d -s $S -x 120 -y 40
tmux set -t $S @fleet_root "$FLEET_DOCS/proof-inbox"
tmux send-keys -t $S "FLEET_ROOT=$FLEET_DOCS/proof-inbox bin/fleet-dash $S" Enter
sleep 1
tmux send-keys -t $S t                      # open triage
sleep 1; tmux capture-pane -p -e -t $S > frames/01-triage-all-sev.txt
tmux send-keys -t $S Space; tmux send-keys -t $S j; tmux send-keys -t $S Space
sleep 1; tmux capture-pane -p -e -t $S > frames/02-triage-marked.txt
tmux send-keys -t $S o                      # flip sort newest↓
sleep 1; tmux capture-pane -p -e -t $S > frames/03-triage-newest.txt
tmux send-keys -t $S q                       # back to agents
tmux send-keys -t $S e                       # per-agent e-view (if a row has msgs)
sleep 1; tmux capture-pane -p -e -t $S > frames/04-eview.txt
# empty state: archive all, reopen triage
tmux send-keys -t $S q; tmux send-keys -t $S t; tmux send-keys -t $S c
sleep 1; tmux capture-pane -p -e -t $S > frames/05-empty.txt
# narrow pane: resize and recapture triage
tmux resize-window -t $S -x 70 -y 40; tmux send-keys -t $S r
sleep 1; tmux capture-pane -p -e -t $S > frames/06-narrow.txt
tmux kill-session -t $S
```

**Pass criteria, checked per frame:**
- `01` — three sev pills visible: a **red** `blocked`, **yellow** `warn`, **cyan
  (or grey, per R1)** `info` capsule; `main` sender row dimmed; age column right-
  aligned; the right rail `│` is in the **same column on every row** (the
  alignment invariant — grep each line for the trailing `│` position).
- `02` — one row shows `◉` (bright green), counter `1 marked` in header.
- `03` — order reversed, header shows `newest↓`.
- `04` — per-agent view: no `from` column, no `*` marker (if §2b adopted), sev
  pills present, title fills the freed width.
- `05` — centred "inbox empty", no stray pills/rails.
- `06` — at 70 cols the rail still aligns; age column dropped if it must, no
  wrap/scroll.

Verify colour with `grep -c $'\033\[38;5;1m' frames/01-*.txt` (red pill fg) etc.,
and rail alignment with an `awk` that asserts every content line's last `│` is at
the same byte/display column.

### 8c. Zero-regression check of the non-styled (CLI) fallback

The dash has no non-colour mode, but the **CLI inbox is the path with NO_COLOR /
non-TTY semantics**, and we must prove we did **not** touch it:

```sh
# before the change (git stash / worktree at HEAD) and after — must be identical:
NO_COLOR=1 bin/fleet inbox list   > /tmp/cli-nocolor.after
FLEET_INBOX_COLOR=always bin/fleet inbox list | cat -v > /tmp/cli-color.after
bin/fleet inbox read all          > /tmp/cli-read.after
git stash; # (or compare against a HEAD checkout)
#  ...rerun the three into .before, then:
diff /tmp/cli-*.before /tmp/cli-*.after      # expect EMPTY (no CLI change)
```
Plus `git diff --stat` must show **only `bin/fleet-dash`** changed — proving the
CLI styling is untouched (the strongest zero-regression signal). And the dash's
own non-pill paths (empty state, narrow-drop) are covered by frames `05`/`06`.

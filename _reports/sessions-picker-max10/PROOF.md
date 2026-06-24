# Fix: leader "sessions" switcher popup — cramped / one-row-visible

## Root cause (diagnosed with evidence, not guessed)

The popup is sized by `popup_fit_content`, which captures the measure output with
`content=$(eval "$measure_cmd")`. **Command substitution strips trailing
newlines.** `cmd_sessions --measure` ended its chrome with `printf 'fleet session> \n\n'`
— the final line is **blank**, so `$()` ate it. Effect: the sizer counted one
fewer line than intended, the popup came up **one interior row too short**, and
fzf clipped the list.

Chain (old code), N sessions:
- measure emits: N data + `fleet session> ` + blank  → N+2 lines, but blank stripped → **N+1 counted**
- `popup_fit_content`: rows = (N+1) + 2 = N+3 → `display-popup -h N+3`
- rounded border consumes 2 → fzf interior = **N+1**
- fzf chrome (prompt + info) = 2 → list area = **N−1**
- For **N=2 → 1 visible row** = the reported "only the highlighted session + the N/N count".

### Evidence

Command substitution strips the blank:
```
$ out=$(printf 'a\nb\nfleet session> \n\n'); printf '%s' "$out" | grep -c ''
3        # expected 4 — trailing blank eaten
```

fzf rendering at the height the OLD code actually produced (interior = N+1),
via a throwaway tmux pane of exact height + `capture-pane` (fzftest.sh):
```
interior H=3, N=2  -> visible data rows: 1     <-- reproduces the bug exactly
interior H=4, N=3  -> visible data rows: 2
interior H=6, N=5  -> visible data rows: 4
```

(Bare fzf at the *intended* height interior=N+2 always showed all N — proving the
fault was the height math, not fzf: `interior 7,N=5 -> 5`; `interior 4,N=2 -> 2`.)

## Fix (bin/fleet, `cmd_sessions` + new `SESSIONS_MAX_ROWS=10`)

1. **Cap visible rows at 10.** `--measure` emits at most 10 data rows
   (`head -n "$SESSIONS_MAX_ROWS"`); ≤10 sessions → all shown, >10 → a 10-row
   window, the rest scroll inside fzf. Capping in `--measure` keeps the sizer and
   the interactive picker in lockstep.
2. **Non-blank chrome lines.** Replaced `'fleet session> \n\n'` with
   `'fleet session>\n  --\n'` — two non-blank lines, so `$()` cannot strip the
   last one. Sizer now counts min(N,10)+2 → popup `-h` = min(N,10)+4 →
   interior = min(N,10)+2 → fzf list = min(N,10). No clipping.
3. **`--layout=reverse`** on the interactive fzf (prompt+list at top, rows read
   top-down, predictable). Kept `--height=100%` (popup is pre-sized to the
   window) and `--border=none` (no double border inside the rounded popup).
4. Width fit + proportional fallback unchanged. Non-tty/no-fzf fallthrough still
   lists **all** sessions plainly (informational `fleet sessions | cat`); ≤1
   session short-circuit unchanged.

## Verification

### Real chain: actual `fleet sessions --measure` (against fake tmux servers, TMUX
inherited so fleet's tmux calls target them) fed through the real
`popup_fit_content` arithmetic:
```
N=2   -> measure: 2 data + 'fleet session>' + '  --'   popup -h=6  interior_h=4
N=5   -> measure: 5 data + chrome                      popup -h=9  interior_h=7
N=10  -> measure: 10 data + chrome                     popup -h=14 interior_h=12
N=15  -> measure: 10 data (CAPPED) + chrome            popup -h=14 interior_h=12
```
Chrome lines present & non-blank → nothing stripped. interior_h = min(N,10)+2.

### fzf renders min(N,10) at those exact interiors (throwaway tmux pane +
capture-pane, new flags `--height=100% --border=none --layout=reverse`):
```
N=2  interior=4   -> visible data rows: 2    (all)
N=5  interior=7   -> visible data rows: 5    (all)
N=10 interior=12  -> visible data rows: 10   (all)
N=15 interior=12  -> visible data rows: 10   (capped, remaining 5 scroll)
```

### Other paths
```
$ bash -n bin/fleet                 -> OK: bin/fleet parses
$ ./bin/fleet sessions | cat        -> lists all sessions plainly (non-tty)
1-session fake server               -> "only one open fleet session ... nothing to switch to"
```

## Cases tried
N = 1 (short-circuit), 2, 3, 5, 10 (cap boundary), 12, 15 (over cap) — plus the
non-tty pipe path and `bash -n`. All match: ≤10 show all, >10 show a scrolling
10-row window, full min(N,10) rows always visible (no clipping).

#!/usr/bin/env bash
# Proof 3 (d32) — the other half of the ask: a parked agent is off the tmux
# status bar AND unreachable by next/prev.
#
# Checked STRUCTURALLY (which session owns the window) rather than by scraping
# rendered bar text: the bar draws the windows of the session you are looking at,
# so "not in list-windows -t <visible session>" IS "not on the bar", and it does
# not depend on theme, width, or the status format fleetd heals.
#
# Case 4 is the one that kills the rejected alternative: a
# `window-status-format` conditional would omit the window from the BAR while
# leaving `C-b n` walking straight into it. tmux has no per-window
# skip-in-next/prev flag — living in another session is the only mechanism that
# delivers non-navigability, which is the entire reason parking exists.
set -u
. "$(cd "$(dirname "$0")" && pwd)/hidden-proof-common.sh"
proof_isolate
proof_session t1

tmux new-window -d -t t1 -n alpha sh 2>/dev/null
tmux new-window -d -t t1 -n beta  sh 2>/dev/null
"$FLEET" new --scratch parked >/dev/null 2>&1
wait_window parked || { no 'parked scratch agent never spawned'; proof_summary; }
# ...and a child from inside it, so the assertions cover the nesting path too.
sleep 0.5
in_pane "$(pane_of parked)" "'$FLEET' new --scratch parked2" >/dev/null 2>&1 || true
wait_window parked2 || no 'parked2 never spawned'

section 'case 1 — parked windows are not in the visible session'
WINS=$(tmux list-windows -t '=t1' -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' ')
chk 'visible session window list' 'alpha beta main ' "$WINS"

section 'case 2 — the bar format render omits them'
BAR=$(tmux display -p -t t1 '#{W:#{window_name} }' 2>/dev/null)
case " $BAR " in *" parked "*) no 'parked appears in the rendered bar' ;;
                 *) ok 'parked absent from the rendered bar' ;; esac
case " $BAR " in *" parked2 "*) no 'parked2 appears in the rendered bar' ;;
                 *) ok 'parked2 absent from the rendered bar' ;; esac
case " $BAR " in *" alpha "*) ok 'a normal window still renders in the bar' ;;
                 *) no "normal window missing from the bar: '$BAR'" ;; esac

section 'case 3 — visible-session agents still render (no collateral hiding)'
chk 'three visible windows' '3' \
    "$(tmux list-windows -t '=t1' -F '#{window_id}' 2>/dev/null | grep -c . || true)"

section 'case 4 — next-window never walks into a parked pane'
tmux select-window -t 't1:main' 2>/dev/null
VISITED=""
for _ in 1 2 3 4 5 6; do
  VISITED="$VISITED $(tmux display -p -t t1 '#{window_name}' 2>/dev/null)"
  tmux next-window -t '=t1' 2>/dev/null || true
done
case "$VISITED" in *parked*) no "next-window reached a parked window:$VISITED" ;;
                   *)        ok "next-window stayed on the visible windows:$VISITED" ;; esac

section 'case 5 — the rejected approach was NOT quietly adopted'
# A per-window window-status-format override survives a global rewrite and stays
# blank even after the window is surfaced (the design note at bin/fleet:1368).
# Setting one anywhere would be the format-conditional approach sneaking in.
LEAK=0
while IFS= read -r w; do
  [ -n "$(tmux show -w -t "$w" -v window-status-format 2>/dev/null)" ] && LEAK=$((LEAK+1))
done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null)
chk 'no per-window window-status-format override set anywhere' '0' "$LEAK"

proof_summary

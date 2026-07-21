#!/usr/bin/env bash
# TDD scenario harness for the `fleet ls` interactive picker (--pick/--measure).
#
#   ls_pick_test.sh <path-to-bin/fleet>
#
# Runs every runtime check in a THROWAWAY tmux server (`tmux -L lsnavtest`) with
# a scratch FLEET_SESSION=sbx and an empty XDG_RUNTIME_DIR (so `rpc fleet.list`
# fails and agents_tsv uses the daemon-down `@agent_state` fallback). The live
# `pc` session is never touched.
#
# Exit 0 iff every check passes (GREEN). Against a pristine bin/fleet the new
# checks fail (RED), proving the behaviour is absent.
set -u
SELF="${1:?usage: ls_pick_test.sh <bin/fleet>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
SOCKET=lsnavtest
XDGEMPTY="$(mktemp -d /tmp/lsnav-xdg.XXXXXX)"   # no fleet.sock -> daemon-down

pass=0; fail=0
ok(){   printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){   printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
chk(){  # chk "name" condition-rc
  if [ "$2" -eq 0 ]; then ok "$1"; else no "$1"; fi
}

# ---- setup throwaway server + fake agents ------------------------------------
tmux -L "$SOCKET" kill-server 2>/dev/null
tmux -L "$SOCKET" new-session -d -s sbx -x 200 -y 50
tmux -L "$SOCKET" new-window  -t sbx: -n repoA_feat
tmux -L "$SOCKET" new-window  -t sbx: -n repoB_fix
tmux -L "$SOCKET" new-window  -t sbx: -n repoC_idle
# a parked-scratch sibling session "<sess>_hidden" with one agent window
tmux -L "$SOCKET" new-session -d -s sbx_hidden -x 200 -y 50
tmux -L "$SOCKET" new-window  -t sbx_hidden: -n scratchpad
SP=$(tmux -L "$SOCKET" display -p '#{socket_path}')

setstate(){ # setstate <sess:win> <state>
  local p
  for p in $(tmux -L "$SOCKET" list-panes -t "$1" -F '#{pane_id}'); do
    tmux -L "$SOCKET" set -p -t "$p" @agent_state "$2"
  done
}
setstate sbx:repoA_feat blocked
setstate sbx:repoB_fix  working
setstate sbx:repoC_idle idle
setstate sbx_hidden:scratchpad idle

winid(){ tmux -L "$SOCKET" list-windows -t sbx -F '#{window_name} #{window_id}' | awk -v n="$1" '$1==n{print $2}'; }
WA=$(winid repoA_feat); WB=$(winid repoB_fix); WC=$(winid repoC_idle)
active_win(){ tmux -L "$SOCKET" list-windows -t sbx -F '#{window_active} #{window_id}' | awk '$1==1{print $2}'; }
reset_active(){ TMUX="$SP,0,0" tmux select-window -t "$WA" 2>/dev/null; }

run_fleet(){ TMUX="$SP,0,0" XDG_RUNTIME_DIR="$XDGEMPTY" FLEET_SESSION=sbx "$SELF" "$@"; }
pick_filter(){ # $1 = fzf --filter query; drives --pick under a real pty
  python3 "$DIR/ptyrun.py" env "TMUX=$SP,0,0" "XDG_RUNTIME_DIR=$XDGEMPTY" \
    FLEET_SESSION=sbx "FZF_DEFAULT_OPTS=--filter=$1" "$SELF" ls --pick
}

echo "== SELF=$SELF =="
echo "== windows: A=$WA(blocked) B=$WB(working) C=$WC(idle) =="

# ---- A. non-interactive paths (must stay unchanged) --------------------------
# Capture the static `ls` for the empty-diff keystone (compared by the driver).
run_fleet ls > "$XDGEMPTY/ls-static.out" 2>/dev/null
cp "$XDGEMPTY/ls-static.out" "${LS_STATIC_OUT:-/dev/null}" 2>/dev/null || true

# static print SHOWS *_hidden scratch (scope keeps "<sess>_hidden")
grep -q 'sbx_hidden:scratchpad' "$XDGEMPTY/ls-static.out"; chk "static print lists *_hidden agent" $?

# ---- measure: pure-text sizer face -------------------------------------------
MEAS=$(run_fleet ls --measure 2>/dev/null)
# NEW behaviour: --measure is the picker face, NOT the static table -> the
# tab-separated static header must be ABSENT.
printf '%s\n' "$MEAS" | grep -qP '^STATE\tAGENT\tWINDOW\tIN-STATE'
if [ $? -ne 0 ]; then ok "--measure is not the static table (no tab header)"; else no "--measure is not the static table (no tab header)"; fi
# NEW: --measure carries the fzf prompt chrome line
printf '%s\n' "$MEAS" | grep -q 'agent>'; chk "--measure emits fzf prompt chrome line" $?
# --measure DROPS *_hidden (no teleport target in the sized rows)
printf '%s\n' "$MEAS" | grep -q 'scratchpad'
if [ $? -ne 0 ]; then ok "--measure drops *_hidden rows"; else no "--measure drops *_hidden rows"; fi
# --measure exits 0 and does not hang
timeout 5 bash -c 'true'; run_fleet ls --measure >/dev/null 2>&1; chk "--measure exits 0" $?

# piped --pick must NOT hang and must NOT launch fzf (non-tty fallback)
OUT=$(timeout 5 bash -c "TMUX='$SP,0,0' XDG_RUNTIME_DIR='$XDGEMPTY' FLEET_SESSION=sbx '$SELF' ls --pick </dev/null" 2>/dev/null); rc=$?
chk "ls --pick piped/non-tty returns (no hang)" $([ $rc -ne 124 ] && echo 0 || echo 1)
printf '%s\n' "$OUT" | grep -q 'repoB_fix'; chk "ls --pick non-tty falls back to printed rows" $?

# ---- B. interactive navigation (the new behaviour) ---------------------------
# pick an agent -> jump to its window (same session, select-window)
reset_active
pick_filter 'repoC_idle' >/dev/null 2>&1
got=$(active_win)
chk "picking repoC_idle navigates to its window ($got==$WC)" $([ "$got" = "$WC" ] && echo 0 || echo 1)
# prove it is the selection, not a fixed target: pick the other one
reset_active
pick_filter 'repoB_fix' >/dev/null 2>&1
got=$(active_win)
chk "picking repoB_fix navigates to its window ($got==$WB)" $([ "$got" = "$WB" ] && echo 0 || echo 1)
# *_hidden is never a navigation target: filter matches nothing -> no nav
reset_active
pick_filter 'scratchpad' >/dev/null 2>&1
got=$(active_win)
chk "*_hidden agent is not selectable (active stays $WA)" $([ "$got" = "$WA" ] && echo 0 || echo 1)
# cancel (no fzf match anywhere) is inert
reset_active
pick_filter 'zzz-nomatch-zzz' >/dev/null 2>&1
got=$(active_win)
chk "no-match pick is inert (active stays $WA)" $([ "$got" = "$WA" ] && echo 0 || echo 1)

# ---- C. health ---------------------------------------------------------------
run_fleet doctor 2>/dev/null | grep -qi 'ok.*fzf'; chk "fleet doctor reports ok fzf" $?

echo "== $pass passed, $fail failed =="
tmux -L "$SOCKET" kill-server 2>/dev/null
rm -rf "$XDGEMPTY"
[ "$fail" -eq 0 ]

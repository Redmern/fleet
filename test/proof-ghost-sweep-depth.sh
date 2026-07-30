#!/usr/bin/env bash
# Proof 7 (d32) — `fleet up`'s ghost-parking-session sweep must reach EVERY depth.
#
# Context: tmux-continuum/resurrect can restore a GHOST "<name>_hidden" session of
# dead shells; `fleet up` sweeps it before booting, recognising a live one by
# @fleet_harness being stamped on a window. Before d32 that sweep tested exactly
# one name, so a nested "<name>_hidden_hidden" — which pre-fix sub-orch spawns
# created, and which tmux then orphaned the moment the depth-1 parent lost its
# last window — was never swept and lingered indefinitely (one sat around for a
# week on the live machine).
#
# Two halves, both exercised against the REAL source:
#   A. the depth classifier (extracted between the `# >>> d32:sweepawk` markers in
#      bin/fleet) selects <name> plus one-or-more "_hidden" suffixes and NOTHING
#      else — in particular never the visible session itself, never another
#      project, and never a near-miss like "<name>_hiddenX".
#   B. end to end on a throwaway tmux server: a harness-less nested ghost is
#      killed, while a nested session that still carries @fleet_harness (a live
#      parked agent) is REFUSED — the sweep must never destroy running work.
set -u
. "$(cd "$(dirname "$0")" && pwd)/hidden-proof-common.sh"
proof_isolate

section 'part A — the depth classifier, extracted from bin/fleet'
AWKP=$(sed -n '/# >>> d32:sweepawk/,/# <<< d32:sweepawk/p' "$FLEET_REPO/bin/fleet")
if [ -z "$AWKP" ]; then
  no 'could not extract the d32 sweep classifier from bin/fleet'
else
  ok 'extracted the d32 sweep classifier from bin/fleet'
  classify() { printf '%s\n' "$@" | awk -v n=pc "$AWKP" | tr '\n' ' '; }
  chk 'depth 1 selected'            'pc_hidden '        "$(classify pc_hidden)"
  chk 'depth 2 selected'            'pc_hidden_hidden ' "$(classify pc_hidden_hidden)"
  chk 'depth 3 selected'            'pc_hidden_hidden_hidden ' \
                                    "$(classify pc_hidden_hidden_hidden)"
  chk 'the visible session itself is never swept' '' "$(classify pc)"
  chk 'another project is never swept'            '' "$(classify techweb2_hidden)"
  chk 'a near-miss suffix is never swept'         '' "$(classify pc_hiddenX)"
  chk 'a prefix collision is never swept'         '' "$(classify pcx_hidden)"
  chk 'a mid-name match is never swept'           '' "$(classify pc_hidden_live)"
  chk 'mixed input selects only the parking sessions' 'pc_hidden pc_hidden_hidden ' \
      "$(classify pc pc_hidden pc_hidden_hidden pc_hiddenX techweb2_hidden)"
fi

section 'part B — end to end: ghosts die, live parked agents survive'
# A ghost: a nested parking session whose windows carry no @fleet_harness.
tmux new-session -d -s pc_hidden_hidden -n ghost sh 2>/dev/null
# A live one: nested, but stamped as a real parked agent.
tmux new-session -d -s pc2_hidden_hidden -n live sh 2>/dev/null
tmux set -w -t 'pc2_hidden_hidden:live' @fleet_harness claude 2>/dev/null

# Replay the sweep exactly as cmd_up runs it, over both project names.
sweep() { # sweep <project-name>
  local name="$1" stale_hidden
  while IFS= read -r stale_hidden; do
    [ -n "$stale_hidden" ] || continue
    tmux list-windows -t "=$stale_hidden" -F '#{@fleet_harness}' 2>/dev/null | grep -q . && continue
    tmux kill-session -t "=$stale_hidden" 2>/dev/null || true
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | awk -v n="$name" "$AWKP")
}
sweep pc
sweep pc2

chk 'harness-less nested ghost swept' '' \
    "$(tmux has-session -t '=pc_hidden_hidden' 2>/dev/null && echo present)"
chk 'nested session with a live harness REFUSED' 'present' \
    "$(tmux has-session -t '=pc2_hidden_hidden' 2>/dev/null && echo present)"

proof_summary

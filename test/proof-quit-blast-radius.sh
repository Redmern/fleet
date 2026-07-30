#!/usr/bin/env bash
# Proof 5 (d32) — the blast radius of `fleet quit`.
#
# TWO separate properties, and the first version of this proof only had the first:
#
#   1. `fleet quit` must stay LITERAL-session. project_session() normalizes
#      "<sess>_hidden" back to the visible project; cmd_quit is the ONE targeting
#      site that must NOT adopt it, or a sub-orchestrator quitting itself would
#      kill the human's real session and every worker in it.
#
#   2. ...and literal is NOT sufficient. A sub-orch lives in the PARKING session,
#      so its `fleet quit` used to kill "<sess>_hidden" — every parked agent of
#      the project: sibling sub-orchs, and the human's own hidden agents. The
#      human session survived, which is exactly what made that easy to miss, and
#      the earlier revision of this proof ASSERTED the collateral as correct
#      ("the parking session tore itself down"). PLAN §3.2 required a guard here;
#      cmd_quit now refuses outright when the caller is parked.
#
# Cases:
#   1. quit from a PARKED pane REFUSES (non-zero) and says why
#   2. ...the human's session and its windows survive (property 1)
#   3. ...the parking session survives (property 2)
#   4. ...and so does every OTHER parked agent — the collateral that was the bug
#   5. quit from the project session still tears down both sessions
set -u
. "$(cd "$(dirname "$0")" && pwd)/hidden-proof-common.sh"
proof_isolate
proof_session t1

tmux new-window -d -t t1 -n survivor sh 2>/dev/null
# Two parked agents: the one that runs quit, and a bystander. The bystander is
# the whole point — it stands for a sibling sub-orch or a human's hidden agent.
"$FLEET" new --scratch orch     >/dev/null 2>&1
"$FLEET" new --scratch bystander >/dev/null 2>&1
wait_window orch      || { no 'parked orch pane never spawned'; proof_summary; }
wait_window bystander || { no 'parked bystander never spawned'; proof_summary; }
chk 'bystander is parked alongside orch' 't1_hidden' "$(sess_of bystander)"
OPANE=$(pane_of orch); sleep 0.5

section 'case 1 — quit from a PARKED pane is REFUSED'
OUT=$(in_pane "$OPANE" "'$FLEET' quit" 2>&1); RC=$?
chk_ne 'fleet quit from a parked pane exits non-zero' '0' "$RC"
case "$OUT" in
  *refusing*) ok 'it explains the refusal' ;;
  *)          no "no refusal message; got: $(printf '%s' "$OUT" | tr '\n' '|')" ;;
esac
sleep 0.5

section 'case 2 — the human session is untouched (literal-session property)'
if tmux has-session -t '=t1' 2>/dev/null; then
  ok 'the human'"'"'s session t1 survived'
else
  no 'CATASTROPHE: a sub-orch quit destroyed the human'"'"'s session'
fi
case " $(tmux list-windows -t '=t1' -F '#{window_name}' 2>/dev/null | tr '\n' ' ') " in
  *" survivor "*) ok 'the human'"'"'s worker windows survived' ;;
  *)              no 'the human'"'"'s worker windows were destroyed' ;;
esac

section 'case 3 — the parking session survives (the guard, not just literalness)'
if tmux has-session -t '=t1_hidden' 2>/dev/null; then
  ok 'the parking session was NOT torn down'
else
  no 'the parking session was destroyed — the guard did not hold'
fi

section 'case 4 — no collateral: every OTHER parked agent survives'
chk 'the bystander agent is still alive' 't1_hidden' "$(sess_of bystander)"
chk 'the quitting agent itself is still alive' 't1_hidden' "$(sess_of orch)"

section 'case 5 — quit from the project session still tears down both'
FLEET_SESSION=t1 "$FLEET" quit >/dev/null 2>&1 || true
sleep 0.3
chk 'visible session gone' '' "$(tmux has-session -t '=t1' 2>/dev/null && echo present)"
chk 'parking sibling gone' '' "$(tmux has-session -t '=t1_hidden' 2>/dev/null && echo present)"

proof_summary

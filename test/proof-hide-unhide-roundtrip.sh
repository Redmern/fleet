#!/usr/bin/env bash
# Proof 4 (d32) — `fleet hide` / `fleet unhide` round-trip, including the path
# that the new helper changes: running them FROM INSIDE a parked pane.
#
# cmd_hide/cmd_unhide both derive their move-window target from the caller's own
# session. Run from a sub-orch (which is itself parked), hide would move a window
# into "<sess>_hidden_hidden" and unhide would surface it into the PARKED session
# rather than onto the human's bar — i.e. "surfaced" without ever appearing.
#
# Cases:
#   1-3. hide from the main pane: parks at depth 1, @fleet_hidden=2, off the bar
#   4-6. unhide from the main pane: back in the visible session, @fleet_hidden=0
#   7-8. CRITICAL — hide from inside a parked pane parks at depth 1, not depth 2
#   9-10. CRITICAL — unhide from inside a parked pane surfaces into the VISIBLE
#         session (the bar), not into the parked one
#   11.  no per-window window-status-format override is ever left behind
set -u
. "$(cd "$(dirname "$0")" && pwd)/hidden-proof-common.sh"
proof_isolate
proof_session t1

# A plain (non-scratch) agent window. agents_tsv's daemon-down fallback keys on
# @agent_state, so mark_agent is what gives it a resolvable row.
tmux new-window -d -t t1 -n subject sh 2>/dev/null
SUBJ=$(win_of subject); mark_agent "$SUBJ" idle

section 'cases 1-3 — hide from the main pane'
"$FLEET" hide subject >/dev/null 2>&1
chk 'subject parked at depth 1'        't1_hidden' "$(sess_of subject)"
chk '@fleet_hidden = 2 (user-hidden)'  '2' "$(tmux show -w -t "$SUBJ" -v @fleet_hidden 2>/dev/null)"
case " $(tmux list-windows -t '=t1' -F '#{window_name}' 2>/dev/null | tr '\n' ' ') " in
  *" subject "*) no 'subject still on the visible bar' ;;
  *)             ok 'subject gone from the visible session' ;;
esac

section 'cases 4-6 — unhide from the main pane'
"$FLEET" unhide subject >/dev/null 2>&1
chk 'subject back in the visible session' 't1' "$(sess_of subject)"
chk '@fleet_hidden = 0 (surfaced)' '0' "$(tmux show -w -t "$SUBJ" -v @fleet_hidden 2>/dev/null)"
case " $(tmux list-windows -t '=t1' -F '#{window_name}' 2>/dev/null | tr '\n' ' ') " in
  *" subject "*) ok 'subject renders in the bar again' ;;
  *)             no 'subject did not come back onto the bar' ;;
esac

# ---------------------------------------------------------------------------
section 'cases 7-8 — CRITICAL: hide from inside a parked pane'
"$FLEET" new --scratch orch >/dev/null 2>&1
wait_window orch || { no 'parked orch pane never spawned'; proof_summary; }
OPANE=$(pane_of orch); sleep 0.5
in_pane "$OPANE" "'$FLEET' hide subject" >/dev/null 2>&1 || true
sleep 0.3
chk 'hide from a parked pane parks at depth 1 (NOT _hidden_hidden)' \
    't1_hidden' "$(sess_of subject)"
chk 'zero *_hidden_hidden sessions' '0' "$(sessions | grep -c '_hidden_hidden' || true)"

section 'cases 9-10 — CRITICAL: unhide from inside a parked pane'
in_pane "$OPANE" "'$FLEET' unhide subject" >/dev/null 2>&1 || true
sleep 0.3
chk 'unhide from a parked pane surfaces into the VISIBLE session' \
    't1' "$(sess_of subject)"
case " $(tmux list-windows -t '=t1' -F '#{window_name}' 2>/dev/null | tr '\n' ' ') " in
  *" subject "*) ok 'surfaced onto the human bar, not into the parked session' ;;
  *)             no 'surfaced somewhere that is not the bar' ;;
esac

section 'case 11 — the rejected format-override approach was not adopted'
LEAK=0
while IFS= read -r w; do
  [ -n "$(tmux show -w -t "$w" -v window-status-format 2>/dev/null)" ] && LEAK=$((LEAK+1))
done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null)
chk 'no per-window window-status-format override anywhere' '0' "$LEAK"

proof_summary

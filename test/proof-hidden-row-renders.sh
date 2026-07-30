#!/usr/bin/env bash
# Proof 2 (d32) — the user-visible outcome: a parked agent still gets a dashboard
# row, and `fleet ls` run from inside a parked pane can see the project.
#
# Three claims:
#   A. the TSV contract is untouched — `fleet agents` still emits exactly 9
#      tab-separated fields per row (every parser is positional; a 10th field
#      makes fleet-dash paint `done` on live agents and a human reaps live work).
#   B. the dashboard's session filter keeps a parked row at ANY depth and flags
#      it hid=1 / counts it into HIDDEN_N — defence-in-depth for the nested
#      sessions that already exist on a pre-fix machine.
#   C. `fleet ls` from inside a parked pane lists the VISIBLE session's agents.
#      Today it cannot see them at all (it scopes to the caller's own session).
#
# Claim B is checked against the REAL code: the two filter fragments are
# extracted from bin/fleet-dash between `# >>> d32:` / `# <<< d32:` markers and
# eval'd over a table of session names. Driving the full-screen TUI is not
# possible headlessly; re-typing the expression here would prove nothing.
set -u
. "$(cd "$(dirname "$0")" && pwd)/hidden-proof-common.sh"
proof_isolate
proof_session t1

# a visible (non-scratch) agent in t1, plus a parked scratch agent
tmux new-window -d -t t1 -n worker sh 2>/dev/null
mark_agent "$(win_of worker)" idle
"$FLEET" new --scratch parent >/dev/null 2>&1
wait_window parent || { no 'parent scratch agent never spawned'; proof_summary; }
mark_agent "$(win_of parent)" idle
PPANE=$(pane_of parent)
sleep 0.5
in_pane "$PPANE" "'$FLEET' new --scratch child" >/dev/null 2>&1 || true
wait_window child || no 'child scratch agent never spawned'
mark_agent "$(win_of child)" idle

section 'claim A — the 9-field TSV contract is untouched'
TSV=$("$FLEET" agents 2>/dev/null)
chk 'parent row present' '1' "$(printf '%s\n' "$TSV" | awk -F'\t' '$5=="parent"' | grep -c . || true)"
chk 'child row present'  '1' "$(printf '%s\n' "$TSV" | awk -F'\t' '$5=="child"'  | grep -c . || true)"
BADW=$(printf '%s\n' "$TSV" | awk -F'\t' 'NF && NF!=9' | grep -c . || true)
chk 'every row has exactly 9 fields' '0' "$BADW"
chk 'parent session field is depth-1' 't1_hidden' \
    "$(printf '%s\n' "$TSV" | awk -F'\t' '$5=="parent"{print $3; exit}')"
chk 'child session field is depth-1'  't1_hidden' \
    "$(printf '%s\n' "$TSV" | awk -F'\t' '$5=="child"{print $3; exit}')"

section 'claim B — dashboard row filter, against the real bin/fleet-dash source'
extract() { sed -n "/# >>> d32:$1/,/# <<< d32:$1/p" "$FLEET_DASH" | sed '1d;$d'; }
FILT=$(extract sessfilter)
HIDF=$(extract hidflag)
if [ -z "$FILT" ] || [ -z "$HIDF" ]; then
  no 'could not extract the d32 filter markers from bin/fleet-dash'
else
  ok 'extracted both d32 filter fragments from bin/fleet-dash'
  # Replay one row through the real fragments. `continue` inside the extracted
  # filter needs a loop to land in, so the body runs inside `for _ in 1`.
  row_verdict() { # row_verdict <sess> <SESS> -> "<keep|drop> <hid> <HIDDEN_N>"
    local sess="$1" SESS="$2" hid=0 HIDDEN_N=0 _base="" verdict=drop
    for _ in 1; do
      eval "$FILT"
      eval "$HIDF"
      verdict=keep
    done
    printf '%s %s %s' "$verdict" "$hid" "$HIDDEN_N"
  }
  # The contract table IS the requirement.
  chk 'own session kept, not hidden'        'keep 0 0' "$(row_verdict t1                t1)"
  chk 'depth-1 parked kept, hidden+counted' 'keep 1 1' "$(row_verdict t1_hidden         t1)"
  chk 'depth-2 parked kept, hidden+counted' 'keep 1 1' "$(row_verdict t1_hidden_hidden  t1)"
  chk 'depth-3 parked kept, hidden+counted' 'keep 1 1' "$(row_verdict t1_hidden_hidden_hidden t1)"
  chk 'another project dropped'             'drop 0 0' "$(row_verdict other             t1)"
  chk 'another project parked dropped'      'drop 0 0' "$(row_verdict other_hidden      t1)"
  chk 'prefix collision dropped'            'drop 0 0' "$(row_verdict t1x               t1)"
  # A `${SESS}_hidden*` glob would wrongly ACCEPT this; suffix-stripping does not.
  chk 'near-miss suffix dropped'            'drop 0 0' "$(row_verdict t1_hiddenX        t1)"

  # A project session GENUINELY named "<x>_hidden". project_session() supports
  # this (it never invents a base that does not exist — see proof 1 case 5), so
  # the dashboard must too. Stripping every "_hidden" unconditionally reduces
  # SESS's own rows to a non-match and empties the ENTIRE dashboard for that
  # project. These four rows are the regression guard for that.
  chk 'own session kept when SESS ends in _hidden' 'keep 0 0' \
      "$(row_verdict foo_hidden               foo_hidden)"
  chk 'its parked sibling kept + counted'          'keep 1 1' \
      "$(row_verdict foo_hidden_hidden        foo_hidden)"
  chk 'its depth-2 sibling kept + counted'         'keep 1 1' \
      "$(row_verdict foo_hidden_hidden_hidden foo_hidden)"
  chk 'the stripped base is NOT this project'      'drop 0 0' \
      "$(row_verdict foo                      foo_hidden)"
fi

section 'claim C — `fleet ls` from inside a parked pane sees the project'
LS=$(in_pane "$PPANE" "'$FLEET' ls" 2>/dev/null || true)
case "$LS" in
  *worker*) ok 'parked pane lists the visible session'"'"'s agent (worker)' ;;
  *)        no "parked pane cannot see the visible session's agents; got: $(printf '%s' "$LS" | tr '\n' '|')" ;;
esac
case "$LS" in
  *parent*) ok 'parked pane still lists the parked agents' ;;
  *)        no 'parked pane lost sight of the parked agents' ;;
esac

proof_summary

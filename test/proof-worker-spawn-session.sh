#!/usr/bin/env bash
# Proof 8 (d32, loop 2) — a CODE WORKER spawned by a sub-orch belongs to the
# project, not to the sub-orch's parking session.
#
# The gap this closes: every other proof spawns `--scratch`, so `cmd_new`'s
# non-scratch branch — the one that creates real worktree agents — had zero
# coverage. It still targeted `session_name()`, so a worker spawned from a parked
# pane landed in "<sess>_hidden": off the bar, unreachable by `C-b n`, carrying no
# @fleet_hidden marker at all, and — the durable half — persisted to
# "<sess>_hidden.agents", a file `fleet restore` and `fleet forget` never read.
# The worker was un-restorable after a tmux restart and its saved-agents line
# immortal.
#
# Cases:
#   1-2. spawned from the MAIN pane: lands in the project session, on the bar
#        (the baseline that must not regress)
#   3-5. CRITICAL — spawned from a PARKED pane: still lands in the project
#        session, on the bar, and is NOT marked hidden
#   6-7. the saved-agents line goes to <project>.agents, and NOT to
#        <project>_hidden.agents
#   8.   `fleet restore` from the project session SEES it (it used to report
#        "no saved agents")
#   9.   `fleet forget` from the parked pane actually drops the line (it used to
#        be a silent no-op, leaving the line forever)
#   10.  a scratch spawn from the same parked pane still parks — the fix must not
#        surface scratch agents onto the bar as collateral
set -u
. "$(cd "$(dirname "$0")" && pwd)/hidden-proof-common.sh"
proof_isolate
proof_session t1

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

# A real repo for cmd_new to resolve. A plain working repo (has .git, not bare)
# is used in place, so no worktree machinery is exercised — this proof is about
# session targeting, nothing else.
mkrepo() { # mkrepo <name>
  local r="$FLEET_ROOT/$1"
  mkdir -p "$r"
  git -C "$r" init -q 2>/dev/null
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  echo hi > "$r/f"; git -C "$r" add f 2>/dev/null
  git -C "$r" commit -qm init 2>/dev/null
}
mkrepo repo1
mkrepo repo2

AGENTS_DIR="$XDG_CONFIG_HOME/fleet/sessions"

section 'cases 1-2 — baseline: worker spawned from the main pane'
"$FLEET" new repo1 feat-a --bare >/dev/null 2>&1
wait_window 'repo1/feat-a' || { no 'worker never spawned from the main pane'; proof_summary; }
chk 'lands in the project session' 't1' "$(sess_of 'repo1/feat-a')"
case " $(tmux list-windows -t '=t1' -F '#{window_name}' 2>/dev/null | tr '\n' ' ') " in
  *" repo1/feat-a "*) ok 'and is on the bar' ;;
  *)                  no 'baseline worker is not on the project bar' ;;
esac

section 'cases 3-5 — CRITICAL: worker spawned from a PARKED sub-orch pane'
"$FLEET" new --scratch orch >/dev/null 2>&1
wait_window orch || { no 'parked orch pane never spawned'; proof_summary; }
chk 'the spawning pane really is parked' 't1_hidden' "$(sess_of orch)"
OPANE=$(pane_of orch); sleep 0.5
in_pane "$OPANE" "'$FLEET' new repo2 feat-b --bare" >/dev/null 2>&1 || true
wait_window 'repo2/feat-b' || no 'worker never spawned from the parked pane'
chk 'lands in the PROJECT session, not the parking one' 't1' "$(sess_of 'repo2/feat-b')"
case " $(tmux list-windows -t '=t1' -F '#{window_name}' 2>/dev/null | tr '\n' ' ') " in
  *" repo2/feat-b "*) ok 'and is on the human'"'"'s bar' ;;
  *)                  no 'sub-orch-spawned worker is off the bar' ;;
esac
# A code worker is not a scratch agent: it must carry no hidden marker at all.
HM=$(tmux show -w -t "$(win_of 'repo2/feat-b')" -v @fleet_hidden 2>/dev/null)
case "$HM" in ''|0) ok 'not marked hidden' ;;
               *)   no "worker marked @fleet_hidden=$HM" ;; esac

section 'cases 6-7 — the saved-agents line lands in the file readers use'
if [ -f "$AGENTS_DIR/t1.agents" ] && grep -q 'feat-b' "$AGENTS_DIR/t1.agents" 2>/dev/null; then
  ok 'persisted to <project>.agents'
else
  no "not in t1.agents; sessions dir holds: $(ls "$AGENTS_DIR" 2>/dev/null | tr '\n' ' ')"
fi
if [ -f "$AGENTS_DIR/t1_hidden.agents" ]; then
  no 'a <project>_hidden.agents file was written — restore/forget never read it'
else
  ok 'no orphan <project>_hidden.agents file'
fi

section 'case 8 — `fleet restore` from the project session sees it'
R=$(FLEET_SESSION=t1 "$FLEET" restore 2>&1 || true)
case "$R" in
  *'no saved agents'*) no "restore reports no saved agents: $R" ;;
  *)                   ok 'restore reads the project'"'"'s saved agents' ;;
esac

section 'case 9 — `fleet forget` from the parked pane drops the line'
in_pane "$OPANE" "'$FLEET' forget $FLEET_ROOT/repo2" >/dev/null 2>&1 || true
sleep 0.3
if grep -q 'feat-b' "$AGENTS_DIR/t1.agents" 2>/dev/null; then
  no 'forget from a parked pane was a silent no-op — the line survives'
else
  ok 'forget from a parked pane removed the line'
fi

section 'case 10 — scratch spawns from the same pane still park'
in_pane "$OPANE" "'$FLEET' new --scratch kid" >/dev/null 2>&1 || true
wait_window kid || no 'scratch child never spawned'
chk 'scratch child is still parked (no collateral surfacing)' 't1_hidden' "$(sess_of kid)"
chk 'and still stamped hidden' '1' \
    "$(tmux show -w -t "$(win_of kid)" -v @fleet_hidden 2>/dev/null)"

proof_summary

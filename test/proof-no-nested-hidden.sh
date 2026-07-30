#!/usr/bin/env bash
# Proof 1 (d32, headline) — a scratch spawn must NEVER nest the parking session.
#
# The bug: session_name() (bin/fleet:89) answers "which session is MY pane in?",
# and FLEET_SESSION is exported only by `fleet up`/`main`/`restore` — never into a
# scratch spawn. A sub-orchestrator IS a scratch agent, so it already lives in
# "<sess>_hidden"; its own `fleet new --scratch` therefore parks the child into
# "<sess>_hidden_hidden", which no depth-1 consumer (bin/fleet-dash:452 among
# them) knows how to look in. tmux then destroys the depth-1 session when its last
# window leaves, orphaning the depth-2 one with no parent to name it back to.
#
# The fix: project_session() — the VISIBLE project session, from any pane.
#
# Cases:
#   1. parent scratch spawn parks at depth 1 (unchanged behaviour, guard)
#   2. CRITICAL — a scratch spawn FROM INSIDE a parked pane also parks at depth 1
#   3. no session named *_hidden_hidden exists anywhere on the server
#   4. depth 3: a grandchild from inside the child pane still parks at depth 1
#   5. "never invent a session": a real session literally named <x>_hidden whose
#      base <x> does NOT exist resolves to ITSELF, not to a fabricated base
#   6. ...and when the base DOES exist, the same pane resolves to the base
set -u
. "$(cd "$(dirname "$0")" && pwd)/hidden-proof-common.sh"
proof_isolate
proof_session t1

section 'case 1 — parent scratch parks at depth 1'
"$FLEET" new --scratch parent >/dev/null 2>&1
wait_window parent || { no 'parent scratch agent never spawned'; proof_summary; }
chk 'parent parked in ${FLEET_SESSION}_hidden' 't1_hidden' "$(sess_of parent)"

section 'case 2 — CRITICAL: child spawned FROM the parked pane must not nest'
PPANE=$(pane_of parent)
sleep 0.5                                   # let the fake harness reach its prompt
in_pane "$PPANE" "'$FLEET' new --scratch child" >/dev/null 2>&1 || true
wait_window child || no 'child scratch agent never spawned'
chk 'child parked in ${FLEET_SESSION}_hidden (NOT _hidden_hidden)' \
    't1_hidden' "$(sess_of child)"

section 'case 3 — no nested parking session on the server'
NESTED=$(sessions | grep -c '_hidden_hidden' || true)
chk 'zero *_hidden_hidden sessions' '0' "$NESTED"

section 'case 4 — depth 3: grandchild from inside the child pane'
CPANE=$(pane_of child)
if [ -n "$CPANE" ]; then
  sleep 0.5
  in_pane "$CPANE" "'$FLEET' new --scratch grandchild" >/dev/null 2>&1 || true
  wait_window grandchild || no 'grandchild scratch agent never spawned'
  chk 'grandchild parked in ${FLEET_SESSION}_hidden' 't1_hidden' "$(sess_of grandchild)"
  chk 'still zero *_hidden_hidden sessions' '0' "$(sessions | grep -c '_hidden_hidden' || true)"
else
  no 'no child pane to spawn a grandchild from'
fi

# ---------------------------------------------------------------------------
# Cases 5/6 pin the guard that keeps project_session() honest. Stripping
# "_hidden" unconditionally would hijack a user's genuinely-named session; the
# normalized base is used ONLY when tmux says that session really exists.
section 'case 5 — a real session named <x>_hidden with NO base resolves to itself'
tmux new-session -d -s solo_hidden -n main sh 2>/dev/null
tmux set -t solo_hidden @fleet_root "$FLEET_ROOT" 2>/dev/null
SOLO=$(tmux list-panes -t 'solo_hidden:main' -F '#{pane_id}' 2>/dev/null | head -1)
sleep 0.3
in_pane "$SOLO" "'$FLEET' new --scratch solokid" >/dev/null 2>&1 || true
wait_window solokid || no 'solokid never spawned'
# "solo" does not exist, so project_session must NOT invent it: the parking base
# stays the literal session name.
chk 'no base invented — parked beside the literal session' \
    'solo_hidden_hidden' "$(sess_of solokid)"

section 'case 6 — a session that LOOKS like a parking sibling is treated as one'
# solo2_hidden holds only agent windows (no `main`), which is exactly what a
# parking sibling looks like — fleet cannot tell it from one, and treating it as
# one is the documented, honest limit. The child lands in solo2_hidden, i.e. in
# the caller's own session, so it must NOT be stamped as hidden (case 8 below is
# the general form of that rule).
tmux new-session -d -s solo2 -n main sh 2>/dev/null
tmux set -t solo2 @fleet_root "$FLEET_ROOT" 2>/dev/null
tmux new-session -d -s solo2_hidden -n park sh 2>/dev/null
tmux set -t solo2_hidden @fleet_root "$FLEET_ROOT" 2>/dev/null
S2=$(tmux list-panes -t 'solo2_hidden:park' -F '#{pane_id}' 2>/dev/null | head -1)
sleep 0.3
in_pane "$S2" "'$FLEET' new --scratch solo2kid" >/dev/null 2>&1 || true
wait_window solo2kid || no 'solo2kid never spawned'
chk 'main-less "<x>_hidden" resolves to its base' 'solo2_hidden' "$(sess_of solo2kid)"

# ---------------------------------------------------------------------------
# Cases 7/8 are the collision the earlier revision of case 6 quietly blessed.
# With genuine fleet PROJECTS "a" and "a_hidden" both booted, naive stripping
# resolved "a_hidden" → "a" and parked a_hidden's own scratch agents back into
# "a_hidden" — on the bar, reachable by `C-b n`, dashboard hid=0 — while stamping
# them @fleet_hidden 1. "Hidden" that does not hide.
section 'case 7 — a genuine PROJECT named <x>_hidden resolves to ITSELF'
tmux new-session -d -s a      -n main sh 2>/dev/null
tmux set -t a        @fleet_root "$FLEET_ROOT" 2>/dev/null
tmux new-session -d -s a_hidden -n main sh 2>/dev/null   # `main` == a real project
tmux set -t a_hidden @fleet_root "$FLEET_ROOT" 2>/dev/null
AP=$(tmux list-panes -t 'a_hidden:main' -F '#{pane_id}' 2>/dev/null | head -1)
sleep 0.3
in_pane "$AP" "'$FLEET' new --scratch akid" >/dev/null 2>&1 || true
wait_window akid || no 'akid never spawned'
chk 'parked below the project, not INTO it' 'a_hidden_hidden' "$(sess_of akid)"
chk_ne 'did NOT land in the caller'"'"'s own visible session' 'a_hidden' "$(sess_of akid)"
AW=$(win_of akid)
chk 'and it really is stamped hidden' '1' \
    "$(tmux show -w -t "$AW" -v @fleet_hidden 2>/dev/null)"
# It must also be off `a_hidden`'s bar — the property the stamp claims.
case " $(tmux list-windows -t '=a_hidden' -F '#{window_name}' 2>/dev/null | tr '\n' ' ') " in
  *" akid "*) no 'akid is on the project bar despite being stamped hidden' ;;
  *)          ok 'akid is genuinely off the bar' ;;
esac

section 'case 8 — a window that lands VISIBLE is never stamped hidden'
# Spawning from project "a": the parking target is "a_hidden", which here is a
# real project session with its own bar. The window lands on it, so the
# @fleet_hidden stamp must say 0 rather than assert a hiding that did not happen.
BP=$(tmux list-panes -t 'a:main' -F '#{pane_id}' 2>/dev/null | head -1)
sleep 0.3
in_pane "$BP" "'$FLEET' new --scratch bkid" >/dev/null 2>&1 || true
wait_window bkid || no 'bkid never spawned'
chk 'landed in the sibling project session' 'a_hidden' "$(sess_of bkid)"
chk 'NOT stamped hidden — it is on that project'"'"'s bar' '0' \
    "$(tmux show -w -t "$(win_of bkid)" -v @fleet_hidden 2>/dev/null)"

proof_summary

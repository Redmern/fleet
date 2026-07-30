#!/usr/bin/env bash
# Proof 6 (d32) — the repo's fail-silent contract.
#
# CLAUDE.md: "if the daemon, tmux, nvim, or claude is missing, each command
# degrades to a working subset rather than erroring". project_session() adds tmux
# calls (has-session, display), so each must be guarded — an unguarded one turns
# `fleet ls` outside tmux from a friendly listing into a stderr splat, and turns a
# daemon-down dashboard refresh into an empty screen.
#
# No fleetd runs in any proof (XDG_RUNTIME_DIR is redirected to an empty dir), so
# every case here already exercises the daemon-down path.
#
# Cases:
#   1-3. daemon down: agents / ls / ls --all all exit 0 and still produce rows
#   4.   OUTSIDE tmux entirely: ls exits 0 (session_name fails -> no scoping)
#   5.   outside tmux: agents exits 0
#   6-7. hide/unhide of a real target exit 0 with no daemon
#   8.   hide of a nonexistent target fails LOUDLY (a die, not a silent no-op) —
#        fail-silent is about missing integrations, not about swallowing a user
#        error; regressing this would make a typo look like a successful hide
#   9.   the parked-pane path stays fail-silent too
set -u
. "$(cd "$(dirname "$0")" && pwd)/hidden-proof-common.sh"
proof_isolate
proof_session t1

[ -S "${XDG_RUNTIME_DIR}/fleet.sock" ] && no 'a daemon socket exists — isolation broken'

tmux new-window -d -t t1 -n subject sh 2>/dev/null
mark_agent "$(win_of subject)" idle

rc_of() { "$@" >/dev/null 2>&1; echo $?; }

section 'cases 1-3 — daemon down, inside tmux'
chk 'fleet agents exits 0'   '0' "$(rc_of "$FLEET" agents)"
chk 'fleet ls exits 0'       '0' "$(rc_of "$FLEET" ls)"
chk 'fleet ls --all exits 0' '0' "$(rc_of "$FLEET" ls --all)"
case "$("$FLEET" ls 2>/dev/null)" in
  *subject*) ok 'fleet ls still lists the agent (degraded but working)' ;;
  *)         no 'fleet ls produced no usable output with the daemon down' ;;
esac

section 'cases 4-5 — outside tmux entirely'
# No TMUX, no FLEET_SESSION: session_name() and project_session() both fail.
chk 'fleet ls exits 0 outside tmux' '0' \
    "$(env -u TMUX -u TMUX_PANE -u FLEET_SESSION TMUX_TMPDIR="$TMPROOT/nowhere" \
       sh -c "$(printf '%q' "$FLEET") ls >/dev/null 2>&1; echo \$?")"
chk 'fleet agents exits 0 outside tmux' '0' \
    "$(env -u TMUX -u TMUX_PANE -u FLEET_SESSION TMUX_TMPDIR="$TMPROOT/nowhere" \
       sh -c "$(printf '%q' "$FLEET") agents >/dev/null 2>&1; echo \$?")"

section 'cases 6-7 — hide / unhide with no daemon'
chk 'fleet hide exits 0'   '0' "$(rc_of "$FLEET" hide subject)"
chk 'fleet unhide exits 0' '0' "$(rc_of "$FLEET" unhide subject)"

section 'case 8 — a user error still fails loudly'
chk_ne 'fleet hide <nonexistent> does NOT silently succeed' '0' \
       "$(rc_of "$FLEET" hide zzz-no-such-agent)"

section 'case 9 — the parked-pane path is fail-silent too'
"$FLEET" new --scratch orch >/dev/null 2>&1
if wait_window orch; then
  sleep 0.5
  in_pane "$(pane_of orch)" "'$FLEET' ls" >/dev/null 2>&1
  chk 'fleet ls from a parked pane exits 0' '0' "$?"
else
  no 'parked orch pane never spawned'
fi

proof_summary

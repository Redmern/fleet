#!/usr/bin/env bash
# Proof harness — cleanup must NEVER tear down the command-center session.
#
# The bug: tmux destroys a session the instant its LAST window closes. The fleet
# command center lives in a window named `main`, shielded ONLY by the literal
# name-string "main". Any cleanup kill-window (reap, dashboard Close, hide) that
# lands on the main window — because the name drifted, or a cwd-collision made
# reap resolve to it — kills the last window and the whole fleet session dies.
#
# This harness boots a THROWAWAY, fully-isolated tmux server (TMUX_TMPDIR) and
# config (XDG_CONFIG_HOME) so it can never touch the real fleet session, stamps
# a fake command center exactly like `fleet up` (window `main`, @fleet_role main,
# the .fleet/roles/<pane> role file), and runs every hostile cleanup path,
# asserting the session + its command-center window SURVIVE.
#
# Run before the fix (expect RED on cases 2,3,4,5,6,7) and after (expect all
# PASS). A single FAIL fails the proof; the script exits 0 only if every case
# passes. Self-contained: no test runner, mirrors the repo's `fleet doctor`
# smoke-test convention.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"
DASH="$HERE/bin/fleet-dash"

# --- isolation: a private tmux server + private config, never the real one -----
TMPROOT=$(mktemp -d)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR"
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
unset TMUX  # we must not look like we're already inside a session

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

# pass/fail run INSIDE each per-case subshell and exit it with the right code, so
# the parent can aggregate via the subshell return codes ($r1..$r8).
pass() { echo "  PASS($1)"; exit 0; }
fail() { echo "  FAIL($1): $2"; exit 1; }

# The core invariant: the designated command-center window (tagged @fleet_ccenter
# by boot(), a harness-owned marker independent of the fix) outlives the cleanup,
# and so does its session. This is the user's requirement as a tmux fact. On
# violation it calls fail(), which exits the subshell — so a true return means
# the center survived.
assert_center_alive() { # <case> <sess>
  local c="$1" s="$2"
  tmux has-session -t "=$s" 2>/dev/null \
    || fail "$c" "session '$s' was destroyed by cleanup"
  tmux list-windows -t "=$s" -F '#{@fleet_ccenter}' 2>/dev/null | grep -qx 1 \
    || fail "$c" "command-center window was killed by cleanup"
  return 0
}

# Build a project root with a repo + a linked worktree on <branch> (merged into
# main), flag it ready, and record it in <sess>'s saved-agents file. Echoes the
# worktree dir.
mkrepo() { # <root> <sess> <branch>
  local root="$1" sess="$2" br="$3"
  mkdir -p "$root"
  git init -q "$root/repo"
  git -C "$root/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$root/repo" branch -M main 2>/dev/null
  local wt="$root/repo/${br//\//_}"
  git -C "$root/repo" worktree add -q -b "$br" "$wt" main 2>/dev/null
  mkdir -p "$wt/.fleet"; : > "$wt/.fleet/ready"
  # saved-agents fields: dir <TAB> repo <TAB> branch <TAB> bare <TAB> base <TAB> harness
  printf '%s\trepo\t%s\t\tmain\tclaude\n' "$wt" "$br" \
    >> "$XDG_CONFIG_HOME/fleet/sessions/$sess.agents"
  printf '%s' "$wt"
}

# Boot a fake command center, mirroring cmd_up: a window stamped as `main` by
# both the role registry file and @fleet_role, plus our test marker. <name> lets
# a case simulate a DRIFTED window name while role identity stays `main`.
# Echoes "<window_id> <pane_id>".
boot() { # <sess> <root> <cwd> [name]
  local sess="$1" root="$2" cwd="$3" name="${4:-main}"
  tmux new-session -d -s "$sess" -n "$name" -c "$cwd" sh 2>/dev/null
  local win pane
  win=$(tmux list-windows -t "=$sess" -F '#{window_id}' 2>/dev/null | head -1)
  pane=$(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null | head -1)
  tmux set -t "$sess" @fleet_root "$root" 2>/dev/null
  tmux set -w -t "$win" @fleet_role main 2>/dev/null
  tmux set -w -t "$win" @fleet_ccenter 1 2>/dev/null      # harness-owned survival marker
  tmux set -w -t "$win" automatic-rename off 2>/dev/null
  mkdir -p "$root/.fleet/roles"
  printf 'main\n' > "$root/.fleet/roles/$pane"
  printf '%s %s' "$win" "$pane"
}

# Add a plain (non-main) window at <cwd>; echoes its window_id.
addwin() { # <sess> <name> <cwd>
  tmux new-window -P -F '#{window_id}' -t "=$1" -n "$2" -c "$3" sh 2>/dev/null
}

reap() { FLEET_SESSION="$1" "$FLEET" reap "${@:2}" 2>&1; }

wt_exists() { [ -d "$1" ]; }   # worktree dir still present (not yet reaped)

echo "== reap-teardown-safety: cleanup must never destroy the command center =="

# --- Case 1: reap the only worker — session + center survive, worker removed ---
# Sanity that reap still does its job (must not be weakened by the fix).
( c=1; s=ft1; r="$TMPROOT/c1"
  wt=$(mkrepo "$r" "$s" feat)
  boot "$s" "$r" "$r" >/dev/null
  addwin "$s" worker "$wt" >/dev/null
  reap "$s" >/dev/null 2>&1
  if assert_center_alive "$c" "$s"; then
    if wt_exists "$wt"; then fail "$c" "worker worktree not reaped"; else pass "$c"; fi
  fi
) ; r1=$?

# --- Case 2: cwd-collision reap onto a RENAMED, single-window main -------------
# main's name drifted to "claude" and its pane cwd equals a flagged worktree, so
# reap's cwd-resolver lands on main. It is the last window → pre-fix the whole
# session is destroyed. The brake (refuse main / refuse last window) must save it.
( c=2; s=ft2; r="$TMPROOT/c2"
  wt=$(mkrepo "$r" "$s" feat)
  boot "$s" "$r" "$wt" claude >/dev/null     # main parked IN the worktree dir, renamed
  reap "$s" >/dev/null 2>&1
  assert_center_alive "$c" "$s" && pass "$c"
) ; r2=$?

# --- Case 3: cwd-collision reap onto a RENAMED main + a holder window ----------
# Same collision, but a second window keeps the session alive — isolating the
# "never kill the command-center WINDOW" guarantee from the last-window one.
( c=3; s=ft3; r="$TMPROOT/c3"
  wt=$(mkrepo "$r" "$s" feat)
  boot "$s" "$r" "$wt" claude >/dev/null     # renamed main, cwd == worktree
  addwin "$s" _hold "$r" >/dev/null          # holder so the session can't last-window-die
  reap "$s" >/dev/null 2>&1
  assert_center_alive "$c" "$s" && pass "$c"
) ; r3=$?

# --- Case 4: brake refuses an EMPTY target ------------------------------------
# The hide/Close sites guard empty with a load-bearing [ -n ] test; the brake
# must absorb it so an empty target can never fall through to the current window.
( c=4; s=ft4; r="$TMPROOT/c4"
  boot "$s" "$r" "$r" >/dev/null
  out=$(FLEET_SESSION="$s" "$FLEET" safe-kill-window "" 2>&1); rc=$?
  if printf '%s' "$out" | grep -qiE 'usage|unknown'; then
    fail "$c" "safe-kill-window brake not implemented (no empty-target protection)"
  elif [ "$rc" -eq 0 ]; then
    fail "$c" "brake accepted an empty target (rc=0)"
  else
    assert_center_alive "$c" "$s" && pass "$c"
  fi
) ; r4=$?

# --- Case 5: brake refuses the MAIN (command-center) window -------------------
( c=5; s=ft5; r="$TMPROOT/c5"
  read -r win _ < <(boot "$s" "$r" "$r" claude)   # renamed; role identity = main
  out=$(FLEET_SESSION="$s" "$FLEET" safe-kill-window "$win" 2>&1); rc=$?
  if printf '%s' "$out" | grep -qiE 'usage|unknown'; then
    fail "$c" "safe-kill-window brake not implemented (no main protection)"
  elif [ "$rc" -eq 0 ]; then
    fail "$c" "brake killed the command-center window (rc=0)"
  else
    assert_center_alive "$c" "$s" && pass "$c"
  fi
) ; r5=$?

# --- Case 6: brake refuses the LAST window of a session -----------------------
# A genuine non-main worker, but it is the only window → killing it destroys the
# session. The brake must refuse on the last-window check alone.
( c=6; s=ft6; r="$TMPROOT/c6"
  tmux new-session -d -s "$s" -n worker -c "$r" sh 2>/dev/null
  tmux set -t "$s" @fleet_root "$r" 2>/dev/null
  tmux set -w -t "=$s:worker" @fleet_ccenter 1 2>/dev/null   # treat as the thing that must survive
  win=$(tmux list-windows -t "=$s" -F '#{window_id}' 2>/dev/null | head -1)
  out=$(FLEET_SESSION="$s" "$FLEET" safe-kill-window "$win" 2>&1); rc=$?
  if printf '%s' "$out" | grep -qiE 'usage|unknown'; then
    fail "$c" "safe-kill-window brake not implemented (no last-window protection)"
  elif [ "$rc" -eq 0 ]; then
    fail "$c" "brake killed the last window, destroying the session (rc=0)"
  else
    tmux has-session -t "=$s" 2>/dev/null && pass "$c" || fail "$c" "session destroyed"
  fi
) ; r6=$?

# --- Case 7: over-match target must not mass-reap -----------------------------
# Two flagged worktrees under a root whose PATH contains the token "proj". The
# loose substring filter ("$lbl $dir") makes `reap proj` match the dir of BOTH.
# A label-only match reaps neither (no label is "proj"). Assert both survive.
( c=7; s=ft7; r="$TMPROOT/proj_c7"
  wa=$(mkrepo "$r" "$s" feata)
  wb=$(mkrepo "$r" "$s" featb)
  boot "$s" "$r" "$r" >/dev/null
  reap "$s" proj >/dev/null 2>&1
  if wt_exists "$wa" && wt_exists "$wb"; then
    assert_center_alive "$c" "$s" && pass "$c"
  else
    fail "$c" "over-match: 'reap proj' reaped a worktree it should not have"
  fi
) ; r7=$?

# --- Case 8: branch-with-slashes reaps the right worktree, center survives -----
# Precise targeting + slash→underscore dir mapping. Targeted `reap repo/feat/x`.
( c=8; s=ft8; r="$TMPROOT/c8"
  wt=$(mkrepo "$r" "$s" feat/x)
  boot "$s" "$r" "$r" >/dev/null
  addwin "$s" feat_x "$wt" >/dev/null
  reap "$s" repo/feat/x >/dev/null 2>&1
  if assert_center_alive "$c" "$s"; then
    if wt_exists "$wt"; then fail "$c" "slash-branch worktree not reaped"; else pass "$c"; fi
  fi
) ; r8=$?

# Subshells can't mutate parent counters, so aggregate via the per-case return
# codes ($rN == 0 means that case passed).
tot=$((r1+r2+r3+r4+r5+r6+r7+r8))
echo "== summary: $((8-tot)) passed, $tot failed =="
if [ "$tot" -eq 0 ]; then
  echo "RESULT: ALL CASES PASS — cleanup cannot tear down the command center."
  exit 0
else
  echo "RESULT: $tot case(s) FAILED — command center is reachable by cleanup."
  exit 1
fi

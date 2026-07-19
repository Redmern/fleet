#!/usr/bin/env bash
# Proof harness — "ready-shortcut": workers must be TOLD to self-mark, and the
# destructive end must refuse to act on a live agent.
#
# The bug (two halves):
#   Half 1 — NOTHING in fleet ever makes a worker run `fleet ready`. `cmd_new`
#     passes -p through verbatim; no hook, no daemon, no nvim path mentions it.
#     Workers comply only by luck (the project-root CLAUDE.md that `fleet up`
#     installs happens to be an ancestor of every worktree). Seeding the
#     instruction raises marker volume, so the DESTRUCTIVE end must also stop
#     trusting the marker blindly: `cmd_reap` has no live-state guard, so a
#     flagged, actively-working agent is reapable today — and the daemon-down
#     `agents_tsv` fallback emits 7 fields, not 9, so the ready column is always
#     empty and NO UI ever shows `done` while reap still destroys.
#   Half 2 — mark-ready lives on the leader menu (selection-independent, prompts
#     for an agent name). It belongs on the dashboard row under `y`, as a TOGGLE
#     with no confirm modal (cheapest-possible-undo is what buys no-confirm).
#
# Boots a THROWAWAY, fully-isolated tmux server (TMUX_TMPDIR) + config
# (XDG_CONFIG_HOME) + runtime dir + project root, so it can never touch the real
# fleet session, its saved-agents file, or its inbox/ledger.
#
# before: RED on cases 4, 7, 9, 10 (the load-bearing ones)   after: ALL PASS
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"
DASH="$HERE/bin/fleet-dash"

# --- isolation: private tmux server, config, runtime dir and project root ------
TMPROOT=$(mktemp -d)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR"
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run";   mkdir -p "$XDG_RUNTIME_DIR"   # => no fleet.sock => daemon-down path
unset TMUX                                # must not look like we're already inside a session
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export FLEET_DEBUG_PORT=59223             # cmd_reap ends in `fuser -k <port>/tcp` — never the real one
export FLEET_SESSION="rs_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

# pass/fail run INSIDE each per-case subshell and set its exit status, so the
# parent aggregates with `|| FAILED=1` — no shared state across the subshell wall.
FAILED=0
pass() { echo "  PASS($1)"; return 0; }
fail() { echo "  FAIL($1): $2"; return 1; }

# --- a recording harness stub, first on PATH ----------------------------------
# harness.d/claude.conf: H_BIN="claude-profile claude" — first on PATH wins, so a
# `claude-profile` stub captures the exact argv `cmd_new` composed (the seeded
# prompt is the last arg on the --bare path).
BINSTUB="$TMPROOT/bin"; mkdir -p "$BINSTUB"
REC="$TMPROOT/argv.log"
cat > "$BINSTUB/claude-profile" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$REC"
printf -- '---ARGV-END---\n' >> "$REC"
sleep 9999
EOS
chmod +x "$BINSTUB/claude-profile"
export REC
export PATH="$BINSTUB:$PATH"
reset_rec() { : > "$REC"; }

# --- fixtures -----------------------------------------------------------------
# A worktree-CONTAINER repo: <root>/wt/ holds no .git of its own, but <root>/wt/main
# is a git repo — cmd_new anchors off it and creates <root>/wt/<branch> worktrees.
mkcontainer() { # <root> — echoes the container path
  local root="$1"
  local c="$root/wt"
  mkdir -p "$c"
  git init -q "$c/main"
  git -C "$c/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$c/main" branch -M main 2>/dev/null
  printf '%s' "$c"
}

# A worktree already flagged ready, clean and merged into main, recorded in the
# session's saved-agents file — the exact shape `fleet reap` iterates.
mkready() { # <root> <sess> <branch> — echoes the worktree dir
  local root="$1" sess="$2" br="$3"
  [ -d "$root/repo" ] || {
    git init -q "$root/repo"
    git -C "$root/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$root/repo" branch -M main 2>/dev/null
  }
  local wt="$root/repo/${br//\//_}"
  git -C "$root/repo" worktree add -q -b "$br" "$wt" main 2>/dev/null
  mkdir -p "$wt/.fleet"; : > "$wt/.fleet/ready"
  # saved-agents: dir <TAB> repo <TAB> branch <TAB> bare <TAB> base <TAB> harness
  printf '%s\trepo\t%s\t\tmain\tclaude\n' "$wt" "$br" \
    >> "$XDG_CONFIG_HOME/fleet/sessions/$sess.agents"
  printf '%s' "$wt"
}

# A window at <cwd> carrying the tmux state mirror fleetd normally writes.
addwin() { # <sess> <name> <cwd> [state] — echoes its window_id
  local w
  w=$(tmux new-window -P -F '#{window_id}' -t "=$1" -n "$2" -c "$3" 'sleep 9999' 2>/dev/null)
  [ -n "${4:-}" ] && tmux set -w -t "$w" @agent_state "$4" 2>/dev/null
  tmux set -w -t "$w" automatic-rename off 2>/dev/null
  printf '%s' "$w"
}

# --- boot the fake command center ---------------------------------------------
tmux new-session -d -s "$FLEET_SESSION" -n main -c "$FLEET_ROOT" 'sleep 9999' 2>/dev/null
MAIN_WIN=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id}' 2>/dev/null | head -1)
MAIN_PANE=$(tmux list-panes -t "$MAIN_WIN" -F '#{pane_id}' 2>/dev/null | head -1)
tmux set -t "$FLEET_SESSION" @fleet_root "$FLEET_ROOT" 2>/dev/null
tmux set -w -t "$MAIN_WIN" @fleet_role main 2>/dev/null
tmux set -w -t "$MAIN_WIN" automatic-rename off 2>/dev/null
mkdir -p "$FLEET_ROOT/.fleet/roles"; printf 'main\n' > "$FLEET_ROOT/.fleet/roles/$MAIN_PANE"

CONTAINER=$(mkcontainer "$FLEET_ROOT")

echo "== ready-shortcut: instructed self-ready + a reap that refuses live agents =="

# --- Case 1: the completion trailer is seeded into a worktree worker's prompt --
reset_rec
"$FLEET" new wt feat -p "do the thing" --bare >/dev/null 2>&1
sleep 0.5
( c=1
if grep -q 'fleet ready' "$REC" 2>/dev/null; then
  if grep -q 'do the thing' "$REC" 2>/dev/null; then
    pass 1
  else
    fail 1 "trailer seeded but the original -p prompt was not preserved verbatim"
  fi
else
  fail 1 "seeded prompt contains no 'fleet ready' completion instruction (got: $(tr '\n' '|' < "$REC" | head -c 300))"
fi ) || FAILED=1

# --- Case 3: the durable per-worktree instruction file --------------------------
# (checked here, while case 1's worktree exists; the prompt trailer dies with the
# first context window / a /clear — the file is what the worker can RE-read.)
INSTR="$CONTAINER/feat/.fleet/ready-instructions"
( c=3
if [ -f "$INSTR" ] && grep -q 'fleet ready' "$INSTR" 2>/dev/null; then
  pass 3
else
  fail 3 "no durable instruction file at $INSTR mentioning 'fleet ready'"
fi ) || FAILED=1

# --- Case 2: NO trailer for --scratch (no worktree; cmd_ready would no-op) ------
reset_rec
"$FLEET" new --scratch sc -p "scratch task" >/dev/null 2>&1
sleep 0.5
( c=2
if grep -q 'scratch task' "$REC" 2>/dev/null; then
  if grep -q 'fleet ready' "$REC" 2>/dev/null; then
    fail 2 "scratch agent was seeded with the completion trailer (it has no worktree to reap)"
  else
    pass 2
  fi
else
  fail 2 "scratch spawn did not record a prompt at all (harness stub not reached)"
fi ) || FAILED=1

# --- Case 4: reap REFUSES a flagged agent that is still WORKING (the danger) ----
( c=4; s=rs4; r="$TMPROOT/c4"; mkdir -p "$r"
  tmux new-session -d -s "$s" -n main -c "$r" 'sleep 9999' 2>/dev/null
  tmux set -t "$s" @fleet_root "$r" 2>/dev/null
  wt=$(mkready "$r" "$s" feat4)
  addwin "$s" repo-feat4 "$wt" working >/dev/null
  sleep 0.3
  out=$(FLEET_SESSION="$s" "$FLEET" reap 2>&1)
  if [ -d "$wt" ]; then
    case "$out" in
      *"still working"*) pass $c ;;
      *skip*) fail $c "reap skipped, but NOT via the live-state guard — some other guard masked it (got: $out)" ;;
      *) fail $c "worktree survived but reap printed no 'skip' line (got: $out)" ;;
    esac
  else
    fail $c "REAPED a worktree whose agent is still working — output: $out"
  fi ) || FAILED=1

# --- Case 4b: the live-state guard holds through a SYMLINKED project root ------
# tmux reports the RESOLVED physical cwd; $dir is whatever cmd_new recorded. A
# literal string compare never matches under a symlinked root, which silently
# disables the guard and reaps the working agent it exists to protect.
( c=4b; s=rs4b; real="$TMPROOT/c4b-real"; r="$TMPROOT/c4b-link"
  mkdir -p "$real"; ln -s "$real" "$r"
  tmux new-session -d -s "$s" -n main -c "$r" 'sleep 9999' 2>/dev/null
  tmux set -t "$s" @fleet_root "$r" 2>/dev/null
  wt=$(mkready "$r" "$s" feat4b)          # saved-agents records the SYMLINK path
  addwin "$s" repo-feat4b "$wt" working >/dev/null
  sleep 0.3
  out=$(FLEET_SESSION="$s" "$FLEET" reap 2>&1)
  if [ ! -d "$wt" ]; then
    fail $c "REAPED a working agent's worktree under a symlinked root — the guard compared raw strings (got: $out)"
  else
    case "$out" in
      *"still working"*) pass $c ;;
      *) fail $c "worktree survived but not via the live-state guard (got: $out)" ;;
    esac
  fi ) || FAILED=1

# --- Case 4c: the main pane's cwd must NOT lend a worktree its state -----------
# main parked in a worktree's cwd would otherwise make that worktree refuse
# forever, with --force (which drops the dirty AND unmerged guards) the only way out.
( c=4c; s=rs4c; r="$TMPROOT/c4c"; mkdir -p "$r"
  wt_pre="$r/repo/feat4c"
  tmux new-session -d -s "$s" -n main -c "$r" 'sleep 9999' 2>/dev/null
  tmux set -t "$s" @fleet_root "$r" 2>/dev/null
  mw=$(tmux list-windows -t "=$s" -F '#{window_id}' 2>/dev/null | head -1)
  mp=$(tmux list-panes -t "$mw" -F '#{pane_id}' 2>/dev/null | head -1)
  tmux set -w -t "$mw" @fleet_role main 2>/dev/null
  mkdir -p "$r/.fleet/roles"; printf 'main\n' > "$r/.fleet/roles/$mp"
  wt=$(mkready "$r" "$s" feat4c)
  # park MAIN in the worktree cwd, marked working; the real worker is idle
  tmux respawn-pane -k -t "$mp" -c "$wt" 'sleep 9999' 2>/dev/null
  tmux set -w -t "$mw" @agent_state working 2>/dev/null
  addwin "$s" repo-feat4c "$wt" idle >/dev/null
  sleep 0.4
  out=$(FLEET_SESSION="$s" "$FLEET" reap 2>&1)
  if [ -d "$wt" ]; then
    fail $c "the command-center pane's own cwd/state blocked the reap of an IDLE worker (got: $out)"
  else pass $c; fi ) || FAILED=1

# --- Case 5: reap STILL works on an idle flagged agent (regression guard) -------
( c=5; s=rs5; r="$TMPROOT/c5"; mkdir -p "$r"
  tmux new-session -d -s "$s" -n main -c "$r" 'sleep 9999' 2>/dev/null
  tmux set -t "$s" @fleet_root "$r" 2>/dev/null
  wt=$(mkready "$r" "$s" feat5)
  addwin "$s" repo-feat5 "$wt" idle >/dev/null
  sleep 0.3
  out=$(FLEET_SESSION="$s" "$FLEET" reap 2>&1)
  if [ -d "$wt" ]; then
    fail $c "an IDLE flagged worktree was not reaped — the guard over-fires (got: $out)"
  else pass $c; fi ) || FAILED=1

# --- Case 6: unresolvable state must NOT block reap (fail-silent, not fail-safe)-
( c=6; s=rs6; r="$TMPROOT/c6"; mkdir -p "$r"
  tmux new-session -d -s "$s" -n main -c "$r" 'sleep 9999' 2>/dev/null
  tmux set -t "$s" @fleet_root "$r" 2>/dev/null
  wt=$(mkready "$r" "$s" feat6)     # NO window at $wt at all: state unresolvable
  sleep 0.3
  out=$(FLEET_SESSION="$s" "$FLEET" reap 2>&1)
  if [ -d "$wt" ]; then
    fail $c "a flagged worktree with a dead/absent pane was skipped — stale worktrees would be unreapable (got: $out)"
  else pass $c; fi ) || FAILED=1

# --- Case 7: daemon-down agents_tsv emits 9 fields, not 7 -----------------------
# XDG_RUNTIME_DIR points at an empty dir, so $SOCK does not exist and `fleet
# agents` takes the tmux-mirror fallback. Consumers index field 8 (age) and
# field 9 (ready); at 7 fields the ready column is ALWAYS empty, so no UI ever
# paints `done` while reap happily destroys.
( c=7
  # a window carrying the @agent_state mirror is what the fallback enumerates
  addwin "$FLEET_SESSION" tsvprobe "$FLEET_ROOT" idle >/dev/null
  sleep 0.3
  [ -S "$XDG_RUNTIME_DIR/fleet.sock" ] && { fail $c "isolation leak: a fleet daemon socket exists in the test runtime dir"; exit 1; }
  rows=$("$FLEET" agents 2>/dev/null)
  if [ -z "$rows" ]; then
    fail $c "no agent rows on the daemon-down path — fixture produced nothing to count"; exit 1
  fi
  bad=$(printf '%s\n' "$rows" | awk -F'\t' 'NF!=9{c++} END{print c+0}')
  if [ "$bad" != 0 ]; then
    fail $c "$bad row(s) are not 9 fields (widths: $(printf '%s\n' "$rows" | awk -F'\t' '{print NF}' | sort -u | tr '\n' ' '))"
    exit 1
  fi
  # Field COUNT alone is not the property. Field 9 must actually carry the marker,
  # or the `done` pill, the ⚑ glyph and the dash `y` toggle (which reads field 9
  # to decide flag-vs-clear, so it would RE-FLAG instead of clearing) all break
  # silently whenever the daemon is down.
  mkdir -p "$FLEET_ROOT/.fleet"; printf 'reason=all done\n' > "$FLEET_ROOT/.fleet/ready"
  got=$("$FLEET" agents 2>/dev/null | awk -F'\t' '$5=="tsvprobe"{print $9; exit}')
  rm -f "$FLEET_ROOT/.fleet/ready"
  if [ "$got" = "all done" ]; then pass $c
  else fail $c "daemon-down ready column is '$got', expected 'all done' — no UI can show \`done\` and \`y\` cannot toggle off"
  fi ) || FAILED=1

# --- Case 8: the leader-menu `ready` action is gone -----------------------------
( c=8
  # Assert on the ACTION (its label + its freed key), not on the bare word
  # "ready" — the surviving `reap` row legitimately reads "Reap ready worktrees".
  keys=$("$FLEET" keys 2>/dev/null)
  if printf '%s\n' "$keys" | grep -q 'Flag ready'; then
    fail $c "\`fleet keys\` still advertises the leader 'Flag ready' action"
  elif printf '%s\n' "$keys" | grep -qE '^\s+menu y\b'; then
    fail $c "\`fleet keys\` still binds a leader 'y' — the key must be free for the dashboard row verb"
  elif grep -qE '^ready\|' "$FLEET"; then
    fail $c "the fleet_actions heredoc still carries a 'ready|' row"
  elif grep -qE '^\s+ready\)\s+echo "command-prompt' "$FLEET"; then
    fail $c "action_tmux_command still carries the ready) case"
  else pass $c; fi ) || FAILED=1

# --- Case 9: the dashboard `y` toggle -------------------------------------------
# Source fleet-dash under its DASH_LIB seam (functions loaded, interactive loop
# never runs), point FLEET_BIN at a recording stub, and drive the toggle directly
# against a synthetic ROWS[] — field 8 empty (=> flag) then non-empty (=> clear).
( c=9
  YREC="$TMPROOT/y.log"; : > "$YREC"
  cat > "$TMPROOT/bin/fleetstub" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$YREC"
EOS
  chmod +x "$TMPROOT/bin/fleetstub"
  export YREC
  # shellcheck disable=SC1090
  DASH_LIB=1 . "$DASH" "$FLEET_SESSION" >/dev/null 2>&1
  if ! declare -F toggle_ready >/dev/null 2>&1; then
    fail $c "fleet-dash exposes no toggle_ready function to drive (the 'y' handler must be a function, not inline in the key loop, to be testable)"
    exit 1
  fi
  FLEET_BIN="$TMPROOT/bin/fleetstub"
  MODE=agents; sel=0
  # 1 state, 2 label, 3 window_id, 4 window_name, 6 pane_id, 7 age, 8 ready, 9 hidden
  ROWS=("idle"$'\t'"repo/feat"$'\t'"@9"$'\t'"repo-feat"$'\t'"1m00s"$'\t'"%9"$'\t'"60"$'\t'""$'\t'"0")
  N=1; status=""
  toggle_ready >/dev/null 2>&1
  got1=$(tail -1 "$YREC" 2>/dev/null)
  ROWS=("idle"$'\t'"repo/feat"$'\t'"@9"$'\t'"repo-feat"$'\t'"1m00s"$'\t'"%9"$'\t'"60"$'\t'"ready"$'\t'"0")
  toggle_ready >/dev/null 2>&1
  got2=$(tail -1 "$YREC" 2>/dev/null)
  # window_name (field 4), not the label (field 2): cmd_ready's target match is a
  # SUBSTRING match, first hit wins, so the label can collide across agents.
  if [ "$got1" != "ready repo-feat" ]; then
    fail $c "unflagged row: expected \`ready repo-feat\` (window_name), got \`$got1\`"
  elif [ "$got2" != "ready repo-feat --clear" ]; then
    fail $c "flagged row: expected \`ready repo-feat --clear\` (toggle back), got \`$got2\`"
  elif ! grep -qE '^\s+y\)' "$DASH"; then
    fail $c "toggle_ready works but no \`y)\` case binds it in the dashboard key loop"
  else pass $c; fi ) || FAILED=1

# --- Case 10: the scratch/root bleed guard covers the <target> path too ---------
# cmd_ready's guard is self-path only, so `fleet ready <scratch-agent>` writes
# <project-root>/.fleet/ready — the SHARED root — which then falsely flags main,
# the sub-orchs and every other root-cwd agent as done.
( c=10; s=rs10; r="$TMPROOT/c10"; mkdir -p "$r/.fleet"
  tmux new-session -d -s "$s" -n main -c "$r" 'sleep 9999' 2>/dev/null
  tmux set -t "$s" @fleet_root "$r" 2>/dev/null
  sw=$(tmux new-window -P -F '#{window_id}' -t "=$s" -n scratchy -c "$r" 'sleep 9999' 2>/dev/null)
  tmux set -w -t "$sw" @agent_state idle 2>/dev/null
  tmux set -w -t "$sw" automatic-rename off 2>/dev/null
  sleep 0.3
  out=$(FLEET_SESSION="$s" FLEET_ROOT="$r" "$FLEET" ready scratchy 2>&1)
  if [ -e "$r/.fleet/ready" ]; then
    fail $c "\`fleet ready <scratch-agent>\` wrote a marker into the SHARED project root ($r/.fleet/ready) — every root-cwd agent now falsely reads as done. Output: $out"
  else
    case "$out" in
      *"no worktree"*|*scratch*) pass $c ;;
      *) fail $c "no root marker written, but the refusal was not explained (got: $out)" ;;
    esac
  fi ) || FAILED=1

# --- Case 11: the footer hint fits its rule and advertises `y` ------------------
( c=11
  hint=$(grep -o 'Spc l[^"]*' "$DASH" | head -1)
  if [ -z "$hint" ]; then fail $c "could not locate the footer hint literal in $DASH"; exit 1; fi
  n=${#hint}
  if (( n > 100 )); then
    fail $c "hint is $n chars (>100): it clips in the dash's right-hand pane — '$hint'"
  elif ! printf '%s' "$hint" | grep -q 'y ready'; then
    fail $c "hint does not advertise 'y ready' — '$hint'"
  else pass $c; fi ) || FAILED=1

# --- Case 12: the `fleet ready` bullet is in sync across FLEET.md and CLAUDE.md -
# CLAUDE.md's bottom section is a verbatim copy of FLEET.md (the rule is stated at
# CLAUDE.md's own head, and install_orch_guide propagates FLEET.md into every
# project's CLAUDE.md / AGENTS.md). Compare the `fleet ready` bullet byte-for-byte.
( c=12
  bullet() { awk '/^- `fleet ready /{f=1} f{print} f&&/^$/{exit}' "$1"; }
  fb=$(bullet "$HERE/FLEET.md"); cb=$(awk '/^# Fleet — orchestrator capabilities/{s=1} s' "$HERE/CLAUDE.md" \
        | awk '/^- `fleet ready /{f=1} f{print} f&&/^$/{exit}')
  if [ -z "$fb" ]; then fail $c "no \`fleet ready\` bullet found in FLEET.md"; exit 1; fi
  if [ "$fb" != "$cb" ]; then
    fail $c "the \`fleet ready\` bullet differs between FLEET.md and CLAUDE.md's mirrored block"; exit 1
  fi
  if ! printf '%s' "$fb" | grep -q 'committed'; then
    fail $c "the bullet is not an unambiguous worker instruction (must say: when the task is done AND COMMITTED; not when pausing/blocked/asking)"
  elif ! grep -qF '**`y`** toggles the ready flag' "$HERE/FLEET.md" \
    || ! grep -qF '**`y`** toggles the ready flag' "$HERE/CLAUDE.md"; then
    fail $c "the agents-view \`y\` verb is not documented in both FLEET.md and CLAUDE.md"
  else pass $c; fi ) || FAILED=1

# --- Case 13: syntax -----------------------------------------------------------
( c=13
  err=""
  bash -n "$FLEET"            2>/dev/null || err="$err bin/fleet"
  bash -n "$DASH"             2>/dev/null || err="$err bin/fleet-dash"
  sh   -n "$HERE/bin/fleet-hook" 2>/dev/null || err="$err bin/fleet-hook"
  [ -z "$err" ] && pass $c || fail $c "syntax errors in:$err" ) || FAILED=1

echo
if [ "$FAILED" = 0 ]; then echo "RESULT: ALL PASS"; else echo "RESULT: FAILURES ABOVE"; fi
exit "$FAILED"

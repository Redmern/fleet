#!/usr/bin/env bash
# Proof harness — `fleet new --task <enum>` (agent task tag, d26).
#
# The feature: a validated task enum (research|plan|impl|test|scratch|generic)
# stamped at spawn into a NEW `@fleet_task` window option PLUS a window-name-keyed
# <root>/.fleet/tasks/<wname> file, rendered as a 4-char ASCII tag (rsch/plan/impl/
# test/scr, blank when unset) in the tmux status bar, the dashboard row, and a new
# TASK column in `fleet ls`.
#
# The three things this harness exists to nail down, in priority order:
#
#   A. THE REGRESSION GUARD (highest value). The obvious implementation — "add a
#      role column to the agents table" — is a silent-corruption bomb in three
#      independent readers, and this repo is fail-silent by house rule, so all
#      three fail QUIETLY WITH A WRONG ANSWER:
#        * bin/fleet-dash's positional `read` of 9 tab fields: tab is IFS
#          whitespace, so an empty col-9 collapses and col 10 lands in $ready →
#          EVERY agent renders the `done` pill → a human trusting the dash reaps
#          live work;
#        * bin/fleetd's hard `len(parts) == 9` → every row loses its metadata →
#          blank dashboard;
#        * cmd_restore's `IFS=$'\037' read … owner` — the last var absorbs every
#          extra column → mangled owner → mangled window prefix.
#      There is no schema/version/migration mechanism anywhere in this repo, and
#      this box deliberately runs a pacman copy alongside a dev symlink, so
#      version skew is live. The 9-field shapes must stay byte-identical.
#
#   B. FAIL-CLOSED VALIDATION. `--task main` must be rejected (a worker must not
#      self-promote past the FLEET_ROLE / .fleet/roles / @fleet_role brakes), and
#      the enum must be re-validated ON READ — tmux format-expands a window
#      option's CONTENTS, so a value carrying `#[` would corrupt the status bar
#      for the WHOLE tmux server, not one window.
#
#   C. ASCII-only, fixed 4-cell width. popup_fit_content / fit_left / hrule all
#      count CODEPOINTS, not display cells, and there is no ASCII-fallback ladder
#      to degrade to.
#
# Isolation: a THROWAWAY tmux server (TMUX_TMPDIR), config (XDG_CONFIG_HOME),
# runtime dir (XDG_RUNTIME_DIR → its own fleetd socket) and project root, all
# under mktemp -d, plus stub harness binaries earlier on PATH so no real `claude`
# is ever launched. It can never touch the live fleet.
#
# Run before the fix: RED. After: every case PASS. Exits non-zero on any failure.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"
DASH="$HERE/bin/fleet-dash"
FLEETD="$HERE/bin/fleetd"

# --- isolation ----------------------------------------------------------------
TMPROOT=$(mktemp -d)
# Socket isolation is INTRINSIC, never inherited. Ambient `export TMUX_TMPDIR` is
# NOT enough on its own: any step running in a shell that did not inherit it falls
# back to /tmp/tmux-$(id -u)/default — the REAL server — and then a bare
# `tmux kill-server` in cleanup() tears down the live fleet. (That happened: the
# real server went down and pc/techweb2 had to be recreated.) So resolve the socket
# HERE, assert it lives under TMPROOT, and inject it with -S on every tmux call via
# the wrapper below. TMUX_TMPDIR is still exported, but only so CHILD processes
# ($FLEET -> tmux) reach the SAME private server; correctness no longer rests on it.
export TMUX_TMPDIR="$TMPROOT/tmuxsock"
# The socket dir must exist and be 0700 or every spawn dies and the harness
# reports FEATURE failures for what is really an environment fault.
mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
# FLEET_HARNESS_SOCK exists ONLY so the guard below can be proven to fire; it is
# itself guarded, so it can never be used to escape to the real socket.
SOCK="${FLEET_HARNESS_SOCK:-$TMUX_TMPDIR/tmux-$(id -u)/default}"

# --- fail-fast guard: runs BEFORE any tmux call -------------------------------
if [ "$SOCK" = "/tmp/tmux-$(id -u)/default" ]; then
  echo "REFUSE: harness resolved to the real tmux socket ($SOCK)" >&2
  rm -rf "$TMPROOT"; exit 1
fi
case "$SOCK" in
  "$TMPROOT"/*) ;;
  *) echo "REFUSE: harness socket is not under TMPROOT ($SOCK not under $TMPROOT)" >&2
     rm -rf "$TMPROOT"; exit 1 ;;
esac

# Every tmux call in THIS FILE routes through here — defined in the same file as the
# calls, so -S can be neither forgotten nor lost across a subshell. `command tmux`
# avoids recursing into this function.
tmux() { command tmux -S "$SOCK" "$@"; }

export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run";    mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export FLEET_DEBUG_PORT=59223       # cmd_reap fuser-kills this; never the real 9222
export FLEET_SESSION="task_t"
export FLEET_ROOT="$TMPROOT/root"
mkdir -p "$FLEET_ROOT/.fleet"

# Stub harnesses FIRST on PATH: claude.conf's H_BIN is "claude-profile claude", so
# both candidates must be stubbed or a real agent gets launched 20+ times.
mkdir -p "$TMPROOT/bin"
for b in claude claude-profile; do
  printf '#!/bin/sh\nexec sleep 9999\n' > "$TMPROOT/bin/$b"; chmod +x "$TMPROOT/bin/$b"
done
export PATH="$TMPROOT/bin:$PATH"

DAEMON_PID=""
cleanup() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
  command tmux -S "$SOCK" kill-server 2>/dev/null
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }

TASKS_DIR="$FLEET_ROOT/.fleet/tasks"
task_file() { printf '%s/%s' "$TASKS_DIR" "$1"; }
opt_of()  { tmux show -wqv -t "$1" @fleet_task 2>/dev/null; }
wid_of()  { # <wname> -> window_id, across the visible session and its hidden sibling
  local s
  for s in "$FLEET_SESSION" "${FLEET_SESSION}_hidden"; do
    tmux list-windows -t "=$s" -F '#{window_id} #{window_name}' 2>/dev/null \
      | awk -v n="$1" '$2==n{print $1; exit}'
  done | head -1
}
pane_of() { tmux list-panes -t "$1" -F '#{pane_id}' 2>/dev/null | head -1; }

# A repo container with a bare repo + `main`, so cmd_new cuts real worktrees.
mkrepo() { # <name>
  local r="$FLEET_ROOT/$1"
  mkdir -p "$r"
  git init -q "$r/seed"
  git -C "$r/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$r/seed" branch -M main 2>/dev/null
}

spawn() { # <repo> <branch> [extra flags…] -> stdout+stderr of cmd_new
  local repo="$1" branch="$2"; shift 2
  "$FLEET" new "$repo" "$branch" --bare "$@" 2>&1
}

mkrepo repo
tmux new-session -d -s "$FLEET_SESSION" -n base -c "$FLEET_ROOT" sh 2>/dev/null
tmux set -t "$FLEET_SESSION" @fleet_root "$FLEET_ROOT" 2>/dev/null

echo "== A. regression guard — the tables did not change =========================="

# --------------------------------------------------------------------------- 1
# persist_agent must still write EXACTLY 9 tab-separated fields. A 10th column is
# the cmd_restore owner-absorption bug.
spawn repo feat/one --task impl >/dev/null 2>&1
AGENTS_FILE="$XDG_CONFIG_HOME/fleet/sessions/$FLEET_SESSION.agents"
if [ -f "$AGENTS_FILE" ]; then
  nf=$(awk -F'\t' 'END{print NF}' "$AGENTS_FILE")
  [ "$nf" = 9 ] && pass 1 || fail 1 "persist_agent wrote $nf tab fields, must be exactly 9"
else
  fail 1 "no .agents file written by cmd_new"
fi

# --------------------------------------------------------------------------- 2
# `fleet agents` field counts: 9 on the daemon path, 7 on the daemon-down
# fallback. Both are positionally consumed by bin/fleet-dash.
"$FLEETD" >/dev/null 2>&1 &
DAEMON_PID=$!
sleep 0.6
W1=$(wid_of "repo/feat_one"); P1=$(pane_of "$W1")
report() { # <pane> <state> <cwd>
  python3 - "$XDG_RUNTIME_DIR/fleet.sock" "$1" "$2" "$3" <<'PY' 2>/dev/null
import json, socket, sys, time
sp, pane, state, cwd = sys.argv[1:5]
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(2); c.connect(sp)
c.sendall((json.dumps({"id": 1, "method": "agent.report", "params": {
    "pane_id": pane, "session_id": "s", "state": state,
    "seq": time.time_ns(), "cwd": cwd}}) + "\n").encode())
c.recv(65536)
PY
}
report "$P1" idle "$FLEET_ROOT/repo/feat_one"
sleep 0.3
d_nf=$("$FLEET" agents 2>/dev/null | awk -F'\t' 'NF{print NF; exit}')
if [ -S "$XDG_RUNTIME_DIR/fleet.sock" ] && [ -n "$d_nf" ]; then
  [ "$d_nf" = 9 ] && pass 2a || fail 2a "daemon-path \`fleet agents\` emitted $d_nf fields, must be 9"
else
  fail 2a "daemon path produced no rows — cannot prove the 9-field shape"
fi
kill "$DAEMON_PID" 2>/dev/null; wait "$DAEMON_PID" 2>/dev/null; DAEMON_PID=""
rm -f "$XDG_RUNTIME_DIR/fleet.sock"
tmux set -w -t "$W1" @agent_state idle 2>/dev/null    # fallback path reads this
f_nf=$("$FLEET" agents 2>/dev/null | awk -F'\t' 'NF{print NF; exit}')
[ "$f_nf" = 7 ] && pass 2b || fail 2b "fallback-path \`fleet agents\` emitted ${f_nf:-0} fields, must be 7"

# --------------------------------------------------------------------------- 3
# THE done-PILL REGRESSION. Two agents, a task on one, .fleet/ready on NEITHER.
# Nothing may report done/ready. This is the exact bug a 10th column causes, and
# it is the one that makes a human reap live work.
spawn repo feat/two >/dev/null 2>&1
W2=$(wid_of "repo/feat_two")
tmux set -w -t "$W2" @agent_state idle 2>/dev/null
ls_out=$("$FLEET" ls 2>/dev/null)
if printf '%s' "$ls_out" | grep -qi 'done\|ready'; then
  fail 3a "no agent is flagged ready, yet \`fleet ls\` reports done/ready:"$'\n'"$ls_out"
else
  pass 3a
fi
# and the dashboard's own positional reader must agree with ls: field 8 (ready) is
# empty for every row it builds off `fleet agents`.
bad=$("$FLEET" agents 2>/dev/null | awk -F'\t' 'NF>=8 && $8!=""{c++} END{print c+0}')
[ "$bad" = 0 ] && pass 3b || fail 3b "$bad row(s) carry a non-empty ready field with no marker set"

# --------------------------------------------------------------------------- 4
# A legacy 9-column .agents line still restores cleanly, owner intact (no glued-on
# task column). Drives the parse only — the restore respawn is case 9.
legacy="$TMPROOT/legacy.agents"
printf '%s\trepo\tfeat/legacy\t1\tmain\tclaude\t1\td7-repo/feat_legacy\tso-d7\n' \
  "$FLEET_ROOT/repo/feat_legacy" > "$legacy"
own=$(tr '\t' '\037' <"$legacy" | { IFS=$'\037' read -r d r b ba bs h sm wn ow; printf '%s' "$ow"; })
[ "$own" = "so-d7" ] && pass 4 || fail 4 "legacy owner parsed as '$own', expected 'so-d7' (a 10th column would glue onto it)"

echo "== B. storage + read precedence ============================================"

# --------------------------------------------------------------------------- 5
o=$(opt_of "$W1"); f=$(cat "$(task_file 'repo/feat_one')" 2>/dev/null)
[ "$o" = impl ] && pass 5a || fail 5a "@fleet_task is '$o', expected 'impl'"
[ "$f" = impl ] && pass 5b || fail 5b ".fleet/tasks/repo/feat_one is '$f', expected 'impl'"

# --------------------------------------------------------------------------- 6
# window option wins over the file
mkdir -p "$(dirname "$(task_file 'repo/feat_one')")"
printf 'test\n' > "$(task_file 'repo/feat_one')"
t=$("$FLEET" task-of "$W1" "$FLEET_ROOT" "repo/feat_one" 2>/dev/null)
[ "$t" = impl ] && pass 6 || fail 6 "option must win over file; got '$t', expected 'impl'"

# --------------------------------------------------------------------------- 7
# file is the fallback when the option is gone (a tmux server restart)
tmux set -w -t "$W1" -u @fleet_task 2>/dev/null
t=$("$FLEET" task-of "$W1" "$FLEET_ROOT" "repo/feat_one" 2>/dev/null)
[ "$t" = test ] && pass 7 || fail 7 "file fallback failed; got '$t', expected 'test'"
printf 'impl\n' > "$(task_file 'repo/feat_one')"
tmux set -w -t "$W1" @fleet_task impl 2>/dev/null

# --------------------------------------------------------------------------- 8
# neither present -> empty task, and the tag is 4 spaces (stable column width)
t=$("$FLEET" task-of "$W2" "$FLEET_ROOT" "repo/feat_two" 2>/dev/null)
tag=$("$FLEET" task-tag "$t" 2>/dev/null)
if [ -z "$t" ] && [ "$tag" = "    " ]; then pass 8
else fail 8 "unset task must be '' with a 4-space tag; got task='$t' tag='$tag'"; fi

echo "== C. durability ==========================================================="

# --------------------------------------------------------------------------- 9
# tmux server restart: options are gone, the window-name-keyed file survives, and
# cmd_restore must re-pass --task so the respawned agent comes back tagged.
command tmux -S "$SOCK" kill-server 2>/dev/null; sleep 0.3
tmux new-session -d -s "$FLEET_SESSION" -n base -c "$FLEET_ROOT" sh 2>/dev/null
tmux set -t "$FLEET_SESSION" @fleet_root "$FLEET_ROOT" 2>/dev/null
"$FLEET" restore >/dev/null 2>&1
sleep 0.4
W1=$(wid_of "repo/feat_one")
if [ -n "$W1" ]; then
  rtag=$(tmux show -wqv -t "$W1" @fleet_task_tag 2>/dev/null)
  if [ "$(opt_of "$W1")" != impl ]; then fail 9 "restored agent lost its task (@fleet_task='$(opt_of "$W1")')"
  elif [ "$rtag" != impl ]; then fail 9 "restored agent lost its rendered tag (@fleet_task_tag='$rtag')"
  else pass 9; fi
else
  fail 9 "cmd_restore did not respawn repo/feat_one after the server restart"
fi
W2=$(wid_of "repo/feat_two")

# -------------------------------------------------------------------------- 10
# the task never lived in the daemon: with no daemon at all it is still readable
[ -S "$XDG_RUNTIME_DIR/fleet.sock" ] && fail 10 "daemon socket unexpectedly present" || {
  t=$("$FLEET" task-of "$W1" "$FLEET_ROOT" "repo/feat_one" 2>/dev/null)
  [ "$t" = impl ] && pass 10 || fail 10 "task unreadable with the daemon down; got '$t'"
}

# -------------------------------------------------------------------------- 11
# daemon down -> `fleet ls` walks the 7-field fallback and STILL prints the tag
tmux set -w -t "$W1" @agent_state idle 2>/dev/null
tmux set -w -t "$W2" @agent_state idle 2>/dev/null
ls_out=$("$FLEET" ls 2>/dev/null)
printf '%s' "$ls_out" | awk -F'\t' '$3 ~ /feat_one/ {found=($2 ~ /impl/)} END{exit !found}' \
  && pass 11 || fail 11 "fallback-path \`fleet ls\` did not show the impl tag:"$'\n'"$ls_out"

# -------------------------------------------------------------------------- 12
# synthetic/stale row: a window stamped with @fleet_harness + @fleet_task but
# never reported by a hook must still carry its tag (option-based store, not
# fleet.list-sourced).
tmux new-window -d -t "=$FLEET_SESSION" -n "repo/synth" -c "$FLEET_ROOT" sh 2>/dev/null
WS=$(wid_of "repo/synth")
tmux set -w -t "$WS" @fleet_harness claude 2>/dev/null
tmux set -w -t "$WS" @fleet_task research 2>/dev/null
t=$("$FLEET" task-of "$WS" "$FLEET_ROOT" "repo/synth" 2>/dev/null)
[ "$t" = research ] && pass 12 || fail 12 "synthetic row lost its tag; got '$t'"

echo "== D. validation / injection / self-promotion (fail-closed) ================="

# -------------------------------------------------------------------------- 13
# unknown value: warn on stderr, DROP it, still spawn (fail-silent house style)
out=$(spawn repo feat/bogus --task bogus 2>&1)
WB=$(wid_of "repo/feat_bogus")
if [ -z "$WB" ]; then fail 13 "a bad --task must not prevent the spawn"
elif ! printf '%s' "$out" | grep -qi 'task'; then fail 13 "no warning on stderr for --task bogus: $out"
elif [ -n "$(opt_of "$WB")" ]; then fail 13 "bogus task was stored: '$(opt_of "$WB")'"
elif [ -e "$(task_file 'repo/feat_bogus')" ]; then fail 13 "bogus task was persisted to the tasks file"
else pass 13; fi

# -------------------------------------------------------------------------- 14
# `--task main` — THE SELF-PROMOTION GUARD. Rejected, and every existing role
# brake still reads `worker` for that pane.
spawn repo feat/promote --task main >/dev/null 2>&1
WP=$(wid_of "repo/feat_promote"); PP=$(pane_of "$WP")
r_opt=$(tmux show -wqv -t "$WP" @fleet_role 2>/dev/null)
r_env=$(tmux show-environment -t "$FLEET_SESSION" 2>/dev/null | grep '^FLEET_ROLE=' | head -1)
r_file=$(cat "$FLEET_ROOT/.fleet/roles/$PP" 2>/dev/null)
if [ -n "$(opt_of "$WP")" ]; then fail 14 "--task main was STORED as '$(opt_of "$WP")'"
elif [ "$r_opt" = main ]; then fail 14 "--task main promoted @fleet_role to main"
elif [ "$r_file" = main ]; then fail 14 "--task main promoted the roles file to main (got '$r_file')"
elif [ -e "$(task_file 'repo/feat_promote')" ]; then fail 14 "--task main was persisted to the tasks file"
else pass 14; fi
case "$r_file" in worker*) pass 14b ;; *) fail 14b "roles file is '$r_file', expected worker[:so-…]" ;; esac

# -------------------------------------------------------------------------- 15
# tmux format injection, both directions.
spawn repo feat/inj --task 'x#[fg=red]' >/dev/null 2>&1
WI=$(wid_of "repo/feat_inj")
if [ -n "$WI" ] && [ -z "$(opt_of "$WI")" ]; then pass 15a
else fail 15a "a '#[' task must be rejected at the write site; got '$(opt_of "$WI")'"; fi
spawn repo feat/inj2 --task 'x#{q:#{pane_id}}' >/dev/null 2>&1
WI2=$(wid_of "repo/feat_inj2")
if [ -n "$WI2" ] && [ -z "$(opt_of "$WI2")" ]; then pass 15b
else fail 15b "a '#{' task must be rejected at the write site; got '$(opt_of "$WI2")'"; fi
# …and a HAND-EDITED file cannot inject either: task_of re-validates on READ.
mkdir -p "$(dirname "$(task_file 'repo/feat_two')")"
printf 'x#[fg=red]\n' > "$(task_file 'repo/feat_two')"
tmux set -w -t "$W2" -u @fleet_task 2>/dev/null
t=$("$FLEET" task-of "$W2" "$FLEET_ROOT" "repo/feat_two" 2>/dev/null)
[ -z "$t" ] && pass 15c || fail 15c "task_of must re-validate on read; a hand-edited file yielded '$t'"

# -------------------------------------------------------------------------- 16
# WHOLE-SERVER corruption case. Every stored @fleet_task must be in the enum, and
# no window may contribute an EXTRA '#[' to its expanded status format. The
# baseline is a window with no task set — the user's real tmux theme legitimately
# emits '#[fg=…]' of its own, so we compare counts rather than forbidding '#['.
"$FLEET" ls >/dev/null 2>&1     # force any status-format injection to have run
tmux new-window -d -t "=$FLEET_SESSION" -n "baseline" -c "$FLEET_ROOT" sh 2>/dev/null
WBASE=$(wid_of baseline)
sgr_count() { tmux display-message -p -t "$1" '#{E:window-status-format}' 2>/dev/null \
                | grep -o '#\[' | grep -c . ; }
base_n=$(sgr_count "$WBASE")
bad=0
while read -r w; do
  [ -n "$w" ] || continue
  v=$(tmux show -wqv -t "$w" @fleet_task 2>/dev/null)
  case "$v" in ""|research|plan|impl|test|scratch|generic) ;; *) bad=1; echo "    poison in $w: @fleet_task='$v'" ;; esac
  # …and the RENDERED companion, which is the one the status format expands
  v=$(tmux show -wqv -t "$w" @fleet_task_tag 2>/dev/null)
  case "$v" in ""|rsch|plan|impl|test|scr) ;; *) bad=1; echo "    poison in $w: @fleet_task_tag='$v'" ;; esac
  n=$(sgr_count "$w")
  if [ "${n:-0}" -gt "${base_n:-0}" ]; then
    bad=1; echo "    $w expands to $n '#[' vs baseline $base_n — format injection"
  fi
done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null)
[ "$bad" = 0 ] && pass 16 || fail 16 "status-bar format corruption reachable"

# ------------------------------------------------------------------------- 16b
# …and the bar must actually SHOW the tag. This is the surface the human sees
# without running any command — the whole point of the feature. inject_status_format
# is only run by `fleet up`/fleetd, so drive it through its internal subcommand
# against a known format. NOT `( . "$FLEET"; inject_status_format )`: sourcing the
# CLI runs its dispatch block, which falls through to usage — or, on a tty, to the
# interactive project picker, where it HANGS. That made this case prove nothing.
tmux set -g window-status-format '#I:#W' 2>/dev/null
tmux set -g window-status-current-format '#I:#W' 2>/dev/null
"$FLEET" inject-status-format >/dev/null 2>&1
gfmt=$(tmux show -g -v window-status-format 2>/dev/null)
e_tagged=$(tmux display-message -p -t "$W1" '#{E:window-status-format}' 2>/dev/null)
e_plain=$(tmux display-message -p -t "$WBASE" '#{E:window-status-format}' 2>/dev/null)
if ! printf '%s' "$gfmt" | grep -q '@fleet_task_tag'; then
  fail 16b "inject_status_format did not append a task token: $gfmt"
elif [ "$(printf '%s' "$gfmt" | grep -o '@fleet_task_tag' | grep -c .)" != 2 ]; then
  # exactly one token — which itself names the option twice (test + value)
  fail 16b "the task token was appended more than once: $gfmt"
elif ! printf '%s' "$e_tagged" | grep -q 'impl'; then
  fail 16b "an impl-tagged window's status bar does not show its tag: '$e_tagged'"
elif printf '%s' "$e_plain" | grep -qE 'rsch|impl|test|scr'; then
  fail 16b "an untagged window's status bar shows a tag: '$e_plain'"
else pass 16b; fi
# second run must be a no-op (fleetd's heal_status_format re-runs this forever)
"$FLEET" inject-status-format >/dev/null 2>&1
[ "$(tmux show -g -v window-status-format 2>/dev/null)" = "$gfmt" ] \
  && pass 16c || fail 16c "inject_status_format is not idempotent across runs"

# -------------------------------------------------------------------------- 17
# a literal tab or newline is rejected at the write site (it would shear the TSVs
# and the tasks file alike)
spawn repo feat/tabby --task "$(printf 'impl\tx')" >/dev/null 2>&1
WT=$(wid_of "repo/feat_tabby")
if [ -n "$WT" ] && [ -z "$(opt_of "$WT")" ]; then pass 17a
else fail 17a "a tab-bearing task must be rejected; got '$(opt_of "$WT")'"; fi
spawn repo feat/nlk --task "$(printf 'impl\nmain')" >/dev/null 2>&1
WN=$(wid_of "repo/feat_nlk")
if [ -n "$WN" ] && [ -z "$(opt_of "$WN")" ]; then pass 17b
else fail 17b "a newline-bearing task must be rejected; got '$(opt_of "$WN")'"; fi

echo "== E. rendering ============================================================"

# -------------------------------------------------------------------------- 18
# `fleet ls` grows a TASK column; every row keeps a stable field count.
ls_out=$("$FLEET" ls 2>/dev/null)
hdr=$(printf '%s' "$ls_out" | head -1)
printf '%s' "$hdr" | grep -q 'TASK' && pass 18a || fail 18a "\`fleet ls\` header has no TASK column: $hdr"
hdr_nf=$(printf '%s' "$hdr" | awk -F'\t' '{print NF}')
odd=$(printf '%s' "$ls_out" | awk -F'\t' -v n="$hdr_nf" 'NF && NF!=n{c++} END{print c+0}')
[ "$odd" = 0 ] && pass 18b || fail 18b "$odd row(s) do not match the header's $hdr_nf fields"

# -------------------------------------------------------------------------- 19
# The width-degradation ladder must shed the task field FIRST — before cost /
# mode / ✉ — so a narrow pane never squeezes the label.
#
# 19a is STRUCTURAL (shed ORDER). It is kept, but it is NOT sufficient and must
# never again stand alone: a source-grep proves the rungs are in the right ORDER
# and says nothing about the THRESHOLD they fire at. The shipped gate was
# `LW < 1`, while fit_left elides as soon as the label exceeds LW — so the ladder
# was in the correct order and still truncated the identity to keep a 4-char
# badge. That is what 19b measures, by RENDERING.
lad=$(grep -n 'LW < LBLMIN' "$DASH" | head -1 | cut -d: -f1)
tdrop=$(grep -n 'task_show=0' "$DASH" | head -1 | cut -d: -f1)
cdrop=$(grep -n 'cost_show=0' "$DASH" | head -1 | cut -d: -f1)
if [ -n "$tdrop" ] && [ -n "$cdrop" ] && [ "$tdrop" -lt "$cdrop" ]; then pass 19a
else fail 19a "task must be dropped before cost in the dash width ladder (task@${tdrop:-none} cost@${cdrop:-none}, ladder gate @${lad:-none})"; fi

# 19b FUNCTIONAL — the real invariant, measured on rendered output across the
# width band where the ladder actually trades. THE RULE: a row may show a task
# tag, or it may show a left-ellipsised (squeezed) label, but NEVER BOTH — the
# badge is a convenience, the label is the identity. Widths step through the band
# one at a time because the failure lives INSIDE it: sampling 100 then 60 steps
# straight over the point where the tag is still held and the label has already
# been eaten.
bad=""
for W in 120 110 100 95 90 85 80; do
  tmux kill-window -t "=$FLEET_SESSION:dashw" 2>/dev/null
  tmux new-window -d -t "=$FLEET_SESSION" -n dashw -c "$FLEET_ROOT" "$DASH $FLEET_SESSION" 2>/dev/null
  tmux set -w -t "=$FLEET_SESSION:dashw" window-size manual 2>/dev/null
  tmux resize-window -t "=$FLEET_SESSION:dashw" -x "$W" -y 24 2>/dev/null
  sleep 0.8
  cap=$(tmux capture-pane -p -t "=$FLEET_SESSION:dashw" 2>/dev/null)
  # a squeezed row is one carrying the left-ellipsis fit_left inserts
  while IFS= read -r ln; do
    case "$ln" in
      *…*) case "$ln" in
             *rsch*|*plan*|*impl*|*test*|*scr*)
               bad="$bad w=$W:[$(printf '%s' "$ln" | sed 's/^ *//;s/ *$//')]" ;;
           esac ;;
    esac
  done <<< "$cap"
done
tmux kill-window -t "=$FLEET_SESSION:dashw" 2>/dev/null
[ -z "$bad" ] && pass 19b \
  || fail 19b "a task tag survived while its label was squeezed (tag must shed first):$bad"

# -------------------------------------------------------------------------- 20
# THE CODEPOINT-VS-CELL GUARD: every tag is 4 ASCII bytes AND 4 characters. This
# is what keeps popup_fit_content / fit_left / hrule honest — they all measure
# codepoints, and there is no ASCII-fallback ladder anywhere to degrade to.
bad=0
for r in research plan impl test scratch generic ""; do
  tg=$("$FLEET" task-tag "$r" 2>/dev/null)
  nb=$(printf '%s' "$tg" | LC_ALL=C wc -c | tr -d ' ')
  nc=$(printf '%s' "$tg" | wc -m | tr -d ' ')
  if [ "$nb" != 4 ] || [ "$nc" != 4 ]; then
    bad=1; echo "    tag for '${r:-<unset>}' = '$tg' ($nb bytes, $nc chars) — must be 4/4"
  fi
  case "$tg" in *[!\ -~]*) bad=1; echo "    tag for '${r:-<unset>}' is not pure ASCII" ;; esac
done
[ "$bad" = 0 ] && pass 20 || fail 20 "tag widths are not a fixed 4 ASCII cells"

echo "== F. lifecycle ============================================================"

# -------------------------------------------------------------------------- 21
# forget drops the task file (it runs at the tail of reap's MUTATE phase, after
# `git worktree remove` has already succeeded — inside the atomic contract).
tf="$(task_file 'repo/feat_one')"
[ -e "$tf" ] || printf 'impl\n' > "$tf"
"$FLEET" forget "$FLEET_ROOT/repo/feat_one" >/dev/null 2>&1
[ -e "$tf" ] && fail 21 "fleet forget left $tf behind" || pass 21

# -------------------------------------------------------------------------- 22
# ATOMICITY: a REFUSED reap (dirty worktree) leaves the task file intact, so a
# plain re-run is the retry.
spawn repo feat/dirty --task test >/dev/null 2>&1
DW="$FLEET_ROOT/repo/feat_dirty"
tfd="$(task_file 'repo/feat_dirty')"
mkdir -p "$DW/.fleet"; : > "$DW/.fleet/ready"
echo dirt > "$DW/dirty.txt"; git -C "$DW" add dirty.txt 2>/dev/null   # tracked + uncommitted
"$FLEET" reap >/dev/null 2>&1
if [ -d "$DW" ] && [ -e "$tfd" ] && [ "$(cat "$tfd" 2>/dev/null)" = test ]; then pass 22
else fail 22 "a refused reap must leave everything intact (worktree:$([ -d "$DW" ] && echo yes || echo GONE) taskfile:$([ -e "$tfd" ] && echo yes || echo GONE))"; fi

# -------------------------------------------------------------------------- 23
# NO --task => NOTHING is stored, on EVERY spawn path including --scratch. Every
# sub-orch is spawned via `cmd_new --scratch`, so a default here would silently
# tag every fleet that has ever used the dispatch layer — flipping the dashboard's
# task column on for users who never typed the flag.
"$FLEET" new --scratch plainscratch >/dev/null 2>&1
WSC=$(wid_of plainscratch)
if [ -z "$WSC" ]; then fail 23 "--scratch spawn failed"
elif [ -n "$(opt_of "$WSC")" ]; then fail 23 "--scratch defaulted a task: '$(opt_of "$WSC")'"
elif [ -e "$(task_file plainscratch)" ]; then fail 23 "--scratch wrote a tasks file with no --task"
else pass 23; fi

# -------------------------------------------------------------------------- 24
# SPAWN IS AUTHORITATIVE. The tasks file is keyed by window NAME and names are
# recycled; a window killed by hand never routes through cmd_forget, so its file
# survives. A later agent reusing that name WITHOUT --task must not inherit the
# dead agent's tag through task_of's file fallback.
spawn repo feat/recycle --task research >/dev/null 2>&1
WR=$(wid_of "repo/feat_recycle")
tmux kill-window -t "$WR" 2>/dev/null            # by hand: no cmd_forget, file survives
[ -e "$(task_file 'repo/feat_recycle')" ] || fail 24 "harness: the file should still be there"
spawn repo feat/recycle >/dev/null 2>&1          # same window name, NO --task
WR=$(wid_of "repo/feat_recycle")
t=$("$FLEET" task-of "$WR" "$FLEET_ROOT" "repo/feat_recycle" 2>/dev/null)
if [ -z "$t" ] && [ ! -e "$(task_file 'repo/feat_recycle')" ]; then pass 24
else fail 24 "an untagged respawn inherited a dead agent's tag (task='$t', file $([ -e "$(task_file 'repo/feat_recycle')" ] && echo present || echo gone))"; fi

# -------------------------------------------------------------------------- 25
# `fleet ls` must never swallow its rows. The NR==FNR two-file idiom degenerates
# on an EMPTY first file — every stdin line would satisfy NR==FNR and hit `next`,
# leaving only the header. Assert real data rows survive.
rows=$("$FLEET" ls 2>/dev/null | tail -n +2 | grep -c .)
[ "${rows:-0}" -ge 1 ] && pass 25 || fail 25 "\`fleet ls\` printed a header and no rows"

# -------------------------------------------------------------------------- 26
# `generic` is REJECTED (d26 gate item 4), exactly like `main`. It was accepted but
# rendered on no surface, while still flipping HAS_TASKS — so it cost every label
# 4+G columns fleet-wide to display nothing, which is the precise harm the
# "--scratch does not default to task=scratch" decision was taken to avoid.
spawn repo feat/generic --task generic >/dev/null 2>&1
WG=$(wid_of "repo/feat_generic")
if [ -n "$WG" ] && [ -z "$(opt_of "$WG")" ]; then pass 26a
else fail 26a "--task generic must be rejected; got '$(opt_of "$WG")'"; fi
# …and the rejection must leave NOTHING behind that could flip HAS_TASKS: no
# @fleet_task_tag, no durable sidecar. The dash derives HAS_TASKS from the tag, so
# a stored-but-unrenderable value is exactly the failure being closed here.
gtag=$(tmux show -wqv -t "$WG" @fleet_task_tag 2>/dev/null)
if [ -z "$gtag" ] && [ ! -e "$(task_file 'repo/feat_generic')" ]; then pass 26b
else fail 26b "rejected 'generic' left state behind: tag='$gtag' file=$(task_file 'repo/feat_generic')"; fi
# the warning must name the CLOSED enum, so the message can't advertise a value
# the write site rejects
gmsg=$(spawn repo feat/generic2 --task generic 2>&1 | grep -i 'unknown --task' | head -1)
case "$gmsg" in
  *generic*want*research*plan*impl*test*scratch*)
    case "$gmsg" in *"|generic"*) fail 26c "the warning still advertises 'generic': $gmsg" ;;
                    *) pass 26c ;; esac ;;
  *) fail 26c "no closed-enum warning for --task generic: '$gmsg'" ;;
esac

echo "== tail: syntax ============================================================"
bash -n "$FLEET"  && pass "syntax-fleet"  || fail "syntax-fleet"  "bin/fleet does not parse"
bash -n "$DASH"   && pass "syntax-dash"   || fail "syntax-dash"   "bin/fleet-dash does not parse"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$FLEETD" \
  && pass "syntax-fleetd" || fail "syntax-fleetd" "bin/fleetd does not parse"

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }

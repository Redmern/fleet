#!/usr/bin/env bash
# Proof harness — S3: the sub-orch WINDOW is self-sufficient (d34 round 2).
#
# THE BUG. A sub-orch window is harness pane + nvim viewer rooted at
# `.fleet/dispatch/<id>/` (bin/fleet, suborch_attach_viewer). The human's whole
# premise — "I go to that window and everything I need is there" — fails twice:
#
#   * THE QUESTION IS NOT THERE. `gate_post` puts the gate body in
#     `.fleet/inbox/*.msg`, which is OUTSIDE the dir the viewer is rooted at. The
#     window shows the evidence and not the question.
#   * THE EVIDENCE IS THERE ONLY IF A MODEL REMEMBERED A CHORE. The symlink farm is
#     pure prose (FLEET_SUBORCH.md §3.0.6); there is no farm `ln -sfn` anywhere in
#     `bin/fleet`. `test/dispatch-symlink-farm.sh` case 6 proves THE MANUAL'S
#     COMMANDS work — it evals them itself — which is precisely not a proof that a
#     live sub-orch ever ran them. The farm can be silently empty.
#
# THE FIX UNDER TEST. `gate_post` also writes `<dispatch-dir>/GATE-<N>.md`; and
# `fleet dispatch farm <id>` is a BASH populator (workers.tsv + the ledger `reports`
# key -> links), called from `dispatch rename` and from `gate post`, so the farm is
# rebuilt by fleet at exactly the two moments the human is about to look at it.
#
# Cases:
#   1.  `gate post 1 -d <id>` writes GATE-1.md into the dispatch dir
#   2.  ...whose FIRST line is the sentinel (bare body — gate_parse parses it)
#   3.  ...and whose content is byte-identical to the inbox message body
#   4.  `gate post` with no -d writes NO stray GATE file (nothing to write it into)
#   5.  re-posting the same gate is last-wins, not an append
#   6.  `dispatch rename` creates the `reports` symlink IN BASH
#   7.  ...pointing at the absolute reports dir, and resolving
#   8.  re-rename re-points the link (ln -sfn semantics, no stale link)
#   9.  a worker row in workers.tsv is linked BY BASH — the sub-orch never runs `ln`
#   10. ...including its notes-<label> link
#   11. `gate post` re-runs the populator, so a farm that was empty at rename is
#       populated by the time the human is looking at the gate
#   12. the populator is idempotent (re-run changes nothing, adds nothing)
#   13. a dangling worker link does not stop the populator (reaped worktree)
#   14. NEGATIVE CONTROL: a dispatch dir with no workers.tsv and no reports key
#       yields no links and no error (fail-silent, gateless fleet unaffected)
#   15. the viewer still attaches and the window still has EXACTLY 2 panes
#       (the npanes>=2 self-heal guard must not be broken by S3)
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

# ---- socket isolation: INTRINSIC, never ambient --------------------------------
# Identical rationale to test/dispatch-symlink-farm.sh: SOCK is derived from our own
# mktemp root and every tmux call is pinned to it, so this file can never reach the
# live fleet server that its own cleanup runs `kill-server` against.
TMPROOT=$(mktemp -d)
# Socket isolation is INTRINSIC, never inherited. Ambient `export TMUX_TMPDIR` is
# NOT enough on its own: any step running in a shell that did not inherit it falls
# back to /tmp/tmux-$(id -u)/default — the REAL server — and then a bare
# `tmux kill-server` in cleanup() tears down the live fleet. So resolve the socket
# HERE, assert it lives under TMPROOT, and inject it with -S on every tmux call via
# the wrapper below. TMUX_TMPDIR is still exported, but only so CHILD processes
# ($FLEET -> tmux) reach the SAME private server; correctness no longer rests on it.
export TMUX_TMPDIR="$TMPROOT/tmuxsock"
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
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FLEET_SESSION="ss_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"

cleanup() { command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }

mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

echo "== d34 S3 — sub-orch window self-sufficiency proof"

# `bash -n` first: a syntax error in the CLI under test would make every case below
# fail for the wrong reason and report as a meaningful RED.
if bash -n "$FLEET" 2>/dev/null; then pass "0 bin/fleet parses"; else
  fail "0 bin/fleet parses" "$(bash -n "$FLEET" 2>&1 | head -3)"; fi

D="$FLEET_ROOT/.fleet/dispatch/d1"; mkdir -p "$D"
tmux new-session -d -s "$FLEET_SESSION" -n "so-d1" 'sleep 9999' 2>/dev/null
sleep 0.3
WID=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk '$2=="so-d1"{print $1; exit}')
printf 'window_id\t%s\n' "$WID" >> "$D/meta.tsv"

# --- 6/7/8. the reports link is created BY BASH at rename ----------------------
"$FLEET" dispatch rename d1 "Gate Ux Rework" >/dev/null 2>&1
slug=$("$FLEET" slug "Gate Ux Rework" 2>/dev/null)
rep=$(mget "$D" reports)
mkdir -p "$rep"; echo plan > "$rep/PLAN-PLAIN.md"
# rename ran before the reports dir existed (the real order: rename, then the agents
# write). Re-run rename so the populator has something to link, exactly as a live
# sub-orch would hit it.
"$FLEET" dispatch rename d1 "Gate Ux Rework" >/dev/null 2>&1
if [ -L "$D/reports" ]; then pass "6 dispatch rename creates the reports symlink in bash"; else
  fail "6 dispatch rename creates the reports symlink in bash" \
       "no $D/reports link — the farm is still model prose"; fi
if [ -f "$D/reports/PLAN-PLAIN.md" ] && [ "$(readlink "$D/reports" 2>/dev/null)" = "$rep" ]; then
  pass "7 reports link is absolute and resolves"
else
  fail "7 reports link is absolute and resolves" \
       "readlink='$(readlink "$D/reports" 2>/dev/null)' want='$rep'"; fi
"$FLEET" dispatch rename d1 "Second Slug" >/dev/null 2>&1
rep2=$(mget "$D" reports); mkdir -p "$rep2"
if [ "$(readlink "$D/reports" 2>/dev/null)" = "$rep2" ]; then
  pass "8 re-rename re-points the link (ln -sfn, no stale link)"
else
  fail "8 re-rename re-points the link" \
       "readlink='$(readlink "$D/reports" 2>/dev/null)' want='$rep2'"; fi

# --- 9/10. a workers.tsv row is linked BY BASH --------------------------------
# The sub-orch in this proof NEVER runs `ln`. It does exactly what §3 tells it to do
# and no more: append the row. If the links appear, fleet made them.
mkdir -p "$FLEET_ROOT/repo/fleet_thing/.fleet/notes"
printf '%s\t%s\t%s\n' "repo" "fleet/thing" "impl" >> "$D/workers.tsv"
"$FLEET" dispatch farm d1 >/dev/null 2>&1
if [ -d "$D/repo-fleet_thing" ]; then
  pass "9 workers.tsv row is linked by bash (no ln in the sub-orch)"
else
  fail "9 workers.tsv row is linked by bash" \
       "no $D/repo-fleet_thing; farm entries: $(ls -A "$D" 2>/dev/null | tr '\n' ' ')"; fi
if [ -d "$D/notes-impl" ]; then
  pass "10 the notes-<label> link is created too"
else
  fail "10 the notes-<label> link is created too" \
       "no $D/notes-impl; entries: $(ls -A "$D" 2>/dev/null | tr '\n' ' ')"; fi

# --- 12. idempotent ------------------------------------------------------------
before=$(ls -A "$D" | sort | tr '\n' ' ')
"$FLEET" dispatch farm d1 >/dev/null 2>&1
after=$(ls -A "$D" | sort | tr '\n' ' ')
# non-vacuous: there must BE links for "unchanged" to mean anything
if [ "$before" = "$after" ] && [ -L "$D/reports" ] && [ -L "$D/repo-fleet_thing" ]; then
  pass "12 populator is idempotent"; else
  fail "12 populator is idempotent" "'$before' -> '$after'"; fi

# --- 13. a dangling link does not stop the populator ---------------------------
mkdir -p "$FLEET_ROOT/repo/fleet_gone/.fleet/notes"
printf '%s\t%s\t%s\n' "repo" "fleet/gone" "test" >> "$D/workers.tsv"
"$FLEET" dispatch farm d1 >/dev/null 2>&1
rm -rf "$FLEET_ROOT/repo/fleet_gone"
if "$FLEET" dispatch farm d1 >/dev/null 2>&1 \
   && [ -L "$D/repo-fleet_gone" ] && [ ! -e "$D/repo-fleet_gone" ] \
   && [ -d "$D/repo-fleet_thing" ]; then
  pass "13 a dangling (reaped) worker link is an inert tombstone the populator tolerates"
else
  fail "13 dangling link tolerated" \
       "rc=$? entries: $(ls -A "$D" 2>/dev/null | tr '\n' ' ')"; fi

# --- 1/2/3/5. gate_post writes GATE-<N>.md into the dispatch dir ---------------
"$FLEET" gate post 1 --slug "$(mget "$D" window | sed 's/^so-d1-//')" \
  --summary "one paragraph" -d d1 >/dev/null 2>&1
if [ -f "$D/GATE-1.md" ]; then pass "1 gate post 1 writes GATE-1.md into the dispatch dir"; else
  fail "1 gate post 1 writes GATE-1.md into the dispatch dir" \
       "the viewer is rooted here and the question is still only in .fleet/inbox"; fi
l1=$(sed -n 1p "$D/GATE-1.md" 2>/dev/null)
case "$l1" in
  \[FLEET-GATE:1*\]*) pass "2 GATE-1.md line 1 is the sentinel (bare body)" ;;
  *) fail "2 GATE-1.md line 1 is the sentinel" "line 1 = '$l1'" ;;
esac
if "$FLEET" gate parse "$D/GATE-1.md" >/dev/null 2>&1; then
  pass "2b the shared oracle parses GATE-1.md (no private grammar)"
else
  fail "2b gate parse accepts GATE-1.md" "gate_parse returned rc 1 on our own artifact"; fi
msg=$(ls -1 "$FLEET_ROOT/.fleet/inbox/"*.msg 2>/dev/null | head -1)
if [ -n "$msg" ] && [ -s "$D/GATE-1.md" ]; then
  # body = everything after the `--` header separator (inbox_body, verbatim)
  body=$(sed -n '/^--$/,$p' "$msg" | sed '1d')
  if [ "$body" = "$(cat "$D/GATE-1.md")" ]; then
    pass "3 GATE-1.md is byte-identical to the inbox body"
  else
    fail "3 GATE-1.md is byte-identical to the inbox body" "they differ"; fi
else
  fail "3 GATE-1.md is byte-identical to the inbox body" "no .msg was written"; fi
sz1=$(wc -c < "$D/GATE-1.md" 2>/dev/null)
"$FLEET" gate post 1 --slug "$(mget "$D" window | sed 's/^so-d1-//')" \
  --summary "one paragraph" -d d1 >/dev/null 2>&1
sz2=$(wc -c < "$D/GATE-1.md" 2>/dev/null)
if [ "${sz1:-0}" = "${sz2:-1}" ]; then pass "5 re-post is last-wins, not an append"; else
  fail "5 re-post is last-wins" "$sz1 -> $sz2 bytes"; fi

# --- 11. gate post re-runs the populator --------------------------------------
rm -f "$D/reports" "$D/repo-fleet_thing" "$D/notes-impl"
"$FLEET" gate post 1 --slug x --summary y -d d1 >/dev/null 2>&1
if [ -L "$D/reports" ] && [ -L "$D/repo-fleet_thing" ]; then
  pass "11 gate post rebuilds the farm (the human looks at the window NOW)"
else
  fail "11 gate post rebuilds the farm" \
       "entries: $(ls -A "$D" 2>/dev/null | tr '\n' ' ')"; fi

# --- 4. no -d => no stray GATE file -------------------------------------------
strays_before=$(find "$FLEET_ROOT/.fleet/dispatch" -name 'GATE-*.md' | wc -l)
"$FLEET" gate post 1 --slug loose --summary z >/dev/null 2>&1
strays_after=$(find "$FLEET_ROOT/.fleet/dispatch" -name 'GATE-*.md' | wc -l)
if [ "$strays_before" = "$strays_after" ]; then
  pass "4 gate post without -d writes no stray GATE file"
else
  fail "4 gate post without -d writes no stray GATE file" "$strays_before -> $strays_after"; fi

# --- 14. NEGATIVE CONTROL: empty dispatch dir ---------------------------------
E="$FLEET_ROOT/.fleet/dispatch/d9"; mkdir -p "$E"
"$FLEET" dispatch farm d9 >/dev/null 2>&1; rc=$?
n=$(ls -A "$E" 2>/dev/null | grep -c .)
if [ "$rc" = 0 ] && [ "${n:-0}" = 0 ]; then
  pass "14 negative control: no workers.tsv + no reports key => no links, rc 0"
else
  fail "14 negative control" "rc=$rc entries=$n"; fi

# --- 15. the viewer still attaches, window still has EXACTLY 2 panes ----------
if command -v nvim >/dev/null 2>&1; then
  "$FLEET" attach-viewer "$WID" "$D" >/dev/null 2>&1
  sleep 0.4
  np=$(tmux list-panes -t "$WID" -F '#{pane_id}' 2>/dev/null | grep -c .)
  vw=$(tmux list-panes -t "$WID" -F '#{@fleet_viewer}' 2>/dev/null | grep -c '^1$')
  if [ "${np:-0}" = 2 ] && [ "${vw:-0}" = 1 ]; then
    pass "15 viewer attaches; window has exactly 2 panes (heal guard intact)"
  else
    fail "15 viewer attaches; exactly 2 panes" "npanes=$np viewer-flagged=$vw"; fi
else
  echo "  SKIP(15): nvim not installed"
fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

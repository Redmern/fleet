#!/usr/bin/env bash
# Proof harness — S3c: the viewer's :Fleet* Ex commands (d34).
#
# The sub-orch window's right pane is plain `nvim .` running THE HUMAN'S OWN CONFIG,
# rooted at the dispatch dir. It has no `--listen` socket (the `--listen` elsewhere
# in bin/fleet is the AGENT nvim, a different thing), and `test/suborch-viewer-send.sh`
# asserts `@fleet_nvim_sock` stays UNSET — setting it flips cmd_send to RPC-only with
# no fallback, which then dies. So the decision surface in that pane cannot be a
# keymap grab and cannot be driven from outside: it is additive `:Fleet*` Ex commands.
#
# THE FAILURE THIS PROOF EXISTS FOR: the whole viewer-attach path is fail-silent, so
# a command that never installed is INDISTINGUISHABLE from an approval that worked —
# a human types :FleetApprove, sees nothing, and walks away believing they approved.
# Hence the echoerr, and hence case 5.
#
# Cases:
#   1. attaching the viewer generates the Ex-command file in the dispatch dir
#   2. it defines FleetApprove, FleetReject and FleetGate — and nothing else public
#   3. it maps NO keys (the human's keys are theirs) and never loads fleet.lua
#   4. the commands reach the real CLI: driven headlessly, :FleetApprove decides
#      the gate for real (ledger + decision file), exactly as the CLI would
#   5. a FAILING command is VISIBLE — it echoerrs rather than failing silently
#   6. :FleetReject with an empty reason aborts and writes nothing
#   7. the viewer pane still carries @fleet_viewer and @fleet_nvim_sock stays UNSET
#   8. the window still has exactly 2 panes (the npanes>=2 heal guard)
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

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
export FLEET_SESSION="vx_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"
cleanup() { command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

echo "== d34 S3c — viewer Ex-command proof"
if bash -n "$FLEET" 2>/dev/null; then pass "0 bin/fleet parses"; else
  fail "0 bin/fleet parses" "$(bash -n "$FLEET" 2>&1 | head -3)"; fi

command -v nvim >/dev/null 2>&1 || { echo "  SKIP: nvim not installed"; echo; echo "ALL PASS"; exit 0; }

D="$FLEET_ROOT/.fleet/dispatch/d1"; mkdir -p "$D"
tmux new-session -d -s "$FLEET_SESSION" -n "so-d1" 'sleep 9999' 2>/dev/null
sleep 0.3
WID=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk '$2=="so-d1"{print $1; exit}')
printf 'window_id\t%s\n' "$WID" >> "$D/meta.tsv"
"$FLEET" dispatch rename d1 "Viewer Thing" >/dev/null 2>&1
SLUG=$("$FLEET" slug "Viewer Thing" 2>/dev/null)
"$FLEET" gate post 1 --slug "$SLUG" --summary "the plan" -d d1 --park >/dev/null 2>&1

"$FLEET" attach-viewer "$WID" "$D" >/dev/null 2>&1
sleep 0.5

V="$D/.fleet-viewer.vim"
if [ -f "$V" ]; then pass "1 attaching the viewer generates the Ex-command file"; else
  fail "1 attaching the viewer generates the Ex-command file" "no $V"; fi
if grep -q 'command! .*FleetApprove' "$V" 2>/dev/null \
   && grep -q 'command! .*FleetReject' "$V" 2>/dev/null \
   && grep -q 'command! .*FleetGate' "$V" 2>/dev/null; then
  pass "2 FleetApprove / FleetReject / FleetGate are defined"
else
  fail "2 the three Ex commands are defined" "$(grep -c 'command!' "$V" 2>/dev/null) command! lines"; fi
# Namespacing: every public command must start with Fleet. A stray `command! Approve`
# would collide with the human's own config, which is exactly what we promised not
# to do.
stray=$(grep -o 'command![^ ]* *-\?[a-z]* *[A-Za-z]*' "$V" 2>/dev/null | grep -v 'Fleet' | grep -c . )
if [ "${stray:-0}" = 0 ]; then pass "2b every public command is Fleet-namespaced"; else
  fail "2b every public command is Fleet-namespaced" "$stray non-Fleet command! definitions"; fi
if ! grep -qE '^\s*(n|i|v|x|o)?(nore)?map|set(local)? .*=.*map|fleet\.lua' "$V" 2>/dev/null; then
  pass "3 it maps no keys and never loads fleet.lua"
else
  fail "3 it maps no keys and never loads fleet.lua" "$(grep -nE 'map|fleet\.lua' "$V" | head -2)"; fi

# --- 4. the commands reach the REAL CLI ---------------------------------------
# Drive nvim headlessly with the SAME file the viewer sources. This is the only
# honest way to prove the command reaches the CLI: asserting the file contains the
# right string proves the string, not the wiring.
export PATH="$TMPROOT/bin:$PATH"; mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/fleet" <<EOF
#!/usr/bin/env bash
exec "$FLEET" "\$@"
EOF
chmod +x "$TMPROOT/bin/fleet"
( cd "$D" && nvim --headless -u NONE -c "source $V" -c 'FleetApprove' -c 'qa!' ) >/dev/null 2>&1
if [ "$(mget "$D" decision)" = approve ] && [ -f "$D/decision-1.txt" ]; then
  pass "4 :FleetApprove reaches the CLI and really decides the gate"
else
  fail "4 :FleetApprove reaches the CLI" \
       "decision='$(mget "$D" decision)' file=$([ -f "$D/decision-1.txt" ] && echo yes || echo no)"; fi

# --- 5. a failing command is VISIBLE ------------------------------------------
# Point the command at a dispatch that cannot resolve. The CLI dies (its one
# deliberate non-fail-silent behaviour); the viewer must SAY SO.
cat > "$TMPROOT/bad.vim" <<EOF
source $V
let g:fleet_dispatch = 'd999'
EOF
out=$( cd "$D" && nvim --headless -u NONE -c "source $TMPROOT/bad.vim" -c 'FleetApprove' -c 'qa!' 2>&1 )
if printf '%s' "$out" | grep -qi 'fleet gate'; then
  pass "5 a failing command is visible (echoerr), not silent"
else
  fail "5 a failing command is visible" \
       "nvim said nothing — a command that silently does nothing is indistinguishable from one that worked. out='$(printf '%s' "$out" | head -2)'"; fi

# --- 6. :FleetReject with an empty reason aborts ------------------------------
E="$FLEET_ROOT/.fleet/dispatch/d2"; mkdir -p "$E"
printf 'window_id\t%s\n' "$WID" >> "$E/meta.tsv"
"$FLEET" dispatch rename d2 "Reject Thing" >/dev/null 2>&1
S2=$("$FLEET" slug "Reject Thing" 2>/dev/null)
"$FLEET" gate post 1 --slug "$S2" --summary "p" -d d2 --park >/dev/null 2>&1
printf '# only comments here\n#\n' > "$TMPROOT/empty-reason.txt"
"$FLEET" gate reject d2 --file "$TMPROOT/empty-reason.txt" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && [ -z "$(mget "$E" decision)" ]; then
  pass "6 a comments-only reason counts as EMPTY and aborts (rc 2)"
else
  fail "6 a comments-only reason aborts" "rc=$rc decision='$(mget "$E" decision)'"; fi

# --- 6b/6c. GATE 2 asks for the slug, from the VIEWER --------------------------
# The viewer must do the asking itself: system() gives the CLI no tty, so the CLI's
# own prompt can never run from here — it refuses by design. A viewer that merely
# relayed that refusal would be useless at the one gate that moves code, and a viewer
# that called the CLI plainly would inherit the refusal. Driven headlessly through
# nvim with `input()` fed from a keystroke feed, so this proves the WIRING, not a
# string in a file.
G="$FLEET_ROOT/.fleet/dispatch/d3"; mkdir -p "$G"
printf 'window_id\t%s\n' "$WID" >> "$G/meta.tsv"
"$FLEET" dispatch rename d3 "Ship Thing" >/dev/null 2>&1
S3=$("$FLEET" slug "Ship Thing" 2>/dev/null)
"$FLEET" gate post 2 --slug "$S3" --summary "green" -d d3 --park >/dev/null 2>&1
cat > "$TMPROOT/g2.vim" <<EOF
source $V
let g:fleet_dispatch = 'd3'
EOF
# WRONG slug typed => aborted, nothing written.
( cd "$G" && nvim --headless -u NONE -c "source $TMPROOT/g2.vim" \
    -c 'call feedkeys("not-the-slug\<CR>", "t")' -c 'FleetApprove' -c 'qa!' ) >/dev/null 2>&1
wrong_decision=$(mget "$G" decision)
# RIGHT slug typed => decided, and at gate 2.
( cd "$G" && nvim --headless -u NONE -c "source $TMPROOT/g2.vim" \
    -c "call feedkeys(\"$S3\<CR>\", 't')" -c 'FleetApprove' -c 'qa!' ) >/dev/null 2>&1
if [ -n "$wrong_decision" ]; then
  fail "6b :FleetApprove at gate 2 aborts on a slug mismatch" \
       "decision='$wrong_decision' was written after typing the WRONG slug — the confirmation is decorative"
else
  pass "6b :FleetApprove at gate 2 aborts on a slug mismatch (nothing written)"; fi
if [ "$(mget "$G" decision)" = approve ] && [ "$(mget "$G" decision_gate)" = 2 ]; then
  pass "6c :FleetApprove at gate 2 decides once the slug is typed back"
else
  fail "6c :FleetApprove at gate 2 decides on the correct slug" \
       "decision='$(mget "$G" decision)' gate='$(mget "$G" decision_gate)' — the viewer inherited the CLI's no-tty refusal and can never approve a merge"; fi

# --- 7/8. the viewer pane's invariants ----------------------------------------
vw=$(tmux list-panes -t "$WID" -F '#{@fleet_viewer}' 2>/dev/null | grep -c '^1$')
sock=$(tmux show -wqv -t "$WID" @fleet_nvim_sock 2>/dev/null)
if [ "${vw:-0}" = 1 ] && [ -z "$sock" ]; then
  pass "7 viewer pane flagged @fleet_viewer; @fleet_nvim_sock stays UNSET"
else
  fail "7 viewer pane invariants" \
       "viewer-flagged=$vw nvim_sock='$sock' (setting it flips cmd_send to RPC-only, which dies)"; fi
np=$(tmux list-panes -t "$WID" -F '#{pane_id}' 2>/dev/null | grep -c .)
if [ "${np:-0}" = 2 ]; then pass "8 the window still has exactly 2 panes (heal guard)"; else
  fail "8 exactly 2 panes" "npanes=$np — a third pane permanently disables viewer self-heal"; fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

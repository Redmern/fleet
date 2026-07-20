#!/usr/bin/env bash
# Meta-harness — prove the OTHER tmux harnesses can never reach the REAL tmux server.
#
# WHY THIS EXISTS. Socket isolation used to be AMBIENT: each harness did
# `export TMUX_TMPDIR=…` and every tmux call went bare. That is source-dependent —
# any step running in a shell that did not inherit the variable falls back to
# /tmp/tmux-$(id -u)/default, the REAL server, and then `tmux kill-server` in
# cleanup() tears down the live fleet. It happened: on 2026-07-20 the real server
# went down and sessions pc + techweb2 had to be recreated, orphaning the in-flight
# dispatch gates. The harnesses now resolve one explicit `$SOCK` under their own
# TMPROOT, guard it fail-fast, and route every tmux call through a `tmux()` wrapper
# defined in the same file. Nothing verified that those guards actually FIRE —
# an unfired guard and a correct guard look identical on a green run. This file is
# that verification.
#
# THE SAFETY PROBLEM IN TESTING A GUARD, AND THE DESIGN THAT SOLVES IT.
# To prove a guard refuses the real socket you must run it with SOCK poisoned to
# the real socket — but if the guard is broken, that run does the exact damage
# being tested for. A naive `FLEET_HARNESS_SOCK=/tmp/tmux-$(id -u)/default bash
# harness.sh` is a live grenade: it is only safe if the thing it is testing works.
# So the real-socket case is NEVER run against a full harness. Instead [2] extracts
# the guard block ALONE — from the SOCK assignment through the wrapper definition,
# with no tmux call anywhere after it — appends a REACHED marker, and poisons THAT.
# A broken guard prints REACHED; it has nothing to tear down. The full-harness
# fault injection in [3] is therefore restricted to a poison path that is merely
# outside TMPROOT (a scratch path), where even total guard failure is harmless.
# The real socket is only ever READ (`tmux -S … ls`, `has-session`), never written.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
HARNESSES="reap-teardown-safety.sh reap-tracked-notes-proof.sh suborch-wake-proof.sh"
REAL_SOCK="/tmp/tmux-$(id -u)/default"
# Snapshot the real server BEFORE anything runs — [5] compares against this. Read-only.
BEFORE=$(command tmux -S "$REAL_SOCK" ls 2>/dev/null | sort)

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }   # no tmux call: this harness starts no server
trap cleanup EXIT

pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }
FAILED=0

# Code lines only — a comment mentioning `command tmux` is not a call, and counting
# comments is how an earlier version of this file false-failed.
code() { grep -vE '^[[:space:]]*#' "$1"; }

# --- 1. every harness carries the intrinsic-isolation contract ----------------
echo "[1] static contract: guard + wrapper + socket-scoped kills"
for h in $HARNESSES; do
  f="$HERE/test/$h"
  [ -f "$f" ] || { fail "$h: present" "missing"; continue; }

  code "$f" | grep -q 'SOCK="\${FLEET_HARNESS_SOCK:-\$TMUX_TMPDIR/tmux-\$(id -u)/default}"' \
    && pass "$h: SOCK resolved from TMUX_TMPDIR, overridable only for testing" \
    || fail "$h: SOCK resolution" "SOCK is not the guarded, overridable form"

  code "$f" | grep -q '^tmux() { command tmux -S "\$SOCK" "\$@"; }' \
    && pass "$h: tmux() wrapper injects -S \$SOCK" \
    || fail "$h: tmux() wrapper" "wrapper missing or altered"

  code "$f" | grep -q 'REFUSE: harness resolved to the real tmux socket' \
    && pass "$h: guard arm 1 (real socket)" || fail "$h: guard arm 1" "missing"
  code "$f" | grep -q 'REFUSE: harness socket is not under TMPROOT' \
    && pass "$h: guard arm 2 (outside TMPROOT)" || fail "$h: guard arm 2" "missing"

  # tmux refuses a default-resolved socket dir that is group/world accessible, so
  # the 700 is load-bearing for CHILD processes ($FLEET -> tmux), not cosmetic.
  code "$f" | grep -q 'chmod 700 "\$TMUX_TMPDIR/tmux-\$(id -u)"' \
    && pass "$h: socket dir chmod 700" || fail "$h: socket dir chmod 700" "missing"

  # Any `command tmux` bypasses the wrapper by design; each one must carry -S itself.
  bad=$(code "$f" | grep -n 'command tmux' | grep -v 'command tmux -S "\$SOCK"')
  [ -z "$bad" ] && pass "$h: every 'command tmux' is socket-scoped" \
    || fail "$h: every 'command tmux' is socket-scoped" "$bad"

  # No absolute tmux path can sneak past the wrapper.
  code "$f" | grep -qE '(/usr/bin/|/bin/)tmux' \
    && fail "$h: no absolute tmux path" "absolute path bypasses the wrapper" \
    || pass "$h: no absolute tmux path"

  # Server-destroying calls must state their socket literally, not merely inherit
  # the wrapper — this is the call that caused the outage.
  ks=$(code "$f" | grep 'kill-server')
  if [ -n "$ks" ] && ! printf '%s\n' "$ks" | grep -qv 'command tmux -S "\$SOCK" kill-server'; then
    pass "$h: kill-server is explicitly socket-scoped"
  elif [ -z "$ks" ]; then pass "$h: no kill-server"
  else fail "$h: kill-server is explicitly socket-scoped" "$ks"; fi

  # ORDER: the guard must precede the first tmux call, or it guards nothing.
  gline=$(grep -n 'REFUSE: harness resolved to the real tmux socket' "$f" | head -1 | cut -d: -f1)
  tline=$(grep -nE '(^|[^-[:alnum:]_])tmux ' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' \
          | grep -v 'REFUSE' | head -1 | cut -d: -f1)
  if [ -n "$gline" ] && { [ -z "$tline" ] || [ "$gline" -lt "$tline" ]; }; then
    pass "$h: guard precedes first tmux call (line $gline < ${tline:-none})"
  else fail "$h: guard precedes first tmux call" "guard@${gline:-none} tmux@${tline:-none}"; fi
done

# --- 2. INERT fault injection: the guard refuses the REAL socket ---------------
# The extracted block contains no tmux call, so a broken guard reaches REACHED and
# destroys nothing. This is the only place the real socket path is used as a poison.
echo "[2] guard refuses the REAL socket (inert extraction — cannot damage anything)"
for h in $HARNESSES; do
  f="$HERE/test/$h"; [ -f "$f" ] || continue
  snip="$TMPROOT/guard-$h"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -u'
    echo 'TMPROOT=$(mktemp -d)'
    echo 'export TMUX_TMPDIR="$TMPROOT/tmuxsock"'
    sed -n '/^SOCK="${FLEET_HARNESS_SOCK/,/^tmux() { command tmux -S/p' "$f"
    echo 'echo REACHED'
  } > "$snip"

  # sanity: the extraction must actually have captured the guard, else [2] is vacuous
  if ! grep -q 'REFUSE: harness resolved to the real tmux socket' "$snip"; then
    fail "$h: guard block extracted" "extraction captured no guard — assertion would be vacuous"
    continue
  fi

  out=$(FLEET_HARNESS_SOCK="$REAL_SOCK" bash "$snip" 2>&1); rc=$?
  if printf '%s' "$out" | grep -q REACHED; then
    fail "$h: refuses the real socket" "GUARD DID NOT FIRE — body reached with SOCK=$REAL_SOCK"
  elif [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'REFUSE: harness resolved to the real tmux socket'; then
    pass "$h: refuses the real socket (rc=$rc)"
  else
    fail "$h: refuses the real socket" "rc=$rc out='$out'"
  fi
done

# --- 3. full-harness fault injection, poisoned OUTSIDE TMPROOT ----------------
# Exercises the whole file end-to-end. The poison is a scratch path, never the real
# socket, so a guard failure here starts a stray server instead of killing the fleet.
echo "[3] full harness refuses a socket outside TMPROOT"
for h in $HARNESSES; do
  [ -f "$HERE/test/$h" ] || continue
  out=$(cd "$HERE" && FLEET_HARNESS_SOCK="$TMPROOT/outside/harness.sock" \
        timeout 120 bash "test/$h" 2>&1); rc=$?
  if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'REFUSE: harness socket is not under TMPROOT'; then
    pass "$h: full harness refuses (rc=1)"
  else
    fail "$h: full harness refuses" "rc=$rc first='$(printf '%s' "$out" | head -1)'"
  fi
done

# --- 4. TMUX_TMPDIR unset is a NO-OP -----------------------------------------
# The point of intrinsic isolation: correctness must not rest on the ambient var.
# A harness that REFUSED here would prove it was still ambient-dependent, so the
# expected result is a normal green run — not a refusal.
echo "[4] TMUX_TMPDIR unset is a no-op (isolation is intrinsic, not inherited)"
for h in $HARNESSES; do
  [ -f "$HERE/test/$h" ] || continue
  out=$(cd "$HERE" && env -u TMUX_TMPDIR timeout 600 bash "test/$h" 2>&1); rc=$?
  if printf '%s' "$out" | grep -q 'REFUSE:'; then
    fail "$h: runs with TMUX_TMPDIR unset" "refused — isolation is still ambient-dependent"
  elif [ "$rc" = 0 ]; then
    pass "$h: runs green with TMUX_TMPDIR unset"
  else
    # rc!=0 is a REAL failure. An earlier version of this file accepted rc=1 as long
    # as some PASS( appeared in the output, which masked a genuine regression.
    fail "$h: runs green with TMUX_TMPDIR unset" "rc=$rc last='$(printf '%s' "$out" | tail -1)'"
  fi
done

# --- 5. the real server is provably untouched --------------------------------
echo "[5] real tmux server untouched by everything above"
after=$(command tmux -S "$REAL_SOCK" ls 2>/dev/null | sort)
if [ "$BEFORE" = "$after" ]; then
  pass "real socket session list unchanged"
  printf '%s\n' "$after" | sed 's/^/      /'
else
  fail "real socket session list unchanged" "BEFORE:[$BEFORE] AFTER:[$after]"
fi
if command tmux -S "$REAL_SOCK" has-session -t pc 2>/dev/null; then
  pass "session 'pc' still exists"
else
  fail "session 'pc' still exists" "pc is gone — a harness escaped its sandbox"
fi
if [ -n "$BEFORE" ]; then
  pass "real server was running throughout (so [5] was a meaningful check)"
else
  fail "real server was running throughout" "no sessions listed at start — [5] proved nothing"
fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }

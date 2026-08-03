# shellcheck shell=bash
# Shared preamble for the d32 "hidden from the tmux bar" proofs.
#
# WHY A SHARED FILE. The isolation preamble is ~70 lines of load-bearing safety
# (a past incident: a proof's cleanup `kill-server` took down the live command
# center). Six copies of it drift; one copy does not. Sourcing is safe here
# because `proof_isolate` DEFINES the `tmux` wrapper in the SOURCING shell — the
# same shell that makes every tmux call — so the "wrapper lives in the file that
# calls it" property from test/suborch-viewer-liveness.sh is preserved, not lost.
#
# Contract for callers:
#   . "$(dirname "$0")/hidden-proof-common.sh"
#   proof_isolate            # TMPROOT, throwaway tmux server, XDG, PATH shims
#   proof_session t1         # create the visible session, stamp @fleet_root
#   ...assertions via ok/no/chk...
#   proof_summary            # prints the tally, exits non-zero on any FAIL
#
# Every proof runs against a THROWAWAY tmux server on a socket inside its own
# mktemp dir, with XDG_RUNTIME_DIR redirected so `rpc` can never reach the real
# fleetd and no real ledger is touched.

FLEET_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Explicitly the bin/ NEXT TO THIS SCRIPT — never ~/.local/bin/fleet or $PATH,
# which may be a symlink into a different checkout. The whole point is to
# exercise the UNCOMMITTED worktree.
FLEET="${FLEET_BIN:-$FLEET_REPO/bin/fleet}"
FLEET_DASH="$FLEET_REPO/bin/fleet-dash"

PASS_N=0; FAIL_N=0

ok()  { PASS_N=$((PASS_N+1)); printf 'PASS  %s\n' "$*"; }
no()  { FAIL_N=$((FAIL_N+1)); printf 'FAIL  %s\n' "$*"; }
chk() { # chk <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$2', got '$3')"; fi
}
chk_ne() { # chk_ne <desc> <not-expected> <actual>
  if [ "$2" != "$3" ]; then ok "$1"; else no "$1 (got the forbidden value '$3')"; fi
}
section() { printf '\n== %s\n' "$*"; }

proof_summary() {
  printf '\n---- %s: %d passed, %d failed\n' "$(basename "$0")" "$PASS_N" "$FAIL_N"
  [ "$FAIL_N" -eq 0 ] || exit 1
  exit 0
}

# ---- isolation ---------------------------------------------------------------
proof_isolate() {
  local inherited_tmpdir="${TMUX_TMPDIR:-/tmp}"   # captured BEFORE we overwrite it
  TMPROOT=$(mktemp -d)

  # TMUX_TMPDIR has to be exported: `bin/fleet` (the code under test) calls tmux
  # itself and resolves the server from it. We pin OUR calls to the same path so
  # both sides talk to one throwaway server, and a lost export can never redirect
  # us onto the real one.
  export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR"
  SOCK="${FLEET_TEST_SOCK:-$TMUX_TMPDIR/tmux-$(id -u)/default}"
  # 0700 is REQUIRED: tmux refuses a socket dir with "unsafe permissions" for any
  # DEFAULT-socket caller — which is exactly what bin/fleet is. At the umask
  # default every fleet-side tmux call fails fail-silently and the proof would
  # report PASS while asserting nothing.
  mkdir -p "$(dirname "$SOCK")" 2>/dev/null && chmod 700 "$(dirname "$SOCK")" 2>/dev/null

  # Defined in the SOURCING shell — every tmux call in every proof goes through it.
  tmux() { command tmux -S "$SOCK" "$@"; }

  # Fail-fast BEFORE any tmux call. FLEET_TEST_SOCK exists only so a safety proof
  # can inject a hostile value: it can only ever FAIL these checks, never bypass.
  local realsock="/tmp/tmux-$(id -u)/default"
  case "$SOCK" in
    "$realsock"|"$inherited_tmpdir/tmux-$(id -u)/default")
      echo "REFUSE: proof resolved to the real tmux socket ($SOCK)" >&2
      rm -rf "$TMPROOT"; exit 1 ;;
  esac
  case "$SOCK" in
    "$TMPROOT"/*) ;;
    *) echo "REFUSE: socket '$SOCK' is outside the proof TMPROOT ($TMPROOT)" >&2
       rm -rf "$TMPROOT"; exit 1 ;;
  esac

  # d38: TMUX_TMPDIR itself, not only the derived SOCK. FLEET_TEST_SOCK can move
  # SOCK back inside TMPROOT while TMUX_TMPDIR still points at the real server —
  # and `bin/fleet` (the code under test) resolves its OWN server from TMUX_TMPDIR,
  # not from our wrapper. Half-isolation is what let the 2026-08-02 fixture write
  # the live ledger; a harness that can be half-used is the thing being fixed.
  case "$TMUX_TMPDIR" in
    "$TMPROOT"/*) ;;
    *) echo "REFUSE: TMUX_TMPDIR '$TMUX_TMPDIR' is outside the proof TMPROOT ($TMPROOT)" >&2
       rm -rf "$TMPROOT"; exit 1 ;;
  esac

  export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
  export XDG_RUNTIME_DIR="$TMPROOT/run";    mkdir -p "$XDG_RUNTIME_DIR"  # no real fleetd
  unset TMUX TMUX_PANE                                   # never inherit the live server

  # AMBIENT FLEET ENV. A proof is frequently RUN FROM a fleet pane — often a
  # sub-orchestrator's — and every var that pane carries is inherited by the
  # `bin/fleet` under test. Each of these changes cmd_new's OBSERVABLE output, so
  # a leak turns a green proof red in a way indistinguishable from a real spawn
  # failure ("agent never spawned"). Scrubbed, one reason each:
  #   FLEET_SUBORCH_ID      cmd_new owner-prefixes the window name (`d32-parked`
  #                         instead of `parked`) and stamps @fleet_owner, so every
  #                         `wait_window <name>` in every proof misses.
  #   FLEET_NEW_SUBORCH_ID  gates that same branch off; leaked, it would MASK the
  #                         prefix and also inject -e FLEET_SUBORCH_ID into spawns.
  #   FLEET_NEW_WID_FILE    cmd_new writes the new window id to it — a path outside
  #                         TMPROOT, i.e. a proof scribbling on the live ledger.
  #   FLEET_HARNESS         first in harness_select's precedence, so it overrides
  #                         the default `claude` the PATH shim below stands in for;
  #                         the real (or a missing) harness would launch instead.
  # Deliberately NOT scrubbed: FLEET_ROLE, FLEET_DOCS, FLEET_SELF_MERGE,
  # FLEET_PROMPT, FLEET_AUTOCLAUDE, FLEET_HARNESS_BIN, FLEET_START_MODE,
  # FLEET_TERM_MATCH — cmd_new only ever WRITES these onto the spawned pane with
  # `tmux -e`; it never reads the ambient value, so they cannot alter behaviour.
  # FLEET_SESSION/FLEET_ROOT are not unset but OVERWRITTEN below/by proof_session.
  unset FLEET_SUBORCH_ID FLEET_NEW_SUBORCH_ID FLEET_NEW_WID_FILE FLEET_HARNESS

  export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet"

  # A fake harness. harness.d/claude.conf's H_BIN is "claude-profile claude" and
  # "first on PATH wins" — shim BOTH or the REAL claude launches (and blocks on
  # its trust prompt, so the pane never runs anything the proof can drive).
  # `exec /bin/sh` deliberately drops "$@": fleet appends --permission-mode.
  BIN="$TMPROOT/bin"; mkdir -p "$BIN"
  { echo '#!/bin/sh'; echo 'exec /bin/sh'; } > "$BIN/claude"
  chmod +x "$BIN/claude"; cp "$BIN/claude" "$BIN/claude-profile"
  export PATH="$BIN:$PATH"

  # kill-server is SCOPED by the wrapper above to `-S "$SOCK"`, so it can only
  # ever kill our own server. rm -rf targets the ONE dir we created — never a glob.
  trap 'tmux kill-server 2>/dev/null || true; rm -rf "$TMPROOT"' EXIT
}

# ---- fixtures ----------------------------------------------------------------

proof_session() { # proof_session <name> — visible fleet session with @fleet_root
  local s="$1"
  export FLEET_SESSION="$s"
  tmux new-session -d -s "$s" -n main sh 2>/dev/null
  # FLEET_PROOF_ROOT_OVERRIDE exists ONLY so a safety proof can inject a deliberate
  # disagreement, exactly like FLEET_TEST_SOCK above: it can fail the tripwire below,
  # never bypass it.
  tmux set -t "$s" @fleet_root "${FLEET_PROOF_ROOT_OVERRIDE:-$FLEET_ROOT}" 2>/dev/null
  proof_root_tripwire
}

# d38 P6 — REFUSE TO RUN HALF-ISOLATED. `fleet_root()` reads tmux @fleet_root FIRST
# and FLEET_ROOT second, so a fixture that isolates only the env variable runs
# against whatever project tmux names. On 2026-08-02 that was the live one: a gate
# parked on the human's real d1, a message in their real inbox, and their own pop
# stamped onto it. The escaping fixture simply did not source this file — which is
# the argument for making the harness impossible to half-use, rather than for adding
# one more thing a fixture author must remember.
#
# Fail-CLOSED, unlike the rest of fleet: a proof that silently runs against the
# wrong root is worse than a proof that does not run.
proof_root_tripwire() {
  local t; t=$(tmux show -v @fleet_root 2>/dev/null)
  if [ "$t" != "${FLEET_ROOT:-}" ]; then
    echo "REFUSE: FLEET_ROOT ('${FLEET_ROOT:-}') and tmux @fleet_root ('$t') disagree — half-isolated fixture" >&2
    tmux kill-server 2>/dev/null || true
    rm -rf "$TMPROOT"; exit 1
  fi
  case "${FLEET_ROOT:-}" in
    "$TMPROOT"/*) ;;
    *) echo "REFUSE: FLEET_ROOT ('${FLEET_ROOT:-}') is outside the proof TMPROOT ($TMPROOT)" >&2
       tmux kill-server 2>/dev/null || true
       rm -rf "$TMPROOT"; exit 1 ;;
  esac
}

pane_of() { # pane_of <window-name> -> pane id (first match, any session)
  tmux list-panes -a -F '#{window_name}	#{pane_id}' 2>/dev/null \
    | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'
}
sess_of() { # sess_of <window-name> -> session name
  tmux list-panes -a -F '#{window_name}	#{session_name}' 2>/dev/null \
    | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'
}
win_of() { # win_of <window-name> -> window id
  tmux list-panes -a -F '#{window_name}	#{window_id}' 2>/dev/null \
    | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'
}

# Run a fleet command FROM INSIDE a pane, with FLEET_SESSION deliberately blanked
# so the caller-relative session_name() path is the one under test — that is the
# exact condition a sub-orch spawn runs under (FLEET_SESSION is exported only by
# `fleet up`/`main`/`restore`, never into a scratch spawn).
# Echoes the command's combined output; returns its exit status.
in_pane() { # in_pane <pane-id> <command string...>
  local pane="$1"; shift
  local tag="p$$_$RANDOM" out="$TMPROOT/inpane.$$.$RANDOM"
  tmux send-keys -t "$pane" \
    "FLEET_SESSION= $* > $out 2>&1; echo $tag:\$? >> $out" Enter 2>/dev/null
  local i rc=""
  for i in $(seq 200); do
    rc=$(grep -o "$tag:[0-9]*" "$out" 2>/dev/null | head -1) && [ -n "$rc" ] && break
    sleep 0.1
  done
  grep -v "^$tag:" "$out" 2>/dev/null
  [ -n "$rc" ] || return 99          # never fired: treat as a hard failure
  return "${rc#*:}"
}

# Wait until a session exists (spawns inside a pane are asynchronous).
wait_session() { # wait_session <name> [tries]
  local i; for i in $(seq "${2:-40}"); do
    tmux has-session -t "=$1" 2>/dev/null && return 0; sleep 0.1
  done; return 1
}
wait_window() { # wait_window <window-name> [tries]
  local i; for i in $(seq "${2:-40}"); do
    [ -n "$(pane_of "$1")" ] && return 0; sleep 0.1
  done; return 1
}

# Make a window visible to agents_tsv's daemon-DOWN fallback, which keys on the
# @agent_state window option (normally mirrored there by fleetd). No daemon runs
# in any proof, so this is how a fixture agent gets a row.
mark_agent() { # mark_agent <window-id> [state]
  tmux set -w -t "$1" @agent_state "${2:-idle}" 2>/dev/null || true
  tmux set -w -t "$1" @fleet_harness claude 2>/dev/null || true
}

# List every session on the throwaway server.
sessions() { tmux list-sessions -F '#{session_name}' 2>/dev/null | sort; }

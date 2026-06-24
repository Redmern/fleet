#!/usr/bin/env bash
# Layer B — REAL @fleet_owner path (does NOT stub owner_of).
#
# Spins a throwaway private tmux server (`tmux -L <sock>`, never the live
# server), sets the real `@fleet_owner` *window* option on a worker window, and
# asserts the dash's owner_of() reads it back via `tmux show -wqv` — returning
# the owning so-<id> for the worker window and "" for the sub-orch window itself.
#
# Feature is NOT implemented yet: owner_of() does not exist in bin/fleet-dash, so
# every owner_of call resolves to nothing and the assertions MUST FAIL. After the
# feature lands the same calls hit the real option and pass.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not available — real-@fleet_owner path not exercised"
  exit 0
fi

SOCK="fleettest_$$"
TMP=$(mktemp -d)
SOCK_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
teardown() {
  command tmux -L "$SOCK" kill-server 2>/dev/null
  rm -f "$SOCK_DIR/$SOCK" 2>/dev/null   # kill-server can leave a stale socket file
  rm -rf "$TMP"
}
trap teardown EXIT

# Private server + session; one sub-orch window and one worker window owned by it.
command tmux -L "$SOCK" new-session -d -s testcards -n so-d1 2>/dev/null
command tmux -L "$SOCK" new-window  -t testcards   -n worker1 2>/dev/null
command tmux -L "$SOCK" set -w -t testcards:worker1 @fleet_owner so-d1 2>/dev/null

wid_worker=$(command tmux -L "$SOCK" display -p -t testcards:worker1 '#{window_id}' 2>/dev/null)
wid_so=$(command tmux -L "$SOCK" display -p -t testcards:so-d1 '#{window_id}' 2>/dev/null)

if [ -z "$wid_worker" ] || [ -z "$wid_so" ]; then
  echo "SKIP: could not create throwaway tmux windows (no display?)"
  exit 0
fi

# Sanity: confirm the option really is set on the private server (proves the
# harness itself works, so a later FAIL can only be the missing owner_of).
raw=$(command tmux -L "$SOCK" show -wqv -t "$wid_worker" @fleet_owner 2>/dev/null)
assert_eq "harness: @fleet_owner is really set on the worker window" "$raw" "so-d1"

# Source the dash; route its tmux calls to the private server so owner_of (once
# it exists) queries THIS server, never the live one.
DASH_LIB=1 FLEET_ROOT="$TMP" source "$DASH" testcards
tmux() { command tmux -L "$SOCK" "$@"; }

# owner_of is absent today -> these resolve empty -> assertions FAIL (feature absent).
got_worker=$(owner_of "$wid_worker" 2>/dev/null)
got_so=$(owner_of "$wid_so" 2>/dev/null)

assert_eq "owner_of(worker window) reads real @fleet_owner == so-d1" "$got_worker" "so-d1"
assert_eq "owner_of(so-d1 window itself) == '' (carries no owner)" "$got_so" ""

exit "$FAILED"

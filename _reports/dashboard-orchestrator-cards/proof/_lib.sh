#!/usr/bin/env bash
# Shared harness for the dashboard-orchestrator-cards proof tests.
#
# Layer A drives bin/fleet-dash through its DASH_LIB source-seam
# (bin/fleet-dash:80-89, returns at :1431 before the tty/alt-screen/event-loop),
# so every function is loaded but nothing grabs the terminal. We stub the one
# external input (`fleet agents`) with a fabricated TSV and fabricate a dispatch
# ledger under a throwaway mktemp root — the live `pc` session and real ~/.fleet
# are NEVER touched.
#
# Resolve the repo root + the dash under test.
PROOF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(git -C "$PROOF_DIR" rev-parse --show-toplevel 2>/dev/null) \
  || REPO=$(cd "$PROOF_DIR/../../.." && pwd)
DASH="$REPO/bin/fleet-dash"

# --- assertion helpers -------------------------------------------------------
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
assert_eq() { # <desc> <got> <want>
  if [ "$2" = "$3" ]; then pass "$1"
  else fail "$1"; printf '      got:  %s\n      want: %s\n' "$2" "$3"; fi
}

# --- fixture plumbing --------------------------------------------------------
# write_fake <tsv-file>: install a fake `fleet` that emits the given TSV for
# `fleet agents` (and nothing for any other subcommand, so config_live /
# cost-pane degrade to empty). Sets FLEET_BIN to point at it.
write_fake() {
  FAKE_TSV="$1"
  FAKE_BIN="$TMP/fakefleet"
  cat > "$FAKE_BIN" <<EOF
#!/usr/bin/env bash
[ "\$1" = agents ] && cat "$FAKE_TSV"
exit 0
EOF
  chmod +x "$FAKE_BIN"
  FLEET_BIN="$FAKE_BIN"
}

# tsv_row <state> <label> <sess> <wid> <wname> <pane> [age] [ready]
# Emits the 9-col agents_tsv schema (since column is a literal 't').
tsv_row() {
  printf '%s\t%s\t%s\t%s\t%s\tt\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "${7:-5}" "${8:-}"
}

# NOTE on sourcing: `DASH_LIB=1 source "$DASH" <sess>` MUST be run at the test's
# (sub)shell top level, NEVER inside a helper function. The dash declares its
# caches with `declare -A GIT_TS ...`; run inside a function those become
# function-LOCAL and lose the -A attribute on return, so render() later recreates
# GIT_TS as an indexed array and a `%101` pane key throws an arithmetic error.
# After the inline source, each test neutralises remaining live touches:
#   FLEET_BIN="$FAKE_BIN"   # dash resets FLEET_BIN to the real fleet on source (:15)
#   tmux() { :; }           # swallow read-only display/show queries (owner_of is stubbed)
#   dash_root() { printf '%s' "$TMP"; }

# stub_tput <cols> <lines>: make `tput cols/lines` return fixed geometry and
# swallow `tput cup ...` so render() can be captured to a pipe with no tty.
stub_tput() {
  eval "tput() { case \"\$1\" in cols) echo $1;; lines) echo $2;; *) : ;; esac; }"
}

# strip CSI escape sequences (SGR colours, \033[K, cursor moves) so a line's
# character count == its terminal display width (the metric fit_left/hrule use).
strip_sgr() { sed -E $'s/\033\\[[0-9;?]*[A-Za-z]//g'; }

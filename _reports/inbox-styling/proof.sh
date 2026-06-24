#!/usr/bin/env bash
# proof.sh — TDD proof for inbox color styling (Phase 3a, tests-first).
#
# Encodes the PROOF DESIGN with con's must-fixes applied:
#   #5 ROOT ISOLATION: export FLEET_ROOT + FLEET_SESSION (BOTH, so the script(1)
#      pty inherits them) before ANY fleet call. No reliance on cd. inbox_dir is
#      verified to resolve under $ROOT.
#   #6 NO 'fleet inbox field' subcommand: the on-disk field check greps the .msg
#      header directly (and/or sources bin/fleet + calls inbox_field). `fleet
#      doctor` is a SYNTAX canary only — never leaned on as a color canary.
#
# What it proves (once the styling lands GREEN):
#   (a)  TTY  → ANSI present; blocked carries red \033[31m.
#   (b)  piped (| cat), redirected (> file), and `inbox read all | cat` → ZERO ANSI.
#   (c)  consume path `fleet inbox | cat` → clean AND archives every live msg.
#   (e)  .msg files stay PLAIN on disk; sev field readable (sev=warn).
#        NO_COLOR → no ANSI even on a tty; NO_COLOR beats FLEET_INBOX_COLOR=always.
#        FLEET_INBOX_COLOR=always → ANSI even when piped.
#
# Run it against the CURRENT (unstyled) bin/fleet and the color assertions (a/a2,
# always-on-pipe, and the NO_COLOR-vs-always distinction) MUST FAIL — that is the
# correct RED. The "clean when piped/on disk" assertions PASS now.
#
# Exit nonzero if ANY assertion fails. Set PROOF_EXPECT_RED=1 to invert: exit 0
# only when EXACTLY the known color assertions are red and the rest green (used to
# certify the RED state during Phase 3a).

set -u

# ---- locate the fleet binary under test (absolute; no cd reliance) -----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLEET="$REPO/bin/fleet"
[ -x "$FLEET" ] || { echo "proof: $FLEET not found/executable" >&2; exit 2; }

# ---- must-fix #5: isolated root, BOTH vars exported ---------------------------
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fleet-inbox-proof.XXXXXX")" || exit 2
export FLEET_ROOT="$ROOT"
export FLEET_SESSION="prooftest"
INBOX="$ROOT/.fleet/inbox"

cleanup() {
  rm -rf "$ROOT" 2>/dev/null
  # belt-and-braces: kill a throwaway tmux session if one ever got made
  tmux kill-session -t prooftest 2>/dev/null || true
}
trap cleanup EXIT

# ---- assertion bookkeeping ---------------------------------------------------
ESC="$(printf '\033')"
REDSEQ="$(printf '\033[31m')"
FAILS=0; PASSES=0
RED_NAMES=""   # assertions that failed
# ok/no <name> <description>: print result, track bare NAME (not the prose) so the
# PROOF_EXPECT_RED gate can compare the red set against EXPECTED_RED.
ok(){ printf 'PASS  %-4s %s\n' "$1" "$2"; PASSES=$((PASSES+1)); }
no(){ printf 'FAIL  %-4s %s\n' "$1" "$2"; FAILS=$((FAILS+1)); RED_NAMES="$RED_NAMES $1"; }
# chk <name> <description> <bool 0|1>  (0 == pass)
chk(){ if [ "$3" = 0 ]; then ok "$1" "$2"; else no "$1" "$2"; fi; }

has_esc(){ printf '%s' "$1" | grep -q "$ESC"; }          # rc0 = contains ESC
has_red(){ printf '%s' "$1" | grep -qF "$REDSEQ"; }      # rc0 = contains \033[31m
live_count(){ ls -1 "$INBOX"/*.msg 2>/dev/null | wc -l | tr -d ' '; }

# run a fleet command inside a real pty so [ -t 1 ] is TRUE; env is inherited
# from the exported FLEET_ROOT/FLEET_SESSION (must-fix #5).
tty_run(){ script -qec "$*" /dev/null 2>/dev/null; }

seed(){
  "$FLEET" inbox put --from tester-a --sev info    -t 'info ping'    -m 'info body line' >/dev/null 2>&1
  "$FLEET" inbox put --from tester-b --sev warn     -t 'warn ping'    -m 'warn body line' >/dev/null 2>&1
  "$FLEET" inbox put --from tester-c --sev blocked  -t 'blocked ping' -m 'blocked body line' >/dev/null 2>&1
}

# =============================================================================
echo "== fleet under test: $FLEET"
echo "== isolated root:     $ROOT"
echo

# ---- must-fix #5: inbox_dir resolves under $ROOT ----------------------------
# Source the binary (its bottom dispatch, with no args, just prints usage which we
# discard) then call the real inbox_dir — proves resolution, not a reimplementation.
RESOLVED="$( set -- ; source "$FLEET" >/dev/null 2>&1; inbox_dir 2>/dev/null )"
chk D5 "inbox_dir resolves to \$ROOT/.fleet/inbox (root isolation)" \
  "$([ "$RESOLVED" = "$INBOX" ] && echo 0 || echo 1)"

# ---- SYNTAX canary (must-fix #6: doctor is NOT the color canary) -------------
bash -n "$FLEET"; chk SYN "bin/fleet parses (bash -n) — syntax canary" "$?"
# doctor runs without a syntax-level blowup; informational only, never a color test.
"$FLEET" doctor >/dev/null 2>&1; dc=$?
[ "$dc" -lt 2 ] && echo "info  doctor exit=$dc (informational canary only)" \
                 || echo "info  doctor exit=$dc (env-dependent; ignored)"

seed
echo

# =============================================================================
# (a) TTY → ANSI present, blocked carries red
# =============================================================================
TTY_LIST="$(tty_run "$FLEET inbox list")"
chk A1 "[TTY] inbox list emits ANSI" \
  "$(has_esc "$TTY_LIST" && echo 0 || echo 1)"

TTY_READ="$(tty_run "$FLEET inbox read all")"
chk A2 "[TTY] inbox read all: blocked carries red \\033[31m" \
  "$(has_red "$TTY_READ" && echo 0 || echo 1)"

# =============================================================================
# (b) piped / redirected / read-all|cat → ZERO ANSI
# =============================================================================
PIPE_LIST="$("$FLEET" inbox list 2>/dev/null | cat)"
chk B1 "[pipe] inbox list | cat has NO ANSI" \
  "$(has_esc "$PIPE_LIST" && echo 1 || echo 0)"

REDIR_FILE="$ROOT/redir.out"
"$FLEET" inbox read all >"$REDIR_FILE" 2>/dev/null
chk B2 "[redirect] inbox read all > file has NO ANSI" \
  "$(grep -q "$ESC" "$REDIR_FILE" && echo 1 || echo 0)"

READALL="$("$FLEET" inbox read all 2>/dev/null | cat)"
chk B3 "[pipe] inbox read all | cat has NO ANSI" \
  "$(has_esc "$READALL" && echo 1 || echo 0)"

# =============================================================================
# (e) on-disk .msg stay PLAIN; field readable; NO_COLOR; always
# =============================================================================
DISK_ESC=0
for f in "$INBOX"/*.msg; do [ -e "$f" ] || continue; grep -q "$ESC" "$f" && DISK_ESC=1; done
chk E1 "[disk] no *.msg carries ANSI" "$DISK_ESC"

# must-fix #6: read the sev field by grepping the header (no `inbox field` verb)
chk E2 "[disk] warn message header has '^sev=warn\$'" \
  "$(grep -rqx 'sev=warn' "$INBOX"/*.msg 2>/dev/null && echo 0 || echo 1)"

# NO_COLOR on a tty → still no ANSI
NC_TTY="$(NO_COLOR=1 tty_run "$FLEET inbox list")"
chk NC1 "[TTY+NO_COLOR] inbox list has NO ANSI" \
  "$(has_esc "$NC_TTY" && echo 1 || echo 0)"

# NO_COLOR wins over FLEET_INBOX_COLOR=always (on a tty)
NC_ALWAYS="$(NO_COLOR=1 FLEET_INBOX_COLOR=always tty_run "$FLEET inbox read all")"
chk NC2 "[TTY+NO_COLOR+always] NO_COLOR beats FLEET_INBOX_COLOR=always (no ANSI)" \
  "$(has_esc "$NC_ALWAYS" && echo 1 || echo 0)"

# FLEET_INBOX_COLOR=always → ANSI even when piped (no tty)
ALWAYS_PIPE="$(FLEET_INBOX_COLOR=always "$FLEET" inbox read all 2>/dev/null | cat)"
chk AL1 "[pipe+always] FLEET_INBOX_COLOR=always forces ANSI when piped" \
  "$(has_esc "$ALWAYS_PIPE" && echo 0 || echo 1)"

# DISTINCTION: always emits ANSI AND NO_COLOR+always (piped) suppresses it.
NC_ALWAYS_PIPE="$(NO_COLOR=1 FLEET_INBOX_COLOR=always "$FLEET" inbox read all 2>/dev/null | cat)"
if has_esc "$ALWAYS_PIPE" && ! has_esc "$NC_ALWAYS_PIPE"; then dist=0; else dist=1; fi
chk DIST "[distinction] always→ANSI, NO_COLOR+always→no ANSI" "$dist"

# =============================================================================
# (c) consume path: clean output AND archives every live msg
# =============================================================================
BEFORE="$(live_count)"
chk C1 "[consume] >=3 live msgs before consume (have $BEFORE)" \
  "$([ "${BEFORE:-0}" -ge 3 ] && echo 0 || echo 1)"

CONSUME="$("$FLEET" inbox 2>/dev/null | cat)"   # bare = pager that CONSUMES
chk C2 "[consume] fleet inbox | cat has NO ANSI" \
  "$(has_esc "$CONSUME" && echo 1 || echo 0)"

AFTER="$(live_count)"
chk C3 "[consume] all live msgs archived after consume (now $AFTER)" \
  "$([ "${AFTER:-1}" -eq 0 ] && echo 0 || echo 1)"

# =============================================================================
echo
echo "== $PASSES passed, $FAILS failed"
[ -n "$RED_NAMES" ] && echo "== RED:$RED_NAMES"

# Expected-RED gate: during Phase 3a (unstyled tree) the ONLY assertions allowed
# to fail are the color ones; everything else must already be green.
EXPECTED_RED="A1 A2 AL1 DIST"
if [ "${PROOF_EXPECT_RED:-0}" = 1 ]; then
  want="$(printf '%s\n' $EXPECTED_RED | sort)"
  got="$(printf '%s\n' $RED_NAMES | sort)"
  if [ "$want" = "$got" ]; then
    echo "== PROOF_EXPECT_RED: correct RED (exactly the color assertions failed)"
    exit 0
  fi
  echo "== PROOF_EXPECT_RED: WRONG red set — want [$EXPECTED_RED] got [$RED_NAMES]"
  exit 1
fi

[ "$FAILS" -eq 0 ]

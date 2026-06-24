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
YELSEQ="$(printf '\033[33m')"   # warn
DIMSEQ="$(printf '\033[2m')"    # info / dim / system-sender
BOLDSEQ="$(printf '\033[1m')"   # read-title anchor
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
has_seq(){ printf '%s' "$1" | grep -qF "$2"; }           # rc0 = contains literal seq $2
live_count(){ ls -1 "$INBOX"/*.msg 2>/dev/null | wc -l | tr -d ' '; }

# run a fleet command inside a real pty so [ -t 1 ] is TRUE; env is inherited
# from the exported FLEET_ROOT/FLEET_SESSION (must-fix #5).
tty_run(){ script -qec "$*" /dev/null 2>/dev/null; }
# WIDE pty: resize to 200 cols inside the pty before running, so a width-aware
# inbox_list reads the REAL terminal width (not a pinned 80). Proves BLOCKER 1.
wide_tty_run(){ script -qec "stty cols 200 2>/dev/null; $*" /dev/null 2>/dev/null; }

# A >47-char title (LW at 80 cols = 80-5-9-14-5 = 47) with a unique tail marker so
# truncation is detectable: marker present == not truncated == real width was read.
LONGTITLE="LONGTITLE_$(printf 'x%.0s' $(seq 1 50))_ENDMARKER"

seed(){
  "$FLEET" inbox put --from tester-a --sev info    -t 'info ping'    -m 'info body line' >/dev/null 2>&1
  "$FLEET" inbox put --from tester-b --sev warn     -t 'warn ping'    -m 'warn body line' >/dev/null 2>&1
  "$FLEET" inbox put --from tester-c --sev blocked  -t 'blocked ping' -m 'blocked body line' >/dev/null 2>&1
}

# Extra seeds for the visual/width guards (BLOCKER 2): a system sender (from=main →
# inbox_from_is_system) beside a worker sender, a long title, and a backdated msg-id.
seed_extra(){
  "$FLEET" inbox put --from main     --sev info -t 'system note' -m 'sys body' >/dev/null 2>&1
  "$FLEET" inbox put --from worker-z --sev warn -t 'worker note' -m 'wk body'  >/dev/null 2>&1
  "$FLEET" inbox put --from tester-w --sev info -t "$LONGTITLE"  -m 'long body' >/dev/null 2>&1
  # Backdated id (epoch = now-7200 = "2h") crafted on disk — inbox_put can't backdate
  # the id (= epoch.nanos.pane), and the age column derives from it.
  local now epoch id; now=$(date +%s); epoch=$((now-7200)); id="$epoch.000000000.proof"
  mkdir -p "$INBOX" 2>/dev/null
  {
    printf 'id=%s\n' "$id"; printf 'from=%s\n' aged-sender; printf 'dispatch=-\n'
    printf 'ts=%s\n' backdated; printf 'sev=%s\n' info; printf 'title=%s\n' 'aged msg'
    printf -- '--\n'; printf 'aged body\n'
  } > "$INBOX/$id.msg" 2>/dev/null
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
# (W) NEEDS-WORK loop — visual-payload + real-width guards (BLOCKER 1 & 2)
# =============================================================================
seed_extra

# W-WIDTH (BLOCKER 1): on a WIDE pty a >47-char title is NOT truncated → the marker
# survives. RED on 86fc0eb (COLS pinned to ${COLUMNS:-80}=80, COLUMNS unset in the
# child). GREEN once COLS reads the real terminal (tput cols).
WIDE_LIST="$(wide_tty_run "$FLEET inbox list")"
chk W-WIDTH "[TTY-wide] long title not truncated (real terminal width)" \
  "$(has_seq "$WIDE_LIST" 'ENDMARKER' && echo 0 || echo 1)"

# W-AGE: a backdated msg-id renders an age token ('2h') in inbox list on a tty.
TTY_LIST_X="$(tty_run "$FLEET inbox list")"
chk W-AGE "[TTY] backdated msg renders age token '2h'" \
  "$(has_seq "$TTY_LIST_X" '2h' && echo 0 || echo 1)"

# W-WARN / W-INFO: sev tokens carry the right SGR (yellow / dim) on a tty.
chk W-WARN "[TTY] warn [warn] token carries \\033[33m" \
  "$(has_seq "$TTY_LIST_X" "${YELSEQ}[warn]" && echo 0 || echo 1)"
chk W-INFO "[TTY] info [info] token carries \\033[2m" \
  "$(has_seq "$TTY_LIST_X" "${DIMSEQ}[info]" && echo 0 || echo 1)"

# W-BOLD: inbox read title is the bold anchor on a tty.
TTY_READ_X="$(tty_run "$FLEET inbox read all")"
chk W-BOLD "[TTY] inbox read title carries \\033[1m (bold anchor)" \
  "$(has_seq "$TTY_READ_X" "$BOLDSEQ" && echo 0 || echo 1)"

# W-SYSDIM: system sender (from=main) is dimmed; a worker sender is NOT. Exercises
# the inbox_from_is_system branch the original proof never seeded.
SYS_DIM="$(has_seq "$TTY_LIST_X" "${DIMSEQ}main" && echo y || echo n)"
WORKER_DIM="$(has_seq "$TTY_LIST_X" "${DIMSEQ}worker-z" && echo y || echo n)"
chk W-SYSDIM "[TTY] system sender dimmed, worker sender not (sys=$SYS_DIM worker=$WORKER_DIM)" \
  "$([ "$SYS_DIM" = y ] && [ "$WORKER_DIM" = n ] && echo 0 || echo 1)"

# W-NOCOLOR: NO_COLOR set but EMPTY → still no color on a tty (no-color.org: present
# regardless of value). RED on 86fc0eb ([ -n "${NO_COLOR:-}" ] treats ''==unset).
NC_EMPTY="$(NO_COLOR= tty_run "$FLEET inbox list")"
chk W-NOCOLOR "[TTY+NO_COLOR=''] empty-but-set NO_COLOR suppresses color" \
  "$(has_esc "$NC_EMPTY" && echo 1 || echo 0)"

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

# Expected-RED gate. PROOF_EXPECT_RED=1 certifies the RED-first state of an
# iteration: it exits 0 only when the failing set equals EXPECTED_RED exactly.
#   Phase 3a (unstyled tree):       EXPECTED_RED="A1 A2 AL1 DIST"
#   NEEDS-WORK loop (styled tree, pre-fix 86fc0eb): only the two genuine gaps —
#     W-WIDTH (COLS pinned to 80) and W-NOCOLOR (empty NO_COLOR ignored). The other
#     new visual guards (W-AGE/W-WARN/W-INFO/W-BOLD/W-SYSDIM) already pass on the
#     styled tree — they are regression guards, green from the start.
# After the fix, the DEFAULT run (no PROOF_EXPECT_RED) is all-green.
EXPECTED_RED="${PROOF_EXPECT_RED_SET:-W-WIDTH W-NOCOLOR}"
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

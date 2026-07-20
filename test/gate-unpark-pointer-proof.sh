#!/usr/bin/env bash
# Proof harness — a gate unpark message must RE-ORIENT a context-compacted sub-orch.
#
# Bug (W6, cheap half): `cmd_reconcile` only respawns a sub-orch whose pane is DEAD
# (`! suborch_live`), so a sub-orch that is ALIVE but has been CONTEXT-COMPACTED is
# invisible to crash recovery — FLEET_SUBORCH.md §3.0.5 (the role-phase cursor +
# artifact cross-check) is bypassed. The compounding factor is the gate body itself:
# it carried NO pointer back to the manual, so a compacted sub-orch pops it, proceeds
# on a lossy summary, and at GATE 2 MERGES + PUSHES. The body must tell it, in the
# message, to re-read the manual and its ledger BEFORE acting.
#
# What is asserted, for BOTH gates:
#   1. sentinel is still the FIRST body line and byte-identical in format
#      (`[FLEET-GATE:1 slug=S action=implement]` / `[FLEET-GATE:2 slug=S action=merge target=T]`)
#   2. `fleet gate parse` still returns rc=0 with the right fields (load-bearing: an
#      active dispatch depends on it)
#   3. the re-orientation pointer is present, naming the manual, the meta.tsv
#      role-phase cursor, and the _reports/<slug>/ artifacts
#   4. the manual path is ABSOLUTE and resolves like the rest of bin/fleet
#      ($FLEET_DIR/FLEET_SUBORCH.md), not a machine-specific hardcode
#
# Run before the fix: RED (no pointer). After: every case PASS.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

# --- isolation ----------------------------------------------------------------
TMPROOT=$(mktemp -d)
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
# HARD isolation. `fleet_root` asks tmux for the session's @fleet_root BEFORE it
# honours $FLEET_ROOT — so merely unsetting $TMUX is NOT enough: a bare
# `tmux display -p` still reaches the real server and the harness would queue its
# fake gate messages into the LIVE project inbox. Point TMUX_TMPDIR at an empty
# dir (no server there) and name a throwaway session, so every tmux lookup fails
# and $FLEET_ROOT wins.
export TMUX_TMPDIR="$TMPROOT/tmuxsock"
mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
# Isolation must be INTRINSIC, not inherited: an ambient TMUX_TMPDIR is lost by any
# step whose shell did not inherit it, which falls back to the REAL socket. Resolve
# the socket here, assert it lives under TMPROOT, and refuse to start otherwise.
SOCK="${FLEET_HARNESS_SOCK:-$TMUX_TMPDIR/tmux-$(id -u)/default}"
if [ "$SOCK" = "/tmp/tmux-$(id -u)/default" ]; then
  echo "REFUSE: harness resolved to the real tmux socket ($SOCK)" >&2
  rm -rf "$TMPROOT"; exit 1
fi
case "$SOCK" in
  "$TMPROOT"/*) ;;
  *) echo "REFUSE: harness socket is not under TMPROOT ($SOCK not under $TMPROOT)" >&2
     rm -rf "$TMPROOT"; exit 1 ;;
esac
tmux() { command tmux -S "$SOCK" "$@"; }
unset TMUX TMUX_PANE
export FLEET_SESSION="gatept_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet"

cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }
FAILED=0

INBOX="$FLEET_ROOT/.fleet/inbox"

# Post a gate message and print JUST its body (everything after the `--` header sep).
post_body() { # <gate> [extra args…]
  local gate="$1"; shift
  rm -rf "$INBOX" 2>/dev/null
  "$FLEET" gate post "$gate" "$@" >/dev/null 2>&1 || { echo "<<post failed>>"; return 1; }
  local f; f=$(ls "$INBOX"/*.msg 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "<<no msg>>"; return 1; }
  sed -n '/^--$/,$p' "$f" | tail -n +2
}

# --- bodies under test --------------------------------------------------------
B1=$(post_body 1 --slug demo --summary "does the thing" -d d99)
B2=$(post_body 2 --slug demo --target main --summary "tests cover it" -d d99)

f1="$TMPROOT/g1.body"; printf '%s\n' "$B1" > "$f1"
f2="$TMPROOT/g2.body"; printf '%s\n' "$B2" > "$f2"

echo "== gate 1 body =="; cat "$f1"
echo "== gate 2 body =="; cat "$f2"
echo

# --- 1. sentinel is FIRST line, byte-identical format -------------------------
echo "[1] sentinel first line, exact format"
l1=$(sed -n '1p' "$f1")
if [ "$l1" = "[FLEET-GATE:1 slug=demo action=implement]" ]; then pass "g1 sentinel"
else fail "g1 sentinel" "first line is '$l1'"; fi

l2=$(sed -n '1p' "$f2")
if [ "$l2" = "[FLEET-GATE:2 slug=demo action=merge target=main]" ]; then pass "g2 sentinel"
else fail "g2 sentinel" "first line is '$l2'"; fi

# --- 2. `fleet gate parse` still parses both, rc=0 ----------------------------
echo "[2] gate parse rc=0 + fields"
p1=$("$FLEET" gate parse "$f1" 2>/dev/null); rc1=$?
if [ "$rc1" = 0 ] && [ "$p1" = "gate=1 slug=demo action=implement" ]; then pass "g1 parse"
else fail "g1 parse" "rc=$rc1 out='$p1'"; fi

p2=$("$FLEET" gate parse "$f2" 2>/dev/null); rc2=$?
if [ "$rc2" = 0 ] && [ "$p2" = "gate=2 slug=demo action=merge target=main" ]; then pass "g2 parse"
else fail "g2 parse" "rc=$rc2 out='$p2'"; fi

# parse must also work from STDIN (the way the sub-orch actually pipes a popped body)
p1s=$(printf '%s\n' "$B1" | "$FLEET" gate parse 2>/dev/null); rcs=$?
if [ "$rcs" = 0 ] && [ "$p1s" = "gate=1 slug=demo action=implement" ]; then pass "g1 parse stdin"
else fail "g1 parse stdin" "rc=$rcs out='$p1s'"; fi

# --- 3. the re-orientation pointer is present in BOTH bodies ------------------
echo "[3] re-orientation pointer present"
for g in 1 2; do
  eval "b=\$B$g"
  case "$b" in *FLEET_SUBORCH.md*) pass "g$g names manual" ;;
    *) fail "g$g names manual" "no FLEET_SUBORCH.md in body" ;; esac
  case "$b" in *meta.tsv*) pass "g$g names meta.tsv" ;;
    *) fail "g$g names meta.tsv" "no meta.tsv in body" ;; esac
  case "$b" in *role-phase*) pass "g$g names role-phase" ;;
    *) fail "g$g names role-phase" "no role-phase cursor in body" ;; esac
  # NB: the pre-existing "Plain plan:/Details: _reports/demo/…" line already mentions
  # _reports/demo/, so a bare substring test would pass RED. Require the artifacts
  # reference on a line that ALSO carries the re-orientation (meta.tsv / role-phase).
  if printf '%s\n' "$b" | grep -q '_reports/demo/.*\(meta\.tsv\|role-phase\)\|\(meta\.tsv\|role-phase\).*_reports/demo/'; then
    pass "g$g names artifacts dir in pointer"
  else fail "g$g names artifacts dir in pointer" "no _reports/demo/ on a re-orientation line"; fi
done

# --- 4. manual path is absolute + resolved, not hardcoded ---------------------
echo "[4] manual path absolute + repo-resolved"
want="$HERE/FLEET_SUBORCH.md"
for g in 1 2; do
  eval "b=\$B$g"
  case "$b" in *"$want"*) pass "g$g manual path = \$FLEET_DIR/FLEET_SUBORCH.md" ;;
    *) fail "g$g manual path" "body does not contain '$want'" ;; esac
done
[ -f "$want" ] && pass "manual exists on disk" || fail "manual exists on disk" "$want missing"

# --- 5. dispatch id reaches the ledger pointer --------------------------------
# The pointer is useless if it can't name WHICH ledger to re-read.
echo "[5] ledger pointer carries the dispatch id"
for g in 1 2; do
  eval "b=\$B$g"
  case "$b" in *.fleet/dispatch/d99/meta.tsv*) pass "g$g ledger path has id" ;;
    *) fail "g$g ledger path has id" "no .fleet/dispatch/d99/meta.tsv in body" ;; esac
done

# --- 5b. NO -d flag: the pointer must never emit a path that does not resolve --
# `disp` defaults to "-" in the gate_post arg parse, so a gate posted without -d
# would render `.fleet/dispatch/-/meta.tsv` — a nonexistent path, handed to exactly
# the reader least equipped to notice it is nonsense (a compacted sub-orch follows
# it literally). Degrading to the manual line alone is strictly better than
# pointing at a lie. Case [5] above only exercises the WITH-`-d` path and misses this.
echo "[5b] no -d: no bogus ledger path"
N1=$(post_body 1 --slug demo --summary "does the thing")
N2=$(post_body 2 --slug demo --target main --summary "tests cover it")
nf1="$TMPROOT/n1.body"; printf '%s\n' "$N1" > "$nf1"
nf2="$TMPROOT/n2.body"; printf '%s\n' "$N2" > "$nf2"
echo "== gate 1 body (no -d) =="; cat "$nf1"
echo "== gate 2 body (no -d) =="; cat "$nf2"

for g in 1 2; do
  eval "b=\$N$g"
  case "$b" in
    *".fleet/dispatch/-/"*) fail "g$g no bogus ledger path" "body contains .fleet/dispatch/-/ " ;;
    *) pass "g$g no bogus ledger path" ;;
  esac
  # Belt and braces: ANY dispatch path present must name a real-looking id, never a
  # placeholder. Catches "-", "", "<id>" and friends however they get introduced.
  bad=$(printf '%s\n' "$b" | grep -o '\.fleet/dispatch/[^/ ]*' | grep -v '\.fleet/dispatch/[A-Za-z0-9_.][A-Za-z0-9_.-]*$')
  if [ -n "$bad" ]; then fail "g$g dispatch path well-formed" "placeholder id: $bad"
  else pass "g$g dispatch path well-formed"; fi
  # Degrading must not cost the manual pointer — it is still valid and still useful.
  case "$b" in *"$HERE/FLEET_SUBORCH.md"*) pass "g$g manual pointer survives no -d" ;;
    *) fail "g$g manual pointer survives no -d" "manual path dropped when -d omitted" ;; esac
done

# the sentinel + parse invariants must hold on the no-`-d` bodies too
sn1=$(sed -n '1p' "$nf1"); sn2=$(sed -n '1p' "$nf2")
[ "$sn1" = "[FLEET-GATE:1 slug=demo action=implement]" ] \
  && pass "g1 sentinel (no -d)" || fail "g1 sentinel (no -d)" "first line is '$sn1'"
[ "$sn2" = "[FLEET-GATE:2 slug=demo action=merge target=main]" ] \
  && pass "g2 sentinel (no -d)" || fail "g2 sentinel (no -d)" "first line is '$sn2'"
q1=$("$FLEET" gate parse "$nf1" 2>/dev/null); qrc1=$?
[ "$qrc1" = 0 ] && [ "$q1" = "gate=1 slug=demo action=implement" ] \
  && pass "g1 parse (no -d)" || fail "g1 parse (no -d)" "rc=$qrc1 out='$q1'"
q2=$("$FLEET" gate parse "$nf2" 2>/dev/null); qrc2=$?
[ "$qrc2" = 0 ] && [ "$q2" = "gate=2 slug=demo action=merge target=main" ] \
  && pass "g2 parse (no -d)" || fail "g2 parse (no -d)" "rc=$qrc2 out='$q2'"

# terseness cap applies to the degraded body as well
for g in 1 2; do
  eval "b=\$N$g"
  n=$(printf '%s\n' "$b" | grep -c 'FLEET_SUBORCH.md\|meta\.tsv\|role-phase\|_reports/')
  if [ "$n" -le 3 ]; then pass "g$g pointer <=3 lines, no -d ($n)"
  else fail "g$g pointer <=3 lines, no -d" "$n lines"; fi
done

# --- 6. pointer is TERSE (2-3 lines) — the body gets pasted into the sub-orch --
echo "[6] pointer terse"
for g in 1 2; do
  eval "b=\$B$g"
  n=$(printf '%s\n' "$b" | grep -c 'FLEET_SUBORCH.md\|meta.tsv\|role-phase\|_reports/')
  if [ "$n" -le 3 ]; then pass "g$g pointer <=3 lines ($n)"
  else fail "g$g pointer <=3 lines" "$n lines"; fi
done

# --- 7. syntax ----------------------------------------------------------------
echo "[7] bash -n"
if bash -n "$FLEET" 2>/dev/null; then pass "bin/fleet parses"; else fail "bin/fleet parses" "syntax error"; fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }

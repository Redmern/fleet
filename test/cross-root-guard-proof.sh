#!/usr/bin/env bash
# cross-root-guard-proof.sh — d38 suite B: a ledger write must be able to show it
# is in the namespace the caller is actually in.
#
# THE INCIDENT THIS REPRODUCES (2026-08-02). A test fixture exported
# FLEET_ROOT=/tmp/adv3/proj but did NOT isolate TMUX_TMPDIR, so `fleet_root()` —
# which reads tmux @fleet_root FIRST and FLEET_ROOT second — resolved to the REAL
# project. The fixture parked a gate on the human's real dispatch d1, put a message
# in their real inbox, and the human's own pop stamped gate1_popped on it. Nothing
# anywhere compared the environment that produced the root with the argument that
# produced the target. The gate artifact it left behind points at
# /tmp/adv3/tree/FLEET_SUBORCH.md — an outside path a real sub-orch would have been
# told to read.
#
# WHAT IS AND IS NOT CLAIMED. B1/B2/B4 are blast-radius and mis-addressing guards,
# NOT security. Everything runs as one uid. The alert in B1 is DETECTION, fail-soft
# by design: its value is that a fixture escaping its sandbox writes it into the
# REAL project's log and cannot suppress it.
#
# A containment assertion ("is the target under the root?") is deliberately ABSENT:
# the target path is BUILT from the root, so such a case is green by construction —
# exactly the false-green this dispatch exists to eliminate.
#
#   bash test/cross-root-guard-proof.sh

. "$(dirname "$0")/hidden-proof-common.sh"

proof_isolate
proof_session t1

sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Two isolated project roots inside TMPROOT. RB is the one tmux names.
RA="$TMPROOT/rootA"; RB="$TMPROOT/rootB"
mk_root() { # mk_root <root>
  mkdir -p "$1/.fleet/dispatch/d1"
  printf 'state\tplanning\nwindow\tso-d1-live\n' > "$1/.fleet/dispatch/d1/meta.tsv"
  printf 'brief for %s\n' "$1" > "$1/.fleet/dispatch/d1/instruction.txt"
}
mk_root "$RA"; mk_root "$RB"

# ---------------------------------------------------------------------------
section "B1 — the cross-root mutation, reproduced (env says RA, tmux says RB)"
tmux set -t t1 @fleet_root "$RB" 2>/dev/null
B1_RA_BEFORE=$(sha "$RA/.fleet/dispatch/d1/meta.tsv")
B1_RB_BEFORE=$(sha "$RB/.fleet/dispatch/d1/meta.tsv")
rm -f "$RB/.fleet/dispatch/alerts.log" "$RA/.fleet/dispatch/alerts.log"

# A ledger-writing verb targeting d1, run with the pane env pointing at RA.
B1_OUT=$(FLEET_ROOT="$RA" "$FLEET" dispatch done d1 2>&1); B1_RC=$?

# POSITIVE CONTROL FIRST. Without it the "RA is byte-identical" assertion below
# passes when the verb never ran at all.
chk "B1 pos-control: the verb exited 0" 0 "$B1_RC"
chk_ne "B1 pos-control: the write LANDED (RB's ledger changed)" "$B1_RB_BEFORE" "$(sha "$RB/.fleet/dispatch/d1/meta.tsv")"

chk "B1: the ledger that was NOT addressed is byte-identical" "$B1_RA_BEFORE" "$(sha "$RA/.fleet/dispatch/d1/meta.tsv")"
if grep -qi 'root' "$RB/.fleet/dispatch/alerts.log" 2>/dev/null
then ok "B1: the FLEET_ROOT/@fleet_root disagreement is alerted into the resolved root's log"
else no "B1: the disagreement was SILENT — exactly as on 2026-08-02 (no alert in $RB/.fleet/dispatch/alerts.log)"; fi
if grep -qi 'root' "$RA/.fleet/dispatch/alerts.log" 2>/dev/null
then no "B1: the alert landed in the UNRESOLVED root — an escaping fixture could keep it out of the real log"
else ok "B1: the alert is written where the write went, not where the env pointed"; fi

# Negative control: agreement must NOT alert, or the signal is worthless noise.
tmux set -t t1 @fleet_root "$FLEET_ROOT" 2>/dev/null
mkdir -p "$FLEET_ROOT/.fleet/dispatch/d1"; printf 'state\tplanning\n' > "$FLEET_ROOT/.fleet/dispatch/d1/meta.tsv"
rm -f "$FLEET_ROOT/.fleet/dispatch/alerts.log"
"$FLEET" dispatch done d1 >/dev/null 2>&1
if grep -qi 'root.*disagree\|disagree.*root' "$FLEET_ROOT/.fleet/dispatch/alerts.log" 2>/dev/null
then no "B1 neg-control: an AGREEING root still alerted (the alert would be pure noise)"
else ok "B1 neg-control: an agreeing root does not alert"; fi

# ---------------------------------------------------------------------------
section "B2 — the reorient cut: no absolute path into a foreign tree"
# gate_post emits \$FLEET_DIR/FLEET_SUBORCH.md into the gate artifact. FLEET_DIR
# comes from the binary's own location and was never compared to the resolved root
# — that split is how /tmp/adv3/tree/FLEET_SUBORCH.md reached a real sub-orch.
install_fleet_at() { # install_fleet_at <dir> -> prints the binary path
  local dst="$1"
  mkdir -p "$dst/bin"
  cp "$FLEET_REPO/bin/fleet" "$dst/bin/fleet"
  [ -d "$FLEET_REPO/harness.d" ] && cp -a "$FLEET_REPO/harness.d" "$dst/" 2>/dev/null
  : > "$dst/FLEET_SUBORCH.md"
  printf '%s\n' "$dst/bin/fleet"
}
tmux set -t t1 @fleet_root "$FLEET_ROOT" 2>/dev/null
mkdir -p "$FLEET_ROOT/.fleet/dispatch/d1"

# (a) OUTSIDE: the binary lives in a tree that is not under the resolved root.
OUTSIDE=$(install_fleet_at "$TMPROOT/foreign-install")
rm -f "$FLEET_ROOT/.fleet/dispatch/d1/GATE-1.md"
"$OUTSIDE" gate post 1 --slug s1 -d d1 --summary 'x' >/dev/null 2>&1
B2_ART="$FLEET_ROOT/.fleet/dispatch/d1/GATE-1.md"
if [ -s "$B2_ART" ]; then ok "B2 pos-control: the gate artifact was written"
else no "B2 pos-control: no GATE-1.md — the case below would assert nothing"; fi
if grep -q 'FLEET_SUBORCH.md' "$B2_ART" 2>/dev/null
then ok "B2 pos-control: the artifact still carries the re-orient pointer"
else no "B2 pos-control: the re-orient pointer is missing entirely"; fi
if grep -q "$TMPROOT/foreign-install" "$B2_ART" 2>/dev/null
then no "B2: the artifact names an ABSOLUTE path into a foreign tree ($TMPROOT/foreign-install/FLEET_SUBORCH.md)"
else ok "B2: no absolute path outside the resolved root appears in the artifact"; fi
if grep -qE '(^|[^/[:alnum:]_-])FLEET_SUBORCH\.md' "$B2_ART" 2>/dev/null
then ok "B2: the artifact records a BARE filename"
else no "B2: the pointer is not a bare filename"; fi

# (b) DISCRIMINATOR — inside the root the absolute path is still emitted, so (a)
#     cannot pass by the pointer having been blanket-removed.
INSIDE=$(install_fleet_at "$FLEET_ROOT/local-install")
rm -f "$FLEET_ROOT/.fleet/dispatch/d1/GATE-1.md"
"$INSIDE" gate post 1 --slug s1 -d d1 --summary 'x' >/dev/null 2>&1
if grep -q "$FLEET_ROOT/local-install/FLEET_SUBORCH.md" "$B2_ART" 2>/dev/null
then ok "B2 discriminator: a binary INSIDE the root still gets its absolute path"
else no "B2 discriminator: the cut fired even for an in-root binary (blanket removal, not a cut)"; fi

# (c) SECOND DISCRIMINATOR — the PRODUCTION shape: the binary is outside the project
#     (release tree / a checkout) but inside this user's own tree. A blanket
#     "outside the root ⇒ bare filename" cut would fire here on EVERY real gate
#     message and replace a pointer that resolves with one that does not.
HOMEISH="$TMPROOT/home"
UNDER_HOME=$(install_fleet_at "$HOMEISH/.local/lib/fleet")
rm -f "$FLEET_ROOT/.fleet/dispatch/d1/GATE-1.md"
HOME="$HOMEISH" "$UNDER_HOME" gate post 1 --slug s1 -d d1 --summary 'x' >/dev/null 2>&1
if grep -q "$HOMEISH/.local/lib/fleet/FLEET_SUBORCH.md" "$B2_ART" 2>/dev/null
then ok "B2 discriminator: a binary outside the root but under \$HOME keeps its absolute path"
else no "B2 discriminator: the cut fired on the ordinary production layout (release tree outside the project)"; fi

# ---------------------------------------------------------------------------
section "B3 — the harness refuses to start half-isolated"
# The escaping fixture did not source this harness. That is the argument for making
# the harness impossible to HALF-use: FLEET_ROOT isolated, tmux socket not.
run_isolated_harness() { # run_isolated_harness <env-assignments…> -> prints rc
  (
    env -u TMUX -u TMUX_PANE "$@" \
      bash -c '. "'"$FLEET_REPO"'/test/hidden-proof-common.sh"; proof_isolate; proof_session t9' \
      >/dev/null 2>&1
    echo $?
  )
}
B3_RC=$(run_isolated_harness FLEET_TEST_SOCK="/tmp/tmux-$(id -u)/default")
chk_ne "B3: a fixture resolving to the REAL tmux socket is refused" "0" "$B3_RC"

# The d38 addition: FLEET_ROOT and tmux @fleet_root must agree before any verb runs.
B3B_RC=$(run_isolated_harness FLEET_PROOF_ROOT_OVERRIDE="$TMPROOT/elsewhere")
chk_ne "B3b: a FLEET_ROOT/@fleet_root disagreement refuses to start" "0" "$B3B_RC"

# POSITIVE CONTROL: the ordinary, fully-isolated harness still starts. Without this
# both cases above pass against a harness that refuses unconditionally.
B3C_RC=$(run_isolated_harness FLEET_UNUSED=1)
chk "B3 pos-control: a correctly isolated harness starts normally" "0" "$B3C_RC"

# ---------------------------------------------------------------------------
section "B4 — a dispatch id must look like a dispatch id"
tmux set -t t1 @fleet_root "$FLEET_ROOT" 2>/dev/null
LED="$FLEET_ROOT/.fleet/dispatch"
mkdir -p "$LED/d1"
# The traversal target must EXIST, or the case passes for the wrong reason: today's
# `d[0-9]*` glob accepts the string and is stopped only by `[ -d ]` on a path that
# happens not to be there. `$LED/d1/../../evil` resolves to $FLEET_ROOT/.fleet/evil.
EVIL="$FLEET_ROOT/.fleet/evil"
rm -rf "$EVIL"; mkdir -p "$EVIL"
printf 'state\tplanning\n' > "$EVIL/meta.tsv"
printf 'sentinel\n' > "$EVIL/GATE-1.md"
if [ -d "$LED/d1/../../evil" ]; then ok "B4 pos-control: the traversal target genuinely resolves on disk"
else no "B4 pos-control: the traversal target does not resolve — the case would assert nothing"; fi
B4_OUT=$("$FLEET" gate show 'd1/../../evil' 2>&1); B4_RC=$?
chk_ne "B4: 'd1/../../evil' is refused (nonzero rc)" "0" "$B4_RC"
case "$B4_OUT" in
  *sentinel*|*"$EVIL"*) no "B4: the verb reached a dir OUTSIDE the ledger (output names it)" ;;
  *) ok "B4: nothing outside the ledger dir was reached" ;;
esac

# POSITIVE CONTROL: a well-formed id still resolves, so B4 cannot pass because the
# verb refuses everything.
B4B_OUT=$("$FLEET" gate show d1 2>&1); B4B_RC=$?
chk "B4 pos-control: a well-formed id d1 still resolves" "0" "$B4B_RC"

# SECOND POSITIVE CONTROL — the corpus's out-of-band ids. `d1c`, `d2c`, `d2e`, `d2f`
# are real fixture dispatch ids in gate3-state-proof.sh and gate-courier-proof.sh. A
# strict `^d[0-9]+$` at the resolver silently unresolves them at every gate verb,
# which buys nothing: a name with no separator and no `..` cannot leave the ledger.
rm -rf "$LED/d1c"; cp -a "$LED/d1" "$LED/d1c"   # byte-identical to the d1 fixture: only the NAME differs
B4C_OUT=$("$FLEET" gate show d1c 2>&1); B4C_RC=$?
chk "B4 pos-control: a suffixed out-of-band id (d1c) still resolves" "0" "$B4C_RC"

proof_summary

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

# B1b — THE FLAG IS PER-PROCESS STATE, NOT A KNOB (V2). It was seeded
# `${_ROOT_DISAGREE_ALERTED:-0}`, i.e. read from the ENVIRONMENT — so one exported
# `_ROOT_DISAGREE_ALERTED=1` suppressed the alert in this process and in every child
# of it, with no file write and no trace. That is a strictly easier suppression
# vector than the disclosed same-uid one, and an audit trail that can be switched
# off from the environment reads as innocence. Re-run B1's own disagreement with the
# flag pre-exported: the alert must still be written.
tmux set -t t1 @fleet_root "$RB" 2>/dev/null
rm -f "$RB/.fleet/dispatch/alerts.log" "$RA/.fleet/dispatch/alerts.log"
# B1 already drove d1 to `done`, and `dispatch done` is idempotent — so the mutation
# pos-control below would fail for the wrong reason. Reset the fixture so the verb has
# something to change.
printf 'state\tplanning\n' > "$RB/.fleet/dispatch/d1/meta.tsv"
B1B_RB_BEFORE=$(sha "$RB/.fleet/dispatch/d1/meta.tsv")
B1B_RC=0
_ROOT_DISAGREE_ALERTED=1 FLEET_ROOT="$RA" "$FLEET" dispatch done d1 >/dev/null 2>&1 || B1B_RC=$?
chk "B1b pos-control: the verb exited 0 with the flag exported" 0 "$B1B_RC"
chk_ne "B1b pos-control: the write LANDED (RB's ledger changed)" "$B1B_RB_BEFORE" "$(sha "$RB/.fleet/dispatch/d1/meta.tsv")"
if grep -qi 'root' "$RB/.fleet/dispatch/alerts.log" 2>/dev/null
then ok "B1b: an exported _ROOT_DISAGREE_ALERTED=1 does NOT suppress the alert"
else no "B1b: the audit trail was silenced by one exported env var — process-wide suppression, no file write"; fi

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

# ---------------------------------------------------------------------------
# B4d — the WRITE verbs, not only the read verb (V1).
#
# `gate show` was shape-checked and `gate park` was not, so the traversal stayed open
# at the verb that MUTATES: `fleet gate park '../../../victim' 1` printed "parked" and
# wrote `state gate1-wait` + `parked_at` into a directory outside every ledger — hence
# outside every alerts.log, so the audit trail that IS this half's deliverable recorded
# nothing at all. Refusing the read while allowing the write is the worst of both.
#
# The green state of "the victim was not written" is "nothing changed", so this case
# ASSERTS THE OPERATION EXECUTED FIRST: the victim dir exists, the path resolves, and
# the byte-identical control park on `d1` demonstrably DOES mutate meta.tsv.
VICT="$FLEET_ROOT/.fleet/victim"
rm -rf "$VICT"; mkdir -p "$VICT"; printf 'state\tplanning\n' > "$VICT/meta.tsv"
if [ -d "$LED/d1/../../victim" ]; then ok "B4d pos-control: the park traversal target genuinely resolves on disk"
else no "B4d pos-control: the park target does not resolve — the case would assert nothing"; fi
V_BEFORE=$(cksum < "$VICT/meta.tsv")

B4D_OUT=$("$FLEET" gate park 'd1/../../victim' 1 2>&1); B4D_RC=$?
chk_ne "B4d: 'gate park d1/../../victim' is refused (nonzero rc)" "0" "$B4D_RC"
case "$B4D_OUT" in *parked*) no "B4d: park reported success on a traversal id" ;; *) ok "B4d: park did not report success" ;; esac
chk "B4d: the out-of-ledger victim meta.tsv is unwritten" "$V_BEFORE" "$(cksum < "$VICT/meta.tsv")"
case "$(cat "$VICT/meta.tsv")" in *gate1-wait*|*parked_at*) no "B4d: park state/stamp landed outside the ledger" ;; *) ok "B4d: no park state or stamp outside the ledger" ;; esac

# POSITIVE CONTROL for B4d — the SAME verb on a well-formed id must still park, and
# must be seen to MUTATE. Without this, B4d passes just as happily against a `gate
# park` that is broken, missing, or refuses everything.
D1_BEFORE=$(cksum < "$LED/d1/meta.tsv" 2>/dev/null || echo none)
B4E_OUT=$("$FLEET" gate park d1 1 2>&1); B4E_RC=$?
chk "B4d pos-control: a well-formed id d1 still parks" "0" "$B4E_RC"
chk_ne "B4d pos-control: parking d1 actually MUTATED its meta.tsv" "$D1_BEFORE" "$(cksum < "$LED/d1/meta.tsv" 2>/dev/null || echo none)"
case "$(cat "$LED/d1/meta.tsv")" in *gate1-wait*) ok "B4d pos-control: d1 carries state gate1-wait" ;; *) no "B4d pos-control: d1 did not get state gate1-wait — park is inert, B4d proves nothing" ;; esac

# B4h — the THIRD unvalidated id site: `gate_write_artifact`, reached by `gate post -d`.
# Its refusal is fail-SILENT by contract (every other refusal in it is `return 0`), so
# rc says nothing here and the case must be measured on the FILE. Positive control
# first — the same command with a well-formed id must demonstrably write GATE-1.md, or
# "no artifact outside the ledger" is satisfied by a gate_post that writes nothing.
rm -f "$LED/d1/GATE-1.md" "$VICT/GATE-1.md"
"$FLEET" gate post 1 --slug someslug -d d1 --summary 'control' >/dev/null 2>&1
if [ -s "$LED/d1/GATE-1.md" ]; then ok "B4h pos-control: gate post -d d1 writes GATE-1.md inside the ledger"
else no "B4h pos-control: gate post wrote no artifact at all — B4h would prove nothing"; fi

"$FLEET" gate post 1 --slug someslug -d 'd1/../../victim' --summary 'traversal' >/dev/null 2>&1
if [ -e "$VICT/GATE-1.md" ]; then no "B4h: a gate artifact was written OUTSIDE every ledger ($VICT/GATE-1.md)"
else ok "B4h: no gate artifact outside the ledger"; fi

# B4f — `dispatch rename` has the identical shape and additionally writes the ABSOLUTE
# `reports` key, so a traversal there aims every later consumer of that key off-ledger.
#
# THIS CASE MAY NOT ASSERT ONLY "nonzero rc" OR "the victim is unwritten" — MEASURED:
# with the shape check deleted, rename still exits 1 and still writes nothing, because
# `acquire_lock "$led/.spawnlock-$id"` mkdirs through a path whose parent does not
# exist and returns 1. That is the "inert only by accident" the round-1 report named,
# and both of those assertions stay GREEN against the unguarded source — i.e. vacuous.
# So the case pins the REFUSAL MECHANISM: the shape check must be what refused, named
# in the message, before any of the interpolation happens.
B4F_OUT=$("$FLEET" dispatch rename 'd1/../../victim' some slug 2>&1); B4F_RC=$?
chk_ne "B4f: 'dispatch rename d1/../../victim' is refused (nonzero rc)" "0" "$B4F_RC"
case "$B4F_OUT" in
  *"invalid dispatch id"*) ok "B4f: refused BY THE SHAPE CHECK, not by an incidental lock failure" ;;
  *) no "B4f: refused for some other reason ('$B4F_OUT') — the traversal is unguarded and only accidentally inert" ;;
esac
case "$(cat "$VICT/meta.tsv")" in *reports*|*window*) no "B4f: rename wrote keys outside the ledger" ;; *) ok "B4f: no rename keys outside the ledger" ;; esac

# POSITIVE CONTROL for B4f — the same verb on a well-formed id must still rename and
# must be seen to WRITE the ledger, or B4f is satisfied by a rename that refuses all
# input (including the `acquire_lock` corpse above).
B4G_BEFORE=$(sha "$LED/d1/meta.tsv")
B4G_OUT=$("$FLEET" dispatch rename d1 some slug 2>&1); B4G_RC=$?
chk "B4f pos-control: a well-formed id d1 still renames" "0" "$B4G_RC"
chk_ne "B4f pos-control: renaming d1 actually MUTATED its meta.tsv" "$B4G_BEFORE" "$(sha "$LED/d1/meta.tsv")"
case "$(cat "$LED/d1/meta.tsv")" in *reports*) ok "B4f pos-control: d1 carries the reports key" ;; *) no "B4f pos-control: rename wrote no reports key — rename is inert, B4f proves nothing" ;; esac

# B4i / B4j — the two REMAINING CLI-reachable write verbs that interpolate an id.
# Round 1 closed the four read/resolve sites and left every MUTATING one open, which is
# what made V1 a blocker; enumerating the write verbs exhaustively is the fix for the
# class, not just for the two the report happened to name.
#
# B4i — `fleet dispatch farm <id>` mkdirs and plants symlinks under the ledger dir.
# Observable: with a `reports` key present it plants `reports ->`. Positive control on
# a well-formed id first, or "no link in the victim" is satisfied by an inert farm.
printf 'state\tplanning\nreports\t%s\n' "$FLEET_ROOT/_reports/x" > "$LED/d1/meta.tsv"
printf 'state\tplanning\nreports\t%s\n' "$FLEET_ROOT/_reports/x" > "$VICT/meta.tsv"
rm -f "$LED/d1/reports" "$VICT/reports"
"$FLEET" dispatch farm d1 >/dev/null 2>&1
if [ -L "$LED/d1/reports" ]; then ok "B4i pos-control: 'dispatch farm d1' plants the reports link inside the ledger"
else no "B4i pos-control: farm planted nothing — B4i would prove nothing"; fi
"$FLEET" dispatch farm 'd1/../../victim' >/dev/null 2>&1
if [ -e "$VICT/reports" ]; then no "B4i: 'dispatch farm' planted the farm OUTSIDE every ledger ($VICT/reports)"
else ok "B4i: no farm planted outside the ledger"; fi

# B4j — `fleet gate deliver <id>` is the courier and WRITES: `.deliver.lock` first of
# all, before any decision is even read. That file is the observable, and it appears
# whether or not a decision exists — so this case does not depend on staging one.
rm -f "$LED/d1/.deliver.lock" "$VICT/.deliver.lock"
"$FLEET" gate deliver d1 >/dev/null 2>&1
if [ -e "$LED/d1/.deliver.lock" ]; then ok "B4j pos-control: 'gate deliver d1' opens its lock inside the ledger"
else no "B4j pos-control: the courier wrote nothing at all — B4j would prove nothing"; fi
"$FLEET" gate deliver 'd1/../../victim' >/dev/null 2>&1
if [ -e "$VICT/.deliver.lock" ]; then no "B4j: the courier opened a lock OUTSIDE every ledger ($VICT/.deliver.lock)"
else ok "B4j: the courier wrote nothing outside the ledger"; fi



# ---------------------------------------------------------------------------
section "B5 — a SHAPE-VALID id that is a SYMLINK must not escape the ledger (round 2, S1)"
# THE HOLE THIS PINS, measured by the round-2 adversary against 05a323d: `d99` passes
# valid_dispatch_id (it is even STRICT-valid, so this is not an argument about the
# non-strict choice), and every site then asked `[ -d "$d" ]` — which FOLLOWS SYMLINKS.
# With `ln -sfn <victim> $LED/d99`, `gate park d99 1`, `dispatch done d99` and
# `dispatch rename d99 slugx` each wrote a 0600 meta.tsv and planted a farm symlink in
# the victim, OUTSIDE every ledger and hence outside every alerts.log: round 1's V1
# outcome by a second route. Closed by `ledger_entry_dir` (`[ -L ]` before `[ -d ]`).
#
# RED PROOF: delete the `[ ! -L "$d" ] || return 1` line in ledger_entry_dir and the
# five escape assertions below go red (the pos-controls stay green).
VS="$FLEET_ROOT/.fleet/vsym"
rm -rf "$VS"; mkdir -p "$VS"; printf 'state\tplanning\n' > "$VS/meta.tsv"
rm -rf "$LED/d99"; ln -sfn "$VS" "$LED/d99"
# Vacuity guards: the link must exist, be shape-valid, and `-d`-true through the link —
# otherwise every assertion below is satisfied by the link simply not resolving.
if [ -L "$LED/d99" ] && [ -d "$LED/d99" ]; then ok "B5 pos-control: \$LED/d99 is a symlink that -d resolves through"
else no "B5 pos-control: the symlink does not resolve — the case would assert nothing"; fi
VS_BEFORE=$(cksum < "$VS/meta.tsv")

B5A_OUT=$("$FLEET" gate park d99 1 2>&1); B5A_RC=$?
chk_ne "B5a: 'gate park d99' (symlinked entry) is refused (nonzero rc)" "0" "$B5A_RC"
chk "B5a: the victim's meta.tsv is byte-identical after the park" "$VS_BEFORE" "$(cksum < "$VS/meta.tsv")"

B5B_OUT=$("$FLEET" dispatch done d99 2>&1); B5B_RC=$?
chk_ne "B5b: 'dispatch done d99' is refused (nonzero rc)" "0" "$B5B_RC"
chk "B5b: no terminal state written outside the ledger" "$VS_BEFORE" "$(cksum < "$VS/meta.tsv")"

B5C_OUT=$("$FLEET" dispatch rename d99 slugx 2>&1); B5C_RC=$?
chk_ne "B5c: 'dispatch rename d99 slugx' is refused (nonzero rc)" "0" "$B5C_RC"
chk "B5c: no window/reports key written outside the ledger" "$VS_BEFORE" "$(cksum < "$VS/meta.tsv")"

# The farm is the one that plants a SYMLINK in the victim, so its observable is a path,
# not a checksum. `reports` is pre-seeded so an unguarded farm would definitely plant.
printf 'state\tplanning\nreports\t%s\n' "$FLEET_ROOT/_reports/x" > "$VS/meta.tsv"
VS_BEFORE=$(cksum < "$VS/meta.tsv")
rm -f "$VS/reports"
"$FLEET" dispatch farm d99 >/dev/null 2>&1
if [ -e "$VS/reports" ]; then no "B5d: 'dispatch farm d99' planted the farm OUTSIDE every ledger ($VS/reports)"
else ok "B5d: no farm planted through the symlinked entry"; fi

# The courier: `.deliver.lock` is written before any decision is read (see B4j).
rm -f "$VS/.deliver.lock"
"$FLEET" gate deliver d99 >/dev/null 2>&1
if [ -e "$VS/.deliver.lock" ]; then no "B5e: the courier opened a lock OUTSIDE every ledger ($VS/.deliver.lock)"
else ok "B5e: the courier wrote nothing through the symlinked entry"; fi

# The READ verb too — a symlinked entry must not be resolvable at all, or the human is
# shown an off-ledger dispatch as if it were one of theirs. The victim is staged with a
# PENDING GATE first: with a bare `state=planning` this case passes against the
# unguarded source too (gate_show dies on "has no gate"), i.e. it would be vacuous.
printf 'state\tgate1-wait\n' > "$VS/meta.tsv"; printf 'off-ledger question\n' > "$VS/GATE-1.md"
VS_BEFORE=$(cksum < "$VS/meta.tsv")
B5F_OUT=$("$FLEET" gate show d99 2>&1); B5F_RC=$?
chk_ne "B5f: 'gate show d99' does not resolve a symlinked ledger entry" "0" "$B5F_RC"

# S3 EXTENSION (cheap, same fixture): `fleet dispatch <id>` is the spawn verb and was
# never driven hostilely by the shipped suite. It gates on instruction.txt, so the
# victim carries one — without it the refusal is for the wrong reason.
printf 'brief\n' > "$VS/instruction.txt"
B5G_OUT=$("$FLEET" dispatch d99 2>&1); B5G_RC=$?
chk_ne "B5g: 'fleet dispatch d99' does not spawn against a symlinked entry" "0" "$B5G_RC"
chk "B5g: no state/window key written outside the ledger" "$VS_BEFORE" "$(cksum < "$VS/meta.tsv")"

# NARROWNESS CONTROL — the whole point of ledger_entry_dir is that it refuses ONLY the
# symlink. A REAL d99 directory must still work at the same verb, or B5 is satisfied by
# a gate/dispatch layer that refuses everything.
rm -f "$LED/d99"; mkdir -p "$LED/d99"; printf 'state\tplanning\n' > "$LED/d99/meta.tsv"
B5H_OUT=$("$FLEET" gate park d99 1 2>&1); B5H_RC=$?
chk "B5 narrowness: a REAL d99 directory still parks (rc 0)" "0" "$B5H_RC"
case "$(cat "$LED/d99/meta.tsv")" in *gate1-wait*) ok "B5 narrowness: the real d99 was genuinely parked" ;;
  *) no "B5 narrowness: park reported success but wrote no state — B5 proves nothing" ;; esac

proof_summary

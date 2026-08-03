#!/usr/bin/env bash
# RED-VERIFICATION DRIVER for worker-selfsubmit-defang-proof.sh (d37 f1b).
#
# WHY THIS FILE EXISTS. A case whose green state is "nothing changed" passes when
# the operation under test never ran. That is not a hypothetical: d36's V1 case
# still reported PASS after the spawn it tested was replaced with a no-op, because
# the rc it depended on was discarded. So every case in the proof must be shown to
# FAIL when its subject is deleted — and shown here, mechanically, not asserted in
# a report.
#
# Each mutation below copies the whole worktree, neuters ONE operation in the copy,
# runs the proof against that copy (FLEET_BIN), and asserts that exactly the
# expected cases went red — and, just as importantly, that the cases which are
# NOT about that operation stayed green. A mutation that reddens everything proves
# nothing about which case covers what.
#
# It also names, honestly, the cases that are green PRE-FIX by construction. Those
# are premise-pins (8c, 14, 15) and negative controls (3, 3b, 8b), not coverage of
# the change; each is reddened by a mutation of the thing it actually pins.
#
# CASE 8, AND WHY THIS DRIVER EARNED ITS KEEP. After the d37 merge this driver went
# 6/8: case 8 stopped reddening under `remove-defang`. The defence was fine (20/20);
# what had gone false was case 8's COVERAGE CLAIM. 3839f03 (d36, merged in 184b844)
# tightened gate_parse's anchor to require a single-token <from>, and case 8's
# fixture had NO from= at all — so its degenerate "From : " header was refused by
# the anchor whether or not the defang ran. Case 8 was reshaped to a truncation
# that keeps from= (so the anchor accepts and only the defang defends), and the
# now-double-protected empty-<from> path was pinned separately as 8c with its own
# mutation (M9) below. The expected red sets for M1/M7 were NOT edited — 8 is still
# in both. See _reports/f1b-worker-selfsubmit/CASE8-DIAGNOSIS.md.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
PROOF="$HERE/test/worker-selfsubmit-defang-proof.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Every case the proof contains. A mutation run that reports fewer than this did
# not finish, whatever its FAIL set looks like. Derived, not hard-coded, so adding
# a case cannot silently un-guard the completeness check below.
TOTAL_CASES=$(FLEET_BIN="" timeout 600 bash "$PROOF" 2>&1 \
  | sed -n 's/^---- .*: \([0-9]*\) passed, \([0-9]*\) failed$/\1+\2/p' | tail -1)
TOTAL_CASES=$(( ${TOTAL_CASES:-0} ))
if [ "$TOTAL_CASES" -eq 0 ]; then
  echo "REFUSE: baseline proof run produced no tally — cannot verify completeness" >&2
  exit 1
fi

PASS_N=0; FAIL_N=0
ok() { PASS_N=$((PASS_N+1)); printf 'PASS  %s\n' "$*"; }
no() { FAIL_N=$((FAIL_N+1)); printf 'FAIL  %s\n' "$*"; }

# mutate <label> <sed-expr> <expected-red-case-ids...>
mutate() {
  local label="$1" expr="$2"; shift 2
  local want_red="$*"
  local dir="$WORK/$label"
  mkdir -p "$dir"
  cp -a "$HERE/bin" "$HERE/harness.d" "$dir/" 2>/dev/null
  local mut="$dir/bin/fleet"
  local before after
  before=$(sha256sum "$mut" | cut -d' ' -f1)
  sed -i "$expr" "$mut"
  after=$(sha256sum "$mut" | cut -d' ' -f1)
  # VACUITY GUARD: a sed that matched nothing would run the UNMUTATED tree and
  # every case would stay green, which reads exactly like "the mutation is
  # harmless". Refuse instead.
  if [ "$before" = "$after" ]; then
    no "$label — MUTATION DID NOT APPLY (sed matched nothing); this run proves nothing"
    return
  fi
  if ! bash -n "$mut" 2>/dev/null; then
    no "$label — mutant does not parse; sed is malformed, not a valid neutering"
    return
  fi

  local out; out=$(FLEET_BIN="$mut" timeout 600 bash "$PROOF" 2>&1)
  # COMPLETENESS GUARD (review finding). Comparing only the FAIL-id set is not
  # enough: a mutant that HANGS or dies partway yields the same set as one that
  # legitimately reddened those cases and no others — for `remove-defang` the
  # highest expected id is 11, well before groups C/D/E, so an abort after case 11
  # is byte-identical to a pass. Require the proof's own tally, and require it to
  # account for every case. This is the same "green state is nothing changed"
  # trap the driver exists to catch, one level up.
  local tally n_pass n_fail
  tally=$(printf '%s\n' "$out" | sed -n 's/^---- .*: \([0-9]*\) passed, \([0-9]*\) failed$/\1 \2/p' | tail -1)
  if [ -z "$tally" ]; then
    no "$label — proof produced no summary line: it aborted or hung, so its FAIL set proves nothing"
    return
  fi
  n_pass=${tally% *}; n_fail=${tally#* }
  if [ $((n_pass + n_fail)) -ne "$TOTAL_CASES" ]; then
    no "$label — proof reported $((n_pass + n_fail))/$TOTAL_CASES cases: it did not run to completion"
    return
  fi
  local got_red
  got_red=$(printf '%s\n' "$out" | sed -n 's/^FAIL  \([0-9][0-9a-z]*\) .*/\1/p' | sort -u | tr '\n' ' ')
  got_red=${got_red% }
  local want_sorted; want_sorted=$(printf '%s\n' $want_red | sort -u | tr '\n' ' '); want_sorted=${want_sorted% }
  if [ "$got_red" = "$want_sorted" ]; then
    ok "$label — exactly the expected cases went red: [$want_sorted]"
  else
    no "$label — red set mismatch: want [$want_sorted], got [$got_red]"
  fi
}

printf '== RED verification: every case fails when its subject is deleted\n\n'

# M1 — DELETE THE DEFANG. The `so-*` arm can never match, so inbox_pop_text emits
# the pre-fix one-line header. This is the headline: it reproduces the bug.
mutate remove-defang 's/^    so-\*) printf/    so-NEVER-MATCH) printf/' \
  1 2 4 5 6b 7 8 9 10b 11

# M2 — MAKE THE DEFANG UNCONDITIONAL (apply it to every message, not only
# owner-stamped ones). Reddens the two controls and nothing else, which is what
# proves the proof can tell the two classes apart — the whole point of the change.
mutate defang-everything 's/^    so-\*) printf/    *) printf/' 3 3b

# M3 — REVERT THE S1 SCRUB of dispatch and key.
mutate no-scrub '/^  dispatch=\$(printf .*tr /d; /^  key=\$(printf .*tr /d' 12 13

# M4 — NO-OP THE AUTO-SUBMIT (the exact d36 shape). Case 16 must fail with
# "pasted but never submitted"; if it stayed green it would be asserting on the
# routing decision instead of the outcome.
mutate no-submit 's/^    tmux run-shell -b -d /    : run-shell -b -d /' 16

# M5 — NO-OP THE PASTE ITSELF. 16 must fail differently (nothing arrived).
mutate no-paste 's/^    && tmux paste-buffer /    \&\& true paste-buffer /' 16

# M6 — WIDEN gate_parse's head read to three lines. Only case 14 reddens, and that
# is a finding worth keeping in the file: the `sed -n '1,2p'` literal is a PROXY.
# The bound is really enforced by gate_parse's l1/l2 `case` structure, so widening
# the sed alone changes no behaviour. 14 is therefore a source pin, not a
# behavioural one — do not upgrade its wording to claim otherwise.
mutate widen-bound-literal "s/sed -n '1,2p'/sed -n '1,3p'/g" 14

# M7 — WIDEN THE BOUND FOR REAL: make the popped-message arm honour line 3. This
# is the mutation that shows the defang is only as strong as the premise it
# exploits — every group-B inertness case reddens, and so does control 3 (a
# genuine gate on line 2 stops parsing). If this ever happens for real, the guard
# stops defending SILENTLY, which is the whole reason case 14 exists.
mutate widen-bound-real "s/sed -n '1,2p'/sed -n '1,3p'/g; s/| sed -n 2p)/| sed -n 3p)/" \
  1 3 4 5 7 8 9 11 14

# M8 — DELETE THE OWNER ROUTE (inbox_route's `so-*` arm). Case 15 is green PRE-FIX
# by construction; this mutation is what makes it coverage rather than decoration,
# and it re-reddens 16, proving 16 depends on the real route and not on a pane the
# fixture hard-coded.
mutate no-owner-route 's/^    so-\*)$/    so-NEVER-MATCH)/' 15 16

# M9 — DELETE THE ANCHOR'S EMPTY-<from> REJECTION (bin/fleet:2904). This is what
# makes 8c coverage rather than decoration: 8c is green pre-fix by construction,
# so only a mutation of the thing it actually pins can red it. Expected red is 8c
# ALONE — the space-rejection arm survives (case 10's `from` is a whole sentinel,
# i.e. multi-token), and no defang case depends on this clause. A wider red set
# here would mean the two guards are entangled, which is a finding, not a pass.
mutate no-empty-from-reject 's/^        ""|\*\[\[:space:\]\]\*) ;;/        *[[:space:]]*) ;;/' 8c

printf '\n---- %s: %d passed, %d failed\n' "$(basename "$0")" "$PASS_N" "$FAIL_N"
[ "$FAIL_N" -eq 0 ] || exit 1
exit 0

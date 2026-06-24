#!/usr/bin/env bash
# Layer A — pure-function grouping proof (DASH_LIB source-seam).
#
# Drives load_rows over a fabricated `fleet agents` TSV + ledger and asserts the
# reordered ROWS[] display order is GROUPED per orchestrator card:
#   - each owned worker is contiguous under its so-<id> header
#   - cards ordered by MAX-SEVERITY-WITHIN (blocked floats up), tie-break NUMERIC
#     dispatch id (d2 before d10)
#   - within a card: header first, then workers by urgency-rank then name
#   - empty sub-orch renders as a lone header
#   - unowned / main-spawned workers fall to a trailing bucket, last
#   - nav invariants: arows == N+ORPHAN_ROW+SYSTEM_ROW; field <sel> 3 (window_id)
#     maps to the expected window per index
#   - zero-suborch fixture: ROWS[] order is byte-identical to today's flat
#     urgency order (zero-regression default)
#
# Feature is NOT implemented yet, so the grouping/ordering assertions MUST FAIL
# (load_rows currently emits a flat urgency list with no owner grouping).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Case 1 — full grouping: severity-first card order + numeric tie + within-card
#   d1 (idle header) owns aaa(idle), adv-pro(working)        -> card min-rank 1
#   d2 (idle header) owns bbb(BLOCKED)                        -> card min-rank 0  (floats above d1)
#   d3 (idle header) owns nobody                              -> empty card, rank 1
#   loose-worker(idle)                                        -> unowned, last
# urgency rank: blocked=0 < idle=1 < working=2  (lower floats up).
# Card order by (min-rank, numeric-id): d2(0), d1(1,#1), d3(1,#3).
# Expected wname order:
#   so-d2  fleet/fleet_bbb  so-d1  fleet/fleet_aaa  adv-pro  so-d3  loose-worker
# ===========================================================================
(
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  SESS=testcards

  mkdir -p "$TMP/.fleet/dispatch"/{d1,d2,d3}
  printf 'window\tso-d1\nstate\trunning\n'  > "$TMP/.fleet/dispatch/d1/meta.tsv"
  printf 'window\tso-d2\nstate\trunning\n'  > "$TMP/.fleet/dispatch/d2/meta.tsv"
  printf 'window\tso-d3\nstate\tqueued\n'   > "$TMP/.fleet/dispatch/d3/meta.tsv"

  TSV="$TMP/agents.tsv"
  {
    tsv_row idle    x/y testcards        @101 so-d1           %101
    tsv_row idle    x/y testcards        @102 so-d2           %102
    tsv_row idle    x/y testcards        @103 so-d3           %103
    tsv_row idle    r/a testcards_hidden @201 fleet/fleet_aaa %201
    tsv_row working r/a testcards_hidden @202 adv-pro         %202
    tsv_row blocked r/b testcards_hidden @203 fleet/fleet_bbb %203
    tsv_row idle    m/n testcards        @301 loose-worker    %301
  } > "$TSV"
  write_fake "$TSV"
  DASH_LIB=1 FLEET_ROOT="$TMP" source "$DASH" "$SESS"   # top-level (see _lib.sh)
  FLEET_BIN="$FAKE_BIN"; tmux() { :; }; dash_root() { printf '%s' "$TMP"; }
  # Layer A stubs ownership (real @fleet_owner path is proved in test_owner_real.sh)
  owner_of() { case "$1" in @201|@202) echo so-d1;; @203) echo so-d2;; *) echo "";; esac; }

  load_rows

  order=(); wids=()
  for (( i=0; i<N; i++ )); do order+=("$(field "$i" 4)"); wids+=("$(field "$i" 3)"); done
  got_order="${order[*]}"
  want_order="so-d2 fleet/fleet_bbb so-d1 fleet/fleet_aaa adv-pro so-d3 loose-worker"
  assert_eq "case1 grouped ROWS[] order (severity-first, numeric tie, within-card)" \
    "$got_order" "$want_order"

  assert_eq "case1 N == live row count (7; empty card header counts, no pending inflate)" \
    "$N" "7"
  assert_eq "case1 arows == N + ORPHAN_ROW + SYSTEM_ROW" \
    "$(arows)" "$(( N + ORPHAN_ROW + SYSTEM_ROW ))"
  assert_eq "case1 arows == 7 (no synthetic rows in this fixture)" "$(arows)" "7"

  # nav invariant: selecting each index and reading window_id (field 3) targets
  # the expected agent post-regroup.
  got_wids="${wids[*]}"
  want_wids="@102 @203 @101 @201 @202 @103 @301"
  assert_eq "case1 field <sel> 3 (window_id) maps per index after regroup" \
    "$got_wids" "$want_wids"

  # structural: empty card so-d3 is a lone header (no worker row follows before
  # the unowned loose-worker).
  idx_d3=-1; idx_loose=-1
  for (( i=0; i<N; i++ )); do
    [ "${order[$i]}" = so-d3 ] && idx_d3=$i
    [ "${order[$i]}" = loose-worker ] && idx_loose=$i
  done
  assert_eq "case1 empty card so-d3 immediately precedes the unowned bucket" \
    "$idx_d3" "$(( idx_loose - 1 ))"
  exit "$FAILED"
) ; r1=$?

# ===========================================================================
# Case 2 — NUMERIC dispatch-id tie-break (d2 before d10, NOT lexical d10<d2).
#   so-d2 owns w-bbb ; so-d10 owns w-ccc ; all idle (equal severity).
# Expected: so-d2, w-bbb, so-d10, w-ccc.
# ===========================================================================
(
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  SESS=testcards
  mkdir -p "$TMP/.fleet/dispatch"/{d2,d10}
  printf 'window\tso-d2\n'  > "$TMP/.fleet/dispatch/d2/meta.tsv"
  printf 'window\tso-d10\n' > "$TMP/.fleet/dispatch/d10/meta.tsv"

  TSV="$TMP/agents.tsv"
  {
    tsv_row idle x/y testcards        @110 so-d10 %110
    tsv_row idle x/y testcards        @102 so-d2  %102
    tsv_row idle r/c testcards_hidden @210 w-ccc  %210
    tsv_row idle r/b testcards_hidden @202 w-bbb  %202
  } > "$TSV"
  write_fake "$TSV"
  DASH_LIB=1 FLEET_ROOT="$TMP" source "$DASH" "$SESS"   # top-level (see _lib.sh)
  FLEET_BIN="$FAKE_BIN"; tmux() { :; }; dash_root() { printf '%s' "$TMP"; }
  owner_of() { case "$1" in @202) echo so-d2;; @210) echo so-d10;; *) echo "";; esac; }

  load_rows
  order=(); for (( i=0; i<N; i++ )); do order+=("$(field "$i" 4)"); done
  assert_eq "case2 numeric tie-break d2 BEFORE d10 (not lexical)" \
    "${order[*]}" "so-d2 w-bbb so-d10 w-ccc"
  exit "$FAILED"
) ; r2=$?

# ===========================================================================
# Case 3 — ZERO sub-orchs: ROWS[] order is byte-identical to today's flat
#   urgency order. No so-* rows, no owners. This is the zero-regression
#   default and is computed feature-independently by replaying the exact
#   urgency pipeline from load_rows.
# ===========================================================================
(
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  SESS=testcards
  TSV="$TMP/agents.tsv"
  {
    tsv_row working r/a testcards_hidden @201 fleet/fleet_aaa %201
    tsv_row idle    r/b testcards_hidden @202 fleet/fleet_bbb %202
    tsv_row blocked r/c testcards_hidden @203 fleet/fleet_ccc %203
  } > "$TSV"
  write_fake "$TSV"
  DASH_LIB=1 FLEET_ROOT="$TMP" source "$DASH" "$SESS"   # top-level (see _lib.sh)
  FLEET_BIN="$FAKE_BIN"; tmux() { :; }; dash_root() { printf '%s' "$TMP"; }
  owner_of() { echo ""; }   # nothing owned

  load_rows
  got=(); for (( i=0; i<N; i++ )); do got+=("$(field "$i" 4)"); done

  # Reference: today's flat order, replicating load_rows' filter + urgency sort
  # independently of the feature code.
  want=$("$FLEET_BIN" agents \
    | awk -F'\t' -v S="$SESS" '($7!="")&&($3==S||$3==S"_hidden")&&($5!="main"){print}' \
    | sort -t$'\t' -k1,1 \
    | awk -F'\t' '$1=="blocked"{o=0}$1=="idle"{o=1}$1=="working"{o=2}$1!~/blocked|idle|working/{o=3}{print o"\t"$0}' \
    | sort -n | cut -f2- | cut -f5 | paste -sd' ' -)
  assert_eq "case3 zero-suborch ROWS[] == today's flat urgency order (byte-identical)" \
    "${got[*]}" "$want"
  exit "$FAILED"
) ; r3=$?

(( r1 || r2 || r3 )) && exit 1
exit 0

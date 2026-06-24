#!/usr/bin/env bash
# D2 proof — owner_of's process-lifetime cache must actually memoise.
#
# owner_of reads @fleet_owner via `tmux show -wqv … @fleet_owner`. The grouping
# pass classifies every non-header row by owner. The cache (OWN_RAW, not cleared
# per load_rows, owner immutable per window) must hold ACROSS refreshes: re-running
# load_rows must NOT re-issue the tmux query for windows already seen.
#
# We do NOT stub owner_of (that is the code under test); instead we stub `tmux` to
# COUNT every @fleet_owner query (and still return the right owner). Then we run
# load_rows three times and assert the query count after the 3rd load equals the
# count after the 1st (cache holds — zero re-queries on refresh).
#
# On HEAD 26d9d89 this MUST FAIL: group_rows calls `own=$(owner_of "$wid")` via a
# command substitution, so owner_of's OWN_RAW write lands in a throwaway subshell
# and is discarded — every non-header row re-queries tmux on every refresh, so the
# count grows linearly with the number of loads.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  QFILE="$TMP/qcount"; : > "$QFILE"
  mkdir -p "$TMP/.fleet/dispatch"/{d1,d2}
  printf 'window\tso-d1\n' > "$TMP/.fleet/dispatch/d1/meta.tsv"
  printf 'window\tso-d2\n' > "$TMP/.fleet/dispatch/d2/meta.tsv"
  TSV="$TMP/agents.tsv"
  {
    tsv_row idle    x/y testcards        @101 so-d1           %101
    tsv_row idle    x/y testcards        @102 so-d2           %102
    tsv_row working r/a testcards_hidden @201 fleet/fleet_aaa %201
    tsv_row idle    r/a testcards_hidden @202 adv-pro         %202
    tsv_row blocked r/b testcards_hidden @203 fleet/fleet_bbb %203
  } > "$TSV"
  write_fake "$TSV"
  DASH_LIB=1 FLEET_ROOT="$TMP" source "$DASH" testcards   # top-level (see _lib.sh)
  FLEET_BIN="$FAKE_BIN"; dash_root() { printf '%s' "$TMP"; }

  # Counting tmux stub: records one query per @fleet_owner lookup and returns the
  # owner so grouping still works. owner_of is NOT stubbed — its real caching runs.
  tmux() {
    case "$*" in
      *@fleet_owner*)
        printf 'q\n' >> "$QFILE"
        local a prev="" wid=""
        for a in "$@"; do [ "$prev" = -t ] && wid="$a"; prev="$a"; done
        case "$wid" in @201|@202) printf 'so-d1' ;; @203) printf 'so-d2' ;; esac ;;
      *) : ;;
    esac
  }

  load_rows; c1=$(grep -c . "$QFILE")
  load_rows; load_rows; c3=$(grep -c . "$QFILE")

  # sanity: the first load DID query (the harness counts) and grouping is alive
  assert_eq "D2 sanity: first load issued >=1 @fleet_owner query (counter live)" \
    "$(( c1 >= 1 ? 1 : 0 ))" "1"
  assert_eq "D2 sanity: grouping still works through the real owner_of (so-d* live + N==5)" \
    "$N" "5"
  # the cache must hold: 2 more loads add ZERO queries
  assert_eq "D2 owner_of cache holds across refreshes (queries after load#3 == after load#1; got c1=$c1 c3=$c3)" \
    "$c3" "$c1"
  exit "$FAILED"
) || exit 1
exit 0

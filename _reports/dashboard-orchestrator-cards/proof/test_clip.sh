#!/usr/bin/env bash
# D1 proof — card-mode overscroll + half-written header at the clip boundary.
#
# Over a multi-card fixture, sweep LINES 3..24 (COLS=100) and assert at EVERY
# height:
#   (a) NO OVERSCROLL — rendered output line count <= LINES (render must keep
#       content within slots=LINES-2 plus the two borders; a terminal that gets
#       > LINES lines scrolls, drifting the top border off and corrupting the
#       next tput-cup-0,0 redraw).
#   (b) NO HEADER FALL-THROUGH — a clipped so-<id> header must never be drawn as
#       an ordinary worker/pill row. A header only ever appears on a DIVIDER line
#       (one carrying the ─ rule glyph); if a so-<id> shows up on a line with no
#       ─, the header block's `continue` was skipped and it fell through to the
#       worker-row printer (a half-written card).
#
# On HEAD 26d9d89 (feature present, bug present) this MUST FAIL: the worker-row
# print is unguarded by (( drawn < slots )) and the header `continue` sits inside
# the clip guard. test_width.sh's "clean clip" only samples LINES=8 (which
# happens to pass), so the sweep is what exposes it.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

HEADER_IDS="so-d1 so-d2 so-d3"

(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/.fleet/dispatch"/{d1,d2,d3}
  printf 'window\tso-d1\nstate\trunning\n' > "$TMP/.fleet/dispatch/d1/meta.tsv"
  printf 'window\tso-d2\nstate\trunning\n' > "$TMP/.fleet/dispatch/d2/meta.tsv"
  printf 'window\tso-d3\nstate\tqueued\n'  > "$TMP/.fleet/dispatch/d3/meta.tsv"
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
  DASH_LIB=1 FLEET_ROOT="$TMP" source "$DASH" testcards   # top-level (see _lib.sh)
  FLEET_BIN="$FAKE_BIN"; tmux() { :; }; dash_root() { printf '%s' "$TMP"; }
  owner_of() { case "$1" in @201|@202) echo so-d1;; @203) echo so-d2;; *) echo "";; esac; }

  over=0 fall=0 sampled=0
  for L in $(seq 3 24); do
    stub_tput 100 "$L"
    load_rows
    mapfile -t OUT < <(render)
    sampled=$(( sampled + 1 ))
    (( ${#OUT[@]} > L )) && { over=$(( over + 1 )); printf '      OVERSCROLL L=%s -> %s lines\n' "$L" "${#OUT[@]}"; }
    for ln in "${OUT[@]}"; do
      s=$(printf '%s' "$ln" | strip_sgr)
      for id in $HEADER_IDS; do
        case "$s" in
          *"$id"*) case "$s" in *"─"*) : ;; *) fall=$(( fall + 1 )); printf '      FALLTHROUGH L=%s header %s as worker row: |%s|\n' "$L" "$id" "$s" ;; esac ;;
        esac
      done
    done
  done

  assert_eq "D1(a) no card-mode overscroll across LINES 3..24 (sampled $sampled heights)" "$over" "0"
  assert_eq "D1(b) no clipped so-<id> header rendered as a worker/pill row" "$fall" "0"
  exit "$FAILED"
) || exit 1
exit 0

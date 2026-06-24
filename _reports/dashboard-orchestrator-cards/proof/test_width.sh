#!/usr/bin/env bash
# Layer A — render alignment / width-invariant proof.
#
# Captures render() at several COLUMNS over a fixture containing cards and an
# unowned worker, then asserts:
#   - CARD CHROME is emitted: a labelled divider line per so-<id> (a line that
#     contains both the so-id AND the ─ rule glyph) and a `unowned` rule. These
#     are the feature-present signals and MUST FAIL while the feature is absent
#     (today so-d1 renders as a normal pill row with no ─ divider, and no
#     "unowned" label is ever printed).
#   - WIDTH INVARIANT: after stripping SGR, every rendered line has the same
#     display width, == COLUMNS-1 (the right rail is a constant column) and no
#     line exceeds COLUMNS-1 (the no-wrap/no-scroll invariant, fleet-dash:692).
#   - CLEAN CLIP: at a tiny LINES the output never overscrolls (line count <= LINES).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# write the card fixture (ledger + agents TSV + fake bin) into $TMP. Does NOT
# source the dash — that must happen at the subshell top level (see _lib.sh).
build_fixture() {
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
}

# emit the standard Layer-A overrides; eval'd at subshell top level after source.
ownmap='owner_of() { case "$1" in @201|@202) echo so-d1;; @203) echo so-d2;; *) echo "";; esac; }'

# --- width invariant + card chrome across COLUMNS -----------------------------
for COLS in 60 80 120 200; do
(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  build_fixture
  DASH_LIB=1 FLEET_ROOT="$TMP" source "$DASH" testcards   # top-level (see _lib.sh)
  FLEET_BIN="$FAKE_BIN"; tmux() { :; }; dash_root() { printf '%s' "$TMP"; }
  eval "$ownmap"
  stub_tput "$COLS" 40
  load_rows
  mapfile -t LINES < <(render)

  # Width invariant is measured over the OUTER-RAIL content lines (those starting
  # with the left rail │) — that is exactly where the card indent / right-rail
  # alignment lives and where the §2.4 card-chrome width-budget bug would show.
  # The decorative corner borders (╭…╮ / ╰…╯) are excluded: the bottom hint rule
  # carries a known pre-existing hrule off-by-one (n==0 emits a stray ─) that is
  # unrelated to this feature, so folding it in would taint the feature-absent
  # signal. Overflow that would actually wrap/scroll is caught as `> COLS`.
  want_w=$(( COLS - 1 ))     # inner+2 == cols-1 (right rail one column in)
  maxw=0; over=0; uneven=0; common=-1; rails=0
  for ln in "${LINES[@]}"; do
    s=$(printf '%s' "$ln" | strip_sgr)
    [ -z "$s" ] && continue          # ignore wholly-empty capture lines
    w=${#s}
    (( w > maxw )) && maxw=$w
    (( w > COLS )) && over=1          # genuine overflow → terminal wrap/scroll
    case "$s" in
      '│'*) rails=$(( rails + 1 ))
            if (( common < 0 )); then common=$w
            elif (( w != common )); then uneven=1; fi ;;
    esac
  done

  assert_eq "w$COLS: every rail content line is the same display width (col aligned)" \
    "$uneven" "0"
  assert_eq "w$COLS: rail content width == COLUMNS-1 ($want_w); got common=$common" \
    "$common" "$want_w"
  assert_eq "w$COLS: no line overflows the terminal (maxw=$maxw <= $COLS)" \
    "$over" "0"

  # card chrome: a divider line carrying the so-id AND the ─ rule glyph
  for id in so-d1 so-d2 so-d3; do
    hit=0
    for ln in "${LINES[@]}"; do
      s=$(printf '%s' "$ln" | strip_sgr)
      case "$s" in *"$id"*"─"*|*"─"*"$id"*) hit=1; break;; esac
    done
    assert_eq "w$COLS: card divider rule present for $id" "$hit" "1"
  done

  # unowned bucket rule
  uhit=0
  for ln in "${LINES[@]}"; do
    s=$(printf '%s' "$ln" | strip_sgr)
    case "$s" in *unowned*) uhit=1; break;; esac
  done
  assert_eq "w$COLS: unowned bucket rule present" "$uhit" "1"

  exit "$FAILED"
) || exit 1
done

# --- clean clip at tiny LINES -------------------------------------------------
(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  build_fixture
  DASH_LIB=1 FLEET_ROOT="$TMP" source "$DASH" testcards   # top-level (see _lib.sh)
  FLEET_BIN="$FAKE_BIN"; tmux() { :; }; dash_root() { printf '%s' "$TMP"; }
  eval "$ownmap"
  L=8
  stub_tput 100 "$L"
  load_rows
  mapfile -t LINES < <(render)
  assert_eq "clip: output line count <= LINES ($L) — no overscroll" \
    "$(( ${#LINES[@]} <= L ? 0 : 1 ))" "0"
  exit "$FAILED"
) || exit 1

exit 0

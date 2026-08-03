#!/usr/bin/env bash
# dispatch-alloc-proof.sh — d38 suite A: the allocator never returns a directory
# it did not create.
#
# THE RULE THIS SUITE IS BUILT AROUND. A case whose green state is "nothing
# changed" passes when the operation under test never ran. Two traps are specific
# to this area and both were live before this suite existed:
#   * the allocator `die`s without a tmux session, and
#   * `bin/fleet-dispatch.sh` swallows the allocator's stderr AND its rc.
# So a broken fixture produces "no damage" and reads GREEN. EVERY case here
# asserts FIRST that the operation under test actually executed (a genuinely new
# dir, a printed path, a written brief), and only then that the thing it must not
# touch is byte-identical.
#
# SANDBOX. Sources the hardened test/hidden-proof-common.sh, which isolates all
# five of FLEET_ROOT, FLEET_SESSION, TMUX_TMPDIR, XDG_RUNTIME_DIR and
# XDG_CONFIG_HOME, and (P6) refuses to start when FLEET_ROOT and tmux @fleet_root
# disagree. This dispatch exists BECAUSE a fixture escaped its sandbox and mutated
# the live d1 ledger.
#
#   bash test/dispatch-alloc-proof.sh

. "$(dirname "$0")/hidden-proof-common.sh"

proof_isolate
proof_session t1

LED="$FLEET_ROOT/.fleet/dispatch"
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
reset_led() { rm -rf "$LED"; mkdir -p "$LED"; }

# ---------------------------------------------------------------------------
section "A1 — the original condition, reproduced directly (seq behind a LIVE d36)"
# 2026-08-02: seq read 35, d36 existed (created out-of-band by so-d31) and was
# RUNNING (state=planning, live sub-orch in @53). `fleet dispatch-alloc` returned
# d36 and stamped `state queued` + a fresh `created` over the live meta.tsv.
reset_led
echo 35 > "$LED/seq"
mkdir -p "$LED/d36"
printf 'state\tplanning\nwindow\tso-d36-live\n' > "$LED/d36/meta.tsv"
printf 'the live brief that must not be touched\n'    > "$LED/d36/instruction.txt"
A1_META_BEFORE=$(sha "$LED/d36/meta.tsv")
A1_INST_BEFORE=$(sha "$LED/d36/instruction.txt")

A1_OUT=$("$FLEET" dispatch-alloc 2>"$TMPROOT/a1.err"); A1_RC=$?

# POSITIVE CONTROL FIRST — without this the three byte-identical assertions below
# all pass when the allocator did nothing at all (the exact silent-pass shape this
# suite exists to stamp out).
chk "A1 pos-control: allocator exited 0" 0 "$A1_RC"
if [ -n "$A1_OUT" ] && [ -d "$A1_OUT" ]; then ok "A1 pos-control: a dir path was printed and exists ($A1_OUT)"
else no "A1 pos-control: no usable dir printed (got '$A1_OUT'; stderr: $(cat "$TMPROOT/a1.err"))"; fi
if [ -s "${A1_OUT:-/nonexistent}/meta.tsv" ] && grep -q '^created' "${A1_OUT:-/nonexistent}/meta.tsv" 2>/dev/null
then ok "A1 pos-control: the NEW dir carries an allocator-written 'created'"
else no "A1 pos-control: new dir has no allocator-written 'created' — allocator did not really run"; fi

chk_ne "A1 (i): the returned dir is NOT the live d36" "$LED/d36" "$A1_OUT"
chk "A1 (ii): d36/meta.tsv is byte-identical"        "$A1_META_BEFORE" "$(sha "$LED/d36/meta.tsv")"
chk "A1 (iii): d36/instruction.txt is byte-identical" "$A1_INST_BEFORE" "$(sha "$LED/d36/instruction.txt")"

# ---------------------------------------------------------------------------
section "A2 — counter far behind the disk (seq=0, d1..d38 present)"
reset_led
echo 0 > "$LED/seq"
for i in $(seq 1 38); do mkdir -p "$LED/d$i"; done
A2_OUT=$("$FLEET" dispatch-alloc 2>/dev/null)
chk "A2: allocates d39 (seeded from the disk max, not the counter)" "$LED/d39" "$A2_OUT"
chk "A2: seq is advanced to 39"                                     "39" "$(cat "$LED/seq" 2>/dev/null)"
if grep -qi 'is BEHIND the highest ledger dir' "$LED/alerts.log" 2>/dev/null
then ok "A2: an alert records that seq was behind the disk"
else no "A2: no 'seq behind disk' alert in $LED/alerts.log"; fi

# ---------------------------------------------------------------------------
section "A3 — 20 concurrent allocations hand out 20 DISTINCT dirs"
reset_led
echo 0 > "$LED/seq"
for i in $(seq 1 20); do ( "$FLEET" dispatch-alloc 2>/dev/null > "$TMPROOT/a3.$i" ) & done
wait
A3_ALL=$(cat "$TMPROOT"/a3.* 2>/dev/null | grep -c .)
A3_UNIQ=$(cat "$TMPROOT"/a3.* 2>/dev/null | sort -u | grep -c .)
chk "A3 pos-control: all 20 allocations produced a path" 20 "$A3_ALL"
chk "A3: all 20 paths are DISTINCT (no dir handed out twice)" "$A3_ALL" "$A3_UNIQ"
A3_MAX=$(ls -1 "$LED" 2>/dev/null | grep -E '^d[0-9]+$' | sed 's/^d//' | sort -n | tail -1)
chk "A3: seq equals the max allocated id" "$A3_MAX" "$(cat "$LED/seq" 2>/dev/null)"

# ---------------------------------------------------------------------------
section "A4 — stray ledger entries are ignored; a symlink is never written through"
# The symlink is planted at the id the allocator will try NEXT (d6), not at some
# distant d99: a symlink it never reaches proves nothing. `mkdir -p` FOLLOWS a
# trailing symlink and `[ -d ]` follows it too — only bare `mkdir(2)` refuses — so
# this fixture is what makes that difference observable instead of asserted.
reset_led
echo 5 > "$LED/seq"
mkdir -p "$LED/d1" "$LED/d5" "$LED/d1c"
: > "$LED/alerts.log"
mkdir -p "$TMPROOT/x"; printf 'outside\n' > "$TMPROOT/x/canary"
ln -s "$TMPROOT/x" "$LED/d6"
ln -s "$TMPROOT/x" "$LED/d99"
A4_CANARY=$(sha "$TMPROOT/x/canary")
A4_OUT=$("$FLEET" dispatch-alloc 2>"$TMPROOT/a4.err"); A4_RC=$?
# The `^d[0-9]+$` filter's own justification is that a filename otherwise reaches an
# ARITHMETIC (i.e. eval) context. Nothing else in A4 can observe it — every other
# assertion here is independently covered by bare `mkdir` — so assert it directly:
# with strays in the ledger the scan must stay silent.
if [ -s "$TMPROOT/a4.err" ]
then no "A4: the scan reached a stray name in an arithmetic context: $(tr '\n' '|' < "$TMPROOT/a4.err" | head -c 200)"
else ok "A4: no stray ledger entry reaches the scan's arithmetic context"; fi
chk "A4 pos-control: allocation succeeded" 0 "$A4_RC"
if [ -n "$A4_OUT" ] && [ -d "$A4_OUT" ] && [ ! -L "$A4_OUT" ]
then ok "A4 pos-control: returned a REAL directory, not a symlink ($A4_OUT)"
else no "A4 pos-control: returned '$A4_OUT' (missing, or a symlink)"; fi
chk_ne "A4: never returns the symlinked d6 (the very next candidate)" "$LED/d6" "$A4_OUT"
chk_ne "A4: never returns the symlinked d99"                          "$LED/d99" "$A4_OUT"
chk "A4: the symlink target is untouched" "$A4_CANARY" "$(sha "$TMPROOT/x/canary")"
if [ -e "$TMPROOT/x/meta.tsv" ]; then no "A4: wrote meta.tsv THROUGH the symlink into $TMPROOT/x"
else ok "A4: nothing was written through the symlink"; fi
if [ "$A4_OUT" = "$LED/d1c" ] || [ "$A4_OUT" = "$LED/seq" ]
then no "A4: a non-conforming entry ($A4_OUT) was treated as a dispatch id"
else ok "A4: non-conforming entries (d1c, seq, alerts.log) are not dispatch ids"; fi

# ---------------------------------------------------------------------------
section "A5 — an unwritable seq degrades to an alert, never to a collision"
reset_led
echo 3 > "$LED/seq"
mkdir -p "$LED/d1" "$LED/d2" "$LED/d3"
chmod 0444 "$LED/seq"
A5_FIRST=$("$FLEET" dispatch-alloc 2>/dev/null)
A5_SECOND=$("$FLEET" dispatch-alloc 2>/dev/null)
chmod 0644 "$LED/seq" 2>/dev/null || true
if [ -n "$A5_FIRST" ] && [ -d "$A5_FIRST" ]; then ok "A5 pos-control: first allocation still produced a dir ($A5_FIRST)"
else no "A5 pos-control: first allocation produced nothing"; fi
chk_ne "A5: the SECOND allocation does not re-hand-out the first dir" "$A5_FIRST" "$A5_SECOND"
if [ -n "$A5_SECOND" ] && [ -d "$A5_SECOND" ]; then ok "A5: the second allocation self-healed from the disk max"
else no "A5: second allocation produced nothing"; fi
if grep -qi 'seq write FAILED' "$LED/alerts.log" 2>/dev/null
then ok "A5: the failed seq write is alerted, not swallowed"
else no "A5: no seq-write-failure alert in $LED/alerts.log"; fi

# ---------------------------------------------------------------------------
section "A6 — THE CALLER: bin/fleet-dispatch.sh asserts freshness, not existence"
# The repo's first test that drives bin/fleet-dispatch.sh at all. A stub FLEET_BIN
# stands in for `fleet`, so this case tests the HOOK's guard in isolation from the
# allocator fix: even handed a colliding dir, the hook must not truncate the brief.
HOOK="$FLEET_REPO/bin/fleet-dispatch.sh"
STUB="$TMPROOT/stubbin"; mkdir -p "$STUB"
mk_stub() { # mk_stub <dir-that-dispatch-alloc-prints> <alloc-rc>
  cat > "$STUB/fleet" <<EOF
#!/bin/sh
case "\$1" in
  dispatch-classify) echo dispatch-bare ;;
  dispatch-alloc)    printf '%s\n' '$1'; exit $2 ;;
  dispatch-alert)    shift; printf '%s\n' "\$*" >> '$TMPROOT/a6.alerts' ;;
  *)                 : ;;
esac
exit 0
EOF
  chmod +x "$STUB/fleet"
}
run_hook() { # run_hook <prompt-body>
  (
    export PATH="$STUB:$PATH" FLEET_ROLE=main
    unset TMUX_PANE
    printf '{"prompt":"%s"}' "$1" | sh "$HOOK" >"$TMPROOT/a6.out" 2>"$TMPROOT/a6.err"
  )
  echo $?
}

if ! command -v jq >/dev/null 2>&1; then
  no "A6: jq is missing — bin/fleet-dispatch.sh passes through and this case cannot run"
else
  # (a) COLLISION: the stub hands the hook a dir that already holds a brief.
  reset_led; : > "$TMPROOT/a6.alerts"
  mkdir -p "$LED/d7"
  printf 'the live brief that must not be truncated\n' > "$LED/d7/instruction.txt"
  printf 'state\tplanning\n' > "$LED/d7/meta.tsv"
  A6_BEFORE=$(sha "$LED/d7/instruction.txt")
  mk_stub "$LED/d7" 0
  run_hook "a brand new instruction" >/dev/null
  chk "A6 (collision): instruction.txt is NOT truncated" "$A6_BEFORE" "$(sha "$LED/d7/instruction.txt")"
  if [ -s "$TMPROOT/a6.alerts" ] || grep -qi 'refus\|collision\|exists' "$TMPROOT/a6.err" 2>/dev/null
  then ok "A6 (collision): the refusal is recorded loudly, not swallowed"
  else no "A6 (collision): the hook failed SILENTLY (no alert, no stderr)"; fi

  # (b) POSITIVE CONTROL: the same harness, a genuinely fresh dir → the brief lands.
  #     Without this, (a) passes when the hook exits at some earlier guard and never
  #     reaches the write at all.
  mkdir -p "$LED/d8"
  mk_stub "$LED/d8" 0
  run_hook "a brand new instruction" >/dev/null
  chk "A6 pos-control: on a FRESH dir the same harness writes the brief" \
      "a brand new instruction" "$(cat "$LED/d8/instruction.txt" 2>/dev/null)"

  # (c) The allocator's rc is honoured: a failed alloc must not be read as success.
  reset_led; : > "$TMPROOT/a6.alerts"
  mkdir -p "$LED/d9"
  mk_stub "$LED/d9" 1
  run_hook "must not be written" >/dev/null
  if [ -e "$LED/d9/instruction.txt" ]
  then no "A6 (rc): a NONZERO dispatch-alloc rc was treated as success"
  else ok "A6 (rc): a nonzero dispatch-alloc rc is refused"; fi
fi

# ---------------------------------------------------------------------------
section "A7 — cmd_dispatch_alloc never stamps a dir it did not create"
# Drives the real function with FLEET_SOURCE_ONLY, overriding alloc_id to return a
# colliding id WITHOUT the provenance the allocator sets on a successful create.
reset_led
mkdir -p "$LED/d4"
printf 'state\tplanning\nwindow\tso-d4-live\n' > "$LED/d4/meta.tsv"
A7_BEFORE=$(sha "$LED/d4/meta.tsv")
A7_RC=$(
  (
    FLEET_SOURCE_ONLY=1 . "$FLEET" 2>/dev/null
    alloc_id() { printf 'd4\n'; return 0; }      # a liar: echoes a dir it did not create
    cmd_dispatch_alloc >/dev/null 2>&1
    echo $?
  ) | tail -1
)
chk_ne "A7: refuses (nonzero rc) an id it did not create" "0" "$A7_RC"
chk "A7: the pre-existing meta.tsv is byte-identical"     "$A7_BEFORE" "$(sha "$LED/d4/meta.tsv")"

# A7b — the bounded-retry cap: every candidate taken ⇒ refuse, never stamp, never hang.
# The disk-max scan is stubbed to 0 so the seed lands ON the taken range; without
# that the allocator would (correctly) skip straight past it to a free id and the
# cap would never be exercised.
reset_led
echo 0 > "$LED/seq"
for i in $(seq 1 8); do mkdir -p "$LED/d$i"; done
printf 'state\tplanning\n' > "$LED/d1/meta.tsv"
A7B_BEFORE=$(sha "$LED/d1/meta.tsv")
A7B_RC=$(
  (
    FLEET_SOURCE_ONLY=1 . "$FLEET" 2>/dev/null
    ALLOC_MAX_TRIES=3            # squeeze the cap so the case is fast and deterministic
    ledger_disk_max() { echo 0; }
    cmd_dispatch_alloc >/dev/null 2>&1
    echo $?
  ) | tail -1
)
chk_ne "A7b: an exhausted retry cap refuses (nonzero rc)" "0" "$A7B_RC"
chk "A7b: no ledger dir was stamped on the way"           "$A7B_BEFORE" "$(sha "$LED/d1/meta.tsv")"

proof_summary

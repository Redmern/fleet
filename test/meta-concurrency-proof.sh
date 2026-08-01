#!/usr/bin/env bash
# Proof harness — B3 (d34 round 3): the dispatch ledger must not lose writes.
#
# THE BUG. `meta_set` is an unlocked read-modify-write through a FIXED temporary
# path (`$f.tmp`), and its own comment calls it "atomic tmp+mv". It is neither:
#
#   * no lock  => two writers each read the pre-state, each drop the other's key;
#   * one tmp  => writer A's `mv` can publish writer B's half-written file.
#
# This did not matter until d34 added a courier that writes six keys per delivery on
# fleetd's 2s cadence while the sub-orch writes the same file. The worst observed
# outcome is the SILENT one: `decision-<N>.txt` lands but the ledger `decision` key
# ends up empty, so `gate_deliver` returns 1 forever at `[ -n "$dec" ]` and the
# dispatch sits PARKED FOREVER with nothing able to notice.
#
# `meta_compact` (bin/fleet) has the IDENTICAL defect and runs from reconcile — i.e.
# concurrently with the courier by construction. Fixing only one leaves a writer that
# still `mv`s over a locked writer's file, so case 5 covers it.
#
# GREEN IS NOT PROBABILISTIC. Every assertion here is an invariant a correct lock
# cannot violate even once — "0 losses in N", never "fewer losses than before".
#
# Cases:
#   1. N concurrent writers of DISTINCT keys — every key survives (0 lost)
#   2. meta.tsv is never garbled: every line is exactly key<TAB>value, no dupes
#   3. THE BEHAVIOURAL ONE: decision-<N>.txt exists => ledger `decision` non-empty
#   4. a lock timeout returns non-zero and DOES NOT KILL THE CALLER (subshell pin)
#   5. meta_compact concurrent with meta_set loses no key and leaves no fixed tmp
#   6. meta_set reports a real exit status on failure
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }

# Source the real functions — never a copy. FLEET_SOURCE_ONLY is bin/fleet's own
# source guard, so this exercises the shipping definitions of meta_set/meta_compact.
export FLEET_SOURCE_ONLY=1
# shellcheck disable=SC1090
. "$FLEET" || { echo "REFUSE: cannot source $FLEET"; exit 1; }
unset FLEET_SOURCE_ONLY

echo "== d34 B3 — dispatch ledger concurrency proof"
if bash -n "$FLEET" 2>/dev/null; then pass "0 bin/fleet parses"; else
  fail "0 bin/fleet parses" "$(bash -n "$FLEET" 2>&1 | head -3)"; fi

# --- 1. N concurrent writers of distinct keys: every key survives --------------
N=30
D1="$TMPROOT/d1"; mkdir -p "$D1"
i=0; while [ "$i" -lt "$N" ]; do meta_set "$D1" "k$i" "v$i" & i=$((i+1)); done
wait 2>/dev/null
missing=""; i=0
while [ "$i" -lt "$N" ]; do
  [ "$(meta_get "$D1" "k$i")" = "v$i" ] || missing="$missing k$i"
  i=$((i+1))
done
lost=$(printf '%s' "$missing" | wc -w)
if [ "$lost" = 0 ]; then
  pass "1 $N concurrent distinct-key writes — 0 lost"
else
  fail "1 concurrent distinct-key writes lose nothing" \
       "$lost of $N keys lost:$missing — an unlocked read-modify-write drops every key it did not read"; fi

# --- 2. the file is never garbled --------------------------------------------
# A shared tmp path lets one writer's `mv` publish another's half-written file, so
# the failure shows up as a truncated line or a duplicated key, not only as loss.
bad=$(awk -F'\t' 'NF!=2{b++} {seen[$1]++} END{for(k in seen) if(seen[k]>1) b++; print b+0}' "$D1/meta.tsv" 2>/dev/null)
if [ "${bad:-1}" = 0 ]; then
  pass "2 meta.tsv is well-formed after concurrent writes (no partial lines, no duplicate keys)"
else
  fail "2 meta.tsv is well-formed after concurrent writes" \
       "$bad malformed-or-duplicated lines — the shared \$f.tmp published a half-written file"; fi

# --- 3. THE BEHAVIOURAL ONE ---------------------------------------------------
# The blocker's worst outcome stated as a rule: if the decision artifact is on disk,
# the ledger key that makes it deliverable is non-empty. A writer that loses THAT key
# parks the dispatch forever, silently. Each round races the decision write against a
# competing telemetry write, exactly as the courier races the sub-orch.
ROUNDS=${FLEET_META_PROOF_ROUNDS:-60}
viol=0; r=0
while [ "$r" -lt "$ROUNDS" ]; do
  D="$TMPROOT/r$r"; mkdir -p "$D"
  meta_set "$D" state gate1-wait
  printf '[FLEET-GATE:1 slug=x action=implement]\n' > "$D/decision-1.txt"
  ( meta_set "$D" decision approve ) &
  ( meta_set "$D" deliver_attempts 1 ) &
  ( meta_set "$D" decided_at now ) &
  wait 2>/dev/null
  if [ -f "$D/decision-1.txt" ] && [ -z "$(meta_get "$D" decision)" ]; then
    viol=$((viol+1))
  fi
  r=$((r+1))
done
if [ "$viol" = 0 ]; then
  pass "3 decision artifact on disk => ledger decision non-empty (0/$ROUNDS violations)"
else
  fail "3 decision artifact on disk => ledger decision non-empty" \
       "$viol/$ROUNDS rounds ended deliverable-on-disk but UNDELIVERABLE in the ledger — parked forever, silently"; fi

# --- 4. a lock timeout must not kill the caller -------------------------------
# `{ …; exit 1; } 9>>f` runs the exit in the CURRENT shell and takes `fleet` down.
# Only the subshell form `( … ) 9>>f` is safe. Behavioural, not a source grep: hold
# the lock, call meta_set with a 1s wait, and assert the CALLER is still alive after.
D4="$TMPROOT/d4"; mkdir -p "$D4"
meta_set "$D4" pre 1
survived=$(
  ( flock -x 9; sleep 3 ) 9>>"$D4/.meta.lock" &
  holder=$!
  sleep 0.3
  FLEET_META_LOCK_WAIT=1 meta_set "$D4" contended 1 >/dev/null 2>&1
  rc=$?
  printf 'alive rc=%s' "$rc"     # only ever reached if meta_set did not exit us
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
)
case "$survived" in
  alive*) if [ "$survived" = "alive rc=0" ]; then
            fail "4 a lock timeout returns non-zero and does not kill the caller" \
                 "the caller survived but meta_set reported SUCCESS on a contended lock ($survived)"
          else pass "4 a lock timeout returns non-zero and does not kill the caller ($survived)"; fi ;;
  *) fail "4 a lock timeout does not kill the caller" \
          "the calling shell died inside meta_set (got '$survived') — the brace form's \`exit\` killed fleet itself" ;;
esac

# --- 5. meta_compact races meta_set -------------------------------------------
# Same fixed-tmp defect, and reconcile calls it while the courier is writing.
D5="$TMPROOT/d5"; mkdir -p "$D5"
i=0; while [ "$i" -lt 12 ]; do printf 'k%s\tv%s\n' "$i" "$i" >> "$D5/meta.tsv"; i=$((i+1)); done
printf 'k3\tSTALE\n' >> "$D5/meta.tsv"     # a legacy stacked key for compact to collapse
i=0; while [ "$i" -lt 12 ]; do meta_set "$D5" "n$i" "w$i" & i=$((i+1)); done
meta_compact "$D5" &
meta_compact "$D5" &
wait 2>/dev/null
lost5=""; i=0
while [ "$i" -lt 12 ]; do
  [ "$(meta_get "$D5" "n$i")" = "w$i" ] || lost5="$lost5 n$i"
  [ -n "$(meta_get "$D5" "k$i")" ] || lost5="$lost5 k$i"
  i=$((i+1))
done
stray=$(ls -1 "$D5"/meta.tsv.tmp 2>/dev/null | grep -c . || true)
n5=$(printf '%s' "$lost5" | wc -w)
if [ "$n5" = 0 ] && [ "${stray:-0}" = 0 ] && [ -s "$D5/meta.tsv" ]; then
  pass "5 meta_compact concurrent with meta_set loses no key and leaves no shared tmp"
else
  fail "5 meta_compact is concurrency-safe" \
       "$n5 keys lost ($lost5), stray fixed-path tmp=$stray, size=$(wc -c <"$D5/meta.tsv" 2>/dev/null) — meta_compact mv'd over a locked writer"; fi

# --- 6. a real exit status ----------------------------------------------------
# B-8: `meta_set` returning 0 unconditionally is what lets a truncated meta.tsv fail
# SILENTLY in gate_decide — the one verb in fleet deliberately designed to die loudly.
if meta_set "$TMPROOT/d6" ok 1 && [ "$(meta_get "$TMPROOT/d6" ok)" = 1 ]; then
  pass "6a meta_set returns 0 on success"
else
  fail "6a meta_set returns 0 on success" "a successful write reported failure"; fi
: > "$TMPROOT/notadir"                       # mkdir -p must fail against a plain file
if meta_set "$TMPROOT/notadir" k v 2>/dev/null; then
  fail "6b meta_set returns non-zero on failure" \
       "an unwritable dispatch dir reported SUCCESS — gate_decide's \`|| die\` can never fire"
else
  pass "6b meta_set returns non-zero on failure"; fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

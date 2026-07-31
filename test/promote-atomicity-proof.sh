#!/usr/bin/env bash
# promote-atomicity-proof — there is no half-promoted state, ever.
#
# PROOF DESIGN §2 (_reports/install-outage/PLAN-PLAIN.md). Four claims:
#   A. SIGKILL a promote at N different points; after EVERY kill `current` still
#      resolves to a complete, valid release.
#   B. A long-running invocation of the released `fleet` survives a promote
#      swapping a different version underneath it — no `unexpected EOF`. This is
#      the running-script-corruption hazard: bash reads a script incrementally by
#      byte offset, so rewriting one in place corrupts the RUNNING process. It
#      must be tested, not assumed.
#   C. Hammer: thousands of reads of current/bin/fleet against a promote loop,
#      zero read failures.
#   D. `fleet promote --rollback` returns to the previous release and still works.
#
# Half-promote is the specific thing being excluded, and it is worse than the
# outage it replaces: new `fleet` + old `fleet-guard` fails SILENTLY, and a stale
# fail-silent guard ALLOWS what it should deny.
set -u
. "$(dirname "$0")/hidden-proof-common.sh"
proof_isolate

REL="$TMPROOT/rel"
SRC="$TMPROOT/src"
mkdir -p "$SRC"
tar -C "$FLEET_REPO" --exclude=.git --exclude=node_modules -cf - . 2>/dev/null \
  | tar -C "$SRC" -xf - 2>/dev/null

export FLEET_RELEASE_DIR="$REL"
export FLEET_SOURCE="$SRC"

MAN=$("$SRC/bin/fleet" release-manifest "$SRC")

# A release is VALID iff every manifest file is present, the CLI parses, and it
# actually runs. Anything less than all three would pass on a half-promote.
release_valid() {
  local p
  [ -x "$REL/current/bin/fleet" ] || { echo "no bin/fleet"; return 1; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$REL/current/$p" ] || { echo "missing $p"; return 1; }
  done <<EOF
$MAN
EOF
  bash -n "$REL/current/bin/fleet" 2>/dev/null || { echo "bin/fleet does not parse"; return 1; }
  sh -n "$REL/current/bin/fleet-guard" 2>/dev/null || { echo "fleet-guard does not parse"; return 1; }
  FLEET_NO_PROMOTE=1 "$REL/current/bin/fleet" ls >/dev/null 2>&1 || { echo "fleet ls failed"; return 1; }
  return 0
}

section "0. baseline release"
"$SRC/bin/fleet" promote >/dev/null 2>&1
chk "initial promote exits 0" 0 "$?"
why=$(release_valid); chk "baseline release is valid" "" "$why"

section "A. SIGKILL mid-promote, at 12 offsets"

bad=0; killed=0
for us in 1000 3000 6000 10000 15000 25000 40000 60000 90000 130000 180000 250000; do
  touch "$SRC/bin/fleet"                       # give promote real work every round
  before=$(readlink "$REL/current")
  setsid "$SRC/bin/fleet" promote >/dev/null 2>&1 &
  pid=$!
  perl -e "select undef,undef,undef,$us/1000000" 2>/dev/null || sleep 0.01
  kill -9 -"$pid" 2>/dev/null && killed=$((killed+1))
  wait "$pid" 2>/dev/null
  why=$(release_valid)
  if [ -n "$why" ]; then
    no "kill@${us}us: current still valid ($why)"; bad=$((bad+1))
  fi
  after=$(readlink "$REL/current")
  # Whatever happened, `current` is either the OLD release or a NEW complete one
  # — never a partial tree, never dangling, never a stage dir.
  [ -d "$REL/current/" ] || { no "kill@${us}us: current resolves"; bad=$((bad+1)); }
  case "$after" in
    "$before") ;;                       # kill landed before the swap: unchanged
    rel-*) [ -d "$REL/$after" ] || { no "kill@${us}us: new target '$after' exists"; bad=$((bad+1)); } ;;
    *) no "kill@${us}us: current became '$after' (not a rel-<stamp>)"; bad=$((bad+1)) ;;
  esac
done
[ "$bad" = 0 ] && ok "current stayed a complete valid release across 12 kill points" \
               || no "current stayed a complete valid release across 12 kill points ($bad bad)"
[ "$killed" -gt 0 ] && ok "kills actually landed ($killed/12)" || no "kills actually landed (0/12)"

# A killed promote may litter a staging dir; it may never litter a live one, and
# no staging dir may ever be complete enough to be mistaken for a release.
stray=$(command ls -d "$REL"/.stage-* 2>/dev/null | wc -l)
printf '      %s abandoned staging dir(s) after the kills\n' "$stray"
bad2=0
for d in "$REL"/.stage-*; do
  [ -d "$d" ] || continue
  [ "$(readlink "$REL/current")" = "${d##*/}" ] && bad2=$((bad2+1))
done
chk "no staging dir is ever referenced by current" 0 "$bad2"
case "$(readlink "$REL/current")" in
  rel-*) ok "current points at a rel-<stamp>, never a stage dir" ;;
  *)     no "current points at a rel-<stamp> (got '$(readlink "$REL/current")')" ;;
esac

section "B. promote underneath a RUNNING released fleet"

# The long call is itself a promote (a few hundred ms of real work in the
# released bin/fleet), swapped underneath by a second promote from the worktree.
corrupt=0
for i in 1 2 3 4 5; do
  touch "$SRC/bin/fleet-dash"
  err="$TMPROOT/long.$i.err"
  FLEET_NO_PROMOTE=1 "$REL/current/bin/fleet" promote >/dev/null 2>"$err" &
  long=$!
  perl -e 'select undef,undef,undef,0.05' 2>/dev/null || sleep 0.05
  touch "$SRC/bin/fleet"
  "$SRC/bin/fleet" promote >/dev/null 2>&1
  wait "$long"; rc=$?
  [ "$rc" -le 3 ] || { no "long call rc=$rc after a swap underneath"; corrupt=1; }
  if grep -qiE 'unexpected EOF|syntax error|No such file' "$err" 2>/dev/null; then
    no "long call was corrupted by the swap: $(head -1 "$err")"; corrupt=1
  fi
done
[ "$corrupt" = 0 ] && ok "a running released fleet survives 5 swaps underneath it" \
                   || no "a running released fleet survives 5 swaps underneath it"

section "C. hammer — concurrent reads vs a promote loop"

( for i in $(seq 40); do
    touch "$SRC/bin/fleet"
    "$SRC/bin/fleet" promote >/dev/null 2>&1
  done ) &
loop=$!
fails=0; reads=0
while kill -0 "$loop" 2>/dev/null; do
  for i in 1 2 3 4 5 6 7 8 9 10; do
    reads=$((reads+1))
    cat "$REL/current/bin/fleet" >/dev/null 2>&1 || fails=$((fails+1))
  done
done
wait "$loop" 2>/dev/null
[ "$reads" -ge 100 ] && ok "hammer did real work ($reads reads)" || no "hammer did real work ($reads reads)"
chk "zero failed reads of current/bin/fleet during promotes" 0 "$fails"
why=$(release_valid); chk "release still valid after the hammer" "" "$why"

section "D. rollback"

prev=$(head -1 "$REL/previous" 2>/dev/null)
cur=$(readlink "$REL/current")
[ -n "$prev" ] && ok "a previous release is recorded ($prev)" || no "a previous release is recorded"
out=$("$SRC/bin/fleet" promote --rollback 2>&1); rc=$?
chk "promote --rollback exits 0" 0 "$rc"
chk "current is now the previous release" "$prev" "$(readlink "$REL/current")"
why=$(release_valid); chk "the rolled-back release is valid" "" "$why"
FLEET_NO_PROMOTE=1 "$REL/current/bin/fleet" ls >/dev/null 2>&1
chk "fleet ls works after rollback" 0 "$?"
# Toggle: rolling back again returns to where we were, so recovery is reversible.
"$SRC/bin/fleet" promote --rollback >/dev/null 2>&1
chk "rollback is a toggle (back to the release we started from)" "$cur" "$(readlink "$REL/current")"

section "E. retention — at least 3 release trees are kept"

n=$(command ls -1d "$REL"/rel-* 2>/dev/null | wc -l)
[ "$n" -ge 3 ] && ok "≥3 release trees retained ($n)" || no "≥3 release trees retained ($n)"

# Pruning is deliberately COLD-ONLY: a release tree is not removed until it has
# been untouched for 10 minutes, because a long-running `fleet` may still be
# reading harness.d/ or FLEET.md out of the tree its FLEET_DIR resolved to.
# So retention is bounded eventually, not instantly — backdate the trees to
# prove the reaper actually reaps rather than asserting a bound that only holds
# because the proof runs fast.
cur=$(readlink "$REL/current"); prev=$(head -1 "$REL/previous" 2>/dev/null)
for d in "$REL"/rel-*; do
  case "${d##*/}" in "$cur"|"$prev") continue ;; esac
  touch -d '2 hours ago' "$d" 2>/dev/null
done
mkdir -p "$REL/.stage-stale-test" && touch -d '2 hours ago' "$REL/.stage-stale-test"
touch "$SRC/bin/fleet"
"$SRC/bin/fleet" promote >/dev/null 2>&1
n2=$(command ls -1d "$REL"/rel-* 2>/dev/null | wc -l)
[ "$n2" -lt "$n" ] && ok "cold releases ARE pruned ($n -> $n2)" \
                   || no "cold releases ARE pruned ($n -> $n2)"
[ "$n2" -ge 3 ] && ok "…but never below 3 ($n2 kept)" || no "…but never below 3 (got $n2)"
[ -d "$REL/current/" ] && ok "current survived the prune" || no "current survived the prune"
[ -d "$REL/$prev" ] && ok "the rollback target survived the prune" \
                    || no "the rollback target survived the prune"
[ -e "$REL/.stage-stale-test" ] && no "abandoned staging trees are reaped" \
                                || ok "abandoned staging trees are reaped"
why=$(release_valid); chk "release still valid after pruning" "" "$why"

proof_summary

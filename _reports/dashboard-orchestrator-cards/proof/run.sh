#!/usr/bin/env bash
# Run all dashboard-orchestrator-cards proof tests; PASS/FAIL summary; non-zero
# exit if any test fails. While the feature is unimplemented these are EXPECTED
# to fail (red phase) — for the right reason: grouping/card/owner_of absent.
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

TESTS=(test_grouping.sh test_width.sh test_owner_real.sh)
declare -A RC
fail_any=0

for t in "${TESTS[@]}"; do
  echo "==================================================================="
  echo "### $t"
  echo "-------------------------------------------------------------------"
  bash "$DIR/$t"
  RC[$t]=$?
  (( RC[$t] != 0 )) && fail_any=1
  echo
done

echo "==================================================================="
echo "### SUMMARY"
for t in "${TESTS[@]}"; do
  if (( RC[$t] == 0 )); then printf '  PASS  %s\n' "$t"
  else printf '  FAIL  %s (exit %d)\n' "$t" "${RC[$t]}"; fi
done
echo "==================================================================="

exit "$fail_any"

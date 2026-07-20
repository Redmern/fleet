#!/usr/bin/env bash
# Proof harness — the PLAN role + its RECON pre-step, as SHIPPED IN THE DOCS.
#
# This change (d28, W1-W5+W7) is doc-only: it renames the sub-orch's Role 1
# RESEARCH → PLAN, inserts a cheap read-only RECON pre-step (§3.0.1b) that folds
# INTO the research rung, pins a handoff contract with a trust asymmetry, makes
# the fan-out wording harness-neutral, and states a tripwire/escape valve.
#
# Prose has no runner, so the proof is a set of grep-level assertions that the
# invariants the code and crash-recovery depend on SURVIVED the prose edit:
#
#   [1] the `role-phase` cursor value is still the string `research` — RECON did
#       NOT get its own rung. A new value has no case arm and an in-flight ledger
#       would silently restart (the failure §3.0.5 exists to prevent).
#   [2] the cursor SEQUENCE is byte-unchanged.
#   [3] PLAN.md / SYNTHESIS.md / PLAN-PLAIN.md are byte-identical filenames in
#       the docs AND still match what bin/fleet hardcodes into the GATE 1 body.
#   [4] §3.0.1b exists, names RECON.md, and carries the three agreed budgets
#       (<=15-line digest, <=8 read-only calls fallback, <=25-line RECON.md).
#   [5] the RECON denylist is stated (5 prohibitions).
#   [6] §3.0.5's cross-check TABLE carries a RECON.md row.
#   [7] the rename actually landed: `Role 1 — PLAN`, `<slug>-plan`,
#       `<slug>-plan-2` — and NO stale `<slug>-research` survives.
#   [8] the handoff contract: trust asymmetry + a MANDATORY `## Corrections`
#       section in PLAN.md.
#   [9] harness-neutral wording + the degradation clause (no-sub-agent harness).
#  [10] the `fleet new --scratch <slug>-…` sibling machinery survives — it is the
#       W5 escape valve; deleting it would remove the only opt-up.
#  [11] FLEET_SUBORCH.md and SKILL.md ship in ONE commit and AGREE — a sub-orch
#       reads both; a split would hand it contradictory instructions.
#  [12] ZERO bin/fleet edits on this branch. Doc-only means doc-only.
#
# Run before the edit: RED. After: every case PASS.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
MANUAL="$HERE/FLEET_SUBORCH.md"
FLEETBIN="$HERE/bin/fleet"
# SKILL.md lives OUTSIDE this repo (~/.claude_personal/skills/…) and is therefore
# NOT covered by this repo's commit. Assert on it when present; skip loudly when
# absent (a fresh clone on another machine has no such file).
SKILL="${FLEET_SKILL_MD:-$HOME/.claude_personal/skills/fleet-implementation-pipeline/SKILL.md}"

pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }
skip() { echo "  SKIP($1): $2"; }
FAILED=0
SKIPPED=0

has()  { grep -qF -- "$2" "$1"; }          # fixed-string
hasre(){ grep -qE -- "$2" "$1"; }          # regex
hasi() { grep -qEi -- "$2" "$1"; }         # regex, case-insensitive

[ -f "$MANUAL" ] || { echo "FATAL: $MANUAL missing"; exit 1; }

# --- 1. role-phase value is still exactly `research` --------------------------
echo "[1] role-phase rung unchanged (RECON folded into \`research\`)"
if hasre "$MANUAL" '^research → gate1-wait → impl → test → gate2-wait → done$'; then
  pass "cursor sequence line byte-identical"
else
  fail "cursor sequence line byte-identical" "the 6-value sequence line is gone or altered"
fi
# No new rung may be introduced anywhere in the cursor's own vocabulary.
if hasre "$MANUAL" 'role-phase[^\n]*\brecon\b|\brecon →|→ recon\b'; then
  fail "no recon rung" "a \`recon\` value appears in the role-phase cursor"
else
  pass "no recon rung"
fi
# The rename must NOT have swept the cursor value to `plan`.
if hasre "$MANUAL" '^plan → gate1-wait|role-phase.*\bplan\b.*gate1-wait'; then
  fail "cursor not renamed to plan" "cursor value was renamed — bin/fleet has no case arm for it"
else
  pass "cursor not renamed to plan"
fi
# The section must say OUT LOUD that the string stays `research` despite the rename,
# otherwise the next editor 'fixes' the inconsistency and breaks recovery.
# flattened: this explanation legitimately spans several wrapped lines.
if tr '\n' ' ' < "$MANUAL" | grep -qEi 'rung is still spelled .?research|value stays the literal string .?research|(stays|remains) the (literal )?string .?research'; then
  pass "mismatch is documented as deliberate"
else
  fail "mismatch is documented as deliberate" "nothing explains why the rung stays \`research\` after the PLAN rename"
fi

# --- 2. the three artifact filenames are byte-identical -----------------------
echo "[2] artifact filenames intact (bin/fleet hardcodes them)"
for f in PLAN.md SYNTHESIS.md PLAN-PLAIN.md; do
  if has "$MANUAL" "$f"; then pass "manual names $f"; else fail "manual names $f" "missing"; fi
done
# bin/fleet:~1943 bakes this exact path into the GATE 1 body the human pops.
if has "$FLEETBIN" '_reports/$slug/PLAN-PLAIN.md'; then
  pass "bin/fleet still hardcodes _reports/\$slug/PLAN-PLAIN.md"
else
  fail "bin/fleet still hardcodes _reports/\$slug/PLAN-PLAIN.md" "gate body path changed"
fi
# The manual's own artifact contract must still name PLAN-PLAIN.md alongside the
# other two, so the doc and the gate body cannot drift apart.
# grep is line-based and the contract legitimately wraps; flatten before matching.
if tr '\n' ' ' < "$MANUAL" | grep -qE 'PLAN\.md.{0,300}SYNTHESIS\.md.{0,300}PLAN-PLAIN\.md'; then
  pass "artifact contract lists all three together"
else
  fail "artifact contract lists all three together" "the PLAN/SYNTHESIS/PLAN-PLAIN triple was broken up"
fi

# --- 3. §3.0.1b RECON step exists, with the agreed budgets --------------------
echo "[3] §3.0.1b RECON pre-step + budgets"
if hasre "$MANUAL" '^### 3\.0\.1b .*RECON'; then pass "§3.0.1b heading"
else fail "§3.0.1b heading" "no '### 3.0.1b … RECON' heading"; fi
if has "$MANUAL" 'RECON.md'; then pass "names RECON.md"; else fail "names RECON.md" "missing"; fi
if has "$MANUAL" '_reports/<slug>/RECON.md'; then pass "RECON.md path under _reports/<slug>/"
else fail "RECON.md path under _reports/<slug>/" "RECON.md is not pinned to the artifacts dir"; fi
# The three numbers the human signed off on.
hasre "$MANUAL" '15[- ]line|≤ ?15|<= ?15' && pass "15-line digest budget" \
  || fail "15-line digest budget" "no <=15-line digest cap"
hasre "$MANUAL" '8 read-only|≤ ?8|<= ?8'   && pass "8 read-only call budget" \
  || fail "8 read-only call budget" "no <=8 read-only call fallback cap"
hasre "$MANUAL" '25[- ]line|≤ ?25|<= ?25'  && pass "25-line RECON.md budget" \
  || fail "25-line RECON.md budget" "no <=25-line RECON.md cap"
# AUDITABILITY. PLAN.md W1 made `## BUDGET SPENT` a mandatory RECON.md section and
# PROOF DESIGN P1 calls it "the audit, and the reason that section exists". It was
# silently dropped from both shipped docs, so the cap cannot be checked from the
# artifact at all — d28's P1(d) was unrunnable and the measured RECON.mds came in
# at 33 and 35 lines against the 25 cap with nothing to catch it.
if has "$MANUAL" '## BUDGET SPENT'; then
  pass "RECON.md must carry ## BUDGET SPENT (the cap audit)"
else
  fail "RECON.md must carry ## BUDGET SPENT (the cap audit)" \
       "without it the <=25-line / <=8-call budget is unverifiable from the artifact"
fi

# --- 4. the RECON denylist is stated ------------------------------------------
echo "[4] RECON denylist (what RECON must NOT do)"
# Extract just the 3.0.1b section so a hit elsewhere in the manual cannot fake it.
SECT=$(awk '/^### 3\.0\.1b /{f=1} f&&/^### 3\.0\.2 /{f=0} f' "$MANUAL")
sect_has() { printf '%s\n' "$SECT" | grep -qEi -- "$1"; }
sect_has 'no implementation plan|not an implementation plan|never.{0,30}implementation plan' \
  && pass "deny: implementation plan" || fail "deny: implementation plan" "not stated in §3.0.1b"
sect_has 'lens|verdict' \
  && pass "deny: lens/verdict" || fail "deny: lens/verdict" "not stated in §3.0.1b"
sect_has 'PLAN\.md|SYNTHESIS\.md|PLAN-PLAIN\.md' \
  && pass "deny: PLAN/SYNTHESIS/PLAN-PLAIN" || fail "deny: PLAN/SYNTHESIS/PLAN-PLAIN" "not stated in §3.0.1b"
sect_has 'no code|never.{0,20}code|writes no code' \
  && pass "deny: code" || fail "deny: code" "not stated in §3.0.1b"
sect_has 'second sub-agent|one sub-agent|single sub-agent|exactly one' \
  && pass "deny: second sub-agent" || fail "deny: second sub-agent" "not stated in §3.0.1b"

# --- 5. §3.0.5 cross-check TABLE carries a RECON.md row -----------------------
echo "[5] §3.0.5 cross-check table + RECON.md row"
SECT5=$(awk '/^### 3\.0\.5 /{f=1} f&&/^## 3\. /{f=0} f' "$MANUAL")
s5() { printf '%s\n' "$SECT5" | grep -qEi -- "$1"; }
s5 '^\|.*\|.*\|' && pass "cross-check is a table" || fail "cross-check is a table" "no markdown table in §3.0.5"
s5 '^\|.*RECON\.md.*\|' && pass "RECON.md row" || fail "RECON.md row" "no RECON.md row in the table"
s5 '^\|.*SYNTHESIS\.md.*\|' && pass "SYNTHESIS.md row" || fail "SYNTHESIS.md row" "the pre-existing cross-check was lost"
s5 '^\|.*TEST-VERDICT\.md.*\|' && pass "TEST-VERDICT.md row" || fail "TEST-VERDICT.md row" "the pre-existing cross-check was lost"

# --- 6. the RESEARCH → PLAN rename landed, with no stale suffix ---------------
echo "[6] Role 1 renamed RESEARCH → PLAN"
hasre "$MANUAL" 'Role 1 — \*?\*?PLAN' && pass "Role 1 — PLAN" || fail "Role 1 — PLAN" "still 'Role 1 — RESEARCH'"
has "$MANUAL" '<slug>-plan'   && pass "window suffix <slug>-plan"   || fail "window suffix <slug>-plan" "missing"
has "$MANUAL" '<slug>-plan-2' && pass "loop key <slug>-plan-2"      || fail "loop key <slug>-plan-2" "missing"
for f in "$MANUAL"; do
  if grep -qF -- '<slug>-research' "$f"; then
    fail "no stale <slug>-research ($(basename "$f"))" "$(grep -nF -- '<slug>-research' "$f" | head -3 | tr '\n' ' ')"
  else pass "no stale <slug>-research ($(basename "$f"))"; fi
done

# --- 7. handoff contract: trust asymmetry + mandatory ## Corrections ----------
echo "[7] handoff contract"
# The trust asymmetry must be DIRECTIONAL. This check used to be a loose OR-list
# ('unverified|may be wrong|not authoritative|do not trust|verify before') that was
# satisfied by EITHER direction — so it certified green a manual that had silently
# INVERTED the rule PLAN.md W3 specified ("TERRITORY/PRIOR ART are trusted, do not
# re-derive them"), and the d28 proof read ALL PASS while P2 was failing. Assert the
# direction that actually shipped, and reject the inverse.
if tr '\n' ' ' < "$MANUAL" \
   | grep -qEi 'overrules? RECON|never the reverse|RECON is the untrusted|treat every claim[^.]{0,60}lead'; then
  pass "trust asymmetry stated DIRECTIONALLY (PLAN overrules RECON, never the reverse)"
else
  fail "trust asymmetry stated DIRECTIONALLY (PLAN overrules RECON, never the reverse)" \
       "no one-way statement — a vague 'may be wrong' passes in both directions and hides an inversion"
fi
# The inverse rule must NOT also be present. Shipping both leaves the PLAN agent
# holding contradictory instructions, which is worse than shipping neither.
if tr '\n' ' ' < "$MANUAL" \
   | grep -qEi 'do not re-derive|don.t re-derive|territory[^.]{0,40}(is|are) trusted|trusts? the territory'; then
  fail "no contradictory inverse trust rule" \
       "the manual states BOTH that RECON is untrusted AND that its territory is trusted"
else
  pass "no contradictory inverse trust rule"
fi
has "$MANUAL" '## Corrections' && pass "names the ## Corrections section" \
  || fail "names the ## Corrections section" "PLAN.md's mandatory Corrections section is not specified"
hasre "$MANUAL" '## Corrections.{0,600}(MUST|mandatory|required|always)|( MUST|mandatory|required|always).{0,600}## Corrections' \
  && pass "Corrections is mandatory" || fail "Corrections is mandatory" "Corrections is not stated as required"
if hasi "$MANUAL" 'Corrections.{0,400}(none|nothing)|(none|nothing).{0,400}## Corrections'; then
  pass "empty-case spelled out"
else fail "empty-case spelled out" "no instruction for the nothing-to-correct case"; fi

# --- 8. harness-neutral wording + degradation clause -------------------------
echo "[8] harness-neutral fan-out + degradation"
hasre "$MANUAL" 'harness sub-agent|sub-agent tool|harness-neutral|harness.{0,40}(Task|sub-agent)' \
  && pass "fan-out named harness-neutrally" || fail "fan-out named harness-neutrally" "only claude's 'Task tool' is named"
hasre "$MANUAL" '(no|without|lacks?).{0,40}sub-agent' \
  && pass "degradation clause present" || fail "degradation clause present" "no clause for a harness without sub-agents"
# The degradation must land on the SAME budget the fallback names (<=8 read-only calls).
printf '%s\n' "$SECT" | grep -qEi '(inline|yourself|your own context|no sub-agent|without sub-agent)' \
  && pass "RECON degrades inline" || fail "RECON degrades inline" "§3.0.1b has no inline fallback"

# --- 9. the escape valve survives ---------------------------------------------
echo "[9] W5 tripwire / escape valve"
has "$MANUAL" 'fleet new --scratch' && pass "--scratch sibling machinery intact" \
  || fail "--scratch sibling machinery intact" "the escape valve spawn form was deleted"
if hasi "$MANUAL" 'tripwire|blows? (its |the )?budget|exceeds? the budget|over budget|budget is (blown|spent)'; then
  pass "tripwire stated"
else fail "tripwire stated" "no tripwire for a RECON that overruns"; fi

# --- 10. FLEET_SUBORCH.md and SKILL.md agree ---------------------------------
echo "[10] SKILL.md agrees (shipped in the same change; lives outside this repo)"
if [ -f "$SKILL" ]; then
  if grep -qF -- '<slug>-research' "$SKILL"; then
    fail "SKILL.md no stale <slug>-research" "$(grep -nF -- '<slug>-research' "$SKILL" | head -3 | tr '\n' ' ')"
  else pass "SKILL.md no stale <slug>-research"; fi
  has "$SKILL" '<slug>-plan' && pass "SKILL.md uses <slug>-plan" || fail "SKILL.md uses <slug>-plan" "missing"
  has "$SKILL" 'RECON.md' && pass "SKILL.md names RECON.md" || fail "SKILL.md names RECON.md" "the two docs disagree"
  has "$SKILL" '## Corrections' && pass "SKILL.md names ## Corrections" || fail "SKILL.md names ## Corrections" "the two docs disagree"
  for f in PLAN.md SYNTHESIS.md PLAN-PLAIN.md; do
    has "$SKILL" "$f" && pass "SKILL.md names $f" || fail "SKILL.md names $f" "artifact filename lost"
  done
  # The two docs must agree on the DIRECTION of the trust asymmetry, not merely both
  # mention trust. A sub-orch reads both; opposite directions is the worst outcome.
  if tr '\n' ' ' < "$SKILL" \
     | grep -qEi 'overrules? RECON|never the reverse|RECON is the untrusted|treat every claim[^.]{0,60}lead'; then
    pass "SKILL.md states the SAME trust direction as the manual"
  else
    fail "SKILL.md states the SAME trust direction as the manual" \
         "manual says PLAN overrules RECON; SKILL.md does not state that direction"
  fi
else
  skip "SKILL.md assertions" "$SKILL not present on this machine"
  SKIPPED=1
fi

# --- 11. ZERO bin/fleet edits -------------------------------------------------
echo "[11] doc-only: no bin/fleet diff on this branch"
BASE=$(cd "$HERE" && git merge-base HEAD main 2>/dev/null)
if [ -n "$BASE" ]; then
  changed=$(cd "$HERE" && git diff --name-only "$BASE"..HEAD 2>/dev/null; cd "$HERE" && git diff --name-only HEAD 2>/dev/null)
  if printf '%s\n' "$changed" | grep -qx 'bin/fleet'; then
    fail "bin/fleet untouched" "bin/fleet appears in the branch diff"
  else pass "bin/fleet untouched"; fi
else
  skip "bin/fleet untouched" "no merge-base with main"
fi
if bash -n "$FLEETBIN" 2>/dev/null; then pass "bin/fleet parses"; else fail "bin/fleet parses" "syntax error"; fi

echo
# A skip is NOT a pass. Reporting "ALL PASS" with SKILL.md unchecked is how an
# unversioned, absent second doc silently stops being covered.
if [ "$FAILED" != 0 ]; then
  echo "FAILURES"; exit 1
elif [ "$SKIPPED" != 0 ]; then
  echo "PASS (WITH SKIPS — coverage incomplete, see SKIP lines above)"; exit 0
else
  echo "ALL PASS"; exit 0
fi

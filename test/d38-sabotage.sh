#!/usr/bin/env bash
# d38-sabotage.sh — RED-VERIFICATION HARNESS (the proof bar, mechanised).
#
#   "No case ships on a predicted red — run each delete-the-operation mutation,
#    paste observed output."
#
# A case whose green state is "nothing changed" passes when the operation under test
# never ran. Prose cannot tell those apart; only deleting the operation can. This
# script takes a throwaway COPY of the worktree, applies ONE mutation that deletes
# the specific operation a case tests, re-runs that suite in the copy, and records
# the sabotage diff together with the assertions that actually went RED.
#
# EVERY MUTATION CARRIES ITS OWN VACUITY GUARD: each edit is an exact string
# replacement that ABORTS if the text it targets is not found. A mutation that
# silently no-ops would "prove" a case red-verified while changing nothing — the same
# false-green this whole dispatch exists to eliminate, one level up.
#
# This is a HARNESS, not a proof. It must never appear in a green run's evidence on
# its own; its output is the RED half, pasted into the report.
#
#   bash test/d38-sabotage.sh            # every mutation
#   bash test/d38-sabotage.sh M_A1       # one

set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT="${SABOTAGE_OUT:-${FLEET_DOCS:-$REPO/.fleet/notes}/red-evidence}"
mkdir -p "$OUT" 2>/dev/null
ONLY="${1:-}"

run_mutation() { # <name> <suite> <python-mutation-file>
  local name="$1" suite="$2" mut="$3"
  local work; work=$(mktemp -d)
  ( cd "$REPO" && tar cf - bin test FLEET_SUBORCH.md 2>/dev/null ) | tar xf - -C "$work"

  local mrc mout
  mout=$( cd "$work" && python3 "$mut" 2>&1 ); mrc=$?

  {
    printf '### %s — `%s`\n\n' "$name" "$suite"
    if [ "$mrc" -ne 0 ]; then
      printf '**MUTATION DID NOT APPLY — this case has NO red evidence.**\n\n```\n%s\n```\n\n' "$mout"
    else
      printf '**Sabotage diff:**\n\n```diff\n'
      diff -u "$REPO/bin/fleet"                   "$work/bin/fleet"                   2>/dev/null
      diff -u "$REPO/bin/fleet-dispatch.sh"       "$work/bin/fleet-dispatch.sh"       2>/dev/null
      diff -u "$REPO/test/hidden-proof-common.sh" "$work/test/hidden-proof-common.sh" 2>/dev/null
      printf '```\n\n**Observed output — assertions that went RED:**\n\n```\n'
      ( cd "$work" && timeout 300 bash "test/$suite" 2>&1 ) | grep -E '^ *FAIL' | sed -n '1,40p'
      printf '```\n\n'
    fi
  } | tee "$OUT/$name.md"
  rm -rf "$work"
}

M() { # M <name> <suite>  — python mutation body on stdin
  local name="$1" suite="$2" mut; mut=$(mktemp)
  { cat <<'PRELUDE'
import sys
def edit(path, old, new, count=1):
    s = open(path).read()
    if s.count(old) < count:
        sys.exit("VACUITY GUARD: target text not found in %s:\n%s" % (path, old[:300]))
    open(path, 'w').write(s.replace(old, new, count))
PRELUDE
    cat; } > "$mut"
  case "$ONLY" in ""|"$name") run_mutation "$name" "$suite" "$mut" ;; esac
  rm -f "$mut"
}

# ---------------------------------------------------------------------------
# A1 — THE EXACT PRE-IMAGE. All three of the pre-image's properties, because A1
# reproduces the incident and the incident needed all three: no disk-max seed (so
# the counter lands on the live d36), `mkdir -p` (so "already exists" reads as
# success), and no provenance refusal (so meta_set stamps it). Restoring any two
# leaves A1 green — which is itself the measurement that the fix is not one thing.
M M_A1 dispatch-alloc-proof.sh <<'EOF'
edit('bin/fleet', '  disk=$(ledger_disk_max "$led")', '  disk=0')
edit('bin/fleet', 'if mkdir "$led/d$n" 2>/dev/null; then',
                  'if mkdir -p "$led/d$n" 2>/dev/null; then')
edit('bin/fleet', '''  [ -n "$ALLOC_CREATED_DIR" ] && [ -n "$id" ] && [ "$ALLOC_CREATED_DIR" = "$d" ] \\
    || die "dispatch-alloc: refusing to stamp ${d:-<unknown>} — this process did not create it"
''', '')
EOF

# A2 — delete the disk-max scan: seed from the counter alone, as before. NOTE what
# this measures: the returned id stays CORRECT, because the bounded retry reaches
# d39 anyway. Two independent mechanisms cover A2's headline, and only the ALERT is
# unique to the seed — so the alert is the assertion that discriminates. M_A2b below
# removes both and takes the headline red.
M M_A2 dispatch-alloc-proof.sh <<'EOF'
edit('bin/fleet', '  disk=$(ledger_disk_max "$led")', '  disk=0')
EOF

# A2b — seed AND retry both deleted: the allocator has nothing left to reconcile the
# counter against reality and hands back the collided id.
M M_A2b dispatch-alloc-proof.sh <<'EOF'
edit('bin/fleet', '  disk=$(ledger_disk_max "$led")', '  disk=0')
edit('bin/fleet', 'if mkdir "$led/d$n" 2>/dev/null; then',
                  'if mkdir -p "$led/d$n" 2>/dev/null; then')
EOF

# A3 — DELETE THE EXCLUSION. Both halves: the bare-`mkdir` arbiter and the seq lock.
# Deleting either ALONE leaves A3 green, and that is a result worth recording rather
# than hiding — the lock serialises the counter, and the bare mkdir arbitrates even
# unlocked, so each covers for the other. A3 is red only when neither is left.
M M_A3 dispatch-alloc-proof.sh <<'EOF'
edit('bin/fleet', 'if mkdir "$led/d$n" 2>/dev/null; then',
                  'if mkdir -p "$led/d$n" 2>/dev/null; then')
edit('bin/fleet', '  acquire_lock "$led/.seqlock" || return 1\n', '')
EOF

# A4 — `mkdir -p` FOLLOWS the trailing symlink planted at the next candidate, so the
# allocator hands back d6 and cmd_dispatch_alloc stamps meta.tsv straight through it
# into $TMPROOT/x. This is the SECURITY rider made observable: `[ -d ]` and
# `mkdir -p` follow symlinks where `mkdir(2)` does not.
M M_A4 dispatch-alloc-proof.sh <<'EOF'
edit('bin/fleet', 'if mkdir "$led/d$n" 2>/dev/null; then',
                  'if mkdir -p "$led/d$n" 2>/dev/null; then')
EOF

# A4b — delete the `^d[0-9]+$` filter and the -type d guard from the disk scan, so
# stray names (`d1c`, `seq`, `alerts.log`) and a symlinked `d99` reach the scan.
M M_A4b dispatch-alloc-proof.sh <<'EOF'
edit('bin/fleet', '    case "$e" in d) continue ;; d*[!0-9]*) continue ;; d*) ;; *) continue ;; esac\n', '')
edit('bin/fleet', 'find "$led" -maxdepth 1 -mindepth 1 -type d -printf',
                  'find "$led" -maxdepth 1 -mindepth 1 -printf')
EOF

# A5 — discard the seq-write rc, as the pre-image did.
M M_A5 dispatch-alloc-proof.sh <<'EOF'
edit('bin/fleet', '''      echo "$n" > "$led/seq" 2>/dev/null \\
        || append_dashboard_alert "dispatch alloc: seq write FAILED at $led/seq (allocated d$n) — next allocation will self-heal from the disk max"''',
                  '      echo "$n" > "$led/seq" 2>/dev/null')
EOF

# A6 — restore the caller's existence oracle and its truncating write, verbatim.
M M_A6 dispatch-alloc-proof.sh <<'EOF'
s = open('bin/fleet-dispatch.sh').read()
a = s.index('_alert() {')
b = s.index('ID="$(basename "$DIR")"')
pre = ('DIR="$("$FLEET_BIN" dispatch-alloc 2>/dev/null)"\n'
       '[ -n "$DIR" ] && [ -d "$DIR" ] || exit 0\n'
       "printf '%s' \"$BODY\" > \"$DIR/instruction.txt\" 2>/dev/null || exit 0\n")
open('bin/fleet-dispatch.sh', 'w').write(s[:a] + pre + s[b:])
EOF

# A7 — remove ONLY the provenance refusal, keeping the allocator otherwise intact.
M M_A7 dispatch-alloc-proof.sh <<'EOF'
edit('bin/fleet', '''  alloc_id "$led" >/dev/null || die "id allocation failed (no free id, or lock contention) — nothing was stamped"
  id="$ALLOC_ID"; d="$led/$id"
  [ -n "$ALLOC_CREATED_DIR" ] && [ -n "$id" ] && [ "$ALLOC_CREATED_DIR" = "$d" ] \\
    || die "dispatch-alloc: refusing to stamp ${d:-<unknown>} — this process did not create it"''',
'''  id=$(alloc_id "$led") || die "id allocation failed"
  d="$led/$id"''')
EOF

# B1 — delete the root-disagreement alert.
M M_B1 cross-root-guard-proof.sh <<'EOF'
edit('bin/fleet', '{ root_disagreement_alert "$r"; echo "$r"; return 0; }',
                  '{ echo "$r"; return 0; }')
EOF

# B2 — delete the reorient cut: always emit the absolute $FLEET_DIR path.
M M_B2 cross-root-guard-proof.sh <<'EOF'
edit('bin/fleet', '''  case "$FLEET_DIR/" in
    "${_gp_root:-/nonexistent}"/*) ;;
    "${HOME:-/nonexistent}"/*)     ;;
    *) _manual="FLEET_SUBORCH.md" ;;
  esac
''', '')
EOF

# B3 — delete the harness root tripwire call.
M M_B3 cross-root-guard-proof.sh <<'EOF'
edit('test/hidden-proof-common.sh', '\n  proof_root_tripwire\n', '\n')
EOF

# B4 — restore the resolver's `d[0-9]*` glob with no shape check at all.
M M_B4 cross-root-guard-proof.sh <<'EOF'
edit('bin/fleet', '''    case "$want" in
      */*|*..*) die "fleet gate: invalid dispatch target '$want'" ;;
    esac
    if valid_dispatch_id "$want"; then''',
'''    if case "$want" in d[0-9]*) true ;; *) false ;; esac; then''')
EOF

printf '\nred evidence written to %s\n' "$OUT"

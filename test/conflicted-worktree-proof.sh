#!/usr/bin/env bash
# conflicted-worktree-proof — the 2026-07-30 outage is structurally gone.
#
# THE LOAD-BEARING PROOF (PROOF DESIGN §1). It reproduces the incident in a
# sandbox: a conflicted `fleet/main` worktree, whose files WERE the installed
# binaries, took every agent on the machine down — `fleet` died with
# `syntax error near unexpected token '<<<'`, and `fleet-guard`, which runs
# before EVERY tool call, was conflicted too.
#
# Four variants of "the worktree is broken", because one is not enough:
#   1. the literal incident — a real `git merge` conflict, MERGE_HEAD set, UU files
#   2. markers with NO merge in progress — the grep must work on its own
#   3. markers INSIDE bin/fleet-guard's embedded python heredoc — the file still
#      parses as shell, so this is the class a `bash -n`-only gate lets through
#   4. marker-free BROKEN PYTHON in that same heredoc — nothing but a real smoke
#      invocation can catch this one
#
# And then the half that proves we did not cheat by simply freezing the release:
# resolve the conflict and assert the very next invocation — with NO human
# promote step — is running the new bytes. A design that passed the first half
# and failed that one is the explicit-promote design that was rejected.
set -u
. "$(dirname "$0")/hidden-proof-common.sh"
proof_isolate

REL="$TMPROOT/rel"
SRC="$TMPROOT/src"
BIN="$TMPROOT/localbin"          # stands in for ~/.local/bin
mkdir -p "$SRC" "$BIN"
tar -C "$FLEET_REPO" --exclude=.git --exclude=node_modules -cf - . 2>/dev/null \
  | tar -C "$SRC" -xf - 2>/dev/null

export FLEET_RELEASE_DIR="$REL"
# NOTE: FLEET_SOURCE is deliberately NOT exported. The hot-path binaries must
# find their source through the release's own `source` pointer, exactly as they
# will in the real install — an env var would let the proof cheat.

# A real git repo, so variant 1 can be an honest `git merge` conflict.
git -C "$SRC" init -q 2>/dev/null
git -C "$SRC" config user.email proof@example.com
git -C "$SRC" config user.name proof
git -C "$SRC" add -A 2>/dev/null
git -C "$SRC" commit -qm base 2>/dev/null

GOOD_FLEET=$(cat "$SRC/bin/fleet")
GOOD_GUARD=$(cat "$SRC/bin/fleet-guard")

restore_source() {                       # back to a valid, merge-free worktree
  git -C "$SRC" merge --abort 2>/dev/null
  git -C "$SRC" checkout -q -- . 2>/dev/null
  printf '%s\n' "$GOOD_FLEET"  > "$SRC/bin/fleet"
  printf '%s\n' "$GOOD_GUARD"  > "$SRC/bin/fleet-guard"
  chmod +x "$SRC/bin/fleet" "$SRC/bin/fleet-guard"
}

# Install exactly like install.sh does: four symlinks at current/bin/*.
"$SRC/bin/fleet" promote >/dev/null 2>&1 || { echo "setup: initial promote failed" >&2; exit 1; }
for b in fleet fleetd fleet-hook fleet-guard; do ln -sfnT "$REL/current/bin/$b" "$BIN/$b"; done

# Fingerprint of everything currently published. If ANY variant promotes bad
# bytes, this changes — proving nothing bad shipped, not merely that we survived.
snap() { (cd "$REL/current" 2>/dev/null && find . -type f -print0 \
          | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null) | sha256sum; }

guard_payload='{"tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"/tmp"}'
# A worker `git push` MUST be denied. This is the payload that distinguishes a
# working guard from a dead one, since a dead one exits 0 either way.
push_payload='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

# ---- one variant's worth of assertions ---------------------------------------
assert_survives() { # assert_survives <label> <expected-drift-file> <expected-check>
  local label="$1" wantfile="$2" wantcheck="$3" out rc

  out=$("$BIN/fleet" ls 2>/dev/null); rc=$?
  chk "[$label] fleet ls exits 0 (the original symptom, negated)" 0 "$rc"

  out=$(printf '%s' "$guard_payload" | "$BIN/fleet-guard" 2>/dev/null); rc=$?
  chk "[$label] fleet-guard exits 0 on the hot path" 0 "$rc"
  # An allow is silence; a deny is a JSON object. Either is well-formed, a shell
  # error message is not.
  if [ -z "$out" ] || printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "[$label] fleet-guard emitted a well-formed response (no protocol noise)"
  else
    no "[$label] fleet-guard emitted a well-formed response (got: $(printf '%s' "$out" | head -1))"
  fi

  "$BIN/fleet-hook" working >/dev/null 2>&1; chk "[$label] fleet-hook working exits 0" 0 "$?"
  "$BIN/fleet-hook" idle    >/dev/null 2>&1; chk "[$label] fleet-hook idle exits 0" 0 "$?"

  chk "[$label] NOTHING was promoted (release bytes unchanged)" "$BASE_SNAP" "$(snap)"

  if [ -f "$REL/drift" ]; then
    ok "[$label] a drift marker was written"
    grep -q "$wantfile" "$REL/drift" \
      && ok "[$label] drift marker names the offending file ($wantfile)" \
      || no "[$label] drift marker names the offending file ($wantfile); got: $(tr '\n' ' ' < "$REL/drift")"
    grep -q "check: *$wantcheck" "$REL/drift" \
      && ok "[$label] drift marker names the failing check ($wantcheck)" \
      || no "[$label] drift marker names the failing check ($wantcheck); got: $(grep check: "$REL/drift")"
  else
    no "[$label] a drift marker was written"
    no "[$label] drift marker names the offending file ($wantfile)"
    no "[$label] drift marker names the failing check ($wantcheck)"
  fi

  out=$("$BIN/fleet" doctor 2>&1); rc=$?
  [ "$rc" -le 1 ] && ok "[$label] fleet doctor stays fail-silent (rc=$rc)" \
                  || no "[$label] fleet doctor stays fail-silent (rc=$rc)"
  printf '%s\n' "$out" | grep -q 'release is BEHIND' \
    && ok "[$label] doctor reports the release is behind" \
    || no "[$label] doctor reports the release is behind"
  printf '%s\n' "$out" | grep -q 'promote was REFUSED' \
    && ok "[$label] doctor shows the gate rejection detail" \
    || no "[$label] doctor shows the gate rejection detail"

  # EXACTLY one stderr line per `fleet` call: zero and the human debugs a phantom
  # "my edit didn't work"; several and they learn to ignore it.
  local errs
  errs=$("$BIN/fleet" ls 2>&1 >/dev/null | grep -c 'BEHIND' || true)
  chk "[$label] fleet prints exactly ONE stderr drift line" 1 "$errs"
  errs=$(printf '%s' "$guard_payload" | "$BIN/fleet-guard" 2>&1 >/dev/null | wc -c)
  chk "[$label] fleet-guard stays completely silent (hook protocol)" 0 "$errs"
  errs=$("$BIN/fleet-hook" idle 2>&1 >/dev/null | wc -c)
  chk "[$label] fleet-hook stays completely silent" 0 "$errs"
}

reset_release() {
  restore_source
  rm -f "$REL/drift"
  "$SRC/bin/fleet" promote >/dev/null 2>&1
  BASE_SNAP=$(snap)
}

MARK_A='<<<<<<< HEAD'
MARK_B='======='
MARK_C='>>>>>>> other'

section "variant 1 — the literal incident (real git merge conflict, MERGE_HEAD set)"
reset_release
git -C "$SRC" checkout -q -b other 2>/dev/null
printf '\n# other-branch line\necho other >/dev/null\n' >> "$SRC/bin/fleet"
git -C "$SRC" commit -qam other 2>/dev/null
git -C "$SRC" checkout -q master 2>/dev/null || git -C "$SRC" checkout -q main 2>/dev/null
printf '\n# main-branch line\necho main >/dev/null\n' >> "$SRC/bin/fleet"
git -C "$SRC" commit -qam mainline 2>/dev/null
git -C "$SRC" merge other >/dev/null 2>&1
gd=$(git -C "$SRC" rev-parse --absolute-git-dir 2>/dev/null)
[ -e "$gd/MERGE_HEAD" ] && ok "[v1] fixture: MERGE_HEAD really is set" || no "[v1] fixture: MERGE_HEAD really is set"
grep -q '^<<<<<<< ' "$SRC/bin/fleet" && ok "[v1] fixture: bin/fleet really has conflict markers" \
                                     || no "[v1] fixture: bin/fleet really has conflict markers"
bash -n "$SRC/bin/fleet" 2>/dev/null && no "[v1] fixture: the conflicted bin/fleet is really broken" \
                                     || ok "[v1] fixture: the conflicted bin/fleet is really broken"
assert_survives v1 worktree git-in-progress

section "variant 2 — markers, no merge in progress"
reset_release
{ printf '%s\n' "$MARK_A"; printf 'x=1\n'; printf '%s\n' "$MARK_B"; printf 'x=2\n'; printf '%s\n' "$MARK_C"; } >> "$SRC/bin/fleet"
gd=$(git -C "$SRC" rev-parse --absolute-git-dir 2>/dev/null)
[ -e "$gd/MERGE_HEAD" ] && no "[v2] fixture: NO merge in progress" || ok "[v2] fixture: NO merge in progress"
assert_survives v2 bin/fleet conflict-marker

section "variant 3 — markers inside fleet-guard's python heredoc (parses as shell)"
reset_release
python3 - "$SRC/bin/fleet-guard" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# Inject INTO the embedded python program, not into the shell around it.
needle = "import json, os, fnmatch, sys, re, shlex"
assert needle in s, "guard fixture anchor moved"
s = s.replace(needle, "<<<<<<< HEAD\n" + needle + "\n=======\n" + needle + "\n>>>>>>> other", 1)
open(p, "w").write(s)
PY
sh -n "$SRC/bin/fleet-guard" 2>/dev/null \
  && ok "[v3] fixture: the conflicted guard STILL PARSES as shell (this is the trap)" \
  || no "[v3] fixture: the conflicted guard STILL PARSES as shell (this is the trap)"
# How a broken guard actually fails is the whole point: its python ends in
# `|| exit 0`, so it still EXITS 0 — while silently allowing everything it is
# meant to deny. Exit codes cannot see this; behaviour can.
if [ -z "$(printf '%s' "$push_payload" | FLEET_ROLE=worker FLEET_NO_PROMOTE=1 \
           sh "$SRC/bin/fleet-guard" 2>/dev/null)" ]; then
  ok "[v3] fixture: the conflicted guard silently STOPS DENYING (exit code still 0)"
else
  no "[v3] fixture: the conflicted guard silently STOPS DENYING (exit code still 0)"
fi
assert_survives v3 bin/fleet-guard conflict-marker

section "variant 4 — marker-free broken python in the guard (no shell parser sees it)"
reset_release
python3 - "$SRC/bin/fleet-guard" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
needle = "import json, os, fnmatch, sys, re, shlex"
assert needle in s, "guard fixture anchor moved"
s = s.replace(needle, needle + "\nif True\n    pass", 1)     # SyntaxError, no markers
open(p, "w").write(s)
PY
grep -q '^<<<<<<< ' "$SRC/bin/fleet-guard" && no "[v4] fixture: no conflict markers present" \
                                           || ok "[v4] fixture: no conflict markers present"
sh -n "$SRC/bin/fleet-guard" 2>/dev/null \
  && ok "[v4] fixture: still parses as shell (bash -n / sh -n say it is fine)" \
  || no "[v4] fixture: still parses as shell (bash -n / sh -n say it is fine)"
assert_survives v4 bin/fleet-guard embedded-python

section "variant 5 — VALID python that silently stops denying (only the smoke run catches it)"
# The nastiest shape, and the reason the smoke check is behavioural rather than
# exit-code-based: syntactically perfect, parses everywhere, exits 0 — and the
# always-on worker merge/push floor is simply gone. A stale guard that ALLOWS is
# worse than an outage, because it is silent.
reset_release
python3 - "$SRC/bin/fleet-guard" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
needle = 'role = os.environ.get("FLEET_ROLE", "")'
assert needle in s, "guard fixture anchor moved"
open(p, "w").write(s.replace(needle, 'role = ""', 1))
PY
sh -n "$SRC/bin/fleet-guard" 2>/dev/null \
  && ok "[v5] fixture: parses as shell" || no "[v5] fixture: parses as shell"
if printf '%s' "$push_payload" | FLEET_ROLE=worker FLEET_NO_PROMOTE=1 \
     sh "$SRC/bin/fleet-guard" >/dev/null 2>&1; then
  ok "[v5] fixture: exits 0 — indistinguishable from healthy, except in behaviour"
else
  no "[v5] fixture: exits 0"
fi
if [ -z "$(printf '%s' "$push_payload" | FLEET_ROLE=worker FLEET_NO_PROMOTE=1 \
           sh "$SRC/bin/fleet-guard" 2>/dev/null)" ]; then
  ok "[v5] fixture: the sabotaged guard really does stop denying a worker push"
else
  no "[v5] fixture: the sabotaged guard really does stop denying a worker push"
fi
assert_survives v5 bin/fleet-guard smoke

section "the other half — resolving the conflict goes live with NO promote step"

restore_source
# One deliberate, observable change to each hot-path binary, so "the release
# matches the worktree" cannot pass by accident.
printf '\n# resolved-marker-%s\n' "$$" >> "$SRC/bin/fleet"
printf '\n# resolved-marker-%s\n' "$$" >> "$SRC/bin/fleet-guard"
gd=$(git -C "$SRC" rev-parse --absolute-git-dir 2>/dev/null)
[ -e "$gd/MERGE_HEAD" ] && no "fixture: the merge is resolved" || ok "fixture: the merge is resolved"

before=$(snap)
"$BIN/fleet" ls >/dev/null 2>&1
chk "fleet ls exits 0 after the fix" 0 "$?"
chk_ne "the release CHANGED with no human promote step" "$before" "$(snap)"
chk "released bin/fleet == worktree bin/fleet" \
    "$(sha256sum < "$SRC/bin/fleet")" "$(sha256sum < "$REL/current/bin/fleet")"
[ -f "$REL/drift" ] && no "the drift marker was cleared by the good promote" \
                    || ok "the drift marker was cleared by the good promote"

# ...and the same, driven ONLY by the hot path — the guard's own prologue must
# publish an edit to the guard, or `fleet-guard` alone would run stale forever.
reset_release
printf '\n# guard-hotpath-marker-%s\n' "$$" >> "$SRC/bin/fleet-guard"
before=$(snap)
printf '%s' "$guard_payload" | "$BIN/fleet-guard" >/dev/null 2>&1
chk "fleet-guard exits 0 while promoting" 0 "$?"
chk_ne "fleet-guard's own prologue promoted the edit" "$before" "$(snap)"
chk "released fleet-guard == worktree fleet-guard" \
    "$(sha256sum < "$SRC/bin/fleet-guard")" "$(sha256sum < "$REL/current/bin/fleet-guard")"

# The steady state must NOT keep promoting: nothing to do = nothing written.
steady=$(snap)
for i in 1 2 3 4 5; do printf '%s' "$guard_payload" | "$BIN/fleet-guard" >/dev/null 2>&1; done
"$BIN/fleet" ls >/dev/null 2>&1
chk "steady state promotes nothing (5 guard calls + 1 fleet call)" "$steady" "$(snap)"

section "the one-hop marker is CONSUMED, never inherited by descendants"

# FLEET_PROMOTED bounds the re-exec to one hop, and it is passed through `exec`,
# i.e. in the ENVIRONMENT. If it were merely tested rather than consumed, every
# descendant would inherit it — and `fleet up` starts the tmux SERVER, so a
# single `fleet up` after an edit would stamp it on every agent pane for the
# whole session, silently disabling the guard/hook prologues fleet-wide. The
# design's core promise would stop holding with no symptom but stale code.
mkdir -p "$TMPROOT/envbin"
printf '#!/bin/sh\nprintf "%%s\\n" "${FLEET_PROMOTED:-<unset>}" >> %s/seen.txt\nexit 0\n' \
  "$TMPROOT" > "$TMPROOT/envbin/git"
chmod +x "$TMPROOT/envbin/git"
reset_release
touch "$SRC/bin/fleet"                       # force the promote + re-exec path
: > "$TMPROOT/seen.txt"
PATH="$TMPROOT/envbin:$PATH" "$BIN/fleet" doctor >/dev/null 2>&1 || true
seen=$(sort -u "$TMPROOT/seen.txt" 2>/dev/null | tr '\n' ' ')
[ -s "$TMPROOT/seen.txt" ] && ok "the env probe actually ran (children were spawned)" \
                           || no "the env probe actually ran (children were spawned)"
chk "no descendant of the re-exec'd fleet inherits FLEET_PROMOTED" "<unset> " "$seen"

section "a worktree copy run DIRECTLY is never hijacked into the release"

# Running ./bin/fleet-guard by hand — or from another proof — must exercise THAT
# file. If the prologue re-exec'd into the release whenever one was stale, every
# other proof in test/ would silently be testing the wrong bytes.
reset_release
printf '\n# direct-run-marker-%s\n' "$$" >> "$SRC/bin/fleet-guard"
before=$(snap)
printf '%s' "$guard_payload" | "$SRC/bin/fleet-guard" >/dev/null 2>&1
chk "the worktree guard still exits 0" 0 "$?"
chk "running the worktree copy promotes NOTHING" "$before" "$(snap)"
printf '%s' "$guard_payload" | "$SRC/bin/fleet-hook" idle >/dev/null 2>&1 || true
chk "running the worktree hook promotes NOTHING" "$before" "$(snap)"
"$SRC/bin/fleet" ls >/dev/null 2>&1
chk "running the worktree fleet promotes NOTHING" "$before" "$(snap)"

proof_summary

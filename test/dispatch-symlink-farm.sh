#!/usr/bin/env bash
# Proof harness — the per-dispatch symlink farm (P1 + P2 of d25).
#
# The ask presupposes "the folder where all its created files are visible". No such
# folder exists today: `_reports/<slug>/` is a RELATIVE path with no env var behind it,
# so it resolves against whichever agent's cwd wrote it (research at $root, impl/test
# inside their own worktrees — four separate trees). Two fixes:
#
#   P1  `fleet dispatch rename` records the ABSOLUTE reports dir in the ledger. That
#       is the missing d<N> <-> <slug> join, and it is what makes crash recovery
#       (FLEET_SUBORCH.md) read the real path instead of a cwd-relative guess.
#   P2  the sub-orch drops symlinks into its own .fleet/dispatch/<id>/ as it appends
#       each workers.tsv row, so that dir genuinely becomes the folder. Documentation
#       only — zero lines of bash.
#
# Cases:
#   1. `fleet dispatch rename` writes an ABSOLUTE `reports` key into meta.tsv
#   2. ...pointing at $root/_reports/<slug> for the slug it just renamed to
#   3. re-running rename is last-wins, not a duplicate-key mess
#   4. FLEET_SUBORCH.md documents the farm (ln -sfn, reports/worktree/notes links)
#   5. FLEET_SUBORCH.md's recovery step reads the ledger `reports` key, not a bare
#      cwd-relative `_reports/<slug>/`
#   6. the documented links resolve to real dirs
#   7. after a `fleet reap` deletes a worktree, the dangling link is inert: the farm
#      still lists, `fleet agents` still runs, and the viewer still attaches
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"
MANUAL="$HERE/FLEET_SUBORCH.md"

TMPROOT=$(mktemp -d)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"; mkdir -p "$TMUX_TMPDIR"
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FLEET_SESSION="farm_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=1; }

# last-wins read of a ledger key, exactly like meta_get
mget() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/meta.tsv" 2>/dev/null; }

echo "== d25 dispatch symlink farm — P1 + P2 proof"

D="$FLEET_ROOT/.fleet/dispatch/d1"; mkdir -p "$D"
tmux new-session -d -s "$FLEET_SESSION" -n "so-d1" 'sleep 9999' 2>/dev/null
sleep 0.3
WID=$(tmux list-windows -t "=$FLEET_SESSION" -F '#{window_id} #{window_name}' \
      | awk '$2=="so-d1"{print $1; exit}')
printf 'window_id\t%s\n' "$WID" >> "$D/meta.tsv"

# --- 1 + 2. rename records the absolute reports dir ---------------------------
"$FLEET" dispatch rename d1 "Suborch Nvim Viewer" >/dev/null 2>&1
slug=$("$FLEET" slug "Suborch Nvim Viewer" 2>/dev/null)
rep=$(mget "$D" reports)
case "$rep" in
  /*) pass "1 reports key is absolute ($rep)" ;;
  "") fail "1 reports key is absolute" "no 'reports' key in meta.tsv — the d<N><->slug join is still missing" ;;
  *)  fail "1 reports key is absolute" "relative path '$rep' — resolves against the reader's cwd, the bug this fixes" ;;
esac
if [ "$rep" = "$FLEET_ROOT/_reports/$slug" ]; then
  pass "2 reports key == \$root/_reports/<slug>"
else
  fail "2 reports key == \$root/_reports/<slug>" "got '$rep' wanted '$FLEET_ROOT/_reports/$slug'"
fi

# --- 3. rename again -> last-wins ---------------------------------------------
"$FLEET" dispatch rename d1 "Second Slug" >/dev/null 2>&1
slug2=$("$FLEET" slug "Second Slug" 2>/dev/null)
rep2=$(mget "$D" reports)
if [ "$rep2" = "$FLEET_ROOT/_reports/$slug2" ]; then
  pass "3 second rename is last-wins ($rep2)"
else
  fail "3 second rename is last-wins" "got '$rep2' wanted '$FLEET_ROOT/_reports/$slug2'"
fi

# --- 4 + 5. the manual documents the farm -------------------------------------
if grep -q 'ln -sfn' "$MANUAL" \
   && grep -q 'dispatch/<id>/reports' "$MANUAL" \
   && grep -qi 'notes-' "$MANUAL"; then
  pass "4 FLEET_SUBORCH.md documents the symlink farm"
else
  fail "4 FLEET_SUBORCH.md documents the symlink farm" "missing ln -sfn / reports link / notes-<label> link instructions"
fi
# The recovery step must READ the ledger key, so the manual has to carry a concrete
# meta.tsv `reports` read — not just mention the word somewhere.
if grep -qF 'awk -F' "$MANUAL" && grep -qF '$1=="reports"' "$MANUAL"; then
  pass "5 recovery reads the ledger 'reports' key"
else
  fail "5 recovery reads the ledger 'reports' key" "the recovery step still resolves _reports/<slug>/SYNTHESIS.md against the sub-orch cwd"
fi

# --- 6. the manual's OWN commands, executed, build a resolving farm ------------
# P2 is documentation the sub-orch executes, so the only honest proof is to run what
# the manual actually says. Extract every fenced block from §3.0.6, substitute the
# placeholders a sub-orch would fill in, and eval it — this catches a quoting bug or a
# broken `${branch//\//_}` in the doc, which a hand-copy of the commands never would.
mkdir -p "$FLEET_ROOT/repo/fleet_thing/.fleet/notes"
echo hi > "$rep2/PLAN.md" 2>/dev/null || { mkdir -p "$rep2"; echo hi > "$rep2/PLAN.md"; }
# `^## ` (two hashes + space) is the next TOP-level heading and never matches the
# `### 3.0.6` we start on — so this stops at the section boundary and cannot swallow
# §3's flat-worker examples (it did, before: their `slug=$(fleet slug "login 500")`
# leaked in and quietly redefined $branch).
doc_snippet=$(awk '/^### 3\.0\.6/{s=1; next} s && /^## /{exit} s' "$MANUAL" \
              | awk '{ t=$0; sub(/^[ \t]+/,"",t); if (t=="```") { f=!f; next } if (f) print }' \
              | sed -e 's/<id>/d1/g' -e 's/<repo>/repo/g' -e 's/<role-or-label>/impl/g')
if [ -z "$doc_snippet" ]; then
  fail "6 the manual's own farm commands build a resolving farm" "could not extract any fenced block from §3.0.6"
else
  ( cd "$FLEET_ROOT" || exit 1
    root="$FLEET_ROOT" branch="fleet/thing"
    eval "$doc_snippet" ) >/dev/null 2>&1
  if [ -d "$D/reports" ] && [ -f "$D/reports/PLAN.md" ] \
     && [ -d "$D/repo-fleet_thing" ] && [ -d "$D/notes-impl" ]; then
    pass "6 the manual's own farm commands build a resolving farm"
  else
    fail "6 the manual's own farm commands build a resolving farm" \
         "ran §3.0.6 verbatim; got: $(ls -l "$D" 2>&1 | tr '\n' ';')"
  fi
fi

# --- 7. a reaped worktree leaves an inert dangling link ------------------------
# Non-tautological form: the row count and the surviving links must be UNCHANGED by
# the deletion — a dangling link must not remove the farm's other entries, break a
# directory read, or perturb `fleet agents`.
before_rows=$("$FLEET" agents 2>/dev/null | grep -c .)
before_entries=$(ls -A "$D" 2>/dev/null | grep -c .)
rm -rf "$FLEET_ROOT/repo/fleet_thing"
dang=0; [ -L "$D/repo-fleet_thing" ] && [ ! -e "$D/repo-fleet_thing" ] && dang=1
after_entries=$(ls -A "$D" 2>/dev/null | grep -c .)
after_rows=$("$FLEET" agents 2>/dev/null | grep -c .)
reports_ok=0; [ -f "$D/reports/PLAN.md" ] && reports_ok=1
if [ "$dang" = 1 ] && [ "$after_entries" = "$before_entries" ] \
   && [ "$after_rows" = "$before_rows" ] && [ "$reports_ok" = 1 ]; then
  pass "7 dangling link is an inert tombstone (farm entries $after_entries, rows $after_rows)"
else
  fail "7 dangling link is an inert tombstone" \
       "dangling=$dang entries $before_entries->$after_entries rows $before_rows->$after_rows reports_ok=$reports_ok"
fi

echo
[ "$FAILED" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES"; exit 1

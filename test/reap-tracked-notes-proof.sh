#!/usr/bin/env bash
# Proof harness — `fleet reap` must be ATOMIC: a refused reap must leave the
# worktree, its window, its saved-agents line and its `.fleet/ready` marker ALL
# intact, and must never dirty the tree by its own hand.
#
# The bug (see _reports/reap-tracked-notes/SYNTHESIS.md): cmd_reap kills the
# window, forgets the agent, `mv`s .fleet/notes into the archive and deletes the
# ready marker BEFORE the step that can fail (`git worktree remove`). When that
# step refuses, the worktree is orphaned — no longer selectable by `fleet reap`
# under ANY flag, because the selector (`.fleet/ready`) and the iteration source
# (the agents line) were both destroyed by the failed attempt. Worse, for TRACKED
# notes the `mv` is itself what makes removal refuse: reap dirties the tree and
# then refuses because the tree is dirty.
#
# Isolation: a THROWAWAY tmux server (TMUX_TMPDIR) + private config
# (XDG_CONFIG_HOME) + temp repos under one mktemp dir. The live `pc` session, the
# orchestrator pane and every real worktree are unreachable from here.
#
# TWO mkrepo variants, deliberately:
#   mkrepo … 1  — WITH `/.fleet/` in the repo's COMMON .git/info/exclude. This is
#                 PRODUCTION fidelity: `cmd_new` writes that line for every
#                 worktree it creates, so `.fleet/` is IGNORED, never `??` in
#                 porcelain, and `git worktree remove` deletes it happily.
#   mkrepo … 0  — WITHOUT the exclude line. This is the LATE-FAILURE fixture: the
#                 only shape where an untracked `.fleet/` member makes plain
#                 `worktree remove` genuinely refuse WITH THE POST-STATE FULLY
#                 INTACT (dir present, still registered) — exactly what
#                 assert_intact needs. It also covers "an exclude-less worktree
#                 must still reap" (T11).
# The `chmod a-w` fixture is REJECTED PERMANENTLY: `worktree remove` deletes the
# contents and unregisters the worktree BEFORE failing on the final rmdir, so the
# "failure" is a successful destruction with rc!=0 — every assert_intact
# sub-assertion is already false, and it breaks `rm -rf "$TMPROOT"` in cleanup().
#
# RED TALLY — on current `main` (pre-fix) this harness is 11 RED / 8 GREEN.
# Without the tally the first run reads as a broken harness.
#   RED:   T1, T3, T4b, T8, T12, A1a, A1b, A2, A3, A4, A5
#   GREEN: T2, T4a, T5, T6, T7, T9, T10, T11
# T4a is ALREADY green (guard 5 fires pre-mutation for a change outside
# `.fleet/`); only T4b is red. T12 exercises the new worktree-LOCK DECIDE guard.
# (SYNTHESIS §3 predicted T6 red "by intent"; measured, T6 is green on current
# main — the pre-fix `mv` does archive tracked notes under --force, and
# `worktree remove --force` tolerates the dirt it creates. Tally size unchanged:
# T12 is red in its place.)
# Post-fix: every case must PASS.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

# --- isolation: private tmux server + private config, never the real ones ------
TMPROOT=$(mktemp -d)
# Socket isolation is INTRINSIC, never inherited. Ambient `export TMUX_TMPDIR` is
# NOT enough on its own: any step running in a shell that did not inherit it falls
# back to /tmp/tmux-$(id -u)/default — the REAL server — and then a bare
# `tmux kill-server` in cleanup() tears down the live fleet. (That happened: the
# real server went down and pc/techweb2 had to be recreated.) So resolve the socket
# HERE, assert it lives under TMPROOT, and inject it with -S on every tmux call via
# the wrapper below. TMUX_TMPDIR is still exported, but only so CHILD processes
# ($FLEET -> tmux) reach the SAME private server; correctness no longer rests on it.
export TMUX_TMPDIR="$TMPROOT/tmuxsock"
mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
# FLEET_HARNESS_SOCK exists ONLY so the guard below can be proven to fire; it is
# itself guarded, so it can never be used to escape to the real socket.
SOCK="${FLEET_HARNESS_SOCK:-$TMUX_TMPDIR/tmux-$(id -u)/default}"

# --- fail-fast guard: runs BEFORE any tmux call -------------------------------
if [ "$SOCK" = "/tmp/tmux-$(id -u)/default" ]; then
  echo "REFUSE: harness resolved to the real tmux socket ($SOCK)" >&2
  rm -rf "$TMPROOT"; exit 1
fi
case "$SOCK" in
  "$TMPROOT"/*) ;;
  *) echo "REFUSE: harness socket is not under TMPROOT ($SOCK not under $TMPROOT)" >&2
     rm -rf "$TMPROOT"; exit 1 ;;
esac

# Every tmux call in THIS FILE routes through here — defined in the same file as the
# calls, so -S can be neither forgotten nor lost across a subshell. `command tmux`
# avoids recursing into this function.
tmux() { command tmux -S "$SOCK" "$@"; }
export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
unset TMUX  # we must not look like we're already inside a session
# The developer's git identity/hooks/templates must not leak into the fixtures.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# cmd_reap ends in `fuser -k ${FLEET_DEBUG_PORT:-9222}/tcp`. Unset, that kills the
# developer's Chromium remote-debug session. Point it at a port nothing uses.
export FLEET_DEBUG_PORT=59222

# kill-server is EXPLICITLY socket-scoped, not just wrapper-scoped: this is the one
# call that destroys a whole server, so it states its target literally.
cleanup() { command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

# pass/fail run INSIDE each per-case subshell and exit it with the right code, so
# the parent can aggregate via the subshell return codes.
pass() { echo "  PASS($1)"; exit 0; }
fail() { echo "  FAIL($1): $2"; exit 1; }

# --- fixtures -----------------------------------------------------------------

commit_in() { # <dir> <msg>  — commit everything staged, with an explicit identity
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m "$2"
}

# Build a project root with a repo + a linked worktree on <branch> (cut from
# main), flag it ready, record it in <sess>'s saved-agents file. <excl>=1 appends
# `/.fleet/` to the COMMON info/exclude exactly as cmd_new does. Echoes the dir.
mkrepo() { # <root> <sess> <branch> <excl>
  local root="$1" sess="$2" br="$3" excl="$4"
  mkdir -p "$root"
  git init -q "$root/repo"
  git -C "$root/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$root/repo" branch -M main 2>/dev/null
  local wt="$root/repo/${br//\//_}"
  git -C "$root/repo" worktree add -q -b "$br" "$wt" main 2>/dev/null
  [ "$excl" = 1 ] && printf '/.fleet/\n' >> "$root/repo/.git/info/exclude"
  mkdir -p "$wt/.fleet"; : > "$wt/.fleet/ready"
  # saved-agents fields: dir <TAB> repo <TAB> branch <TAB> bare <TAB> base <TAB> harness
  printf '%s\trepo\t%s\t\tmain\tclaude\n' "$wt" "$br" \
    >> "$XDG_CONFIG_HOME/fleet/sessions/$sess.agents"
  printf '%s' "$wt"
}

# Create scratch docs in <wt>. <mode>: tracked | untracked | mixed | empty.
# `tracked` commits them on the branch AND fast-forwards main onto it, so guard 6
# (branch merged into base) passes — the reproduced live shape.
mknotes() { # <wt> <mode>
  local wt="$1"; local mode="$2"; local nd="$wt/.fleet/notes"; local rp; rp=$(dirname "$wt")
  mkdir -p "$nd"
  case "$mode" in
    empty) return 0 ;;
    tracked|mixed)
      printf 'plan A\n' > "$nd/plan.md"; printf 'research B\n' > "$nd/research.md"
      git -C "$wt" add -f .fleet/notes/plan.md .fleet/notes/research.md
      commit_in "$wt" "notes"
      git -C "$rp" -c user.email=t@t -c user.name=t merge -q --ff-only \
        "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" 2>/dev/null
      ;;
  esac
  case "$mode" in
    untracked|mixed)
      printf 'scratch C\n' > "$nd/scratch.md"; printf 'notes D\n' > "$nd/extra.md"
      ;;
  esac
}

# Boot a fake command center, mirroring cmd_up. Echoes "<window_id> <pane_id>".
boot() { # <sess> <root> <cwd> [name]
  local sess="$1" root="$2" cwd="$3" name="${4:-main}"
  tmux new-session -d -s "$sess" -n "$name" -c "$cwd" sh 2>/dev/null
  local win pane
  win=$(tmux list-windows -t "=$sess" -F '#{window_id}' 2>/dev/null | head -1)
  pane=$(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null | head -1)
  tmux set -t "$sess" @fleet_root "$root" 2>/dev/null
  tmux set -w -t "$win" @fleet_role main 2>/dev/null
  tmux set -w -t "$win" @fleet_ccenter 1 2>/dev/null      # harness-owned survival marker
  tmux set -w -t "$win" automatic-rename off 2>/dev/null
  mkdir -p "$root/.fleet/roles"
  printf 'main\n' > "$root/.fleet/roles/$pane"
  printf '%s %s' "$win" "$pane"
}

# Add a plain (non-main) window at <cwd>; echoes its window_id (M5: callers MUST
# capture it — it is the thing assert_intact proves survived).
addwin() { # <sess> <name> <cwd>
  tmux new-window -P -F '#{window_id}' -t "=$1" -n "$2" -c "$3" sh 2>/dev/null
}

reap() { FLEET_SESSION="$1" "$FLEET" reap "${@:2}" 2>&1; }

wt_exists() { [ -d "$1" ]; }
win_exists() { tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -qx "$1"; }
agents_line() { grep -qF "$1" "$XDG_CONFIG_HOME/fleet/sessions/$2.agents" 2>/dev/null; }
arch_of() { ls -d "$1/.fleet/notes/archive/repo__${2//\//_}__"* 2>/dev/null | head -1; }
porcelain() { git -C "$1" status --porcelain 2>/dev/null; }

assert_center_alive() { # <case> <sess>
  local c="$1" s="$2"
  tmux has-session -t "=$s" 2>/dev/null \
    || fail "$c" "session '$s' was destroyed"
  tmux list-windows -t "=$s" -F '#{@fleet_ccenter}' 2>/dev/null | grep -qx 1 \
    || fail "$c" "command-center window was killed"
  return 0
}

# THE atomicity assertion. All five at once. Each miss calls fail(), which exits
# the subshell — so a plain `return 0` on success is what makes `&& pass` safe
# (M4: without the explicit return, a falsy last test silently swallows the case).
assert_intact() { # <case> <wt> <sess> <win>
  local c="$1" wt="$2" s="$3" w="$4"
  wt_exists "$wt"                  || fail "$c" "worktree dir was removed by a REFUSED reap"
  [ -e "$wt/.fleet/ready" ]        || fail "$c" "ready marker deleted — worktree is now unreapable by any flag"
  [ -d "$wt/.fleet/notes" ]        || fail "$c" "scratch-docs dir gone from a refused reap"
  [ -n "$(ls -A "$wt/.fleet/notes" 2>/dev/null)" ] \
                                   || fail "$c" "scratch-docs dir emptied by a refused reap"
  win_exists "$w"                  || fail "$c" "worker window killed before the removal succeeded"
  agents_line "$wt" "$s"           || fail "$c" "saved-agents line dropped before the removal succeeded"
  return 0
}

echo "== reap-tracked-notes-proof: a refused reap must orphan NOTHING =="

# --- T1: tracked notes -> plain reap SUCCEEDS ---------------------------------
# The reproduced live failure: notes committed on the branch, merged, tree clean.
# Pre-fix the `mv` deletes tracked files, the tree goes dirty, removal refuses.
( c=T1; s=rt1; r="$TMPROOT/T1"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" tracked
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  printf '%s' "$out" | grep -q 'reaped repo/feat' || fail "$c" "plain reap did not report success: $out"
  wt_exists "$wt" && fail "$c" "worktree not removed"
  git -C "$r/repo" branch --list feat | grep -q . && fail "$c" "branch not deleted"
  # The archive must be COMPLETE (S1: copy, not move) — or at minimum the content
  # is still reachable from main. Assert the union, then insist on the archive.
  a=$(arch_of "$r" feat)
  if [ -n "$a" ] && [ -f "$a/plan.md" ]; then :
  elif git -C "$r/repo" show main:.fleet/notes/plan.md >/dev/null 2>&1; then :
  else fail "$c" "tracked note neither archived nor reachable from main"; fi
  [ -n "$a" ] && [ -f "$a/plan.md" ] || fail "$c" "archive incomplete: tracked notes missing from $a"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT1=$?

# --- T2: untracked notes -> still archived (no regression) --------------------
( c=T2; s=rt2; r="$TMPROOT/T2"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" untracked
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  wt_exists "$wt" && fail "$c" "worktree not removed: $out"
  a=$(arch_of "$r" feat); [ -n "$a" ] || fail "$c" "no archive dir created"
  for f in scratch.md extra.md; do
    [ -f "$a/$f" ] || fail "$c" "$f missing from the archive"
  done
  grep -qx 'scratch C' "$a/scratch.md" || fail "$c" "archived content differs"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT2=$?

# --- T3: mixed tracked + untracked -> nothing lost in either direction --------
( c=T3; s=rt3; r="$TMPROOT/T3"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" mixed
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  wt_exists "$wt" && fail "$c" "worktree not removed: $out"
  a=$(arch_of "$r" feat); [ -n "$a" ] || fail "$c" "no archive dir created"
  for f in scratch.md extra.md; do
    [ -f "$a/$f" ] || fail "$c" "untracked $f lost (not in archive)"
  done
  for f in plan.md research.md; do
    [ -f "$a/$f" ] || git -C "$r/repo" show "main:.fleet/notes/$f" >/dev/null 2>&1 \
      || fail "$c" "tracked $f lost (neither archived nor in history)"
  done
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT3=$?

# --- T4a: real uncommitted change OUTSIDE .fleet/ -> REFUSE, nothing touched --
( c=T4a; s=rt4a; r="$TMPROOT/T4a"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" tracked
  printf 'x\n' > "$wt/src.txt"; git -C "$wt" add src.txt; commit_in "$wt" src
  git -C "$r/repo" -c user.email=t@t -c user.name=t merge -q --ff-only feat
  printf 'user edit\n' > "$wt/src.txt"          # real uncommitted user work
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  printf '%s' "$out" | grep -q 'skip .*uncommitted' || fail "$c" "did not refuse: $out"
  assert_intact "$c" "$wt" "$s" "$w"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT4a=$?

# --- T4b: modified TRACKED note inside .fleet/notes -> REFUSE (defect 1.4) ----
# The blanket `^...\.fleet/` filter hides this from guard 5, so pre-fix reap kills
# the window first and only then refuses at the removal.
( c=T4b; s=rt4b; r="$TMPROOT/T4b"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" tracked
  printf 'UNREVIEWED LOCAL EDIT\n' >> "$wt/.fleet/notes/plan.md"
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  printf '%s' "$out" | grep -q 'skip .*uncommitted' \
    || fail "$c" "a tracked note with local mods must trip guard 5: $out"
  grep -q 'UNREVIEWED LOCAL EDIT' "$wt/.fleet/notes/plan.md" 2>/dev/null \
    || fail "$c" "the unreviewed local edit was destroyed"
  assert_intact "$c" "$wt" "$s" "$w"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT4b=$?

# --- T5: unmerged branch -> still REFUSES -------------------------------------
( c=T5; s=rt5; r="$TMPROOT/T5"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" tracked
  printf 'y\n' > "$wt/only-here.txt"; git -C "$wt" add only-here.txt
  commit_in "$wt" "unmerged work"               # NOT merged into main
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  printf '%s' "$out" | grep -q 'not merged into main' || fail "$c" "did not refuse: $out"
  git -C "$r/repo" branch --list feat | grep -q . || fail "$c" "branch deleted by a refusal"
  assert_intact "$c" "$wt" "$s" "$w"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT5=$?

# --- T6: --force on unmerged + tracked notes -> reaps, archive is COMPLETE ----
# --force deletes an unmerged branch, so the archive is the ONLY surviving copy
# of the tracked notes. It must therefore contain them (S1's copy-everything).
( c=T6; s=rt6; r="$TMPROOT/T6"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" tracked
  printf 'y\n' > "$wt/only-here.txt"; git -C "$wt" add only-here.txt
  commit_in "$wt" "unmerged work"
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s" --force)
  wt_exists "$wt" && fail "$c" "--force did not remove the worktree: $out"
  git -C "$r/repo" branch --list feat | grep -q . && fail "$c" "branch not deleted"
  a=$(arch_of "$r" feat); [ -n "$a" ] || fail "$c" "no archive dir created"
  [ -f "$a/plan.md" ] || fail "$c" "tracked note absent from the archive — it now exists nowhere"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT6=$?

# --- T7: empty notes dir ------------------------------------------------------
( c=T7; s=rt7; r="$TMPROOT/T7"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" empty
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  wt_exists "$wt" && fail "$c" "worktree not removed: $out"
  [ -n "$(arch_of "$r" feat)" ] && fail "$c" "empty notes dir produced an archive dir"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT7=$?

# --- T8: symlinked notes dir (target CONSTRAINED inside $TMPROOT) -------------
# Must not archive THROUGH or move the link: the archive must never contain a
# symlink entry, and the link target's files must be untouched.
( c=T8; s=rt8; r="$TMPROOT/T8"
  tgt="$TMPROOT/T8-linktarget"; mkdir -p "$tgt"; printf 'outside\n' > "$tgt/keep.md"
  wt=$(mkrepo "$r" "$s" feat 1)
  mkdir -p "$wt/.fleet"; ln -s "$tgt" "$wt/.fleet/notes"
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  [ -f "$tgt/keep.md" ] || fail "$c" "the symlink target's files were moved/destroyed"
  grep -qx outside "$tgt/keep.md" || fail "$c" "the symlink target's content changed"
  a=$(arch_of "$r" feat)
  if [ -n "$a" ]; then
    [ -L "$a" ] && fail "$c" "the notes SYMLINK itself was archived (dangling-by-construction)"
    find "$a" -type l 2>/dev/null | grep -q . && fail "$c" "archive contains a symlink entry"
  fi
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT8=$?

# --- T9: unresolvable project root -> fallback stays inside the sandbox -------
# HF-1: `fleet_root` ends in a bare `pwd` and NEVER returns empty. A naive "omit
# the root" test would `mkdir -p` and copy fixture notes INTO THE LIVE fleet
# CHECKOUT. So: no @fleet_root option, no FLEET_ROOT, and a cwd pinned inside
# $TMPROOT — then assert the live checkout gained nothing.
( c=T9; s=rt9; r="$TMPROOT/T9"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" untracked
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  tmux set -u -t "$s" @fleet_root 2>/dev/null     # make the option lookup fail
  unset FLEET_ROOT
  before=$(ls "$HERE/.fleet/notes/archive" 2>/dev/null | wc -l)
  out=$(cd "$TMPROOT" && FLEET_SESSION="$s" "$FLEET" reap 2>&1)
  after=$(ls "$HERE/.fleet/notes/archive" 2>/dev/null | wc -l)
  [ "$before" = "$after" ] || fail "$c" "reap wrote into the LIVE checkout ($before -> $after)"
  find "$TMPROOT" -maxdepth 4 -path "*/\.fleet/notes/archive/*" -name 'repo__feat__*' \
    >/dev/null 2>&1 || true
  wt_exists "$wt" && fail "$c" "reap did not proceed without a real project root: $out"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT9=$?

# --- T10: the existing teardown-safety invariants must not regress ------------
( c=T10
  if bash "$HERE/test/reap-teardown-safety.sh" >/dev/null 2>&1; then pass "$c"
  else fail "$c" "test/reap-teardown-safety.sh no longer passes 8/8"; fi
) ; rT10=$?

# --- T11: an EXCLUDE-LESS worktree must still reap ----------------------------
# No `/.fleet/` exclude line, untracked notes + the ready marker => porcelain
# shows `?? .fleet/` and plain `worktree remove` would refuse. Reap owns those
# artifacts, so it must clear them and still complete.
( c=T11; s=rt11; r="$TMPROOT/T11"
  wt=$(mkrepo "$r" "$s" feat 0); mknotes "$wt" untracked
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  wt_exists "$wt" && fail "$c" "exclude-less worktree was not reaped: $out"
  a=$(arch_of "$r" feat); [ -n "$a" ] && [ -f "$a/scratch.md" ] \
    || fail "$c" "untracked notes not archived on the exclude-less path"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT11=$?

# --- T12: a LOCKED worktree is refused during DECIDE, before any mutation -----
( c=T12; s=rt12; r="$TMPROOT/T12"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" untracked
  git -C "$r/repo" worktree lock "$wt" 2>/dev/null || fail "$c" "could not lock the fixture"
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  printf '%s' "$out" | grep -qi 'lock' || fail "$c" "no lock-specific refusal: $out"
  assert_intact "$c" "$wt" "$s" "$w"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rT12=$?

# ============================================================================ #
# ATOMICITY CASES — the primary proof.
# ============================================================================ #

# --- A1a: a LATE removal failure must kill NOTHING ----------------------------
# Fixture (the only honest one): exclude-less worktree + an untracked
# `.fleet/devport`. Guard 5 legitimately ignores `?? .fleet/`, so the run reaches
# `git worktree remove`, which refuses — with the post-state fully intact.
# Reap owns notes/ and ready, and puts them back; it does NOT own devport, so the
# refusal is genuine and repeatable.
( c=A1a; s=ra1a; r="$TMPROOT/A1a"
  wt=$(mkrepo "$r" "$s" feat 0); mknotes "$wt" untracked
  printf '9333\n' > "$wt/.fleet/devport"        # untracked, NOT fleet-removable
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  printf '%s' "$out" | grep -q '^skip' || fail "$c" "expected a refusal, got: $out"
  # S3: OUR skip line must stop advertising --force. (git's own quoted stderr may
  # well say "use --force to delete it" — that is git talking, and it is honest.)
  printf '%s\n' "$out" | grep '^skip' | grep -q -- '--force' \
    && fail "$c" "S3: the skip line still hard-recommends --force"
  printf '%s' "$out" | grep -qi 'contains modified or untracked\|git:' \
    || fail "$c" "S3: git's real error was swallowed: $out"
  assert_intact "$c" "$wt" "$s" "$w"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rA1a=$?

# --- A1b: on SUCCESS the destructive steps all still happen, in order ---------
( c=A1b; s=ra1b; r="$TMPROOT/A1b"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" tracked
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")
  printf '%s' "$out" | grep -q 'reaped repo/feat' || fail "$c" "no success line: $out"
  wt_exists "$wt"        && fail "$c" "worktree not removed"
  win_exists "$w"        && fail "$c" "worker window NOT killed after a successful removal"
  agents_line "$wt" "$s" && fail "$c" "saved-agents line NOT dropped after a successful removal"
  git -C "$r/repo" branch --list feat | grep -q . && fail "$c" "branch not deleted"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rA1b=$?

# --- A2: a failed reap is RETRYABLE — a second PLAIN reap still selects it ----
# This is the exact property that failed live (`nothing flagged ready`).
( c=A2; s=ra2; r="$TMPROOT/A2"
  wt=$(mkrepo "$r" "$s" feat 0); mknotes "$wt" untracked
  printf '9333\n' > "$wt/.fleet/devport"
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  reap "$s" >/dev/null 2>&1                      # first attempt: refuses
  out=$(reap "$s")                               # second, PLAIN (no --force)
  printf '%s' "$out" | grep -q 'nothing flagged ready' \
    && fail "$c" "the worktree became unreachable by reap after one refusal"
  printf '%s' "$out" | grep -q 'repo/feat' \
    || fail "$c" "second plain reap did not select the worktree: $out"
  assert_intact "$c" "$wt" "$s" "$w"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rA2=$?

# --- A3: the ready marker is NEVER deleted before success ---------------------
# Asserted across every refusing shape at once.
( c=A3; s=ra3; r="$TMPROOT/A3"
  # (i) guard-5 refusal, (ii) guard-6 refusal, (iii) late removal refusal
  wa=$(mkrepo "$r/i"   "${s}i"  feat 1); mknotes "$wa" tracked
  printf 'edit\n' >> "$wa/.fleet/notes/plan.md"
  wb=$(mkrepo "$r/ii"  "${s}ii" feat 1); mknotes "$wb" tracked
  printf 'z\n' > "$wb/only.txt"; git -C "$wb" add only.txt; commit_in "$wb" unmerged
  wc_=$(mkrepo "$r/iii" "${s}iii" feat 0); mknotes "$wc_" untracked
  printf '9333\n' > "$wc_/.fleet/devport"
  for n in i ii iii; do boot "${s}$n" "$r/$n" "$r/$n" >/dev/null; done
  addwin "${s}i" worker "$wa" >/dev/null; addwin "${s}ii" worker "$wb" >/dev/null
  addwin "${s}iii" worker "$wc_" >/dev/null
  reap "${s}i" >/dev/null 2>&1; reap "${s}ii" >/dev/null 2>&1; reap "${s}iii" >/dev/null 2>&1
  for x in "$wa" "$wb" "$wc_"; do
    [ -e "$x/.fleet/ready" ] || fail "$c" "marker deleted by a refused reap: $x"
  done
  pass "$c"
) ; rA3=$?

# --- A4: reap leaves NO self-inflicted dirt -----------------------------------
# Unfiltered porcelain after the attempt must equal what it was before it. On the
# clean tracked fixture that means: still empty (or the worktree is gone).
( c=A4; s=ra4; r="$TMPROOT/A4"
  wa=$(mkrepo "$r/a" "${s}a" feat 1); mknotes "$wa" tracked        # clean, merged
  wb=$(mkrepo "$r/b" "${s}b" feat 0); mknotes "$wb" untracked      # late-failure shape
  printf '9333\n' > "$wb/.fleet/devport"
  boot "${s}a" "$r/a" "$r/a" >/dev/null; addwin "${s}a" worker "$wa" >/dev/null
  boot "${s}b" "$r/b" "$r/b" >/dev/null; addwin "${s}b" worker "$wb" >/dev/null
  pa=$(porcelain "$wa"); pb=$(porcelain "$wb")
  [ -n "$pa" ] && fail "$c" "fixture a was not clean to begin with: $pa"
  reap "${s}a" >/dev/null 2>&1; reap "${s}b" >/dev/null 2>&1
  if wt_exists "$wa"; then
    [ "$(porcelain "$wa")" = "$pa" ] \
      || fail "$c" "reap dirtied the tree it then refused to remove: $(porcelain "$wa")"
  fi
  [ "$(porcelain "$wb")" = "$pb" ] \
    || fail "$c" "post-refusal state differs from pre-reap state: '$(porcelain "$wb")' != '$pb'"
  pass "$c"
) ; rA4=$?

# --- A5: --force is NOT required for a self-inflicted case --------------------
( c=A5; s=ra5; r="$TMPROOT/A5"
  wt=$(mkrepo "$r" "$s" feat 1); mknotes "$wt" mixed
  boot "$s" "$r" "$r" >/dev/null; w=$(addwin "$s" worker "$wt")
  out=$(reap "$s")                               # PLAIN — no --force anywhere
  wt_exists "$wt" && fail "$c" "plain reap failed on a fully self-inflicted case: $out"
  printf '%s' "$out" | grep -q -- '--force' \
    && fail "$c" "the success path still advertises --force: $out"
  assert_center_alive "$c" "$s" && pass "$c"
) ; rA5=$?

# --- report -------------------------------------------------------------------
CASES="rT1 rT2 rT3 rT4a rT4b rT5 rT6 rT7 rT8 rT9 rT10 rT11 rT12 rA1a rA1b rA2 rA3 rA4 rA5"
n=0; tot=0
for v in $CASES; do n=$((n+1)); eval "tot=\$((tot + \$$v))"; done
echo "== summary: $((n-tot)) passed, $tot failed =="
if [ "$tot" -eq 0 ]; then
  echo "RESULT: ALL $n CASES PASS — reap is atomic; a refusal orphans nothing."
  exit 0
else
  echo "RESULT: $tot of $n case(s) FAILED — reap can still orphan a worktree."
  exit 1
fi

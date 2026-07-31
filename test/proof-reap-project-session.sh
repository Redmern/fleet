#!/usr/bin/env bash
# Proof (d36) — `fleet reap` resolves its saved-agents file with project_session(),
# so it is NOT inert when invoked from a PARKED pane (every sub-orchestrator).
#
# THE LIVE BUG. cmd_reap did `sess=$(session_name)` then `f=$(agents_file "$sess")`.
# A sub-orch lives in the detached parking session "<sess>_hidden", so from its pane
# reap read ~/.config/fleet/sessions/<sess>_hidden.agents — a file that holds NONE of
# the project's workers (persist_agent writes to <project>.agents, and cmd_restore /
# cmd_forget read that same one; all three already key on project_session()). Reap
# printed "nothing flagged ready" — or, when the parking file did not exist at all,
# "no saved agents for this session" — for a worktree that was flagged ready, clean
# and merged. The WRONG FILE is read BEFORE the ready marker or the <target> label is
# ever consulted, so no per-worktree guard could catch it.
#
# Cases:
#   1.  fixture sanity — the parked pane really is in t1_hidden
#   2.  BASELINE: reap from the MAIN pane still reaps (must not regress)
#   3-4. CRITICAL: reap <label> from the PARKED pane reaps, and the worktree is gone
#   5.  the saved-agents line is struck from <project>.agents (writer/reader agree —
#       cmd_forget re-resolves project_session(), so MUTATE and DECIDE name one file)
#   6.  no orphan <project>_hidden.agents was created
#   7-8. NEGATIVE: an UNFLAGGED worktree is untouched from that same pane
#   9-10. NEGATIVE: a flagged DIRTY worktree is refused (and left intact)
#   11-12. NEGATIVE: a flagged UNMERGED worktree is refused (and left intact)
#   13. the <target> label match still scopes: a non-matching label reaps nothing
#
# Against HEAD~ (session_name) cases 3,4,5 fail — reap is inert from the parked pane.
# The negatives pass on both: they assert the guards the change must not weaken.
set -u
. "$(cd "$(dirname "$0")" && pwd)/hidden-proof-common.sh"
proof_isolate
proof_session t1

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

AGENTS_DIR="$XDG_CONFIG_HOME/fleet/sessions"
CONT="$FLEET_ROOT/cont"          # a worktree container: main checkout + linked worktrees

# ---- fixtures ----------------------------------------------------------------
# One container repo. cmd_reap requires a LINKED worktree (git-dir contains
# "/worktrees/"), which is exactly what `git worktree add` off cont/main makes.
mkdir -p "$CONT/main"
git -C "$CONT/main" init -q -b main 2>/dev/null
git -C "$CONT/main" config user.email t@t; git -C "$CONT/main" config user.name t
echo hi > "$CONT/main/f"; git -C "$CONT/main" add f 2>/dev/null
git -C "$CONT/main" commit -qm init 2>/dev/null

# mkwt <branch> — a linked worktree cut from main, with .fleet/ excluded (every
# worktree cmd_new makes carries that exclude, and it is what keeps fleet's own
# untracked markers out of the dirty guard).
mkwt() {
  local br="$1" d="$CONT/$1"
  git -C "$CONT/main" worktree add -q -b "$br" "$d" main 2>/dev/null
  mkdir -p "$d/.fleet" "$CONT/main/.git/worktrees/$br/info"
  printf '/.fleet/\n' >> "$CONT/main/.git/worktrees/$br/info/exclude" 2>/dev/null
  printf '%s' "$d"
}
flag()  { touch "$1/.fleet/ready"; }                       # mark ready
# register <dir> <branch> — a 9-field saved-agents line in the PROJECT's file
register() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" cont "$2" 0 main claude 0 "cont/$2" "" >> "$AGENTS_DIR/t1.agents"
}

D_OK=$(mkwt feat-ok);     flag "$D_OK";  register "$D_OK" feat-ok
D_BASE=$(mkwt feat-base); flag "$D_BASE"; register "$D_BASE" feat-base
D_NOFLAG=$(mkwt feat-noflag);            register "$D_NOFLAG" feat-noflag
D_DIRTY=$(mkwt feat-dirty); flag "$D_DIRTY"; register "$D_DIRTY" feat-dirty
echo scribble > "$D_DIRTY/newfile"
D_UNM=$(mkwt feat-unm);   flag "$D_UNM";  register "$D_UNM" feat-unm
echo ahead > "$D_UNM/ahead"; git -C "$D_UNM" add ahead 2>/dev/null
git -C "$D_UNM" commit -qm ahead 2>/dev/null                # 1 commit ahead of main

# ---- the parked pane ---------------------------------------------------------
section 'case 1 — fixture: a genuinely PARKED pane (a sub-orch lives here)'
"$FLEET" new --scratch orch >/dev/null 2>&1
wait_window orch || { no 'parked orch pane never spawned'; proof_summary; }
chk 'spawning pane is parked in the sibling session' 't1_hidden' "$(sess_of orch)"
OPANE=$(pane_of orch); sleep 0.5

section 'case 2 — BASELINE: reap from the MAIN pane still works'
OUT=$(FLEET_SESSION=t1 "$FLEET" reap cont/feat-base 2>&1)
case "$OUT" in
  *"reaped cont/feat-base"*) ok 'main-pane reap unchanged' ;;
  *) no "main-pane reap regressed: $OUT" ;;
esac

section 'cases 3-4 — CRITICAL: reap from the PARKED pane'
OUT=$(in_pane "$OPANE" "'$FLEET' reap cont/feat-ok" 2>&1)
case "$OUT" in
  *"reaped cont/feat-ok"*) ok 'parked pane reaps the PROJECT'"'"'s flagged worktree' ;;
  *"no saved agents"*)     no "reap read the PARKING file (the bug): $OUT" ;;
  *"nothing flagged ready"*) no "reap read the wrong file (the bug): $OUT" ;;
  *) no "unexpected reap output: $OUT" ;;
esac
if [ -d "$D_OK" ]; then no 'worktree still on disk after a reported reap'
else ok 'worktree removed'; fi

section 'case 5 — the line is struck from <project>.agents'
if grep -q 'feat-ok' "$AGENTS_DIR/t1.agents" 2>/dev/null; then
  no 'saved-agents line survives — cmd_forget struck a different file than reap read'
else
  ok 'DECIDE and MUTATE named the same file'
fi

section 'case 6 — no orphan parking-session agents file'
if [ -f "$AGENTS_DIR/t1_hidden.agents" ]; then
  no 'a t1_hidden.agents appeared — restore/forget never read it'
else
  ok 'no <project>_hidden.agents file'
fi

section 'cases 7-8 — NEGATIVE: an UNFLAGGED worktree is untouched'
OUT=$(in_pane "$OPANE" "'$FLEET' reap cont/feat-noflag" 2>&1)
case "$OUT" in
  *"reaped cont/feat-noflag"*) no "unflagged worktree was reaped: $OUT" ;;
  *) ok 'unflagged worktree not selected' ;;
esac
[ -d "$D_NOFLAG" ] && ok 'unflagged worktree still on disk' || no 'unflagged worktree gone'

section 'cases 9-10 — NEGATIVE: a flagged DIRTY worktree is refused'
OUT=$(in_pane "$OPANE" "'$FLEET' reap cont/feat-dirty" 2>&1)
case "$OUT" in
  *"skip   cont/feat-dirty"*uncommitted*) ok 'dirty guard still refuses from a parked pane' ;;
  *) no "dirty guard did not fire: $OUT" ;;
esac
[ -d "$D_DIRTY" ] && [ -e "$D_DIRTY/.fleet/ready" ] \
  && ok 'dirty worktree + its ready marker left intact (re-run is the retry)' \
  || no 'dirty worktree or its marker was disturbed'

section 'cases 11-12 — NEGATIVE: a flagged UNMERGED worktree is refused'
OUT=$(in_pane "$OPANE" "'$FLEET' reap cont/feat-unm" 2>&1)
case "$OUT" in
  *"skip   cont/feat-unm"*"not merged"*) ok 'unmerged guard still refuses from a parked pane' ;;
  *) no "unmerged guard did not fire: $OUT" ;;
esac
[ -d "$D_UNM" ] && ok 'unmerged worktree left intact' || no 'unmerged worktree was removed'

section 'case 13 — the <target> label match still scopes the sweep'
OUT=$(in_pane "$OPANE" "'$FLEET' reap cont/no-such-branch" 2>&1)
case "$OUT" in
  *reaped*) no "a non-matching target reaped something: $OUT" ;;
  *"nothing flagged ready"*) ok 'non-matching target selects nothing' ;;
  *) no "unexpected output for a non-matching target: $OUT" ;;
esac

proof_summary

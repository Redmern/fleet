#!/usr/bin/env bash
# Proof harness — "no-auto-commit" (dispatch d31).
#
# THE FEATURE: workers STAGE their work (`git add -A`) and never commit; the human
# reviews the staged tree and makes the one commit that enters history.
#
# The keystone is that `git add` is NOT `git commit` and `git diff HEAD` includes the
# index: a worker that stages everything is already visible in every existing surface,
# still counts as dirty for `reap`'s guard, and is one `git commit` from shipped. So
# `git add` MUST keep working — a guard that blocks it breaks all three wants.
#
# Cases map 1:1 onto the PROOF DESIGN P1-P9 in
# _reports/no-auto-commit/PLAN-PLAIN.md (the case header names its P).
#
# Boots a THROWAWAY, fully-isolated tmux server (TMUX_TMPDIR) + config
# (XDG_CONFIG_HOME) + runtime dir + project root, so it can never touch the real
# fleet session, its saved-agents file, or its inbox/ledger.
#
# before: RED on every case except 8 (plain-git sanity) and 18 (syntax).
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"
DASH="$HERE/bin/fleet-dash"
GUARD="$HERE/bin/fleet-guard"

# --- isolation: private tmux server, config, runtime dir and project root ------
TMPROOT=$(mktemp -d)
export TMUX_TMPDIR="$TMPROOT/tmuxsock"
mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
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
tmux() { command tmux -S "$SOCK" "$@"; }

export XDG_CONFIG_HOME="$TMPROOT/config"; mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run";    mkdir -p "$XDG_RUNTIME_DIR"  # no fleet.sock => daemon-down path
unset TMUX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export FLEET_DEBUG_PORT=59227
export FLEET_SESSION="nac_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet"

cleanup() { command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

FAILED=0
pass() { echo "  PASS($1)"; return 0; }
fail() { echo "  FAIL($1): $2"; return 1; }

# --- a recording harness stub, first on PATH ----------------------------------
# Records argv AND the FLEET_* env the pane was spawned with, so the env-injection
# assertions read the REAL spawn env rather than a re-derived guess.
BINSTUB="$TMPROOT/bin"; mkdir -p "$BINSTUB"
REC="$TMPROOT/argv.log"
cat > "$BINSTUB/claude-profile" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$REC"
env | grep '^FLEET_' | sort >> "$REC"
printf -- '---ARGV-END---\n' >> "$REC"
sleep 9999
EOS
chmod +x "$BINSTUB/claude-profile"
export REC
export PATH="$BINSTUB:$PATH"
reset_rec() { : > "$REC"; }

# --- guard driver -------------------------------------------------------------
# Feeds fleet-guard one PreToolUse payload and prints its stdout (empty = allow).
guard() { # <command> [role] [autocommit] [tool]
  local cmd="$1" role="${2:-worker}" ac="${3:-}" tool="${4:-Bash}"
  local json
  json=$(CMD="$cmd" TOOL="$tool" python3 -c \
    'import json,os;print(json.dumps({"tool_name":os.environ["TOOL"],"tool_input":{"command":os.environ["CMD"]},"cwd":"/tmp"}))')
  printf '%s' "$json" | env FLEET_ROLE="$role" FLEET_AUTOCOMMIT="$ac" sh "$GUARD" 2>/dev/null
}
denied()  { printf '%s' "$1" | grep -q '"permissionDecision": *"deny"'; }

# --- fixtures -----------------------------------------------------------------
# A worktree CONTAINER: <root>/repo holds the anchor working tree; per-branch
# worktrees hang off it, exactly as cmd_new builds them.
mkrepo() {
  [ -d "$FLEET_ROOT/repo" ] && return 0
  git init -q "$FLEET_ROOT/repo"
  ( cd "$FLEET_ROOT/repo" && echo base > tracked.txt && git add -A && git commit -qm init )
  git -C "$FLEET_ROOT/repo" branch -M main 2>/dev/null
}

# A ready worktree carrying STAGED-but-uncommitted work: one modified tracked file
# and one brand-new file — the exact end state a no-commit worker leaves behind.
mkstaged() { # <branch> [--unstaged-new] -> echoes the worktree dir
  local br="$1" mode="${2:-}"
  mkrepo
  local wt="$FLEET_ROOT/repo/${br//\//_}"
  git -C "$FLEET_ROOT/repo" worktree add -q -b "$br" "$wt" main 2>/dev/null
  echo changed > "$wt/tracked.txt"
  echo brandnew > "$wt/created.txt"
  [ "$mode" = --unstaged-new ] || git -C "$wt" add -A 2>/dev/null
  mkdir -p "$wt/.fleet"
  printf '%s' "$wt"
}
mkagents() { # <dir> <branch> — record it in the session's saved-agents file
  printf '%s\trepo\t%s\t\tmain\tclaude\n' "$1" "$2" \
    >> "$XDG_CONFIG_HOME/fleet/sessions/$FLEET_SESSION.agents"
}

tmux new-session -d -s "$FLEET_SESSION" -n main -c "$FLEET_ROOT" 'sleep 9999' 2>/dev/null
tmux set -t "$FLEET_SESSION" @fleet_root "$FLEET_ROOT" 2>/dev/null

echo "== no-auto-commit proof =="

# --- Case 1 (P1): the seeded instruction says STAGE, never COMMIT --------------
( c=1
  txt=$("$FLEET" ready-instructions 2>/dev/null)
  if [ -z "$txt" ]; then fail $c "\`fleet ready-instructions\` printed nothing (no way to read the seeded text)"; exit 1; fi
  if ! printf '%s' "$txt" | grep -qF 'git add -A'; then
    fail $c "instruction does not tell the worker to stage with 'git add -A'"; exit 1; fi
  if ! printf '%s' "$txt" | grep -qi 'do not commit\|never commit'; then
    fail $c "instruction does not forbid committing"; exit 1; fi
  if printf '%s' "$txt" | grep -qi 'COMPLETE and committed'; then
    fail $c "instruction still says 'COMPLETE and committed' — the old auto-commit directive"; exit 1; fi
  if ! printf '%s' "$txt" | grep -qF 'fleet ready'; then
    fail $c "instruction no longer names \`fleet ready\`"; exit 1; fi
  if printf '%s' "$txt" | grep -qi 'flags the worktree for deletion'; then
    fail $c "instruction still claims ready == deletion (it now means 'your turn, human')"; exit 1; fi
  pass $c ) || FAILED=1

# --- Case 2 (P2): the guard refuses every commit spelling ----------------------
( c=2
  bad=""
  for cmd in 'git commit -m x' 'git commit -am x' 'git -C . commit -m x' \
             'git commit --amend' 'git -c user.name=x commit -m y' \
             'git cherry-pick abc' 'git revert abc' 'git am /tmp/p' \
             'echo hi && git commit -m x'; do
    out=$(guard "$cmd")
    denied "$out" || bad="$bad
    NOT DENIED: $cmd"
  done
  [ -z "$bad" ] && pass $c || fail $c "commit slipped past the guard:$bad" ) || FAILED=1

# --- Case 3 (P2): the deny message tells the worker what to do instead ---------
( c=3
  out=$(guard 'git commit -m x')
  if ! denied "$out"; then fail $c "git commit was not denied at all"; exit 1; fi
  if ! printf '%s' "$out" | grep -qF 'git add -A'; then
    fail $c "deny message does not name 'git add -A' — the worker cannot comply"; exit 1; fi
  if ! printf '%s' "$out" | grep -qF 'fleet ready'; then
    fail $c "deny message does not name 'fleet ready'"; exit 1; fi
  if ! printf '%s' "$out" | grep -qF 'fleet autocommit on'; then
    fail $c "deny message does not name the 'fleet autocommit on' escape hatch"; exit 1; fi
  pass $c ) || FAILED=1

# --- Case 4 (P2 REGRESSION): staging and the non-destructive verbs still work --
# This is the load-bearing regression: blocking `git add` breaks all three wants.
( c=4
  bad=""
  for cmd in 'git add -A' 'git add .' 'git add -p file' 'git status' 'git diff HEAD' \
             'git stash' 'git stash pop' 'git rebase --abort' 'git log --oneline' \
             'fleet send x "remember to git commit later"'; do
    out=$(guard "$cmd")
    denied "$out" && bad="$bad
    WRONGLY DENIED: $cmd"
  done
  [ -z "$bad" ] && pass $c || fail $c "the guard broke non-commit git usage:$bad" ) || FAILED=1

# --- Case 5 (P2): merge/push floor intact, and its text no longer says "commit" -
( c=5
  m=$(guard 'git merge main'); p=$(guard 'git push origin HEAD')
  if ! denied "$m" || ! denied "$p"; then
    fail $c "the always-on merge/push floor regressed"; exit 1; fi
  if printf '%s' "$m" | grep -qF 'Commit on your own branch'; then
    fail $c "merge/push deny text still instructs the worker to commit"; exit 1; fi
  if ! printf '%s' "$m" | grep -qF 'git add -A'; then
    fail $c "merge/push deny text does not redirect to staging"; exit 1; fi
  pass $c ) || FAILED=1

# --- Case 6 (P9): the guard's commit arm is scoped and escapable ---------------
( c=6
  bad=""
  denied "$(guard 'git commit -m x' worker 1)"        && bad="$bad; FLEET_AUTOCOMMIT=1 still denied"
  denied "$(guard 'git commit -m x' main)"            && bad="$bad; a non-worker role was denied"
  denied "$(guard 'git commit -m x' worker '' Edit)"  && bad="$bad; a non-Bash tool was denied"
  [ -z "$bad" ] && pass $c || fail $c "commit-arm scoping wrong:$bad" ) || FAILED=1

# --- Case 7 (P3): the diff surface tells the truth about untracked files -------
( c=7
  wt=$(mkstaged fleet/diffa --unstaged-new)     # new file NOT staged: the worst case
  out=$("$FLEET" diff-view "$wt" 2>/dev/null)
  if [ -z "$out" ]; then fail $c "\`fleet diff-view\` printed nothing"; exit 1; fi
  if printf '%s' "$out" | grep -qi 'working tree clean'; then
    fail $c "diff view claims 'working tree clean' while the tree is dirty (the lie being fixed)"; exit 1; fi
  printf '%s' "$out" | grep -qF 'tracked.txt' || { fail $c "diff omits the MODIFIED tracked file"; exit 1; }
  printf '%s' "$out" | grep -qF 'created.txt' || { fail $c "diff omits the UNTRACKED new file"; exit 1; }
  printf '%s' "$out" | grep -qF 'brandnew'    || { fail $c "diff omits the new file's CONTENTS"; exit 1; }
  # A filename with a space must survive as ONE name — an unquoted expansion
  # word-splits it (and pathname-expands metacharacters) on the one surface whose
  # whole job is telling the human the truth about which files exist.
  echo sp > "$wt/spaced name.txt"
  out2=$("$FLEET" diff-view "$wt" 2>/dev/null)
  printf '%s' "$out2" | grep -qF 'spaced name.txt' \
    || { fail $c "a space-named untracked file is mangled in the diff view"; exit 1; }
  pass $c ) || FAILED=1

# --- Case 8 (P3): staged work shows, and a genuinely clean tree still says so --
( c=8
  wt=$(mkstaged fleet/diffb)                    # everything staged
  out=$("$FLEET" diff-view "$wt" 2>/dev/null)
  printf '%s' "$out" | grep -qF 'created.txt' || { fail $c "staged new file missing from the diff"; exit 1; }
  printf '%s' "$out" | grep -qF 'tracked.txt' || { fail $c "staged modification missing from the diff"; exit 1; }
  # a PRISTINE repo of its own — $FLEET_ROOT/repo hosts the sibling worktrees, which
  # show up as untracked dirs and would make it legitimately dirty.
  clean="$TMPROOT/cleanrepo"; git init -q "$clean"
  ( cd "$clean" && echo x > a.txt && git add -A && git commit -qm init )
  cout=$("$FLEET" diff-view "$clean" 2>/dev/null)
  printf '%s' "$cout" | grep -qi 'clean' || { fail $c "a genuinely clean tree does not report clean"; exit 1; }
  pass $c ) || FAILED=1

# --- Case 9 (P3): the dashboard routes `v` through the honest diff -------------
( c=9
  body=$(awk '/^view_diff\(\)/{f=1} f{print} f&&/^}/{exit}' "$DASH")
  if [ -z "$body" ]; then fail $c "view_diff() not found in $DASH"; exit 1; fi
  if printf '%s' "$body" | grep -qF 'diff HEAD'; then
    fail $c "view_diff still runs a bare 'git diff HEAD' — untracked files stay invisible"; exit 1; fi
  if ! printf '%s' "$body" | grep -qF 'diff-view'; then
    fail $c "view_diff does not delegate to \`fleet diff-view\` (one source of diff truth)"; exit 1; fi
  pass $c ) || FAILED=1

# --- Case 10 (P4): the human's commit is one command ---------------------------
( c=10
  wt=$(mkstaged fleet/commitme)
  ( cd "$wt" && GIT_AUTHOR_NAME=human GIT_COMMITTER_NAME=human git commit -qm "human commit" ) 2>/dev/null
  n=$(git -C "$wt" rev-list --count main..HEAD 2>/dev/null)
  [ "$n" = 1 ] || { fail $c "expected exactly 1 commit after a bare \`git commit\`, got '$n'"; exit 1; }
  files=$(git -C "$wt" show --name-only --format= HEAD 2>/dev/null)
  printf '%s' "$files" | grep -qF tracked.txt || { fail $c "the commit missed tracked.txt"; exit 1; }
  printf '%s' "$files" | grep -qF created.txt || { fail $c "the commit missed created.txt"; exit 1; }
  who=$(git -C "$wt" log -1 --format='%an' 2>/dev/null)
  [ "$who" = human ] || { fail $c "author is '$who', not the human"; exit 1; }
  pass $c ) || FAILED=1

# --- Case 11 (P5): reap refuses ready+dirty and points at COMMITTING -----------
( c=11
  wt=$(mkstaged fleet/reapa); : > "$wt/.fleet/ready"; mkagents "$wt" fleet/reapa
  out=$(cd "$FLEET_ROOT" && "$FLEET" reap fleet/reapa 2>&1)
  [ -d "$wt" ] || { fail $c "reap REMOVED a dirty worktree without --force"; exit 1; }
  printf '%s' "$out" | grep -qi 'commit' || {
    fail $c "the dirty refusal does not tell the human to commit — got: $out"; exit 1; }
  if printf '%s' "$out" | grep -qF -- '--force'; then
    fail $c "the dirty refusal still advertises --force as the remedy — got: $out"; exit 1; fi
  pass $c ) || FAILED=1

# --- Case 12 (P5): --force exports the work before it destroys anything --------
( c=12
  wt=$(mkstaged fleet/reapb); : > "$wt/.fleet/ready"; mkagents "$wt" fleet/reapb
  # TWO untracked files, one with a space: the NUL-separated list must reach tar
  # intact. A single staged fixture left `ls-files -o` empty and the tarball
  # assertion vacuous — which is how a real NUL-stripping bug survived a green run.
  echo loose1 > "$wt/loose-one.txt"; echo loose2 > "$wt/loose two.txt"
  out=$(cd "$FLEET_ROOT" && "$FLEET" reap fleet/reapb --force 2>&1)
  [ -d "$wt" ] && { fail $c "--force did not remove the worktree: $out"; exit 1; }
  ex=$(find "$FLEET_ROOT/.fleet" -name uncommitted.patch 2>/dev/null | head -1)
  tg=$(find "$FLEET_ROOT/.fleet" -name 'untracked.tgz' 2>/dev/null | head -1)
  [ -s "$ex" ] || { fail $c "no non-empty uncommitted.patch exported outside the worktree"; exit 1; }
  [ -f "$tg" ] || { fail $c "no untracked.tgz exported"; exit 1; }
  names=$(tar -tzf "$tg" 2>/dev/null)
  printf '%s' "$names" | grep -qF 'loose-one.txt' || { fail $c "untracked.tgz is missing loose-one.txt (got: $(printf '%s' "$names" | tr '\n' ' '))"; exit 1; }
  printf '%s' "$names" | grep -qF 'loose two.txt' || { fail $c "untracked.tgz is missing the space-named file (got: $(printf '%s' "$names" | tr '\n' ' '))"; exit 1; }
  # the patch must reproduce the tree: apply it onto a fresh checkout of base
  rep="$TMPROOT/replay"; git -C "$FLEET_ROOT/repo" worktree add -q --detach "$rep" main 2>/dev/null
  if ! git -C "$rep" apply "$ex" 2>/dev/null; then
    fail $c "the exported patch does not apply onto base — the work is NOT recoverable"; exit 1; fi
  grep -qx changed  "$rep/tracked.txt" 2>/dev/null || { fail $c "patch lost the tracked modification"; exit 1; }
  grep -qx brandnew "$rep/created.txt" 2>/dev/null || { fail $c "patch lost the new file"; exit 1; }
  pass $c ) || FAILED=1

# --- Case 13 (P5): the dashboard's force-remove cannot eat the work either -----
( c=13
  body=$(awk '/^confirm_teardown\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DASH")
  if [ -z "$body" ]; then fail $c "confirm_teardown() not found in $DASH"; exit 1; fi
  if ! printf '%s' "$body" | grep -qF 'export-uncommitted'; then
    fail $c "the dashboard's force-remove does not export the work first (3-keystroke data loss)"; exit 1; fi
  if printf '%s' "$body" | grep -qF 'use FORCE'; then
    fail $c "the failure text still coaches FORCE"; exit 1; fi
  pass $c ) || FAILED=1

# --- Case 14 (P5): `fleet ready` writes the recovery checkpoint ref ------------
( c=14
  wt=$(mkstaged fleet/ckpt)
  ( cd "$wt" && "$FLEET" ready >/dev/null 2>&1 )
  ref=$(git -C "$wt" for-each-ref --format='%(refname)' 'refs/fleet/checkpoint/*' 2>/dev/null | head -1)
  [ -n "$ref" ] || { fail $c "no refs/fleet/checkpoint/* written — uncommitted work has no recovery net"; exit 1; }
  files=$(git -C "$wt" show --name-only --format= "$ref" 2>/dev/null)
  printf '%s' "$files" | grep -qF created.txt || { fail $c "checkpoint ref does not contain the staged work"; exit 1; }
  n=$(git -C "$wt" rev-list --count main..HEAD 2>/dev/null)
  [ "$n" = 0 ] || { fail $c "the checkpoint leaked onto the worker's BRANCH ($n commits ahead)"; exit 1; }
  pass $c ) || FAILED=1

# --- Case 15 (P6): GATE 2 cannot declare shipped work that does not exist ------
( c=15
  wt=$(mkstaged fleet/gate2); mkdir -p "$FLEET_ROOT/.fleet"
  out=$(cd "$FLEET_ROOT" && "$FLEET" gate post 2 --slug gate2 -w "$wt" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    fail $c "gate post 2 SUCCEEDED with zero commits — the pipeline would report shipped work that does not exist"; exit 1; fi
  printf '%s' "$out" | grep -qi 'commit' || { fail $c "the refusal does not explain the zero-commit cause — got: $out"; exit 1; }
  ( cd "$wt" && git -c user.name=h -c user.email=h@h commit -qm real ) 2>/dev/null
  out2=$(cd "$FLEET_ROOT" && "$FLEET" gate post 2 --slug gate2 -w "$wt" 2>&1); rc2=$?
  [ "$rc2" = 0 ] || { fail $c "gate post 2 refused a branch that DOES have commits — got: $out2"; exit 1; }
  pass $c ) || FAILED=1

# --- Case 16 (P7): ready+dirty surfaces as `review`, ready+clean as done -------
( c=16
  d=$(mkstaged fleet/revw);  : > "$d/.fleet/ready"
  k=$(mkstaged fleet/cleanw); : > "$k/.fleet/ready"
  ( cd "$k" && git -c user.name=h -c user.email=h@h commit -qm x ) 2>/dev/null
  wd=$(tmux new-window -P -F '#{window_id}' -t "=$FLEET_SESSION" -n dirtyw  -c "$d" 'sleep 9999' 2>/dev/null)
  wk=$(tmux new-window -P -F '#{window_id}' -t "=$FLEET_SESSION" -n cleanw  -c "$k" 'sleep 9999' 2>/dev/null)
  tmux set -w -t "$wd" @agent_state idle 2>/dev/null; tmux set -w -t "$wd" automatic-rename off 2>/dev/null
  tmux set -w -t "$wk" @agent_state idle 2>/dev/null; tmux set -w -t "$wk" automatic-rename off 2>/dev/null
  rows=$(cd "$FLEET_ROOT" && "$FLEET" agents 2>/dev/null)
  rd=$(printf '%s\n' "$rows" | awk -F'\t' '$5=="dirtyw"{print $9}')
  rk=$(printf '%s\n' "$rows" | awk -F'\t' '$5=="cleanw"{print $9}')
  [ "$rd" = review ] || { fail $c "ready+dirty shows '$rd', want 'review'"; exit 1; }
  [ -n "$rk" ] && [ "$rk" != review ] || { fail $c "ready+clean shows '$rk', want a plain ready/done marker"; exit 1; }
  tmux kill-window -t "$wd" 2>/dev/null; tmux kill-window -t "$wk" 2>/dev/null
  pass $c ) || FAILED=1

# --- Case 17 (P8 REGRESSION): the agents TSV is still EXACTLY 9 fields --------
# Three independent readers parse it positionally and fail SILENTLY WRONG on a 10th.
( c=17
  w=$(tmux new-window -P -F '#{window_id}' -t "=$FLEET_SESSION" -n ninef -c "$FLEET_ROOT/repo" 'sleep 9999' 2>/dev/null)
  tmux set -w -t "$w" @agent_state idle 2>/dev/null; tmux set -w -t "$w" automatic-rename off 2>/dev/null
  bad=$(cd "$FLEET_ROOT" && "$FLEET" agents 2>/dev/null | awk -F'\t' 'NF!=9{print NR": "NF" fields"}')
  tmux kill-window -t "$w" 2>/dev/null
  [ -z "$bad" ] && pass $c || fail $c "agents TSV is not 9 fields: $bad" ) || FAILED=1

# --- Case 18 (P8): a LEGACY saved-agents row restores with the safe default ----
( c=18
  f="$XDG_CONFIG_HOME/fleet/sessions/legacy.agents"
  printf '%s\trepo\tfleet/legacy\t\tmain\tclaude\t0\t\t\n' "$FLEET_ROOT/repo/fleet_legacy" > "$f"
  # cmd_restore must parse a 9-field legacy row and pick the NO-COMMIT default.
  out=$(FLEET_SESSION=legacy "$FLEET" restore 2>&1)
  printf '%s' "$out" | grep -qi 'error\|unbound\|syntax' && { fail $c "restore choked on a legacy short row: $out"; exit 1; }
  # and persist_agent must not have widened the default line beyond 9 fields
  nf=$(awk -F'\t' 'NR==1{print NF}' "$f")
  [ "$nf" = 9 ] || { fail $c "legacy row rewritten to $nf fields"; exit 1; }
  # Round-trip the column for real, in BOTH directions, through the actual writer:
  # a DEFAULT spawn must still emit exactly 9 fields (an older 9-var cmd_restore
  # parses this same file, and a 10th column would land in `owner`), and an
  # --autocommit spawn must emit 10 with a trailing "1".
  mkrepo
  af="$XDG_CONFIG_HOME/fleet/sessions/$FLEET_SESSION.agents"
  # Measured ONE AT A TIME: `repo` is a plain working repo (used in place, no
  # worktree), so both spawns share a dir and persist_agent replaces the line.
  ( cd "$FLEET_ROOT" && "$FLEET" new repo fleet/persistdef --bare -p t >/dev/null 2>&1 )
  sleep 0.5
  dn=$(awk -F'\t' '$3=="fleet/persistdef"{print NF; exit}' "$af")
  ( cd "$FLEET_ROOT" && "$FLEET" new repo fleet/persistac --bare --autocommit -p t >/dev/null 2>&1 )
  sleep 0.5
  an=$(awk -F'\t' '$3=="fleet/persistac"{print NF"|"$10; exit}' "$af")
  [ "$dn" = 9 ]     || { fail $c "a DEFAULT agent persisted $dn fields, not 9 — an older cmd_restore would mangle \`owner\`"; exit 1; }
  [ "$an" = "10|1" ] || { fail $c "an --autocommit agent persisted '$an', want '10|1'"; exit 1; }
  pass $c ) || FAILED=1

# --- Case 19 (P9): the toggle, both polarities, marker + per-agent override ----
( c=19
  m="$FLEET_ROOT/.fleet/autocommit"
  ( cd "$FLEET_ROOT" && "$FLEET" autocommit off >/dev/null 2>&1 )
  [ -e "$m" ] && { fail $c "'autocommit off' left the marker in place (polarity is POSITIVE: present = allowed)"; exit 1; }
  ( cd "$FLEET_ROOT" && "$FLEET" autocommit on >/dev/null 2>&1 )
  [ -e "$m" ] || { fail $c "'autocommit on' did not create $m"; exit 1; }
  s=$(cd "$FLEET_ROOT" && "$FLEET" autocommit status 2>&1)
  printf '%s' "$s" | grep -qi 'on' || { fail $c "status does not report ON — got: $s"; exit 1; }
  ( cd "$FLEET_ROOT" && "$FLEET" autocommit off >/dev/null 2>&1 )
  s2=$(cd "$FLEET_ROOT" && "$FLEET" autocommit status 2>&1)
  printf '%s' "$s2" | grep -qi 'off' || { fail $c "status does not report off — got: $s2"; exit 1; }
  pass $c ) || FAILED=1

# --- Case 20 (P9): the spawn env carries the resolved decision ------------------
( c=20
  mkrepo
  ( cd "$FLEET_ROOT" && "$FLEET" autocommit off >/dev/null 2>&1 )
  reset_rec
  ( cd "$FLEET_ROOT" && "$FLEET" new repo fleet/acoff --bare -p task >/dev/null 2>&1 )
  sleep 0.6
  grep -qx 'FLEET_AUTOCOMMIT=0' "$REC" || { fail $c "default spawn did not carry FLEET_AUTOCOMMIT=0 (got: $(grep FLEET_AUTOCOMMIT "$REC" | tr '\n' ' '))"; exit 1; }
  reset_rec
  ( cd "$FLEET_ROOT" && "$FLEET" new repo fleet/acflag --bare --autocommit -p task >/dev/null 2>&1 )
  sleep 0.6
  grep -qx 'FLEET_AUTOCOMMIT=1' "$REC" || { fail $c "--autocommit did not override the project default"; exit 1; }
  reset_rec
  ( cd "$FLEET_ROOT" && "$FLEET" autocommit on >/dev/null 2>&1 )
  ( cd "$FLEET_ROOT" && "$FLEET" new repo fleet/acmark --bare -p task >/dev/null 2>&1 )
  sleep 0.6
  grep -qx 'FLEET_AUTOCOMMIT=1' "$REC" || { fail $c "the project marker did not reach the spawn env"; exit 1; }
  reset_rec
  ( cd "$FLEET_ROOT" && "$FLEET" new repo fleet/acno --bare --no-autocommit -p task >/dev/null 2>&1 )
  sleep 0.6
  grep -qx 'FLEET_AUTOCOMMIT=0' "$REC" || { fail $c "--no-autocommit did not override the marker"; exit 1; }
  ( cd "$FLEET_ROOT" && "$FLEET" autocommit off >/dev/null 2>&1 )
  pass $c ) || FAILED=1

# --- Case 21: docs state the new contract, and the mirrors stay in sync --------
( c=21
  bullet() { awk '/^- `fleet ready /{f=1} f{print} f&&/^$/{exit}' "$1"; }
  fb=$(bullet "$HERE/FLEET.md")
  cb=$(awk '/^# Fleet — orchestrator capabilities/{s=1} s' "$HERE/CLAUDE.md" \
        | awk '/^- `fleet ready /{f=1} f{print} f&&/^$/{exit}')
  [ -n "$fb" ] || { fail $c "no \`fleet ready\` bullet in FLEET.md"; exit 1; }
  [ "$fb" = "$cb" ] || { fail $c "the \`fleet ready\` bullet differs between FLEET.md and CLAUDE.md"; exit 1; }
  printf '%s' "$fb" | grep -qF 'git add -A' || { fail $c "the ready bullet does not tell workers to stage"; exit 1; }
  printf '%s' "$fb" | grep -qi 'not commit\|never commit' || { fail $c "the ready bullet does not forbid committing"; exit 1; }
  grep -qF 'fleet autocommit' "$HERE/FLEET.md" || { fail $c "FLEET.md does not document \`fleet autocommit\`"; exit 1; }
  grep -qi 'advisory\|claude-only\|not a wall\|backstop' "$HERE/FLEET.md" \
    || { fail $c "FLEET.md does not state the enforcement scope honestly"; exit 1; }
  grep -qi 'commit' "$HERE/FLEET_SUBORCH.md" || { fail $c "FLEET_SUBORCH.md still says nothing about commits"; exit 1; }
  pass $c ) || FAILED=1

# --- Case 22: syntax ------------------------------------------------------------
( c=22
  err=""
  bash -n "$FLEET" 2>/dev/null || err="$err bin/fleet"
  bash -n "$DASH"  2>/dev/null || err="$err bin/fleet-dash"
  sh   -n "$GUARD" 2>/dev/null || err="$err bin/fleet-guard"
  [ -z "$err" ] && pass $c || fail $c "syntax errors in:$err" ) || FAILED=1

echo
if [ "$FAILED" = 0 ]; then echo "RESULT: ALL PASS"; else echo "RESULT: FAILURES ABOVE"; fi
exit "$FAILED"

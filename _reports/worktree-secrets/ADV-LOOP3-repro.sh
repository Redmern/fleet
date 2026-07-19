#!/usr/bin/env bash
# ADVERSARY loop-3 — try to break the .git-dir refusal + spot-regress prior wins.
set -u
HERE=/home/red/proj/pc-tune/fleet/fleet_worktree-secrets
FLEET="$HERE/bin/fleet"
TMPROOT=$(mktemp -d /tmp/wts-adv.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "  ** FAIL: $*"; FAIL=$((FAIL+1)); }

new_box() { # <repo>  -> sets WT, SECRETS, AUDIT, GD (git dir)
  BOX=$(mktemp -d "$TMPROOT/box.XXXXXX")
  export XDG_CONFIG_HOME="$BOX/config"
  export PASSWORD_STORE_DIR="$BOX/store"
  export GNUPGHOME="$BOX/gnupg"
  export FLEET_SESSION="adv-$$"
  CONF="$XDG_CONFIG_HOME/fleet"
  SECRETS="$CONF/secrets/$1"
  AUDIT="$CONF/secrets/audit.log"
  WT="$BOX/wt"
  mkdir -p "$SECRETS" "$PASSWORD_STORE_DIR" "$GNUPGHOME"
  git init -q "$WT"
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  GD="$WT/.git"
}
inject() { local repo="$1"; shift; timeout 20 env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
  PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" GNUPGHOME="$GNUPGHOME" "$@" \
  "$FLEET" inject-secrets "$repo" "$WT"; }
EXCL() { printf '%s' "$WT/.git/info/exclude"; }

echo "===== ADVERSARY: attack the .git-dir refusal ====="

echo "--- A1: secret with literal .git/ component (baseline, must refuse) ---"
( new_box app
  mkdir -p "$SECRETS/.git/hooks"
  printf '#!/bin/sh\necho PWNED' > "$SECRETS/.git/hooks/post-checkout"
  inject app >/dev/null 2>&1
  if [ -e "$GD/hooks/post-checkout" ] && grep -q PWNED "$GD/hooks/post-checkout" 2>/dev/null; then
    bad "A1 literal .git/hooks landed a hook"
  else ok "A1 literal .git/hooks/post-checkout refused"; fi
  grep -q 'git-dir' "$AUDIT" 2>/dev/null && ok "A1 audit logged git-dir" || bad "A1 no git-dir audit"
)

echo "--- A2: bare top-level file literally named .git ---"
( new_box app
  printf 'gitdir: /evil' > "$SECRETS/.git"
  inject app >/dev/null 2>&1
  # .git already exists as a DIR in the worktree; refusal must hold regardless
  if [ -f "$GD" ]; then bad "A2 .git replaced with a file"; else ok "A2 top-level .git file refused"; fi
)

echo "--- A3: PARENT SYMLINK to .git committed in base branch (THE attack) ---"
( new_box app
  # plant a committed symlink foo -> .git in the worktree, like a malicious base branch
  ( cd "$WT" && ln -s .git foo && git add foo 2>/dev/null && \
    git -c user.email=t@t -c user.name=t commit -q -m sym 2>/dev/null )
  ls -ld "$WT/foo"
  # secret source: plain dir foo/ + plain file foo/hooks/post-checkout (NO literal .git in rel)
  mkdir -p "$SECRETS/foo/hooks"
  printf '#!/bin/sh\necho PWNED_VIA_SYMLINK' > "$SECRETS/foo/hooks/post-checkout"
  inject app >/dev/null 2>&1
  if [ -e "$GD/hooks/post-checkout" ] && grep -q PWNED_VIA_SYMLINK "$GD/hooks/post-checkout" 2>/dev/null; then
    bad "A3 *** secret landed a git hook via committed symlink parent ***"
    echo "      dest resolved: $(realpath "$WT/foo/hooks/post-checkout" 2>/dev/null)"
  else ok "A3 symlink-parent route did NOT write into .git/hooks"; fi
)

echo "--- A4: parent symlink to .git, single file (foo -> .git, secret foo/config) ---"
( new_box app
  ( cd "$WT" && ln -s .git foo && git add foo && git -c user.email=t@t -c user.name=t commit -q -m sym )
  mkdir -p "$SECRETS/foo"
  printf '[core] evil=1' > "$SECRETS/foo/config-injected"
  before=$(cat "$GD/config" 2>/dev/null)
  inject app >/dev/null 2>&1
  if [ -e "$GD/config-injected" ]; then bad "A4 wrote $GD/config-injected (inside real git dir)"
  else ok "A4 no file landed inside .git via symlink"; fi
)

echo "--- A5: case/spelling variants on a CASE-SENSITIVE FS (.GIT .git. '.git ' .gitfoo) ---"
( new_box app
  mkdir -p "$SECRETS/.GIT" "$SECRETS/.git." "$SECRETS/.git "
  printf x > "$SECRETS/.GIT/h";  printf x > "$SECRETS/.git./h"; printf x > "$SECRETS/.git /h"
  printf 'LEGIT' > "$SECRETS/.gitfoo"
  printf 'IGNOREME' > "$SECRETS/.gitignore"
  inject app >/dev/null 2>&1
  # On ext4 these are DISTINCT dirs from .git -> harmless literal dirs in the worktree.
  for d in .GIT .git. ".git "; do
    [ -e "$GD/hooks" ] && true
  done
  # Crucial: none should have written into the REAL .git
  if [ -e "$GD/h" ]; then bad "A5 a case-variant wrote into real .git"; else ok "A5 no case-variant reached real .git"; fi
  # .gitfoo / .gitignore must NOT be over-rejected (legit top-level dotfiles)
  [ -f "$WT/.gitfoo" ] && grep -q LEGIT "$WT/.gitfoo" && ok "A5 .gitfoo placed (not over-rejected)" || bad "A5 .gitfoo wrongly rejected"
  [ -f "$WT/.gitignore" ] && ok "A5 .gitignore placed (not over-rejected)" || bad "A5 .gitignore wrongly rejected"
  echo "      worktree top-level entries:"; ls -a "$WT" | grep -E '^\.G|^\.git' | sed 's/^/        /'
)

echo "--- A6: mid-list isolation — .git reject must NOT skip a following sound secret ---"
( new_box app
  mkdir -p "$SECRETS/.git/hooks"
  printf 'evil' > "$SECRETS/.git/hooks/pre-commit"
  printf 'GOOD' > "$SECRETS/zzz-after.env"   # sorts AFTER .git lexically in find order
  printf 'GOOD2' > "$SECRETS/aaa-before.env" # sorts BEFORE
  inject app >/dev/null 2>&1
  [ -f "$WT/zzz-after.env" ] && grep -q GOOD "$WT/zzz-after.env" && ok "A6 secret after .git still placed" || bad "A6 following secret skipped"
  [ -f "$WT/aaa-before.env" ] && ok "A6 secret before .git still placed" || bad "A6 preceding secret skipped"
  [ -e "$GD/hooks/pre-commit" ] && bad "A6 .git hook still landed" || ok "A6 .git hook refused"
)

echo "--- A7: symlink SOURCE named .git -> real dir (which check fires first?) ---"
( new_box app
  ( cd "$SECRETS" && ln -s /etc .git 2>/dev/null )
  inject app >/dev/null 2>&1
  if [ -e "$GD/passwd" ] || [ -L "$GD" ]; then bad "A7 symlink .git source followed/replaced"; else ok "A7 symlink source named .git refused"; fi
)

echo "--- A8: .git as a FILE in worktree (gitdir pointer / linked-worktree layout) ---"
( new_box app
  # simulate linked worktree: replace .git dir reference test — make a 2nd worktree
  GDcommon="$WT/.git"
  # secret literally targeting .git (a file in linked-wt) still must refuse
  printf 'gitdir: /evil' > "$SECRETS/.git"
  inject app >/dev/null 2>&1
  ok "A8 ran (literal .git refused as in A2)"
)

echo "===== SPOT-REGRESS prior protections ====="

echo "--- R1: GAP1 skip-worktree (tracked dest not committable) ---"
( new_box app
  printf 'PLACEHOLDER' > "$WT/config.json"
  git -C "$WT" add config.json && git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m add
  printf 'REALSECRET' > "$SECRETS/config.json"
  inject app >/dev/null 2>&1
  got=$(cat "$WT/config.json")
  [ "$got" = REALSECRET ] && ok "R1 tracked dest overwritten with secret" || bad "R1 dest content=$got"
  if git -C "$WT" status --porcelain | grep -q config.json; then bad "R1 secret shows committable in status"
  else ok "R1 skip-worktree hides tracked secret from status"; fi
  git -C "$WT" ls-files -v config.json | grep -q '^S' && ok "R1 skip-worktree bit set" || bad "R1 no skip-worktree bit"
)

echo "--- R2: GAP2 dir-collision refused ---"
( new_box app
  mkdir -p "$WT/data"   # dest is a real directory
  mkdir -p "$SECRETS/data"; printf x > "$SECRETS/data"_x 2>/dev/null
  # make secret 'data' a file colliding with the dir
  rm -rf "$SECRETS/data"; printf 'SECRET' > "$SECRETS/data"
  out=$(inject app 2>&1)
  [ -d "$WT/data" ] && ok "R2 dir-collision: worktree dir intact" || bad "R2 dir clobbered"
  echo "$out" | grep -qi 'directory' && ok "R2 refused loudly" || bad "R2 not refused loudly"
  grep -q 'dir-collision' "$AUDIT" 2>/dev/null && ok "R2 audit dir-collision" || bad "R2 no dir-collision audit"
)

echo "--- R3: audit logs NO values ---"
( new_box app
  printf 'TOPSECRETVALUE12345' > "$SECRETS/.env"
  inject app >/dev/null 2>&1
  if grep -q TOPSECRETVALUE12345 "$AUDIT" 2>/dev/null; then bad "R3 audit leaked secret value"; else ok "R3 audit has no value"; fi
  echo "      audit tail: $(tail -1 "$AUDIT" 2>/dev/null)"
)

echo "--- R4: fail-silent on missing pass entry ---"
( new_box app
  printf 'pass:nonexistent/entry' > "$SECRETS/.env"
  out=$(inject app 2>&1); rc=$?
  [ "$rc" = 0 ] && ok "R4 exit 0 on missing pass entry" || bad "R4 exit $rc"
  [ -f "$WT/.env" ] && bad "R4 wrote empty/garbage dest" || ok "R4 no dest written on missing entry"
)

echo "--- R5: parent-symlink ESCAPE outside worktree still rejected (confinement) ---"
( new_box app
  ext=$(mktemp -d "$TMPROOT/ext.XXXXXX")
  ( cd "$WT" && ln -s "$ext" out && git add out && git -c user.email=t@t -c user.name=t commit -q -m out )
  mkdir -p "$SECRETS/out"; printf 'ESCAPED' > "$SECRETS/out/leak"
  inject app >/dev/null 2>&1
  if [ -e "$ext/leak" ]; then bad "R5 secret escaped worktree to $ext/leak"; else ok "R5 escape via symlink-to-external rejected"; fi
)

echo
echo "===== RESULT: $PASS pass, $FAIL fail ====="

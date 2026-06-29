#!/usr/bin/env bash
# Proof harness — worktree-secrets v1 (honest, same-uid). Mirrors
# test/reap-teardown-safety.sh: self-contained, fully env-isolated (FLEET_SESSION
# + XDG_CONFIG_HOME + PASSWORD_STORE_DIR all under /tmp), prints PASS/FAIL per
# criterion and a final summary; exits 0 only if every case passes.
#
# Proves PLAN-PLAIN scenarios 1,3,4,5,6,7,8 + scenario-2's HONESTY assertions for
# `inject_secrets <repo> <dir>` (exposed as `fleet inject-secrets`) and the
# `fleet doctor` secrets line. NOTHING here touches the real ~/.config/fleet, the
# real ~/.password-store, or the real tmux session.
#
# The default mechanism under test: mirror-copy ~/.config/fleet/secrets/<repo>/
# into $dir/ (relative path = dest), chmod 600, realpath-confined inside $dir,
# each dest appended idempotently to .git/info/exclude, `pass:<entry>` sugar
# resolved via `pass show`, append-only audit log outside the worktree, all
# fail-silent (never abort, never hang on pinentry).
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"

TMPROOT=$(mktemp -d /tmp/wts-proof.XXXXXX)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# Subshells can't mutate a parent counter, so failures are appended to a marker
# file and tallied at the end.
FAILMARK="$TMPROOT/fails"
pass() { echo "  PASS($1): $2"; }
fail() { echo "  FAIL($1): $2"; echo "$1: $2" >> "$FAILMARK"; }

# Run inject_secrets in a fully isolated config/store, never the real one. Always
# bounded by an outer `timeout` so a pinentry hang fails the proof instead of
# wedging it. Echoes nothing; sets globals CONF/SECRETS/AUDIT/WT for the caller.
new_box() { # <repo>
  BOX=$(mktemp -d "$TMPROOT/box.XXXXXX")
  export XDG_CONFIG_HOME="$BOX/config"
  export FLEET_SESSION="wts-$$"
  CONF="$XDG_CONFIG_HOME/fleet"
  SECRETS="$CONF/secrets/$1"
  AUDIT="$CONF/secrets/audit.log"
  WT="$BOX/wt"
  mkdir -p "$SECRETS"
  git init -q "$WT"
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

inject() { # <repo> [extra-env...] — runs `fleet inject-secrets <repo> $WT`
  local repo="$1"; shift
  timeout 20 env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$@" \
    "$FLEET" inject-secrets "$repo" "$WT"
}

EXCL() { printf '%s' "$WT/.git/info/exclude"; }
perms() { stat -c '%a' "$1" 2>/dev/null; }

echo "== worktree-secrets-proof: honest same-uid v1 =="

# --- Scenario 1: happy path (CORE PROOF) --------------------------------------
( c=1
  new_box myapp
  printf 'SENTINEL_VALUE' > "$SECRETS/.env.local"
  out=$(inject myapp 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "exit 0" || fail "$c" "exit $rc ($out)"
  if [ -f "$WT/.env.local" ]; then pass "$c" "dest placed"; else fail "$c" "dest missing"; fi
  got=$(cat "$WT/.env.local" 2>/dev/null)
  [ "$got" = "SENTINEL_VALUE" ] && pass "$c" "content byte-exact" || fail "$c" "content='$got'"
  p=$(perms "$WT/.env.local"); [ "$p" = 600 ] && pass "$c" "perms 600" || fail "$c" "perms=$p"
  if grep -qF '.env.local' "$(EXCL)" 2>/dev/null; then pass "$c" "dest gitignored"
  else fail "$c" "dest not in info/exclude"; fi
  if git -C "$WT" status --porcelain 2>/dev/null | grep -qF '.env.local'; then
    fail "$c" "secret shows as committable in git status"
  else pass "$c" "git status ignores secret"; fi
) ; [ $? = 0 ] || true

# --- Scenario 2: no-read is tested HONESTLY -----------------------------------
# We ASSERT the agent CAN read — green here means "we are not lying to the user".
( c=2
  new_box myapp
  printf 'SENTINEL_VALUE' > "$SECRETS/.env.local"
  inject myapp >/dev/null 2>&1
  if cat "$WT/.env.local" >/dev/null 2>&1; then pass "$c" "agent CAN cat placed secret (no-read is false)"
  else fail "$c" "could not cat (unexpected)"; fi
  doc=$(XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$FLEET" doctor 2>&1)
  if printf '%s' "$doc" | grep -qiE 'same-uid|CAN read|not secrecy|cannot guarantee'; then
    pass "$c" "doctor prints honest threat-model caveat"
  else fail "$c" "doctor missing honest caveat"; fi
  # the docs must NOT claim AI cannot read
  if printf '%s' "$doc" | grep -qiE 'AI cannot read|agent cannot read'; then
    fail "$c" "doctor dishonestly claims AI cannot read"
  else pass "$c" "doctor makes no false no-read claim"; fi
) ; [ $? = 0 ] || true

# --- Scenario 3: missing pass entry degrades fail-silent ----------------------
( c=3
  new_box myapp
  export PASSWORD_STORE_DIR="$BOX/store"; mkdir -p "$PASSWORD_STORE_DIR"
  printf 'pass:fleet/myapp/db-url' > "$SECRETS/.env.local"   # entry does NOT exist
  out=$(inject myapp PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "exit 0 (worktree still created)" || fail "$c" "exit $rc"
  if [ ! -e "$WT/.env.local" ]; then pass "$c" "no sentinel masquerading as secret"
  else fail "$c" "empty/partial dest left behind"; fi
  if printf '%s' "$out" | grep -qiE 'warn|secret|missing'; then pass "$c" "warning emitted"
  else fail "$c" "no warning on stderr"; fi
  if grep -qE 'missing' "$AUDIT" 2>/dev/null; then pass "$c" "audit outcome=missing"
  else fail "$c" "audit did not record missing"; fi
) ; [ $? = 0 ] || true

# --- Scenario 4: gpg locked / pass unavailable --------------------------------
( c=4
  # 4a: entry EXISTS in store but decrypt fails (empty GNUPGHOME) -> gpg-locked
  new_box myapp
  export PASSWORD_STORE_DIR="$BOX/store"; mkdir -p "$PASSWORD_STORE_DIR/fleet/myapp"
  : > "$PASSWORD_STORE_DIR/fleet/myapp/db-url.gpg"   # entry present, undecryptable
  printf 'pass:fleet/myapp/db-url' > "$SECRETS/.env.local"
  out=$(inject myapp PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" GNUPGHOME="$BOX/emptygpg" 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "4a exit 0 (no hang on pinentry)" || fail "$c" "4a exit $rc ($out)"
  [ ! -s "$WT/.env.local" ] && pass "$c" "4a dest absent/empty-rejected" || fail "$c" "4a wrote a value"
  grep -qE 'gpg-locked|locked|fail' "$AUDIT" 2>/dev/null && pass "$c" "4a audit gpg-locked" || fail "$c" "4a no audit"

  # 4b: pass binary absent -> no-backend. Build a PATH that has every tool EXCEPT
  # pass (a symlink farm of the real bindirs minus `pass`), so `command -v pass`
  # genuinely fails while bash/coreutils/git still resolve.
  new_box myapp
  printf 'pass:fleet/myapp/db-url' > "$SECRETS/.env.local"
  FAKEBIN="$BOX/fakebin"; mkdir -p "$FAKEBIN"
  for d in /usr/bin /bin; do
    [ -d "$d" ] || continue
    for b in "$d"/*; do n=$(basename "$b"); [ "$n" = pass ] && continue
      [ -e "$FAKEBIN/$n" ] || ln -s "$b" "$FAKEBIN/$n" 2>/dev/null; done
  done
  out=$(timeout 20 env -i XDG_CONFIG_HOME="$XDG_CONFIG_HOME" HOME="$BOX" PATH="$FAKEBIN" \
        "$FLEET" inject-secrets myapp "$WT" 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "4b exit 0 (pass absent)" || fail "$c" "4b exit $rc ($out)"
  [ ! -s "$WT/.env.local" ] && pass "$c" "4b dest absent" || fail "$c" "4b wrote a value"
  grep -qE 'no-backend|backend|missing|fail' "$AUDIT" 2>/dev/null && pass "$c" "4b audit no-backend" || fail "$c" "4b no audit"
) ; [ $? = 0 ] || true

# --- Scenario 5: path-confinement (security, fail-CLOSED) ---------------------
( c=5
  # 5a: a symlink IN the secrets dir pointing outside $dir must never be followed
  new_box myapp
  mkdir -p "$BOX/outside"; printf 'PWNED' > "$BOX/outside/target"
  ln -s "$BOX/outside/target" "$SECRETS/evil"      # source entry is an escaping symlink
  out=$(inject myapp 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "5a exit 0 (per-file reject, not fatal)" || fail "$c" "5a exit $rc"
  if [ "$(cat "$BOX/outside/target")" = PWNED ]; then pass "$c" "5a nothing written outside (target intact)"
  else fail "$c" "5a target outside worktree was modified"; fi
  if [ ! -e "$WT/evil" ] || [ ! -L "$WT/evil" ]; then pass "$c" "5a no escaping symlink materialized"; else fail "$c" "5a symlink copied through"; fi

  # 5b: dest whose PARENT is a symlink escaping $dir -> realpath confinement rejects
  new_box myapp
  mkdir -p "$BOX/outside2"
  ln -s "$BOX/outside2" "$WT/link"                 # planted escaping dir at dest side
  mkdir -p "$SECRETS/link"; printf 'PWN2' > "$SECRETS/link/evil"
  out=$(inject myapp 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "5b exit 0" || fail "$c" "5b exit $rc"
  if [ ! -e "$BOX/outside2/evil" ]; then pass "$c" "5b nothing escaped via parent symlink"
  else fail "$c" "5b wrote through escaping parent symlink"; fi

  # 5c: DEEPER nested dest under an escaping parent symlink — mkdir -p must NOT
  # create any directory outside $dir before the rejection.
  new_box myapp
  mkdir -p "$BOX/outside3"
  ln -s "$BOX/outside3" "$WT/link"
  mkdir -p "$SECRETS/link/sub"; printf 'PWN3' > "$SECRETS/link/sub/evil"
  out=$(inject myapp 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "5c exit 0" || fail "$c" "5c exit $rc"
  if [ ! -e "$BOX/outside3/sub" ] && [ ! -e "$BOX/outside3/evil" ]; then
    pass "$c" "5c no dir/file created outside via deep parent symlink"
  else fail "$c" "5c mkdir/-write escaped the worktree"; fi

  # 5d: worktree path contains glob metachars ([]) — confinement must treat the
  # path literally (quoted case pattern), not as a character class, so a legit
  # secret still lands INSIDE.
  new_box myapp
  WT2="$BOX/wt[x]"; git init -q "$WT2"
  printf 'BRACKET' > "$SECRETS/.env.local"
  out=$(timeout 20 env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$FLEET" inject-secrets myapp "$WT2" 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "5d exit 0 (bracket path)" || fail "$c" "5d exit $rc"
  if [ "$(cat "$WT2/.env.local" 2>/dev/null)" = BRACKET ]; then pass "$c" "5d secret placed inside bracket path"
  else fail "$c" "5d confinement wrongly rejected a literal bracket path"; fi

  # 5e: a pre-planted SYMLINK at the dest (pointing at a decoy outside) must be
  # unlinked and replaced by a regular file — never written THROUGH.
  new_box myapp
  printf 'DECOY' > "$BOX/decoy"
  ln -s "$BOX/decoy" "$WT/.env.local"
  printf 'REALVAL' > "$SECRETS/.env.local"
  inject myapp >/dev/null 2>&1
  if [ ! -L "$WT/.env.local" ] && [ "$(cat "$WT/.env.local" 2>/dev/null)" = REALVAL ]; then
    pass "$c" "5e dest symlink replaced by regular file"
  else fail "$c" "5e wrote through a planted dest symlink"; fi
  [ "$(cat "$BOX/decoy" 2>/dev/null)" = DECOY ] && pass "$c" "5e decoy outside untouched" || fail "$c" "5e wrote through to decoy"
) ; [ $? = 0 ] || true

# --- Scenario 6: idempotency / re-run -----------------------------------------
( c=6
  new_box myapp
  printf 'V1' > "$SECRETS/.env.local"
  inject myapp >/dev/null 2>&1
  printf 'V2' > "$SECRETS/.env.local"              # change source between runs
  out=$(inject myapp 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "exit 0 on re-run" || fail "$c" "exit $rc"
  got=$(cat "$WT/.env.local" 2>/dev/null)
  [ "$got" = V2 ] && pass "$c" "re-run overwrote to new value" || fail "$c" "stale content='$got'"
  p=$(perms "$WT/.env.local"); [ "$p" = 600 ] && pass "$c" "perms stay 600" || fail "$c" "perms=$p"
  n=$(grep -cF '.env.local' "$(EXCL)" 2>/dev/null)
  [ "$n" = 1 ] && pass "$c" "no duplicate exclude lines (n=1)" || fail "$c" "exclude has $n lines"
) ; [ $? = 0 ] || true

# --- Scenario 7: no-config no-op (backward compat) ----------------------------
( c=7
  new_box myapp
  rm -rf "$SECRETS"                                 # repo, but NO secrets dir
  before=$(git -C "$WT" status --porcelain 2>/dev/null)
  out=$(inject myapp 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "exit 0 (no secrets dir)" || fail "$c" "exit $rc"
  after=$(git -C "$WT" status --porcelain 2>/dev/null)
  [ "$before" = "$after" ] && pass "$c" "zero new files (no regression)" || fail "$c" "worktree changed"
  [ ! -e "$AUDIT" ] || [ ! -s "$AUDIT" ] && pass "$c" "no-op leaves no audit churn" || pass "$c" "audit present (acceptable)"
) ; [ $? = 0 ] || true

# --- Scenario 8: fleet doctor (warn-only, never fatal on secrets state) -------
( c=8
  # baseline doctor with NO secrets configured
  new_box myapp; rm -rf "$CONF/secrets"
  XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$FLEET" doctor >/dev/null 2>&1; rc_base=$?
  # doctor with a BROKEN pass entry referenced
  new_box myapp
  export PASSWORD_STORE_DIR="$BOX/store"; mkdir -p "$PASSWORD_STORE_DIR"
  printf 'pass:fleet/myapp/db-url' > "$SECRETS/.env.local"
  doc=$(XDG_CONFIG_HOME="$XDG_CONFIG_HOME" PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" "$FLEET" doctor 2>&1); rc_sec=$?
  [ "$rc_sec" = "$rc_base" ] && pass "$c" "broken secret does not change doctor rc ($rc_base)" \
    || fail "$c" "secrets state changed rc ($rc_base -> $rc_sec)"
  printf '%s' "$doc" | grep -qiE 'pass' && pass "$c" "doctor reports pass state" || fail "$c" "no pass line"
  printf '%s' "$doc" | grep -qiE 'same-uid|CAN read' && pass "$c" "doctor prints honest caveat" || fail "$c" "no caveat"
  printf '%s' "$doc" | grep -qiE 'db-url' && pass "$c" "doctor checks referenced entry" || fail "$c" "entry not checked"
) ; [ $? = 0 ] || true

# --- Scenario 9: dest matches a git-TRACKED file (loop-2 GAP 1) ---------------
# A repo that SHIPS a placeholder config the user overrides locally is a legit
# common case — injection must NOT refuse it, but the local secret value must be
# uncommittable. info/exclude is powerless for tracked paths, so the fix flags the
# dest skip-worktree. Assert: value present locally, `git status` clean / not
# committable / not stageable, audit ok.
( c=9
  new_box myapp
  printf 'PLACEHOLDER\n' > "$WT/.env"                 # repo ships a tracked placeholder
  git -C "$WT" add .env
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m 'ship placeholder .env'
  printf 'REAL_SECRET_VALUE' > "$SECRETS/.env"        # injected local override
  out=$(inject myapp 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "exit 0" || fail "$c" "exit $rc ($out)"
  got=$(cat "$WT/.env" 2>/dev/null)
  [ "$got" = REAL_SECRET_VALUE ] && pass "$c" "local secret value present" || fail "$c" "content='$got'"
  if git -C "$WT" status --porcelain 2>/dev/null | grep -qF '.env'; then
    fail "$c" "tracked secret shows as committable in git status"
  else pass "$c" "git status clean — tracked secret not committable"; fi
  git -C "$WT" add .env 2>/dev/null || true
  if git -C "$WT" diff --cached --name-only 2>/dev/null | grep -qF '.env'; then
    fail "$c" "tracked secret got staged"
  else pass "$c" "tracked secret cannot be staged"; fi
  grep -qE '	ok$' "$AUDIT" 2>/dev/null && pass "$c" "audit outcome=ok for tracked dest" || fail "$c" "audit not ok"
) ; [ $? = 0 ] || true

# --- Scenario 10: dest collides with an existing DIRECTORY (loop-2 GAP 2) ------
# cp would drop the file INSIDE the dir and chmod 600 would strip exec from the
# directory → worktree corruption. Must REFUSE: real failure (audit != ok), exit 0,
# directory perms untouched, tracked file under it still readable, no exclude line.
( c=10
  new_box myapp
  mkdir -p "$WT/config"
  printf 'IMPORTANT\n' > "$WT/config/keep"
  git -C "$WT" add config/keep
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m 'ship config dir'
  dperm_before=$(perms "$WT/config")
  printf 'SHOULD_NOT_LAND' > "$SECRETS/config"        # rel path collides with the dir
  out=$(inject myapp 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "exit 0 (per-file refuse, not fatal)" || fail "$c" "exit $rc ($out)"
  [ -d "$WT/config" ] && pass "$c" "dest still a directory" || fail "$c" "directory clobbered"
  dperm_after=$(perms "$WT/config")
  [ "$dperm_before" = "$dperm_after" ] && pass "$c" "directory perms unchanged ($dperm_before)" \
    || fail "$c" "dir perms $dperm_before -> $dperm_after"
  [ ! -e "$WT/config/config" ] && pass "$c" "no file cp'd into the directory" || fail "$c" "file landed inside dir"
  got=$(cat "$WT/config/keep" 2>/dev/null)
  [ "$got" = IMPORTANT ] && pass "$c" "tracked file under dir still readable" || fail "$c" "tracked file corrupted='$got'"
  grep -qE 'dir-collision' "$AUDIT" 2>/dev/null && pass "$c" "audit outcome=dir-collision" || fail "$c" "audit missing dir-collision"
  if grep -qE '	ok$' "$AUDIT" 2>/dev/null; then fail "$c" "audit wrongly recorded ok"; else pass "$c" "audit not ok"; fi
  if grep -qxF '/config' "$(EXCL)" 2>/dev/null; then fail "$c" "refused placement still excluded"; else pass "$c" "no exclude line for refused dir"; fi
) ; [ $? = 0 ] || true

# --- Scenario 11: `pass:` directive with CRLF line endings (footgun 1) --------
# A secret file authored on Windows ends the directive with \r\n, so `head -1`
# keeps a trailing \r and the parsed entry becomes `…\r` — the pass lookup then
# misses and the secret is audited `missing` instead of resolving. The directive
# parse must tolerate (strip) the CR. Uses a throwaway batch GPG key + pass store;
# the DECRYPTED value must land byte-exact (and NO CR may leak into it).
( c=11
  type -P gpg >/dev/null 2>&1 && type -P pass >/dev/null 2>&1 || { pass "$c" "gpg/pass absent — scenario skipped"; exit 0; }
  new_box myapp
  export GNUPGHOME="$BOX/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  export PASSWORD_STORE_DIR="$BOX/store"
  gpg --batch --pinentry-mode loopback --passphrase '' \
      --quick-generate-key 'Fleet Test <test@fleet>' default default never >/dev/null 2>&1
  keyid=$(gpg --homedir "$GNUPGHOME" --list-keys --with-colons test@fleet 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
  if [ -z "$keyid" ]; then pass "$c" "could not mint throwaway key — scenario skipped"; gpgconf --homedir "$GNUPGHOME" --kill gpg-agent 2>/dev/null; exit 0; fi
  # NB: the harness defines pass()/fail() shell functions that shadow the `pass`
  # password-manager binary — use `command pass` here to reach the real tool.
  command pass init "$keyid" >/dev/null 2>&1
  printf 'DECRYPTED_SENTINEL_VALUE' | command pass insert -m -f fleet/myapp/db-url >/dev/null 2>&1
  printf 'pass:fleet/myapp/db-url\r\n' > "$SECRETS/.env.local"        # CRLF directive
  out=$(inject myapp PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" GNUPGHOME="$GNUPGHOME" 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "exit 0" || fail "$c" "exit $rc ($out)"
  if [ -f "$WT/.env.local" ]; then pass "$c" "dest placed (CRLF directive resolved)"; else fail "$c" "dest missing — CR broke the pass lookup"; fi
  got=$(cat "$WT/.env.local" 2>/dev/null)
  [ "$got" = "DECRYPTED_SENTINEL_VALUE" ] && pass "$c" "decrypted value byte-exact" || fail "$c" "content='$got'"
  if grep -qE '	ok$' "$AUDIT" 2>/dev/null; then pass "$c" "audit outcome=ok"; else fail "$c" "audit not ok (recorded missing?)"; fi
  if grep -qE '	missing$' "$AUDIT" 2>/dev/null; then fail "$c" "audit wrongly recorded missing (CR not stripped)"; else pass "$c" "audit not missing"; fi
  gpgconf --homedir "$GNUPGHOME" --kill gpg-agent 2>/dev/null
) ; [ $? = 0 ] || true

# --- Scenario 12: newline in a secret's source filename (footgun 2) -----------
# A `$rel` containing a newline cannot be written as a single git info/exclude
# line (`printf '/%s\n'` splits it), corrupting the exclude + the dedup grep. Such
# a name is a mistake/attack and must be REJECTED early (nothing written, audit
# `bad-name`, exit 0), the exclude must gain NO split/garbage line, AND a SOUND
# secret in the same run must still land (mid-list isolation — `continue`, not abort).
( c=12
  new_box myapp
  printf 'GOODVAL' > "$SECRETS/.env.good"                            # well-formed sibling
  : > "$SECRETS/$(printf 'bad\nname')"                               # source name has a newline
  out=$(inject myapp 2>&1); rc=$?
  [ "$rc" = 0 ] && pass "$c" "exit 0 (per-file reject, not fatal)" || fail "$c" "exit $rc ($out)"
  # exactly ONE secret file placed (the good one); the bad-name file wrote nothing.
  cnt=$(find "$WT" -mindepth 1 -type f -not -path "$WT/.git/*" -print0 2>/dev/null | tr -dc '\0' | wc -c)
  [ "$cnt" = 1 ] && pass "$c" "only the sound secret landed (count=1)" || fail "$c" "$cnt files placed — bad-name file was written"
  [ "$(cat "$WT/.env.good" 2>/dev/null)" = GOODVAL ] && pass "$c" "sibling secret still lands (mid-list isolation)" || fail "$c" "sound secret missing"
  grep -qE 'bad-name' "$AUDIT" 2>/dev/null && pass "$c" "audit outcome=bad-name" || fail "$c" "audit missing bad-name"
  # the split second half of the rel ('name') must NOT appear as an exclude line.
  if grep -qxF 'name' "$(EXCL)" 2>/dev/null; then fail "$c" "exclude gained a split garbage line"; else pass "$c" "no split/garbage exclude line"; fi
  grep -qxF '/.env.good' "$(EXCL)" 2>/dev/null && pass "$c" "sound secret excluded normally" || fail "$c" "sound secret not excluded"
) ; [ $? = 0 ] || true

N=0; [ -f "$FAILMARK" ] && N=$(wc -l < "$FAILMARK" 2>/dev/null | tr -d ' '); N=${N:-0}
echo "== summary: $N failed =="
if [ "$N" = 0 ]; then echo "RESULT: ALL PASS — worktree-secrets v1 proven."; exit 0
else echo "RESULT: $N assertion(s) FAILED."; exit 1; fi

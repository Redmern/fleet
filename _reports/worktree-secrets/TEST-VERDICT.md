# worktree-secrets — ADVERSARY LOOP-3 verdict

**VERDICT: NEEDS-WORK** (overwrites the prior DONE)

Commit under test: `32832de` (`fix(secrets): refuse secret dest inside .git/`), branch `fleet/worktree-secrets`.
Target: `inject_secrets` / `fleet inject-secrets <repo> <dir>` in `bin/fleet`.
Repro harness: `_reports/worktree-secrets/ADV-LOOP3-repro.sh` (fully /tmp-isolated; XDG_CONFIG_HOME + PASSWORD_STORE_DIR + GNUPGHOME under mktemp; throwaway repos; binary by absolute path; nothing real touched).

---

## FINDING — the loop-3 `.git` refusal is bypassable via a committed parent symlink (code execution)

**Severity: MEDIUM** (lands a live `.git/hooks/post-checkout` → code execution on the next git op; reaches the *exact* outcome the loop-3 fix exists to prevent, but requires an attacker-controlled committed symlink co-located with a user secret).

### Root cause
The loop-3 fix matches a literal `.git` component on the **source-relative** path:

```sh
case "/$rel/" in
  */.git/*) ... refuse git-dir ;;
esac
```

But `rel` is never resolved. The only resolution step — realpath-confinement — checks that the dest stays **inside `$dir`**, and `$dir/.git` *is* inside `$dir`, so it **passes** anything that resolves into the control dir:

```sh
destr=$(realpath "$destdir" ...)
case "$destr" in "$dirr"|"$dirr"/*) ;; *) reject ;; esac   # .git is inside $dirr → ALLOWED
```

So a worktree path component that is a **symlink to `.git`** routes a `rel` with **no literal `.git`** straight into the git dir. Source symlinks are rejected (`[ -L "$f" ]`) and `find` doesn't descend symlinks — but this symlink lives in the **destination worktree** (checked out from the base branch), not in the secrets source, so neither guard fires.

### Exact repro (A3 in the harness)
1. Base branch of the repo contains a committed symlink `foo -> .git` (git checks it out fine; git's own symlink-into-.git CVE guards don't apply — `inject_secrets` writes with `cp`, not git).
2. User has a secret at `~/.config/fleet/secrets/<repo>/foo/hooks/post-checkout` (plain dir `foo/`, plain file — `rel=foo/hooks/post-checkout`, no `.git` component).
3. `fleet inject-secrets <repo> <wt>` → `cp` follows `foo` → writes `<wt>/.git/hooks/post-checkout`.

Harness output (real binary):
```
--- A3: PARENT SYMLINK to .git committed in base branch (THE attack) ---
  ** FAIL: A3 *** secret landed a git hook via committed symlink parent ***
      dest resolved: .../wt/.git/hooks/post-checkout
--- A4: parent symlink to .git, single file (foo -> .git, secret foo/config) ---
  ** FAIL: A4 wrote .../wt/.git/config-injected (inside real git dir)
```
A4 is the same hole writing an arbitrary file inside `.git/` (e.g. clobbering `config`).

### One-line(-class) fix — confine the RESOLVED dest against the gitdir
Right after the post-`mkdir` confinement re-check (the `# inside the worktree → ok` esac), also reject when the resolved `destdir` lands inside the gitdir or the common-dir:

```sh
for __g in "$(realpath "$dir/.git" 2>/dev/null)" "$(realpath "$common" 2>/dev/null)"; do
  [ -n "$__g" ] || continue
  case "$destr/" in "$__g/"|"$__g"/*)
    printf 'fleet: secret %s resolves into a git dir, refused\n' "$rel" >&2
    audit_secret "$audit" "$repo" "$rel" git-dir; continue 2 ;;
  esac
done
```

Verified: this patch closes A3 + A4, keeps every legit case (`.gitfoo`/`.gitignore` not over-rejected, mid-list isolation, R1/R2/R5), and the **full official 13-scenario proof harness still reports `0 failed`**. (Keep the existing source-relative `.git` pattern too — it's the cheap fail-fast for the common literal case.)

---

## What ELSE I tried and could NOT break (these hold)

- **A1 literal `.git/hooks/post-checkout`** — refused, audited `git-dir`. ✔
- **A2 / A8 bare top-level file named `.git`** (plain repo and linked-worktree `.git`-is-a-file layout) — refused. ✔
- **A5 case/spelling on this ext4 (case-sensitive) box** — `.GIT`, `.git.`, `.git ` (trailing space) are *distinct, inert* directories; none reached the real `.git`. `.gitfoo` and `.gitignore` are correctly **not** over-rejected (placed fine). ✔
  - ⚠ **Portability caveat (not a finding on this Linux box):** `*/.git/*` is case-sensitive and exact. On a **case-insensitive FS** (macOS default) `.GIT` ≡ `.git`; on **Windows** trailing dot/space are stripped so `.git.`/`.git ` ≡ `.git`. The gitdir-confinement fix above closes these too (it resolves the real path). Worth a one-line code comment; out of scope for the single-user Linux target.
- **A6 mid-list isolation** — a `.git` reject `continue`s, never `break`/aborts (no `set -e`); secrets before *and* after the rejected one still land. ✔
- **A7 symlink SOURCE named `.git` → real dir** — rejected (the `.git` pattern fires before `[ -L ]`, and `[ -L ]` would catch it anyway). ✔
- **R1 GAP1 skip-worktree** — tracked dest overwritten, hidden from `git status`, skip-worktree bit set. ✔
- **R2 GAP2 dir-collision** — refused loudly, worktree dir intact, audited `dir-collision`. ✔
- **R3 audit** — logs only `ts/repo/rel/outcome`; no secret value present. ✔
- **R4 fail-silent** — missing `pass` entry → exit 0, no dest written. ✔
- **R5 escape-to-external symlink** — committed `out -> /external` parent rejected by confinement; secret did not escape the worktree. ✔ (Note: this same confinement is exactly what *fails open* for `.git` in A3/A4, because `.git` is *inside* the worktree — hence the fix.)

## Bottom line
The loop-3 fix correctly closes the literal-name `.git` route but not the resolved-path route to the same control dir. That is a real, demonstrated way to land a git hook → **NEEDS-WORK**. The fix is small, validated, and non-regressive against the full proof harness.

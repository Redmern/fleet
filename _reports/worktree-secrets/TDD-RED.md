# TDD-RED — worktree-secrets

## Loop-2 — dest-already-exists blind spot (GAP 1 + GAP 2)

Test adversary returned NEEDS-WORK: `inject_secrets`'s placement loop never
checked whether `$dest` was a git-tracked file or an existing directory before
`rm`/`cp`/`chmod`. Two failing scenarios added to `test/worktree-secrets-proof.sh`
FIRST, run against the pre-fix code:

### Scenario 9 — dest matches a git-TRACKED file (GAP 1, med-high)
Repo ships a tracked placeholder `.env`; injected secret overwrites it with the
real value. `.git/info/exclude` is powerless for tracked paths → secret shows as
committable `M .env`.

### Scenario 10 — dest collides with an existing DIRECTORY (GAP 2, med)
`rm -f` can't remove a dir, `cp` drops the file INSIDE it, `chmod 600` strips
exec from the directory → worktree corruption, falsely audited `ok`.

### RED output (against commit 1dbd194, fixes NOT yet applied)

```
  FAIL(9): tracked secret shows as committable in git status
  FAIL(9): tracked secret got staged
  FAIL(10): dir perms 755 -> 600
  FAIL(10): tracked file corrupted=''
  FAIL(10): audit missing dir-collision
  FAIL(10): audit wrongly recorded ok
  FAIL(10): refused placement still excluded
== summary: 7 failed ==
RESULT: 7 assertion(s) FAILED.
```

All 7 failures isolated to the two new scenarios; scenarios 1–8 (prior loop) still
GREEN — no existing assertion weakened. Scenario 10's `tracked file corrupted=''`
is the smoking gun: `chmod 600` on the directory removed traversal (`x`), so the
tracked `config/keep` under it became unreadable.

## Loop-3 — dest inside `.git/` bypasses confinement (one-line fix)

The realpath confinement only proves the dest stays inside `$dir`; but `$dir/.git`
*is* inside `$dir`, so a secret whose rel path lands under `.git/` (e.g.
`.git/hooks/pre-commit` → code execution on next commit, or a clobbered
`.git/config`) sails straight through. Scenario 13 added to
`test/worktree-secrets-proof.sh` FIRST.

### RED output (guard NOT yet added)

```
  FAIL(13): secret written INTO .git/ (hook planted)
  FAIL(13): git-dir not audited as failure
  FAIL(13): refused git-dir placement still excluded
== summary: 3 failed ==
RESULT: 3 assertion(s) FAILED.
```

3 failures isolated to scenario 13; scenarios 1–12 still GREEN.

## Loop-4 — resolved-path `.git` bypass via committed parent symlink

Adversary loop-3 verdict (NEEDS-WORK, MEDIUM): the loop-3 guard matches a literal
`.git` component on the SOURCE-relative `rel`, but `rel` is never resolved. A
symlink committed in the base branch (`foo -> .git`) routes a rel with NO literal
`.git` (`foo/hooks/post-checkout`) into the real git dir — `cp` follows it, and the
realpath confinement passes because `.git` IS inside `$dir`. Lands a live hook →
code execution. The source-symlink guard can't fire (the symlink is in the DEST
worktree, not the secrets source). Scenarios 14 (attack) and 15 (lookalike
over-rejection guard-rail) added FIRST.

### RED output (gitdir confinement NOT yet added)

```
  FAIL(14): A3 hook planted in .git via committed symlink parent
  FAIL(14): A4 arbitrary file written inside real .git
  FAIL(14): resolved git-dir not audited as failure
  FAIL(14): refused placement still excluded
== summary: 4 failed ==
RESULT: 4 assertion(s) FAILED.
```

4 failures isolated to scenario 14; scenarios 1–13 and 15 GREEN throughout —
scenario 15 is deliberately green in RED too (it proves the fix must not
over-reject `.gitignore`/`.gitfoo`).

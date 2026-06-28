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

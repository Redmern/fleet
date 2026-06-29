# TDD-GREEN — worktree-secrets

## Loop-2 — dest-already-exists fixes (GAP 1 + GAP 2)

Both fixes applied to `inject_secrets` in `bin/fleet`:

### GAP 2 — directory-collision refusal (before `rm`/`cp`)
```sh
if [ -d "$dest" ] && [ ! -L "$dest" ]; then
  printf 'fleet: secret %s dest is a directory, refused\n' "$rel" >&2
  audit_secret "$audit" "$repo" "$rel" dir-collision; continue
fi
```
A real directory at `$dest` is refused — stderr warn, audit `dir-collision` (a REAL
failure, never `ok`), `continue`. Symlink-to-dir excluded (`! -L`) so the existing
unlink-and-replace path still handles planted symlinks.

### GAP 1 — tracked dest → skip-worktree (after a successful write)
A tracked dest (repo ships a placeholder the user overrides locally) is a LEGIT
common case — NOT refused. info/exclude is powerless for tracked paths, so the
write/protect block now splits on tracked-ness and is gated on `outcome=ok`:
```sh
if [ "$outcome" = ok ]; then
  chmod 600 "$dest" 2>/dev/null || true
  if git -C "$dir" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    git -C "$dir" update-index --skip-worktree -- "$rel" 2>/dev/null || true
  elif [ -n "$excl" ]; then
    grep -qxF "/$rel" "$excl" 2>/dev/null || printf '/%s\n' "$rel" >>"$excl" 2>/dev/null || true
  fi
fi
```
**skip-worktree vs assume-unchanged:** skip-worktree is the intended "I have local
changes I never intend to commit" flag (git keeps the local value out of `git add`
/`git status`); assume-unchanged is only a perf hint git may silently clear.
Caveat noted in-code: an upstream change to a tracked+skip-worktree path can
conflict on later merge/checkout — acceptable for a deliberately-overridden value.

### Minor — no exclude line for failed placements
Folding the info/exclude append inside `if [ "$outcome" = ok ]` means
missing / gpg-locked / no-backend / dir-collision placements no longer add a
`/rel` line for a file that was never written.

### GREEN output (fixes applied)

```
  PASS(10): no exclude line for refused dir
== summary: 0 failed ==
RESULT: ALL PASS — worktree-secrets v1 proven.
```

**55 PASS / 0 FAIL.** Scenarios 1–8 (prior loop) unchanged and still green — no
existing assertion weakened. `bash -n bin/fleet` clean. Fail-silent preserved
(every git call `2>/dev/null || true`; the only fail-CLOSED point remains the
realpath confinement). NOT merged.

## Loop-3 — `.git/` confinement guard (one-line case)

Added before the symlink check in `inject_secrets`:
```sh
case "/$rel/" in
  */.git/*) printf 'fleet: secret %s targets a git dir, refused\n' "$rel" >&2
     audit_secret "$audit" "$repo" "$rel" git-dir; continue ;;
esac
```
Wrapping the rel path in `/…/` makes `.git`, `.git/hooks/x`, `sub/.git`, and
`sub/.git/x` all match `*/.git/*` — refusing any `.git` path component (top-level
worktree git dir or a nested submodule's) before any rm/cp. Outcome audited
`git-dir` (a REAL failure, never ok); no exclude line for the refused placement;
a sound sibling in the same run still lands (`continue`, not abort).

### GREEN output

```
== summary: 0 failed ==
RESULT: ALL PASS — worktree-secrets v1 proven.
```
**71 PASS / 0 FAIL.** Scenarios 1–12 unchanged and still green. `bash -n bin/fleet`
clean. Fail-silent preserved (the fail-CLOSED confinement points are unchanged
in spirit — this just extends them to the git dir). NOT merged.

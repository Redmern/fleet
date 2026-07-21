# TEST-b — `fleet new-project` wizard: acceptance + negative / failure-mode checks

**Tester:** B (independent)
**Binary:** `/home/red/proj/pc-tune/fleet/new-project-create/bin/fleet`
**Code under test:** `new_bare_repo` (bin/fleet:128-147), `cmd_new_project` (bin/fleet:421-467), `cmd_pick_project` (bin/fleet:392-419), dispatch `new-project)` (bin/fleet:4147).
**Spec intent:** "Fail-silent throughout (clean backout on bad/unwritable path, name clash, non-empty target). fleet never hard-crashes." Every invocation must exit 0.

## Sandbox

```
export HOME=$(mktemp -d)/home; mkdir -p "$HOME"
unset XDG_CONFIG_HOME TMUX FLEET_SESSION FLEET_ROOT
CONF_DIR=$HOME/.config/fleet      # projects/<name>.yml
PROJ=$(mktemp -d)                 # all project dirs under here
```

No real `~/.config/fleet`, no live tmux session touched. Wizard driven non-interactively via `printf ... | fleet new-project`. In non-interactive mode the wizard creates the project but skips the tmux boot (`cmd_up`), printing `(non-interactive: skipped boot ...)`.

---

## CHECK 1 — DUPLICATE PROJECT NAME  ⚠ SPEC VIOLATION

Two distinct project dirs whose basename is both `myproj`.

```
# run 1: dir=$PROJ/X/myproj repo=alpha
printf '%s\nalpha\n\n' "$PROJ/X/myproj" | fleet new-project
  created repo 'alpha'
  created project 'myproj' -> /tmp/.../X/myproj (1 repo(s))
exit1=0

# yml after run 1:
name: myproj
root: /tmp/.../X/myproj

# run 2: dir=$PROJ/Y/myproj repo=beta
printf '%s\nbeta\n\n' "$PROJ/Y/myproj" | fleet new-project
  created repo 'beta'
  created project 'myproj' -> /tmp/.../Y/myproj (1 repo(s))
exit2=0

# yml after run 2:
name: myproj
root: /tmp/.../Y/myproj          <-- SILENTLY OVERWRITTEN
```

`$CONF_DIR/projects/` contains a single `myproj.yml`, now pointing at the **second** (`Y`) root. The first project's saved entry is gone.

**Result: the spec's "name clash → refused" intent is NOT met.** `cmd_new_project` derives the name from the basename (`name=$(basename "$pdir" | tr -cd ...)`, bin/fleet:454) and writes `$CONF_DIR/projects/$name.yml` with **no existence check** (bin/fleet:457-459) — it unconditionally `printf ... > "$yml"`. A second project with a colliding basename clobbers the first's yml. Exit code is still 0 (fail-silent in the no-crash sense), but the documented "refused on name clash" behaviour is absent.

**Pin:** bin/fleet:457-459 (no `[ -e "$yml" ]` guard before the redirect).

**PASS** for "never hard-crashes" / exit 0. **FAIL** for spec "refused on name clash".

---

## CHECK 2 — REPO NAME ALREADY EXISTS  ✅

(a) Same repo name twice in one run:
```
printf '%s\nalpha\nalpha\n\n' "$PROJ/dupRepo" | fleet new-project
  created repo 'alpha'
  'alpha' already exists, skipped
  created project 'dupRepo' -> ... (1 repo(s))
exit=0
# repo dirs: only one 'alpha'
```
Second `alpha` hits the `[ -e "$pdir/$repo" ]` guard (bin/fleet:447) → "already exists, skipped". Count stays 1. Not corrupted.

(b) Pre-existing dir at `$pdir/gamma` (with a `keep` file), then add repo `gamma`:
```
mkdir -p "$P/gamma"; touch "$P/gamma/keep"
printf '%s\ny\ngamma\n\n' "$P" | fleet new-project   # 'y' = use non-empty proj dir
  'gamma' already exists, skipped
  created project 'proj2b' -> ... (0 repo(s))
exit=0
# $P/gamma still holds only 'keep', has NO .git
```
Existing repo-named dir is left untouched; `new_bare_repo` is never invoked over it. **PASS**.

---

## CHECK 3 — NON-EMPTY TARGET DIR  ✅

Project dir pre-seeded with `existing.txt`.

```
# decline with 'n'
printf '%s\nn\n' "$P3" | fleet new-project   -> "fleet: cancelled"   exit=0   yml: NO
# decline with blank
printf '%s\n\n' "$P3" | fleet new-project    -> "fleet: cancelled"   exit=0   yml: NO
# proceed with 'y' + repo delta
printf '%s\ny\ndelta\n\n' "$P3" | fleet new-project
  created repo 'delta'
  created project 'nonempty' -> ... (1 repo(s))   exit=0   yml: YES
  $P3/delta/.git present: YES
```
Both branches of the `use it anyway? [y/N]` prompt (bin/fleet:433-437) behave: decline → "cancelled", no yml; accept → proceeds, yml written, repo created. **PASS**.

---

## CHECK 4 — INVALID / EMPTY / TRAVERSAL REPO NAMES  ✅ (no traversal)

Fed `''`, `'   '`, `'@@@'`, `'../escape'`, `'a/b'` (plus a valid `zeta` to prove the loop continues):
```
printf '%s\nzeta\n../escape\na/b\n@@@\n\n' "$P4" | fleet new-project
  created repo 'zeta'
  created repo '..escape'
  created repo 'ab'
  invalid name, skipped              # the @@@ (and empty/whitespace) case
  created project 'badrepos4' -> ... (3 repo(s))
exit=0
# contents of $P4:  ..escape/  ab/  zeta/   (all bare repos, all INSIDE $pdir)
```

Sanitization (`tr -cd 'a-zA-Z0-9_.-'`, bin/fleet:445) results:

| input        | sanitized | outcome |
|--------------|-----------|---------|
| `""`         | `""`      | empty → "invalid name, skipped", no dir |
| `"   "`      | `""`      | empty → "invalid name, skipped", no dir |
| `"@@@"`      | `""`      | empty → "invalid name, skipped", no dir |
| `"../escape"`| `..escape`| created as bare repo `$pdir/..escape` (literal, slash stripped) |
| `"a/b"`      | `ab`      | created as bare repo `$pdir/ab` (slash stripped) |

**No path traversal.** The `/` is stripped by `tr`, so `../escape` becomes the harmless literal directory name `..escape` and `a/b` becomes `ab`; both stay inside `$pdir`. Verified parent (`$PROJ`) gained no `escape`/`ab` dir, and `new_bare_repo "$TROOT" "..escape"` builds `$TROOT/..escape`, not `$TROOT/../escape`.

**Extra edge probed — names that sanitize to pure dots** (the only real traversal vector, since `tr` keeps `.`):

| input    | sanitized | outcome |
|----------|-----------|---------|
| `..`     | `..`      | `[ -e "$pdir/.." ]` is always true → "already exists, skipped" (NOT created) |
| `.`      | `.`       | `[ -e "$pdir/." ]` always true → "already exists, skipped" (NOT created) |
| `../..`  | `....`    | harmless literal dir `$pdir/....` created |

The dangerous `.`/`..` cases are blocked by the `[ -e "$pdir/$repo" ]` existence guard (bin/fleet:447) before `new_bare_repo` is ever called — parent dir is never turned into a repo. No traversal occurred in any case. **PASS** (safe, though the safety net for `.`/`..` is the existence check, not the sanitizer — see Notes).

---

## CHECK 5 — EMPTY PROJECT DIR INPUT  ✅

```
printf '\n' | fleet new-project
  fleet: cancelled (no directory)
exit=0
# no new yml written
```
Blank first line hits `[ -n "$pdir" ] || { echo "fleet: cancelled (no directory)"; return 0; }` (bin/fleet:430). **PASS**.

---

## CHECK 6 — UNWRITABLE PATH  ✅

```
mkdir -p "$HOME/ro"; chmod 000 "$HOME/ro"
printf '%s\n\n' "$HOME/ro/proj" | fleet new-project
  fleet: cannot create /tmp/.../home/ro/proj
exit=0
# yml for 'proj': NOT written
chmod 755 "$HOME/ro"   # restored
```
`mkdir -p "$pdir" 2>/dev/null || { echo "fleet: cannot create $pdir" >&2; return 0; }` (bin/fleet:438) fires; graceful message, exit 0, no yml, no crash. (The `[ -w "$pdir" ]` branch at :439 covers the create-succeeds-but-unwritable case.) **PASS**.

---

## CHECK 7 — `fleet doctor` REGRESSION  ✅

```
fleet doctor; echo exit=$?
ok   tmux / nvim / git / python3 / fzf / notify-send / tmuxinator(optional)
ok   claude-profile / harness: claude / harness: omp / default harness: claude
ok   fleetd socket / fleet-hook -> .../bin/fleet-hook / fleetd.service enabled
ok   tmux prefix: C-s (leader: prefix+F)
exit=0
```
Completes cleanly, command structure intact, exit 0. **PASS**.

---

## CHECK 8 — SYNTAX  ✅

```
bash -n bin/fleet; echo syntax=$?   ->   syntax=0
```
No syntax regression. **PASS**.

---

## PASS / FAIL TABLE

| # | Check | Exit 0 / no crash | Spec behaviour | Verdict |
|---|-------|-------------------|----------------|---------|
| 1 | Duplicate project name | yes (exit 0) | yml silently **overwritten**, not refused | **FAIL (spec)** |
| 2 | Repo name already exists | yes | 2nd skipped; existing dir untouched | PASS |
| 3 | Non-empty target dir (y / n / blank) | yes | both branches correct | PASS |
| 4 | Invalid/empty/traversal repo names | yes | sanitized, empties skipped, **no traversal** | PASS |
| 5 | Empty project dir input | yes | "cancelled (no directory)", no yml | PASS |
| 6 | Unwritable path | yes | "cannot create", no yml, graceful | PASS |
| 7 | `fleet doctor` regression | yes | completes, structure intact | PASS |
| 8 | `bash -n` syntax | n/a | syntax=0 | PASS |

## Spec violations found

- **CHECK 1 (duplicate project name):** spec says clean backout / refuse on name clash; instead the wizard **silently overwrites** `$CONF_DIR/projects/<name>.yml` when a new project's basename collides with an existing saved project. The first project's saved root is lost. No existence guard before the write. **bin/fleet:457-459.** (Does not crash — exit 0 — so it satisfies "never hard-crashes" but not "refused".)

## Notes / latent risk (not a failure here)

- The `.`/`..` repo-name traversal vector is neutralized only by the `[ -e "$pdir/$repo" ]` existence check (bin/fleet:447), since `tr -cd 'a-zA-Z0-9_.-'` deliberately keeps `.`. It holds today, but a future refactor that reorders/removes that guard (or a name like `...` → already harmless) could re-expose dot-name handling. Defensive hardening would be to also reject names matching `^\.+$` in the sanitizer at bin/fleet:445-446. Low priority; no exploit found.

## Verdict

**One spec violation (CHECK 1, duplicate project name silently overwrites the yml — bin/fleet:457-459); all other acceptance/negative/failure-mode checks PASS, no path traversal, no hard crash, every invocation exits 0.**

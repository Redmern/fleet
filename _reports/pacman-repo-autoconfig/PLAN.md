# PLAN — eliminate the manual `/etc/pacman.conf` edit when installing fleet

**Status:** research only. No code written, no tracked file modified.
**Goal:** a new (non-dev) Arch machine installs fleet with zero hand-editing of
`/etc/pacman.conf`.
**Scope note:** the dev box (this machine) deliberately keeps the worktree +
`~/.local/bin` symlink install which shadows `/usr/bin/fleet` on PATH. Nothing
here touches that; see §1.4 for why that constraint nearly kills half the
orchestrator's leaning.

---

## 0. Confirmation of the given context (all verified by reading)

| Claim | Verified at |
|---|---|
| fleet is already distributed via pacman as `fleet-git`, a VCS package with `pkgver()` → `r<commits>.<shorthash>` | `packaging/PKGBUILD:9`, `:53-59` |
| post-install scriptlet prints `fleet setup` guidance | `packaging/fleet-git.install:1-22` |
| CI builds in an `archlinux:latest` container and publishes DB + package to a **mutable** release tagged `repo` | `.github/workflows/pacman-repo.yml:43`, `:51` (`REPO_TAG: repo`), `:96-154` |
| the four DB assets are `fleet.db`, `fleet.files`, `fleet.db.tar.gz`, `fleet.files.tar.gz` | `.github/workflows/pacman-repo.yml:126-134` |
| install is documented as (a) hand-append a stanza, (b) `pacman -S fleet-git` | `docs/custom-repo.md:21-40`, `:74-84` |
| step (a) is the only manual step | `docs/custom-repo.md:40` — *"Edit with: `sudo ${EDITOR:-nano} /etc/pacman.conf`"* |
| pc-tune `bootstrap.sh` prereq comment still says clone fleet + run `install.sh` | `/home/red/proj/pc-tune/bootstrap.sh:14-19` |

Live facts gathered beyond the brief (these change the design materially):

1. **The `repo` release exists and is populated right now.** `gh release view repo`
   returns `fleet-git-r207.041e14b-1-any.pkg.tar.zst` plus all four DB assets. The
   channel is live, not hypothetical.
2. **`Redmern/fleet` is PUBLIC** (`gh repo view` → `"visibility":"PUBLIC"`), and an
   unauthenticated `curl` of `raw.githubusercontent.com/Redmern/fleet/main/README.md`
   returns **200**. `Redmern/pc-tune` is **PRIVATE**. This asymmetry decides §4.
3. **There is already a precedent script for exactly this shape:** `install-web.sh`
   at the repo root is a `curl … | sh` bootstrap with a documented trust model
   (`install-web.sh:6-16`) and a hard anti-truncation pattern. add-repo.sh must
   copy it, not invent a new style.
4. **This machine's `/etc/pacman.conf` is not stock Arch.** It is 30 lines, 705
   bytes, and already ends with a third-party TrustAll repo:

   ```ini
   # /etc/pacman.conf:19-30
   [core]
   Include = /etc/pacman.d/mirrorlist
   [extra]
   Include = /etc/pacman.d/mirrorlist
   [multilib]
   Include = /etc/pacman.d/mirrorlist
   [omarchy]
   SigLevel = Optional TrustAll
   Server = https://pkgs.omarchy.org/stable/$arch
   ```

   Omarchy already does precisely what we propose, appended at EOF. That is both
   validation of the approach and the reason §2's insertion algorithm can be far
   simpler than the brief assumes.
5. **pacman is 7.1.0**, and `/etc/pacman.conf.d` does **not** exist (`No such file
   or directory`). The rejected-alternative reasoning holds — see §5.5.

---

## 1. Touch-points and the cross-repo split

### 1.1 fleet repo (`/home/red/proj/pc-tune/fleet/main`) — lands FIRST

| File | Change | Why |
|---|---|---|
| `packaging/add-repo.sh` | **NEW.** The idempotent stanza installer. | The deliverable. |
| `docs/custom-repo.md:21-40` | Rewrite section (a): one-liner primary, manual stanza demoted to a "if you'd rather not pipe to shell" fallback. Keep the existing warning box at `:44-70` untouched. | Docs are the contract. |
| `README.md:154-165` | Same swap in the short Install block. | README currently prints the raw stanza as the only path. |
| `docs/multi-device-update.md:29-34` | Replace *"the one-time `pacman.conf` stanza"* with the one-liner. | Third and last place the manual step is documented. |
| `test/pacman-add-repo-proof.sh` | **NEW.** §6. | Repo convention is a self-contained proof harness per feature (`test/` holds three already). |
| `packaging/README.md:7-11` | Add `add-repo.sh` to the file table. | That table is the packaging index. |

Deliberately **not** touched: `PKGBUILD`, `.SRCINFO`, `fleet-git.install`, the CI
workflow. add-repo.sh is a *pre*-install bootstrap; shipping it inside the package
it bootstraps is circular. (One exception worth debating — see §7 OQ-3.)

**Placement argument (stress-tested).** The brief says `packaging/add-repo.sh`.
The counter-argument is `install-web.sh` sits at the **repo root** precisely
because it is curl'd, so a curl'd `add-repo.sh` arguably belongs there too. I
recommend **`packaging/`** anyway: it is unambiguously a packaging artifact, it
sits next to `publish-repo.sh` (its publisher-side mirror), and the URL depth
costs nothing in a copy-pasted one-liner. Note the asymmetry in the docs so the
next reader doesn't think it's an accident.

### 1.2 pc-tune repo (`/home/red/proj/pc-tune`) — lands SECOND

pc-tune tracks only 7 files (`git ls-files`): `.fleet/harness`, `.fleet/protected`,
`.gitignore`, `CLAUDE.md`, `MISSION.md`, `PLAN.md`, `bootstrap.sh`.

| File | Change |
|---|---|
| `bootstrap.sh:14-19` | Fix the stale prereq comment (§1.4). |
| `bootstrap.sh` (new section) | Optional consumer-mode fleet install — **but read §1.4 before writing a line of it.** |

### 1.3 Ordering

fleet first, pc-tune second, non-negotiable: pc-tune's bootstrap would consume a
fleet-side script by URL (or by path), so the fleet change must be merged and
pushed to `main` before pc-tune references it. There is no atomic cross-repo
commit here. Sequence:

1. Merge `packaging/add-repo.sh` + docs to `Redmern/fleet@main`, push.
2. Verify the raw URL serves 200 (the CI workflow does not gate on
   `packaging/**` for raw availability — raw is served straight from the git
   ref, so it is live the moment the push lands).
3. Only then merge the pc-tune bootstrap change.

Note the CI path filter at `.github/workflows/pacman-repo.yml:16-26` includes
`packaging/**`, so adding `add-repo.sh` will trigger a pointless package rebuild
and republish. Harmless (`--clobber` + the prune step at `:143-154` keep it
idempotent), but worth a one-line note in the commit message so a future reader
doesn't hunt for why the pkgver bumped.

### 1.4 ⚠ The tension the brief does not name: pc-tune bootstrap is the DEV model

This is the most important finding in this document.

`bootstrap.sh:32-37` lists `fleet` in `REMOTES` and `bootstrap.sh:54-76` clones it
as a bare worktree container with a checked-out `main`. Any machine that runs
`bootstrap.sh` therefore **already has a fleet worktree**, and the pc-tune workflow
symlinks `~/.local/bin/fleet` into it. `docs/custom-repo.md:44-70` and
`docs/multi-device-update.md:44-48` both state the consequence explicitly:

> `~/.local/bin` sits *before* `/usr/bin` on `PATH` … so the package stays
> **masked and unused** until the dev install is gone.

So "wire add-repo.sh into pc-tune's bootstrap.sh so a fresh machine needs no
hand-editing" — as literally stated in the leaning — would install a
`fleet-git` package that is **guaranteed to be shadowed and never executed** on
exactly the machines bootstrap.sh runs on. That is worse than doing nothing: it
creates a silent second install that `pacman -Syu` keeps updating while the user
runs a different binary.

Three coherent resolutions:

- **(A) Fix only the comment.** pc-tune stays 100% dev-model. `bootstrap.sh:14-19`
  gets corrected to reference `install-web.sh` or the `fleet/main` container it
  builds anyway (the current text tells you to clone fleet to `~/proj/fleet`,
  which bootstrap.sh then *also* clones to `$PC_TUNE_ROOT/fleet` — the comment is
  not just stale, it's actively misleading). add-repo.sh ships in fleet only, and
  the "no hand-edit" win lands for consumer machines via the one-liner in the docs.
- **(B) Add a consumer mode.** `bootstrap.sh --fleet=pacman` (default `worktree`):
  drops `fleet` from the container loop, runs add-repo.sh, then
  `sudo pacman -Sy && sudo pacman -S fleet-git && fleet setup`. Clean, but it
  forks bootstrap.sh into two meaningfully different products.
- **(C) Split the script.** A separate `pc-tune/bootstrap-consumer.sh`. Most
  honest, most duplication.

**Recommendation: (A) now, (B) as a follow-up if a real consumer machine
materialises.** The stated goal — "eliminate the manual pacman.conf edit when
installing fleet on a new non-dev Arch machine" — is fully achieved by the fleet
side alone. pc-tune's bootstrap is by construction a *dev* bootstrap; bolting a
consumer path onto it right now is scope creep that ships a shadowed package.
This is **OQ-1** for the adviser debate.

---

## 2. `add-repo.sh` design

### 2.1 The insertion-point question — the brief over-engineers it

The brief asks for an algorithm to "locate below the official repos robustly."
**There is no such problem.** pacman.conf is read top-to-bottom and `Include` is
inline expansion at the point of the directive; there is no mechanism by which
anything in that file is evaluated *after* EOF. Appending at EOF is therefore
*by definition* below `[core]`, `[extra]`, and `[multilib]`, wherever they are.
`/etc/pacman.conf:28-30` is the empirical proof — omarchy's stanza sits at EOF and
is correctly last.

Worse, the comfort the ordering is supposed to buy is **partly illusory**, and
this feeds §5: repo order breaks ties for `pacman -S <name>` resolution, but
`pacman -Syu` upgrades **by version comparison across all synced repos**. A
hostile `[fleet]` DB publishing `glibc-99.0` gets installed on the next `-Syu`
*regardless of where the stanza sits in the file*. Ordering is hygiene, not a
security control. Say so in the docs; do not let "we put it below the official
repos" read as mitigation.

**Decision: append at EOF. No section-scanning parser.** This removes the entire
class of INI-parsing bugs the brief was (reasonably) worried about, and the
remaining edge cases collapse to byte-level file hygiene, which is testable.

### 2.2 Argument surface

```
packaging/add-repo.sh [--yes] [--dry-run] [--remove] [--server URL] [--help]
```

| Flag | Behaviour |
|---|---|
| *(none)* | Show the exact stanza + the security statement, **prompt for confirmation**, then write. See §5 for why prompted is the default. |
| `--yes` / `-y` | Skip the prompt. Required for non-interactive use (`curl … \| sudo bash -s -- --yes`) and for the proof harness. |
| `--dry-run` | Print the resulting diff/stanza and the target path, write nothing, exit 0. |
| `--remove` | Remove a previously-installed fleet-managed stanza (see §2.4 markers). Symmetry with `install.sh --uninstall`, `install-web.sh`'s printed uninstall line. |
| `--server URL` | Override the `Server =` value. Needed by the proof harness and by anyone mirroring the release. |
| `--help` | Usage + the stanza + the trust statement. |

**Environment overrides** (this is a hard requirement flowing from §6, mirroring
how `fleet inject-secrets` / `fleet deliver-wake` were exposed as internal
subcommands purely so a harness could drive them):

| Var | Default | Purpose |
|---|---|---|
| `FLEET_PACMAN_CONF` | `/etc/pacman.conf` | **The test seam.** The harness points this at a temp fixture. |
| `FLEET_REPO_SERVER` | `https://github.com/Redmern/fleet/releases/download/repo` | Matches `publish-repo.sh:80`'s printed value. |
| `FLEET_REPO_NAME` | `fleet` | The section name. |

**The script never calls `sudo` itself.** It writes to `$FLEET_PACMAN_CONF` and
fails cleanly if it can't. Reasons: (a) the one-liner already supplies privilege
via `sudo bash`; (b) a script that self-escalates is unrunnable in a test harness
as an unprivileged user; (c) internal `sudo` in a piped script fights for stdin
with the confirmation prompt. This is a correctness constraint, not a preference.

### 2.3 Anti-truncation structure — copy `install-web.sh` exactly

`install-web.sh:14-16` states the rule:

> The ENTIRE body lives inside `main()`; the script does nothing until the final
> `main "$@"` line. A truncated download (connection dropped mid-transfer) can
> therefore never run a half-parsed script.

For `install-web.sh` a truncated run means a partial clone. For `add-repo.sh`, a
truncated run means **a half-written `/etc/pacman.conf`** — i.e. a machine that
cannot `pacman -Syu` at all. The pattern is mandatory here, not stylistic. Same
`#!/bin/sh` + `set -eu` inside `main()`, same header comment block documenting the
trust model and the download-read-run alternative.

### 2.4 Idempotency rule

Write a **fleet-owned marker comment** so `--remove` and re-detection are exact
rather than heuristic:

```ini
# >>> fleet repo (managed by packaging/add-repo.sh) >>>
[fleet]
SigLevel = Optional TrustAll
Server = https://github.com/Redmern/fleet/releases/download/repo
# <<< fleet repo <<<
```

Detection is a three-way classification, not a boolean:

1. **Managed block present** (both markers found, well-formed):
   - body byte-identical to desired → **no-op, exit 0**, print "already configured".
   - body differs (e.g. `Server` changed) → **replace the block in place**, keeping
     its position. Backup first. Exit 0.
2. **No markers, but an active `[fleet]` section exists** (an uncommented line
   matching `^[[:space:]]*\[fleet\][[:space:]]*$`) → **do not touch it.** Print
   what was found and what we would have written, exit **3** (see §2.7). This is
   the hand-edited-earlier case and the someone-else's-`[fleet]` case; both
   deserve a human, not a merge algorithm.
3. **Neither** → append the managed block at EOF.

Detection must ignore comments. The stock Arch pacman.conf ships a commented
example that is a live false-positive for naive greps:

```ini
#[custom]
#SigLevel = Optional TrustAll
#Server = file:///home/custompkgs
```

So: match `^[[:space:]]*\[fleet\]` **only**, never `grep -q '\[fleet\]'` (which
hits `#[fleet]` and any prose mention), and never grep for `SigLevel`/`Server`
values (which hit the example block and `[omarchy]`).

### 2.5 Backup scheme

Before **any** write:

```
cp -p "$CONF" "$CONF.fleet-bak.$(date +%Y%m%d%H%M%S)"
```

`-p` preserves mode/owner (root:root 644 per `ls -l /etc/pacman.conf`).
Timestamped, never overwriting a previous backup — a repeated bad run must not
destroy the one good copy. The path is printed. Deliberately **not** `.pacsave`
or `.bak` (pacman/pacnew namespace collision — note `/etc/pacman.d/mirrorlist.pacnew`
already exists on this box).

Backups are only taken when a write will actually happen, so the no-op re-run
case (the common one) leaves no litter.

### 2.6 Write algorithm

Atomic, in this order:

1. Resolve `CONF="${FLEET_PACMAN_CONF:-/etc/pacman.conf}"`, then
   `CONF_REAL=$(readlink -f "$CONF")` — **follow symlinks deliberately and write
   to the resolved path** (see §3.9).
2. Preflight (§3): exists, regular file after resolution, readable, writable.
3. Classify (§2.4). Exit early on no-op / conflict.
4. Backup (§2.5).
5. Build the new content in a temp file **in the same directory** as `CONF_REAL`
   (`mktemp "$(dirname "$CONF_REAL")/.pacman.conf.fleet.XXXXXX"`) so the final
   `mv` is a same-filesystem atomic rename. `/tmp` is very often a separate
   filesystem; `mv` across it is copy+unlink and not atomic.
6. Normalise the tail: if the existing content's last byte is not `\n`, emit one
   before the block. If the file uses CRLF (§3.4), match it.
7. `chmod --reference="$CONF_REAL" "$TMP"` (and `chown` if root) then
   `mv "$TMP" "$CONF_REAL"`.
8. Verify: re-read and confirm the block parses, then run
   `pacman-conf --repo-list` if available and assert `fleet` appears. This is the
   single best end-to-end assertion available and costs nothing —
   `pacman-conf` is part of pacman itself and honours `--config`, so the harness
   can use it too.
9. Print next steps verbatim from `docs/custom-repo.md:78-81`:
   `sudo pacman -Sy && sudo pacman -S fleet-git`, then `fleet setup`.

The script does **not** run `pacman -Sy` itself. Adding a repo and syncing
databases are different blast radii; the docs already treat them as steps (a) and
(b) and there is no reason to fuse them. (**OQ-4** — the counter-argument is that
an unsynced repo is a half-finished job.)

### 2.7 Exit codes

| Code | Meaning |
|---|---|
| 0 | Added, updated, or already-present no-op. |
| 1 | Generic/usage error. |
| 2 | Preflight failed: not Arch / no pacman, conf missing, not writable, not root. |
| 3 | Conflict: an unmanaged `[fleet]` section already exists. Human required. |
| 4 | Write/verification failed after backup (backup path printed prominently). |

Distinct codes matter because pc-tune's `bootstrap.sh` runs under `set -euo
pipefail` (`bootstrap.sh:20`) and would need to distinguish "already fine" from
"actually broken" if §1.4 option (B) is ever taken.

### 2.8 Failure modes to handle explicitly

- Disk full during step 5 → temp write fails → original untouched → exit 4.
- Interrupted between backup and `mv` → original untouched (that is the point of
  the atomic rename).
- `readlink -f` unavailable → it's coreutils, present on any Arch box; the
  preflight for `pacman` already implies Arch.
- Concurrent invocation → two runs both classify "absent" and both append,
  yielding a duplicate stanza (pacman errors on duplicate sections). Mitigate
  with a lock: `mkdir "$CONF_REAL.fleet-lock"` as the mutex (atomic, portable,
  no `flock` dependency), removed by a trap. Low probability, cheap to close.

---

## 3. Edge cases

| # | Case | Required behaviour | How |
|---|---|---|---|
| 3.1 | **Re-run** (managed block present, identical) | Exit 0, no write, no backup, message "already configured". | §2.4 case 1a; byte-compare the block body. |
| 3.2 | **Stanza present but `Server` changed** | Replace the managed block in place, preserving position; backup taken. | §2.4 case 1b. Position preservation matters so a user who deliberately moved the block keeps their ordering. |
| 3.3 | **No trailing newline** | Emit `\n` before the block; never concatenate `[fleet]` onto the previous line. | §2.6 step 6. This is the highest-severity naive-append bug: `Server = …$arch[fleet]` silently makes the *previous* repo's Server garbage. |
| 3.4 | **CRLF line endings** | Detect (`\r\n` in the last line) and emit CRLF for the appended block. Do **not** rewrite the rest of the file. | Unlikely on Arch but cheap. Detection must be on the *last* line, not `grep -c $'\r'` over the whole file (a lone `\r` inside a comment would false-positive). Note pacman itself tolerates trailing `\r` poorly in values — flag in docs rather than trying to repair. |
| 3.5 | **`[fleet]` present but commented out** (`#[fleet]`) | Treated as absent → append the managed block. Do **not** uncomment the old one. | Anchored regex `^[[:space:]]*\[fleet\]` (§2.4). Leaves a commented-out corpse in the file; acceptable and visible. |
| 3.6 | **A DIFFERENT `[fleet]` repo already defined** (someone else's, or a prior hand-edit) | **Refuse.** Print both the found stanza and the desired one. Exit 3. | §2.4 case 2. Never silently repoint a repo the user may be relying on. This also covers the "user followed the old docs by hand" migration path — and it is the *right* answer there too, because we cannot distinguish it from a genuine collision. Docs must tell that user to delete their hand-added stanza and re-run. |
| 3.7 | **Non-Arch machine** | `command -v pacman` fails → exit 2 with "this is Arch-specific; see README's `curl … \| sh` path (`install-web.sh`) for other Linux." | Cheap and prevents a Debian user writing a `/etc/pacman.conf` that will never be read. |
| 3.8 | **No sudo / not root** | Test `[ -w "$CONF_REAL" ]` rather than `[ "$(id -u)" = 0 ]`. Root-check alone is wrong for the harness (unprivileged user, writable temp fixture) and for exotic ACLs. If unwritable, print the exact re-run command with `sudo` and exit 2. | Mirrors `publish-repo.sh:26`'s explicit privilege assertion, inverted. |
| 3.9 | **`/etc/pacman.conf` missing** | Exit 2. Do **not** create it — an Arch box without pacman.conf is broken in a way this script must not paper over, and a fabricated minimal conf with only `[fleet]` in it would break `pacman -Syu` catastrophically. | Explicit `[ -f ]` check after resolution. |
| 3.10 | **`/etc/pacman.conf` is a symlink** (e.g. into a chezmoi/dotfiles tree) | Resolve with `readlink -f` and write the **target**. Never `mv` over the symlink itself (that silently replaces the link with a regular file and detaches it from the dotfile manager). Report the resolution in output. | §2.6 steps 1 and 7. pc-tune already knows about chezmoi clobbering managed paths (`bootstrap.sh:99-104`) — same class of hazard, same instinct. |
| 3.11 | Conf contains an `Include` that pulls in repos from elsewhere | Irrelevant to correctness: EOF is still after everything. Worth one doc sentence. | §2.1. |
| 3.12 | Duplicate `[fleet]` already in the file twice | Falls into case 2 → exit 3. Do not attempt dedup. | §2.4. |

---

## 4. Bootstrapping / ordering: curl vs vendor

The one-liner fetches from `raw.githubusercontent.com/Redmern/fleet/main/…`.

**Verified:** `Redmern/fleet` is public and unauthenticated raw fetch returns 200.
So the private-repo failure mode **does not currently apply** — but it would apply
instantly if fleet were ever made private, and it silently produces a 404 body
that `curl -fsSL` correctly turns into a non-zero exit (the `-f` flag is doing real
work; keep it in every documented invocation).

| Failure | Effect | Handling |
|---|---|---|
| Repo goes private | `curl -f` → exit 22, nothing runs. | Acceptable: loud, not silent. |
| GitHub raw rate-limit (60/hr unauthenticated per IP) | 429; `curl -f` fails. | Loud. Retry or use the manual stanza fallback that §1.1 keeps in the docs. |
| Offline | curl fails. | Loud. |
| **raw serves a *newer* `main` than the release** | Harmless — add-repo.sh writes a static stanza; there is no version coupling with the package. | None needed. |

**Should pc-tune's bootstrap.sh vendor a copy instead of curling?**

Given §1.4 recommendation (A), the question is nearly moot — bootstrap.sh doesn't
call it at all. But if option (B) is taken later, the answer is **neither curl nor
vendor: call it from the local checkout.** `bootstrap.sh:54-76` already clones the
fleet container, so `$PC_TUNE_ROOT/fleet/main/packaging/add-repo.sh` exists on disk
by the time any fleet-install step could run. That path has zero network
dependency, zero drift (it's the pinned checkout), and zero vendored duplicate to
rot. It is strictly better than both options in the brief.

Vendoring a *copy* into pc-tune is the worst option: two divergent scripts, and
pc-tune is private so the copy can't even be curl'd by a third party.

---

## 5. Security analysis

### 5.1 What the stanza actually authorises

```ini
SigLevel = Optional TrustAll
```

Per `pacman.conf(5)`: `Optional` = packages need not be signed; `TrustAll` = if a
signature *is* present, accept it regardless of whether the key is in the local
keyring or marked trusted. Together: **no cryptographic verification of anything
from this repo, ever.** `docs/custom-repo.md:144-152` already states this honestly.

Two properties make it sharper than the docs currently convey:

1. **It is not scoped to fleet.** A repo is a namespace of arbitrary package
   names. Whoever controls the `repo` release's `fleet.db` can publish a package
   named *anything* — `glibc`, `openssh`, `sudo`, `linux` — at any version.
2. **Repo ordering does not save you.** `-S <name>` resolves by repo order, but
   `-Syu` upgrades by **version comparison across all synced repos**. A
   `sudo-9999.0-1` in `[fleet]` is a newer version than official `sudo`, so
   `pacman -Syu` installs it — from the bottom-of-file repo — and runs its
   `.install` scriptlet **as root**. The "put it below the official repos"
   guidance in `docs/custom-repo.md:23-25` and `README.md:156` is *hygiene*, and
   the docs should stop implying otherwise.

So the honest statement is: **adding this repo grants the publisher of that
GitHub release a persistent root-code-execution channel on the machine, fired by
the user's own routine `pacman -Syu`.**

### 5.2 Who can publish

- **red's GitHub account** (release assets on `Redmern/fleet`).
- **Anyone who can push to `main`** — because `.github/workflows/pacman-repo.yml:14-26`
  triggers on push and `:37` grants `contents: write`, so a push that alters
  `packaging/PKGBUILD`'s `package()` publishes an arbitrary payload automatically.
  **Pushing to main is equivalent to publishing.** That is a wider surface than
  "red's account can upload a release asset."
- **Anyone who can run `workflow_dispatch`** (`:28`) — repo write access.
- **GitHub itself**, and anyone with a valid cert for `github.com`.

An account compromise therefore buys the attacker root on every machine that ran
add-repo.sh, delivered by a mechanism the user believes is a routine system
update. There is no revocation channel: the release tag is mutable, the DB is
re-fetched on every `-Sy`, and no local state would flag the change.

### 5.3 What `curl | sudo bash` adds

Materially less than it looks. The pipe-to-shell is HTTPS-TOFU — the same trust
model `install-web.sh:6-8` already documents and the user already accepts for the
existing installer. The genuinely new exposure is the **repo**, not the pipe: the
pipe is a one-shot execution at a moment the user chose, while `TrustAll` is a
standing grant redeemed at every future `-Syu`.

Ranked by actual risk:

1. Standing unsigned-repo root channel (§5.1) — **high, persistent**.
2. Push-to-main ⇒ publish (§5.2) — **high**, and under-documented.
3. curl-pipe TOFU — **moderate, one-shot**, already an accepted precedent in this repo.

An anti-truncation `main()` wrapper (§2.3) is what makes #3 tolerable here, and it
is non-negotiable because a partial write corrupts pacman.conf.

### 5.4 Options

| Option | Cost | Effect |
|---|---|---|
| **(a) Silent write, no prompt** | zero | Fastest. Gives the user no moment to learn they just granted a standing root channel. |
| **(b) Print stanza + threat statement, prompt, `--yes` to skip** | ~15 lines | Preserves informed consent interactively; `--yes` keeps automation possible. |
| **(c) GPG-sign now, `SigLevel = Required DatabaseOptional`** | CI: private key + passphrase as Actions secrets, `gpg --import`, `makepkg --sign`, `repo-add -s -k`; device: `pacman-key --recv-keys` + `--lsign-key` **once per device — a new manual step**. `docs/custom-repo.md:154-165` already spells out the exact recipe. | Closes §5.1 and §5.2-via-release-upload. Does **not** close push-to-main-⇒-publish if the signing key lives in CI. |
| **(d) Defer signing, written rationale + trigger** | zero | Honest debt. |

Note the sharp irony in (c): signing *reintroduces a manual per-device step*
(`pacman-key --lsign-key`), which is the exact thing this work exists to
eliminate. add-repo.sh could run the `pacman-key` commands itself — but then it
is fetching and locally-signing a key over the same HTTPS-TOFU channel, which
recovers most of the security benefit only against *later* release tampering, not
against a compromise at add-repo time.

### 5.5 On the rejected `fleet-repo` package — rejection **confirmed**, reasoning refined

The brief's stated reason ("pacman has no drop-in conf.d directory") is correct
and I verified it: `/etc/pacman.conf.d` does not exist on this box, and pacman
7.1.0 ships no such convention.

One refinement the brief misses: pacman's `Include` directive **does support
globs**, so `Include = /etc/pacman.d/conf.d/*.conf` in pacman.conf would create a
real drop-in directory, after which a `fleet-repo` package could ship
`/etc/pacman.d/conf.d/fleet.conf` and never touch pacman.conf again.

That does not rescue the alternative:

1. Installing that one `Include` line **is the same `/etc/pacman.conf` edit** we
   are trying to remove — so add-repo.sh (or a manual edit) is still required.
2. It is *more* moving parts for the same first-run cost, and inverts the
   dependency: you would need `pacman -U <url-of-fleet-repo-pkg>` before the repo
   exists, i.e. a hand-pasted URL — another manual step by a different name.
3. A package writing `/etc/pacman.conf` (rather than a drop-in) via a scriptlet is
   worse still: pacman-owned config mutating pacman's own config, with no
   `.pacnew` semantics to fall back on.

The rejection stands on stronger ground than the brief gave it.

### 5.6 RECOMMENDATION

**Ship option (b) + (d): prompt by default with `--yes`, and defer GPG signing
with a written trigger condition.**

Rationale:

- add-repo.sh does not create the TrustAll risk — `docs/custom-repo.md:21-40`
  already instructs users to accept it by hand, and this machine already runs
  `[omarchy]` on identical terms (`/etc/pacman.conf:28-30`). The script *lowers
  the friction on an existing accepted risk*; it should not be blocked on
  retro-fixing that risk.
- But it also *removes the friction that was doing the disclosing.* Hand-editing
  `/etc/pacman.conf` under `sudo` is a moment of attention. Automating it silently
  deletes that moment. The prompt is how you pay that back, and it costs 15 lines.
- Publisher == consumer today (red's personal fleet), which is the standard
  accepted-trade-off condition and is exactly what `docs/custom-repo.md:150-152`
  claims.

**Written deferral trigger — sign before any of these becomes true:**

1. Any machine that is not solely red's runs add-repo.sh.
2. Anyone other than red gains push access to `Redmern/fleet` (see §5.2 — push
   access *is* publish access).
3. fleet is advertised for third-party installation.

**Ship alongside, at zero cost:**

- Correct the ordering-implies-safety wording in `docs/custom-repo.md:23-25` and
  `README.md:156` (§5.1 point 2).
- Add §5.2's push-⇒-publish equivalence to the security note at
  `docs/custom-repo.md:144-165`. It is currently absent and is the widest part of
  the surface.
- Have add-repo.sh print the `--remove` invocation on success, so revocation is
  discoverable at the moment of grant.

---

## 6. Proof design — `test/pacman-add-repo-proof.sh`

### 6.1 Conventions to match (read from the two existing harnesses)

From `test/reap-teardown-safety.sh` and `test/suborch-wake-proof.sh`:

- `#!/usr/bin/env bash`, `set -u` (**not** `-e` — cases must be able to fail and
  still aggregate).
- A header comment stating the bug/property, the scenario list, and the
  RED-before / GREEN-after expectation (`reap-teardown-safety.sh:1-19`).
- `HERE=$(cd "$(dirname "$0")/.." && pwd)` then absolute paths to the artefact
  under test (`:22-24`).
- **Isolation via env, with a `trap cleanup EXIT`** and `TMPROOT=$(mktemp -d)`
  (`:27-32`). This is the direct analogue of what we need: those harnesses
  redirect `TMUX_TMPDIR`/`XDG_CONFIG_HOME` so they can never touch the real tmux
  server; we redirect `FLEET_PACMAN_CONF` so we can never touch the real
  `/etc/pacman.conf`.
- Per-case subshells with `pass()`/`fail()` that `exit 0`/`exit 1`, aggregated by
  capturing `$?` into `r1..rN` (`:37-38`, `:104-112`, `:210-213`) — subshells
  can't mutate parent counters. (`suborch-wake-proof.sh:43-44` uses the flat
  `FAILED=1` variant; the subshell form is the better fit here since each case
  wants its own fixture.)
- Final `== summary: N passed, M failed ==` then an explicit
  `RESULT: …` line, `exit 0` only if all pass (`:212-220`).
- A tail case running `bash -n` on the artefact (`suborch-wake-proof.sh:157`).

### 6.2 Hard safety requirement

The harness must be **structurally incapable** of touching `/etc/pacman.conf`.
Three independent layers:

1. Every invocation sets `FLEET_PACMAN_CONF="$TMPROOT/case-N/pacman.conf"`.
2. A guard at the top of every case asserts
   `case "$FLEET_PACMAN_CONF" in "$TMPROOT"/*) ;; *) fail … ;; esac` — if the
   env seam is ever broken or renamed, the harness aborts rather than falling
   back to the default path.
3. A final post-run assertion that `/etc/pacman.conf`'s mtime and sha256 are
   unchanged from a snapshot taken at harness start. This catches a script bug
   that ignores the env var entirely — the one failure mode layers 1 and 2 miss.

Fixtures are built by shell heredocs into `$TMPROOT`, never copied from `/etc`.

### 6.3 Fixtures

| Fixture | Content |
|---|---|
| `stock` | Full stock Arch pacman.conf including the commented `#[custom]` example block and commented `#[multilib]`. |
| `omarchy` | Byte-shape of this machine's real conf (§0 item 4): `[core]/[extra]/[multilib]` + a trailing `[omarchy]` TrustAll stanza. |
| `no-newline` | `omarchy` with the final newline stripped. |
| `crlf` | `stock` with CRLF endings. |
| `commented-fleet` | `stock` plus a `#[fleet]` / `#Server = …` commented block. |
| `foreign-fleet` | `stock` plus an **active** `[fleet]` stanza with a different `Server`. |
| `managed-current` | `stock` plus our exact managed block (marker-delimited). |
| `managed-stale` | `stock` plus our managed block with an **old** `Server` URL. |
| `symlinked` | a symlink at `conf` → `real/pacman.conf`. |
| `readonly` | `stock`, `chmod 0444`, owned by the test user. |
| `missing` | path that does not exist. |

### 6.4 Cases

| # | Scenario | Pass condition |
|---|---|---|
| 1 | **Fresh add** on `omarchy` | exit 0; exactly one `^\[fleet\]` line; it is the **last** section header in the file; `Server` matches the default; markers present; original bytes are an exact prefix of the result (nothing above EOF mutated). |
| 2 | **Re-run** (case 1's output, run again) | exit 0; file **byte-identical** to case 1's output; **no new `.fleet-bak.*` file created**. |
| 3 | **Stale Server** on `managed-stale` | exit 0; exactly one `[fleet]`; `Server` is the new value; the block's **line position is unchanged** (it did not move to EOF); one backup created containing the old value. |
| 4 | **No trailing newline** on `no-newline` | exit 0; the pre-existing last line (`Server = …omarchy…`) is intact and terminated; `[fleet]` starts on its own line. **This case is RED against a naive `cat >>`** — it is the point of the test. |
| 5 | **CRLF** on `crlf` | exit 0; appended block uses CRLF; no line in the file has a bare `\n` where the rest use `\r\n`; pre-existing lines byte-unchanged. |
| 6 | **Commented `[fleet]`** on `commented-fleet` | exit 0; the `#[fleet]` line is **still commented and unchanged**; a new active managed block was appended; exactly one *active* `^[[:space:]]*\[fleet\]`. |
| 7 | **Foreign active `[fleet]`** on `foreign-fleet` | exit **3**; file **byte-identical** to the fixture; no backup created; stderr names both the found and the desired `Server`. |
| 8 | **Non-Arch** (`PATH` scrubbed of `pacman` for the invocation) | exit **2**; fixture untouched; message points at `install-web.sh`. |
| 9 | **Not writable** on `readonly` | exit **2**; fixture untouched; message contains a `sudo`-prefixed re-run command. |
| 10 | **Missing conf** on `missing` | exit **2**; **no file created at that path** (the anti-fabrication assertion of §3.9). |
| 11 | **Symlink** on `symlinked` | exit 0; `conf` is **still a symlink** (`[ -L ]`); the block landed in `real/pacman.conf`; the symlink's target is unchanged. |
| 12 | **`--dry-run`** on `omarchy` | exit 0; fixture byte-identical; the desired block is printed to stdout. |
| 13 | **`--remove`** on case 1's output | exit 0; result byte-identical to the pre-add `omarchy` fixture (**round-trip proof**: add then remove is the identity function, trailing newline included); backup created. |
| 14 | **`--remove` with no block present** | exit 0; no-op; file unchanged. |
| 15 | **Backup fidelity** — after case 3 | the newest `.fleet-bak.*` is byte-identical to the pre-run fixture, and its mode matches (`stat -c %a`). |
| 16 | **pacman parses the result** — after case 1 | `pacman-conf --config "$FIXTURE" --repo-list` exits 0 and its output contains `fleet`, with `core`/`extra` still listed. Skipped with a printed `SKIP` if `pacman-conf` is absent (mirrors the repo's fail-silent instinct). **This is the only case that proves the output is valid to pacman rather than merely textually plausible.** |
| 17 | **Concurrency** — two simultaneous runs on one fixture | exactly one `[fleet]` section in the result; both processes exit 0 or one exits 0 and one reports already-present. |
| 18 | **Idempotent `--server` override** | run with `--server X` twice → single block, `Server = X`, second run no-op. |
| 19 | **`bash -n`** / `sh -n` on `packaging/add-repo.sh` | parses clean. |
| 20 | **Anti-truncation structure** | assert the file's only top-level executable statement is the final `main "$@"` — grep that no line outside `main()` is a command. Directly enforces §2.3 and mirrors `install-web.sh:14-16`. |
| 21 | **Real conf untouched** (global, at teardown) | sha256 of `/etc/pacman.conf` equals the snapshot taken at harness start. §6.2 layer 3. |

Cases 4, 7, 10, 11, 13 and 20 are the ones that would be **RED against a naive
implementation** (`grep -q '[fleet]' || cat >> conf`); they are the reason the
harness is worth writing at all. Cases 1–3 are the happy paths.

---

## 7. Risks and OPEN QUESTIONS for the adviser debate

### Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | pc-tune bootstrap installs a package that is permanently PATH-shadowed by the dev worktree (§1.4) | **High** — silently useless, actively confusing | Recommendation (A): don't wire it into bootstrap.sh. |
| R2 | Automating the pacman.conf edit removes the attention moment that was doing the security disclosure (§5.3) | **High** | Prompt by default (§5.6). |
| R3 | A corrupted `/etc/pacman.conf` bricks package management on the target machine | **High** | `main()` wrapper, same-dir temp + atomic rename, timestamped backup, `pacman-conf` verify (§2.6). |
| R4 | Docs imply repo ordering is a security control (§5.1) | Medium | Reword `docs/custom-repo.md:23-25`, `README.md:156`. |
| R5 | Push-to-main ⇒ publish is undocumented (§5.2) | Medium | Add to the security note. |
| R6 | Docs drift — the stanza now lives in 4 places (README, custom-repo.md, multi-device-update.md, add-repo.sh) | Medium | Make add-repo.sh the single source and have the docs say "run this"; where the literal stanza must appear, mark it a copy. |
| R7 | Adding `packaging/add-repo.sh` triggers a spurious CI package rebuild (`pacman-repo.yml:16-26`) | Low | Harmless (`--clobber` + prune); note it in the commit. |
| R8 | `--remove` leaves the machine with `fleet-git` installed but unupdatable | Low | Print the `pacman -R fleet-git` hint, matching `fleet-git.install:29-34`'s tone. |

### Open questions

- **OQ-1 (biggest).** Does pc-tune's `bootstrap.sh` get a consumer mode at all, or
  does it stay a pure dev bootstrap and this work land entirely in fleet? §1.4
  recommends the latter. If the adviser wants a consumer mode, is it a flag, a
  second script, or a separate repo?
- **OQ-2.** Prompt-by-default or `--yes`-by-default? §5.6 says prompt. The counter:
  every documented invocation is `curl … | sudo bash`, where stdin is the *pipe*,
  not the tty — a naive `read` gets EOF and either hangs or auto-declines. The
  script must read from `/dev/tty` explicitly and fall back to "refuse, tell the
  user to pass `--yes`" when there is no tty. **This is a real implementation
  trap and the prompt design is not viable without it.**
- **OQ-3.** Should `fleet-git` itself ship `add-repo.sh` (e.g. as
  `fleet add-repo`)? Circular for first install, but useful for *repointing* the
  Server later on an already-installed machine. §1.1 says no for now.
- **OQ-4.** Should add-repo.sh run `pacman -Sy` on success? §2.6 says no
  (different blast radius); counter is that an unsynced repo leaves the job
  half-done and the very next command in the docs is `-Sy` anyway.
- **OQ-5.** GPG signing now or deferred? §5.6 recommends deferred with a written
  trigger. The strongest counter-argument: signing gets *harder* the more
  machines have already trusted the unsigned repo, and (c)'s per-device
  `pacman-key --lsign-key` step directly reintroduces the manual step this work
  exists to remove — so "we'll do it later" may mean "never."
- **OQ-6.** Marker-comment blocks (§2.4) vs. plain stanza detection. Markers make
  `--remove` and update exact, at the cost of a stanza that no longer matches what
  the docs print verbatim. Accept the mismatch, or print the marker block in the
  docs too?
- **OQ-7.** Should case 16 (`pacman-conf` validation) be a hard requirement rather
  than SKIP-if-absent? It is the only end-to-end proof; on any Arch machine
  `pacman-conf` is present by definition.

---

## Appendix — files read

`packaging/PKGBUILD`, `packaging/fleet-git.install`, `packaging/publish-repo.sh`,
`packaging/README.md`, `.github/workflows/pacman-repo.yml`, `docs/custom-repo.md`,
`docs/multi-device-update.md:20-50`, `README.md:145-215`, `install-web.sh`,
`test/reap-teardown-safety.sh`, `test/suborch-wake-proof.sh`,
`/home/red/proj/pc-tune/bootstrap.sh`, `/etc/pacman.conf` (read-only),
`/etc/pacman.d/` listing, `pacman -V`, `gh repo view` ×2,
`gh release view repo --repo Redmern/fleet`, unauthenticated raw-URL probe.

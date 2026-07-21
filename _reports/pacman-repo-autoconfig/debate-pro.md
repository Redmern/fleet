# Adviser 1 of 4 — the case FOR the plan as written

**Lens:** argue for PLAN.md. **Verdict: PROCEED, with three factual corrections
and a concrete design for (B).**

**OQ-1 is RULED: (B) — bootstrap.sh gains a consumer mode.** This supersedes
PLAN.md §1.4's recommendation of (A). §4 of this document has been rewritten
accordingly: it no longer argues *whether* (B), it stress-tests *how* (B) must be
shaped. My finding on that axis: **(B) is workable, and materially cheaper than
either PLAN.md or the redirect assumes — because three of the five integration
points are already solved by code that exists today.** One is a hard blocker
PLAN.md never mentions, and it is a two-line fix.

I did not take this on trust. Everything checkable was executed against
throwaway fixtures under `mktemp -d`. `/etc/pacman.conf` was read only; its
sha256 at completion is
`b19c50501ef9528fb47623f312978af5a5d0df6e7d25844b01f91b7dc75baa46`, mtime
2026-01-17 — untouched. Every prototype ran with `FLEET_PACMAN_CONF` pointed
inside my temp dir.

---

## 0. What I actually ran

| # | Test | Result |
|---|---|---|
| T1 | `pacman-conf --config <fixture> --repo-list` | works — the §6 test seam is real |
| T2 | EOF-append `[fleet]`, re-run repo-list | `core extra omarchy fleet` — **fleet last** |
| T5 | naive `cat >>` onto a no-trailing-newline conf | **corruption confirmed, and worse than the plan claims** |
| T6 | duplicate `[fleet]` sections | **plan's claim is wrong** — pacman does *not* error |
| T7 | `grep -q '\[fleet\]'` vs anchored regex | naive grep false-positives; anchored is correct |
| T8 | `Include = dir/*.conf` | globs **do** work — §5.5's refinement confirmed |
| T9 | CRLF conf | **plan's claim is wrong** — pacman 7.1.0 strips `\r` cleanly |
| T10 | `mv` over a symlink path vs its resolved target | detach + orphaned edit confirmed |
| T11 | `chmod --reference`, `cp -p` | available, preserve mode |
| T12 | prototype add → `--remove` round-trip | identity holds **only** for newline-terminated input |
| T14 | bootstrap.sh `LINKS` array | **contains no fleet entry** — reframes IP1 |
| T15 | consumer-mode `doctor_config_sync` simulation | prints a `warn`; **doctor still exits 0** |
| T16 | consumer-mode verify-loop simulation | **`fail=1` → `die` → exit 1. Hard blocker.** |
| T17 | `cmd_setup` shadow guard + unit branch conditions | **both already correct for consumer mode** |
| T18 | raw fetch of a `packaging/` path | 200 |

Environment: pacman **7.1.0**; `/etc/pacman.conf.d` absent; `/etc/pacman.conf`
`644 root` 705 bytes; `/etc/pacman.d/mirrorlist.pacnew` present (§2.5's namespace
worry is live); `Redmern/fleet` PUBLIC + raw 200; `Redmern/pc-tune` PRIVATE;
`Redmern/tmux` PRIVATE; the `repo` release carries
`fleet-git-r207.041e14b-1-any.pkg.tar.zst` + all four DB assets; `~/.local/bin`
is **PATH position 2**, `/usr/bin` **position 8**; `fleet-git` **not** installed
here; `~/.local/bin/fleet → /home/red/proj/pc-tune/fleet/main/bin/fleet`;
`systemctl --user show fleetd -p FragmentPath` →
`/home/red/.config/systemd/user/fleetd.service`, and
`/usr/lib/systemd/user/fleetd.service` **does not exist** on this box.

---

## 1. What the plan gets RIGHT

### 1.1 §2.1 — "append at EOF, no section-scanning parser" (PLAN.md:159-182)

Right, and the best decision in the document. Verified (T2): a fixture with
`[core] [extra] [omarchy]` plus an EOF-appended `[fleet]` yields
`pacman-conf --repo-list` = `core extra omarchy fleet`. Ordering achieved with
zero parsing. The justification is *understated* — see §2.1.

### 1.2 §3.3 / case 4 — the no-trailing-newline bug (PLAN.md:349, :600)

Worse than "the highest-severity naive-append bug." T5, verbatim:

```
--- resulting tail:
Server = https://pkgs.omarchy.org/stable/$arch[fleet]
SigLevel = Optional TrustAll
Server = https://x/repo
--- pacman-conf verdict:
core
omarchy
rc=0
--- what omarchy's Server became:
Server = https://pkgs.omarchy.org/stable/x86_64[fleet]
```

Three failures at once; the plan names only the first:

1. `[omarchy]`'s `Server` is silently poisoned (every omarchy package 404s).
2. **`[fleet]` is never created at all** — no `fleet` in `repo-list`. The
   requested operation silently did not happen.
3. **`pacman-conf` exits 0.** The conf is "valid." Nothing errors.

This is the strongest empirical justification in the plan, and it lands on two of
the plan's own decisions: why case 4 must exist, and why case 16 must be a
**hard** assertion (OQ-7) — an exit-code-only harness passes this green.

### 1.3 §3.10 / case 11 — symlinked pacman.conf (PLAN.md:356, :607)

Confirmed (T10). Writing to `readlink -f` of the path: symlink survives, target
updated. `mv`-ing over the symlink path itself:

```
conf2 still a symlink? NO -- detached (plan's hazard CONFIRMED)
real2 content (unchanged = orphaned edit): orig
```

Both halves are real — the link detaches *and* the edit lands nowhere the dotfile
manager can see. Connecting this to `bootstrap.sh:99-104`'s chezmoi warning is
the right generalisation.

### 1.4 §2.4 — anchored detection, never bare `grep` (PLAN.md:256-265)

Confirmed (T7). On a file with `#[custom]`, prose `# see [fleet] docs`, and
`#[fleet]`:

- `grep -q '\[fleet\]'` → **MATCH** (false positive → silent no-op).
- `grep -qE '^[[:space:]]*\[fleet\][[:space:]]*$'` → **no match** (correct).

The `[[:space:]]*` prefix is load-bearing: I verified pacman **accepts** a
leading-whitespace section header (`  [fleet]` parsed as a real repo). A bare
`^\[fleet\]` anchor would miss a genuine hand-edited stanza and then append a
duplicate.

### 1.5 §5.1 point 2 — "repo ordering is hygiene, not a security control"

Correct, and the most valuable *editorial* finding. `docs/custom-repo.md:23-25`
reads as a mitigation; it is not (`-Syu` upgrades by version comparison across
all synced repos). One sentence to fix, and it removes a false sense of safety
that automation would otherwise amplify.

### 1.6 §5.2 — push-to-main ⇒ publish

The workflow triggers on push with `contents: write`, so anyone who can push to
`main` publishes an arbitrary root-executing payload to every machine that ran
add-repo.sh. Genuinely absent from `docs/custom-repo.md:144-165`, which names
only "red's GitHub account / CI token." Widest part of the surface.

### 1.7 §5.5 — the `fleet-repo` rejection, with the glob refinement

Confirmed (T8): `Include = <dir>/*.conf` globs, and included files **can** define
repo sections. A drop-in dir is constructible. The plan is right that it doesn't
rescue the alternative — installing the `Include` line *is* the edit we're
removing, and `pacman -U <hand-pasted-url>` is a manual step renamed. Finding the
counter-argument to your own rejection and defeating it is what makes §5.5
trustworthy.

### 1.8 §2.3 — the `main()` anti-truncation wrapper is mandatory here

`install-web.sh:14-16` documents the pattern; the stakes are higher for
add-repo.sh (a truncated run leaves a machine unable to `pacman -Syu`). Case 20
enforces the *property*, not the output — the right kind of test.

### 1.9 §2.2 — "the script never calls `sudo` itself" (PLAN.md:208-212)

A correctness constraint, and the third sub-argument is sharpest: internal `sudo`
in a piped script fights the confirmation prompt for stdin — and per OQ-2 the
prompt must already read `/dev/tty`. Two `/dev/tty` consumers in one script is
how you get an installer that hangs on a fresh machine. **This constraint is also
what makes (B) clean — see §4.6.**

### 1.10 §2.7 exit codes, §2.6 step 5 same-dir `mktemp`

Exit 3 (conflict, human required) distinct from 2 (preflight) looks like
over-design until someone scripts around it — **which, under (B), someone now
does** (§4.4, §4.6). And the same-directory temp is correct: `/tmp` is `tmpfs`
here, so `mv` from it is copy+unlink, not an atomic rename — exactly the window
where a crash leaves a half-written `/etc/pacman.conf`.

### 1.11 §1.1 — do NOT ship add-repo.sh inside the package it bootstraps

Right, and for a better reason than "circular": `packaging/README.md:15-24`
establishes the package installs **immutable system files** only. A shipped
`add-repo.sh` writing `/etc/pacman.conf` would be a pacman-owned artefact
mutating pacman's own config with no `.pacnew` semantics — §5.5 point 3 already
makes this argument; reuse it at §1.1.

---

## 2. Where the plan UNDER-claims

### 2.1 §2.1's EOF argument is stronger than "there is no such problem"

The plan argues EOF is *sufficient*. T8 makes a stronger claim available: **EOF is
the only unconditionally correct insertion point, and any section-scanning parser
is actively wrong.**

Because `Include` is inline expansion and included files may define repo sections,
a conf ending in `Include = /etc/pacman.d/repos/*.conf` pulls in repos that an
"insert after the last of `[core]`/`[extra]`/`[multilib]`" parser would place
`[fleet]` *above*. The brief's requested algorithm isn't merely more complex than
EOF-append — it returns the wrong answer on exactly the configs the brief worried
about. §3.11 dismisses `Include` as "irrelevant to correctness"; it is the
*proof* of §2.1. Promote it.

### 2.2 §6.2's three-layer isolation is reusable, and layer 3 is new

`reap-teardown-safety.sh:26-32` and `suborch-wake-proof.sh:27-35` isolate by env
redirect (`TMUX_TMPDIR`, `XDG_CONFIG_HOME`) — layer 1 only. Neither has layer 2
(assert the redirect points inside `$TMPROOT`) or layer 3 (snapshot the real
resource's hash, assert at teardown).

Layer 3 is the one that matters, and the plan buries it as "the one failure mode
layers 1 and 2 miss." That failure mode is *the script ignoring the env seam
entirely* — a typo'd variable name, the single likeliest way a harness silently
stops testing anything while reporting green. Write it up as a repo convention
and back-port it (the tmux analogue: `tmux list-sessions` count before/after).

### 2.3 Case 16 is the only case that catches the worst bug — and the plan hedges it

Per T5, the corruption produces **rc=0** on a conf where one repo is poisoned and
the target repo doesn't exist. If case 16 is SKIP-if-absent (PLAN.md:612) and the
harness runs in a container without `pacman-conf`, it reports green on a
catastrophically broken script. The plan raises this as OQ-7 and answers it
timidly. See §3.

### 2.4 §2.7's exit codes and §2.2's "never self-`sudo`" were designed for (B) before (B) existed

PLAN.md:325-327 justifies distinct exit codes by *"would need to distinguish
'already fine' from 'actually broken' if §1.4 option (B) is ever taken."* (B) is
now taken. The plan built the integration contract for the option it declined to
recommend, and that contract is exactly right — see §4.6. Likewise the
never-self-`sudo` rule (§1.9) is what lets bootstrap.sh own privilege escalation
and the consent prompt cleanly. **Two of (B)'s hardest design constraints were
already satisfied by decisions the plan made for other reasons.**

### 2.5 §5.6's "the friction was doing the disclosing" argument

PLAN.md:509-511 — *hand-editing `/etc/pacman.conf` under `sudo` is a moment of
attention; automating it silently deletes that moment; the prompt is how you pay
that back.* That is the correct security frame for **every** convenience wrapper
around a privileged edit, stated in three lines. It should headline §5, not sit
under the recommendation. Under (B) it is load-bearing: bootstrap.sh removes even
the copy-paste moment, so bootstrap.sh must own the prompt (§4.6).

---

## 3. Explicit answers

### Is this the best way?

**For the stated goal — yes.** Only three structurally different mechanisms exist:

| Mechanism | Verdict |
|---|---|
| A script that appends the stanza (the plan) | **Wins.** One step, no new distribution channel, testable end-to-end via `pacman-conf`. |
| Drop-in `Include` dir + `fleet-repo` package | Verified possible (T8), still loses: bootstrapping the `Include` line is the same `/etc` edit, and installing the package pre-repo needs a hand-pasted `pacman -U <url>`. Same manual step, more parts. |
| GPG-signed repo (§5.4c) | Doesn't address the goal. It **adds** a per-device manual step (`pacman-key --lsign-key`). Orthogonal security upgrade. |

### Is there a better way?

One option the plan doesn't consider: **fold the repo path into
`install-web.sh`** — a `--pacman` flag or Arch auto-detect — giving consumers
**one** public URL.

It loses, which strengthens the plan: `install-web.sh`'s outcome (git clone in
`~/.local/share/fleet` + `~/.local/bin` symlinks) is **mutually exclusive** with
the pacman outcome (`/usr/bin/fleet`), and `install-web.sh:47-65` already refuses
to coexist with an out-of-tree symlink. One script with two incompatible terminal
states, one shadowing the other, is a worse product than two scripts with one
decision between them.

**But the cross-link is a real gap**, and (B) widens it — there are now *three*
entry points (install-web.sh, the add-repo.sh one-liner, `bootstrap.sh
--fleet=pacman`). Fix in docs: one decision table stating which machine each is
for.

### What ADDITIONS would improve it for the user?

Ranked by value per line:

1. **Make case 16 hard (OQ-7 → yes).** Per T5, rc=0 hides the worst failure. On
   Arch `pacman-conf` is present by definition and §3.7's preflight already
   exits 2 on non-Arch — the SKIP branch only fires where the script is
   unsupported anyway. Delete it.
2. **`Architecture = auto` in every fixture.** I hit this immediately: a faithful
   byte-shape copy of this machine's conf **fails** `pacman-conf` with
   `mirror '…/$arch' contains the '$arch' variable, but no 'Architecture' is
   defined`, rc=1. Without it, case 16 fails on correct code.
3. **A fixture-validity precondition.** Assert `pacman-conf --config "$FIXTURE"
   --repo-list` succeeds on the *unmodified* fixture before each case, so a
   malformed fixture can't read as a script bug. Would have caught #2 free.
4. **The five (B) additions in §4.7** — B1 is a hard blocker; the rest are cheap.
5. **State case 13's precondition.** T12: add-then-`--remove` is byte-identity
   **only** on newline-terminated input. On a no-newline fixture the add
   correctly emits a `\n` (§2.6 step 6) and `--remove` cannot know to strip it.
   The plan is *correct as written* (case 13 runs on case 1's output, whose
   `omarchy` fixture is newline-terminated) — but say so, or the next person adds
   a "case 4 + 13 combined" test and gets a false RED on correct code.
6. **OQ-6 → print the marker block verbatim in the docs.** Then docs and disk are
   byte-identical and R6 (drift) becomes `grep`-detectable rather than a review
   discipline.
7. **Print the `--remove` line on success** (already §5.6) — keep it; revocation
   should be discoverable at the moment of grant.

---

## 4. OQ-1 IS RULED: (B). Stress-testing (B)'s design.

**Position: (B) is workable and cheaper than PLAN.md fears. I find no reason it
cannot work.** Three of the five integration points are already solved by shipped
code. One is a genuine hard blocker PLAN.md never mentions. One kills a PLAN.md
conclusion outright.

PLAN.md §1.4 is now wrong as a *recommendation*, but its hazard analysis is not
wrong — it is the requirements list (B) must satisfy. Keep §1.4's diagnosis,
delete its conclusion. The shadowing trap is real; (B)'s job is to make it
impossible, and the machinery to do so already exists.

### 4.1 IP1 — the shadowing trap. PLAN.md's framing is right; the redirect's is slightly off.

The redirect says consumer mode must stop bootstrap "clon[ing] fleet into
`$PC_TUNE_ROOT/fleet` **and symlink[ing] `~/.local/bin/fleet`**." I checked
(T14): **`bootstrap.sh` never creates that symlink.** `LINKS` (`:43-47`) contains
exactly three entries — nvim, tmux, tmuxinator. There is no fleet entry.

The symlink comes from `install.sh`, run by hand per the prereq comment at
`:16-17`. Good news for (B): the dangerous half of the coupling is **already**
outside bootstrap.sh. Consumer mode must suppress a *clone*, not a symlink.

`fleet` is hardcoded in exactly three places (verified by grep):

| Line | What | Consumer mode must |
|---|---|---|
| `:36` | `REMOTES[fleet]=…` | leave it (harmless data) or drop it |
| `:54` | `for name in nvim tmux tmuxinator fleet` — **container loop** | **not include fleet** |
| `:111` | `for name in nvim tmux tmuxinator fleet` — **verify loop** | **not include fleet** ← *see 4.2, this is the blocker* |

**Required change:** replace both literal loops with one array set by mode:

```sh
CONTAINERS=(nvim tmux tmuxinator fleet)      # worktree mode (default)
[ "$FLEET_MODE" = pacman ] && CONTAINERS=(nvim tmux tmuxinator)
```

Then iterate `"${CONTAINERS[@]}"` at both `:54` and `:111`. That is the whole of
IP1 — a smaller change than PLAN.md §1.4 implies.

**Proof-harness assertion (required):** after a consumer-mode run,
`[ ! -e "$PC_TUNE_ROOT/fleet" ]` **and** `readlink -f "$(command -v fleet)"`
starts with `/usr/`. Both, not either — the first proves no container, the second
proves nothing else shadows.

### 4.2 IP1(b) — THE HARD BLOCKER PLAN.md NEVER MENTIONS

The verify loop at `:111` is not cosmetic. If consumer mode drops fleet from the
container loop but **not** from the verify loop, then for `name=fleet`:
`bare=no`, `wt=0` → `warn` → `fail=1` → `die "bootstrap finished with warnings"`
→ **exit 1**.

Simulated (T16):

```
  ! fleet: bare=no main-wt=0
fail=1  -> bootstrap would: DIE (exit 1)
```

**Consumer mode would fail on every single run, permanently**, while having done
its work correctly. Under `set -euo pipefail` (`:20`) that is a hard non-zero
exit on a successful bootstrap — the worst kind of bug, because the user's
instinct is to re-run, and re-running is (per 4.5) safe but never succeeds.

Not in PLAN.md §1.4, not in §7's risk table, not in the redirect's IP1 framing.
**It is the single most important (B) finding in this document, and it is a
two-line fix** — the same `CONTAINERS` array covers it, which is exactly why the
fix must land at *both* loops or neither.

### 4.3 IP2 — `fleet doctor` on a consumer machine: warns, does **not** go red

I traced `doctor_config_sync` (`bin/fleet:4550-4620`) and simulated the consumer
state (T15).

`doctor_config_sync` runs whenever `PC_TUNE_ROOT` resolves — which it does on a
consumer machine, since pc-tune is cloned. Its `specs` array
(`bin/fleet:4558-4563`) hardcodes `fleet|$HOME/.local/bin/fleet`. In consumer
mode `$root/fleet/.git` doesn't exist → `mains` empty → `canon` empty → first
branch at `:4578`:

```
warn fleet: no worktree claims branch main (cannot verify live link)
```

**Is it RED? No.** I counted `ok=1` occurrences inside `doctor_config_sync`:
**zero**. Only `MISS` sets `ok=1`, and the call site (end of `cmd_doctor`) is
commented *"non-fatal advisories."* **`fleet doctor` exits 0 on a consumer
machine.** The redirect's fear — "a consumer machine with a permanently-red
doctor is a broken product" — does not materialise. It is a
permanently-*warning* doctor: a cosmetic defect, not a broken product.

Two adjacent checks I verified are **fine** on consumer:

- `MISS fleet-hook missing or dangling` (this one *does* set `ok=1`) — the
  package ships `/usr/bin/fleet-hook` → `/usr/lib/fleet/bin/fleet-hook`
  (`PKGBUILD:73,:95`), so `command -v` + `readlink -f` both resolve. Green.
- `warn hooks NOT wired in $prof (run install.sh)` — `fleet setup` wires them, so
  green after setup. But the **advice string is wrong on a consumer machine**
  ("run install.sh" — there is no install.sh). One-line message fix.

**Decision: in scope now, and cheap.** Skip the `fleet` spec when the running
binary is a packaged install:

```sh
case "$(readlink -f "$(command -v fleet)")" in
  /usr/*) ;;                       # packaged: no worktree expected, skip
  *) specs+=("fleet|$HOME/.local/bin/fleet") ;;
esac
```

~5 lines, keyed on an observable fact rather than a mode flag, so it is also
correct for anyone who installs the package without pc-tune at all. Deferring is
defensible (doctor exits 0 either way) but I'd take it now: it is smaller than
the doc paragraph explaining the warning would be.

### 4.4 IP3 — install.sh vs `fleet setup` vs the package: **they already do not fight**

This is where (B) is much cheaper than feared. I read `cmd_setup`'s systemd branch
and the PKGBUILD; the collision is closed by construction.

**The unit branch (`bin/fleet`, `cmd_setup`) has a double guard:**

```sh
if [ -f "$FLEET_DIR/systemd/fleetd.service" ] && \
   [ ! -f /usr/lib/systemd/user/fleetd.service ]; then
```

On a consumer machine both conjuncts fail:

- `FLEET_DIR=/usr/lib/fleet`, and `PKGBUILD:101-103` installs the unit to
  `$pkgdir/usr/lib/systemd/user/` — **not** into `/usr/lib/fleet/systemd/`. I
  grepped every `systemd` mention in the PKGBUILD to confirm no such path exists.
  So the first test is **false**.
- `/usr/lib/systemd/user/fleetd.service` **exists** (the package put it there),
  so the second is **false** too.

→ no `~/.config/systemd/user/fleetd.service` is ever written, and
`systemctl --user enable --now fleetd` binds the packaged unit. **Two units with
the same name cannot coexist in consumer mode.** The in-code comment (*"Packaged
installs already have the unit"*) shows this was deliberate.

For contrast I confirmed the dev side on this box: `FragmentPath=
/home/red/.config/systemd/user/fleetd.service`, and
`/usr/lib/systemd/user/fleetd.service` does not exist. The mirror image. The two
installs occupy disjoint unit paths, and systemd's precedence (`~/.config`
overrides `/usr/lib`) is only ever exercised if *both* exist — which requires
running install.sh on a package machine, i.e. the thing consumer mode prevents.

**Authority answer, unambiguous:** in consumer mode the **package** owns system
files and **`fleet setup`** owns per-user wiring. **`install.sh` must never run**
— bootstrap.sh consumer mode must not call it, and `packaging/fleet-git.install`
already directs the user to `fleet setup`, not install.sh.

**And the enforcement already exists.** `cmd_setup`'s dev-shadow guard:

```sh
onpath=$(command -v fleet)
if [ "$(readlink -f "$onpath")" != "$(readlink -f "$FLEET_DIR/bin/fleet")" ]; then
    echo "ERROR: fleet setup aborted — another fleet shadows this one on PATH:" >&2
    …
    [ "$FORCE" = 1 ] || exit 3
fi
```

If consumer mode's suppression ever regresses and a worktree symlink reappears,
`fleet setup` — the last step of consumer mode — **hard-aborts with exit 3** and
prints both paths. (B) inherits a tripwire on its own worst failure mode for
free. PLAN.md §1.4 argued the shadowing hazard from first principles while this
guard sat in the same file it cites elsewhere; **this is the strongest single
piece of evidence that (B) is safe to build**, and PLAN.md should cite it.

Note the exit-code interaction and treat it as a feature: `fleet setup` exits
**3** on shadow, and PLAN.md §2.7 assigns add-repo.sh exit **3** to "conflict,
human required." Same semantics, same code, two scripts. Consumer mode should
propagate 3, not collapse it to 1.

### 4.5 IP4 — mode idempotency and switching

`bootstrap.sh:10-12` advertises idempotency. Four transitions:

| Transition | Required behaviour | Why |
|---|---|---|
| **consumer → consumer** (re-run) | Clean no-op. Containers skip (`ok … already present`); add-repo.sh exits 0 "already configured" (§3.1 — and PLAN.md is right that a no-op takes **no backup**, so re-runs leave no litter); `pacman -S fleet-git` reinstalls harmlessly; `fleet setup` re-wires idempotently. | Every component is already idempotent. Free. |
| **worktree → worktree** | Unchanged. | Today's behaviour. |
| **worktree machine, run consumer** | **REFUSE, exit non-zero, change nothing.** | This is the shadowed-package bug. Detect via `[ -d "$PC_TUNE_ROOT/fleet/.git" ]` or `readlink -f "$(command -v fleet)"` outside `/usr`. Print the migration recipe (`docs/custom-repo.md:52-53`: `install.sh --uninstall`) and stop. |
| **consumer machine, run worktree** | **REFUSE, exit non-zero, change nothing.** | Symmetric. Cloning the fleet container onto a package machine creates the shadow the moment anyone runs install.sh. Print `pacman -R fleet-git` + `fleet unsetup` (which exists — `bin/fleet:4854`). |

**Refuse, never migrate.** The redirect names the right worst case ("a silent
half-migration leaving BOTH installs present"); the way to make it unreachable is
to never attempt migration inside bootstrap.sh. Migration is three commands the
user runs deliberately, already documented at `docs/custom-repo.md:44-70`. An
automatic migration would have to uninstall a running daemon, unwire hooks from
two Claude profiles, and remove a package — each with its own failure mode, and a
failure *mid-sequence* is precisely the both-installs-present state.
`install-web.sh:47-65` sets the precedent: when it finds an install it doesn't
own, it **refuses and explains**. Consumer mode should read the same.

**Mode must be detected, not remembered.** Do not persist mode in a state file
that can desync from reality. Both refusals key on observable facts (does the
container exist; where does `command -v fleet` resolve). A dotfile saying
"consumer" on a machine that has a worktree is worse than no dotfile.

### 4.6 IP5 — cross-repo ordering: §4's "call it from the local checkout" is **DEAD**

The redirect is right and PLAN.md §4:379-387 is now wrong. Its conclusion —
*"neither curl nor vendor: call it from the local checkout … `$PC_TUNE_ROOT/
fleet/main/packaging/add-repo.sh` exists on disk by the time any fleet-install
step could run"* — depends on the fleet container existing. Consumer mode's
**entire purpose** is that it does not. Verified: in a consumer-mode root, that
path does not exist.

That paragraph must be **deleted, not amended**. It is the one place PLAN.md's
text becomes actively misleading under the ruling.

**Decision: curl, and the dependency is now genuinely hard.** Grounds:

- **Vendoring a copy into pc-tune loses for the reason §4:390 already gives** —
  two divergent scripts, and pc-tune is PRIVATE (verified), so the copy can't be
  curl'd by anyone else anyway. That argument survives the ruling intact; keep it.
- **Curl is viable**: `Redmern/fleet` is PUBLIC and a `packaging/` raw path
  returns **200** (T18). The `-f` flag is load-bearing (§4's table) — keep it.
- **The auth asymmetry is a non-issue.** A consumer running bootstrap.sh already
  needs `gh` authed for the two PRIVATE config repos (`:15`), so it cannot run on
  an unauthenticated machine regardless — while the fleet fetch needs no auth at
  all. Consumer mode never hits the private-raw problem.

**But do NOT reuse the `curl … | sudo bash` one-liner inside bootstrap.sh.**
Download to a temp file, then execute:

```sh
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
curl -fsSL "$RAW/packaging/add-repo.sh" -o "$tmp" || die "…"
sudo sh "$tmp" --yes || rc=$?     # bootstrap already prompted; see below
```

Three reasons this is strictly better than piping inside a script:

1. bootstrap.sh can **inspect the exit code** — and per §2.7 those codes are
   meaningful (3 = conflict → refuse and explain; 2 = preflight → different
   message). A pipe under `set -o pipefail` collapses that distinction.
2. It sidesteps OQ-2's `/dev/tty` trap entirely. bootstrap.sh **has** a real tty
   (invoked directly, not piped), so **bootstrap.sh does the disclosure and the
   consent prompt itself**, then passes `--yes`. Consent preserved, §5.6's "the
   friction was doing the disclosing" honoured, and add-repo.sh never fights for
   stdin. This is §1.9's never-self-`sudo` rule paying off exactly as designed.
3. A truncated download is caught by `curl -f` + the temp file before anything
   executes — belt and braces with §2.3's `main()` wrapper.

**Ordering is now a hard, blocking dependency.** PLAN.md §1.3's sequence is still
correct but its *severity* changes: under (A) a stale raw URL was a doc bug; under
(B) it is a **runtime failure of bootstrap.sh on a fresh machine**. Elevate step 2
of §1.3 ("verify the raw URL serves 200") from a note to a gate, and have consumer
mode fail loudly with the manual fallback stanza printed if the fetch fails — the
fallback §1.1 already insists the docs keep.

**One privilege-design point neither document raises.** bootstrap.sh currently
needs **no** root (it writes `$PC_TUNE_ROOT` and `$HOME` only). Consumer mode
introduces three privileged steps (add-repo.sh, `pacman -Sy`, `pacman -S`).
Consumer mode should call `sudo -v` **once up front**, after its own consent
prompt and before any work, so the user authenticates at one predictable moment
rather than being ambushed three times mid-run — and so a user who declines fails
fast, before the containers are cloned.

### 4.7 (B) — required additions to PLAN.md

Nothing here changes add-repo.sh's design. All of it is pc-tune-side plus two
small fleet-side edits.

| # | Addition | Size | Severity |
|---|---|---|---|
| B1 | `CONTAINERS` array driving **both** `:54` and `:111`. | ~3 lines | **Blocker** (§4.2) |
| B2 | Refuse both cross-mode transitions; never migrate. Key on observable state, not a mode file. | ~12 lines | **High** (§4.5) |
| B3 | Curl-to-temp-file + exit-code handling + `sudo -v` up front + bootstrap-side consent prompt then `--yes`. Delete PLAN.md §4:379-387. | ~20 lines | **High** (§4.6) |
| B4 | `doctor_config_sync` skips the `fleet` spec when `command -v fleet` resolves under `/usr/`; fix the "run install.sh" advice string. | ~5 lines | Medium (§4.3) |
| B5 | Proof-harness cases: consumer run leaves **no** `$PC_TUNE_ROOT/fleet`; `command -v fleet` under `/usr`; **no** `~/.config/systemd/user/fleetd.service`; consumer-mode verify loop **exits 0**; both cross-mode runs refuse and leave the filesystem byte-unchanged. | ~5 cases | **High** |

B5's fourth case is the regression test for §4.2 and would have caught the
blocker. It needs a `PC_TUNE_ROOT`+`HOME` sandbox — which `bootstrap.sh:11-12`
**already supports by design** (*"Honors PC_TUNE_ROOT … so it can be
sandbox-tested by overriding both PC_TUNE_ROOT and HOME"*). Another case of
existing code already accommodating (B).

### 4.8 Verdict on (B)

**Buildable, and I found nothing that makes it unworkable.** The five integration
points resolve as: **IP3 already solved** (double-guarded unit branch + shadow
guard with exit 3); **IP2 a cosmetic warn, not red** (doctor exits 0); **IP4
solved by refusing rather than migrating**, with every component already
idempotent; **IP1 a three-line change** — plus one **hard blocker** (the verify
loop, §4.2) that neither PLAN.md nor the redirect names and that a two-line fix
closes; and **IP5 kills one PLAN.md paragraph**, replaced by curl-to-temp, which
is better than the one-liner because it restores exit-code handling and resolves
OQ-2's tty trap for free.

The honest summary: **PLAN.md talked itself out of (B) on scope-creep grounds
without checking how much of (B) was already implemented.** §1.4 argued the
shadowing hazard from first principles while `cmd_setup`'s dev-shadow guard —
which hard-aborts on exactly that hazard, with a dedicated exit code — sat in the
file. Total (B) cost is roughly 40 lines across two repos plus five harness
cases, and the hazard §1.4 feared most is already instrumented.

---

## 5. Three corrections the plan needs (from a friendly lens)

I am arguing for this plan, and it is strong. Three factual claims are wrong; all
are cheap, but two change what a test asserts.

### 5.1 §2.8 — "pacman errors on duplicate sections" is FALSE

T6, on a conf with two `[fleet]` stanzas:

```
core
omarchy
fleet
fleet
rc=0
Server = https://a/repo
```

pacman lists the repo **twice**, silently takes the **first** `Server`, exits
**0**. This *strengthens* the mitigation: the plan proposes the `mkdir` lock while
calling the failure loud; it is silent, which raises the lock from "low
probability, cheap to close" to "the only thing between a race and an
undiagnosable repo pinned to a stale Server forever." Keep the lock, fix the
rationale, keep case 17's pass condition (`exactly one [fleet]`) — now clearly
load-bearing.

### 5.2 §3.4 — "pacman tolerates trailing `\r` poorly in values" is FALSE on 7.1.0

T9, on a fully CRLF conf: `repo-list` → `core fleet`, rc=0, and `cat -A` on the
parsed value shows `Server = https://x/repo$` — **no `^M`**. pacman strips it
cleanly. Demote case 5 from correctness to **cosmetic file hygiene** (matching
existing line endings is still right — it just isn't preventing a pacman
failure), and drop the proposed CRLF doc warning rather than writing it.

### 5.3 §6.3 — the `omarchy` fixture as specified does not parse

A byte-shape copy of this machine's conf (§0 item 4) omits `Architecture`, and
`pacman-conf` rejects it:

```
error: mirror 'https://pkgs.omarchy.org/stable/$arch' contains the '$arch'
variable, but no 'Architecture' is defined.
error parsing '<fixture>'
```

Every fixture needs `Architecture = auto` in `[options]`, or case 16 — the most
valuable case — fails on correct code. Exactly why addition #3 (assert fixture
validity first) earns its four lines.

---

## 6. Summary

**PROCEED.** The three defining decisions — EOF-append over parsing,
marker-delimited managed blocks, `FLEET_PACMAN_CONF` as an explicit test seam —
are each independently correct and verified. The security section is honest in a
rare way (it argues *against* the comfort its own docs sell).

Required before implementation:

1. **§1.4's conclusion is superseded by the (B) ruling.** Keep its hazard
   analysis as (B)'s requirements list; delete its recommendation. **Delete
   §4:379-387 outright** — "call it from the local checkout" is false under (B).
2. **Add B1–B5 (§4.7).** B1 is a blocker: without it consumer mode exits 1 on
   every successful run (§4.2).
3. **OQ-7 → yes**, case 16 hard (T5: rc=0 hides the worst bug).
4. **Correct §2.8** (duplicates are silent, not an error), **§3.4** (CRLF is
   fine), **§6.3** (`Architecture = auto` in fixtures), and state case 13's
   newline-terminated precondition.
5. **Promote the `Include`-glob observation** from §3.11 into §2.1 — it proves
   EOF-append is the only *correct* choice, not merely the simple one.

Unchanged and endorsed: prompt-by-default with `/dev/tty` for the standalone
one-liner (OQ-2) — and note that in consumer mode bootstrap.sh prompts instead
and passes `--yes` (§4.6), the cleaner resolution of that same question; deferred
GPG with the written trigger (OQ-5); no `-Sy` inside add-repo.sh (OQ-4) —
consumer mode runs `pacman -Sy` as its own step, exactly the separation §2.6
argued for; `packaging/` placement; no shipping inside the package (OQ-3).

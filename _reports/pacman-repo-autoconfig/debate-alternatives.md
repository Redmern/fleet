# ADVISER 3 — SHAPE. Given (B) is ruled, what shape should (B) take?

**Lens:** question the premise, not the details. I do not review the insertion
algorithm, exit codes, or the 21 test cases — Advisers 1/2/4 own those.

**Status:** the human has ruled **(B)** — `bootstrap.sh` gains a consumer mode.
Not re-litigated below. This report answers the successor question: *what is the
right shape of (B), and what must `add-repo.sh` look like now that (B) is a hard
consumer of it?*

**Verdict up front.** (B) is well-founded — a real non-dev machine makes the
standing `pacman -Syu` channel genuinely worth having, which is the strongest
argument for the `[fleet]` repo anywhere in this project. But three things must
change or (B) ships broken:

1. **The mode must be PERSISTED, not passed.** A flag alone makes `bootstrap.sh`'s
   documented "just re-run it, it's idempotent" idiom **destructive** on a
   consumer machine. This is the single highest-severity finding in this report.
2. **`/etc/pacman.conf` is a wholesale-managed file on omarchy** — an appended
   stanza is silently destroyed by `omarchy-refresh-pacman` / `omarchy-channel-set`.
   The PLAN cites omarchy as *validation* of the append approach; it is the
   opposite. (B) makes this worse, because (B) targets omarchy machines by
   construction.
3. **The pipe must go.** Under (B) the caller is non-interactive, which collides
   head-on with §5.6's prompt-by-default. The resolution is not to weaken the
   prompt — it is to move the disclosure into `bootstrap.sh` and drop
   `curl | sudo bash` from primary. This makes OQ-2 disappear entirely.

---

## 0. The omarchy mechanism — reported prominently, as requested

The PLAN's §0 item 4 reads the live `[omarchy]` stanza at `/etc/pacman.conf:28-30`
and concludes: *"Omarchy already does precisely what we propose, appended at EOF.
That is both validation of the approach and the reason §2's insertion algorithm
can be far simpler."*

**That inference is wrong, and wrong in the dangerous direction.** I diffed the
live file against omarchy's canned template:

```
diff ~/.local/share/omarchy/default/pacman/pacman-stable.conf /etc/pacman.conf
→ IDENTICAL (705 bytes, byte-for-byte)
```

`/etc/pacman.conf` here is not a curated file omarchy appended to. It **is**
omarchy's file, installed wholesale:

| Where | What it does |
|---|---|
| `~/.local/share/omarchy/bin/omarchy-refresh-pacman:19` | `sudo cp -f "$OMARCHY_PATH/default/pacman/pacman-$channel.conf" /etc/pacman.conf` — **wholesale replace**, then `pacman -Syyuu --noconfirm` |
| `bin/omarchy-channel-set` | every channel switch (`stable`/`rc`/`edge`/`dev`) calls `omarchy-refresh-pacman` |
| `install/preflight/pacman.sh:6`, `install/post-install/pacman.sh:2` | same `cp -f` on install / reinstall |
| `migrations/*.sh` | surgical, guarded `sed -i` (`grep -q '^Color' \|\| sudo sed -i …`); 326 migrations, state-tracked in `~/.local/state/omarchy/migrations` |

`omarchy-refresh-pacman` is **user-facing and menu-exposed** — it carries an
`omarchy:summary=` header and sits in the menu group described as *"Reset config
to defaults"*.

### Consequence

**An appended `[fleet]` stanza is destroyed by `omarchy-refresh-pacman` or any
`omarchy-channel-set`, silently.** Nothing errors. `pacman -Syu` simply stops
carrying fleet updates; the machine freezes on one `fleet-git` build forever with
no signal. This is absent from the PLAN's 12-row §3 edge-case table and its 8-row
risk register.

**Under (B) this matters more, not less.** `bootstrap.sh:15` names omarchy as a
prereq — *"Arch + omarchy (the configs assume it)"* — so **every** machine
consumer mode will ever run on is an omarchy machine, i.e. one where the file
consumer mode edits is owned and periodically overwritten by another tool.

Two honest qualifications, so I am not overstating:

1. **Routine `omarchy update` does NOT clobber.** I traced `omarchy-update` →
   `omarchy-update-perform`, which runs `omarchy-update-keyring /
   -available-reset / -system-pkgs / omarchy-migrate / -aur-pkgs / -orphan-pkgs /
   omarchy-hook post-update`. No `cp -f`. The clobber is confined to explicit
   refresh, channel-switch, and reinstall. Occasional, not continuous.
2. Omarchy's own third-party-repo idiom (the Mac T2 case,
   `install/post-install/pacman.sh:6-12`) **is** `cat <<EOF | sudo tee -a
   /etc/pacman.conf`. So the PLAN's stanza *shape* matches omarchy practice. What
   omarchy adds and the PLAN lacks is **re-application** — omarchy re-runs that
   append at every post-install, because it knows its own `cp -f` ate it.

### Should fleet reuse or mimic it?

- **Mimic `cp -f`: no.** That file is omarchy's product. Two owners, one file, no
  `.pacnew` semantics — strictly worse than appending.
- **Add an omarchy migration: no.** `migrations/` lives in omarchy's git repo and
  `omarchy-update-git` runs `git -C $OMARCHY_PATH pull --autostash`; an injected
  migration gets stashed, conflicted, or reset away.
- **Reuse `omarchy hook`: YES.** This is the real find. Omarchy ships a
  first-class extension point:
  - `bin/omarchy-hook <name>` runs `~/.config/omarchy/hooks/<name>` and every file
    in `<name>.d/`.
  - `bin/omarchy-hook-install <type> <file>` is the public installer
    (`omarchy hook install post-update ~/my-hook`).
  - `omarchy-update-perform:18` calls `omarchy-hook post-update` on **every** update.
  - **red already uses this directory** — `~/.config/omarchy/hooks/` contains
    hand-written `generate-tmux-pills`, `generate-swaync-colors`, `theme-set`.

A ~10-line `~/.config/omarchy/hooks/post-update.d/fleet-repo` that re-asserts the
stanza if absent converts a silently-lossy one-shot into a self-healing invariant,
via a mechanism red already runs. **Consumer mode should install this hook.** It
is worth more than every edge case in PLAN §3 combined, because it is the only fix
for the only failure mode that is both likely and silent.

It is omarchy-specific, and correctly skipped elsewhere: `[ -d
~/.config/omarchy/hooks ]`. Two lines, not a fork.

---

## 1. Integration point 1 — the shadowing trap, and a correction to PLAN §1.4

**PLAN §1.4 overstates what `bootstrap.sh` does.** It says *"`bootstrap.sh:32-37`
lists `fleet` in `REMOTES` … and the pc-tune workflow symlinks
`~/.local/bin/fleet` into it."* The first half is right; the second half is not
`bootstrap.sh`.

Verified: `bootstrap.sh` **never** creates `~/.local/bin/fleet` and **never** runs
`install.sh`. `grep -n "local/bin\|install.sh"` returns exactly one hit —
**line 17, a prereq comment**. The `LINKS` array (43-47) contains only
`nvim`, `tmux`, `tmuxinator`; fleet is deliberately absent.

So the shadow is created by the *prereq step* (`~/proj/fleet/install.sh`), not by
`bootstrap.sh`. This slightly softens R1 — but it creates a subtler trap for (B):
**consumer mode's cleanup responsibility is for a symlink `bootstrap.sh` did not
create and cannot see in its own LINKS array.** It must look for it explicitly.

### What must change, concretely

The repo list is hardcoded **three times**, and two of them are literal:

| Line | Code |
|---|---|
| 32-39 | `declare -A REMOTES=( [nvim] … [fleet] … )` |
| **54** | `for name in nvim tmux tmuxinator fleet; do`  ← container clone loop |
| **111** | `for name in nvim tmux tmuxinator fleet; do`  ← **verify** loop |

Consumer mode must drop `fleet` from **all three**. Missing line 111 is a concrete,
silent-looking failure: the verify loop sets `fail=1` when the fleet container is
absent, and the script ends with `die "bootstrap finished with warnings"` →
**exit 1 on a fully successful consumer run**, under `set -euo pipefail`. A
consumer mode that always exits non-zero is a broken product.

**Shape recommendation:** replace all three with a single `REPOS=(nvim tmux
tmuxinator fleet)` array built once from the mode, and iterate `"${REPOS[@]}"`.
That makes "drop fleet" a one-line change in one place instead of a three-site
edit with one site that fails loudly and one that fails at the end.

Additionally, consumer mode must **detect an existing dev shadow** — see §4.

---

## 2. Integration point 2 — does `fleet doctor` go RED on a consumer machine?

**No. It goes green with a permanent spurious warning.** I read `cmd_doctor`
(`bin/fleet:4478-4521`) and `doctor_config_sync`.

`cmd_doctor` sets `ok=1` (non-zero exit) for only three things: a missing hard dep
(`tmux nvim git python3 fzf`), missing `claude`, and a **missing or dangling
`fleet-hook`**. On a packaged consumer machine `/usr/bin/fleet-hook` symlinks to
`/usr/lib/fleet/bin/fleet-hook`, which exists — so it resolves clean. Everything
else is `warn`. **Doctor does not go RED.** Good news, and it means (B) does not
ship a broken-by-default doctor.

But `doctor_config_sync` carries a hardcoded spec:

```
"fleet|$HOME/.local/bin/fleet"
```

It resolves `$root/fleet/.git` (`root="${PC_TUNE_ROOT:-$HOME/proj/pc-tune}"`) and,
finding no container, prints:

> `warn fleet: no worktree claims branch main (cannot verify live link)`

On a consumer machine pc-tune **does** exist — that is the whole premise of (B) —
so this warn fires on every `fleet doctor`, forever, telling the user to fix a
worktree they deliberately do not have. It is non-fatal (the function is
documented *"non-fatal advisories"* and never touches `ok`), so this is a polish
issue, not a correctness one. But a permanently-wrong advisory trains users to
ignore doctor output, which is how the *real* warnings get missed.

**Fix:** `doctor_config_sync` should drop `fleet` from `specs` when the machine is
in consumer mode. That requires doctor to *know* the mode — which is the same
requirement as §4. One marker serves both.

**This is a fleet-side change (B) forces, and the PLAN scopes no fleet change
beyond `add-repo.sh` + docs.** Worth flagging to the implementer: (B)'s blast
radius includes `bin/fleet`, not just `packaging/`.

---

## 3. Integration point 3 — install.sh vs `fleet setup` vs the package

**They do fight, and the dev side wins.**

- `install.sh` writes `~/.config/systemd/user/fleetd.service`.
- The package writes `/usr/lib/systemd/user/fleetd.service` (`PKGBUILD` §3,
  `ExecStart` rewritten to `/usr/bin/fleetd`).

Same unit name; `~/.config/systemd/user` takes precedence over
`/usr/lib/systemd/user`. So a machine with both runs the **dev** unit pointing at
`~/.local/bin/fleetd`. `docs/custom-repo.md:44-70` already documents exactly this
(*"a `~/.config/systemd/user` unit shadows the packaged one, so the package stays
masked and unused"*).

On a **clean** consumer machine there is no conflict, because `install.sh` was
never run. So the rule for (B) is simple and absolute:

> **Consumer mode: package + `fleet setup`. Never `install.sh`.**

`fleet setup` is authoritative there — it is the documented per-user half that
pacman structurally cannot do (`packaging/README.md`, `Formula/fleet.rb` caveats,
`fleet-git.install`). Consumer mode must not call `install.sh` at any point, and
should say so in a comment, because `install.sh` is what the current
`bootstrap.sh:14-19` prereq comment tells you to run — a reader migrating to
consumer mode will reach for it by habit.

---

## 4. Integration point 4 — mode idempotency. **The highest-severity finding.**

`bootstrap.sh` today has **no argument parsing whatsoever**. Verified: no
`getopts`, no `case`, no `$1`, no `$@` anywhere in the file. Its only input is the
`PC_TUNE_ROOT` env var. Under `set -u`, an unguarded `$1` is itself an error. So
(B) means inventing an arg surface from zero.

That matters because of what the script promises. `bootstrap.sh:10-12`:

> *"Idempotent: safe to re-run. Skips anything already set up; backs up anything
> it has to displace."*

And `docs/multi-device-update.md` step 3a instructs exactly that:

> *"`bootstrap.sh` is idempotent — it (re)creates any missing container or live
> symlink … Safe to run."*

### The trap

If the mode is a **flag only**, then on a consumer machine:

```sh
cd "$PC" && ./bootstrap.sh        # the documented re-run idiom
```

…silently re-clones the fleet worktree container, re-creating the dev-model
artefact consumer mode exists to prevent. The user followed the documentation
exactly and got the §1.4 harm back. And it is invisible: `bootstrap.sh` prints
`cloning bare → fleet/.git` amid three other repos doing the same thing.

**This converts `bootstrap.sh`'s single most-advertised property — safe
idempotent re-run — into a silent regression vector.** It is worse than the
original R1, because R1 at least happened once at install time where a human was
watching.

### Shape ruling: persist the mode

**The flag is acceptable as the *entry* surface, but it MUST write a marker, and
every subsequent run MUST read the marker and default to it.** Precedence:

```
explicit flag  >  persisted marker  >  default (worktree)
```

Marker location: `$PC_TUNE_ROOT/.fleet/install-mode` fits the existing convention —
pc-tune already tracks `.fleet/harness` and `.fleet/protected` (they are 2 of its
7 tracked files), so `.fleet/` is the established home for pc-tune-level fleet
state and needs no new concept. **The same marker answers §2** (doctor reads it to
skip the fleet spec) **and §1** (the repo list is derived from it).

An env var alone (`PC_TUNE_FLEET=pacman`, mirroring `PC_TUNE_ROOT`) is **wrong for
the same reason a flag is**: it is not persisted, so the bare re-run still
regresses. It is fine as an *additional* override for sandbox testing — which
`bootstrap.sh:10-12` explicitly cares about (*"can be sandbox-tested by overriding
both PC_TUNE_ROOT and HOME"*) — but it cannot be the mechanism.

Autodetection alone is also wrong: "is `/usr/bin/fleet` present?" is ambiguous on
a machine mid-migration, which is precisely when you need the answer to be
unambiguous.

### The four transitions

| Transition | Ruling |
|---|---|
| **consumer → consumer** (re-run) | Idempotent no-op. Reads marker, skips the fleet container, re-asserts the stanza (already idempotent per PLAN §2.4), re-runs `fleet setup`. Safe. |
| **worktree → consumer** | **REFUSE, do not auto-migrate.** If `~/.local/bin/fleet` resolves into `$PC_TUNE_ROOT/fleet/main`, print the exact remediation and exit non-zero. |
| **consumer → worktree** | **WARN and proceed.** Print that `fleet-git` is still installed and will be shadowed; suggest `pacman -R fleet-git`. Do not auto-remove (needs sudo, and this direction is benign — the dev install correctly wins). |
| **neither → either** | Normal path. |

**Why refuse rather than migrate on worktree → consumer:** auto-removal is
destructive and the dev worktree may hold unpushed commits —
`docs/config-sync-architecture.md` calls unpushed `main` *"the #1 source of
two-laptop divergence"* and its F2/F6 failure rows are exactly this. The
remediation already exists and is already documented at `docs/custom-repo.md:50`:

```sh
cd ~/proj/pc-tune/fleet/main && ./install.sh --uninstall
```

So consumer mode should print *that line* and stop. **The worst outcome the brief
names — a silent half-migration leaving BOTH installs — is exactly what
auto-migration produces when `install.sh --uninstall` partially fails**, since it
must remove symlinks, a systemd unit, and hook entries in two Claude profiles.
Refusing makes the human run one documented command and re-run; migrating makes
`bootstrap.sh` responsible for a multi-step teardown it did not perform and cannot
verify.

There is a strong precedent for refusal **inside this very repo**, which the PLAN
reads without noticing: `install-web.sh:57-72` refuses to clobber a
`~/.local/bin/fleet` resolving outside its managed dir, and prints the resolved
path:

> *"`fleet install: ~/.local/bin/fleet already exists and resolves OUTSIDE the
> managed dir — refusing to clobber it`"*

Consumer mode should reuse that check verbatim, inverted. `bootstrap.sh` also
already has the right idiom for this class of cross-tool-ownership hazard — its
chezmoi warning at lines 99-104 (*"is chezmoi-managed — chezmoi apply will
overwrite this symlink"*). Same instinct, same `warn()`, same shape.

---

## 5. Integration point 5 — cross-repo ordering. **PLAN §4's conclusion is DEAD.**

PLAN §4 concluded: *"neither curl nor vendor: call it from the local checkout …
`$PC_TUNE_ROOT/fleet/main/packaging/add-repo.sh` exists on disk by the time any
fleet-install step could run. It is strictly better than both options."*

**That is now false, and (B) is what killed it.** Consumer mode's defining
behaviour is *dropping fleet from the container loop* (§1). So
`$PC_TUNE_ROOT/fleet/main/` **does not exist** in the exact mode that needs the
script. The only path where §4's conclusion held is the path that no longer runs
it.

Three options remain. My call: **curl to a file, not a pipe, and not a vendored
copy.**

| Option | Verdict |
|---|---|
| **Vendor a copy into pc-tune** | **No.** PLAN §4 is right: two divergent scripts, and pc-tune is private so the copy serves no third party. (B) does not change this. |
| **Pipe: `curl … \| sudo bash -s -- --yes`** | **No.** See §6. Loses the reviewable artefact and the exit-code granularity that PLAN §2.7 says `set -euo pipefail` needs. |
| **Curl to a temp file, then execute** | **Yes.** |

```sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL https://raw.githubusercontent.com/Redmern/fleet/main/packaging/add-repo.sh \
     -o "$tmp/add-repo.sh"
sudo bash "$tmp/add-repo.sh" --yes
```

**Why this shape:**

- The network dependency is **already there** — `bootstrap.sh` clones four repos
  over the network before it could reach this point. Curl adds no new class of
  failure.
- `Redmern/fleet` is **public** (PLAN §0 item 2, verified), so the raw URL works
  unauthenticated even though pc-tune is private.
- It preserves a **reviewable, re-runnable artefact** and a **clean exit code**.
  PLAN §2.7 argues distinct codes matter *specifically because* `bootstrap.sh`
  runs under `set -euo pipefail` and would need to distinguish "already fine" (0)
  from "conflict, human required" (3) from "broken" (4). **Through a pipe to
  `sudo bash`, that granularity is exactly what you lose the ability to handle
  cleanly** — the PLAN designed the exit codes for a caller it then proposed to
  invoke through a pipe.
- It matches what the docs should tell humans to do (§6), so there is **one shape,
  not two**.

The hard ordering constraint from PLAN §1.3 stands and tightens: `add-repo.sh`
must be merged and pushed to `Redmern/fleet@main` **before** the pc-tune consumer
mode ships, because consumer mode now fetches it by URL at runtime with no local
fallback. Worth adding a preflight in consumer mode that fails with a clear
message if the fetch 404s, rather than letting `set -e` abort mid-bootstrap with a
bare curl error. §8a offers a fallback that softens this dependency.

---

## 6. The one-liner's shape — and how (B) *dissolves* OQ-2

The brief flags a real collision: (B) invokes `add-repo.sh` **non-interactively**,
which fights §5.6's prompt-by-default and OQ-2's `/dev/tty` problem. OQ-2 states
the trap correctly — *"every documented invocation is `curl … | sudo bash`, where
stdin is the pipe, not the tty; a naive `read` gets EOF"* — and concludes *"the
prompt design is not viable without it."*

**The right resolution is not to weaken the prompt. It is to drop the pipe.**

Note where the EOF problem actually comes from: **it is created entirely by the
pipe form.** Neither real caller needs it:

| Caller | Has a tty? | What it does |
|---|---|---|
| A human running `sudo bash ./add-repo.sh` from a downloaded file | **Yes** | Prompts normally. No `/dev/tty` gymnastics. |
| `bootstrap.sh` consumer mode | Yes (it is an interactive script a human ran) | **Discloses once, itself, then passes `--yes`.** |

So: **`bootstrap.sh` owns the disclosure.** It is already an interactive script
run by a human at a terminal, it already prints structured output via
`log()`/`ok()`/`warn()`, and it is already where the user is paying attention. It
prints the stanza, states plainly that this grants a standing root-code-execution
channel redeemed at every future `pacman -Syu` (PLAN §5.1's honest framing),
confirms once, then calls `add-repo.sh --yes`. R2 — *"automating the edit removes
the attention moment that was doing the disclosure"* — is paid back at the level
that actually has the user's attention, instead of inside a script being fed
through a pipe.

**With the pipe demoted, OQ-2 has no remaining case to solve.** Keep
prompt-by-default and `--yes`; the `/dev/tty` fallback becomes belt-and-braces
rather than the load-bearing thing the PLAN says the design is non-viable without.

### Which form is primary in the docs?

PLAN §1.1 makes `curl | sudo bash` primary and demotes the manual stanza to *"if
you'd rather not pipe to shell."* **I think that ordering is wrong, and the
`install-web.sh` precedent does not transfer.**

- `install-web.sh` is `curl … | sh` — **unprivileged**, writing only to
  `~/.local/share/fleet` and `~/.local/bin`.
- `add-repo.sh` would be `curl … | sudo bash` — **root**, writing to `/etc`.

Reusing the house style is right for *structure*: the `main()` anti-truncation
wrapper is genuinely mandatory here, more so than in `install-web.sh`, since a
partial write bricks pacman. It is wrong for *doc placement*. `install-web.sh:6-16`
itself offers download-read-run as the cautious path — under root, that stops
being the cautious path and becomes the correct default.

**Does `sudo bash` vs `sh` change the calculus? Yes, on two axes §5.3 undersells:**

1. **No reviewable artefact.** Piped, nothing lands on disk — nothing to `less`,
   diff against the next run, or keep.
2. **Split trust boundary.** `curl` runs as you; `bash` runs as root. A redirect,
   a rate-limit HTML body, or a `main` compromise converts directly into root
   execution, with `-f` as the only guard.

§5.3 rates curl-pipe TOFU *"moderate, one-shot"* and ranks it third. That ranking
is defensible **for `install-web.sh`**; it is carried to a root-privileged script
without re-derivation. And the decisive asymmetry: **the payload is four lines of
text.** The one-liner asks a user to grant root execution to a remote URL to avoid
pasting four lines they could read. That trade is upside down in a way it is not
for `install-web.sh`, whose payload — a clone, a real installer, hook wiring —
genuinely cannot be pasted.

**Ruling:**

- **`README.md` install block:** keep the manual stanza (what it prints today),
  plus a pointer to consumer bootstrap for the automated path.
- **`docs/custom-repo.md` §(a):** **download-read-run is primary.** Manual stanza
  stays as the no-script path.
- **`curl | sudo bash`:** appears once, in `docs/custom-repo.md` only, explicitly
  labelled the convenience path.
- **`bootstrap.sh`:** uses curl-to-file (§5) — the same shape the docs recommend.

---

## 7. Mode flag surface

`bootstrap.sh` has **zero** argument parsing today (verified: no `getopts`, no
`case`, no `$1`/`$@`). So this is a from-scratch surface, and under `set -u`
unguarded positional access is itself an error — the parser must use `"${1:-}"`
throughout.

| Surface | Verdict |
|---|---|
| `--fleet=pacman` (plan's sketch) | **Fine as the entry surface**, and it reads well. But insufficient alone — see §4, it must persist. |
| Positional mode (`./bootstrap.sh consumer`) | Worse. `bootstrap.sh` has no positional vocabulary; a bare word is easy to fat-finger into a silent wrong mode. |
| Env var only (`PC_TUNE_FLEET=pacman`) | **Insufficient**, same reason as a flag: not persisted, bare re-run regresses. Keep as a *test* override alongside `PC_TUNE_ROOT`, which the header already contemplates. |
| Autodetection only | Wrong. Ambiguous exactly when it matters (mid-migration). |
| Separate entry point (`bootstrap-consumer.sh`) | This was option (C), now closed. Also duplicates the container/symlink/verify logic. |
| **`--fleet=pacman` + persisted marker + env override** | **Recommended.** Precedence: flag > `.fleet/install-mode` > default `worktree`. |

Keep the default `worktree`, as sketched: it preserves current behaviour for the
dev box, which is the machine that runs this most.

---

## 8. Missed shapes — is one a better fit for `bootstrap.sh`'s needs?

The brief asks me to say so if true. **Partly true, with an important concession.**

**The concession first, because it is what (B) changes.** My pre-ruling position
was "no repo by default" — `pacman -U` a stable-named asset, since the standing
`TrustAll` channel is a large grant for a rare need. **(B) substantially weakens
that argument.** A consumer machine that catches up on `pacman -Syu` without
thinking is precisely the point of consumer mode, and `-Syu` integration is the
only shape that delivers it. **The `[fleet]` repo is justified for (B), and (B) is
the best argument for it anywhere in this project.** I withdraw the objection for
the consumer-mode case.

Where the missed shapes still earn their place:

### 8a. `pacman -U <stable URL>` — as the *bootstrap*, not the *update* mechanism

```sh
sudo pacman -U https://github.com/Redmern/fleet/releases/download/repo/fleet-git-latest.pkg.tar.zst
```

Verified feasible: `pacman -U` accepts an https URL, and `pacman-conf
LocalFileSigLevel` → `PackageOptional PackageTrustedOnly` on this box, so an
unsigned package installs with no stanza and no keyring work. The only blocker is
naming — the workflow uploads `fleet-git-r<N>.<hash>-…` and prunes the previous
one, so there is no stable URL. That is a **~3-line CI change**: `cp` the built
package to a fixed `fleet-git-latest.pkg.tar.zst`, `--clobber` upload it
alongside, exempt it from the prune step. The DB keeps referencing the versioned
name; nothing else changes.

**Why it still matters under (B):** it is a **fallback that removes the hard
cross-repo dependency of §5.** If the `add-repo.sh` fetch 404s (not yet merged,
rate-limited, offline), consumer mode can still deliver a working fleet with one
line and no script, then tell the user to add the repo later. It converts §5's
hard dependency into a soft one. Cheap insurance for 3 lines of CI.

### 8b. `fleet setup --add-repo` (OQ-3) — **(B) makes this stronger, not weaker**

§1.1 rejects it as *"circular — shipping it inside the package it bootstraps."*
True for first install. **But (B) creates two cases where it is not circular:**

1. **Re-assertion after an omarchy clobber (§0).** The machine already has fleet;
   the *repo entry* is what vanished. Only an installed fleet can self-heal — and
   under (B) that self-healing is what keeps consumer mode's whole value
   proposition (`-Syu` updates) true over time.
2. **Repointing the `Server`** later, which §1.1 already concedes.

It also gives the omarchy post-update hook (§0) something clean to call, rather
than the hook re-implementing the stanza logic or shelling out to a curl'd script.

**Recommendation: ship `add-repo.sh` for the bootstrap case, and expose the same
logic as `fleet setup --add-repo` for the steady state.** Consumer mode uses the
former once; the omarchy hook uses the latter forever.

### 8c. AUR — worth one explicit "no", not silence

`yay` is present at `/usr/bin/yay` on this box, and since `bootstrap.sh:15` makes
omarchy a prereq, an AUR helper exists across the entire target population by
construction. `yay -S fleet-git` needs **no `pacman.conf` edit at all**, has **no
`TrustAll`**, and is immune to the omarchy clobber. `packaging/README.md` already
documents every publish step; the only unmet prerequisite is that red has never
registered the name.

I rank it below the repo for (B) because it publishes red's personal tooling into
a public registry with implied support expectations — a product decision, not a
technical one — and because driving `yay` non-interactively from `bootstrap.sh`
wants care. But it is the one option that makes §0's clobber structurally
impossible, and the PLAN never weighs it despite documenting it in full. **Worth a
recorded "no, because…" rather than silence.**

### 8d. Include-glob drop-in / pacman hook

**PLAN §5.5 is right; nothing to add.** Its refinement — that `Include` supports
globs, but installing the `Include` line *is* the same edit we are removing — is
correct, and (B) does not change it. Rejection stands.

---

# ANSWERS

## What is the right shape of (B)?

```
./bootstrap.sh --fleet=pacman
```

1. **Persist the mode** to `$PC_TUNE_ROOT/.fleet/install-mode` (alongside the
   existing `.fleet/harness`, `.fleet/protected`). Precedence: flag > marker >
   default `worktree`. **Non-negotiable** — without it the documented "safe to
   re-run" idiom silently re-creates the dev shadow (§4).
2. **Derive the repo list from the mode.** Collapse the three hardcoded sites
   (`REMOTES`, line 54, line 111) into one `REPOS=()` array. Missing line 111
   makes a successful consumer run exit 1 (§1).
3. **Refuse on worktree → consumer.** If `~/.local/bin/fleet` resolves into
   `$PC_TUNE_ROOT/fleet/main`, print `install.sh --uninstall` (already documented
   at `docs/custom-repo.md:50`) and stop. Reuse `install-web.sh:57-72`'s check,
   inverted. Never auto-migrate (§4).
4. **Disclose in `bootstrap.sh`, once, at the tty**, then call `add-repo.sh --yes`.
   Pays back R2 where the user is actually looking, and dissolves OQ-2 (§6).
5. **Fetch by curl-to-file, not pipe, not vendor** — PLAN §4's "call it from the
   local checkout" is dead, because consumer mode is defined by that checkout not
   existing (§5). Preserve `add-repo.sh`'s exit codes; the PLAN designed them for
   this caller.
6. **Install the omarchy post-update hook** so the stanza self-heals (§0). Gate on
   `[ -d ~/.config/omarchy/hooks ]`.
7. **Package + `fleet setup`. Never `install.sh`** (§3).
8. **Teach `doctor_config_sync` the mode** so it stops advising a consumer machine
   to fix a worktree it deliberately lacks (§2).

## Is `add-repo.sh` still the right artefact?

**Under (B), yes — with the three changes above.** My pre-ruling objection was
that it was ~200 root-privileged lines serving a population of zero. (B) supplies
the population, and supplies the reason the standing `-Syu` channel is worth
having. The artefact earns its keep now.

What does **not** survive (B) unchanged: its delivery (pipe → file), its
disclosure model (in-script prompt → caller-owned disclosure), and its
one-shot-ness (→ needs the omarchy hook, and ideally `fleet setup --add-repo`).

In fairness to the PLAN: given a script ships, the design is strong. §2.1 (append
at EOF, no INI parser), §2.6 (same-dir temp + atomic rename), §3.3 (the
no-trailing-newline bug), §3.10 (symlink resolution), and §5.1-5.2 (the `TrustAll`
and push-⇒-publish analyses) are all sharp and correct. §5.1-5.2 in particular are
the most valuable pages in the document.

## What ADDITIONS would improve it for the user?

1. **The omarchy `post-update.d` re-assertion hook** (§0). Highest value item
   here; ten lines; the only fix for the only *silent* failure mode.
2. **A mode-aware `fleet doctor`** (§2) — report which install is live
   (`/usr/bin` vs `~/.local/bin` vs `~/.local/share/fleet`), whether the `[fleet]`
   repo is configured, and whether the installed `r<N>.<hash>` is behind the
   published one. This makes the shadowing hazard — currently documented in three
   places nobody reads at the moment it matters — *visible at runtime*, and it is
   the natural home for clobber detection.
3. **A stable `fleet-git-latest.pkg.tar.zst` asset** (§8a). 3 lines of CI; turns
   §5's hard cross-repo dependency into a soft one and gives consumer mode a
   no-script fallback.
4. **`fleet update`** — one verb that does the right thing for whichever model is
   live (`git pull && install.sh` / `pacman -Syu fleet-git` / re-run the `-U` URL).
   With (B) creating a genuine second model, a mode-agnostic update verb stops
   being a nicety.
5. **Document the omarchy clobber in `docs/custom-repo.md`** regardless of what
   else ships. Today the docs tell red to hand-append a stanza that omarchy can
   silently eat, and nothing anywhere says so.

---

## Appendix — verification performed

Read in full: `PLAN.md`, `packaging/README.md`, `packaging/PKGBUILD`,
`packaging/publish-repo.sh`, `install-web.sh`, `Formula/fleet.rb`,
`docs/custom-repo.md`, `docs/multi-device-update.md`, `README.md` install section,
`.github/workflows/pacman-repo.yml`, `/home/red/proj/pc-tune/bootstrap.sh`,
pc-tune `MISSION.md` and `PLAN.md`.

Read **read-only**, no writes to `/etc` at any point: `/etc/pacman.conf`,
`/etc/pacman.d/hooks/`, `/usr/share/libalpm/hooks/`.

Omarchy: `bin/omarchy-refresh-pacman`, `-channel-set`, `-migrate`, `-update`,
`-update-perform`, `-update-git`, `-hook`, `-hook-install`,
`install/preflight/pacman.sh`, `install/post-install/pacman.sh`,
`default/pacman/pacman-{stable,edge,rc}.conf`, the two pacman-touching migrations,
`~/.config/omarchy/hooks/` listing, `~/.local/state/omarchy/migrations` (355 entries).

Commands: `diff` of omarchy template vs live `/etc/pacman.conf` (identical),
`pacman-conf LocalFileSigLevel` (`PackageOptional PackageTrustedOnly`),
`pacman -Sl omarchy`, `command -v yay` (`/usr/bin/yay`), `grep` audit of
`bootstrap.sh` for arg parsing and `install.sh`/`local/bin` references (none),
`bin/fleet:4478-4521` (`cmd_doctor`) and `doctor_config_sync`.

# Adviser 4 — Security (deep)

**Lens:** security. **Position:** firm, not balanced.
**Premise accepted as settled:** OQ-1 is ruled **(B) consumer mode**. I do not
re-litigate it. I evaluate (B) as the shipping design.

---

## 0. Headline

> **(B) is acceptable without GPG signing if and only if the stanza carries
> `Usage = Sync Search Install`. Ship that line or ship signatures — not neither.**

PLAN.md §5 correctly identifies that the stanza grants a persistent root channel,
but it gets the *mechanism* wrong, and as a result it recommends deleting the one
control that actually works while deferring the one that mostly doesn't.

Three findings drive everything below:

1. **§5.1(b) is REFUTED.** Repo ordering *is* a real, empirically-demonstrated
   security control. Bottom-of-file placement blocks the `glibc-9999` attack
   outright. It just doesn't block the attacks that actually matter here.
2. **`Usage =` (pacman.conf(5)) closes the standing-grant threat completely**, at
   the cost of one config line and zero per-device steps. §5 never considers it.
   I verified it neutralises the exact attack that defeated ordering.
3. **GPG signing as §5.4(c) proposes it — key in Actions secrets — does not close
   the top-ranked threat** (push-to-main ⇒ publish, which I confirmed and which is
   *worse* than §5.2 states). Signing-in-CI is largely theatre against this threat
   model. That is a much stronger reason to defer than the "irony" §5.6 offers,
   and it is *conditional* on #2 shipping.

---

## 1. §5.1(b) — ordering vs. version comparison: **REFUTED**

### 1.1 What §5.1(b) claims

> "`-Syu` upgrades by version comparison across all synced repos. A
> `sudo-9999.0-1` in `[fleet]` is a newer version than official `sudo`, so
> `pacman -Syu` installs it — from the bottom-of-file repo."

This is the load-bearing claim behind §2.1's instruction to *"say so in the docs;
do not let 'we put it below the official repos' read as mitigation"* and behind
risk **R4**. It is **wrong**, and acting on it would make the docs less accurate,
not more.

### 1.2 How I determined it

Fully offline, fully isolated. No `/etc` path was written or read-modified.

- Temp root via `mktemp -d` under the session scratchpad.
- Copied `/var/lib/pacman/sync/*.db` and `/var/lib/pacman/local/` into
  `$T/db/` (read-only source), so pacman saw this machine's real 1303-package
  installed set and real official DBs.
- Every invocation used `--config $T/… --dbpath $T/db --root $T/root
  --cachedir $T/cache`. Redirected root + dbpath means no transaction could
  touch the live system even if one had been executed; I only ever ran `--print`.
- Hand-built `.pkg.tar.gz` payloads (`.PKGINFO` + a marker file) and real
  `repo-add`-generated DBs, served over `file://`.
- No `-y` anywhere — the fake DB was placed into the isolated sync dir directly,
  so no network fetch and no possibility of touching real DBs.

### 1.3 Results

| # | Setup | `[fleet]` position | Result |
|---|---|---|---|
| 1 | `glibc-9999.0-1` in `[fleet]` | **last** | `-Su --print` → **empty**. Not selected. |
| 2 | same DB | **first** | `-Su --print` → **selects the malicious glibc** (fails only later on `lib32-glibc` dep, which proves selection happened) |
| 3 | `fleet-y` with `replaces = sudo` | **last** | **empty**. Replacement not offered, even with `yes |` |
| 4 | same | **first** | *"removing sudo breaks dependency 'sudo' required by base-devel"* — **replacement attempted** |
| 5 | `dblab-99.0-1` (name of an **AUR/foreign** installed pkg) | **last** | **SELECTED.** `file://…/dblab-99.0-1-x86_64.pkg.tar.gz` |
| 6 | `fleet-x` with `replaces = dblab` (foreign) | **last** | **SELECTED** |

Corroborating observation from test 1: `pacman -Sl fleet` printed
`fleet glibc 9999.0-1 [installed: 2.43…]` — pacman **saw** the higher version and
still did not upgrade to it. So this is not a parsing or arch failure; it is
deliberate priority logic.

### 1.4 The actual rule

libalpm's sysupgrade does **not** scan all repos for the highest version. For each
installed package it walks the sync DBs **in configured order and stops at the
first DB containing that package name**; only that candidate is version-compared.
The same priority rule gates `replaces=` — a replacement is suppressed when the
victim package is present in an equal-or-higher-priority DB (tests 3/4).

So the correct statement is:

> **Repo order determines *which repo may speak for a given package name*.** A
> lower-priority repo is silent about any name that a higher-priority repo also
> carries.

`pacman.conf(5)`'s own framing supports this — *"pacman searches repositories in
the order defined here"*, echoed as a comment in this machine's own
`/etc/pacman.conf:18`.

### 1.5 Why the plan's *conclusion* still survives

Ordering protects exactly one set: **names carried by an earlier repo**
(`core`/`extra`/`multilib`/`omarchy`). It gives **zero** protection for:

- **`fleet-git` itself.** No official repo carries it, so `[fleet]` speaks for it
  unconditionally. Its `.install` scriptlet runs as root on every upgrade
  (`packaging/fleet-git.install` already has `post_upgrade`). *This alone is total
  compromise.* The `glibc-9999` scenario §5 dramatises is unnecessary —
  the attacker never needs it.
- **Every foreign/AUR-installed package** (test 5). `pacman -Qm` on this box lists
  dozens (`dblab`, `*-bin`, …). Any of those names is hijackable from the bottom
  of the file, with `.install` scriptlets, on a routine `-Syu`.
- **`replaces=` aimed at foreign packages** (test 6) — same hole, and it lets the
  attacker *delete* a package while installing the replacement.

**Verdict on §5.1's bottom line:** the sentence *"adding this repo grants the
publisher a persistent root-code-execution channel fired by the user's own
`pacman -Syu`"* is **CORRECT and I endorse it**. Only the mechanism is wrong.

### 1.6 Required doc correction (opposite of what §5/R4 asks for)

Do **not** tell the docs ordering is not a control. Tell them:

> Put `[fleet]` last. Last position means `[fleet]` can never override a package
> that `core`/`extra`/`multilib` also ship — verified behaviour, not folklore.
> It does **not** protect `fleet-git` itself, nor any package you installed from
> the AUR, because no higher-priority repo carries those names.

That is both true and more useful. **R4's mitigation should be rewritten, not
executed as drafted.**

---

## 2. Threats §5 missed

### 2.1 The version string carries no provenance — **HIGH, and the sharpest miss**

`pkgver()` computes `r<commits>.<shorthash>` from the clone. This *looks* like a
verifiable link to a commit. It is not: `pkgver` is a **client-unverifiable string
chosen by the publisher** and recorded in an **unsigned** DB. An attacker can
publish *old, known-vulnerable fleet code* under `r99999.deadbeef` and every
device takes it as an upgrade. Nothing client-side can detect the mismatch — there
is no commit, no tag, no hash the client can check.

Consequence: the plan's implicit trust that "the version number tells you which
commit you're running" is false, and this defeats the natural instinct that a
rollback attack is impossible because pacman won't downgrade. It won't downgrade
*by version string* — but the attacker controls the version string. **Rollback is
fully available.** §5 does not mention rollback at all.

### 2.2 The DB is unsigned too, and the DB is the attack surface

`/etc/pacman.conf:15` sets `SigLevel = Required DatabaseOptional` globally — i.e.
this machine requires **package** signatures by default. The `[fleet]` stanza's
`SigLevel = Optional TrustAll` overrides that for *both* objects. Every attack I
demonstrated (versions, `replaces=`, `depends=`) is a **metadata** attack executed
entirely through `fleet.db`. Signing packages while leaving the DB optional
(`Required DatabaseOptional`, which §5.4(c) and `docs/custom-repo.md:160` both
propose) leaves the metadata channel **unauthenticated**. A `replaces=` entry
injected into an unsigned DB can still delete packages and redirect installs.

**If you sign, sign the DB too — `SigLevel = Required` full stop, not
`Required DatabaseOptional`.** The existing recommendation in
`docs/custom-repo.md:160` is weaker than its author thinks.

### 2.3 `Optional TrustAll` is mis-described in §5.1 (minor, but fix it)

§5.1 says TrustAll means *"accept it regardless of whether the key is in the local
keyring."* `pacman.conf(5)` says otherwise:

> **TrustAll** — *"If a signature is checked, it must be in the keyring, but is
> not required to be assigned a trust level."*

TrustAll relaxes *trust level*, not *keyring membership*. Immaterial to the
outcome (the attacker simply ships unsigned, which `Optional` accepts), but the
plan should not carry a wrong reading of a man page into the docs.

### 2.4 The docs teach the partial-upgrade footgun

`docs/custom-repo.md:79` and `README.md` both instruct:

```sh
sudo pacman -Sy && sudo pacman -S fleet-git
```

`-Sy` followed by `-S` is the canonical unsupported partial-upgrade state on Arch
— it can install a package built against newer libs onto an un-upgraded system.
It is also a habit that trains the user to refresh the untrusted `[fleet]` DB in
isolation. **Change every occurrence to `sudo pacman -Syu fleet-git`.** Free, and
`-Syu <pkg>` is also the form that keeps working under the `Usage` restriction in
§3.1.

### 2.5 `Architecture = auto` provides no mitigation

`/etc/pacman.conf:8` sets `Architecture = auto` → `x86_64`. This filters nothing
useful: my fake `glibc` declared `arch = x86_64` and was accepted, and `arch=any`
(which `fleet-git` itself uses) is accepted under every setting. An attacker just
declares whichever. Do not count it.

### 2.6 GitHub release assets are mutable in place; there is no revocation

`gh release upload --clobber` (workflow `:134`, `publish-repo.sh:75`) replaces
asset bytes at a **stable URL**. Combined with the prune step (`:143-154`) which
*deletes* previously-published packages, the channel is: mutable content, stable
URL, no history, no signature, no revocation. Once a machine has run add-repo.sh,
nothing short of a human editing `/etc/pacman.conf` withdraws the grant.
CDN/edge caching is an availability and staleness concern only (it can pin a
victim to an older DB), not an integrity one — low, but worth a line.

### 2.7 Dependency injection

`fleet-git` is fully attacker-controlled, so its `depends=` array is too. Adding
`depends=('some-novel-name')` pulls that name from `[fleet]` (no higher-priority
repo carries it), so ordering is bypassed by construction. This is a second
ordering-independent path alongside `.install`.

---

## 3. Mitigations §5 did not consider

### 3.1 `Usage =` — **the recommendation. Ship this.**

`pacman.conf(5)` lines 270-293 define a per-repo usage level with tokens
`Sync | Search | Install | Upgrade | All`, where:

> **Upgrade** — *"Allows this repository to be a valid source of packages when
> performing a --sysupgrade."*
> *"Note that an enabled repository can be operated on explicitly, regardless of
> the Usage level set."*

Omitting `Upgrade` removes `[fleet]` from `-Syu` consideration entirely, while
leaving explicit operations intact.

**Verified.** Against the exact DB that defeated ordering (`dblab-99.0-1`, test 5):

| Config | `-Su --print` | `-Sp dblab` |
|---|---|---|
| no `Usage` (control) | **selects malicious dblab** | resolves from `[fleet]` |
| `Usage = Sync Search Install` | **empty — nothing proposed** | still resolves from `[fleet]` |

So the stanza becomes:

```ini
[fleet]
SigLevel = Optional TrustAll
Usage = Sync Search Install
Server = https://github.com/Redmern/fleet/releases/download/repo
```

**What this buys.** It converts the *standing, automatic, silent* root channel
(§5.3 risk #1, "high, persistent") into an **explicit-pull** channel. `[fleet]`
can no longer inject anything into a routine `pacman -Syu` — not `glibc`, not
`dblab`, not a `replaces=`, not even `fleet-git`. The only way fleet code lands is
a deliberate `sudo pacman -Syu fleet-git`, which is a conscious act on a package
the user intends to install. **That is the same blast radius the user already
accepts for `curl … | sh`** — and unlike GPG it needs no keyring, no
`--recv-keys`, no per-device `--lsign-key`. It costs one line and preserves the
entire point of this work.

**What it costs, honestly.** `pacman -Syu` alone will no longer upgrade
`fleet-git`. `docs/custom-repo.md` §(d)'s promise — *"fleet updates are just
system updates"* — must be rewritten to `sudo pacman -Syu fleet-git`. That is a
real product regression and the team must accept it knowingly. My position is that
trading unattended-auto-update for "no untrusted repo can ever speak during a
system upgrade" is overwhelmingly correct for an unsigned repo, and the trade
disappears the day signing lands (at which point drop `Usage` and go back to `All`).

### 3.2 Pin to an immutable release tag — **rejected, and it wouldn't help**

Pointing `Server` at a versioned tag instead of the mutable `repo` tag defeats the
whole design (every device would need its `Server` line edited per release — the
manual step this work exists to delete). Worse, it buys little: GitHub release
*assets* are mutable regardless of tag immutability (`--clobber` proves it), and
git tags on GitHub are movable by anyone with push access. Immutable-looking, not
immutable.

### 3.3 Checksum pinning — **not available**

pacman has no mechanism to pin a repo's DB hash. `sha256sums=('SKIP')`
(`PKGBUILD:51`) is inherent to VCS packages. There is no client-side integrity
anchor short of a signature. Nothing to do here.

### 3.4 `IgnorePkg` / `IgnoreGroup` — **useless as a blast-radius limiter**

Both are **denylists**; the attacker chooses the package name. To constrain
`[fleet]` you would need to enumerate every name it must *not* be allowed to
supply — an unbounded set. There is no `AllowPkg`. `Usage` is the allowlist-shaped
control and it exists; use it instead. `HoldPkg = pacman glibc`
(`/etc/pacman.conf:7`) similarly only prompts on *removal*, and my test 2 showed it
did not prevent the glibc upgrade being selected.

### 3.5 `pacman -U <url>` with no repo at all — **strong, but loses too much**

Zero standing grant: each install is a one-shot the user initiates, governed by
`LocalFileSigLevel = Optional`. Genuinely the most secure option. But it discards
dependency resolution, discards `-Syu` integration entirely, and requires the user
to know the current filename — which changes every build
(`fleet-git-r<N>.<hash>-…`) and is pruned from the release on the next publish
(`:143-154`), so any pasted URL rots. It also cannot be made idempotent.
**Reject** — but note that `Usage = Sync Search Install` gets you ~90% of its
security value while keeping resolution and discoverability. That is the argument
for §3.1 in one sentence.

---

## 4. §5.2 push ⇒ publish: **CONFIRMED, and STRONGER than stated**

Reading `.github/workflows/pacman-repo.yml`:

- `on: push: branches: [main]` (`:14-15`) with `permissions: contents: write`
  (`:37-38`). `GITHUB_TOKEN` with `contents: write` **is** sufficient to create
  releases and upload/delete release assets — release assets live under the
  `contents` scope. The claim is correct.
- No `pull_request` and **no `pull_request_target`** trigger. Fork PRs **cannot**
  publish. This is the one place the workflow is properly safe; §5 doesn't claim
  otherwise, and it deserves to be stated as a positive.
- No `tags:` trigger. Tag pushes cannot publish.

**Two ways it is worse than §5.2 says:**

1. **The `paths:` filter provides no containment.** `PKGBUILD:50` is
   `source=("git+https://github.com/Redmern/fleet.git")` — makepkg clones the
   repo's **default-branch HEAD at build time**. Step 3 (`:74-79`) checks out
   `GITHUB_SHA` only for the `packaging/` files. So the *shipped code* is whatever
   `main` points at when the runner executes, not the commit that triggered the
   run. Any commit to `main` — path-filtered or not — is published by the *next*
   triggering push, and there is a genuine TOCTOU between trigger and clone. The
   equivalence is therefore **"any commit reaching main is published"**, broader
   than "a push touching `packaging/**`".

2. **`workflow_dispatch` (`:28`) allows a ref.** §5.2 dismisses it as merely
   "repo write access", but `workflow_dispatch` can be run against an **arbitrary
   branch**, and it executes *that branch's* copy of the workflow file. Someone
   with write access but no ability to land on `main` (e.g. under a branch
   protection rule that doesn't cover workflow dispatch) can push a branch with a
   modified `pacman-repo.yml` and publish arbitrary payload **without touching
   `main` at all**. Any future branch protection on `main` is silently bypassed by
   this path.

**Additional, unlisted:** the build environment is unpinned — `container:
archlinux:latest` (`:44`) plus `pacman -Syu … base-devel git github-cli` (`:59`)
against upstream mirrors. Package signatures are checked there by Arch's keyring,
so this is moderate rather than severe, but the build is not reproducible and not
pinned by digest.

**Documentation duty:** §5.6's instruction to add push⇒publish to
`docs/custom-repo.md:144-165` is correct and should be strengthened to cover both
points above. The current security note (`:150-151`) says trust rests on *"only
red's GitHub account / CI token can push to the repo release"* — that is
materially misleading, because it implies the release upload is the choke point
when in fact **any commit on main is**.

---

## 5. (B)-specific: is automatic installation materially worse?

### 5.1 Yes — and the difference is precisely the thing §5.6 relied on

Under a human pasting `curl … | sudo bash`, the grant is issued by someone who
typed `sudo`, read (or at least saw) a stanza, and answered a prompt. Under (B),
`bootstrap.sh` must call `add-repo.sh --yes` — non-interactively, because
`bootstrap.sh` runs `set -euo pipefail` and cannot block on a `read` mid-run.

So **(B) structurally deletes §5.6's mitigation.** §5.6 argued the prompt is "how
you pay back" the lost attention moment; (B) is a design in which the prompt is
never reached. Prompt-by-default is not *incoherent* — it remains correct for the
one-liner path, which still exists and is still the documented primary — but it is
**no longer a mitigation for the (B) path**, and §5.6 must stop counting it as one.

### 5.2 Where the disclosure must move — firm position

**Into `bootstrap.sh`, at the mode decision, not into `add-repo.sh`.** Three
requirements:

1. **Consumer mode must be opt-in and explicitly named.** `--fleet=pacman` (§1.4's
   own proposal) is right; `worktree` must stay the default. A routine re-run of
   `bootstrap.sh` on an existing machine must never silently acquire a repo it
   didn't have.
2. **`bootstrap.sh` prints the stanza and the one-sentence threat statement
   before invoking `add-repo.sh --yes`**, and prints the `--remove` revocation
   command after. The user chose `--fleet=pacman`; they get told what it did. This
   is disclosure without a blocking prompt, which is the only shape compatible
   with a `set -e` setup script.
3. **`bootstrap.sh` must `sudo` explicitly and visibly.** §2.2 is right that
   `add-repo.sh` must never self-escalate; that means `bootstrap.sh` runs
   `sudo add-repo.sh --yes`, and the sudo prompt itself becomes the residual
   attention moment. Do not pre-authenticate sudo earlier in the script to "smooth"
   this — the prompt appearing at the moment of the privileged act is a feature.

`add-repo.sh` keeps prompt-by-default with `--yes` (§5.6/OQ-2 stands, including
OQ-2's correct insistence on reading `/dev/tty` and refusing rather than
auto-accepting when there is no tty — **refuse, never default-yes**; a piped
`curl | sudo bash` with no `--yes` must exit non-zero).

### 5.3 Integration point 3 — stale user unit: **REACHABLE, real, fix it**

`install.sh:176` copies `systemd/fleetd.service` to
`~/.config/systemd/user/fleetd.service`, and that unit hardcodes
`ExecStart=%h/.local/bin/fleetd`. The package ships
`/usr/lib/systemd/user/fleetd.service` with `ExecStart=/usr/bin/fleetd`
(`PKGBUILD:101-104`). **`~/.config/systemd/user` takes strict precedence over
`/usr/lib/systemd/user` for same-named user units.**

The half-migration hazard: a machine that previously ran `install.sh`, then
switches to consumer mode, keeps `~/.config/systemd/user/fleetd.service` unless
`install.sh --uninstall` runs (`:126` is the only thing that removes it). Result:

- **Benign case:** `~/.local/bin/fleetd` is gone → unit fails → `fleetd` never
  starts → fleet silently degrades (fail-silent design hides it). Confusing, not
  dangerous.
- **The security case:** `~/.local/bin/` is a **user-writable directory that
  remains on `PATH`** after the symlink is deleted. A stale enabled user unit then
  names a *writable, non-existent* path as its `ExecStart`. Anything running as
  that uid — including any fleet-spawned coding agent, which fleet's own threat
  model already concedes runs same-uid (`CLAUDE.md`, worktree-secrets section:
  *"same-uid agents CAN read injected secrets"*) — can create
  `~/.local/bin/fleetd` and obtain **systemd-managed, `Restart=on-failure`,
  login-persistent execution**. This is not privilege escalation; it is a clean
  **persistence primitive**, planted in a slot the user believes is owned by a
  package.

**Requirement on (B):** consumer mode must call `install.sh --uninstall` (or at
minimum remove `~/.config/systemd/user/fleetd.service` and the four
`~/.local/bin` symlinks) **before or immediately after** installing the package,
and `fleet doctor` should flag a `~/.config/systemd/user/fleetd.service` whose
`ExecStart` target does not exist. A half-migration that leaves both installs
present (integration point 4) is exactly how this state is reached, so points 3
and 4 are one bug.

### 5.4 Integration point 1 — shadowing has a security consequence too

If consumer mode fails to drop `fleet` from the `REMOTES` loop
(`bootstrap.sh:32-37`) and the `~/.local/bin` symlink still wins on `PATH`, the
machine ends up **receiving package updates it never executes**. Security-relevant
because it manufactures a false patching signal: `pacman -Syu` reports `fleet-git`
upgraded, the user believes a fix landed, and the binary in use is unchanged.
Consumer mode must remove `fleet` from the container loop, not merely add a
package install on top.

### 5.5 Integration point 5 — curl vs vendor on trust grounds: **VENDOR**

§4 concluded "call it from the local checkout, zero network trust". Under (B) that
is **dead**: consumer mode must *not* clone the fleet worktree (§5.4), so
`$PC_TUNE_ROOT/fleet/main/packaging/add-repo.sh` does not exist when it is needed.
§4 also called vendoring *"the worst option"* — but that verdict was reached on
**drift and duplication** grounds, which are maintainability arguments. On trust
grounds the ranking **inverts**:

| Option | Trust roots added | Publishers who can alter what runs as root |
|---|---|---|
| **curl from `raw.githubusercontent.com/Redmern/fleet/main`** | **+1 new TOFU channel** on the critical path | anyone who can push to `Redmern/fleet@main` — including altering the `Server` URL the stanza points at |
| **vendor a copy in `pc-tune`** | **none** | anyone who can push to `Redmern/pc-tune` — *who already controls `bootstrap.sh` itself* |

The decisive asymmetry: **`bootstrap.sh` is already arbitrary code from
`pc-tune`, already executed by the user.** A vendored `add-repo.sh` adds **zero**
new trust root — it is the same artifact, from the same private repo, fetched over
the same authenticated `gh` clone. Curling from public raw adds a **second,
independent, unauthenticated publisher** whose compromise is sufficient to point
the stanza's `Server` at an attacker-controlled host — a strictly worse outcome
than any of the repo-content attacks in §1, because it doesn't even require
GitHub.

`pc-tune` being **private** (PLAN §0 item 2) sharpens this further: a private repo
cloned with `gh` credentials is authenticated; `raw.githubusercontent.com` is
TOFU. §4 treats pc-tune's privacy purely as a *distribution* limitation ("the copy
can't even be curl'd by a third party"); it is also a *trust* advantage.

**Position: vendor.** The drift objection is real but small and mechanically
closable — the payload is a ~3-line static stanza; add a CI check (or a
`bootstrap.sh` startup assertion) that the vendored copy's sha256 matches fleet's,
and drift becomes a build failure rather than a silent divergence. Never curl
add-repo.sh from inside `bootstrap.sh`. (The **documented one-liner for humans**
keeps curling from raw — that path has no better option and the user is choosing
it deliberately.)

### 5.6 Integration point 2 (`fleet doctor` RED on consumer machines)

Outside my lens except for one note: if `doctor` goes RED on a correctly-installed
consumer machine, users learn to ignore it — and `doctor` is the thing that should
be surfacing §5.3's stale-unit condition. A permanently-red doctor is a security
regression by desensitisation. Whoever owns point 2 should treat "doctor must be
GREEN on a clean consumer install" as a hard requirement.

---

## 6. Sign now or defer — **DEFER, conditionally. Firm.**

### 6.1 Does (B) fire §5.6's trigger 1?

Trigger 1: *"Any machine that is not solely red's runs add-repo.sh."*

**On a strict reading: no.** The human's non-dev machine is still red's machine.

**But the trigger is measuring the wrong variable, and that is the finding.** The
risk driver is not *whose* machine it is; it is (i) how many machines hold the
standing grant, (ii) how automatically the grant is issued, and (iii) whether a
human sees the grant being issued. (B) worsens all three while leaving trigger 1
untouched. A trigger set that a design change like (B) can sail straight past is
not a control — it is a note-to-self.

**Rewrite the triggers as:**

1. `add-repo.sh` (or bootstrap consumer mode) has run on **more than 2** machines.
2. Anyone other than red gains **push access to `Redmern/fleet@main`**, *or*
   `workflow_dispatch` rights (see §4 — the ref escape makes these equivalent).
3. fleet is advertised for third-party installation.
4. **The `Usage =` restriction (§3.1) is removed or was never shipped.** ← new, and
   the operative one.

### 6.2 Does automatic non-interactive installation change the calculus?

Yes — it removes the disclosure, as established in §5.1. **But the correct response
is to restore the disclosure (§5.2) and remove the standing grant (§3.1), not to
sign.** Signing does not address disclosure at all: a signed repo installed
silently by a script is still a silently-installed standing channel; it just has a
different set of people able to abuse it.

### 6.3 The real reason to defer

**GPG signing as §5.4(c) actually specifies it — private key + passphrase in
Actions secrets — does not close the top-ranked threat.**

Ranked surface (§4 confirms #1 is wider than §5.2 said):

| # | Threat | Closed by CI-held-key signing? |
|---|---|---|
| 1 | Any commit on `main`, or a `workflow_dispatch` on any branch, publishes root-executed payload | **NO** — the workflow signs it |
| 2 | GitHub account compromise (release upload only) | yes |
| 3 | GitHub-side / CDN tampering | yes |
| 4 | curl-pipe TOFU | no (out of scope) |

§5.4(c) admits this in a parenthetical (*"Does not close push-to-main ⇒ publish if
the signing key lives in CI"*) and then does not let it change the conclusion. It
should: **the dominant threat is #1, and the proposed signing scheme is blind to
it.** Signing-in-CI here is close to theatre. It would buy real protection only if
the key lived **offline on red's machine** with `publish-repo.sh` doing the
signing — which requires disabling CI-on-push publishing, which destroys the "push
to main and every device updates" property that justifies this entire repo channel.
That trade is not worth making today.

Meanwhile §3.1's `Usage` line closes **#1, #2 and #3 for the automatic path
entirely**, for one line and no per-device step.

### 6.4 The §5.6 "irony" — real argument or dodge? **Mostly a dodge, but the
conclusion happens to be right for a different reason.**

§5.6 leans on the irony that signing reintroduces a per-device
`pacman-key --lsign-key`. Judged on its own, that is a **convenience argument
dressed as a security argument**, and §5's own OQ-5 correctly calls out the
counter (*"we'll do it later" may mean "never"*). It should not have been given
the weight it was.

And the plan's own escape hatch is weaker than it looks: **yes, `add-repo.sh`
could run `pacman-key --recv-keys` + `--lsign-key` itself** — it is two commands
and it would fully preserve the zero-manual-steps goal. But it **relocates the TOFU
rather than recovering the security benefit**: the key is fetched and locally
signed over the same unauthenticated channel, at the same moment, by the same
script. You end up authenticating *future* releases against a key you accepted on
trust — which protects against later release-asset tampering (#2/#3) and against
nothing else. Since #1 dominates and is untouched either way, the manoeuvre is
close to net-zero. **So: the irony is a weak argument, the escape hatch is a
genuine option, and neither changes the verdict — §6.3 does.**

### 6.5 Verdict

> **DEFER GPG signing — conditional on shipping `Usage = Sync Search Install`.**
>
> **If `Usage` is rejected** (because the team insists `pacman -Syu` must carry
> fleet updates unattended), then **(B) must not ship without signatures.** An
> automatically-installed, unprompted, unsigned, standing root channel with no
> revocation is not defensible, and in that configuration I would sign now — with
> the key offline and `Required` (not `Required DatabaseOptional`, per §2.2),
> accepting the loss of push-triggered auto-publish.

---

## 7. Explicit answers

### Is this the best way?

**No — but it is close, and it is fixable with one line.** The plan's engineering
is strong: EOF append (§2.1) is correct and the ordering reasoning behind it is
sound even though the security gloss on it is wrong; the atomic-rename +
same-dir-tempfile + timestamped-backup design (§2.5-2.6) is right; the
anti-truncation `main()` wrapper (§2.3) is genuinely mandatory here and correctly
identified as such; the three-way classification with exit 3 on a foreign
`[fleet]` (§2.4/§3.6) is the right call. The proof harness §6.2's three
independent layers protecting `/etc/pacman.conf` are exactly what I would demand.

What is not best: it ships a standing automatic root grant when a one-line config
directive removes it, because §5 never opened `pacman.conf(5)`'s `Usage` section.

### Is there a better way?

**Yes: the same design plus `Usage = Sync Search Install`.** That is the better
way, and it is a two-character-per-line change to the stanza, the docs, and the
proof harness fixtures. Nothing else in the plan needs to move.

The genuinely-better-but-rejected alternatives (`pacman -U`, offline signing) each
sacrifice something the plan legitimately needs. `Usage` sacrifices only unattended
fleet auto-update, and only until signing lands.

### What ADDITIONS would improve it for the user?

Ordered by security value per unit of effort:

1. **`Usage = Sync Search Install` in the stanza** (§3.1). Verified. One line.
   Closes the standing channel. *Highest value in this document.*
2. **`sudo pacman -Syu fleet-git` everywhere `sudo pacman -Sy` currently appears**
   (§2.4) — `docs/custom-repo.md:79`, `README.md`, `docs/multi-device-update.md`.
   Removes a partial-upgrade footgun the docs currently teach, and is the form that
   keeps working under #1.
3. **Correct the ordering claim in the docs — in the *opposite* direction to R4**
   (§1.6). Say last-position is a real control, and say exactly what it does not
   cover (`fleet-git` itself, AUR packages).
4. **Rewrite the security note** at `docs/custom-repo.md:144-165` to say *any
   commit reaching `main`* publishes — not "only red's account can upload"
   (§4). Include the `workflow_dispatch`-on-any-branch path.
5. **`bootstrap.sh` consumer mode: opt-in flag, printed stanza + threat sentence,
   visible `sudo`, printed `--remove` line** (§5.2). This is where (B)'s disclosure
   lives now.
6. **Consumer mode must run `install.sh --uninstall`** and `fleet doctor` must flag
   a `~/.config/systemd/user/fleetd.service` with a missing `ExecStart` target
   (§5.3). Closes a real same-uid persistence slot.
7. **Vendor `add-repo.sh` into `pc-tune`; never curl it from `bootstrap.sh`**
   (§5.5). Add a sha256 drift check.
8. **`add-repo.sh` prints the `--remove` invocation on success** — §5.6 already
   proposes this and it is right; revocation must be discoverable at the moment of
   grant, because it is the *only* revocation that exists.
9. **Two extra proof-harness cases** on top of §6.4's 21: (a) the emitted stanza
   contains a `Usage =` line — a regression guard, since silently dropping it
   re-opens the whole channel; (b) `pacman-conf --config "$FIXTURE" --repo-list`
   shows `fleet` **last** (case 1 already asserts last-section-header textually;
   assert it through pacman too). Also: make **OQ-7 a hard requirement** — case 16
   should not SKIP. On an Arch box `pacman-conf` is present by definition, and it
   is the only case that proves the output is valid to pacman rather than merely
   plausible text.
10. **Document that `pkgver` is not provenance** (§2.1) — one sentence in the
    security note. It is the assumption most likely to mislead a future reader into
    thinking rollback is impossible.

### Answers to the original OQs my lens touches

- **OQ-1** — ruled (B). My requirements on it: §5.2, §5.3, §5.4, §5.5.
- **OQ-2** — **prompt-by-default, and on no tty: REFUSE (non-zero exit), never
  default-yes.** Under (B) the prompt is bypassed by `--yes`, so it is no longer
  load-bearing — the disclosure moves to `bootstrap.sh` (§5.2). Keep the prompt
  anyway for the one-liner path.
- **OQ-4** — **no, `add-repo.sh` must not run `pacman -Sy`.** §2.6 is right on
  blast-radius grounds and §2.4 adds a second reason: a bare `-Sy` is the
  partial-upgrade footgun. If anything is fused, fuse `-Syu fleet-git`, and only
  behind an explicit flag.
- **OQ-5** — **defer, conditional on `Usage`** (§6.5). The plan's stated reasoning
  is weak; the right reasoning is that CI-held-key signing is blind to the
  dominant threat.
- **OQ-7** — **hard requirement, not SKIP.** See addition 9.

---

## Appendix — experimental method and safety

All experiments ran in `mktemp -d` under the session scratchpad. **Nothing under
`/etc` was written, and `/etc/pacman.conf` and `/etc/pacman.d/mirrorlist` were
read only.** Every `pacman` invocation passed `--config`, `--dbpath`, `--root` and
`--cachedir` into the temp tree, and every one used `--print` — no transaction was
ever executed. Official sync DBs and the local package DB were **copied** into the
temp dbpath so the tests ran against this machine's real 1303-package installed
set; the originals were never opened for write. No `-y` was used, so no DB was
refreshed and no network fetch occurred; the malicious DB was placed into the
isolated sync dir directly and served over `file://`.

Fake packages were hand-built `.pkg.tar.gz` archives (`.PKGINFO` + a marker file)
indexed with real `repo-add`. They are inert (they contain a single text file
under `usr/share/`) and exist only inside the scratchpad temp dir.

Man pages consulted: `pacman.conf(5)` — *Repository Sections* / `Usage` (lines
270-293), *Package and Database Signature Checking* (`Optional`, `Required`,
`TrustAll`, `TrustedOnly`, and the `Package`/`Database` prefixes).

Files read: `_reports/pacman-repo-autoconfig/PLAN.md`,
`.github/workflows/pacman-repo.yml`, `packaging/PKGBUILD`,
`packaging/publish-repo.sh`, `packaging/fleet-git.install`, `install-web.sh`,
`install.sh` (systemd/symlink sections), `systemd/fleetd.service`,
`docs/custom-repo.md`, `README.md` (install section),
`/home/red/proj/pc-tune/bootstrap.sh`, `/etc/pacman.conf` (read-only).

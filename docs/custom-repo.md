# Installing fleet from the self-hosted `[fleet]` pacman repo

This lets any Arch device install and update fleet with plain pacman — no AUR
account, no per-device build, no `install.sh`:

```bash
sudo pacman -S fleet-git     # install
sudo pacman -Syu             # update like any other package
```

The packages and the repo database are hosted on a **GitHub Release** of
`Redmern/fleet` (tag `repo`). CI rebuilds and republishes them on every push to
`main`. Design rationale: `_reports/pacman-repo/RESEARCH.md`.

> Which devices is this for? **Other** devices (laptop, fresh box). The **dev
> box** keeps the git-worktree workflow (`~/.local/bin` symlinks shadow
> `/usr/bin/fleet` on PATH on purpose). See `docs/multi-device-update.md`.

---

## (a) Add the `[fleet]` repo to `/etc/pacman.conf`

Append this stanza to `/etc/pacman.conf`. Put it **below** the official repos
(`[core]`, `[extra]`, and `[multilib]` if present) so official packages always
take precedence:

```ini
[fleet]
SigLevel = Optional TrustAll
Server = https://github.com/Redmern/fleet/releases/download/repo
```

- `SigLevel = Optional TrustAll` — packages are **not** GPG-signed in v1. Trust
  rests on HTTPS transport + the fact that only red's GitHub account/CI can
  publish to the release. See the security note at the bottom before relying on
  it beyond a personal fleet.
- `Server = …/releases/download/repo` — the `repo` release's asset path. pacman
  fetches `<Server>/fleet.db` to read the repo, then `<Server>/<pkg>` to install.

Edit with: `sudo ${EDITOR:-nano} /etc/pacman.conf`.

---

## ⚠️ Already have fleet installed another way? Switch cleanly first

pacman won't error if fleet is already present, but two installs **shadow** each
other. If this device already has the **dev / worktree install** (the
`~/.local/bin` symlinks from `install.sh`), remove it *before* installing the
package — otherwise the checkout keeps winning and `pacman -Syu` upgrades have no
effect:

```bash
cd ~/proj/pc-tune/fleet/main && ./install.sh --uninstall   # drops the ~/.local/bin symlinks + user unit + hooks
```

Then proceed with (b). Why it matters:

- **No file conflict either way** — the dev install lives in `~/.local/bin` +
  `~/.config/systemd/user`, the package in `/usr/bin` + `/usr/lib/systemd/user`.
  So pacman installs fine even without cleanup — but `~/.local/bin` sits *before*
  `/usr/bin` on `PATH`, and a `~/.config/systemd/user` unit shadows the packaged
  one, so the package stays **masked and unused** until the dev install is gone.
- Already installed via a **prior `makepkg` / this repo**? No cleanup — `pacman -S
  fleet-git` just reinstalls/upgrades it (same package name).
- Ran `fleet setup` from the dev install? It tags that install, so running it
  again from the package refuses unless `--force`; uninstalling the dev one first
  avoids the prompt.
- **On the dev box** (where you edit fleet) do the *opposite*: keep the worktree,
  **don't** add this repo or install the package — the shadowing is intentional so
  your editable checkout wins.

---

## (b) First-time setup

Refresh the new repo's database, then install:

```bash
sudo pacman -Sy          # pull the [fleet] db (and refresh others)
sudo pacman -S fleet-git
```

`-Sy` is needed once so pacman learns the `[fleet]` repo exists. After that,
`pacman -Syu` keeps it current along with everything else.

If pacman complains it can't find `fleet-git`, the `repo` release hasn't been
published yet — see "First publish" below (red only).

---

## (c) Per-device setup after install (required)

pacman installs only **system files**. Per-user wiring (the `fleetd` user unit +
Claude Code hooks) is not — and cannot be — done by pacman. Run **as your normal
user, not root**, once per device:

```bash
fleet setup              # enable fleetd (user) + wire Claude Code hooks
fleet setup --browser    # also vendor playwright-core for `fleet browser` (optional)
fleet doctor             # verify
```

This is the same `fleet setup` the package's post-install message tells you to
run.

---

## (d) Updating

Once the repo is added, fleet updates are just system updates:

```bash
sudo pacman -Syu         # upgrades fleet-git along with everything else
```

Because `fleet-git` is a `-git` package, its version is `r<commits>.<shorthash>`;
each new `main` commit that CI publishes bumps it, and `-Syu` pulls it. Re-run
`fleet setup` only if an upgrade note says hook paths changed.

---

## (e) How the repo stays fresh

`.github/workflows/pacman-repo.yml` runs on every push to `main` (and on manual
dispatch). In an `archlinux:latest` container it:

1. builds `packaging/PKGBUILD` as a non-root user (`makepkg --nodeps`),
2. assembles the repo DB (`repo-add fleet.db.tar.gz <pkg>`),
3. uploads the DB + package to the `repo` release with `gh release upload
   --clobber`.

So pushing to `main` is all it takes to publish a new fleet to every device — no
manual step on the consuming machines beyond `pacman -Syu`.

To publish **without** CI (e.g. bootstrapping the first release, or from the dev
box), run the local fallback:

```bash
packaging/publish-repo.sh        # needs makepkg + repo-add + an authed `gh`
```

---

## (f) Security note — `SigLevel = Optional TrustAll`

`Optional TrustAll` means pacman does **not** cryptographically verify packages.
You are trusting:

- **HTTPS** from `github.com` (no in-flight tampering), and
- **account control** — only red's GitHub account / CI token can push to the
  `repo` release.

It does **not** protect against a compromise of red's GitHub account. For a
personal fleet (publisher == consumer) that's an accepted trade-off. To harden to
real package signing later:

1. **Repo side:** build with `makepkg --sign`, run `repo-add -s -k "$GPGKEY"`,
   and publish the `*.sig` assets (in CI, add the private key + passphrase as
   Actions secrets and `gpg --import` before building).
2. **Device side:** change the stanza to `SigLevel = Required DatabaseOptional`,
   then `sudo pacman-key --recv-keys <FPR>` and
   `sudo pacman-key --lsign-key <FPR>` once per device.

`publish-repo.sh` and the workflow are structured so this is an additive change,
not a rewrite.

---

## First publish (red only, one-time)

The repo serves nothing until the `repo` release exists. Either:

- **CI:** enable Actions on `Redmern/fleet`, then trigger the `pacman-repo`
  workflow once (Actions tab → *pacman-repo* → *Run workflow*, or push any
  packaging change to `main`). It creates the `repo` release on first run.
- **Local:** run `packaging/publish-repo.sh` from a checkout (needs `gh auth
  login` + `makepkg`). It also creates the release if absent.

After the first publish, the `pacman.conf` stanza above works on every device.

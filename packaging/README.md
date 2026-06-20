# Packaging `fleet` for the AUR (`fleet-git`)

These files package fleet as an AUR **VCS** package that tracks rolling `main`.
Design rationale (channel choice, system/per-user split, the Playwright story,
dep mapping) lives in `_reports/pacman-package/RESEARCH.md`.

| file | purpose |
|---|---|
| `PKGBUILD` | the package recipe (`pkgname=fleet-git`, `source=git+…`) |
| `fleet-git.install` | post_install/post_upgrade/pre_remove scriptlet (tells the user to run `fleet setup`) |
| `.SRCINFO` | machine-readable metadata the AUR requires; regenerate after every PKGBUILD edit |

## What the package does (and deliberately does NOT do)

pacman installs only **immutable system files**:

- the whole exec tree under `/usr/lib/fleet/` (preserving `bin/ lib/ harness.d/
  nvim/` + `FLEET.md FLEET_SUBORCH.md`), so `bin/fleet`'s `FLEET_DIR` resolver
  finds every sibling;
- `/usr/bin/{fleet,fleetd,fleet-hook,fleet-guard}` **symlinks** into that tree
  (a symlink, not a wrapper, so `readlink -f` lands `FLEET_DIR=/usr/lib/fleet`);
- the **user** systemd unit at `/usr/lib/systemd/user/fleetd.service`
  (`ExecStart` patched to `/usr/bin/fleetd`);
- license + docs.

Everything that touches per-user state — `systemctl --user`, a user's
`~/.claude*/settings.json`, vendoring playwright-core — is **not** done by
pacman (root at build time cannot). The `.install` scriptlet tells the user to
run `fleet setup` (and `fleet setup --browser`) themselves.

`lib/node_modules` is **not** shipped — the browser driver is vendored per-user
into `$XDG_DATA_HOME/fleet/lib` by `fleet setup --browser`. The dispatch hook
(`bin/fleet-dispatch.sh`) ships but stays opt-in (`fleet dispatch enable`).

## Publish to the AUR

One-time prerequisite (only red can do this): an AUR account with an SSH key
uploaded, and the `fleet-git` name registered by the first push.

```sh
# 1. clone the (empty) AUR git repo for this package
git clone ssh://aur@aur.archlinux.org/fleet-git.git aur-fleet-git
cd aur-fleet-git

# 2. copy the packaging files from this repo
cp /path/to/fleet/packaging/{PKGBUILD,fleet-git.install,.SRCINFO} .

# 3. regenerate .SRCINFO (REQUIRED on every PKGBUILD change)
makepkg --printsrcinfo > .SRCINFO

# 4. lint
namcap PKGBUILD
makepkg -f                          # builds the tarball (no install)
namcap fleet-git-*.pkg.tar.zst

# 5. smoke-test a real build+install on a machine that is NOT running the
#    pc-tune dev worktree (the worktree's ~/.local/bin symlinks shadow
#    /usr/bin/fleet — see RESEARCH §6.3). Then run the per-user setup:
makepkg -si
fleet setup        # + `fleet setup --browser` for the browser feature
fleet doctor

# 6. publish
git add PKGBUILD .SRCINFO fleet-git.install
git commit -m "fleet-git: initial release"
git push
```

### Updating

`-git` always builds the latest `main` at install time, so content changes need
no AUR action. For PKGBUILD/dependency/scriptlet changes: edit →
`makepkg --printsrcinfo > .SRCINFO` → commit → push. Bump `pkgrel` when only the
PKGBUILD changed (no new upstream code).

### Later: a tagged `fleet`

When releases get tagged (`v0.1.0`, …), a second `fleet` package with a
`source=…/archive/refs/tags/$pkgver.tar.gz` + real `sha256sums` gives
reproducible stable installs. Keep `fleet-git` for bleeding edge (RESEARCH §5.3).

#!/usr/bin/env bash
# publish-repo.sh — local fallback for the pacman-repo CI workflow.
#
# Builds fleet-git with makepkg, assembles the pacman repo DB with repo-add, and
# publishes the DB + package to the 'repo' GitHub Release with --clobber so it
# overwrites in place. Use this to bootstrap the first release, or to publish
# from the dev box without waiting for CI.
#
# Requires: makepkg (pacman/base-devel), repo-add (pacman), gh (logged in:
#   `gh auth status`). Run as your NORMAL user — makepkg refuses to run as root.
#
# Design + rationale: _reports/pacman-repo/RESEARCH.md.
# Mirrors .github/workflows/pacman-repo.yml — keep the two in sync.

set -euo pipefail

REPO_SLUG="${FLEET_REPO_SLUG:-Redmern/fleet}"   # owner/name on GitHub
REPO_TAG="${FLEET_REPO_TAG:-repo}"              # the mutable release holding the DB

# Resolve packaging/ dir regardless of CWD.
PKGDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'publish-repo: %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "do NOT run as root — makepkg refuses. Run as your user."
command -v makepkg  >/dev/null 2>&1 || die "makepkg not found (install base-devel)."
command -v repo-add >/dev/null 2>&1 || die "repo-add not found (part of pacman)."
command -v gh       >/dev/null 2>&1 || die "gh (GitHub CLI) not found."
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run 'gh auth login'."
[ -f "$PKGDIR/PKGBUILD" ] || die "PKGBUILD not found in $PKGDIR."

# --- build -----------------------------------------------------------------
# --nodeps: runtime deps (tmux/neovim/fzf/...) aren't needed to copy files.
# Build into a temp work area so we don't litter the repo checkout.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "==> building fleet-git (makepkg --nodeps) ..."
( cd "$PKGDIR" && PKGDEST="$WORK" BUILDDIR="$WORK/build" makepkg --nodeps -f )

shopt -s nullglob
pkgs=("$WORK"/*.pkg.tar.zst)
[ "${#pkgs[@]}" -gt 0 ] || die "no package produced by makepkg."
echo "==> built: ${pkgs[*]##*/}"

# --- repo database ---------------------------------------------------------
REPO_OUT="$WORK/repo"
mkdir -p "$REPO_OUT"
cp "${pkgs[@]}" "$REPO_OUT/"
echo "==> running repo-add ..."
( cd "$REPO_OUT" && repo-add fleet.db.tar.gz ./*.pkg.tar.zst )

# Dereference the .db/.files symlinks repo-add made into real files to upload.
( cd "$REPO_OUT"
  cp -L fleet.db.tar.gz    db.tar.gz   && mv db.tar.gz   fleet.db.tar.gz
  cp -L fleet.files.tar.gz f.tar.gz    && mv f.tar.gz    fleet.files.tar.gz
  cp -L fleet.db    fleet.db.real    && mv fleet.db.real    fleet.db
  cp -L fleet.files fleet.files.real && mv fleet.files.real fleet.files
)

echo "==> repo contents:"
ls -l "$REPO_OUT"

# --- ensure the release exists (idempotent first run) ----------------------
if ! gh release view "$REPO_TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  echo "==> creating release '$REPO_TAG' ..."
  gh release create "$REPO_TAG" --repo "$REPO_SLUG" \
    --title "fleet pacman repo" \
    --notes "Self-hosted pacman repo for fleet-git. Add the [fleet] repo per docs/custom-repo.md. Auto-published; not a software release." \
    --prerelease
fi

# --- publish ---------------------------------------------------------------
echo "==> uploading assets (--clobber) ..."
gh release upload "$REPO_TAG" --repo "$REPO_SLUG" --clobber \
  "$REPO_OUT/fleet.db" "$REPO_OUT/fleet.db.tar.gz" \
  "$REPO_OUT/fleet.files" "$REPO_OUT/fleet.files.tar.gz" \
  "$REPO_OUT"/*.pkg.tar.zst

echo "==> done. Server = https://github.com/${REPO_SLUG}/releases/download/${REPO_TAG}"

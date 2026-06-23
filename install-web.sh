#!/bin/sh
# fleet web installer — `curl … | sh` bootstrap.
#
#     curl -fsSL https://raw.githubusercontent.com/Redmern/fleet/main/install-web.sh | sh
#
# Trust model: HTTPS-TOFU (trust-on-first-use over TLS). You are trusting GitHub's
# TLS and that this raw file on `main` is what you expect — this is corruption-
# resistant, not authenticated. The cautious path is "download, read, then run":
#
#     curl -fsSL https://raw.githubusercontent.com/Redmern/fleet/main/install-web.sh -o fleet-install.sh
#     less fleet-install.sh        # read it
#     sh fleet-install.sh
#
# The ENTIRE body lives inside main(); the script does nothing until the final
# `main "$@"` line. A truncated download (connection dropped mid-transfer) can
# therefore never run a half-parsed script.
#
# What it does: clones fleet into ${XDG_DATA_HOME:-$HOME/.local/share}/fleet and
# runs that tree's install.sh (which symlinks bins into ~/.local/bin, installs a
# systemd --user unit, and wires fleet-hook + fleet-guard into Claude Code).
# Re-run to update. Uninstall instructions are printed at the end.

main() {
  set -eu

  REPO_URL="${FLEET_REPO_URL:-https://github.com/Redmern/fleet.git}"
  BRANCH="${FLEET_CHANNEL:-main}"
  DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fleet"
  BIN="$HOME/.local/bin/fleet"

  # ---- preflight ----------------------------------------------------------
  # Only what the bootstrap itself needs; the authoritative dep matrix is
  # `fleet doctor`, which the final message tells the user to run.
  missing=
  command -v bash    >/dev/null 2>&1 || missing="$missing bash"
  command -v git     >/dev/null 2>&1 || missing="$missing git"
  command -v python3 >/dev/null 2>&1 || missing="$missing python3"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing="$missing curl-or-wget"
  fi
  if [ -n "$missing" ]; then
    echo "fleet install: missing required tools:$missing" >&2
    echo "  install them and re-run." >&2
    exit 1
  fi

  # ---- dev-shadow pre-check -----------------------------------------------
  # A fleet dev checkout symlinks ~/.local/bin/fleet into its OWN worktree.
  # install.sh's `ln -sf` would silently clobber that. Refuse if an existing
  # ~/.local/bin/fleet resolves OUTSIDE our managed dir — the dev/other install
  # must win. (An entry already inside $DIR is just a prior curl install → fine.)
  if [ -e "$BIN" ] || [ -L "$BIN" ]; then
    resolved=$(readlink -f "$BIN" 2>/dev/null || echo "$BIN")
    case "$resolved" in
      "$DIR"/*) : ;;   # already ours — this is an update
      *)
        echo "fleet install: ~/.local/bin/fleet already exists and resolves OUTSIDE" >&2
        echo "  the managed dir — refusing to clobber it:" >&2
        echo "      $BIN -> $resolved" >&2
        echo "  this looks like a dev checkout or another install. If you really want" >&2
        echo "  the curl install to own it, remove that symlink first and re-run." >&2
        exit 1
        ;;
    esac
  fi

  # ---- fetch: clone fresh, or fast-forward an existing managed tree -------
  if [ -d "$DIR/.git" ]; then
    echo "fleet install: updating existing clone at $DIR"
    git -C "$DIR" pull --ff-only origin "$BRANCH"
  else
    echo "fleet install: cloning fleet ($BRANCH) into $DIR"
    mkdir -p "$(dirname "$DIR")"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$DIR"
  fi

  # ---- disclosure ----------------------------------------------------------
  echo
  echo "fleet install: running $DIR/install.sh"
  echo "  This wires fleet-hook and fleet-guard into your Claude Code settings.json"
  echo "  (~/.claude, ~/.claude_personal by default). Those hooks then run on EVERY"
  echo "  Claude Code prompt, tool use, and notification to report agent state."
  echo

  # ---- run the real installer (bash, unchanged) ---------------------------
  bash "$DIR/install.sh"

  echo
  echo "fleet installed. Next:"
  echo "    fleet doctor && fleet up <project-root>"
  echo
  echo "Update:    re-run the curl one-liner (pulls + re-runs install.sh)."
  echo "Uninstall: bash \"$DIR/install.sh\" --uninstall && rm -rf \"$DIR\""
}

main "$@"

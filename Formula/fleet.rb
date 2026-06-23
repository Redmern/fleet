# Homebrew formula for fleet — Linuxbrew only (rolling / head-only, no tags yet).
#
# Copy this file to the tap repo at Redmern/homebrew-fleet:Formula/fleet.rb, then:
#     brew tap redmern/fleet
#     brew install --HEAD fleet      # head-only: --HEAD is required (no stable url)
#
# There is no `stable` url/sha256 on purpose: fleet has no version tags and
# republishes on every push to `main` (rolling cadence). When tags arrive
# (Fork S) add `url`+`sha256` and drop the head-only requirement.
class Fleet < Formula
  desc "Tmux/git-worktree command-center for orchestrating coding agents"
  homepage "https://github.com/Redmern/fleet"
  license "MIT"
  head "https://github.com/Redmern/fleet.git", branch: "main"

  # Mirror `fleet doctor`'s required set. `bash` is required (not optional):
  # bin/fleet and install.sh use modern bash, and macOS ships bash 3.2.
  depends_on "tmux"
  depends_on "neovim"
  depends_on "git"
  depends_on "python@3.12"
  depends_on "fzf"
  depends_on "bash"

  def install
    # Linux-only. On macOS fleetd cannot bind its socket (no XDG_RUNTIME_DIR /
    # /run), so the daemon — the whole engine (state, RPC, status, notifications)
    # — never starts. A package that lays files but whose daemon never comes up
    # is worse than no package. Refuse rather than ship dead-on-arrival.
    # macOS is a separate, scoped project; see _reports/distribution/SYNTHESIS.md.
    if OS.mac?
      odie "fleet is Linux-only: fleetd needs a Linux user runtime dir to bind " \
           "its socket. macOS is not supported by this tap (it is a separate, " \
           "scoped project). Use Linuxbrew, the curl installer, or pacman."
    end

    # Drop the whole tree into libexec; symlink the 4 user-facing bins into bin.
    # bin/fleet resolves FLEET_DIR via readlink -f of itself, so the bin symlink
    # → Cellar bin → libexec/bin collapses to libexec/bin/fleet and every sibling
    # (harness.d, nvim, lib, *.md) is found with no code change — same mechanism
    # as pacman's /usr/lib/fleet. node_modules is NOT shipped; `fleet setup
    # --browser` vendors playwright-core per-user.
    libexec.install Dir["*"]
    %w[fleet fleetd fleet-hook fleet-guard].each do |b|
      bin.install_symlink libexec/"bin/#{b}"
    end
  end

  def caveats
    <<~EOS
      fleet installed the system files only. Per-user wiring is NOT automatic —
      brew (like any package manager) cannot touch your systemd --user units or
      your Claude Code settings. Run these as your normal user (not via brew):

          fleet setup            # enable fleetd (user) + wire Claude Code hooks
          fleet setup --browser  # optional: vendor playwright-core for `fleet browser`
          fleet doctor           # verify

      `fleet setup` wires fleet-hook + fleet-guard into your Claude Code
      settings.json (~/.claude, ~/.claude_personal by default). Those hooks then
      run on EVERY Claude Code prompt, tool use, and notification.

      Before `brew uninstall fleet`, remove the per-user half brew can't track:
          fleet unsetup          # disable the user unit + unwire hooks + drop ~/.local/bin shims

      Linux only: fleetd needs a Linux user runtime dir. macOS is not supported.
    EOS
  end
end

#!/usr/bin/env bash
# release-manifest-proof — the release tree is COMPLETE.
#
# PROOF DESIGN §3 (_reports/install-outage/PLAN-PLAIN.md): promote into a clean
# sandbox, then DELETE the source worktree entirely and assert the release still
# works standalone. This is the proof that catches the `bin/`-only mistake:
# `bin/fleet` derives FLEET_DIR from its own resolved path and then loads
# harness.d/*.conf, nvim/fleet.lua, FLEET.md, FLEET_SUBORCH.md, lib/ and
# systemd/ from it — a four-file release is broken the moment anything reads a
# sibling.
#
# Second half: cross-check the manifest against packaging/PKGBUILD, so the two
# installation shapes cannot drift apart silently.
#
# No tmux server is created (proof_isolate only ARMS one); the trap still tears
# down exactly the one TMPROOT this script made.
set -u
. "$(dirname "$0")/hidden-proof-common.sh"
proof_isolate

REL="$TMPROOT/rel"
SRC="$TMPROOT/src"

# A throwaway copy of the worktree to promote FROM. Excludes .git (promote must
# work with or without one) and lib/node_modules (13M, deliberately not shipped).
mkdir -p "$SRC"
tar -C "$FLEET_REPO" --exclude=.git --exclude=node_modules -cf - . 2>/dev/null \
  | tar -C "$SRC" -xf - 2>/dev/null

# Everything below runs with the release root redirected into TMPROOT; no proof
# may ever touch ~/.local/lib/fleet.
export FLEET_RELEASE_DIR="$REL"
export FLEET_SOURCE="$SRC"
fleet_src() { "$SRC/bin/fleet" "$@"; }              # the CLI, run from the worktree
fleet_rel() { "$REL/current/bin/fleet" "$@"; }      # the CLI, run from the release

section "1. promote builds a release tree"

out=$(fleet_src promote 2>&1); rc=$?
chk "promote exits 0" 0 "$rc"
[ -L "$REL/current" ] && ok "current is a symlink" || no "current is a symlink"
tgt=$(readlink "$REL/current" 2>/dev/null)
case "$tgt" in
  rel-*) ok "current -> $tgt (relative, rel-<stamp>)" ;;
  *)     no "current -> '$tgt' (want a relative rel-<stamp>)" ;;
esac
[ -d "$REL/current/" ] && ok "current resolves to a directory" || no "current resolves to a directory"
[ -f "$REL/current/.stamp" ] && ok ".stamp written" || no ".stamp written"
[ -f "$REL/current/.release" ] && ok ".release metadata written" || no ".release metadata written"
[ -f "$REL/source" ] && ok "source pointer written" || no "source pointer written"
chk "source pointer names the worktree" "$SRC" "$(cat "$REL/source" 2>/dev/null)"
[ -f "$REL/drift" ] && no "no drift marker on the happy path" || ok "no drift marker on the happy path"

section "2. every manifest file landed, and node_modules did not"

MAN=$("$SRC/bin/fleet" release-manifest "$SRC" 2>/dev/null)
n=$(printf '%s\n' "$MAN" | grep -c . || true)
[ "${n:-0}" -ge 15 ] && ok "manifest is non-trivial ($n files)" || no "manifest is non-trivial (got $n)"

missing=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -f "$REL/current/$p" ] || missing="$missing $p"
done <<EOF
$MAN
EOF
chk "every manifest file present under current/" "" "$missing"

# The four bins install.sh links, explicitly — a regression here is the outage.
for b in fleet fleetd fleet-hook fleet-guard; do
  if [ -x "$REL/current/bin/$b" ]; then ok "current/bin/$b is executable"
  else no "current/bin/$b is executable"; fi
done
[ -e "$REL/current/lib/node_modules" ] \
  && no "lib/node_modules excluded from the release" \
  || ok "lib/node_modules excluded from the release"

section "2b. an INCOMPLETE source is refused, not quietly shipped"

# release_manifest skips what it cannot find, so a source missing a file would
# otherwise yield a self-consistent manifest and a quietly incomplete release —
# a half-promote reached from the other direction.
snap0=$(readlink "$REL/current")
mv "$SRC/bin/fleet-dash" "$SRC/bin/fleet-dash.hidden"
touch "$SRC/bin/fleet"
out=$(fleet_src promote 2>&1); rc=$?
chk "promote REFUSES a source missing bin/fleet-dash" 3 "$rc"
chk "current did not move" "$snap0" "$(readlink "$REL/current")"
grep -q 'bin/fleet-dash' "$REL/drift" 2>/dev/null \
  && ok "drift marker names the missing file" || no "drift marker names the missing file"
grep -q 'check: *missing' "$REL/drift" 2>/dev/null \
  && ok "drift marker names the 'missing' check" \
  || no "drift marker names the 'missing' check (got: $(grep check: "$REL/drift" 2>/dev/null))"
mv "$SRC/bin/fleet-dash.hidden" "$SRC/bin/fleet-dash"
fleet_src promote >/dev/null 2>&1
chk "and promotes again once the file is back" 0 "$?"

section "3. the release is STANDALONE — source worktree deleted"

rm -rf "$SRC"
[ -d "$SRC" ] && no "source worktree really deleted" || ok "source worktree really deleted"

out=$(fleet_rel ls 2>&1); rc=$?
chk "fleet ls exits 0 with no source worktree" 0 "$rc"

out=$(fleet_rel harnesses 2>&1); rc=$?
chk "fleet harnesses exits 0 (reads harness.d/ from the release)" 0 "$rc"
if printf '%s\n' "$out" | grep -q '^claude$'; then ok "harness.d/claude.conf shipped"
else no "harness.d/claude.conf shipped (got: $out)"; fi

# FLEET.md / FLEET_SUBORCH.md are read at runtime by the orchestrator guide
# installer and the sub-orch; nvim/fleet.lua is loaded into every spawned nvim.
for f in FLEET.md FLEET_SUBORCH.md nvim/fleet.lua systemd/fleetd.service; do
  [ -f "$REL/current/$f" ] && ok "$f shipped" || no "$f shipped"
done

out=$(fleet_rel doctor 2>&1); rc=$?
[ "$rc" -le 1 ] && ok "fleet doctor exits sanely from the release (rc=$rc)" \
                || no "fleet doctor exits sanely from the release (rc=$rc)"
# Anchored on the section header, not a loose 'release' grep — this script's own
# name contains "release", so a loose match passes against an error message.
if printf '%s\n' "$out" | grep -q '^--- release'; then ok "doctor reports a release section"
else no "doctor reports a release section"; fi

# The hot-path binaries, standalone. FLEET_NO_PROMOTE keeps this a pure
# standalone check rather than an accidental promote test.
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"true"}}' \
  | FLEET_NO_PROMOTE=1 sh "$REL/current/bin/fleet-guard" >/dev/null 2>&1
chk "fleet-guard runs from the release" 0 "$?"
FLEET_NO_PROMOTE=1 sh "$REL/current/bin/fleet-hook" idle >/dev/null 2>&1
chk "fleet-hook idle runs from the release" 0 "$?"

section "4. manifest vs packaging/PKGBUILD (shapes may not drift silently)"

# Every repo-relative path PKGBUILD installs into /usr/lib/fleet must also be in
# the release manifest. Direction is one-way on purpose: the manifest may ship
# MORE (skills/, systemd/) — it may never ship less.
# Only `install ...` PAYLOAD lines, and only their source operands (destinations
# are "$libdir/..." and are dropped). A loose grep over the whole function scoops
# up prose from the comments — `bin/...`, `lib/fleet` — and asserts nothing.
pkg=$(sed -n '/^package()/,$p' "$FLEET_REPO/packaging/PKGBUILD" \
      | grep -E '^[[:space:]]*(install |(bin|lib|nvim|harness\.d)/)' \
      | tr ' ' '\n' \
      | grep -E '^((bin|lib|nvim|harness\.d)/[A-Za-z0-9._*-]+|FLEET(_SUBORCH)?\.md)$' \
      | sort -u)
[ -n "$pkg" ] && ok "extracted PKGBUILD payload paths" || no "extracted PKGBUILD payload paths"

MANF="$TMPROOT/manifest.txt"; printf '%s\n' "$MAN" > "$MANF"
absent=""
for p in $pkg; do
  case "$p" in *'*'*)                       # expand the glob against the manifest
    pre="${p%%\**}"
    grep -q "^${pre}" "$MANF" || absent="$absent $p"
    continue ;;
  esac
  grep -qx "$p" "$MANF" || absent="$absent $p"
done
chk "every PKGBUILD-installed path is in the release manifest" "" "$absent"

proof_summary

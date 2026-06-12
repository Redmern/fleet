#!/usr/bin/env bash
# fleet installer — symlinks bins, installs the systemd unit, and idempotently
# wires fleet-hook into Claude Code profile settings. --uninstall reverses all.
set -euo pipefail

FLEET_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
PROFILES=("$HOME/.claude" "$HOME/.claude_personal")

HOOK_CMD="$BIN_DIR/fleet-hook"

wire_hooks() { # wire_hooks <settings.json>
  python3 - "$1" "$HOOK_CMD" <<'PY'
import json, sys

path, hook = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}

MAP = {
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "PermissionRequest": "blocked",
    "Notification": "blocked",
    "Stop": "idle",
    "SessionStart": "idle",
    "SessionEnd": "release",
}

hooks = settings.setdefault("hooks", {})
for event, action in MAP.items():
    entries = hooks.setdefault(event, [])
    # drop any previous fleet-hook or herdr entries for this event
    for entry in entries:
        entry["hooks"] = [
            h for h in entry.get("hooks", [])
            if "fleet-hook" not in h.get("command", "")
            and "herdr-agent-state" not in h.get("command", "")
        ]
    hooks[event] = [e for e in entries if e.get("hooks")]
    hooks[event].append({
        "matcher": "*",
        "hooks": [{
            "type": "command",
            "command": f"bash '{hook}' {action}",
            "timeout": 10,
        }],
    })

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"  wired hooks: {path}")
PY
}

unwire_hooks() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        settings = json.load(f)
except FileNotFoundError:
    sys.exit(0)
hooks = settings.get("hooks", {})
for event in list(hooks):
    entries = hooks[event]
    for entry in entries:
        entry["hooks"] = [h for h in entry.get("hooks", []) if "fleet-hook" not in h.get("command", "")]
    hooks[event] = [e for e in entries if e.get("hooks")]
    if not hooks[event]:
        del hooks[event]
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"  unwired hooks: {path}")
PY
}

if [ "${1:-}" = "--uninstall" ]; then
  systemctl --user disable --now fleetd 2>/dev/null || true
  rm -f "$UNIT_DIR/fleetd.service" "$BIN_DIR/fleet" "$BIN_DIR/fleetd" "$BIN_DIR/fleet-hook" "$BIN_DIR/fleet-tile"
  systemctl --user daemon-reload 2>/dev/null || true
  for p in "${PROFILES[@]}"; do
    [ -f "$p/settings.json" ] && unwire_hooks "$p/settings.json"
  done
  echo "fleet uninstalled"
  exit 0
fi

mkdir -p "$BIN_DIR" "$UNIT_DIR"
for b in fleet fleetd fleet-hook fleet-tile; do
  chmod +x "$FLEET_DIR/bin/$b"
  ln -sf "$FLEET_DIR/bin/$b" "$BIN_DIR/$b"
  echo "  linked $BIN_DIR/$b"
done

cp "$FLEET_DIR/systemd/fleetd.service" "$UNIT_DIR/fleetd.service"
systemctl --user daemon-reload
systemctl --user enable --now fleetd
echo "  fleetd.service enabled + started"

for p in "${PROFILES[@]}"; do
  [ -d "$p" ] || continue
  [ -f "$p/settings.json" ] || echo '{}' > "$p/settings.json"
  wire_hooks "$p/settings.json"
done

echo
echo "fleet installed. Try: fleet doctor && fleet up <project-root>"

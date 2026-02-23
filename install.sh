#!/bin/bash
# Install Claude Code iTerm2 notifications
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

echo "Installing Claude Code iTerm2 notifications..."
echo ""

# ── 1. Check for terminal-notifier ────────────────────────────────
if command -v terminal-notifier &>/dev/null; then
  echo "[ok] terminal-notifier already installed"
else
  echo "[..] Installing terminal-notifier via Homebrew..."
  if ! command -v brew &>/dev/null; then
    echo "[!!] Homebrew not found. Install it from https://brew.sh then re-run."
    exit 1
  fi
  brew install terminal-notifier
  echo "[ok] terminal-notifier installed"
fi

# ── 2. Copy hook script ──────────────────────────────────────────
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/notify.sh" "$HOOKS_DIR/notify.sh"
chmod +x "$HOOKS_DIR/notify.sh"
echo "[ok] Copied notify.sh to $HOOKS_DIR/"

# ── 3. Merge hooks into settings.json ────────────────────────────
# Create settings.json if it doesn't exist
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
  echo "[ok] Created $SETTINGS"
fi

# Use python3 to safely merge without clobbering existing settings
/usr/bin/python3 - "$SETTINGS" << 'PYMERGE'
import json, sys, os

settings_path = sys.argv[1]

# Read existing settings
try:
    with open(settings_path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

# The hooks we want to add
notify_hooks = {
    "Stop": [
        {
            "hooks": [{
                "type": "command",
                "command": "~/.claude/hooks/notify.sh stop"
            }]
        }
    ],
    "Notification": [
        {
            "matcher": "permission_prompt",
            "hooks": [{
                "type": "command",
                "command": "~/.claude/hooks/notify.sh permission"
            }]
        },
        {
            "matcher": "elicitation_dialog",
            "hooks": [{
                "type": "command",
                "command": "~/.claude/hooks/notify.sh question"
            }]
        }
    ]
}

if "hooks" not in settings:
    settings["hooks"] = {}

changed = False
for event, entries in notify_hooks.items():
    # Collect existing commands for this event to avoid duplicates
    existing_cmds = set()
    for entry in settings["hooks"].get(event, []):
        for h in entry.get("hooks", []):
            if h.get("type") == "command":
                existing_cmds.add(h.get("command", ""))

    if event not in settings["hooks"]:
        settings["hooks"][event] = []

    for entry in entries:
        cmd = entry["hooks"][0]["command"]
        if cmd not in existing_cmds:
            settings["hooks"][event].append(entry)
            changed = True

if changed:
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print("[ok] Added hooks to " + settings_path)
else:
    print("[ok] Hooks already present in " + settings_path)
PYMERGE

echo ""
echo "Done! Restart Claude Code to activate notifications."
echo ""
echo "First notification will prompt for macOS notification permission."
echo "Grant it in: System Settings > Notifications > terminal-notifier"

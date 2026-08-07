#!/bin/bash
# Uninstall Claude Code iTerm2 notifications
set -euo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

echo "Uninstalling Claude Code iTerm2 notifications..."
echo ""

# ── 1. Remove hook script ────────────────────────────────────────
if [ -f "$HOOKS_DIR/notify.sh" ]; then
  rm "$HOOKS_DIR/notify.sh"
  echo "[ok] Removed $HOOKS_DIR/notify.sh"
else
  echo "[--] notify.sh not found, skipping"
fi

# ── 2. Remove the collected notification event log ───────────────
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-iterm-notify"
if [ -d "$STATE_DIR" ]; then
  rm -rf "$STATE_DIR"
  echo "[ok] Removed event log at $STATE_DIR"
fi

# ── 3. Remove hooks from settings.json ───────────────────────────
if [ -f "$SETTINGS" ]; then
  /usr/bin/python3 - "$SETTINGS" << 'PYREMOVE'
import json, sys, os

settings_path = sys.argv[1]

try:
    with open(settings_path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    print("[--] Could not read settings.json, skipping")
    sys.exit(0)

if "hooks" not in settings:
    print("[--] No hooks in settings.json, skipping")
    sys.exit(0)

changed = False
for event in list(settings["hooks"].keys()):
    original = settings["hooks"][event]
    filtered = [
        entry for entry in original
        if not any(
            ".claude/hooks/notify.sh" in h.get("command", "")
            for h in entry.get("hooks", [])
            if h.get("type") == "command"
        )
    ]
    if len(filtered) != len(original):
        changed = True
        if filtered:
            settings["hooks"][event] = filtered
        else:
            del settings["hooks"][event]

# Remove empty hooks key
if not settings.get("hooks"):
    settings.pop("hooks", None)

if changed:
    tmp_path = settings_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, settings_path)
    print("[ok] Removed hooks from " + settings_path)
else:
    print("[--] No notify.sh hooks found in settings.json")
PYREMOVE
else
  echo "[--] settings.json not found, skipping"
fi

echo ""
echo "Done! Notifications removed."
echo ""
read -p "Also uninstall terminal-notifier? [y/N] " -n 1 -r || true
echo ""
if [[ "${REPLY:-}" =~ ^[Yy]$ ]]; then
  brew uninstall terminal-notifier 2>/dev/null && echo "[ok] terminal-notifier uninstalled" || echo "[--] terminal-notifier not installed via brew"
fi

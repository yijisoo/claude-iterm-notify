#!/bin/bash
# macOS notifications for Claude Code with iTerm2 click-to-focus
#
# Usage (called by Claude Code hooks):
#   echo '{"cwd":"/path"}' | notify.sh stop
#   echo '{"message":"..."}' | notify.sh permission
#   echo '{"message":"..."}' | notify.sh question
#
# Click callback (called by terminal-notifier):
#   notify.sh --focus <ITERM_SESSION_ID>

set -euo pipefail

# ── Click-to-focus callback ────────────────────────────────────────
if [ "${1:-}" = "--focus" ]; then
  TARGET_ID="${2:-}"
  [ -z "$TARGET_ID" ] && exit 0

  osascript <<EOF
tell application "iTerm2"
  activate
  set targetId to "$TARGET_ID"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        set sid to unique id of s
        -- Match regardless of whether unique id includes wXtYpZ: prefix
        if sid is in targetId or targetId is in sid then
          select t
          return
        end if
      end repeat
    end repeat
  end repeat
end tell
EOF
  exit 0
fi

# ── Helper: get iTerm tab title via AppleScript ───────────────────
get_tab_title() {
  local iterm_id="$1"
  [ -z "$iterm_id" ] && return
  osascript 2>/dev/null <<EOF || true
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        set sid to unique id of s
        if sid is in "$iterm_id" or "$iterm_id" is in sid then
          return name of t
        end if
      end repeat
    end repeat
  end repeat
end tell
EOF
}

# ── Notification flow ──────────────────────────────────────────────
HOOK_TYPE="${1:-stop}"
PAYLOAD=$(cat)

# Extract working directory → project name
CWD=$(/usr/bin/python3 -c "
import sys, json
print(json.load(sys.stdin).get('cwd', ''))
" <<< "$PAYLOAD" 2>/dev/null || echo "")
PROJECT=$(basename "${CWD:-unknown}")

# For Stop hooks, skip if Claude is looping from a previous stop hook
if [ "$HOOK_TYPE" = "stop" ]; then
  ACTIVE=$(/usr/bin/python3 -c "
import sys, json
print(json.load(sys.stdin).get('stop_hook_active', False))
" <<< "$PAYLOAD" 2>/dev/null || echo "False")
  [ "$ACTIVE" = "True" ] && exit 0
fi

# Build title and message based on hook type
case "$HOOK_TYPE" in
  stop)
    TITLE="$PROJECT"
    MSG="Ready for input"
    ;;
  permission)
    TITLE="$PROJECT — Permission"
    MSG=$(/usr/bin/python3 -c "
import sys, json
print(json.load(sys.stdin).get('message', 'Permission needed'))
" <<< "$PAYLOAD" 2>/dev/null || echo "Permission needed")
    ;;
  question)
    TITLE="$PROJECT — Question"
    MSG=$(/usr/bin/python3 -c "
import sys, json
print(json.load(sys.stdin).get('message', 'Claude has a question'))
" <<< "$PAYLOAD" 2>/dev/null || echo "Claude has a question")
    ;;
  *)
    TITLE="Claude Code"
    MSG="Needs attention"
    ;;
esac

# iTerm session ID inherited from Claude Code's shell environment
ITERM_ID="${ITERM_SESSION_ID:-}"

ARGS=(-title "$TITLE" -message "$MSG" -sound default)

# Add iTerm tab title as subtitle
if [ -n "$ITERM_ID" ]; then
  TAB_TITLE=$(get_tab_title "$ITERM_ID")
  if [ -n "$TAB_TITLE" ]; then
    ARGS+=(-subtitle "$TAB_TITLE")
  fi
fi

if [ -n "$ITERM_ID" ]; then
  # Group by session so new notifications replace stale ones
  ARGS+=(-group "claude-${ITERM_ID}")
  # On click, call this script back with --focus to switch to the right tab
  ARGS+=(-execute "$HOME/.claude/hooks/notify.sh --focus '$ITERM_ID'")
else
  # No session ID — just activate iTerm2
  ARGS+=(-activate com.googlecode.iterm2)
fi

terminal-notifier "${ARGS[@]}"

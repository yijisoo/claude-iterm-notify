#!/bin/bash
# macOS notifications for Claude Code / OMC with iTerm2 click-to-focus.
#
# Notify only when the firing session is shown in a live iTerm2 tab, and target
# that tab directly. Two cases produce a notification:
#   1. Claude running directly in an iTerm2 tab        -> target that tab
#   2. Claude in a tmux session attached to a tab      -> target the client tab
# A tmux session with NO attached client (an OMC worker/subagent or a stale,
# detached run) has no tab to land on, so it is intentionally NOT notified.
#
# Usage (Claude Code hooks):
#   echo '{"cwd":"/path"}' | notify.sh stop
#   echo '{"message":"..."}' | notify.sh permission
#   echo '{"message":"..."}' | notify.sh question
#
# Click callback (terminal-notifier):
#   notify.sh --focus 'tty:/dev/ttysNNN'

set -euo pipefail

# terminal-notifier's click callback runs with a minimal PATH that excludes
# Homebrew, so tmux/terminal-notifier would not be found. Ensure they are.
# Skipped under NOTIFY_TEST so the test harness can shadow tools with mocks.
if [ -z "${NOTIFY_TEST:-}" ]; then
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi

# Set NOTIFY_DEBUG=1 to trace decisions to /tmp/claude-iterm-notification-*.log
if [ "${NOTIFY_DEBUG:-}" = "1" ]; then
  LOG="/tmp/claude-iterm-notification-$(date +%Y%m%d-%H%M%S)-$$.log"
  log() { echo "$(date +%T) $*" >> "$LOG"; }
else
  log() { :; }
fi

# ── osascript wrapper with a timeout ───────────────────────────────
# An unresponsive/modal iTerm2 can make osascript hang indefinitely, which
# would stall this hook (Claude Code may kill a slow hook). Bound it with
# timeout/gtimeout when available; fall back to a bare call otherwise.
OSA_TIMEOUT_BIN=$(command -v gtimeout || command -v timeout || true)
osa() {
  if [ -n "$OSA_TIMEOUT_BIN" ]; then
    "$OSA_TIMEOUT_BIN" 5 osascript "$@"
  else
    osascript "$@"
  fi
}

# ── Is iTerm2 already running? (does NOT launch it) ────────────────
# `application "X" is running` is the canonical non-launching probe; a bare
# `tell application "iTerm2"` would otherwise boot iTerm2 in the background
# for users on Terminal.app/VS Code/etc. Cached for the life of the process.
ITERM_RUNNING_CACHE=""
iterm_running() {
  if [ -z "$ITERM_RUNNING_CACHE" ]; then
    if [ "$(osa -e 'application "iTerm2" is running' 2>/dev/null)" = "true" ]; then
      ITERM_RUNNING_CACHE=yes
    else
      ITERM_RUNNING_CACHE=no
    fi
  fi
  [ "$ITERM_RUNNING_CACHE" = "yes" ]
}

# Escape a string for embedding inside single quotes in a shell command.
sq_escape() { printf '%s' "${1//\'/\'\\\'\'}"; }

# ── AppleScript: select the iTerm2 tab whose session has the given tty ──
# Returns "yes" on success, "no" if no matching tty is currently visible.
focus_iterm_tty() {
  local target_tty="$1"
  osa 2>/dev/null <<EOF || echo "no"
tell application "iTerm2"
  activate
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          repeat with s in sessions of t
            try
              if tty of s is "$target_tty" then
                try
                  select w
                end try
                select t
                return "yes"
              end if
            end try
          end repeat
        end try
      end repeat
    end try
  end repeat
  return "no"
end tell
EOF
}

# ── Click-to-focus callback ────────────────────────────────────────
if [ "${1:-}" = "--focus" ]; then
  TARGET="${2:-}"
  case "$TARGET" in
    tty:*)
      TTY_PATH="${TARGET#tty:}"
      log "--focus: tty $TTY_PATH -> $(focus_iterm_tty "$TTY_PATH")"
      ;;
    *) log "--focus: nothing to do (target=$TARGET)" ;;
  esac
  exit 0
fi

# ── Is the user actively looking at this session right now? ───────
# True only if iTerm2 is frontmost AND its current tab is the one showing
# the given iTerm2 tty. Used to suppress redundant notifications.
user_is_watching() {
  local iterm_tty="$1"
  [ -z "$iterm_tty" ] && return 1
  local front
  front=$(osa -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "")
  [ "$front" != "iTerm2" ] && return 1
  local cur
  cur=$(osa 2>/dev/null <<EOF || true
tell application "iTerm2"
  try
    return tty of current session of current window
  end try
end tell
EOF
)
  [ "$cur" = "$iterm_tty" ]
}

# ── Debounce: true (notify) if this key wasn't notified recently ─────
# OMC loop modes (ralph/autopilot) make Claude stop-and-continue rapidly;
# without this every iteration would ping. One notification per window.
# Keyed on a DURABLE id (tmux session name, or tty for direct) so it survives
# the session being reattached to a different tab.
DEBOUNCE_SECONDS="${NOTIFY_DEBOUNCE_SECONDS:-180}"
DEBOUNCE_DIR="${NOTIFY_DEBOUNCE_DIR:-/tmp/claude-iterm-notify-debounce}"
debounce_ok() {
  local key_in="$1" key stamp now mtime
  key=$(printf '%s' "$key_in" | shasum 2>/dev/null | cut -c1-40)
  [ -z "$key" ] && key=$(printf '%s' "$key_in" | tr -c 'a-zA-Z0-9' '_')
  mkdir -p "$DEBOUNCE_DIR"
  # Opportunistically reap old stamps so they don't accumulate indefinitely.
  find "$DEBOUNCE_DIR" -type f -mtime +1 -delete 2>/dev/null || true
  stamp="$DEBOUNCE_DIR/$key"
  now=$(date +%s)
  if [ -f "$stamp" ]; then
    mtime=$(stat -f %m "$stamp" 2>/dev/null || echo 0)
    [ $((now - mtime)) -lt "$DEBOUNCE_SECONDS" ] && return 1
  fi
  touch "$stamp"
  return 0
}

# ── Find the controlling tty by walking up the process tree ───────
get_tty() {
  local pid=$$ t
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    t=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ' || true)
    if [ -n "$t" ] && [ "$t" != "??" ]; then
      echo "/dev/$t"
      return
    fi
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  done
}

# ── Resolve the iTerm2 tab for the firing session ──────────────────
# Echoes three lines: TARGET, SUBTITLE, DEBOUNCE_KEY.
#   TARGET   = "tty:<iterm-tty>"  -> notify and focus that tab
#            = "SKIP"             -> tmux session has no tab; do NOT notify
#            = ""                 -> no controlling tty; notify, just raise iTerm
resolve_tab() {
  local raw_tty
  raw_tty=$(get_tty)
  log "raw_tty=$raw_tty"
  if [ -z "$raw_tty" ]; then
    printf '\n\n\n'
    return
  fi

  # Is this tty a tmux pane? Then the tab is whatever client is attached to the
  # pane's session. No client => worker/subagent/stale run => no tab => SKIP.
  # TAB delimiter: tmux allows spaces and '|' in names, but never tabs.
  if command -v tmux >/dev/null 2>&1; then
    local line session title client
    line=$(tmux list-panes -a -F $'#{pane_tty}\t#{session_name}\t#{pane_title}' 2>/dev/null \
      | awk -F'\t' -v t="$raw_tty" '$1 == t {print; exit}' || true)
    if [ -n "$line" ]; then
      session=$(printf '%s' "$line" | cut -d$'\t' -f2)
      title=$(printf '%s' "$line" | cut -d$'\t' -f3-)
      client=$(tmux list-clients -F $'#{client_tty}\t#{session_name}' 2>/dev/null \
        | awk -F'\t' -v s="$session" '$2 == s {print $1; exit}' || true)
      if [ -z "$client" ]; then
        log "tmux session '$session' has no attached tab -> skipping"
        printf 'SKIP\n\n\n'
        return
      fi
      printf 'tty:%s\n%s\n%s\n' "$client" "${title:-$session}" "$session"
      return
    fi
  fi

  # Direct iTerm2 session (not a tmux pane). Subtitle = iTerm2 session name,
  # queried only if iTerm2 is running (so we never launch it).
  local name=""
  if iterm_running; then
    name=$(osa 2>/dev/null <<EOF || true
tell application "iTerm2"
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          repeat with s in sessions of t
            try
              if tty of s is "$raw_tty" then
                return name of s
              end if
            end try
          end repeat
        end try
      end repeat
    end try
  end repeat
end tell
EOF
)
  fi
  printf 'tty:%s\n%s\n%s\n' "$raw_tty" "$name" "$raw_tty"
}

# ── Notification flow ──────────────────────────────────────────────
HOOK_TYPE="${1:-stop}"
PAYLOAD=$(cat)
log "invoked: hook=$HOOK_TYPE pid=$$ ITERM_SESSION_ID=${ITERM_SESSION_ID:-<unset>}"

CWD=$(/usr/bin/python3 -c "
import sys, json
print(json.load(sys.stdin).get('cwd', ''))
" <<< "$PAYLOAD" 2>/dev/null || echo "")
PROJECT=$(basename "${CWD:-unknown}")

case "$HOOK_TYPE" in
  stop)
    TITLE="$PROJECT"
    MSG="Ready for input"
    ;;
  permission)
    TITLE="$PROJECT — Permission"
    MSG=$(/usr/bin/python3 -c "
import sys, json
m = json.load(sys.stdin).get('message', 'Permission needed')
print(str(m)[:200])
" <<< "$PAYLOAD" 2>/dev/null || echo "Permission needed")
    ;;
  question)
    TITLE="$PROJECT — Question"
    MSG=$(/usr/bin/python3 -c "
import sys, json
m = json.load(sys.stdin).get('message', 'Claude has a question')
print(str(m)[:200])
" <<< "$PAYLOAD" 2>/dev/null || echo "Claude has a question")
    ;;
  *)
    TITLE="Claude Code"
    MSG="Needs attention"
    ;;
esac

{ IFS= read -r TARGET; IFS= read -r SUBTITLE; IFS= read -r DEBOUNCE_KEY; } < <(resolve_tab)
log "TARGET=$TARGET SUBTITLE=$SUBTITLE DEBOUNCE_KEY=$DEBOUNCE_KEY"

# Tab-less tmux session (worker/subagent/stale run) -> do not notify at all.
if [ "$TARGET" = "SKIP" ]; then
  exit 0
fi

ITERM_TTY="${TARGET#tty:}"   # the tab's tty (empty if TARGET is empty)

# Skip redundant notifications when the user is already viewing this tab.
if [ "${NOTIFY_ALWAYS:-}" != "1" ] && user_is_watching "$ITERM_TTY"; then
  log "user is watching $ITERM_TTY — skipping notification"
  exit 0
fi

# Debounce Stop notifications so OMC loop modes don't ping every iteration.
# Permission/Question are explicit attention requests and are never debounced.
if [ "$HOOK_TYPE" = "stop" ] && [ -n "$DEBOUNCE_KEY" ] && ! debounce_ok "$DEBOUNCE_KEY"; then
  log "debounced (notified within ${DEBOUNCE_SECONDS}s) — skipping"
  exit 0
fi

ARGS=(-title "$TITLE" -message "$MSG" -sound default)
[ -n "$SUBTITLE" ] && ARGS+=(-subtitle "$SUBTITLE")

if [ -n "$TARGET" ]; then
  ARGS+=(-group "claude-${DEBOUNCE_KEY:-$TARGET}")
  ARGS+=(-execute "$HOME/.claude/hooks/notify.sh --focus '$(sq_escape "$TARGET")'")
else
  ARGS+=(-activate com.googlecode.iterm2)
fi

log "terminal-notifier: title=$TITLE target=$TARGET"
# Silence terminal-notifier's "* Removing previously sent notification…"
# chatter on stdout (it replaces grouped notifications on every fire), which
# Claude Code would otherwise surface as spurious hook output.
terminal-notifier "${ARGS[@]}" >/dev/null 2>&1 || true
log "done"

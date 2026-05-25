#!/bin/bash
# macOS notifications for Claude Code / OMC with iTerm2 click-to-focus.
#
# Works for three session topologies:
#   1. claude running directly in an iTerm2 tab        -> focus that tab
#   2. claude running in a tmux session shown in a tab -> focus that tab
#   3. claude in a *detached* tmux session (OMC bg)    -> attach in a new tab
#
# The durable handle is the tmux session name (survives detach/reattach);
# the iTerm2 tab is only a *current* view of it, resolved at click time.
#
# Usage (Claude Code hooks):
#   echo '{"cwd":"/path"}' | notify.sh stop
#   echo '{"message":"..."}' | notify.sh permission
#   echo '{"message":"..."}' | notify.sh question
#
# Click callback (terminal-notifier):
#   notify.sh --focus 'tty:/dev/ttysNNN'
#   notify.sh --focus 'tmux:<session-name>'

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

# ── Escaping helpers ───────────────────────────────────────────────
# Escape a string for embedding in an AppleScript double-quoted literal.
as_escape() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }
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

# ── AppleScript: open a new iTerm2 tab running a command ────────────
open_iterm_tab() {
  local cmd
  cmd=$(as_escape "$1")
  osa 2>/dev/null <<EOF || true
tell application "iTerm2"
  activate
  if (count of windows) > 0 then
    tell current window to create tab with default profile command "$cmd"
  else
    create window with default profile command "$cmd"
  end if
end tell
EOF
}

# ── Click-to-focus callback ────────────────────────────────────────
if [ "${1:-}" = "--focus" ]; then
  TARGET="${2:-}"
  [ -z "$TARGET" ] && exit 0
  log "--focus: target=$TARGET"

  case "$TARGET" in
    tty:*)
      TTY_PATH="${TARGET#tty:}"
      log "--focus: direct tty $TTY_PATH -> $(focus_iterm_tty "$TTY_PATH")"
      ;;
    tmux:*)
      SESSION="${TARGET#tmux:}"
      # Resolve the *currently* attached client (iTerm2 tty), if any.
      CLIENT_TTY=$(tmux list-clients -F $'#{client_tty}\t#{session_name}' 2>/dev/null \
        | awk -F'\t' -v s="$SESSION" '$2 == s {print $1; exit}' || true)
      if [ -n "$CLIENT_TTY" ]; then
        log "--focus: tmux '$SESSION' attached at $CLIENT_TTY -> $(focus_iterm_tty "$CLIENT_TTY")"
      else
        # Detached: attach it in a fresh tab if the session still exists.
        if tmux has-session -t "$SESSION" 2>/dev/null; then
          log "--focus: tmux '$SESSION' detached -> attaching in new tab"
          open_iterm_tab "tmux attach-session -t '$(sq_escape "$SESSION")'"
        else
          log "--focus: tmux '$SESSION' no longer exists"
          osa -e 'tell application "iTerm2" to activate' 2>/dev/null || true
        fi
      fi
      ;;
    *)
      log "--focus: unknown target scheme"
      ;;
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
  cur=$(osascript 2>/dev/null <<EOF || true
tell application "iTerm2"
  try
    return tty of current session of current window
  end try
end tell
EOF
)
  [ "$cur" = "$iterm_tty" ]
}

# ── Debounce: true (notify) if this target wasn't notified recently ──
# OMC loop modes (ralph/autopilot) make Claude stop-and-continue rapidly;
# without this every iteration would ping. One notification per window.
DEBOUNCE_SECONDS="${NOTIFY_DEBOUNCE_SECONDS:-180}"
DEBOUNCE_DIR="${NOTIFY_DEBOUNCE_DIR:-/tmp/claude-iterm-notify-debounce}"
debounce_ok() {
  local target="$1" key stamp now mtime
  # Hash the target so distinct sessions never collide on a sanitized key.
  key=$(printf '%s' "$target" | shasum 2>/dev/null | cut -c1-40)
  [ -z "$key" ] && key=$(printf '%s' "$target" | tr -c 'a-zA-Z0-9' '_')
  mkdir -p "$DEBOUNCE_DIR"
  # Opportunistically reap stamps older than a day so unique tmux session
  # names (e.g. OMC's timestamped sessions) don't accumulate indefinitely.
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

# ── Identify the session. Echoes two lines: TARGET then SUBTITLE. ──
# TARGET is "tmux:<name>" or "tty:<path>" (empty if no tty found).
identify_target() {
  local raw_tty
  raw_tty=$(get_tty)
  log "raw_tty=$raw_tty"
  if [ -z "$raw_tty" ]; then
    printf '\n\n'
    return
  fi

  # Is this tty a tmux pane? If so the durable handle is the session name,
  # and the human-friendly subtitle is the pane title (the Claude activity).
  if command -v tmux >/dev/null 2>&1; then
    # Use a TAB delimiter: tmux allows spaces and '|' in session names/titles,
    # but not tabs, so this survives any legal name.
    local line session title
    line=$(tmux list-panes -a -F $'#{pane_tty}\t#{session_name}\t#{pane_title}' 2>/dev/null \
      | awk -F'\t' -v t="$raw_tty" '$1 == t {print; exit}' || true)
    if [ -n "$line" ]; then
      session=$(printf '%s' "$line" | cut -d$'\t' -f2)
      title=$(printf '%s' "$line" | cut -d$'\t' -f3-)
      printf 'tmux:%s\n%s\n' "$session" "${title:-$session}"
      return
    fi
  fi

  # Direct iTerm2 session. Subtitle = the iTerm2 tab/session name.
  # Skip the query (and avoid launching iTerm2) if it isn't already running.
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
  printf 'tty:%s\n%s\n' "$raw_tty" "$name"
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

{ IFS= read -r TARGET; IFS= read -r SUBTITLE; } < <(identify_target)
log "TARGET=$TARGET SUBTITLE=$SUBTITLE"

# Determine which iTerm2 tty currently shows this session (empty if detached).
case "$TARGET" in
  tty:*) ITERM_TTY="${TARGET#tty:}" ;;
  tmux:*)
    SESSION="${TARGET#tmux:}"
    ITERM_TTY=$(tmux list-clients -F $'#{client_tty}\t#{session_name}' 2>/dev/null \
      | awk -F'\t' -v s="$SESSION" '$2 == s {print $1; exit}' || true)
    ;;
  *) ITERM_TTY="" ;;
esac

# Skip redundant notifications when the user is already viewing this session.
if [ "${NOTIFY_ALWAYS:-}" != "1" ] && user_is_watching "$ITERM_TTY"; then
  log "user is watching $ITERM_TTY — skipping notification"
  exit 0
fi

# Debounce Stop notifications so OMC loop modes don't ping every iteration.
# Permission/Question are explicit attention requests and are never debounced.
if [ "$HOOK_TYPE" = "stop" ] && [ -n "$TARGET" ] && ! debounce_ok "$TARGET"; then
  log "debounced (notified within ${DEBOUNCE_SECONDS}s) — skipping"
  exit 0
fi

ARGS=(-title "$TITLE" -message "$MSG" -sound default)
[ -n "$SUBTITLE" ] && ARGS+=(-subtitle "$SUBTITLE")

if [ -n "$TARGET" ]; then
  ARGS+=(-group "claude-${TARGET}")
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

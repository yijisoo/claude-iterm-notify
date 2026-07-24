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

# ── Event log: one TSV line per decision, for reviewing notification noise ──
# Always on (cheap, local, size-capped). Fields:
#   timestamp  event  outcome  project  session  target  detail
#   event   = hook type (stop|permission|question) or click (--focus callback)
#   outcome = notified|skip_no_tab|skip_watching|debounced, or yes|no for click
# Review with `notify.sh --report [days]`. Disable with NOTIFY_EVENT_LOG=0.
EVENT_LOG="${NOTIFY_EVENT_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-iterm-notify/events.tsv}"
EVENT_LOG_MAX_BYTES=524288   # ~weeks of events; one .old generation kept

# Collapse tabs/newlines and cap length so every event stays one TSV line.
clean_field() {
  local s="${1:--}"
  s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"
  printf '%s' "${s:0:160}"
}

# event_log <event> <outcome> <project> <session> <target> <detail>
# Must never fail or block the hook, whatever the filesystem does.
event_log() {
  if [ "$EVENT_LOG" = "0" ]; then return 0; fi
  mkdir -p "$(dirname "$EVENT_LOG")" 2>/dev/null || return 0
  local size
  size=$(stat -f %z "$EVENT_LOG" 2>/dev/null || echo 0)
  if [ "$size" -gt "$EVENT_LOG_MAX_BYTES" ] 2>/dev/null; then
    mv -f "$EVENT_LOG" "$EVENT_LOG.old" 2>/dev/null || true
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%Y-%m-%dT%H:%M:%S)" \
    "$(clean_field "$1")" "$(clean_field "$2")" "$(clean_field "$3")" \
    "$(clean_field "$4")" "$(clean_field "$5")" "$(clean_field "$6")" \
    >> "$EVENT_LOG" 2>/dev/null || true
  return 0
}

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
      FOCUS_RESULT=$(focus_iterm_tty "$TTY_PATH")
      log "--focus: tty $TTY_PATH -> $FOCUS_RESULT"
      event_log click "$FOCUS_RESULT" - - "$TARGET" -
      ;;
    *) log "--focus: nothing to do (target=$TARGET)" ;;
  esac
  exit 0
fi

# ── Summarize the event log ────────────────────────────────────────
# Must stay above the `PAYLOAD=$(cat)` hook flow: --report runs from a
# terminal with no piped stdin and must not block waiting for it.
if [ "${1:-}" = "--report" ]; then
  DAYS="${2:-7}"
  if [ ! -f "$EVENT_LOG" ] && [ ! -f "$EVENT_LOG.old" ]; then
    echo "No event log at $EVENT_LOG yet — it fills as Claude Code hooks fire."
    exit 0
  fi
  # ISO timestamps compare lexicographically; an empty cutoff includes all.
  CUTOFF=$(date -v"-${DAYS}d" +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")
  WINDOW=$(mktemp)
  trap 'rm -f "$WINDOW"' EXIT
  cat "$EVENT_LOG.old" "$EVENT_LOG" 2>/dev/null \
    | awk -F'\t' -v c="$CUTOFF" 'c == "" || $1 >= c' > "$WINDOW" || true

  TOTAL=$(wc -l < "$WINDOW" | tr -d ' ')
  DELIVERED=$(awk -F'\t' '$3 == "notified"' "$WINDOW" | wc -l | tr -d ' ')
  CLICKS=$(awk -F'\t' '$2 == "click"' "$WINDOW" | wc -l | tr -d ' ')

  echo "claude-iterm-notify — last $DAYS day(s)"
  echo "log: $EVENT_LOG"
  echo
  echo "Events: $TOTAL   (delivered $DELIVERED, clicks $CLICKS)"
  echo
  echo "Outcomes:"
  awk -F'\t' '$2 != "click" { print $3 }' "$WINDOW" | sort | uniq -c | sort -rn || true
  echo
  echo "Delivered by type:"
  awk -F'\t' '$3 == "notified" { print $2 }' "$WINDOW" | sort | uniq -c | sort -rn || true
  echo
  echo "Delivered by project:"
  awk -F'\t' '$3 == "notified" { print $4 }' "$WINDOW" | sort | uniq -c | sort -rn | head -10 || true
  echo
  echo "Noisiest sessions (delivered):"
  awk -F'\t' '$3 == "notified" { print $4 " / " $5 }' "$WINDOW" | sort | uniq -c | sort -rn | head -10 || true
  echo
  echo "Suppressed tab-less sessions (top):"
  awk -F'\t' '$3 == "skip_no_tab" { print $4 " / " $5 }' "$WINDOW" | sort | uniq -c | sort -rn | head -10 || true
  echo
  # Burst = a delivered notification landing <=60s after the previous one
  # (any session) — the "many parallel sessions ping at once" pressure.
  # Day-seconds comparison; bursts spanning midnight are not counted.
  BURSTS=$(awk -F'\t' '$3 == "notified" {
      d = substr($1, 1, 10)
      split(substr($1, 12), a, ":")
      s = a[1]*3600 + a[2]*60 + a[3]
      if (d == pd && s >= ps && s - ps <= 60) n++
      pd = d; ps = s
    } END { print n + 0 }' "$WINDOW")
  if [ "$DELIVERED" -gt 0 ]; then
    echo "Click-through: $CLICKS of $DELIVERED delivered ($((100 * CLICKS / DELIVERED))%)"
  fi
  echo "Bursts: $BURSTS delivered within 60s of the previous delivered notification"
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

# Filesystem-safe stamp name for a session key (shared by debounce + hold).
hash_key() {
  local key
  key=$(printf '%s' "$1" | shasum 2>/dev/null | cut -c1-40)
  if [ -z "$key" ]; then
    key=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')
  fi
  printf '%s' "$key"
}

debounce_ok() {
  local key_in="$1" key stamp now mtime
  key=$(hash_key "$key_in")
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

# ── Is this hook running under a spawned agent-team worker? ────────
# Worker sessions are launched as `claude --agent-id <agent>@<session>`;
# sessions the user drives carry no such flag. Positive match only: if a
# future Claude Code renames the flag, workers simply notify again
# (today's behavior) instead of anything going silent.
is_agent_worker() {
  local pid=$$ cmd depth=0
  # Depth cap: a real ancestry ends at pid 1, but never trust ps output
  # (or a test mock) to guarantee progress toward it.
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 25 ]; do
    cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
    case "$cmd" in
      *" --agent-id "*|*" --agent-id="*) return 0 ;;
    esac
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
    depth=$((depth + 1))
  done
  return 1
}

# ── Working-spinner detection on a tab title ───────────────────────
# Claude Code titles a working session with a braille-dot spinner frame
# (any of U+2800-28FF) and an idle one with '✳'. We match the whole
# braille block, and we hold ONLY on a positive spinner match: if the
# title convention ever changes, the gate never engages and behavior
# falls back to notify-immediately — late is possible, silence is not.
has_spinner() {
  printf '%s' "${1:-}" | /usr/bin/python3 -c '
import sys
text = sys.stdin.buffer.read().decode("utf-8", "replace")
sys.exit(0 if any(0x2800 <= ord(c) <= 0x28FF for c in text) else 1)
' 2>/dev/null
}

# ── Re-read the live title for the firing session's raw tty ────────
# tmux pane title when the tty is a pane, else the iTerm2 session name.
current_title() {
  local raw_tty="$1" t
  if command -v tmux >/dev/null 2>&1; then
    t=$(tmux list-panes -a -F $'#{pane_tty}\t#{pane_title}' 2>/dev/null \
      | awk -F'\t' -v t="$raw_tty" '$1 == t { sub(/^[^\t]*\t/, ""); print; exit }' || true)
    if [ -n "$t" ]; then
      printf '%s' "$t"
      return 0
    fi
  fi
  osa 2>/dev/null <<EOF || true
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
}

# ── Resolve the iTerm2 tab for the firing session ──────────────────
# Echoes four lines: TARGET, SUBTITLE, DEBOUNCE_KEY, RAW_TTY.
#   TARGET   = "tty:<iterm-tty>"  -> notify and focus that tab
#            = "SKIP"             -> tmux session has no tab; do NOT notify
#            = ""                 -> no controlling tty; notify, just raise iTerm
#   RAW_TTY  = the firing process's own tty (for live title re-checks)
resolve_tab() {
  local raw_tty
  raw_tty=$(get_tty)
  log "raw_tty=$raw_tty"
  if [ -z "$raw_tty" ]; then
    printf '\n\n\n\n'
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
        # Still surface title + session so the skip can be logged by name.
        printf 'SKIP\n%s\n%s\n%s\n' "${title:-$session}" "$session" "$raw_tty"
        return
      fi
      printf 'tty:%s\n%s\n%s\n%s\n' "$client" "${title:-$session}" "$session" "$raw_tty"
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
  printf 'tty:%s\n%s\n%s\n%s\n' "$raw_tty" "$name" "$raw_tty" "$raw_tty"
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

{ IFS= read -r TARGET; IFS= read -r SUBTITLE; IFS= read -r DEBOUNCE_KEY; IFS= read -r RAW_TTY; } < <(resolve_tab)
log "TARGET=$TARGET SUBTITLE=$SUBTITLE DEBOUNCE_KEY=$DEBOUNCE_KEY RAW_TTY=$RAW_TTY"

# Event-log detail: what the session was doing (stop) or what it asked (rest).
if [ "$HOOK_TYPE" = "stop" ]; then DETAIL="$SUBTITLE"; else DETAIL="$MSG"; fi

# Tab-less tmux session (worker/subagent/stale run) -> do not notify at all.
if [ "$TARGET" = "SKIP" ]; then
  event_log "$HOOK_TYPE" skip_no_tab "$PROJECT" "$DEBOUNCE_KEY" - "$DETAIL"
  exit 0
fi

ITERM_TTY="${TARGET#tty:}"   # the tab's tty (empty if TARGET is empty)

# Agent-team worker session: its "done" is the orchestrator's business, not
# an attention request — suppress the stop. Permission/Question still notify
# (a worker blocked on approval is stuck until the user acts).
# NOTIFY_AGENT_STOPS=1 restores worker stop notifications.
if [ "$HOOK_TYPE" = "stop" ] && [ "${NOTIFY_AGENT_STOPS:-}" != "1" ] && is_agent_worker; then
  log "agent-team worker session — suppressing stop"
  event_log "$HOOK_TYPE" skip_agent_worker "$PROJECT" "$DEBOUNCE_KEY" "$TARGET" "$DETAIL"
  exit 0
fi

# Deliver: watching re-check + debounce + send. Shared by the immediate path
# and the idle-gate watcher, so a held delivery re-checks everything late.
# Mode "heartbeat" = truthful still-busy visibility ping from the watcher.
deliver_now() {
  local mode="${1:-}"
  if [ "${NOTIFY_ALWAYS:-}" != "1" ] && user_is_watching "$ITERM_TTY"; then
    log "user is watching $ITERM_TTY — skipping notification"
    event_log "$HOOK_TYPE" skip_watching "$PROJECT" "$DEBOUNCE_KEY" "$TARGET" "$DETAIL"
    return 0
  fi
  # Debounce Stop notifications so loop modes don't ping every iteration.
  # Permission/Question are explicit attention requests, never debounced.
  # Heartbeats skip the debounce AND must not mark its stamp: consuming it
  # here would swallow the real "Ready" if the session idles minutes later.
  if [ "$mode" != "heartbeat" ] \
     && [ "$HOOK_TYPE" = "stop" ] && [ -n "$DEBOUNCE_KEY" ] && ! debounce_ok "$DEBOUNCE_KEY"; then
    log "debounced (notified within ${DEBOUNCE_SECONDS}s) — skipping"
    event_log "$HOOK_TYPE" debounced "$PROJECT" "$DEBOUNCE_KEY" "$TARGET" "$DETAIL"
    return 0
  fi
  local msg="$MSG" outcome="notified"
  if [ "$mode" = "heartbeat" ]; then
    msg="Still working ($(( (HOLD_MAX + 59) / 60 ))+ min, no pause yet)"
    outcome="heartbeat"
  fi
  local ARGS=(-title "$TITLE" -message "$msg" -sound default)
  if [ -n "$SUBTITLE" ]; then ARGS+=(-subtitle "$SUBTITLE"); fi
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
  event_log "$HOOK_TYPE" "$outcome" "$PROJECT" "$DEBOUNCE_KEY" "$TARGET" "$DETAIL"
  return 0
}

# Idle-gate mid-work stops: a stop whose tab title still shows the working
# spinner is an intermediate turn end (e.g. subagents still running). Hold it
# and deliver when the session actually goes idle. The newest stop for a
# session owns the hold stamp, so a burst collapses into one notification at
# the true end. A session that stays busy a full NOTIFY_HOLD_MAX_SECONDS gets
# a truthful "Still working" heartbeat on a clock that superseding stops
# cannot reset — a busy session can be pinged late, but never starved silent.
HOLD_MAX="${NOTIFY_HOLD_MAX_SECONDS:-600}"
HOLD_POLL="${NOTIFY_HOLD_POLL_SECONDS:-10}"
if [ "$HOOK_TYPE" = "stop" ] && [ "$HOLD_MAX" -gt 0 ]; then
  HOLD_STAMP="$DEBOUNCE_DIR/hold-$(hash_key "$DEBOUNCE_KEY")"
  HOLD_SINCE="$DEBOUNCE_DIR/since-$(hash_key "$DEBOUNCE_KEY")"
  if [ -n "$RAW_TTY" ] && has_spinner "$SUBTITLE"; then
    HOLD_TOKEN="$$.$(date +%s)"
    mkdir -p "$DEBOUNCE_DIR" 2>/dev/null || true
    printf '%s' "$HOLD_TOKEN" > "$HOLD_STAMP" 2>/dev/null || true
    # The FIRST un-delivered hold starts the heartbeat clock; superseding
    # stops leave it alone (resetting it starved churning loop sessions).
    if [ ! -f "$HOLD_SINCE" ]; then
      date +%s > "$HOLD_SINCE" 2>/dev/null || true
    fi
    event_log "$HOOK_TYPE" held "$PROJECT" "$DEBOUNCE_KEY" "$TARGET" "$DETAIL"
    log "held: spinner in title — waiting for idle (poll ${HOLD_POLL}s, heartbeat ${HOLD_MAX}s)"
    (
      while :; do
        sleep "$HOLD_POLL"
        # Superseded by a newer stop for this session? Its watcher delivers.
        [ "$(cat "$HOLD_STAMP" 2>/dev/null)" = "$HOLD_TOKEN" ] || exit 0
        TITLE_NOW=$(current_title "$RAW_TTY")
        if ! has_spinner "$TITLE_NOW"; then
          # Session paused for real: the notification the user wanted.
          rm -f "$HOLD_STAMP" "$HOLD_SINCE" 2>/dev/null || true
          if [ -n "$TITLE_NOW" ]; then
            SUBTITLE="$TITLE_NOW"
            DETAIL="$TITLE_NOW"
          fi
          deliver_now
          exit 0
        fi
        SINCE=$(cat "$HOLD_SINCE" 2>/dev/null || true)
        case "$SINCE" in ''|*[!0-9]*) SINCE="" ;; esac
        NOW=$(date +%s)
        if [ -n "$SINCE" ] && [ "$NOW" -ge $(( SINCE + HOLD_MAX )) ]; then
          # Still busy a full interval later: truthful heartbeat, re-arm.
          if [ -n "$TITLE_NOW" ]; then
            SUBTITLE="$TITLE_NOW"
            DETAIL="$TITLE_NOW"
          fi
          deliver_now heartbeat
          printf '%s' "$NOW" > "$HOLD_SINCE" 2>/dev/null || true
        fi
      done
    ) </dev/null >/dev/null 2>&1 &
    exit 0
  fi
  # Title already idle at stop time: clear any hold state so a stale
  # watcher can't double-deliver after this immediate notification.
  rm -f "$HOLD_STAMP" "$HOLD_SINCE" 2>/dev/null || true
fi

deliver_now
log "done"

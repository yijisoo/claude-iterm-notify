#!/bin/bash
# claude-iterm-notify — macOS notifications for Claude Code / OMC
# (oh-my-claudecode), with click-to-focus into the exact iTerm2 tab.
#
# ═══ The overall goal ═══════════════════════════════════════════════
# When a Claude Code session needs the user (it finished a turn, wants a
# permission, or asked a question), pop a native macOS notification — but
# ONLY when that session is actually visible somewhere the user can act on
# it, and make clicking the notification jump straight to that tab.
#
# "Somewhere the user can act" means a live iTerm2 tab. Two cases qualify:
#   1. Claude running directly in an iTerm2 tab        -> target that tab
#   2. Claude in a tmux session attached to a tab      -> target the client tab
# A tmux session with NO attached client (an OMC worker/subagent or a stale,
# detached run) has no tab to land on, so its "done" is intentionally NOT
# notified — that would be noise the user cannot click into.
#
# Everything else in this file exists to keep those notifications quiet and
# truthful: suppress the redundant ones (already watching, repeat pings,
# mid-work pauses), retract the stale ones, and log every decision so the
# noise level can be reviewed later.
#
# ═══ Entry points ═══════════════════════════════════════════════════
# Claude Code hooks (one JSON — JavaScript Object Notation — payload on stdin):
#   echo '{"cwd":"/path"}'      | notify.sh stop        # turn ended / ready
#   echo '{"message":"..."}'    | notify.sh permission  # tool call awaits approval
#   echo '{"message":"..."}'    | notify.sh question    # a question awaits an answer
#   echo '{"cwd":"/path"}'      | notify.sh title       # SessionStart: name the tab (opt-in)
# Invoked by terminal-notifier when the user clicks a notification:
#   notify.sh --focus 'tty:/dev/ttysNNN'
# Run by hand from a terminal:
#   notify.sh --report [days]                           # summarize the event log
#
# ═══ How a hook event flows through the script ══════════════════════
#   1. Parse the JSON payload -> PROJECT (working-directory basename).
#   2. resolve_tab: which iTerm2 tab shows this session, if any — walk the
#      process tree to the controlling tty (terminal device), then map a
#      tmux pane to its attached client tab where applicable.
#   3. clear_stale_notification: any new activity on a session retracts the
#      banner it last posted, before anything else is decided.
#   4. Suppression gates, in order — first match wins, every outcome logged:
#        a. tab-less skip      stop only: nowhere to click into
#        b. agent-worker skip  stop only: a worker's "done" belongs to its
#                              orchestrator, not the user
#        c. idle-gate hold     tab title still shows the working spinner ->
#                              park the event; a background watcher delivers
#                              when the session truly idles, with a "still
#                              working" heartbeat if busy a full interval
#        d. watching skip      iTerm2 frontmost on this very tab already
#        e. debounce           stop only: at most one ping per window per
#                              session, keyed on a durable identity
#   5. Send via terminal-notifier, tagged with a per-session -group id so a
#      later invocation can replace/retract it, plus a "live" marker on disk.
#
# ═══ State on disk ══════════════════════════════════════════════════
#   ~/.local/state/claude-iterm-notify/events.tsv
#       append-only TSV (tab-separated values) decision log; see --report
#   /tmp/claude-iterm-notify-debounce/
#       <hash>        debounce stamp (mtime = when this session last notified)
#       hold-<hash>   idle-gate hold token (the newest stop owns delivery)
#       since-<hash>  when the current busy stretch began (heartbeat clock)
#       live-<hash>   marker: a banner for this session is currently showing
#
# ═══ Design rules the whole file follows ════════════════════════════
#   * Gates match POSITIVELY, and detection failure means "gate does not
#     engage", never "go silent": if Claude Code renames a flag or changes
#     the spinner glyph, behavior degrades to notify-immediately. A late or
#     duplicate notification is acceptable; a silently dropped one is not.
#   * The hook must never fail, block, or leak output: external calls are
#     `|| true`-guarded, osascript is bounded by a timeout, and stdout is
#     swallowed (Claude Code surfaces stray hook stdout to the user).
#   * Targeting is resolved at NOTIFICATION time, not click time: the click
#     callback carries only a tty path. docs/notification-targeting.md
#     records why the durable tmux: scheme was removed.
#
# Tuning knobs (environment variables), all optional:
#   NOTIFY_DEBUG=1               trace decisions to /tmp/claude-iterm-notification-*.log
#   NOTIFY_EVENT_LOG=0|<path>    disable or relocate the event log
#   NOTIFY_ALWAYS=1              notify even when already watching the tab
#   NOTIFY_AGENT_STOPS=1         notify agent-worker stops too
#   NOTIFY_DEBOUNCE_SECONDS=N    stop-ping window per session (default 1200)
#   NOTIFY_HOLD_MAX_SECONDS=N    busy-heartbeat interval (default 600; 0 disables idle-gating)
#   NOTIFY_HOLD_POLL_SECONDS=N   idle-gate title poll interval (default 10)
#   NOTIFY_SET_TITLE=1           allow the `title` hook to rename the tab
#   NOTIFY_TEST=1                test harness: skip the Homebrew PATH prepend

# Strict mode: unset variables and unchecked failures abort. Every call
# below that may legitimately fail is explicitly `|| true`-guarded so the
# only aborts left are genuine bugs.
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
#   event   = hook type (stop|permission|question), click (--focus callback),
#             or retract (a stale notification was cleared before delivery)
#   outcome = notified|held|heartbeat|skip_no_tab|skip_watching|
#             skip_agent_worker|debounced, or yes/no for click, or yes for retract
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
    chmod 600 "$EVENT_LOG.old" 2>/dev/null || true
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%Y-%m-%dT%H:%M:%S)" \
    "$(clean_field "$1")" "$(clean_field "$2")" "$(clean_field "$3")" \
    "$(clean_field "$4")" "$(clean_field "$5")" "$(clean_field "$6")" \
    >> "$EVENT_LOG" 2>/dev/null || true
  # Enforced on every write (not just at creation) so the log stays
  # owner-only even if it pre-existed with looser permissions.
  chmod 600 "$EVENT_LOG" 2>/dev/null || true
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

# Escape a string for embedding inside a double-quoted AppleScript string
# literal. Needed only for values that aren't shape-constrained the way a
# tty/session name is — a directory basename can contain anything.
as_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# ── AppleScript: select the iTerm2 tab whose session has the given tty ──
# Brute-force walk over every window -> tab -> session, comparing each
# session's tty to the target; on a match, raise that window and select the
# tab. Each level sits in its own `try` so a window or tab closing mid-walk
# skips that one object instead of aborting the whole search.
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
# Not a hook: terminal-notifier runs this (via its -execute option) when the
# user clicks a notification. The argument is the tty captured at send time;
# find the tab showing it NOW and jump there, logging whether that worked.
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
# Aggregates the TSV decision log (current file + rotated .old) into
# delivery, suppression, click-through, and burst statistics — the tool for
# judging whether the gates above are tuned right.
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
  # "Actionable" = notified (a genuine decision point: ready/permission/question).
  # Heartbeat is a real terminal-notifier send too, but deliberately a lower-
  # urgency FYI by design — kept out of click-through's denominator (that
  # metric means "did you act on a decision point"), but never hidden.
  ACTIONABLE=$(awk -F'\t' '$3 == "notified"' "$WINDOW" | wc -l | tr -d ' ')
  HEARTBEATS=$(awk -F'\t' '$3 == "heartbeat"' "$WINDOW" | wc -l | tr -d ' ')
  CLICKS=$(awk -F'\t' '$2 == "click"' "$WINDOW" | wc -l | tr -d ' ')
  RETRACTED=$(awk -F'\t' '$2 == "retract"' "$WINDOW" | wc -l | tr -d ' ')

  echo "claude-iterm-notify — last $DAYS day(s)"
  echo "log: $EVENT_LOG"
  echo
  echo "Events: $TOTAL   (actionable $ACTIONABLE, heartbeat $HEARTBEATS, clicks $CLICKS, retracted $RETRACTED)"
  echo
  echo "Outcomes:"
  awk -F'\t' '$2 != "click" && $2 != "retract" { print $3 }' "$WINDOW" | sort | uniq -c | sort -rn || true
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
  # Burst = a real notification (actionable OR heartbeat — both are genuine
  # terminal-notifier sends) landing <=60s after the previous one (any
  # session) — the "many parallel sessions ping at once" pressure, which a
  # heartbeat contributes to regardless of its lower urgency.
  # Day-seconds comparison; bursts spanning midnight are not counted.
  BURSTS=$(awk -F'\t' '$3 == "notified" || $3 == "heartbeat" {
      d = substr($1, 1, 10)
      split(substr($1, 12), a, ":")
      s = a[1]*3600 + a[2]*60 + a[3]
      if (d == pd && s >= ps && s - ps <= 60) n++
      pd = d; ps = s
    } END { print n + 0 }' "$WINDOW")
  if [ "$ACTIONABLE" -gt 0 ]; then
    echo "Click-through: $CLICKS of $ACTIONABLE actionable delivered ($((100 * CLICKS / ACTIONABLE))%)"
  fi
  echo "Bursts: $BURSTS deliveries (actionable + heartbeat) within 60s of the previous one"
  echo "Retracted: $RETRACTED stale notifications cleared before you could click a now-outdated one"
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
# 20 min, not the pre-idle-gating 180s: idle-gating already collapses raw
# rapid-fire stops into one delivery per real pause, so what debounce now
# throttles is repeat "Ready for input" pings from a session that keeps
# cycling through genuine idle points every few minutes (loop modes like
# ralph/autopilot/standup-autopilot) — 180s pinged almost every cycle.
DEBOUNCE_SECONDS="${NOTIFY_DEBOUNCE_SECONDS:-1200}"
DEBOUNCE_DIR="${NOTIFY_DEBOUNCE_DIR:-/tmp/claude-iterm-notify-debounce}"

# Filesystem-safe stamp name for a session key (shared by debounce + hold).
# shasum keeps arbitrary keys (tmux session names may contain spaces or
# unicode) collision-safe; if it is somehow unavailable, degrade to
# character-squashing rather than failing the hook.
hash_key() {
  local key
  key=$(printf '%s' "$1" | shasum 2>/dev/null | cut -c1-40)
  if [ -z "$key" ]; then
    key=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')
  fi
  printf '%s' "$key"
}

# One mtime-stamped file per session key: notify only if the stamp is
# absent or older than the window, and (re)touch it whenever we do.
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

# Group id used for both -group (on send) and -remove (on retraction), so the
# two always agree. Reads the globals set by the time either call site runs.
notify_group() { printf 'claude-%s' "${DEBOUNCE_KEY:-$TARGET}"; }

# Any new hook firing for a session proves whatever notification was last
# shown for it is now stale — the user may have resolved it directly at the
# terminal instead of clicking through, or the session may have simply moved
# on. Retract it before deciding whether THIS event warrants a new one.
# Marker existence only; the group id is recomputed from the current
# DEBOUNCE_KEY, the same stable session identity used when it was set.
clear_stale_notification() {
  local key_in="$1" marker
  [ -z "$key_in" ] && return 0
  marker="$DEBOUNCE_DIR/live-$(hash_key "$key_in")"
  [ -f "$marker" ] || return 0
  rm -f "$marker" 2>/dev/null || true
  terminal-notifier -remove "$(notify_group)" >/dev/null 2>&1 || true
  log "cleared stale notification group=$(notify_group) (new activity on this session)"
  event_log retract yes "$PROJECT" "$key_in" "$(notify_group)" "$DETAIL"
  return 0
}

# ── Find the controlling tty by walking up the process tree ───────
# The hook process itself may report no terminal of its own (ps shows "??"),
# but some ancestor — the Claude Code process, its shell, the tmux pane —
# holds the controlling terminal this session lives on. Walk parent by
# parent until one reports a real tty; that device path is the session's
# identity for everything downstream (tab lookup, focus target, debounce key).
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
# Used by the idle-gate watcher to see the CURRENT spinner state, as opposed
# to the snapshot resolve_tab took when the stop event originally fired.
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
# Everything below runs once per hook event, top to bottom: read the
# payload, build the banner text, resolve the tab, then fall through the
# suppression gates to (maybe) a terminal-notifier send.
HOOK_TYPE="${1:-stop}"
PAYLOAD=$(cat)   # Claude Code pipes one JSON object describing the event
log "invoked: hook=$HOOK_TYPE pid=$$ ITERM_SESSION_ID=${ITERM_SESSION_ID:-<unset>}"

# The project name (working-directory basename) is the notification's title
# line and the per-project axis of the event log. python3 is the JSON
# parser: always present on macOS, and never confused by quoting the way
# grep/sed on JSON would be.
CWD=$(/usr/bin/python3 -c "
import sys, json
print(json.load(sys.stdin).get('cwd', ''))
" <<< "$PAYLOAD" 2>/dev/null || echo "")
PROJECT=$(basename "${CWD:-unknown}")

# ── SessionStart: set the tab title from the project name (opt-in) ──
# sessionTitle's actual effect on the real terminal is undocumented (may be
# internal to Claude Code's own UI only), so this doesn't depend on it at
# all — it sets the tmux pane title / iTerm2 session name directly via
# well-documented primitives. Off by default (NOTIFY_SET_TITLE=1 to enable):
# this is the one place the script WRITES terminal/tmux state instead of
# just reading it, and there's no reliable way to tell "default title" from
# "user renamed this tab" apart, so opt-in is the safety net, not a guess.
if [ "$HOOK_TYPE" = "title" ]; then
  if [ "${NOTIFY_SET_TITLE:-}" = "1" ]; then
    if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
      # Runs synchronously inside the real session, so it inherits its
      # actual TMUX env — the current pane needs no lookup, unlike --focus
      # which runs later from a disconnected process tree.
      tmux select-pane -T "$PROJECT" >/dev/null 2>&1 || true
      log "title: set tmux pane title to $PROJECT"
    elif iterm_running; then
      RAW_TTY=$(get_tty)
      if [ -n "$RAW_TTY" ]; then
        osa 2>/dev/null <<EOF || true
tell application "iTerm2"
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          repeat with s in sessions of t
            try
              if tty of s is "$RAW_TTY" then set name of s to "$(as_escape "$PROJECT")"
            end try
          end repeat
        end try
      end repeat
    end try
  end repeat
end tell
EOF
        log "title: set iTerm2 session name to $PROJECT"
      fi
    fi
  fi
  exit 0
fi

# Map the hook type to banner text. Permission/Question quote the actual
# prompt out of the payload (capped at 200 chars — Notification Center
# truncates anyway); stop is always the fixed "Ready for input".
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

# resolve_tab reports over four lines (click target, human-readable
# subtitle, durable session key, raw tty) — read them into the globals that
# every gate and deliver_now consume from here on.
{ IFS= read -r TARGET; IFS= read -r SUBTITLE; IFS= read -r DEBOUNCE_KEY; IFS= read -r RAW_TTY; } < <(resolve_tab)
log "TARGET=$TARGET SUBTITLE=$SUBTITLE DEBOUNCE_KEY=$DEBOUNCE_KEY RAW_TTY=$RAW_TTY"

# Event-log detail: what the session was doing (stop) or what it asked (rest).
if [ "$HOOK_TYPE" = "stop" ]; then DETAIL="$SUBTITLE"; else DETAIL="$MSG"; fi

# This session did something — retract whatever was last shown for it before
# deciding whether this event itself warrants a new notification. Runs
# ahead of every exit path (SKIP, worker-suppressed, held, debounced) so a
# stale notification never outlives the state it described.
clear_stale_notification "$DEBOUNCE_KEY"

# Tab-less tmux session (worker/subagent/stale run): a "stop" has nothing to
# click into, so it's not notified. Permission/Question are different — the
# worker is genuinely blocked waiting on the user, so still notify, just
# without a click target (there's no client tab to focus).
if [ "$TARGET" = "SKIP" ]; then
  if [ "$HOOK_TYPE" = "stop" ]; then
    event_log "$HOOK_TYPE" skip_no_tab "$PROJECT" "$DEBOUNCE_KEY" - "$DETAIL"
    exit 0
  fi
  log "tab-less worker but hook=$HOOK_TYPE is an attention request — notifying without a click target"
  TARGET=""
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
    ARGS+=(-group "$(notify_group)")
    ARGS+=(-execute "$HOME/.claude/hooks/notify.sh --focus '$(sq_escape "$TARGET")'")
  else
    ARGS+=(-activate com.googlecode.iterm2)
  fi
  log "terminal-notifier: title=$TITLE target=$TARGET"
  # Silence terminal-notifier's "* Removing previously sent notification…"
  # chatter on stdout (it replaces grouped notifications on every fire), which
  # Claude Code would otherwise surface as spurious hook output.
  terminal-notifier "${ARGS[@]}" >/dev/null 2>&1 || true
  # Mark this session's notification live so a later invocation with nothing
  # new to show (held/debounced/suppressed) can still retract it on its own.
  if [ -n "$DEBOUNCE_KEY" ]; then
    mkdir -p "$DEBOUNCE_DIR" 2>/dev/null || true
    touch "$DEBOUNCE_DIR/live-$(hash_key "$DEBOUNCE_KEY")" 2>/dev/null || true
  fi
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

# Immediate path: stop events whose title was already idle (or idle-gating
# disabled), plus every permission/question. deliver_now still applies the
# watching and debounce gates before actually sending.
deliver_now
log "done"

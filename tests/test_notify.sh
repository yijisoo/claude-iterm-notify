#!/bin/bash
# Black-box tests for notify.sh: run it as a subprocess with mocked external
# commands (ps, tmux, osascript, terminal-notifier) and assert on behavior.
#
# Design under test (docs/notification-targeting.md): notify only when the
# firing session maps to a live iTerm2 tab; target it as tty:<tab-tty>. A tmux
# session with no attached client is skipped. Click focuses the tab.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

NOTIFY="$REPO_ROOT/notify.sh"

# Every test mocks tmux so the suite never touches a real tmux server.
# A direct-terminal test uses a tmux mock that reports no matching pane.

# ── Click-to-focus: tty target ─────────────────────────────────────
test_case "--focus tty: selects the iTerm2 tab with that tty"
setup
mock osascript 'echo yes'
run_notify bash "$NOTIFY" --focus 'tty:/dev/ttys5' </dev/null
assert_eq 1 "$(mock_calls osascript)" "osascript called once"
assert_contains "$(mock_stdin osascript)" 'tty of s is "/dev/ttys5"' "selects the right tty"
teardown

test_case "--focus with a non-tty target is a no-op"
setup
mock osascript 'echo yes'
run_notify bash "$NOTIFY" --focus 'tmux:whatever' </dev/null
assert_eq 0 "$(mock_calls osascript)" "no focus attempted for a non-tty target"
teardown

# ── Stop from a direct iTerm2 tab ──────────────────────────────────
test_case "stop in a direct iTerm2 tab targets tty:<raw_tty>"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'   # no pane matches -> direct path
mock osascript 'case "$* $__stdin" in
  *"is running"*) echo true ;;
  *frontmost*) echo Finder ;;
  *"name of s"*) echo myterm ;;
  *) echo "" ;;
esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/proj","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_eq 1 "$(mock_calls terminal-notifier)" "notification sent"
assert_contains "$tn" "proj" "title is the project basename"
assert_contains "$tn" "--focus 'tty:/dev/ttys9'" "callback targets the tty"
assert_contains "$tn" "myterm" "subtitle is the iTerm2 session name"
teardown

# ── Stop from a tmux session attached to a tab ─────────────────────
test_case "stop in an attached tmux session targets the client tty"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tomc-sess\tthe task title\n" ;;
  list-clients) printf "/dev/ttys8\tomc-sess\n" ;;
esac'
mock osascript 'echo Finder'   # not watching
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/proj","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_eq 1 "$(mock_calls terminal-notifier)" "notification sent"
assert_contains "$tn" "--focus 'tty:/dev/ttys8'" "targets the attached client tty"
assert_contains "$tn" "the task title" "subtitle is the tmux pane title"
assert_contains "$tn" "claude-omc-sess" "groups by the durable session name"
teardown

# ── Stop from a tmux session with NO attached tab -> skipped ───────
test_case "permission from a tab-less tmux session still notifies (no click target)"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tomc-worker\twork\n" ;;
  list-clients) : ;;          # no client attached to any session
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" permission <<<'{"cwd":"/x/proj","message":"allow?"}'
tn="$(mock_args terminal-notifier)"
assert_eq 1 "$(mock_calls terminal-notifier)" "tab-less worker's permission prompt still notifies"
assert_contains "$tn" "-activate com.googlecode.iterm2" "no tab to click into, so raise iTerm generically"
assert_not_contains "$tn" "--focus" "no click callback without a tab"
teardown

test_case "question from a tab-less tmux session still notifies"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tomc-worker\twork\n" ;;
  list-clients) : ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" question <<<'{"cwd":"/x/proj","message":"which option?"}'
assert_eq 1 "$(mock_calls terminal-notifier)" "tab-less worker's question still notifies"
teardown

test_case "stop in a tab-less tmux session does not notify"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tomc-worker\twork\n" ;;
  list-clients) : ;;          # no client attached to any session
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/proj","stop_hook_active":false}'
assert_eq 0 "$(mock_calls terminal-notifier)" "tab-less session is not notified"
teardown

# ── tmux session name with spaces survives (subtitle/group) ────────
test_case "tmux session/title with spaces are handled"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tmy session\tsome title here\n" ;;
  list-clients) printf "/dev/ttys8\tmy session\n" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_contains "$tn" "--focus 'tty:/dev/ttys8'" "targets the client tty"
assert_contains "$tn" "some title here" "pane title with spaces preserved in subtitle"
teardown

# ── No controlling tty -> notify with -activate fallback ───────────
test_case "no controlling tty falls back to -activate (still notifies)"
setup
mock ps 'case "$*" in *"-o tty="*) echo "??" ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_eq 1 "$(mock_calls terminal-notifier)" "still notifies"
assert_contains "$tn" "-activate com.googlecode.iterm2" "uses activate fallback"
assert_not_contains "$tn" "--focus" "no click callback without a tab"
teardown

# ── get_tty walks past a tty-less level ────────────────────────────
test_case "get_tty walks up past a ?? tty"
setup
mock ps 'case "$*" in
  *"-o tty="*) if [ -f "'"$SANDBOX"'/seen" ]; then echo ttys9; else touch "'"$SANDBOX"'/seen"; echo "??"; fi ;;
  *"-o ppid="*) echo 2 ;;
esac'
mock tmux 'true'
mock osascript 'case "$* $__stdin" in *"is running"*) echo true ;; *) echo Finder ;; esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/walk","stop_hook_active":false}'
assert_contains "$(mock_args terminal-notifier)" "--focus 'tty:/dev/ttys9'" "found tty after walking up"
teardown

# ── Debounce (keyed on the durable session name) ───────────────────
test_case "second stop within the window is debounced"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessD\tt\n" ;; list-clients) printf "/dev/ttys8\tsessD\n" ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 1 "$(mock_sends terminal-notifier)" "only the first of two rapid stops notifies"
teardown

test_case "production default debounce window is 20 minutes, past typical loop cadence"
setup
assert_contains "$(grep 'DEBOUNCE_SECONDS="\${NOTIFY_DEBOUNCE_SECONDS:-' "$NOTIFY")" "1200" \
  "default outlives the ~3-8 min cycles observed from ralph/autopilot/standup-autopilot loops"
teardown

test_case "debounce expires after the window"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessE\tt\n" ;; list-clients) printf "/dev/ttys8\tsessE\n" ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
NOTIFY_DEBOUNCE_SECONDS=1 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
sleep 3
NOTIFY_DEBOUNCE_SECONDS=1 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 2 "$(mock_sends terminal-notifier)" "both stops notify once the window elapses"
teardown

# ── Permission/question are never debounced ────────────────────────
test_case "two rapid permission prompts both notify"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessP\tt\n" ;; list-clients) printf "/dev/ttys8\tsessP\n" ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" permission <<<'{"cwd":"/x/p","message":"allow?"}'
run_notify bash "$NOTIFY" permission <<<'{"cwd":"/x/p","message":"allow?"}'
assert_eq 2 "$(mock_sends terminal-notifier)" "both permission prompts notify"
teardown

test_case "question hook builds a Question title with the message"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" question <<<'{"cwd":"/x/proj","message":"which option?"}'
tn="$(mock_args terminal-notifier)"
assert_contains "$tn" "proj — Question" "title marks a question"
assert_contains "$tn" "which option?" "message is the question text"
teardown

test_case "oversized permission message is clamped"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
big=$(printf 'x%.0s' $(seq 1 500))
run_notify bash "$NOTIFY" permission <<<"{\"cwd\":\"/x/p\",\"message\":\"$big\"}"
longest=$(mock_args terminal-notifier | tr ' ' '\n' | awk '{ if (length>m) m=length } END { print m }')
if [ "$longest" -le 220 ]; then pass "message clamped (longest token ${longest}b)"; else fail "not clamped (${longest}b)"; fi
teardown

# ── Watching-suppression: direct and tmux ──────────────────────────
test_case "no notification when iTerm2 is frontmost on the firing tab (direct)"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'case "$* $__stdin" in
  *"is running"*) echo true ;;
  *frontmost*) echo iTerm2 ;;
  *"current session of current window"*) echo /dev/ttys9 ;;
  *) echo myterm ;;
esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 0 "$(mock_calls terminal-notifier)" "watched direct tab is not notified"
assert_contains "$(mock_args osascript)" "frontmost" "reached the watching check"
teardown

test_case "no notification when watching the attached tmux tab"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessW\tt\n" ;; list-clients) printf "/dev/ttys8\tsessW\n" ;; esac'
mock osascript 'case "$* $__stdin" in
  *"is running"*) echo true ;;
  *frontmost*) echo iTerm2 ;;
  *"current session of current window"*) echo /dev/ttys8 ;;
  *) echo "" ;;
esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 0 "$(mock_calls terminal-notifier)" "watched tmux tab is not notified"
teardown

test_case "NOTIFY_ALWAYS=1 notifies even when watching"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'case "$* $__stdin" in
  *"is running"*) echo true ;;
  *frontmost*) echo iTerm2 ;;
  *"current session of current window"*) echo /dev/ttys9 ;;
  *) echo myterm ;;
esac'
mock terminal-notifier 'true'
NOTIFY_ALWAYS=1 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 1 "$(mock_calls terminal-notifier)" "override forces a notification"
teardown

# ── Empty payload degrades to 'unknown' ────────────────────────────
test_case "empty payload yields the 'unknown' project, still notifies"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop </dev/null
assert_contains "$(mock_args terminal-notifier)" "unknown" "falls back to 'unknown' project"
teardown

# ── tmux server failure must not abort the hook ────────────────────
test_case "stop does not abort when tmux commands fail (no server)"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'exit 1'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
if run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'; then
  pass "hook exits 0 despite tmux failures"
else
  fail "hook aborted (rc=$?) on tmux failure"
fi
teardown

# ── Event log: every decision leaves one reviewable TSV line ───────
# Fields: ts, event, outcome, project, session, target, detail.
test_case "delivered stop appends a 'notified' event line"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tomc-sess\tthe task title\n" ;;
  list-clients) printf "/dev/ttys8\tomc-sess\n" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/proj","stop_hook_active":false}'
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" \
  $'\tstop\tnotified\tproj\tomc-sess\ttty:/dev/ttys8\tthe task title' \
  "logs event, outcome, project, session, target, subtitle"
teardown

test_case "tab-less skip is logged as skip_no_tab with the session name"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tomc-worker\twork\n" ;;
  list-clients) : ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/proj","stop_hook_active":false}'
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" \
  $'\tstop\tskip_no_tab\tproj\tomc-worker\t-\twork' \
  "suppressed worker session is recorded, not lost"
teardown

test_case "debounced stop is logged as debounced"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessD\tt\n" ;; list-clients) printf "/dev/ttys8\tsessD\n" ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
elog="$(cat "$SANDBOX/events.tsv" 2>/dev/null)"
assert_contains "$elog" $'\tstop\tnotified\tp\tsessD' "first stop logged as notified"
assert_contains "$elog" $'\tstop\tdebounced\tp\tsessD' "second stop logged as debounced"
teardown

test_case "watching suppression is logged as skip_watching"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'case "$* $__stdin" in
  *"is running"*) echo true ;;
  *frontmost*) echo iTerm2 ;;
  *"current session of current window"*) echo /dev/ttys9 ;;
  *) echo myterm ;;
esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" \
  $'\tstop\tskip_watching\tp\t/dev/ttys9' "watched-tab suppression is recorded"
teardown

test_case "notification click is logged from the --focus callback"
setup
mock osascript 'echo yes'
run_notify bash "$NOTIFY" --focus 'tty:/dev/ttys5' </dev/null
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" \
  $'\tclick\tyes\t-\t-\ttty:/dev/ttys5\t-' "click and focus result recorded"
teardown

test_case "NOTIFY_EVENT_LOG=0 disables event logging"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessL\tt\n" ;; list-clients) printf "/dev/ttys8\tsessL\n" ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
NOTIFY_EVENT_LOG=0 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 1 "$(mock_calls terminal-notifier)" "still notifies with logging off"
if [ ! -e "$SANDBOX/events.tsv" ] && [ ! -e "0" ]; then
  pass "no event log written"
else
  fail "event log written despite NOTIFY_EVENT_LOG=0"
fi
teardown

test_case "unwritable event log never breaks the hook"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessU\tt\n" ;; list-clients) printf "/dev/ttys8\tsessU\n" ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
mkdir -p "$SANDBOX/ro" && chmod 500 "$SANDBOX/ro"
if NOTIFY_EVENT_LOG="$SANDBOX/ro/sub/events.tsv" \
   run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'; then
  pass "hook exits 0 despite unwritable log path"
else
  fail "hook aborted (rc=$?) on unwritable log path"
fi
assert_eq 1 "$(mock_calls terminal-notifier)" "notification still sent"
chmod 700 "$SANDBOX/ro"
teardown

test_case "oversized event log rotates to .old"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessR\tt\n" ;; list-clients) printf "/dev/ttys8\tsessR\n" ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
dd if=/dev/zero of="$SANDBOX/events.tsv" bs=1024 count=600 2>/dev/null
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
if [ -f "$SANDBOX/events.tsv.old" ]; then pass "old log rotated aside"; else fail "no .old rotation"; fi
assert_eq 1 "$(wc -l < "$SANDBOX/events.tsv" | tr -d ' ')" "fresh log holds just the new event"
teardown

# ── Stale-notification cleanup: retract what's no longer accurate ──
test_case "resuming activity clears the earlier notification even with no new one to show yet"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessR\tt\n" ;; list-clients) printf "/dev/ttys8\tsessR\n" ;; esac'
mock osascript 'case "$* $__stdin" in *frontmost*) echo Finder ;; *"name of s"*) echo "✳ idle" ;; *) echo "" ;; esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 1 "$(mock_calls terminal-notifier)" "first stop delivers"
mock osascript 'case "$* $__stdin" in *"is running"*) echo true ;; *frontmost*) echo Finder ;; *) echo "" ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessR\t⠐ busy\n" ;; list-clients) printf "/dev/ttys8\tsessR\n" ;; esac'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_eq 2 "$(mock_calls terminal-notifier)" "resumed activity triggers a synchronous -remove, no second send yet"
assert_contains "$tn" "-remove claude-sessR" "the earlier notification is retracted by its group id"
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" $'\tretract\tyes\tp\tsessR' \
  "the retraction is logged as its own event, distinct from held/notified/debounced"
teardown

test_case "a session's first-ever event never attempts a removal (nothing was live)"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_not_contains "$(mock_args terminal-notifier)" "-remove" "nothing to retract on a session's first event"
assert_not_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" $'\tretract\t' "no retract event logged either"
teardown

test_case "a debounced repeat still clears the stale notification from the first"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsessB\tt\n" ;; list-clients) printf "/dev/ttys8\tsessB\n" ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_eq 2 "$(mock_calls terminal-notifier)" "first send + remove, second stayed debounced (no re-send)"
assert_contains "$tn" "-remove claude-sessB" "even a debounced repeat retracts the now-stale first notification"
teardown

test_case "a tab-less worker's suppressed stop still clears an earlier live notification"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tomc-worker\twork\n" ;; list-clients) printf "/dev/ttys8\tomc-worker\n" ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" permission <<<'{"cwd":"/x/p","message":"allow?"}'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tomc-worker\twork\n" ;; list-clients) : ;; esac'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_contains "$(mock_args terminal-notifier)" "-remove claude-omc-worker" "worker going tab-less still retracts its earlier permission ping"
teardown

# ── Worker sessions (claude --agent-id): stops off, asks on ────────
test_case "stop from an agent-team worker session is suppressed"
setup
mock ps 'case "$*" in
  *"-o tty="*) echo ttys9 ;;
  *"-o ppid="*) echo 1 ;;
  *"-o command="*) echo "claude --agent-id explore-1@session-2" ;;
esac'
mock tmux 'true'
mock osascript 'case "$* $__stdin" in *"is running"*) echo true ;; *frontmost*) echo Finder ;; *) echo myterm ;; esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/proj","stop_hook_active":false}'
assert_eq 0 "$(mock_calls terminal-notifier)" "worker stop not notified"
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" \
  $'\tstop\tskip_agent_worker\tproj' "suppression recorded in the event log"
teardown

test_case "permission prompt from a worker session still notifies"
setup
mock ps 'case "$*" in
  *"-o tty="*) echo ttys9 ;;
  *"-o ppid="*) echo 1 ;;
  *"-o command="*) echo "claude --agent-id explore-1@session-2" ;;
esac'
mock tmux 'true'
mock osascript 'case "$* $__stdin" in *"is running"*) echo true ;; *frontmost*) echo Finder ;; *) echo myterm ;; esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" permission <<<'{"cwd":"/x/proj","message":"allow?"}'
assert_eq 1 "$(mock_calls terminal-notifier)" "worker permission prompt delivered"
teardown

# ── Idle-gating: mid-work stops wait for the tab title to go idle ──
test_case "stop with a working-spinner title is held, then delivered on idle"
setup
printf '⠐ deep task (bun)' > "$SANDBOX/title"
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tsessG\t%s\n" "$(cat '"$SANDBOX"'/title)" ;;
  list-clients) printf "/dev/ttys8\tsessG\n" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 0 "$(mock_calls terminal-notifier)" "not delivered while the spinner shows"
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" $'\tstop\theld\tp\tsessG' "hold recorded"
printf '✳ deep task (bun)' > "$SANDBOX/title"
sleep 2.5
assert_eq 1 "$(mock_calls terminal-notifier)" "delivered once the title went idle"
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" $'\tstop\tnotified\tp\tsessG' "delivery recorded"
teardown

test_case "stop with an idle title delivers immediately (no hold)"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'case "$* $__stdin" in
  *"is running"*) echo true ;;
  *frontmost*) echo Finder ;;
  *"name of s"*) echo "✳ myterm" ;;
  *) echo "" ;;
esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 1 "$(mock_calls terminal-notifier)" "idle session notifies without delay"
assert_not_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" $'\theld\t' "no hold recorded"
teardown

test_case "only the newest of two held stops delivers"
setup
printf '⠂ busy (bun)' > "$SANDBOX/title"
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tsessS\t%s\n" "$(cat '"$SANDBOX"'/title)" ;;
  list-clients) printf "/dev/ttys8\tsessS\n" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
printf '✳ busy (bun)' > "$SANDBOX/title"
sleep 2.5
assert_eq 1 "$(mock_calls terminal-notifier)" "burst collapses to a single delivery"
teardown

test_case "a long-busy session gets a truthful heartbeat, then the real ping at idle"
setup
printf '⠐ forever (bun)' > "$SANDBOX/title"
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tsessC\t%s\n" "$(cat '"$SANDBOX"'/title)" ;;
  list-clients) printf "/dev/ttys8\tsessC\n" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
NOTIFY_HOLD_MAX_SECONDS=3 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
sleep 4.5
assert_eq 1 "$(mock_calls terminal-notifier)" "heartbeat delivered while still busy"
assert_contains "$(mock_args terminal-notifier)" "Still working" "heartbeat is truthful, not 'Ready for input'"
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" $'\tstop\theartbeat\tp\tsessC' "heartbeat outcome logged"
printf '✳ forever (bun)' > "$SANDBOX/title"
sleep 2
assert_eq 2 "$(mock_calls terminal-notifier)" "real notification still arrives at idle"
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" $'\tstop\tnotified\tp\tsessC' "idle delivery logged after the heartbeat"
teardown

test_case "a superseding stop does not reset the heartbeat clock"
setup
printf '⠐ churn (bun)' > "$SANDBOX/title"
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tsessH\t%s\n" "$(cat '"$SANDBOX"'/title)" ;;
  list-clients) printf "/dev/ttys8\tsessH\n" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
NOTIFY_HOLD_MAX_SECONDS=4 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
sleep 2
NOTIFY_HOLD_MAX_SECONDS=4 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
sleep 3.5
assert_eq 1 "$(mock_calls terminal-notifier)" "heartbeat fired on the original clock despite the newer stop"
assert_contains "$(mock_args terminal-notifier)" "Still working" "churning session pings truthfully, never starves"
teardown

test_case "NOTIFY_HOLD_MAX_SECONDS=0 disables idle-gating"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tsessO\t⠐ busy (bun)\n" ;;
  list-clients) printf "/dev/ttys8\tsessO\n" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
NOTIFY_HOLD_MAX_SECONDS=0 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 1 "$(mock_calls terminal-notifier)" "gating off notifies immediately"
assert_not_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" $'\theld\t' "no hold recorded"
teardown

test_case "delivery re-checks watching: no ping if you got there first"
setup
printf '⠐ busy (bun)' > "$SANDBOX/title"
printf 'Finder' > "$SANDBOX/front"
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'case "$* $__stdin" in
  *"is running"*) echo true ;;
  *frontmost*) cat '"$SANDBOX"'/front ;;
  *"current session of current window"*) echo /dev/ttys9 ;;
  *"name of s"*) cat '"$SANDBOX"'/title ;;
  *) echo "" ;;
esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" $'\theld\t' "held while working"
printf 'iTerm2' > "$SANDBOX/front"
printf '✳ busy (bun)' > "$SANDBOX/title"
sleep 2.5
assert_eq 0 "$(mock_calls terminal-notifier)" "watched tab not pinged at delivery time"
assert_contains "$(cat "$SANDBOX/events.tsv" 2>/dev/null)" $'\tskip_watching\t' "late suppression recorded"
teardown

# ── SessionStart title hook (opt-in) ────────────────────────────────
# sessionTitle's actual effect on the terminal is undocumented, so this
# doesn't depend on it at all: it sets the tmux pane title / iTerm2 session
# name directly via well-documented primitives, gated behind an explicit
# opt-in (this is the one place the script WRITES terminal/tmux state
# instead of just reading it, and there's no reliable way to tell "default
# title" from "user renamed this tab" apart).
test_case "title hook is a no-op unless NOTIFY_SET_TITLE=1"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" title <<<'{"cwd":"/x/myproj"}'
assert_not_contains "$(mock_args tmux)" "select-pane" "no tmux title set when opted out"
assert_not_contains "$(mock_args osascript)$(mock_stdin osascript)" "set name" "no iTerm2 title set when opted out"
assert_eq 0 "$(mock_calls terminal-notifier)" "title hook never fires a notification, opted in or not"
teardown

test_case "title hook sets the tmux pane title from the project name when opted in"
setup
mock tmux 'true'
export TMUX="/tmp/fake,0,0"
NOTIFY_SET_TITLE=1 run_notify bash "$NOTIFY" title <<<'{"cwd":"/x/myproj"}'
unset TMUX
assert_contains "$(mock_args tmux)" "select-pane -T myproj" "tmux pane title set to the project basename"
teardown

test_case "title hook sets the iTerm2 session name when opted in and not in tmux"
setup
unset TMUX 2>/dev/null || true
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock osascript 'case "$* $__stdin" in *"is running"*) echo true ;; *) echo "" ;; esac'
NOTIFY_SET_TITLE=1 run_notify bash "$NOTIFY" title <<<'{"cwd":"/x/myproj"}'
assert_contains "$(mock_stdin osascript)" 'set name of s to "myproj"' "iTerm2 session name set to the project basename"
teardown

test_case "title hook escapes embedded double quotes for AppleScript"
setup
unset TMUX 2>/dev/null || true
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock osascript 'case "$* $__stdin" in *"is running"*) echo true ;; *) echo "" ;; esac'
NOTIFY_SET_TITLE=1 run_notify bash "$NOTIFY" title <<<'{"cwd":"/x/we\"ird"}'
assert_contains "$(mock_stdin osascript)" 'set name of s to "we\"ird"' "embedded quote is escaped, not breaking the AppleScript string"
teardown

test_case "title hook does nothing if iTerm2 isn't running (never launches it)"
setup
unset TMUX 2>/dev/null || true
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock osascript 'echo false'
mock terminal-notifier 'true'
NOTIFY_SET_TITLE=1 run_notify bash "$NOTIFY" title <<<'{"cwd":"/x/myproj"}'
assert_not_contains "$(mock_stdin osascript)" "set name" "no attempt to set a name when iTerm2 isn't running"
assert_eq 0 "$(mock_calls terminal-notifier)" "still no notification fired"
teardown

# ── --report: summarize the event log ──────────────────────────────
test_case "--report summarizes outcomes, types, and clicks"
setup
now=$(date +%Y-%m-%dT%H:%M:%S)
{
  printf '%s\tstop\tnotified\tprojA\tsess1\ttty:/dev/ttys1\tt\n' "$now"
  printf '%s\tstop\tnotified\tprojA\tsess1\ttty:/dev/ttys1\tt\n' "$now"
  printf '%s\tpermission\tnotified\tprojB\tsess2\ttty:/dev/ttys2\tallow?\n' "$now"
  printf '%s\tstop\tskip_no_tab\tprojB\tworker1\t-\tw\n' "$now"
  printf '%s\tclick\tyes\t-\t-\ttty:/dev/ttys1\t-\n' "$now"
  printf '%s\tretract\tyes\tprojA\tsess1\tclaude-sess1\tt\n' "$now"
  printf '%s\tretract\tyes\tprojA\tsess1\tclaude-sess1\tt\n' "$now"
} > "$SANDBOX/events.tsv"
out=$(run_notify bash "$NOTIFY" --report </dev/null)
assert_contains "$out" "delivered 3" "counts delivered notifications"
assert_contains "$out" "2 stop" "delivered-by-type: stop"
assert_contains "$out" "1 permission" "delivered-by-type: permission"
assert_contains "$out" "1 skip_no_tab" "suppressed outcomes included"
assert_contains "$out" "Click-through: 1 of 3" "click-through rate"
assert_contains "$out" "Bursts: 2" "counts rapid-fire delivered notifications"
assert_contains "$out" "Retracted: 2" "counts stale notifications cleared before they were seen"
assert_not_contains "$(echo "$out" | sed -n '/^Outcomes:/,/^$/p')" "yes" \
  "retract's 'yes' outcome doesn't pollute the generic Outcomes tally (same treatment as click)"
teardown

test_case "--report without a log explains itself"
setup
out=$(run_notify bash "$NOTIFY" --report </dev/null)
assert_contains "$out" "No event log" "empty state is explained, not an error"
teardown

# ── terminal-notifier chatter must not leak to stdout ──────────────
test_case "terminal-notifier output is not surfaced as hook output"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'true'
mock osascript 'echo Finder'
mock terminal-notifier 'echo "* Removing previously sent notification, sent on: now"'
out=$(run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}')
assert_eq "" "$out" "no stray stdout/stderr from terminal-notifier"
teardown

finish

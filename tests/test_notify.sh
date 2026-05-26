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
assert_eq 1 "$(mock_calls terminal-notifier)" "only the first of two rapid stops notifies"
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
assert_eq 2 "$(mock_calls terminal-notifier)" "both stops notify once the window elapses"
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
assert_eq 2 "$(mock_calls terminal-notifier)" "both permission prompts notify"
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

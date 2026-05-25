#!/bin/bash
# Black-box tests for notify.sh: run it as a subprocess with mocked external
# commands (ps, tmux, osascript, terminal-notifier) and assert on behavior.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

NOTIFY="$REPO_ROOT/notify.sh"

# ── Click-to-focus: direct tty ─────────────────────────────────────
test_case "--focus tty: runs AppleScript to select that tty"
setup
mock osascript 'echo yes'
run_notify bash "$NOTIFY" --focus 'tty:/dev/ttys5' </dev/null
assert_eq 1 "$(mock_calls osascript)" "osascript called once"
assert_contains "$(mock_stdin osascript)" 'tty of s is "/dev/ttys5"' "selects the right tty"
teardown

# ── Click-to-focus: attached tmux session ──────────────────────────
test_case "--focus tmux: (attached) focuses the client's iTerm2 tty"
setup
mock tmux 'case "$1" in list-clients) echo "/dev/ttys8|sess1" ;; esac'
mock osascript 'echo yes'
run_notify bash "$NOTIFY" --focus 'tmux:sess1' </dev/null
assert_contains "$(mock_args tmux)" "list-clients" "queried tmux clients"
assert_contains "$(mock_stdin osascript)" 'tty of s is "/dev/ttys8"' "focuses resolved client tty"
teardown

# ── Click-to-focus: detached tmux session ──────────────────────────
test_case "--focus tmux: (detached, exists) attaches in a new tab"
setup
mock tmux 'case "$1" in list-clients) : ;; has-session) exit 0 ;; esac'
mock osascript 'true'
run_notify bash "$NOTIFY" --focus 'tmux:sess1' </dev/null
osa="$(mock_stdin osascript)"
assert_contains "$osa" "create tab" "opens a new tab"
assert_contains "$osa" "tmux attach-session -t 'sess1'" "attaches the detached session"
teardown

# ── Click-to-focus: tmux session no longer exists ──────────────────
test_case "--focus tmux: (gone) just activates iTerm2, no new tab"
setup
mock tmux 'case "$1" in list-clients) : ;; has-session) exit 1 ;; esac'
mock osascript 'true'
run_notify bash "$NOTIFY" --focus 'tmux:sess1' </dev/null
assert_contains "$(mock_args osascript)" "activate" "activates iTerm2"
assert_not_contains "$(mock_stdin osascript)" "create tab" "does not open a tab"
teardown

# ── Click-to-focus: empty target is a no-op ────────────────────────
test_case "--focus with empty target does nothing"
setup
mock osascript 'echo yes'
run_notify bash "$NOTIFY" --focus '' </dev/null
assert_eq 0 "$(mock_calls osascript)" "osascript not called"
teardown

# ── Stop notification from a tmux pane ─────────────────────────────
test_case "stop in a tmux pane builds a tmux: target with pane-title subtitle"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) echo "/dev/ttys9 omc-proj-main-001 the task title" ;;
  list-clients) echo "/dev/ttys8|omc-proj-main-001" ;;
esac'
mock osascript 'echo Finder'   # frontmost != iTerm2 -> not watching
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/myproj","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_eq 1 "$(mock_calls terminal-notifier)" "notification sent"
assert_contains "$tn" "myproj" "title is the project basename"
assert_contains "$tn" "the task title" "subtitle is the tmux pane title"
assert_contains "$tn" "--focus 'tmux:omc-proj-main-001'" "callback targets the tmux session"
teardown

# ── Stop notification from a direct (non-tmux) tty ─────────────────
test_case "stop in a direct iTerm2 tab builds a tty: target"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
# No tmux mock -> command -v tmux fails -> direct path.
mock osascript 'case "$* $__stdin" in *frontmost*) echo Finder ;; *) echo myterm ;; esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/proj2","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_contains "$tn" "--focus 'tty:/dev/ttys9'" "callback targets the tty"
assert_contains "$tn" "myterm" "subtitle is the iTerm2 session name"
teardown

# ── Debounce suppresses rapid repeat stops ─────────────────────────
test_case "second stop within the window is debounced"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) echo "/dev/ttys9 sessX one" ;;
  list-clients) echo "/dev/ttys8|sessX" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 1 "$(mock_calls terminal-notifier)" "only the first of two rapid stops notifies"
teardown

# ── Permission notifications are never debounced ───────────────────
test_case "two rapid permission prompts both notify"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) echo "/dev/ttys9 sessY one" ;;
  list-clients) echo "/dev/ttys8|sessY" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" permission <<<'{"cwd":"/x/p","message":"allow?"}'
run_notify bash "$NOTIFY" permission <<<'{"cwd":"/x/p","message":"allow?"}'
assert_eq 2 "$(mock_calls terminal-notifier)" "both permission prompts notify"
teardown

# ── Suppress when the user is actively watching the session ────────
test_case "no notification when iTerm2 frontmost on the firing tab"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
# Direct path (no tmux mock). osascript: frontmost=iTerm2, current tty=ttys9.
mock osascript 'case "$* $__stdin" in
  *frontmost*) echo iTerm2 ;;
  *"current session of current window"*) echo /dev/ttys9 ;;
  *) echo myterm ;;
esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 0 "$(mock_calls terminal-notifier)" "watched session is not notified"
teardown

# ── NOTIFY_ALWAYS overrides the watching suppression ───────────────
test_case "NOTIFY_ALWAYS=1 notifies even when watching"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock osascript 'case "$* $__stdin" in
  *frontmost*) echo iTerm2 ;;
  *"current session of current window"*) echo /dev/ttys9 ;;
  *) echo myterm ;;
esac'
mock terminal-notifier 'true'
NOTIFY_ALWAYS=1 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 1 "$(mock_calls terminal-notifier)" "override forces a notification"
teardown

finish

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
mock tmux 'case "$1" in list-clients) printf "/dev/ttys8\tsess1\n" ;; esac'
mock osascript 'echo yes'
run_notify bash "$NOTIFY" --focus 'tmux:sess1' </dev/null
assert_contains "$(mock_args tmux)" "list-clients" "queried tmux clients"
assert_contains "$(mock_stdin osascript)" 'tty of s is "/dev/ttys8"' "focuses resolved client tty"
teardown

# ── Click-to-focus: detached session, reuse an existing tmux tab ────
test_case "--focus tmux: (detached) reuses an existing tmux client, no new tab"
setup
# No client for sess1 (detached), but another tmux client exists at ttys8.
# list-clients with -F '#{client_tty}\t#{session_name}' (resolve step) returns
# no match for sess1; list-clients with -F '#{client_tty}' (reuse step) lists ttys8.
mock tmux 'case "$1 ${2:-} ${3:-}" in
  "list-clients -F #{client_tty}") echo "/dev/ttys8" ;;
  "list-clients"*) : ;;                      # resolve step: no client for sess1
  "has-session"*) exit 0 ;;
  "switch-client"*) exit 0 ;;
esac'
mock osascript 'echo yes'
run_notify bash "$NOTIFY" --focus 'tmux:sess1' </dev/null
osa="$(mock_stdin osascript)"
assert_contains "$(mock_args tmux)" "switch-client" "switches an existing client to the session"
assert_contains "$osa" 'tty of s is "/dev/ttys8"' "focuses the reused client's tab"
assert_not_contains "$osa" "create tab" "does NOT open a new tab"
teardown

# ── Click-to-focus: detached, no tmux client to reuse -> new tab ────
test_case "--focus tmux: (detached, no client) falls back to a new tab"
setup
mock tmux 'case "$1" in list-clients) : ;; has-session) exit 0 ;; esac'
mock osascript 'true'
run_notify bash "$NOTIFY" --focus 'tmux:sess1' </dev/null
osa="$(mock_stdin osascript)"
assert_contains "$osa" "create tab" "opens a new tab when no client to reuse"
assert_contains "$osa" "/tmux attach-session -t 'sess1'" "attaches via an absolute tmux path"
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
  list-panes) printf "/dev/ttys9\tomc-proj-main-001\tthe task title\n" ;;
  list-clients) printf "/dev/ttys8\tomc-proj-main-001\n" ;;
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
mock osascript 'case "$* $__stdin" in *"is running"*) echo true ;; *frontmost*) echo Finder ;; *) echo myterm ;; esac'
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
  list-panes) printf "/dev/ttys9\tsessX\tone\n" ;;
  list-clients) printf "/dev/ttys8\tsessX\n" ;;
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
  list-panes) printf "/dev/ttys9\tsessY\tone\n" ;;
  list-clients) printf "/dev/ttys8\tsessY\n" ;;
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
# Positive check: confirm we actually reached the watching logic (not an
# earlier bail-out), so this can't pass for the wrong reason.
assert_contains "$(mock_args osascript)" "frontmost" "frontmost was queried"
teardown

# ── get_tty walks multiple ppid levels before finding a tty ────────
test_case "get_tty skips ?? ttys and walks up to the first real tty"
setup
# First tty query returns "??" (no tty); the next level up returns a real tty.
# notify.sh's own $$ is unknowable here, so toggle on a marker file instead.
mock ps 'case "$*" in
  *"-o tty="*) if [ -f "'"$SANDBOX"'/seen" ]; then echo ttys9; else touch "'"$SANDBOX"'/seen"; echo "??"; fi ;;
  *"-o ppid="*) echo 2 ;;
esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tsx\tt\n" ;;
  list-clients) printf "/dev/ttys8\tsx\n" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/walk","stop_hook_active":false}'
assert_contains "$(mock_args terminal-notifier)" "--focus 'tmux:sx'" "found tty after walking up one level"
teardown

# ── No tty found anywhere -> -activate fallback ────────────────────
test_case "no controlling tty falls back to -activate iTerm2"
setup
mock ps 'case "$*" in *"-o tty="*) echo "??" ;; *"-o ppid="*) echo 1 ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_contains "$tn" "-activate com.googlecode.iterm2" "uses activate fallback"
assert_not_contains "$tn" "--focus" "no click callback without a target"
teardown

# ── Debounce window expiry: second stop after the window notifies ──
test_case "stop after the debounce window notifies again"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in list-panes) printf "/dev/ttys9\tsz\tt\n" ;; list-clients) printf "/dev/ttys8\tsz\n" ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
NOTIFY_DEBOUNCE_SECONDS=1 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
sleep 3
NOTIFY_DEBOUNCE_SECONDS=1 run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 2 "$(mock_calls terminal-notifier)" "both stops notify once window elapses"
teardown

# ── Detached tmux session still notifies (notification flow) ───────
test_case "stop on a detached tmux session notifies with a tmux: callback"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
# Pane exists, but no client is attached (detached background session).
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tomc-bg-001\tworking\n" ;;
  list-clients) : ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/bg","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_eq 1 "$(mock_calls terminal-notifier)" "detached session still notifies"
assert_contains "$tn" "--focus 'tmux:omc-bg-001'" "callback carries the session handle"
assert_not_contains "$tn" "-activate" "uses the tmux callback, not bare activate"
teardown

# ── A watched session suppresses even a question prompt ────────────
test_case "question on the watched tab is suppressed"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock osascript 'case "$* $__stdin" in
  *frontmost*) echo iTerm2 ;;
  *"current session of current window"*) echo /dev/ttys9 ;;
  *) echo myterm ;;
esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" question <<<'{"cwd":"/x/p","message":"which?"}'
assert_eq 0 "$(mock_calls terminal-notifier)" "watched question is suppressed"
teardown

# ── Apostrophe in session name round-trips through the callback ────
test_case "session name with an apostrophe is shell-escaped in the callback"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tbobs\x27 sess\ttitle\n" ;;
  list-clients) printf "/dev/ttys8\tbobs\x27 sess\n" ;;
esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
# sq_escape turns tmux:bobs' sess into a safely single-quotable form.
assert_contains "$(mock_args terminal-notifier)" "--focus 'tmux:bobs'\\''" "apostrophe is shell-escaped"
teardown

# ── tmux session name with spaces survives parsing ─────────────────
test_case "session name with spaces is parsed correctly"
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
assert_contains "$tn" "--focus 'tmux:my session'" "session name with spaces preserved"
assert_contains "$tn" "some title here" "pane title with spaces preserved"
teardown

# ── question hook extracts the message ─────────────────────────────
test_case "question hook builds Question title with the message"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock osascript 'echo Finder'   # direct path, not watching
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" question <<<'{"cwd":"/x/proj","message":"which option?"}'
tn="$(mock_args terminal-notifier)"
assert_contains "$tn" "proj — Question" "title marks a question"
assert_contains "$tn" "which option?" "message is the question text"
teardown

# ── Empty/malformed payload degrades to 'unknown', no crash ────────
test_case "empty payload yields the 'unknown' project, still notifies"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop </dev/null
tn="$(mock_args terminal-notifier)"
assert_contains "$tn" "unknown" "falls back to 'unknown' project"
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

# ── Watching suppression on the tmux path (most common OMC topology) ─
test_case "stop on a watched tmux session is suppressed"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
# Pane ttys9 belongs to session sW, attached at client ttys8.
mock tmux 'case "$1" in
  list-panes) printf "/dev/ttys9\tsW\twork\n" ;;
  list-clients) printf "/dev/ttys8\tsW\n" ;;
esac'
# iTerm2 frontmost AND its current tab is the client tty ttys8 -> watching.
mock osascript 'case "$* $__stdin" in
  *"is running"*) echo true ;;
  *frontmost*) echo iTerm2 ;;
  *"current session of current window"*) echo /dev/ttys8 ;;
  *) echo "" ;;
esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
assert_eq 0 "$(mock_calls terminal-notifier)" "watched tmux session is suppressed"
teardown

# ── A huge/non-string message is clamped, not dumped raw ───────────
test_case "oversized permission message is clamped to 200 chars"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
big=$(printf 'x%.0s' $(seq 1 500))
run_notify bash "$NOTIFY" permission <<<"{\"cwd\":\"/x/p\",\"message\":\"$big\"}"
# The -message arg must not contain the full 500-char blob.
longest=$(mock_args terminal-notifier | tr ' ' '\n' | awk '{ if (length > m) m = length } END { print m }')
if [ "$longest" -le 220 ]; then pass "message clamped (longest token ${longest}b)"; else fail "message not clamped (${longest}b)"; fi
teardown

# ── Don't launch iTerm2 when it isn't running ──────────────────────
test_case "direct path skips the iTerm2 query when iTerm2 isn't running"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
# is running -> false; if the name lookup were attempted it would echo a
# sentinel. The guard must prevent that osascript from ever running.
mock osascript 'case "$* $__stdin" in
  *"is running"*) echo false ;;
  *frontmost*) echo Finder ;;
  *"name of s"*) echo LAUNCHED_ITERM ;;
  *) echo "" ;;
esac'
mock terminal-notifier 'true'
run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'
tn="$(mock_args terminal-notifier)"
assert_eq 1 "$(mock_calls terminal-notifier)" "still notifies (no subtitle)"
assert_not_contains "$tn" "LAUNCHED_ITERM" "iTerm2 session query was NOT issued"
assert_contains "$tn" "--focus 'tty:/dev/ttys9'" "still targets the tty"
teardown

# ── tmux server failure must not abort the hook (set -e + pipefail) ─
test_case "stop does not abort when tmux commands fail (no server)"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
# tmux exists but every subcommand fails (server down) -> exit 1, no output.
mock tmux 'exit 1'
mock osascript 'echo Finder'
mock terminal-notifier 'true'
if run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}'; then
  pass "hook exits 0 despite tmux failures"
else
  fail "hook aborted (rc=$?) on tmux failure"
fi
teardown

test_case "--focus tmux: does not abort when tmux server is down"
setup
mock tmux 'exit 1'
mock osascript 'true'
if run_notify bash "$NOTIFY" --focus 'tmux:gone' </dev/null; then
  pass "--focus exits 0 despite tmux failure"
else
  fail "--focus aborted (rc=$?) on tmux failure"
fi
teardown

# ── terminal-notifier chatter must not leak to stdout ──────────────
test_case "terminal-notifier output is not surfaced as hook output"
setup
mock ps 'case "$*" in *"-o tty="*) echo ttys9 ;; *"-o ppid="*) echo 1 ;; esac'
mock osascript 'echo Finder'   # direct path, not watching
mock terminal-notifier 'echo "* Removing previously sent notification, which was sent on: now"'
out=$(run_notify bash "$NOTIFY" stop <<<'{"cwd":"/x/p","stop_hook_active":false}')
assert_eq "" "$out" "no stray stdout/stderr from terminal-notifier"
teardown

finish

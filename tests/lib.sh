# Shared test helpers for claude-iterm-notify. Source this from test files.
# Dependency-free: pure bash + coreutils. No bats required.

TESTS_PASS=0
TESTS_FAIL=0
CURRENT_TEST=""

# Root of the repo (parent of tests/).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Per-test scratch space, recreated for each `setup`.
SANDBOX=""
MOCKBIN=""
CALLS=""  # directory where mocks record their invocations

setup() {
  SANDBOX="$(mktemp -d)"
  MOCKBIN="$SANDBOX/bin"
  CALLS="$SANDBOX/calls"
  mkdir -p "$MOCKBIN" "$CALLS"
}

teardown() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=""; MOCKBIN=""; CALLS=""
}

# Register a mock command. Usage: mock <name> <body>
# Each invocation records its args (one line) to "$CALLS/<name>.args" and its
# stdin to "$CALLS/<name>.stdin". The body then runs with "$@" = passed args.
# NOTE: the mock consumes stdin, so tests must give notify.sh finite stdin
# (a piped payload or </dev/null) to avoid blocking.
mock() {
  local name="$1" body="$2"
  cat > "$MOCKBIN/$name" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS/$name.args"
__stdin="\$(cat 2>/dev/null || true)"
printf '%s' "\$__stdin" >> "$CALLS/$name.stdin"
# Body may branch on "\$@"/"\$*" (args) and "\$__stdin" (captured stdin).
$body
EOF
  chmod +x "$MOCKBIN/$name"
}

# How many times was a mock called?
mock_calls() {
  local name="$1"
  [ -f "$CALLS/$name.args" ] && wc -l < "$CALLS/$name.args" | tr -d ' ' || echo 0
}

# Full recorded args (all invocations, one per line).
mock_args() {
  local name="$1"
  [ -f "$CALLS/$name.args" ] && cat "$CALLS/$name.args" || true
}

# Full recorded stdin (concatenation of all invocations).
mock_stdin() {
  local name="$1"
  [ -f "$CALLS/$name.stdin" ] && cat "$CALLS/$name.stdin" || true
}

# Run notify.sh as a subprocess with mocks on PATH and test env applied.
# Extra env vars may be passed as VAR=val before the args, e.g.:
#   run_notify HOOK_PAYLOAD='{}' -- stop
run_notify() {
  NOTIFY_TEST=1 \
  NOTIFY_DEBOUNCE_DIR="$SANDBOX/debounce" \
  NOTIFY_DEBOUNCE_SECONDS="${NOTIFY_DEBOUNCE_SECONDS:-180}" \
  NOTIFY_ALWAYS="${NOTIFY_ALWAYS:-}" \
  NOTIFY_EVENT_LOG="${NOTIFY_EVENT_LOG:-$SANDBOX/events.tsv}" \
  NOTIFY_HOLD_POLL_SECONDS="${NOTIFY_HOLD_POLL_SECONDS:-1}" \
  NOTIFY_HOLD_MAX_SECONDS="${NOTIFY_HOLD_MAX_SECONDS:-5}" \
  PATH="$MOCKBIN:$PATH" \
  HOME="$SANDBOX/home" \
  "$@"
}

# ── assertions ────────────────────────────────────────────────────
assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" = "$actual" ]; then
    pass "$msg"
  else
    fail "$msg
      expected: [$expected]
      actual:   [$actual]"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) pass "$msg" ;;
    *) fail "$msg
      expected to contain: [$needle]
      in:                  [$haystack]" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) fail "$msg
      expected NOT to contain: [$needle]
      in:                      [$haystack]" ;;
    *) pass "$msg" ;;
  esac
}

pass() { TESTS_PASS=$((TESTS_PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "${1:-$CURRENT_TEST}"; }
fail() { TESTS_FAIL=$((TESTS_FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "${1:-$CURRENT_TEST}"; }

# Declare the current test (for nicer output).
test_case() { CURRENT_TEST="$1"; printf '\n• %s\n' "$1"; }

# Print summary and set exit status. Call at end of each test file.
finish() {
  printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$TESTS_PASS" "$TESTS_FAIL"
  [ "$TESTS_FAIL" -eq 0 ]
}

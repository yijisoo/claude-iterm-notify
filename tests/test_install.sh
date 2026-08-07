#!/bin/bash
# Tests for install.sh / uninstall.sh: verify the settings.json hook merge and
# removal logic. Runs against an isolated HOME so the real config is untouched.
# terminal-notifier/brew are mocked so install never touches the system.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

SETTINGS=""   # path to the sandbox settings.json

# Run install.sh against the sandbox HOME with brew/terminal-notifier mocked.
run_install() {
  mock terminal-notifier 'true'   # pretend it's already installed
  mock brew 'true'
  HOME="$SANDBOX/home" PATH="$MOCKBIN:$PATH" \
    bash "$REPO_ROOT/install.sh" >/dev/null 2>&1
}

run_uninstall() {
  mock brew 'true'
  # Pipe "n" so the terminal-notifier removal prompt answers No.
  HOME="$SANDBOX/home" PATH="$MOCKBIN:$PATH" \
    bash "$REPO_ROOT/uninstall.sh" >/dev/null 2>&1 <<<'n'
}

# Count how many command hooks in $SETTINGS contain a substring.
count_hook() {
  local needle="$1"
  /usr/bin/python3 - "$SETTINGS" "$needle" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
needle = sys.argv[2]
n = 0
for entries in s.get("hooks", {}).values():
    for entry in entries:
        for h in entry.get("hooks", []):
            if needle in h.get("command", ""):
                n += 1
print(n)
PY
}

prepare_home() {
  mkdir -p "$SANDBOX/home/.claude"
  SETTINGS="$SANDBOX/home/.claude/settings.json"
}

# ── install into a fresh config ────────────────────────────────────
test_case "install adds the three notify hooks to an empty settings.json"
setup; prepare_home
run_install
assert_eq 4 "$(count_hook 'notify.sh')" "Stop + permission + question + SessionStart hooks present"
teardown

# ── install is idempotent ──────────────────────────────────────────
test_case "running install twice does not duplicate hooks"
setup; prepare_home
run_install
run_install
assert_eq 4 "$(count_hook 'notify.sh')" "still exactly four notify hooks"
teardown

# ── install preserves unrelated hooks ──────────────────────────────
test_case "install preserves a pre-existing unrelated Stop hook"
setup; prepare_home
cat > "$SETTINGS" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "~/.claude/hooks/other.sh" } ] } ] } }
JSON
run_install
assert_eq 1 "$(count_hook 'other.sh')" "unrelated hook untouched"
assert_eq 4 "$(count_hook 'notify.sh')" "notify hooks added alongside"
teardown

# ── uninstall removes only this tool's hooks ───────────────────────
test_case "uninstall removes notify.sh hooks but keeps unrelated ones"
setup; prepare_home
run_install
# Add an unrelated hook that merely contains the substring 'notify.sh' in a
# different path — must NOT be removed (tightened match).
/usr/bin/python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["hooks"].setdefault("Stop", []).append(
    {"hooks": [{"type": "command", "command": "~/other/notify.sh run"}]}
)
json.dump(s, open(p, "w"), indent=2)
PY
run_uninstall
assert_eq 0 "$(count_hook '.claude/hooks/notify.sh')" "this tool's hooks removed"
assert_eq 1 "$(count_hook 'other/notify.sh')" "unrelated notify.sh kept (tightened match)"
teardown

# ── uninstall removes the collected event log ──────────────────────
test_case "uninstall removes the event-log state dir"
setup; prepare_home
run_install
mkdir -p "$SANDBOX/home/.local/state/claude-iterm-notify"
touch "$SANDBOX/home/.local/state/claude-iterm-notify/events.tsv"
run_uninstall
if [ ! -d "$SANDBOX/home/.local/state/claude-iterm-notify" ]; then
  pass "event-log state dir removed"
else
  fail "event-log state dir left behind"
fi
teardown

# ── uninstall is safe with no tty on stdin ─────────────────────────
test_case "uninstall completes when stdin is not a tty (piped)"
setup; prepare_home
run_install
mock brew 'true'
# Closed stdin (</dev/null) is the non-tty case the `|| true` guards against.
if HOME="$SANDBOX/home" PATH="$MOCKBIN:$PATH" bash "$REPO_ROOT/uninstall.sh" >/dev/null 2>&1 </dev/null; then
  pass "uninstall exited 0 with no tty"
else
  fail "uninstall aborted on non-tty stdin (exit $?)"
fi
assert_eq 0 "$(count_hook 'notify.sh')" "hooks still removed despite no tty"
teardown

# ── install must NOT clobber a settings.json with invalid JSON ─────
test_case "install aborts on invalid JSON and leaves the file untouched"
setup; prepare_home
printf '{ "permissions": { "allow": ["Bash"] }, }\n' > "$SETTINGS"   # trailing comma = invalid
before=$(cat "$SETTINGS")
if run_install; then
  fail "install should have exited non-zero on invalid JSON"
else
  pass "install exited non-zero on invalid JSON"
fi
assert_eq "$before" "$(cat "$SETTINGS")" "settings.json left untouched (no data loss)"
teardown

finish

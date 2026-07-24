# TODOs

## Adopt new Claude Code hook surfaces (added 2026-05-29)

### 1. `MessageDisplay` hook → richer "Ready for input" notifications — STILL BLOCKED, verified 2026-07-24

**What it is:** a hook event that fires as assistant message text is displayed; hooks can transform or hide the text.

**Why it's useful here:** today the `stop` notification body is a hardcoded `"Ready for input"` — no content. `MessageDisplay` is a place to capture the tail of Claude's last assistant message so the notification can show *what* Claude said, not just *that* it finished.

**2026-07-24 doc verification (claude-code-guide agent, against current https://code.claude.com/docs/en/hooks-guide):** the event is confirmed to exist (no matcher support — fires on every displayed message; 10s timeout) but the **input JSON schema and output contract remain undocumented** — no confirmation of what fields it receives, nor whether omitting output actually guarantees the displayed text is unchanged. This is exactly the risk the original design questions below flagged, and it's still open. Do not implement against assumed behavior: getting the read-only contract wrong risks altering what the user actually sees Claude say, a much worse failure mode than a wrong notification.

**Before attempting this again:** either (a) get schema confirmation directly from Anthropic (file feedback via `/feedback`), or (b) empirically verify in a **disposable** test session — not the user's live global `~/.claude/settings.json` — by registering a temporary hook that only logs stdin and returns zero output, then inspecting whether displayed text was affected. Do not register an experimental `MessageDisplay` hook in real global settings; a mistake there affects every Claude Code session system-wide, immediately.

**Original design questions (still apply once the contract is confirmed):**
- **Read-only contract.** Must return text unchanged if used only as a content side-channel. Add a test that displayed text is byte-identical with the hook installed.
- **Firing frequency + cost.** Fires on every displayed message, not just at stop — stash the latest message text (e.g. a per-session temp file keyed the same way as the debounce dir) and have `stop` read it, rather than notifying directly from this hook.
- **Privacy.** Message text would transit a temp file on disk. Truncate aggressively (match the 200-char clamp already used for permission/question), document it in the README, and gate behind an opt-out env (e.g. `NOTIFY_MESSAGE_PREVIEW=0`).
- **Fallback.** No stashed message (first turn, file reaped, opt-out) → fall back to `"Ready for input"`, never regress.

**Files when scoped:** `install.sh` (register `MessageDisplay` → `notify.sh capture`), `notify.sh` (new `capture` branch that writes the stash + read it in the `stop` branch), `tests/` (pass-through-unchanged test + preview-truncation test), `README.md`.

### 2. Better notification subtitles — DONE 2026-07-24

Shipped as an opt-in `SessionStart` → `notify.sh title` hook (`NOTIFY_SET_TITLE=1`). The crux design question — whether `sessionTitle` flows into the actual terminal/tmux title — turned out to be unconfirmable (2026-07-24 doc verification: undocumented past the field's existence), so the shipped version doesn't depend on it at all: it sets the tmux pane title (`tmux select-pane -T`) or iTerm2 session name (AppleScript `set name of session`) directly, via primitives already used elsewhere in this script. Resolved "don't clobber user titles" by making it opt-in only, rather than trying to heuristically detect a "default" title (no reliable way to do that across differing shell/tmux/iTerm2 configs) — once enabled it unconditionally resets the title on every `SessionStart`. See README § Tab Titles.

# TODOs

## Adopt new Claude Code hook surfaces (added 2026-05-29)

### 7. `SessionStart` now reports source `"fork"` — the marker item #6 was looking for (added 2026-08-03)

**What changed:** July 2026 Claude Code changed **`SessionStart` hooks to report source `"fork"`** when a session begins as a fork, instead of `"resume"`. Previously a forked session was indistinguishable at SessionStart from a resumed one.

**Why it matters here:** item #6 (the `/fork` background-session case) left an open question — *can suppression key on anything to tell a forked background session from the user's foreground session, given a fork may not carry `--agent-id` and thus slips past `is_agent_worker()`?* This `SessionStart source="fork"` field is a concrete answer: `notify.sh` can capture the forked-session state at SessionStart (e.g. record the session id as fork-originated) and consult it when a later `stop`/`Notification` fires, rather than relying only on process-ancestry `--agent-id` walking. Resolves the "what can we key on" half of #6; the suppress-vs-surface *policy* decision in #6 still stands (a forked background session's `stop` is almost certainly a suppress case).

**Before building:** verify in a **disposable** session (not the live global `~/.claude/settings.json`) that (a) `SessionStart` genuinely fires with `source: "fork"` for a `/fork`-created session and carries the session id, and (b) that id correlates with the session id on the later `stop`/`Notification` payloads so suppression can join them. Confirm the exact field name/values against the **primary** Claude Code hooks docs — surfaced via a secondary release summary.

**Files when scoped:** `notify.sh` (record fork-originated session ids at SessionStart; consult in the stop/Notification suppression path — coordinate with #6), `install.sh` (register a `SessionStart` matcher if not already present), `tests/` (forked-session stop → suppressed via the SessionStart marker; foreground unchanged), `README.md`. Sources: [Claude Code changelog](https://code.claude.com/docs/en/changelog), [Claude Code hooks guide](https://code.claude.com/docs/en/hooks-guide).

### 5. New `terminalSequence` hook-output field emits notifications/bells without a controlling terminal (added 2026-07-28)

**What changed:** A **`terminalSequence`** field was added to Claude Code hook JSON output (July 2026) so hooks can "emit desktop notifications, window titles, and bells **without a controlling terminal**." This tool's whole job is turning hook events into native notifications and updating the correct iTerm2/tmux tab, and today it shells out to `terminal-notifier` (plus AppleScript/tmux plumbing) from `notify.sh`.

**Why it matters here:** a hook-native path to emit desktop notifications / set the window title / ring the bell could (a) reduce or replace some of the `terminal-notifier` + AppleScript surface, and (b) matter specifically for **background/detached sessions with no controlling terminal** — exactly the tmux-attach/detach and background-worker cases this tool already special-cases. Worth a scoping pass: does `terminalSequence` reach the same Notification Center surface (with click-to-focus) this tool relies on, or is it terminal-escape-sequence only (title/bell) and therefore complementary rather than a replacement? Click-to-correct-tab is the tool's core value and likely still needs the current mapping logic.

**Before building:** verify the exact Claude Code version that introduced `terminalSequence`, its precise JSON schema, and what it can/can't do (Notification Center vs. terminal escape sequences; whether it carries click-through) against the **primary** Claude Code hooks docs — this surfaced via a secondary release summary. Do the payload check in a disposable session, not the live global `~/.claude/settings.json`.

**Files when scoped:** `notify.sh` (emit path), `install.sh` (if new hook-output wiring is needed), `tests/`, `README.md`. Sources: [Claude Code changelog](https://code.claude.com/docs/en/changelog), [Claude Code hooks guide](https://code.claude.com/docs/en/hooks-guide).

### 6. `/fork` creates a new *background session* (not a subagent) — check it isn't surfaced as foreground (added 2026-08-02)

**What changed:** Claude Code's `/fork` "now copies your conversation into a new background session (its own row in `claude agents`) while you keep working." This is a **forked full session**, distinct from the subagent/background-*agent* case already handled in item #4 (2.1.198) and from the depth-3 subagent-nesting note in item #3.

**Why it matters here:** the tool's worker suppression is `is_agent_worker()`, which walks process ancestry for a `--agent-id` marker. A forked *session* is not obviously a subagent and **may not carry `--agent-id`**, so it might slip past `is_agent_worker()` and fire `stop` / `Notification` events that surface as if they were the user's foreground session needing attention — the same failure mode item #4 flagged for background agents, but via a different mechanism the current suppression may not catch. The forked session runs in the background while the user keeps working in the original, so its completion/stop is almost certainly a **suppress** case (the user isn't looking at it), by analogy to worker-stop suppression.

**Before building:** verify in a **disposable** test session (not the live global `~/.claude/settings.json`) whether a `/fork`-created background session (a) fires `stop`/`Notification` hooks at all, and (b) whether its hook payload / process ancestry carries any `--agent-id` or background marker `is_agent_worker()` (or a new check) can key on. Confirm the exact `/fork` behavior and any session-role field against the primary Claude Code changelog/docs before building — surfaced via a secondary release summary.

**Files when scoped:** `notify.sh` (extend background/worker suppression to forked sessions if they aren't already caught), `tests/` (forked-session stop → suppressed; foreground unchanged), `README.md`. Sources: [Claude Code changelog](https://code.claude.com/docs/en/changelog), [Claude Code hooks guide](https://code.claude.com/docs/en/hooks-guide).

### 4. Background/subagent sessions now fire the `Notification` hook (2.1.198) — decide suppress-vs-surface (added 2026-07-27)

**What changed:** **Claude Code 2.1.198 (2026-07-01)** added background-agent notifications — "sessions that need input or finish now fire the `Notification` hook (`agent_needs_input` / `agent_completed`)." Subagents also now run in the background by default. So the `Notification` event this tool consumes can now originate from **background agent / worker sessions**, not only the user's foreground session.

**Why it matters here:** this tool deliberately suppresses worker sessions (`is_agent_worker()` walks process ancestry for `--agent-id`) so a nested/background worker's stop doesn't notify. A `Notification`-hook path that fires for `agent_needs_input`/`agent_completed` on background agents is a *new* event source that may bypass the stop-path suppression and start surfacing background-worker activity as if it were the foreground session needing attention. Needs an explicit decision:
- **`agent_completed`** on a background subagent → almost certainly suppress (matches existing worker-stop suppression intent).
- **`agent_needs_input`** on a background agent → genuinely ambiguous: a background agent blocked on input *is* an attention event, but it isn't the foreground session the user is looking at. Decide whether to surface (and how to label it so it's distinguishable) or suppress.

**Before building:** verify the exact `Notification` payload fields for these two events (whether the JSON carries `agent_id` / a background-vs-foreground marker the suppression check can key on) against the primary docs — do this in a disposable session, not the live global `~/.claude/settings.json`. Confirm whether the existing `Notification` matcher config already receives these or whether new matchers (`agent_needs_input`/`agent_completed`) must be registered. Sources: [Claude Code v2.1.198 release](https://github.com/anthropics/claude-code/releases/tag/v2.1.198), [Claude Code hooks guide](https://code.claude.com/docs/en/hooks-guide).

**Files when scoped:** `notify.sh` (Notification branch — extend worker/background suppression to the new event sources), `install.sh` (matcher registration if needed), `tests/` (background-agent event → suppressed; foreground unchanged), `README.md`.

### 3. `DirectoryAdded` hook (new in 2.1.219) — evaluated, low value for notifications (added 2026-07-25)

**What it is:** a hook event added in **Claude Code 2.1.219 (2026-07-24)** that "fires after `/add-dir` or the SDK `register_repo_root` control request registers a new working directory mid-session."

**Disposition:** **not adopting.** This tool notifies on *attention* events (stop / permission / question); a mid-session directory registration is neither an attention request nor a completion, so it has no notification use case. Recorded here so a future pass doesn't re-evaluate it. The one adjacent thing worth a glance: if a future feature ever wants the notification subtitle to reflect an added working directory, this is where that signal would come from — but that's speculative and not on the roadmap.

**Related 2.1.219 note (no change needed):** 2.1.219 also flips the subagent-nesting default back on (nested subagents spawn to **depth 3 by default**, was 1). This does **not** affect worker-stop suppression — `is_agent_worker()` walks the full process ancestry (`depth<25`) for `--agent-id`, so a depth-3 nested worker is still detected — and the mid-work "still working" gate keys on the iTerm2/tmux **spinner title**, not on subagent depth. No code change; noted so the depth-default change isn't mistaken for a regression. **Verify the `DirectoryAdded` firing conditions against the primary docs before building against it.** Sources: [Claude Code changelog — 2.1.219](https://code.claude.com/docs/en/changelog).

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

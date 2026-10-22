# Autopilot Queue — 2026-07-26

Produced by /standup. Consumed by /standup-autopilot.

## Project Context

- Test: `bash tests/run.sh`
- Lint: none configured
- E2E: none
- Dev server port: n/a (CLI/hook tool, no running service)

## Queue

| # | Item | Source | Priority | Effort | Status | Confidence | Notes |
|---|------|--------|----------|--------|--------|------------|-------|
| 1 | `--report` silently excludes heartbeats from delivered/click-through/burst counts | review:2026-07-25 | P4 | S | completed | high | Decide: relabel ("N actionable, M heartbeat FYI") or fold heartbeats into the existing totals. Pure decision + small code change in the `--report` branch of `notify.sh`, no external unknowns. Test-first, update README, install, commit. |
| 2 | Headless/scheduled sessions (`/schedule`-style, no tty) bypass debounce entirely | review:2026-07-25 | P4 | M | in-progress | normal | Idle-gating unavoidably can't apply (no title to poll), but debounce could: it's keyed on the same tty-derived DEBOUNCE_KEY, which is empty for these. Fix candidate: read `session_id` from the hook JSON payload (a documented common hook field) and use it as a debounce-key fallback when RAW_TTY is empty. **Verify `session_id` is actually present in practice first** (e.g. capture one real headless invocation's payload with NOTIFY_DEBUG, or confirm via docs) before building — do not assume. If it isn't present or reliable, this item closes as "not fixable," not shipped speculatively. |

Source values: `review:<date>` — these two items came from the 2026-07-25 log review, not from `TODOS.md` or a GitHub issue (issues are disabled on this fork). `/standup-autopilot` should treat completion as "done in this queue" only; there's no backlog file/issue to close out.

## Held Items

None.

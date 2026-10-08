# Recorded opencode 2.0.20 event logs

What a terminal-side spy plugin saw, in panes of a throwaway `tmux -S` server,
on opencode **2.0.20**, macOS arm64, 2026-10-01 to 2026-10-03, with `HOME`, the
four `XDG_*_HOME` directories and `TMPDIR` redirected. They are the measurements
behind `docs/airig/specs/2026-10-02-opencode-2-adapter-design.md` (§2) and the
comments on #150. The adapter contract says fixtures replay recorded turns, not
invented ones; these are the recordings.

Paths were scrubbed (`<scratch>`, `~`, `<user>`); nothing else was edited.

## Format

One JSON object per line. Every line has `ms` (since the plugin's `setup`),
`pane` (the tmux pane id) and `what`. The spy changed between runs, so the
other fields differ by file:

| file | spy | `what` values | the event payload |
|---|---|---|---|
| `fresh.jsonl`, `dead-provider.jsonl`, `tabs.jsonl` | v2 | `tui-setup`, `ev` | `data` holds the event's `details.data` — the payload, with `sessionID` (and `parentID` on a child's `session.created`) at its top level — as a **JSON string clipped at 420 characters**; a value ending in `…` is not valid JSON, and only the fields before the cut are whole (`sessionID` and `parentID` always are; a long `text` is not). `type`, `sid` (last 6 of the session id), `route` (`home` or `session:<last 6>`), `root` and `status` (`context.data.session.status(route)`, JSON-encoded) are separate fields and always whole |
| `late-terminal.jsonl` | v3 | `tui-setup`, `probe`, `ev`, `tick`, `tui-cleanup` | `probe` holds `route`, `status`, `permission.list` before and after `sync`, `family`; `gen` says which plugin instance (GEN-1 before the file was edited, GEN-2 after) |
| `late-terminal-subagent.jsonl` | v3 | the same | the dialog belongs to a child session; `permPerFamily` lists each family member's pending requests and `root()` |
| `family-timing.jsonl` | v4 | `tui-setup`, `ev`, `family`, `pending` | `family` rows probe `family(parent)` at the child's `session.created` and on a schedule after it; `pending` rows ask every family member for pending requests |

`sid`, `root`, `parent`, `child` and the ids inside `family` are the **last six
characters** of a session id. Full ids appear inside `ev` payloads.

## What each file holds

- **fresh.jsonl** — one terminal, one chat. In order: the first prompt typed
  on the home screen (`route` is already the new session at `session.created`);
  a long turn interrupted with Esc Esc (`session.step.failed` aborted,
  `session.execution.interrupted` reason `user`); a `general` subagent whose
  shell call opens a dialog (`session.created` with `parentID`, the child's
  `permission.asked`, two dialogs allowed, the child's `execution.succeeded`
  before the parent's); and a dialog answered Reject (`permission.replied`
  reply `reject`, `session.tool.failed`, `execution.interrupted` reason
  `shutdown`).
- **dead-provider.jsonl** — a provider on a closed port: `retry.scheduled`
  attempts 2…11 over about 87 s, then `step.failed` and `execution.failed`.
  Nothing after.
- **tabs.jsonl** — two chats in one terminal, a turn in each, then `alt+up`
  and `alt+down`. The switches emit **no** event: the file ends at the second
  chat's `session.viewed`.
- **late-terminal.jsonl** — pane `%0` opens a dialog; pane `%1` is started on
  the same chat afterwards (`-s <id>`). `%1`'s `probe` at `setup` shows
  `permission.list` empty before `sync` and holding the request after. Then the
  plugin file is edited: `tui-cleanup` from both GEN-1 instances, `tui-setup`
  from GEN-2 in the same pids, and ticks only from GEN-2.
- **late-terminal-subagent.jsonl** — as above, but the open dialog is a
  subagent's. `%1`'s probe: `family(parent)` is `[parent, child]`,
  `permission.list(parent)` is empty, `permission.list(child)` holds the
  request, `root(child)` is the parent.
- **family-timing.jsonl** — a subagent whose first act is a shell call. At its
  `session.created`, `family(parent)` does not list it and `root(child)` is the
  child; 250 ms later both are right. Its `permission.asked` comes 1.4 s in.
  Then Esc Esc at the open dialog: nothing happens.

## Not recorded

A retry that then succeeds (design §5, A2); compaction; a queued prompt; a
grandchild; a route that is a child session; Linux.

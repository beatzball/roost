# Probe 7.1 — what each harness's tool shell sets (the restore offer's markers)

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 7.1.
Spec: docs/airig/specs/2026-10-24-persistent-sessions-design.md §4.8, check 2c
("the agent markers").

**Question.** Which environment variables does a harness set in the shell its
own tool command runs in, that a person's plain shell does not have? Such a
variable lets `roost` skip the restore offer for an agent without waiting the
60 s no-answer bound.

## Method (run once, 2026-11-06, macOS)

- One throwaway tmux server (`-S` under a `mktemp -d /tmp/amx.XXXX`), started
  through `env -i` with only `HOME`, `PATH`, `TERM`, `LANG`, `USER`,
  `LOGNAME`, `SHELL`, `TMPDIR` and the redirected homes: `XDG_CONFIG_HOME`,
  `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME`, `CODEX_HOME`,
  `COPILOT_HOME`, `PI_CODING_AGENT_DIR` — every one under the temp directory,
  and `HOME` too. No real account, no real config, no credential reachable.
  Starting from `env -i` matters: the probe itself ran under another harness,
  and its own markers must not reach the harness under test, or they would
  read as that harness's.
- A probe script, outside the repository, writes the **names** of the
  environment (Python's `sorted(os.environ)`, never a value) and the results
  of `[ -t 0 ]` and `[ -t 1 ]`, then runs itself once more from a nested
  `sh -c` (the "nested shell" column) with one variable of its own,
  `ENVNAMES_NESTED`, which is left out below.
- The same script ran four ways:
  - **plain login shell**: `bash -l -c` in a new window of that server;
  - **new terminal**: typed into an interactive shell in a new window;
  - **the harness's tool command**: each harness was asked, in its
    non-interactive mode, to run the script with its shell tool, against a
    local model (each smoke test's rig, `tests/live/`): codex through
    `tests/live/codex-tool-proxy.py`, Copilot by BYOK
    (`COPILOT_PROVIDER_BASE_URL`, `COPILOT_OFFLINE=true`), pi through its
    `models.json`. Model `ornith-1.5:9b` on a local ollama.
  - **nested**: the script's own nested `sh -c`, inside each of the above.
- A name counts for a harness when it is in its tool shell **and** its nested
  shell, and in **neither** plain shell. Names the probe put on the harness's
  own command line (`COPILOT_MODEL`, `PI_OFFLINE`, `PI_SKIP_VERSION_CHECK`)
  are left out.

| harness | version | mode run | tool shell `[ -t 0 ]` / `[ -t 1 ]` |
|---|---|---|---|
| codex | codex-cli 0.166.0 | `codex exec` | no / no |
| GitHub Copilot CLI | 1.0.103 | `copilot -p --allow-all-tools --allow-all-paths` | no / no |
| pi | 1.5.0 | `pi -p` | no / no |
| opencode | 2.x | **not measured** | — |

opencode is **not measured**: opencode 2 runs one background service per user
and cannot be run beside the author's own, and no free model in an isolated
home was tried. It stays held off by checks 2b and 2d only (the plan allows
it).

The TUIs were not driven, so the pty case (a tool command given a real
terminal) was not seen in this run; the spec records it once for codex
(§4.8's table, 2026-10-25). The markers below are environment, which a pty
does not change.

## Result: names only

Set in the tool shell and in the nested shell, absent from both plain shells:

| harness | names |
|---|---|
| codex | `CODEX_THREAD_ID`, `CODEX_SESSION_ID`, `CODEX_TOOL_CALL_ID`, `CODEX_VERSION`, `CODEX_CI`, `CODEX_APPLY_PATCH_PRESERVE_LINE_ENDINGS`; also `GIT_PAGER`, `GH_PAGER`, `PAGER`, `NO_COLOR`, `LC_ALL`, `LC_CTYPE` |
| GitHub Copilot CLI | `COPILOT_CLI`, `COPILOT_AGENT_SESSION_ID`, `COPILOT_CLI_BINARY_VERSION`, `COPILOT_CLI_RESOLVED_DIST_DIR`; also `GIT_ASKPASS`, `SSH_ASKPASS`, `GCM_INTERACTIVE`, `GIT_TERMINAL_PROMPT`, `GIT_OPTIONAL_LOCKS`, `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_0..2`, `GIT_CONFIG_VALUE_0..2` |
| pi | `PI_CODING_AGENT`, `AI_AGENT`, `PI_SESSION_ID`, `PI_SESSION_FILE`, `PI_MODEL`, `PI_PROVIDER`, `PI_REASONING_LEVEL` |

`CODEX_THREAD_ID` is confirmed on codex-cli 0.166.0 (the spec saw it once on
an earlier version).

## Applied (the plan's table: set in tool and nested shell, absent from both plain shells → a marker)

Added to the marker list (Task 7.3) and to the page's table:

- codex: `CODEX_THREAD_ID` (already the spec's)
- GitHub Copilot CLI: `COPILOT_CLI`, `COPILOT_AGENT_SESSION_ID`
- pi: `PI_CODING_AGENT`, `AI_AGENT`

Not added, a judgement call: the generic names (`PAGER`, `GIT_PAGER`,
`GH_PAGER`, `NO_COLOR`, `LC_ALL`, `LC_CTYPE`, `GIT_ASKPASS`, `SSH_ASKPASS`,
`GIT_TERMINAL_PROMPT`, `GIT_OPTIONAL_LOCKS`, `GCM_INTERACTIVE`,
`GIT_CONFIG_*`). They were absent from this probe's plain shells only because
those started from `env -i`; a person's own shell profile sets any of them as
often as a harness does, and the spec's rule keeps such names out (it leaves
out the config homes and `TMUX` for the same reason). Version, model and
per-call names (`CODEX_VERSION`, `CODEX_TOOL_CALL_ID`, `PI_MODEL`, …) are not
added either: one stable name per harness is enough, and a second keeps the
list working if one is renamed. `AI_AGENT` is generic in its name but not in
its use: it says an agent runs the command, which is exactly what the check
asks, and no plain shell here had it.

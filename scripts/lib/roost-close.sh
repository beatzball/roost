# roost-close.sh — the per-harness facts `roost close` (#143) needs: which
# harness a pane is running, and the command that harness exits on.
#
# Sourced, not executed, `roost_close_*` prefix. Sourced INSIDE the `close`
# branch of bin/roost, never at the top, the way roost-jsonout.sh is: no other
# command pays for it, and `roost state` on an adapter's hot path least of all.
#
# Both functions SET a variable rather than printing, so the caller needs no
# `$(...)` fork to read the answer, and both are builtins only.

# roost_close_exit_command HARNESS -> ROOST_CLOSE_EXIT, the text typed into the
# harness's input box to ask it to leave its own way. Returns 1, with
# ROOST_CLOSE_EXIT empty, for a harness this table has no entry for: `close`
# refuses those by name rather than typing a guess into an agent. A guess that
# the harness does not know is not harmless — it is a PROMPT, and it starts a
# turn on whatever the model makes of the word.
#
# ONE TABLE, and the only one. Each value, with where it came from. MEASURED
# means typed into the real harness in a throwaway tmux 3.6 server with every
# home redirected, the way `close` types it (the text, 0.3 s, Enter), and timed
# from Enter to the pane closing:
#
#   claude    /exit   MEASURED on Claude Code 2.1.285 against a local fake API:
#                     gone 0.03 s after Enter at rest. Mid-reply it ALSO left at
#                     once, 0.03 s, with no dialog — the reply was abandoned.
#                     End to end, `roost close` on a badged pane: exit 0, 0.64 s
#   codex     /quit   MEASURED on codex-cli 0.157.1 with a local model: gone
#                     0.86 s after the first key at rest; mid-turn it left at
#                     once too, 0.55 s after Enter, with no dialog
#   opencode  /exit   MEASURED on opencode 1.18.30, at rest only: gone within
#                     0.5 s. Mid-turn not measured (no model configured)
#   copilot   /exit   NOT MEASURED: the GitHub Copilot CLI needs a signed-in
#                     account. Read from its own `copilot help commands` on
#                     1.0.83: "/exit  Exit the CLI"
#   pi        /quit   MEASURED on pi 0.81.1, at rest only: gone 0.60 s after the
#                     first key. Its docs/usage.md lists it. Mid-turn not measured
#
# The mid-turn rows are why `close` refuses a `working` pane: the two harnesses
# measured do not ask, they just go, and the turn is lost.
roost_close_exit_command() {
  ROOST_CLOSE_EXIT=""
  case "$1" in
    claude)   ROOST_CLOSE_EXIT=/exit ;;
    codex)    ROOST_CLOSE_EXIT=/quit ;;
    opencode) ROOST_CLOSE_EXIT=/exit ;;
    copilot)  ROOST_CLOSE_EXIT=/exit ;;
    pi)       ROOST_CLOSE_EXIT=/quit ;;
    *) return 1 ;;
  esac
}

# roost_close_harness OPTION COMMAND NAME -> ROOST_CLOSE_HARNESS, the harness a
# pane is running, or empty when nothing says.
#
#   OPTION   the pane's @roost-harness. When it is set it WINS, whatever the
#            other two say: it is written by the agent's own adapter at session
#            start (#141), which is the one party that knows. Until that lands,
#            nothing writes it and the two below are all there is.
#   COMMAND  #{pane_current_command}. A process NAME, so it is a hint and not a
#            fact — but for three harnesses it is a distinctive one. Claude Code
#            renames its process to its own version (measured: "2.1.283" on a
#            live pane), which no shell or tool is called.
#   NAME     the pane's @roost-name. Every adapter's sink call labels an
#            unnamed pane with its harness (ROOST_AGENT_NAME), so an agent
#            nobody named reads "codex", "pi" and so on. A name a human chose
#            ("my-reviewer") says nothing, and is used only when the process
#            did not answer.
#
# pi and copilot are Node programs, so their process may read "node"; that
# alone names neither, and a Node process under any other name is unknown —
# a dev server is a Node process too.
roost_close_harness() {
  ROOST_CLOSE_HARNESS=""
  if [ -n "$1" ]; then ROOST_CLOSE_HARNESS="$1"; return 0; fi
  case "$2" in
    claude|codex|opencode|copilot|pi) ROOST_CLOSE_HARNESS="$2"; return 0 ;;
    # Claude Code's own version string: digits, a dot, digits, a dot, digits.
    [0-9]*.[0-9]*.[0-9]*)
      case "$2" in *[!0-9.]*) ;; *) ROOST_CLOSE_HARNESS=claude; return 0 ;; esac ;;
  esac
  case "$3" in
    claude|codex|opencode|copilot|pi) ROOST_CLOSE_HARNESS="$3" ;;
  esac
  return 0
}

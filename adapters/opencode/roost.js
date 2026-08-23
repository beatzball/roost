// roost.js — report an opencode agent's state onto its tmux pane.
//
// Install by symlinking into opencode's plugin directory, so updating roost
// updates the plugin:
//
//   mkdir -p ~/.config/opencode/plugin
//   ln -s "$HOME/path/to/roost/adapters/opencode/roost.js" ~/.config/opencode/plugin/roost.js
//
// Fill in the path to your roost checkout; `roost doctor` prints this exact
// command with the real path for your copy.
// The plugin runs in opencode's own process, which is the process in the tmux
// pane, so `roost state` finds the right pane from $TMUX_PANE with nothing to
// pass around. (This does not hold for `opencode attach` against a detached
// `opencode serve` — the plugin would run in the server, not the pane.)
//
// Everything arrives through the single `event` hook. That is a deliberate
// choice against the type definitions: opencode declares a "permission.ask"
// hook, but registering it produces nothing when a permission dialog appears —
// the `permission.asked` EVENT is what actually fires.

// The state is derived from opencode's session status rather than from tool
// calls. `tool.execute.before` fires only when a tool runs, and only after the
// turn is underway, so a turn that answers without calling a tool would never
// show as working at all.
//
// Two consecutive retries mean error rather than one, because a single retry
// may be a blip that heals itself, and error fires a desktop notification.
//
// "Consecutive" means within one turn, not back-to-back events: a live run
// against a dead provider showed the real stream interleaves session.status
// busy with every retry — busy, retry, busy, retry, ... — because opencode
// re-announces busy before each retry attempt. busy is therefore not evidence
// of forward progress, and the counter must NOT reset on it, or the threshold
// becomes unreachable and error never fires (this happened; a pane against a
// dead provider sat at working forever). The counter resets only at turn
// boundaries (session.idle, session.error) and on permission events, which
// are genuine progress signals.
const RETRY_THRESHOLD = 2

// opencode's event bus is process-global, and a task/subagent turn does NOT
// run inside the pane's session: opencode creates a CHILD session for it, so
// the child's own busy/idle/error events arrive here interleaved with the
// parent's. A child going idle mid-turn is not the end of the pane's turn.
//
// Measured on opencode 1.18.20, a parent turn that called the task tool with
// the `general` subagent (tests/live/opencode-smoke.sh case 1b logs exactly
// this):
//
//   56331ms  child   session.created   (info.parentID = the parent session)
//   56423ms  child   session.status    busy
//   72396ms  child   session.idle       <- unfiltered, this stamped `done`
//   72430ms  parent  session.status    busy
//   77346ms  parent  session.idle       <- the real end of the turn
//
// So the pane read `done` for 34ms while the parent was still working, and
// the child's idle also zeroed the retry counter mid-turn. `done` is the badge
// that means "finished, go look", and the two `roost state` calls 34ms apart
// are separate processes that can land out of order, so the wrong one can be
// the last writer and the pane stays `done` for the rest of the turn.
//
// The guard is to ignore the child's LIFECYCLE rather than to track which
// sessions are still busy. A set of active sessions that fails to empty leaves
// the pane on `working` forever — the exact bug this adapter already shipped
// once. Ignoring a child's lifecycle cannot get stuck: the parent's own events
// are always mapped, and a child we somehow never learned about only degrades
// to the old behaviour.
//
// Only these three. A subagent asks for permission under its OWN sessionID —
// measured on 1.18.20, a subagent told to run bash under `"bash": "ask"`:
//
//   30540ms  child   session.created
//   47589ms  child   permission.asked   <- the human has to answer this
//   47622ms  child   session.idle
//
// and the pane must show `blocked` for it. Filtering that out would leave the
// fleet reading `working` while the agent sits waiting for a keypress, which
// is the "silently stuck" failure, not a cosmetic one.
const CHILD_MUTED = new Set(["session.status", "session.idle", "session.error"])

// Learn which sessions are children. Only session.created / session.updated
// carry a session in properties.info — message.updated's info is a MESSAGE,
// whose parentID is another message and would poison the set.
const learnChild = (event, children) => {
  const type = event?.type
  const info = event?.properties?.info
  if ((type === "session.created" || type === "session.updated") && info?.id && info?.parentID) {
    children.add(info.id)
  }
}

// node:child_process, not opencode's Bun `$` shell. It behaves identically
// under Bun (which runs the plugin) and under plain Node (which runs the
// offline test), so the test exercises the real invocation path instead of a
// mock. execFile also takes an argv array, so no shell quoting is involved.
import { execFile } from "node:child_process"

// Never throws. A missing roost, a dead tmux server, or a pane that went away
// must leave the pane unbadged, never break the agent being badged — the same
// discipline as the `|| true` on every tmux call in scripts/roost-agent-state.
const report = (state) =>
  new Promise((resolve) => {
    try {
      // ROOST_AGENT_NAME tells roost-agent-state's sink what to label an
      // unnamed pane, instead of falling back to @roost-name-default's
      // Claude-flavoured "claude" — every opencode pane would otherwise
      // read "claude" on its border and in the switcher.
      execFile(
        "roost",
        ["state", state],
        { env: { ...process.env, ROOST_AGENT_NAME: "opencode" }, timeout: 5000 },
        () => resolve()
      )
    } catch {
      resolve()
    }
  })

export const RoostState = async () => {
  // opencode emits session.status busy several times per turn. Holding the
  // last reported state keeps a turn to one process spawn per real transition.
  // This is separate from roost state's own unchanged-state early-bail, which
  // guards the tmux round trip rather than the spawn.
  let last = null
  let retries = 0
  // Session IDs seen carrying a parentID. Never pruned: one entry per subagent
  // a turn spawns is nothing next to a session's own history, and a session
  // that ends can still emit late events.
  const children = new Set()

  const set = async (state) => {
    if (state === last) return
    last = state
    await report(state)
  }

  return {
    event: async ({ event }) => {
      // Before the mapping, not inside it: a subagent's turn is a different
      // turn on the same bus, and its start and end are not this pane's.
      // A child's session.created arrives before its first session.status
      // (92ms apart in the run above), so the set is populated in time.
      learnChild(event, children)
      if (CHILD_MUTED.has(event?.type) && children.has(event?.properties?.sessionID)) return
      switch (event?.type) {
        case "session.status": {
          const status = event.properties?.status?.type
          if (status === "busy") {
            // Do NOT reset retries here. opencode fires busy immediately
            // before every retry, so busy and retry alternate in the real
            // stream — resetting on busy would zero the counter before it
            // could ever reach RETRY_THRESHOLD, making error unreachable.
            //
            // Do NOT report working once the threshold is reached, either.
            // The same busy/retry interleave means busy fires again on every
            // retry after error, and busy unconditionally reporting working
            // would flap the badge working/error for the whole retry loop and
            // re-notify on every cycle (a transition into error notifies). A
            // genuine recovery still resolves: the turn ends with
            // session.idle -> done, which resets the counter below.
            if (retries < RETRY_THRESHOLD) await set("working")
          } else if (status === "retry") {
            retries += 1
            await set(retries >= RETRY_THRESHOLD ? "error" : "working")
          }
          // status "idle" is ignored: session.idle follows it and is the
          // canonical end-of-turn signal.
          return
        }
        case "permission.asked":
          retries = 0
          await set("blocked")
          return
        case "permission.replied":
          retries = 0
          await set("working")
          return
        case "session.idle":
          retries = 0
          await set("done")
          return
        case "session.error": {
          retries = 0
          // MessageAbortedError is the user pressing Esc. Badging their own
          // keystroke as a crash — and pinging their desktop about it — would
          // be worse than saying nothing.
          const aborted = event.properties?.error?.name === "MessageAbortedError"
          await set(aborted ? "done" : "error")
          return
        }
      }
    },
  }
}

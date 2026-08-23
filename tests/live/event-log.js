// event-log.js — write every opencode event to a file, one JSON object a line.
//
// Installed next to adapters/opencode/roost.js by tests/live/opencode-smoke.sh
// so a live run records the stream the adapter is reacting to. opencode loads
// every *.js in its plugin directory, so the two plugins see the same events
// and neither can hide one from the other.
//
// It exists because the two questions this adapter kept getting wrong -- does a
// subagent's session badge the pane, and does opencode count retries for us --
// are both answerable only from the real stream with sessionID attached. A
// claim about the interleaving that nobody logged is how this adapter shipped
// a pane stuck on `working` once already.
//
// Writes only when ROOST_EVENT_LOG is set, so an accidental install in a real
// opencode config is inert rather than a disk filler.
import { appendFileSync } from "node:fs"

export const RoostEventLog = async () => {
  const path = process.env.ROOST_EVENT_LOG
  return {
    event: async ({ event }) => {
      if (!path) return
      try {
        // appendFileSync, not a stream: the process is killed at the end of a
        // case, and a buffered stream loses the last events -- which are the
        // end-of-turn ones every assertion here is about.
        //
        // Date.now() rather than the event's own time field: not every event
        // carries one, and the interleaving is the whole point.
        appendFileSync(path, JSON.stringify({ t: Date.now(), event }) + "\n")
      } catch {
        // Same discipline as the adapter: a logging failure must never break
        // the agent being logged.
      }
    },
  }
}

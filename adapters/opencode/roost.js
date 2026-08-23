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
// The guard is to ignore the child's LIFECYCLE and its SPEECH rather than to
// track which sessions are still busy. A set of active sessions that fails to
// empty leaves the pane on `working` forever — the exact bug this adapter
// already shipped once. Ignoring a child's events cannot get stuck: the
// parent's own events are always mapped, and a child we somehow never learned
// about only degrades to the old behaviour.
//
// The two message events are here for the reply channel, and they were NOT
// needed while this filter only had to protect the badge. A child session's
// messages carry a different assistant message id, and unfiltered they break
// `roost read` two ways at once:
//
//   1. the child's `message.updated` (role assistant) takes over assistantID
//      and clears the pending reply, so the child's text parts are collected
//      as if they were the pane's own answer, and the parent's `session.idle`
//      publishes them;
//   2. the parent's own later text parts are then REJECTED for not matching
//      the hijacked id — so the wrong answer does not merely appear, it
//      crowds out the right one.
//
// Muting them here, rather than keeping assistantID/pending in a per-session
// map, is deliberate. The map would be a second unbounded structure that has
// to be looked up on the parent's idle to mean anything, and it buys nothing:
// with the child muted, assistantID keeps pointing at the parent's message and
// (2) is fixed by the same line as (1). Fewer moving parts, and it reuses a
// mechanism that is already load-bearing and already tested.
//
// The over-filtering trap is real and this stays clear of it. A pane whose own
// turn produced no text of its own now publishes NOTHING rather than the
// child's text, and `roost read` falls back to the screen with its notice.
// That is the honest outcome — the pane's agent genuinely did not answer — and
// it is the outcome for a session that is never added to `children`, because
// only an id carrying a parentID is ever added and a pane's own session has
// none.
//
// Only these five. A subagent asks for permission under its OWN sessionID —
// measured on 1.18.20, a subagent told to run bash under `"bash": "ask"`:
//
//   30540ms  child   session.created
//   47589ms  child   permission.asked   <- the human has to answer this
//   47622ms  child   session.idle
//
// and the pane must show `blocked` for it. Filtering that out would leave the
// fleet reading `working` while the agent sits waiting for a keypress, which
// is the "silently stuck" failure, not a cosmetic one.
const CHILD_MUTED = new Set([
  "session.status",
  "session.idle",
  "session.error",
  "message.updated",
  "message.part.updated",
])

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
const run = (args) =>
  new Promise((resolve) => {
    try {
      // ROOST_AGENT_NAME tells roost-agent-state's sink what to label an
      // unnamed pane, instead of falling back to @roost-name-default's
      // Claude-flavoured "claude" — every opencode pane would otherwise
      // read "claude" on its border and in the switcher.
      execFile(
        "roost",
        args,
        { env: { ...process.env, ROOST_AGENT_NAME: "opencode" }, timeout: 5000 },
        () => resolve()
      )
    } catch {
      resolve()
    }
  })

const report = (state) => run(["state", state])

// The reply goes over argv, not stdin: `roost reply` takes argv precisely so
// that no public entry point can block waiting for input. roost truncates to
// its own byte budget, so nothing is capped here — one place decides that.
const publish = (text) => run(["reply", text])

export const RoostState = async () => {
  // opencode emits session.status busy several times per turn. Holding the
  // last reported state keeps a turn to one process spawn per real transition.
  // This is separate from roost state's own unchanged-state early-bail, which
  // guards the tmux round trip rather than the spawn.
  let last = null
  let retries = 0
  // Set by this turn's own session.error, and the reason the session.idle that
  // follows it must not report `done`.
  //
  // A turn that dies on the provider does not end quietly. Measured on 1.18.20
  // against an unreachable provider (tests/live/opencode-smoke.sh case 2):
  //
  //    3495ms  session.status  {"type":"retry","attempt":1,...} ... four more ...
  //   67103ms  session.error   {"name":"APIError",...}
  //   67103ms  session.idle     <- unfiltered, this stamped `done`
  //
  // The pane badged `error` at the second retry and fired the desktop
  // notification, then overwrote it with `done` a minute later. `done` means
  // "finished, go look", so the last thing the fleet showed for a turn that
  // never reached the model was a success. A wrong `done` is the worst wrong
  // badge there is: every other one makes you look, and this one makes you
  // stop looking.
  //
  // Keyed on session.error and NOT on the badge already reading `error`,
  // because those are different claims. Two retries that then SUCCEED are a
  // turn that finished — it had a rough patch, the model answered, and its
  // session.idle is a real completion that must still report `done`. Only a
  // turn opencode itself declared failed gets its idle swallowed.
  //
  // The mirror risk is a badge stuck on `error` for good, which would be worse
  // than the bug being fixed — the same shape as the pane that once sat on
  // `working` forever. The exact condition that clears it is the next turn
  // starting: a session.status busy below the retry threshold, or a permission
  // event. A turn cannot begin without one of those, so the next healthy turn
  // walks working -> done exactly as it always did. Both clears are marked
  // below.
  let died = false
  // Session IDs seen carrying a parentID. Never pruned: one entry per subagent
  // a turn spawns is nothing next to a session's own history, and a session
  // that ends can still emit late events.
  const children = new Set()
  // The id of the assistant message this turn is building, and the text it has
  // produced so far. Both are needed because the reply arrives spread across
  // several events and none of them is both "assistant" and "text" on its own
  // — see the case comments below.
  let assistantID = null
  let pending = null

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
        // Which event carries what was VERIFIED against a live opencode 1.18.20
        // turn (isolated XDG dirs, a spy plugin, a real model call), not read
        // off the type definitions. The type definitions would have produced a
        // different and broken answer: opencode declares a
        // `session.next.text.ended` event with a required `text` field, and the
        // string is present in the shipped binary, but it NEVER FIRES on a
        // normal turn. This is the same shape as the "permission.ask" hook
        // noted at the top of this file — a declared surface that is not the
        // live one.
        //
        // What actually happens, in order:
        //   message.updated        role=assistant   <- the id, before any text
        //   message.part.updated   partType=reasoning
        //   message.part.updated   partType=text  ""
        //   message.part.updated   partType=text  "<the whole reply>"
        //   session.idle
        case "message.updated": {
          // Learn the assistant message id BEFORE its parts arrive — verified
          // above: this fires first. It is the only thing that distinguishes an
          // assistant text part from the USER's own prompt, which arrives on
          // the very same message.part.updated event with the very same
          // partType "text". The message itself carries no text: an
          // AssistantMessage is id/role/time/cost/tokens with no parts array,
          // so this event can identify the reply but never supply it.
          if (event.properties?.info?.role === "assistant") {
            assistantID = event.properties.info.id
            pending = null
          }
          return
        }
        case "message.part.updated": {
          const part = event.properties?.part
          if (!part || part.messageID !== assistantID) return
          // type "text" only. Reasoning is delivered through this identical
          // event with type "reasoning" — publishing that would post the
          // model's thinking as its reply. `synthetic` parts are opencode's
          // own injected text, not something the agent said.
          if (part.type !== "text" || part.synthetic) return
          // Replace rather than append: the same part id is re-sent as it
          // grows ("" then the full text), with message.part.delta carrying
          // the increments separately. So the last one holds the complete
          // text and there is nothing to reassemble.
          //
          // A turn with several text parts split by tool calls keeps the LAST
          // one, which is also what Claude Code's last_assistant_message
          // returns for that shape — so both harnesses agree on what "the
          // reply" means.
          if (part.text) pending = part.text
          return
        }
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
            //
            // Clear 1 of 2 for `died`, releasing a pane from the previous
            // turn's `error`. It is safe here for a reason that does not
            // depend on the count at all: `died` is set only by session.error,
            // session.error is followed by session.idle, and that idle ends
            // the turn — so no busy belonging to the SAME turn can ever reach
            // this line with `died` already true. A busy that sees it set is
            // always a later turn.
            //
            // Sitting inside the threshold gate is the second line of defence
            // rather than the argument: releasing on a busy that IS part of a
            // retry loop would flap the badge, which is the same reason the
            // `set("working")` it sits next to is gated.
            if (retries < RETRY_THRESHOLD) {
              died = false
              await set("working")
            }
          } else if (status === "retry") {
            retries += 1
            await set(retries >= RETRY_THRESHOLD ? "error" : "working")
          }
          // status "idle" is ignored: session.idle follows it and is the
          // canonical end-of-turn signal.
          return
        }
        // Clear 2 of 2 for `died`, on both permission branches. A dialog means
        // the model answered, so the turn reached it — whatever the previous
        // turn died of is over. This is belt and braces next to the busy
        // clear: every turn opens with busy, so a permission event should
        // never be the first thing a new turn shows. It costs one assignment
        // to guarantee that a badge cannot stick on `error` through a turn
        // that is demonstrably alive.
        case "permission.asked":
          retries = 0
          died = false
          await set("blocked")
          return
        case "permission.replied":
          retries = 0
          died = false
          await set("working")
          return
        case "session.idle":
          retries = 0
          // The fix. `died` is left set, not cleared: it has to outlive this
          // idle to hold the badge on `error` until the next turn starts, and
          // this idle IS the end of the dead turn. Returning without reporting
          // leaves `last` on `error`, so the pane keeps the badge and no
          // process is spawned to say otherwise.
          if (died) return
          // AWAIT the reply before reporting done, and in this order. `roost
          // wait-done` returns the instant the badge stops being
          // working/blocked, and the documented idiom is wait-done then read —
          // so reporting done first opens a window where the reader lands
          // between the two calls and falls back to scraping the screen. Same
          // reasoning as the placement note in scripts/roost-agent-state.
          if (pending) {
            await publish(pending)
            pending = null
          }
          await set("done")
          return
        case "session.error": {
          retries = 0
          // Drop the half-built reply. A turn that ended in an error has no
          // answer to publish, and holding it would let it attach to the NEXT
          // turn — a stale reply served as if it were fresh.
          pending = null
          // MessageAbortedError is the user pressing Esc. Badging their own
          // keystroke as a crash — and pinging their desktop about it — would
          // be worse than saying nothing.
          //
          // It does not set `died` either, and that is the same judgement, not
          // a second one: an abort during a retry loop still ends `done`,
          // because the person who ended the turn is sitting right there and
          // already knows how it went. `died` is for the turns nobody chose.
          const aborted = event.properties?.error?.name === "MessageAbortedError"
          died = !aborted
          await set(aborted ? "done" : "error")
          return
        }
      }
    },
  }
}

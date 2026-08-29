// extension.mjs — report a GitHub Copilot CLI agent's state onto its tmux pane.
//
// Install by symlinking into copilot's user extension directory, so updating
// roost updates the extension:
//
//   mkdir -p ~/.copilot/extensions/roost
//   ln -s "$HOME/path/to/roost/adapters/copilot/extension.mjs" ~/.copilot/extensions/roost/extension.mjs
//
// Fill in the path to your roost checkout; `roost doctor` prints this exact
// command with the real path for your copy.
//
// The directory name is yours, the FILE name is not: copilot discovers
// `<dir>/extension.mjs` and nothing else, and the file must be an ES module.
// User scope (`~/.copilot/extensions/`) rather than project scope
// (`.github/extensions/`) is deliberate — measured on 1.0.81, prompt mode loads
// only the `user`, `plugin` and `session` scopes unless
// GITHUB_COPILOT_PROMPT_MODE_EXTENSIONS=true, so a project-scoped install would
// badge interactive panes and silently do nothing under `copilot -p`.
//
// TWO THINGS GATE THIS FILE, and both are silent when they are not met:
//
//   1. Extensions are behind a feature flag that is OFF by default. Either
//      launch `copilot --experimental`, or set
//      {"enabledFeatureFlags": {"EXTENSIONS": true}} in ~/.copilot/settings.json.
//      Both verified on 1.0.81; `roost doctor` checks for the second and names
//      the first. Without one of them copilot does not read the first line of
//      this file.
//   2. In interactive mode copilot asks the human to approve the extension's
//      elevated permissions, ONCE PER DIRECTORY, and denying prevents it from
//      loading. There is no global pre-approval. See the onPermissionRequest
//      comment for why that ask cannot be avoided.
//
// Unlike the opencode plugin, a copilot extension is a SEPARATE FORKED PROCESS,
// not code running inside the harness. That is the first thing an adapter has
// to check, because `roost state` finds its pane from $TMUX_PANE alone and a
// process that lost the variable would badge the wrong pane or none. Measured
// on 1.0.81: the fork inherits it. A probe logged
// {"TMUX_PANE":"%1","TMUX":"/tmp/cpx/roost,30657,0"} and the pane really was %1
// on that server, so pane targeting needs nothing passed around.
//
// The state is derived from copilot's own turn events rather than from tool
// calls, for the same reason the opencode plugin gives: a turn that answers
// without calling a tool would never show as working at all.

import { execFile } from "node:child_process"

// Never throws. A missing roost, a dead tmux server, or a pane that went away
// must leave the pane unbadged, never break the agent being badged — the same
// discipline as the `|| true` on every tmux call in scripts/roost-agent-state.
// It matters more here than it does for opencode: this code runs on copilot's
// permission path, and an exception thrown out of onPermissionRequest is thrown
// while a human is waiting at a dialog.
const run = (args) =>
  new Promise((resolve) => {
    try {
      // ROOST_AGENT_NAME tells roost-agent-state's sink what to label an
      // unnamed pane, instead of falling back to @roost-name-default's
      // Claude-flavoured "claude" — every copilot pane would otherwise read
      // "claude" on its border and in the switcher.
      execFile(
        "roost",
        args,
        { env: { ...process.env, ROOST_AGENT_NAME: "copilot" }, timeout: 5000 },
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

// A sub-agent's events arrive on this same bus, and this is the whole filter.
//
// Copilot's `task` tool does NOT open a child session the way opencode does.
// The sub-agent runs on the SAME session, and the only thing separating its
// events from the pane's own is one extra envelope key. Measured on 1.0.81, a
// turn that delegated `echo hello-from-subagent`; counted over the entire
// capture, `agentId` was present on every sub-agent event and absent from
// every parent event, with no exceptions in either direction:
//
//   06:41:46.889  assistant.turn_start                          (parent)
//   06:42:03.913  assistant.message   "I'll start a background task agent…"
//   06:42:03.940  subagent.started     agentId=7ec6d39a-…
//   06:42:03.962  assistant.turn_start agentId=7ec6d39a-…       (the child)
//   06:42:22.018  assistant.message    agentId=7ec6d39a-…  "hello-from-subagent"
//   06:42:22.029  subagent.completed   agentId=7ec6d39a-…
//   06:42:23.302  assistant.message   "The sub-agent printed: …"  (parent)
//   06:42:23.321  assistant.idle                                (parent)
//   06:42:23.322  session.idle                                  (parent)
//
// Two facts in that capture decide the shape of this line.
//
// The BADGE is not at risk here the way it was for opencode. The sub-agent
// emitted no session.idle and no assistant.idle at all, so there is no early
// `done` to guard against — copilot's #13 simply does not exist.
//
// The REPLY is at risk, at 06:42:22.018: the child's own answer arrives as a
// perfectly well-formed assistant.message and would be published as the pane's
// reply. In the capture the parent happened to speak afterwards and overwrite
// it, which is exactly the shape that makes this bug survive a green suite —
// so the fixture that matters is the turn where ONLY the sub-agent spoke
// (tests/copilot-extension-harness.mjs).
//
// Filtering by IGNORING an agentId-bearing event, rather than by tracking which
// sub-agents are still running, is spec §5 T1's rule and is why there is no
// latch here to get stuck: a counter that fails to reach zero would leave the
// pane mute for the rest of its life, and this cannot.
//
// The exception that must survive the filter is a sub-agent's PERMISSION
// dialog, because a human still has to answer it. It survives by construction
// rather than by a special case, and that was measured too: on a sub-agent told
// to run `rm -f subdel.txt`, onPermissionRequest is a callback with no envelope
// to filter, and both permission.requested and permission.completed arrived
// with _keys [type, data, id, timestamp, parentId] — no agentId. Had
// permission.completed carried one, this filter would have eaten the CLEAR and
// pinned the pane on `blocked` for good.
const fromSubagent = (event) => event?.agentId != null

export const RoostState = () => {
  // Copilot opens a new assistant.turn_start after every tool call, so one user
  // prompt emits several. Holding the last reported state keeps a turn to one
  // process spawn per real transition. This is separate from roost state's own
  // unchanged-state early-bail, which guards the tmux round trip rather than
  // the spawn.
  let last = null
  // Set by this turn's own session.error, and the reason the session.idle that
  // follows it must not report `done`.
  //
  // A turn that dies on the provider does not end quietly. Measured on 1.0.81
  // against an unreachable provider (a port bound and released, so nothing is
  // listening), the last five lines of the turn:
  //
  //   06:36:06.487  HOOK  onErrorOccurred    <- the sixth and last attempt
  //   06:36:06.489  HOOK  onSessionEnd  reason="error"
  //   06:36:06.489  EVENT session.error  {"errorType":"query","message":"Could not connect…"}
  //   06:36:06.489  EVENT assistant.idle     <- unfiltered, this stamped `done`
  //   06:36:06.490  EVENT session.idle       <- and so did this
  //
  // Without the suppression the pane badges `error`, fires the desktop
  // notification, and overwrites it with `done` one millisecond later. `done`
  // means "finished, go look", so the last thing the fleet would show for a
  // turn that never reached the model is a success. A wrong `done` is the worst
  // wrong badge there is: every other one makes you look, and this one makes
  // you stop looking. This is opencode's #13, in a harness that had not shipped
  // yet.
  //
  // Keyed on session.error and NOT on the badge already reading `error`,
  // because those are different claims — see the onErrorOccurred comment for
  // the several ways a healthy turn can report a failure on the way through.
  //
  // The mirror risk is a badge stuck on `error` for good, which would be worse
  // than the bug being fixed. The exact condition that clears it is the next
  // turn's assistant.turn_start, and the same capture proves no event from the
  // SAME turn can reach it: there is exactly one assistant.turn_start in the
  // whole dead turn, at 06:35:43.357, twenty-three seconds BEFORE the
  // session.error. Copilot re-attempts a failed call through model.turn_retry,
  // which opens no new assistant turn. A second clear is marked on the
  // permission branches.
  let died = false
  // The text this turn has produced so far, published on the way to `done`.
  let pending = null

  const set = async (state) => {
    if (state === last) return
    last = state
    await report(state)
  }

  // The clear for `blocked`, and it is scoped to the state it clears rather
  // than reported unconditionally.
  //
  // Copilot announces the human's answer to the extension's OWN elevated-
  // permissions consent on the same event, in the same millisecond as the join
  // and before any turn exists. Recorded on 1.0.81:
  //
  //   06:40:12.278  JOINED
  //   06:40:12.278  EVENT permission.completed  {"requestId":"e50ca450-…",
  //                                              "result":{"kind":"approved"}}
  //
  // An unconditional `permission.completed -> working` therefore badges a pane
  // that has not been asked to do anything, and `working` is the badge `roost
  // wait-done` blocks on — so a fresh pane would hang a waiter until its first
  // real turn happened to end. Guarding on the badge already reading `blocked`
  // says exactly what the event means: the human answered the thing we said
  // they were being waited on for.
  const unblock = async () => {
    // Belt and braces next to the assistant.turn_start clear: a dialog means
    // the model answered, so the turn reached it and whatever the previous turn
    // died of is over. It costs one assignment to guarantee a badge cannot
    // stick on `error` through a turn that is demonstrably alive.
    died = false
    if (last === "blocked") await set("working")
  }

  return {
    // `blocked` is reachable ONLY because this handler is registered, and that
    // is not an implementation detail — it is the trap this adapter exists
    // around.
    //
    // `permission.requested` is declared in copilot's shipped
    // schemas/session-events.schema.json AND documented in its shipped SDK docs
    // under "Top 10 Most Useful Event Types" as "Agent needs permission (shell,
    // file write, etc.)". Both say to subscribe with session.on. Measured on
    // 1.0.81 with a probe subscribed to every event and a real `rm` dialog open
    // on screen: it never fired once. The only permission event of that entire
    // run was a permission.completed AFTER the human answered — a badge that
    // lights up at the exact moment the human stops being blocked.
    //
    // The event is real. It is gated on registering this handler, and
    // registering one turns it on for session.on() as well:
    //
    //   06:40:36.358  EVENT tool.execution_start
    //   06:40:36.376  ON_PERMISSION_REQUEST  kind=shell   <- badge -> blocked
    //   06:40:36.376  EVENT permission.requested          <- now it fires too
    //                 … dialog on screen, human thinking for 17s …
    //   06:40:53.725  EVENT permission.completed          <- badge -> working
    //
    // ROOST MUST NEVER DECIDE A PERMISSION, and {kind:"no-result"} is the SDK's
    // own pass-through for exactly that: it observes without answering.
    // Verified end to end on 1.0.81 — the handler fired, the badge flipped, the
    // normal TUI dialog stayed on screen with "1. Yes / 2. Yes, and don't ask
    // again / 3. No", the human chose, and the command ran on their approval.
    // Returning anything else here would answer a dialog that exists to ask
    // them. `roost send` refuses a blocked pane with exit 3 for the same
    // reason: an agent must not press Enter on someone else's dialog.
    //
    // The cost is the consent dialog named at the top of this file, and it is
    // not avoidable while `blocked` is: copilot asks for consent because of
    // this handler. Measured on 1.0.81, the ask names what it is for, so the
    // honest thing is to keep it as small as it can be — an extension that also
    // registered a `hooks:` block was announced as "wants to: register hooks,
    // handle permission requests", and this one, which registers no hooks
    // because everything else it needs is on the event bus, is announced as
    // "wants to: handle permission requests".
    onPermissionRequest: async () => {
      // A dialog is proof the turn reached the model. Same clear as `unblock`,
      // for the same belt-and-braces reason.
      died = false
      await set("blocked")
      return { kind: "no-result" }
    },

    event: async (event) => {
      // Before the mapping, not inside it: a sub-agent's turn is a different
      // turn on the same bus, and its start, end and speech are not this
      // pane's. Permission signals never carry agentId, so this cannot swallow
      // a dialog a human has to answer — see the fromSubagent comment.
      if (fromSubagent(event)) return
      switch (event?.type) {
        // Which event carries what was VERIFIED against live copilot 1.0.81
        // turns (an isolated COPILOT_HOME, a BYOK ollama provider, a probe
        // extension logging every event and hook), not read off the type
        // definitions. The type definitions would have produced a broken
        // adapter here: see onPermissionRequest above.
        case "assistant.turn_start":
          // Copilot opens one of these per MODEL turn, not per user prompt, so
          // a prompt that calls a tool emits two or more. The debounce in
          // set() makes the extras free. Recorded on 1.0.81, one `rm` prompt:
          //   06:40:20.338  assistant.turn_start   <- the model's first turn
          //   06:40:53.773  assistant.turn_start   <- after the tool returned
          //
          // Clear 1 of 2 for `died`, releasing a pane from the previous turn's
          // `error`. Safe here for the reason set out at `died`'s declaration:
          // no assistant.turn_start belonging to a dead turn can arrive after
          // that turn's session.error.
          died = false
          await set("working")
          return
        // The other way a copilot turn waits on a human, and it needs no gate:
        // the ask_user tool raises this as a plain event. Recorded on 1.0.81 —
        // the model was told to ask which colour, the TUI drew a choice list,
        // and the pane sat there for over two minutes:
        //
        //   06:44:58.684  EVENT elicitation.requested
        //   06:47:10.703  EVENT elicitation.completed
        //
        // Note it is elicitation.* and NOT the onUserInputRequest handler the
        // SDK also offers: that handler was registered on the probe for this
        // very turn and did not fire. Another declared surface that is not the
        // live one.
        case "elicitation.requested":
          died = false
          await set("blocked")
          return
        case "permission.completed":
        case "elicitation.completed":
          await unblock()
          return
        case "assistant.message": {
          // The reply is the LAST assistant message of the turn that answers
          // rather than requests a tool. Copilot announces both through this
          // one event and tells them apart by toolRequests. Recorded on 1.0.81,
          // one prompt that needed a tool:
          //
          //   06:40:36.337  assistant.message  content=""  toolRequests=[1]
          //   … the tool runs …
          //   06:40:54.604  assistant.message  content="File removed successfully."  toolRequests=[]
          //
          // Requiring toolRequests to be EMPTY as well as content to be
          // non-empty is the stricter of the two available filters and is the
          // right one: a model is free to narrate ("let me check that") while
          // requesting a tool, and that sentence is not the turn's answer.
          // Publishing it would serve a confident wrong answer to a
          // coordinating agent, which is the failure this whole mechanism
          // exists to remove.
          //
          // Replace rather than append. Several answering messages across one
          // prompt keep the LAST, which is also what Claude Code's
          // last_assistant_message returns for the same shape — so `roost read`
          // means one thing regardless of which harness produced the text.
          //
          // Copilot needs none of opencode's message-id bookkeeping, and the
          // reason is a measured difference rather than a simplification:
          // opencode re-announces the same assistant message twice AFTER its
          // text lands (the #14 bug), so it has to clear on an id CHANGE.
          // Copilot emits exactly one assistant.message per model turn, and the
          // model's reasoning arrives on a separate assistant.reasoning event
          // instead of on this one with a different part type. Both were
          // checked across five captures.
          const data = event.data
          if (data?.content && (data.toolRequests?.length ?? 0) === 0) pending = data.content
          return
        }
        // The only signal `error` is taken from, and the second finding in the
        // dead-provider capture rather than an oversight.
        //
        // Copilot announces a failure on this bus once per FAILED ATTEMPT, not
        // once per dead turn. The same capture, in full:
        //
        //   06:35:43.366  model.call_failure    06:35:44.372  model.turn_retry
        //   06:35:44.397  model.call_failure    06:35:46.401  model.turn_retry
        //   06:35:46.417  model.call_failure    06:35:50.421  model.turn_retry
        //   06:35:50.440  model.call_failure    06:35:58.444  model.turn_retry
        //   06:35:58.461  model.call_failure    06:36:06.463  model.turn_retry
        //   06:36:06.486  model.call_failure    06:36:06.488  model.turn_failed
        //   06:36:06.489  session.error   <- the only end-of-turn declaration
        //
        // and it fires the onErrorOccurred HOOK alongside each of those six.
        // So neither model.call_failure nor onErrorOccurred is evidence the
        // turn is over: an adapter that badges on either turns the first
        // transient blip into a red pane and a desktop ping. `error` claims the
        // turn ended, produced no answer, and will not without you; a call
        // copilot is about to retry claims none of those things. This is spec
        // §5 T7 in copilot's clothing.
        //
        // opencode had to COUNT retries because it has no single end-of-turn
        // failure declaration. Copilot does, so there is no threshold here to
        // tune and no counter to reset — and no `hooks:` block to register,
        // which is what keeps the consent ask at the top of this file down to
        // "handle permission requests".
        //
        // One case here is UNVERIFIED and is left alone on purpose: a human
        // pressing Esc mid-turn. opencode raises a MessageAbortedError for that
        // and the opencode adapter badges it `done`, because pinging someone's
        // desktop about their own keystroke is worse than saying nothing. Four
        // attempts to reproduce the equivalent on copilot 1.0.81 failed — Esc
        // was not acted on while a model call was in flight, and every turn
        // completed normally instead — so it is not known whether copilot emits
        // session.error for an abort at all. Guessing at a discriminator from
        // the payload would be inventing a state from a signal nobody has seen,
        // which spec §1 rules out. If it turns out copilot does, the badge is
        // wrong in the loud direction (a red pane and a notification for a turn
        // the human ended themselves), and this comment is where to start.
        case "session.error":
          // Drop the half-built reply. A turn that ended in an error has no
          // answer to publish, and holding it would let it attach to the NEXT
          // turn — a stale reply served as if it were fresh.
          pending = null
          died = true
          await set("error")
          return
        case "session.idle":
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
          // between the two calls and falls back to scraping the screen. The
          // await is part of the rule, not tidiness: the publish is a process
          // spawn. Same reasoning as the placement note in
          // scripts/roost-agent-state.
          if (pending) {
            await publish(pending)
            pending = null
          }
          await set("done")
          return
        // assistant.idle is copilot's redundant sibling of session.idle: in
        // every capture the two arrived back to back, assistant.idle first, one
        // millisecond apart. Only session.idle is mapped, so a turn ends with
        // one `roost state` call rather than two. It is left unmapped rather
        // than deleted from this comment because "which of the two ends a
        // turn?" is the first question the next reader will have.
      }
    },
  }
}

// --- what copilot actually runs ---------------------------------------------
//
// Unlike an opencode plugin, which opencode imports and CALLS, a copilot
// extension is a forked process that has to join the session itself. So this
// file both exports the state machine above (which
// tests/copilot-extension-harness.mjs drives offline, with no SDK and no model
// call) and joins on import, which is what copilot does with it.
//
// The import is inside a try, and the catch is not defensive padding: it is the
// seam that lets the harness import this file at all. `@github/copilot-sdk` is
// injected into an extension subprocess by copilot and exists nowhere else, so
// outside copilot the import throws and this block is a no-op — the same
// "never throw, leave the pane unbadged" rule as run(), applied to the load
// path instead of the report path.
try {
  const { joinSession } = await import("@github/copilot-sdk/extension")
  const adapter = RoostState()
  const session = await joinSession({
    // No `hooks:` block. Everything this adapter needs is on the event bus, and
    // registering hooks would widen copilot's per-directory consent ask from
    // "wants to: handle permission requests" to "wants to: register hooks,
    // handle permission requests" — measured on 1.0.81 — for nothing.
    onPermissionRequest: adapter.onPermissionRequest,
  })
  session.on(adapter.event)
} catch {
  // Nothing to report to: outside copilot there is no session to badge, and
  // inside copilot a failure to join must leave the agent working rather than
  // take the extension subprocess down with it.
}

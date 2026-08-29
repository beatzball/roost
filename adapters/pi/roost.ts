// roost.ts — report a pi agent's state onto its tmux pane.
//
// Install by symlinking into pi's global extension directory, so updating
// roost updates the extension:
//
//   mkdir -p ~/.pi/agent/extensions
//   ln -s "$HOME/path/to/roost/adapters/pi/roost.ts" ~/.pi/agent/extensions/roost.ts
//
// Fill in the path to your roost checkout; `roost doctor` prints this exact
// command with the real path for your copy.
//
// TypeScript with no build step: pi loads extensions through jiti, so a `.ts`
// file in that directory is what pi wants. The file name is yours — pi
// discovers `*.ts` and `*/index.ts` under that directory. GLOBAL scope
// (`~/.pi/agent/extensions/`) rather than project scope (`.pi/extensions/`) is
// deliberate: a project-local extension loads only after the project is
// trusted, so a fresh worktree would badge nothing until the human answered
// pi's trust prompt, and would say nothing about why.
//
// pi runs IN the pane process — `pane_current_command` is `node` — so
// `$TMUX_PANE` names this pane and nothing has to be passed around. There is no
// client/server split to worry about, unlike `opencode attach`.
//
// The state is derived from pi's own agent lifecycle rather than from tool
// calls, for the reason the opencode plugin gives: a turn that answers without
// calling a tool would never show as working at all.
//
// ONE THING PI DOES NOT HAVE, and it is a design decision rather than a gap.
// pi ships no permission prompts. Its own docs/usage.md:309 lists them among
// the things it intentionally omits, alongside MCP, sub-agents, plan mode and
// background bash. So on a stock pi install `blocked` NEVER FIRES — not
// because roost cannot see a dialog, but because nothing asks. What that costs
// a fleet is written down in site/content/docs/state-badges.md and in
// docs/known-gaps.md. The dialog wrap below is what makes the state reachable
// the moment a user brings their own gate.

import { execFile } from "node:child_process"

// Never throws. A missing roost, a dead tmux server, or a pane that went away
// must leave the pane unbadged, never break the agent being badged — the same
// discipline as the `|| true` on every tmux call in scripts/roost-agent-state.
// pi is more forgiving than most here (its docs promise "extension errors are
// logged, agent continues"), but "logged" means a line of noise in a human's
// TUI on every turn, and one of these calls happens while a human is waiting
// at a dialog.
const run = (args: string[]): Promise<void> =>
  new Promise((resolve) => {
    try {
      // ROOST_AGENT_NAME tells roost-agent-state's sink what to label an
      // unnamed pane, instead of falling back to @roost-name-default's
      // Claude-flavoured "claude" — every pi pane would otherwise read
      // "claude" on its border and in the switcher. Without it a pi pane also
      // has nothing better to fall back to: pi's own process name is `node`.
      execFile(
        "roost",
        args,
        { env: { ...process.env, ROOST_AGENT_NAME: "pi" }, timeout: 5000 },
        () => resolve()
      )
    } catch {
      resolve()
    }
  })

const report = (state: string) => run(["state", state])

// The reply goes over argv, not stdin: `roost reply` takes argv precisely so
// that no public entry point can block waiting for input. roost truncates to
// its own byte budget, so nothing is capped here — one place decides that.
const publish = (text: string) => run(["reply", text])

// The four blocking dialogs on pi's ExtensionUIContext. `notify`, `setStatus`
// and `setWidget` are fire-and-forget and nobody waits on them; `custom()` is
// deliberately NOT in this list even though it also takes keyboard focus and
// also resolves on a keypress. pi ships snake.ts, space-invaders.ts and
// tic-tac-toe.ts as `custom()` examples, and a human playing a game is not an
// agent that cannot proceed until they act — badging that `blocked` would fire
// a desktop notification about someone's own choice to open it, and `roost
// send` would refuse the pane with exit 3 for no reason.
const DIALOGS = ["confirm", "select", "input", "editor"] as const

// Two properties parked on pi's shared UI object. They are deliberately
// distinct: WRAPPED says "the methods on this object have already been
// replaced", SINK says "and here is who to tell". See attach() for why one
// flag cannot do both jobs.
const WRAPPED = "__roostDialogWrapped"
const SINK = "__roostDialogSink"

type Sink = { open: () => Promise<void>; close: () => Promise<void> }

/** The whole state machine, exported so tests/pi-extension-harness.mjs can
 *  drive it offline with no pi and no model call. */
export const RoostState = () => {
  // pi emits agent_start once per LOW-LEVEL run, and a turn against a dead
  // provider is four of them (measured — see the agent_settled comment).
  // Holding the last reported state keeps a turn to one process spawn per real
  // transition. This is separate from roost state's own unchanged-state
  // early-bail, which guards the tmux round trip rather than the spawn.
  let last: string | null = null
  // The text this turn has produced so far, published on the way to `done`.
  let pending: string | null = null
  // The stopReason of the most recent ASSISTANT message of this run. This is
  // the whole of `error` detection — see the agent_settled branch.
  let stop: string | null = null
  // How many blocking dialogs are open. A counter rather than a boolean
  // because a gate is free to ask twice (confirm, then input for a reason),
  // and the inner dialog closing must not un-block a pane whose outer dialog
  // is still on screen.
  //
  // T8 says name the exact thing that clears a latch and prove no event from
  // the same turn can leave it stuck. This one is cleared in a `finally`, so
  // it survives the dialog throwing, the human pressing ctrl+c, and the turn
  // being aborted mid-prompt. The clamp in dialogClose covers the one case a
  // `finally` cannot: a `/reload` between an open and its close re-points SINK
  // at a fresh instance whose counter is 0, and that instance then sees a
  // close it never saw an open for.
  let depth = 0

  const set = async (state: string) => {
    if (state === last) return
    last = state
    await report(state)
  }

  // The reply is the last assistant TEXT of the turn, and pi hands us three
  // things on the same event that are not it.
  //
  //   1. A `thinking` part. message.content is a parts array and a reasoning
  //      model puts its reasoning there — recorded live on granite4.2:3b, a
  //      plain "Say exactly: BANANA" turn came back with
  //      partTypes ["thinking","text"]. Publishing the model's thinking as its
  //      answer is spec §2's first exclusion.
  //   2. A tool-calling message. pi marks it stopReason "toolUse", and the
  //      model is free to narrate ("Let me do that") while requesting a tool.
  //      That sentence is not the turn's answer; the answer comes after the
  //      tool returns. Recorded live, an `echo MANGO` turn:
  //        message_end role=assistant stopReason=toolUse  text=""
  //        message_end role=toolResult                    text="MANGO\n"
  //        message_end role=assistant stopReason=stop     text="The command …"
  //   3. A message that ended in `error` or `aborted`. Neither is an answer.
  //
  // So the filter is on stopReason, and it is an ALLOW list of the two values
  // that mean the model finished speaking: "stop", and "length" (it ran out of
  // output budget mid-answer, which is still the answer it gave). A deny list
  // would silently start publishing whatever value pi adds next.
  const answerOf = (message: any): string | null => {
    if (message?.stopReason !== "stop" && message?.stopReason !== "length") return null
    const parts = Array.isArray(message?.content) ? message.content : []
    const text = parts
      .filter((p: any) => p?.type === "text")
      .map((p: any) => p?.text ?? "")
      .join("")
    // An empty string stored in @roost-reply reads as present and is returned
    // as the agent's answer, so publish nothing rather than nothing-shaped.
    return text.length > 0 ? text : null
  }

  const dialogOpen = async () => {
    depth += 1
    if (depth !== 1) return
    // Guarded on the pane already reading `working`, and that guard is the
    // definition of the state rather than caution. spec §1: `blocked` means a
    // human is being waited on AND THE AGENT CANNOT PROCEED until they act. A
    // dialog raised by an extension COMMAND — `/mycommand` asking a question
    // while pi sits idle — waits on a human too, but no turn is stuck behind
    // it. Badging that would ping the human's desktop about a dialog they just
    // opened themselves, and would leave `roost wait-done` blocking on a pane
    // that is not working.
    if (last === "working") await set("blocked")
    // The await is deliberate, and it costs the human up to one process spawn
    // before their dialog draws. It buys the ordering that makes `blocked`
    // worth having: `roost send` refuses a blocked target with exit 3 so that
    // one agent cannot type into another's dialog, and a badge written AFTER
    // the dialog opens leaves a window where the refusal does not fire.
  }

  const dialogClose = async () => {
    // Never below zero — see the `depth` comment for the /reload case this
    // covers. A negative counter would mean the next real dialog needed two
    // opens to reach 1, so the pane would silently stop reporting `blocked`.
    depth = depth > 0 ? depth - 1 : 0
    if (depth !== 0) return
    if (last === "blocked") await set("working")
  }

  return {
    dialogOpen,
    dialogClose,

    // Install the dialog wrap on pi's UI context.
    //
    // `ctx.ui` is a getter that returns ONE SHARED OBJECT for every loaded
    // extension — dist/core/extensions/runner.js:458 `get ui() { return
    // runner.uiContext }`, and the object is installed by setUIContext()
    // BEFORE session_start is emitted, so it is already there when this runs.
    // That sharing is what lets roost see a dialog it did not raise. Verified
    // live on 0.81.1 with two extensions in one pi: `agate.ts` (a stand-in
    // third-party permission gate) called ctx.ui.confirm, and the probe next
    // door saw it, with the dialog on screen at that moment:
    //
    //   {"ev":"session_start","mode":"tui","hasUI":true,"sameObj":true}
    //   {"ev":"__patched"}
    //   {"ev":"agent_start","mode":"tui"}
    //   {"ev":"message_end","role":"assistant","stopReason":"toolUse","text":""}
    //   {"ev":"__dialog_open","m":"confirm","depth":1}   <- agate.ts's dialog
    //   {"ev":"__dialog_close","m":"confirm","depth":0}  <- the human pressed Enter
    //   {"ev":"message_end","role":"toolResult","text":"MANGO\n"}
    //   {"ev":"message_end","role":"assistant","stopReason":"stop","text":"The command …"}
    //   {"ev":"agent_settled","mode":"tui"}
    //
    // ROOST OBSERVES THE DIALOG AND NEVER ANSWERS IT. The wrapper calls the
    // original and returns exactly what it returned; there is no branch here
    // that can decide a permission. `roost send`'s exit-3 refusal exists for
    // the same reason: an agent must not press Enter on someone else's dialog.
    //
    // THE SHARING IS NOT A DOCUMENTED CONTRACT. It is a fact of the 0.81.1
    // build, read out of the shipped runner and then driven live. If pi ever
    // makes ctx.ui per-extension — a reasonable isolation change —
    // third-party dialogs stop reaching us with no crash and no error, just a
    // badge that never appears. tests/live/pi-smoke.sh asserts `blocked`
    // against a real dialog for exactly that reason: it turns a silent break
    // into a red test after a pi upgrade.
    //
    // Why WRAPPED and SINK are two properties rather than one flag.
    //
    // `/reload` re-uses the same UI object and rebuilds every extension.
    // Measured on 0.81.1 — reload, then one dialog, with a naive
    // wrap-if-not-marked:
    //
    //   {"ev":"session_shutdown"}
    //   {"ev":"session_start","sameObj":true}
    //   {"ev":"__patched"}
    //   {"ev":"__dialog_open","m":"confirm","depth":1}   <- the new instance
    //   {"ev":"__dialog_open","m":"confirm","depth":1}   <- and the DEAD one
    //
    // Two `roost state blocked` calls for one dialog, from two instances, and
    // one more with every further reload. A single "already wrapped, skip"
    // flag has the mirror bug and it is the worse of the two: the wrapper left
    // behind belongs to the SHUT-DOWN instance, whose counters are frozen, so
    // the live adapter would never hear about a dialog again.
    //
    // So the methods are replaced exactly once, and the wrapper reads who to
    // tell out of SINK at call time. Every session_start re-points SINK at the
    // instance that is actually running.
    attach: (ui: any) => {
      if (!ui) return
      const sink: Sink = { open: dialogOpen, close: dialogClose }
      ui[SINK] = sink
      if (ui[WRAPPED]) return
      ui[WRAPPED] = true
      for (const name of DIALOGS) {
        const original = ui[name]
        if (typeof original !== "function") continue
        ui[name] = async (...args: any[]) => {
          const s: Sink | undefined = ui[SINK]
          await s?.open()
          try {
            return await original.apply(ui, args)
          } finally {
            await s?.close()
          }
        }
      }
    },

    // One entry point for all four subscribed events, so the harness can
    // replay a recorded turn as a flat list in the order pi emitted it.
    event: async (name: string, event?: any) => {
      switch (name) {
        case "agent_start":
          // pi opens one of these per low-level run, not per user prompt: a
          // retry is a new one. The debounce in set() makes the extras free.
          //
          // Both resets belong here rather than at the end of a turn. `stop`
          // is what the settle below reads to choose error over done, and a
          // stale one would carry the LAST turn's failure into this turn's
          // ending; `pending` is what gets published, and a stale one would
          // serve the last turn's answer as this turn's.
          pending = null
          stop = null
          await set("working")
          return
        case "message_end": {
          const message = event?.message
          // message_end fires for user, assistant AND toolResult messages —
          // all three are in the capture in the attach() comment. Only an
          // assistant one carries a stopReason or an answer.
          if (message?.role !== "assistant") return
          stop = message.stopReason ?? null
          const text = answerOf(message)
          // Replace rather than append: several answering messages across one
          // prompt keep the LAST, which is also what Claude Code's
          // last_assistant_message returns for the same shape, so `roost read`
          // means one thing regardless of which harness produced the text.
          // Guarded on a non-null text so a later tool-calling or errored
          // message cannot wipe an answer that already landed.
          if (text !== null) pending = text
          return
        }
        case "agent_settled": {
          // agent_settled, NEVER agent_end. pi's own docs say so — "use
          // agent_settled for status integrations" — and the reason is
          // measurable. Against a dead provider (a port bound and released,
          // so nothing is listening), recorded live on 0.81.1:
          //
          //   agent_start / turn_start / message_end stopReason=error / agent_end
          //   agent_start / turn_start / message_end stopReason=error / agent_end
          //   agent_start / turn_start / message_end stopReason=error / agent_end
          //   agent_start / turn_start / message_end stopReason=error / agent_end
          //   agent_settled                        <- exactly one, at the true end
          //
          // An adapter on agent_end would flap the badge four times and stamp
          // `done` three times mid-retry, while pi was still trying. A wrong
          // `done` is the worst wrong badge there is: every other one makes
          // you look, and this one makes you stop looking.
          //
          // That single settle is also why there is no suppression latch here.
          // opencode (#13) and copilot both fire a trailing idle AFTER their
          // failure declaration, so both adapters carry a `died` flag to stop
          // it overwriting `error` with `done`. pi emits no such trailing
          // event — the four retries end in one settle and nothing after it —
          // so the whole class of bug is absent, and there is no latch here to
          // get stuck. Do not add one.
          if (stop === "error") {
            // Drop the half-built reply. A turn that ended in an error has no
            // answer to publish, and holding it would let it attach to the
            // NEXT turn — a stale reply served as if it were fresh.
            pending = null
            await set("error")
            return
          }
          // Everything that is not stopReason "error" ends `done`, and the
          // case that makes this a decision rather than a default is
          // "aborted": the human pressed Esc. Verified live on 0.81.1 —
          // Escape mid-turn produces
          //   message_end role=assistant stopReason="aborted"
          //   agent_settled
          // and nothing else. `error` fires a desktop notification, so mapping
          // an abort to it pings someone about their own keystroke and calls
          // it a crash. spec §1 settles this the same way for opencode's
          // MessageAbortedError. The turn is over and there is nothing to fix:
          // that is `done`.
          //
          // The reply is published BEFORE the badge, and the await is part of
          // the rule rather than tidiness. `roost wait-done` returns the
          // instant the badge stops being working/blocked, and the documented
          // idiom is wait-done then read — so reporting done first opens a
          // window where the reader lands between the two calls and falls back
          // to scraping the screen. pi is a full-screen TUI, so a scrape
          // returns its input box and footer.
          if (pending) {
            await publish(pending)
            pending = null
          }
          await set("done")
          return
        }
        // session_start is subscribed but reports no state. spec §1: `idle` is
        // a default, not a report — tmux/roost.conf leaves @agent_state with
        // no global default so an unstamped pane renders as idle already, and
        // stamping it would only spend a process spawn to say the same thing.
        // Its handler exists to call attach().
        //
        // session_shutdown is not subscribed at all, for the same reason plus
        // one more: a pane whose pi has exited is about to be a dead pane or a
        // shell, and `idle` is what both already read as.
      }
    },
  }
}

// --- what pi actually runs ---------------------------------------------------

export default function (pi: any) {
  const adapter = RoostState()

  // ctx.hasUI GATES EVERYTHING, and it is the sub-agent filter (spec §5 T1) —
  // not a nicety about not drawing in a headless run.
  //
  // pi has no built-in sub-agents, but its shipped
  // examples/extensions/subagent/ does, and it implements one by SPAWNING A
  // SEPARATE PI PROCESS: `pi --mode json -p --no-session` (index.ts:294,
  // spawn at :335). A child process started from this pane inherits this
  // pane's environment, so it inherits $TMUX_PANE — and it loads the same
  // GLOBAL extensions, this file among them. Measured live on 0.81.1, running
  // exactly that command from inside a roost pane:
  //
  //   {"ev":"__factory","pid":9307,"TMUX_PANE":"%114","TMUX":"…/roost,…",
  //    "argv":["…/pi","--mode","json","-p","--no-session","Say exactly: CHILD"]}
  //   {"ev":"session_start","pid":9307,"mode":"json","hasUI":false}
  //   {"ev":"agent_start","pid":9307,"mode":"json","hasUI":false}
  //   {"ev":"agent_settled","pid":9307,"mode":"json","hasUI":false}
  //
  // Ungated, every sub-agent would badge its PARENT'S pane: `working` when it
  // starts, `done` when it finishes — while the parent is still working — and
  // it would publish its own answer as the pane's reply. That is opencode's T1
  // in a harsher form, because the two are separate OS processes and no
  // in-process filter can see across them.
  //
  // hasUI rather than mode === "tui" because it is the property that means
  // what we need: `true` in tui and rpc — a human is attached to this pane —
  // and `false` in print (-p) and json, which is how every spawned worker
  // runs. Read straight off the runner: hasUI() is `uiContext !== noOpUIContext`
  // (runner.js:273), and print/json bind no UI context at all.
  //
  // The cost is stated rather than hidden: a pane where a human types
  // `pi -p "…"` themselves is not badged either. See docs/known-gaps.md.
  const badged = (ctx: any) => ctx?.hasUI === true

  pi.on("session_start", async (_event: any, ctx: any) => {
    if (!badged(ctx)) return
    // Re-pointed on every session_start, which covers /reload, /new, /resume
    // and /fork — pi tears the old extension instance down and builds a new
    // one for each, and every one of them arrives here.
    adapter.attach(ctx.ui)
    await adapter.event("session_start")
  })
  pi.on("agent_start", async (_event: any, ctx: any) => {
    if (!badged(ctx)) return
    await adapter.event("agent_start")
  })
  pi.on("message_end", async (event: any, ctx: any) => {
    if (!badged(ctx)) return
    await adapter.event("message_end", event)
    // Returning nothing leaves the message alone. A message_end handler MAY
    // return { message } to replace the finalized message, and this one must
    // never do that: roost reports on an agent, it does not edit it.
  })
  pi.on("agent_settled", async (_event: any, ctx: any) => {
    if (!badged(ctx)) return
    await adapter.event("agent_settled")
  })
}

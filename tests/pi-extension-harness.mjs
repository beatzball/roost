// Fire synthetic pi events at adapters/pi/roost.ts and assert which `roost`
// calls come out, with a recording shim standing in for roost on PATH. Runs
// offline, in milliseconds, with no pi and no model call.
//
// Prints "  PASS:" / "  FAIL:" lines so tests/run.sh counts them like any bash
// test, and always exits 0 — run.sh treats a non-zero exit as a crash.
//
// The shim, the column layout and the \x1e newline escape are lifted verbatim
// from tests/copilot-extension-harness.mjs, which lifted them from
// tests/opencode-plugin-harness.mjs. Three adapters asserting the same contract
// should fail the same way, and a reader who has read one file should not have
// to learn a third set of helpers.
//
// The adapter is a .ts file because that is what pi loads (through jiti, with
// no build step). Node strips the types on import from 22.18 on;
// tests/test-pi-extension.sh is what refuses to run this on an older one,
// rather than letting the import throw and read as a crash.
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync, chmodSync } from "node:fs"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

const HERE = fileURLToPath(new URL(".", import.meta.url))
// Short path: the ~104-char unix socket limit bites elsewhere in this suite,
// and /tmp/amx.* is the prefix its cleanup tooling knows about.
const dir = mkdtempSync("/tmp/amx.")
const log = join(dir, "calls")
const shim = join(dir, "roost")
// Record the subcommand ($1), its argument ($2) and whether ROOST_AGENT_NAME
// arrived, tab-separated, so calls() (states only), replies() (reply text
// only) and envNames() (ROOST_AGENT_NAME only) can each read their own column
// without disturbing the other's assertions.
//
// \x1e (ASCII record separator) stands in for a newline inside the argument: a
// reply is genuinely multi-line — that is most of the point of recording one
// instead of scraping a screen — and a raw newline would split one call across
// two log rows. replies() maps it back before any assertion sees it.
writeFileSync(
  shim,
  `#!/bin/sh\nesc=\`printf '%s' "$2" | tr '\\n' '\\036'\`\nprintf '%s\\t%s\\t%s\\n' "$1" "$esc" "\${ROOST_AGENT_NAME:-}" >> "${log}"\n`
)
chmodSync(shim, 0o755)
const REAL_PATH = process.env.PATH
process.env.PATH = `${dir}:${REAL_PATH}`

let pass = 0
let fail = 0
const check = (got, want, what) => {
  if (got === want) {
    pass++
    console.log(`  PASS: ${what}`)
  } else {
    fail++
    console.log(`  FAIL: ${what}\n       want [${want}] got [${got}]`)
  }
}

const rows = () => (existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean) : [])
const cols = () => rows().map((r) => r.split("\t"))
const calls = () => cols().filter((c) => c[0] === "state").map((c) => c[1]).join(",")
const replies = () => cols().filter((c) => c[0] === "reply").map((c) => c[1].replace(/\x1e/g, "\n"))
// The verbs in order, which is what the reply-before-done assertions are about.
const verbs = () => cols().map((c) => c[0]).join(",")
const envNames = () => cols().map((c) => c[2])

// The adapter is a .ts file because that is the only thing pi loads. Node
// strips the types on import from 22.18 (and 23.6) on; before that the import
// fails with ERR_UNKNOWN_FILE_EXTENSION and there is nothing this file can do
// about it.
//
// That one cause is turned into a SKIP, and everything else is re-thrown so it
// crashes the file and tests/run.sh reports it. The distinction matters: a
// syntax error in the adapter also throws here, and a harness that answered
// "skip" to it would be the exact shape docs/known-gaps.md warns about --
// green that is evidence about the tests rather than about the feature.
let mod
try {
  mod = await import(join(HERE, "..", "adapters", "pi", "roost.ts"))
} catch (e) {
  const why = String(e?.message ?? e)
  if (e?.code === "ERR_UNKNOWN_FILE_EXTENSION" || /strip-types|Unknown file extension/.test(why)) {
    console.log(`  SKIP: node ${process.versions.node} cannot import a .ts file — pi adapter mapping tests skipped (needs node >= 22.18)`)
    rmSync(dir, { recursive: true, force: true })
    process.exit(0)
  }
  throw e
}
const { RoostState } = mod
const install = mod.default

// --- event constructors, shaped exactly as pi 0.81.1 emits them --------------
//
// Every message_end carries { message }, and message is pi-ai's Message: a
// role, a `content` PARTS ARRAY, and — on an assistant message only — a
// stopReason out of "stop" | "length" | "toolUse" | "error" | "aborted".
const msg = (message) => ({ message })
// The final answer of an agent run: stopReason "stop", a text part, and — on a
// reasoning model — a thinking part in front of it that must never be
// published. Both were in every live capture on granite4.2:3b.
const said = (text, { thinking = "the model's private reasoning" } = {}) =>
  msg({
    role: "assistant",
    stopReason: "stop",
    content: [
      ...(thinking === null ? [] : [{ type: "thinking", thinking }]),
      { type: "text", text },
    ],
  })
// An assistant message that is calling a tool rather than answering. Recorded
// live with text "", but `narration` stages the case that matters: a model is
// free to say "let me check that" while requesting a tool.
const calling = (narration = "") =>
  msg({
    role: "assistant",
    stopReason: "toolUse",
    content: [
      ...(narration ? [{ type: "text", text: narration }] : []),
      { type: "toolCall", name: "bash", arguments: { command: "echo MANGO" } },
    ],
  })
// The three roles message_end fires for. The user's own prompt and the tool's
// output arrive on the identical event as the answer.
const userSaid = (text) => msg({ role: "user", content: [{ type: "text", text }] })
const toolSaid = (text) => msg({ role: "toolResult", content: [{ type: "text", text }] })
// A failed attempt. Recorded live against a dead provider: content is EMPTY,
// and the marker is on the envelope.
const failed = () =>
  msg({ role: "assistant", stopReason: "error", errorMessage: "Connection error.", content: [] })
// The human pressed Esc. Recorded live: one of these, then agent_settled.
const aborted = (text = "") =>
  msg({
    role: "assistant",
    stopReason: "aborted",
    content: text ? [{ type: "text", text }] : [],
  })

// A fresh adapter instance per case, so one case's debounce state cannot leak
// into the next and make a later assertion pass for the wrong reason.
//
// fire() takes both kinds of signal, because pi delivers `blocked` through a
// WRAPPED UI METHOD and everything else through pi.on(). A [name, event] pair
// is an event; a bare string is one of the dialog signals, so a fixture can
// place a dialog in the recorded order relative to the events around it.
const OPEN = "\0dialogOpen"
const CLOSE = "\0dialogClose"
const fresh = () => {
  if (existsSync(log)) rmSync(log)
  const adapter = RoostState()
  const fire = async (...signals) => {
    for (const s of signals) {
      if (s === OPEN) await adapter.dialogOpen()
      else if (s === CLOSE) await adapter.dialogClose()
      else await adapter.event(s[0], s[1])
    }
  }
  fire.adapter = adapter
  return fire
}

const START = ["agent_start"]
// agent_end closes a low-level RUN, not a turn, and every fixture below
// replays it where pi emits it. It is deliberately unmapped by the adapter --
// see the T-pi-1 block -- and leaving it out of the fixtures would hide that,
// which is spec 6's "a fixture replays the whole recorded turn" rule.
const END = ["agent_end"]
const TS = ["turn_start"]
const TE = ["turn_end"]
const SETTLED = ["agent_settled"]
const ended = (message) => ["message_end", message]

// --- the states --------------------------------------------------------------

let fire = fresh()
await fire(START)
check(calls(), "working", "agent_start reports working")
check(envNames().every((n) => n === "pi"), true, "roost is called with ROOST_AGENT_NAME=pi")

// --- T-pi-1: agent_settled, never agent_end ---------------------------------
//
// pi's own docs say "use agent_settled for status integrations", and a live
// run against a dead provider is why. Recorded on 0.81.1 with the provider
// baseUrl pointed at a port that was bound and released, so nothing is
// listening — the whole run, trailing events included:
//
//    1  __factory          TMUX_PANE=%114
//    2  session_start      mode=print hasUI=false
//    5  before_agent_start
//    6  agent_start                                <- attempt 1
//    7  turn_start
//    9  message_end  role=user
//   10  message_end  role=assistant stopReason=error errorMessage="Connection error." content=[]
//   11  turn_end
//   12  agent_end                                  <- NOT the end of the turn
//   13  agent_start                                <- attempt 2
//   ...
//   30  agent_end                                  <- attempt 4's end
//   31  agent_settled                              <- exactly one, the true end
//   32  session_shutdown
//
// 4 agent_end, 1 agent_settled. An adapter wired to agent_end would flap the
// badge four times and stamp `done` three times while pi was still retrying.
const DEAD_PROVIDER = [
  START, TS, ended(userSaid("Say exactly: BANANA")), ended(failed()), TE, END,  // attempt 1
  START, TS, ended(failed()), TE, END,                                          // attempt 2
  START, TS, ended(failed()), TE, END,                                          // attempt 3
  START, TS, ended(failed()), TE, END,                                          // attempt 4
  SETTLED,
]

fire = fresh()
await fire(...DEAD_PROVIDER)
check(calls(), "working,error", "a turn that died on the provider ends error, and its four retries are one working")

// The other half, and the more important one to keep green: nothing may leave
// the pane stuck. pi emits no trailing idle after a failure — unlike opencode
// (#13) and copilot — so there is no suppression latch in the adapter, and
// this fixture is what would notice if one were ever added and got stuck.
fire = fresh()
await fire(...DEAD_PROVIDER, START, TS, ended(said("recovered")), TE, END, SETTLED)
check(calls(), "working,error,working,done", "the very next healthy turn still reaches done after a dead one")

fire = fresh()
await fire(...DEAD_PROVIDER, ...DEAD_PROVIDER)
check(calls(), "working,error,working,error", "a second dead turn badges working at its start and error again at its end")

// The recovery case the error path must NOT catch: pi retried and then
// SUCCEEDED, so the turn finished. Reading the LAST assistant stopReason at
// settle rather than remembering that a failure was ever seen is what keeps
// this green — and it is why there is no retry counter here at all, unlike
// opencode's RETRY_THRESHOLD.
fire = fresh()
await fire(START, TS, ended(failed()), TE, END, START, TS, ended(failed()), TE, END, START, TS, ended(said("it worked in the end")), TE, END, SETTLED)
check(calls(), "working,done", "a turn that retried and then SUCCEEDED reports done, not error")
check(replies().join("|"), "it worked in the end", "...and publishes the answer it eventually gave")

// A turn that errors has no answer, and holding the half-built one would let it
// attach to the NEXT turn — a stale reply served as if it were fresh.
fire = fresh()
await fire(START, TS, ended(said("half an answer")), ended(failed()), TE, END, SETTLED, START, TS, TE, END, SETTLED)
check(replies().join("|"), "", "a turn that ends in error publishes no reply, and does not leak it into the next turn")

// --- T-pi-2: an abort is not an error ---------------------------------------
//
// Recorded live on 0.81.1: a long turn, Escape pressed six seconds in.
//
//   agent_start
//   message_end  role=user
//   message_end  role=assistant stopReason="aborted"
//   agent_settled
//
// stopReason "aborted" is pi's word for the human pressing Esc, and it sits in
// the same field as "error". Badging it `error` fires a desktop notification
// about someone's own keystroke and calls it a crash. spec §1 settles this the
// same way for opencode's MessageAbortedError: the turn is over and there is
// nothing to fix, so it is `done`.
fire = fresh()
await fire(START, TS, ended(userSaid("Write a very long essay about tmux.")), ended(aborted()), TE, END, SETTLED)
check(calls(), "working,done", "the human pressing Esc ends done, not error — an abort is not a crash")

// And an abort publishes no reply. Whatever half-sentence the model had got
// out is not an answer, and stopReason is the only thing that separates it
// from one.
fire = fresh()
await fire(START, TS, ended(aborted("Tmux is a terminal multiplex")), TE, END, SETTLED)
check(verbs(), "state,state", "an aborted half-sentence is not published as the turn's reply")

// pi's remaining stopReason. "length" means the model ran out of output budget
// mid-answer — the turn still finished and what it said is still its answer,
// which is why the reply filter is an allow list of {stop, length} rather than
// a deny list of the three that are not answers.
fire = fresh()
await fire(START, TS, ended(msg({ role: "assistant", stopReason: "length", content: [{ type: "text", text: "a truncated answ" }] })), TE, END, SETTLED)
check(calls(), "working,done", "a turn cut off by the output budget still reports done")
check(replies().join("|"), "a truncated answ", "...and what it managed to say is still the reply")

// --- the debounce ------------------------------------------------------------
//
// pi opens one agent_start per LOW-LEVEL run: a retry is a new one, and so is
// an auto-compaction retry and a queued follow-up. Four of them in the dead
// capture above. Without the debounce that is one process spawn per attempt
// for a state that never changed.
fire = fresh()
await fire(START, START, START)
check(calls(), "working", "repeated agent_start events are debounced to one call")

fire = fresh()
await fire(["turn_start"], ["turn_end"], ["tool_call"], ["message_update"], ["context"], ["session_shutdown"], ["model_select"])
check(calls(), "", "unmapped events produce no call at all")

// The trap stated on its own, so that "simplifying" the adapter onto the event
// pi's own lifecycle diagram draws at the end of an agent run fails here
// rather than in the field. agent_end closes a RUN; the turn may still retry.
fire = fresh()
await fire(START, TS, ended(said("BANANA")), TE, END)
check(calls(), "working", "agent_end does not end the turn — the pane stays working until agent_settled")
check(verbs(), "state", "...and nothing is published on it either")

// --- the reply channel --------------------------------------------------------
//
// Recorded live on 0.81.1 (granite4.2:3b over ollama), one prompt that needed a
// tool, with a permission gate in the way. The shape that matters is the FIRST
// assistant message_end: pi announces a tool-calling turn through the same
// event as an answer, and tells them apart by stopReason.
//
//   agent_start
//   message_end  role=user        text="Use the bash tool to run exactly: echo MANGO"
//   message_end  role=assistant   stopReason=toolUse   text=""
//   __dialog_open   confirm                            <- the gate
//   __dialog_close  confirm                            <- the human pressed Enter
//   message_end  role=toolResult  text="MANGO\n"
//   message_end  role=assistant   stopReason=stop      text="The command `echo MANGO` has been executed…"
//   agent_settled
const TOOL_TURN = [
  START,
  TS,
  ended(userSaid("Use the bash tool to run exactly: echo MANGO")),
  ended(calling()),
  OPEN,
  CLOSE,
  ended(toolSaid("MANGO\n")),
  TE,
  TS,
  ended(said("The command `echo MANGO` has been executed and produced:\n\n```\nMANGO\n```")),
  TE,
  END,
  SETTLED,
]
fire = fresh()
await fire(...TOOL_TURN)
check(
  replies().join("|"),
  "The command `echo MANGO` has been executed and produced:\n\n```\nMANGO\n```",
  "the answering assistant message is published as the reply"
)
check(verbs(), "state,state,state,reply,state", "the reply is published BEFORE done is reported")
check(calls(), "working,blocked,working,done", "publishing a reply does not disturb the state machine")

// The model's own reasoning arrives on the SAME event, in the same parts
// array, as a `thinking` part. Recorded live on granite4.2:3b: a plain "Say
// exactly: BANANA" turn came back with partTypes ["thinking","text"].
// Publishing it posts the model's thinking as its answer.
fire = fresh()
await fire(START, TS, ended(said("BANANA", { thinking: "The user wants me to echo one word. I will." })), TE, END, SETTLED)
check(replies().join("|"), "BANANA", "the model's thinking part is not published as its answer")

// A tool-calling message must not be published even when it DOES narrate. The
// answer comes after the tool returns; publishing the narration serves a
// confident wrong answer to a coordinating agent.
fire = fresh()
await fire(START, TS, ended(calling("Let me check that for you.")), ended(toolSaid("ok")), TE, TS, ended(said("the answer is 42")), TE, END, SETTLED)
check(replies().join("|"), "the answer is 42", "a narrating tool-call message is not the reply — the message that ends the turn is")

// The half of that which is invisible when the turn goes on to answer
// properly: here the narration is the ONLY text the turn ever produced,
// because the model finished with a thinking-only message. Taking "the last
// assistant text" instead of "the last text of a message that ENDED the turn"
// publishes "Let me check that for you." as the agent's answer, and a
// coordinating agent reads that as the result.
fire = fresh()
await fire(START, TS, ended(calling("Let me check that for you.")), ended(toolSaid("ok")), TE, TS, ended(said("", { thinking: "nothing more to add" })), TE, END, SETTLED)
check(verbs(), "state,state", "a turn whose only text was narration beside a tool call publishes nothing at all")

// The user's own prompt and the tool's output arrive on the identical event.
// Only `role` separates them from the answer.
fire = fresh()
await fire(START, TS, ended(userSaid("what is 6 times 7?")), ended(toolSaid("42")), ended(said("42")), TE, END, SETTLED)
check(replies().join("|"), "42", "the user's prompt and the tool result are not published as the agent's reply")
check(verbs(), "state,reply,state", "...and neither fires a reply call of its own")

// Several answering messages across one prompt: keep the LAST, which is also
// what Claude Code's last_assistant_message returns for the same shape, so
// `roost read` means one thing regardless of which harness produced the text.
fire = fresh()
await fire(START, TS, ended(said("first, a partial thought")), TE, TS, ended(said("actually, the answer is 42")), TE, END, SETTLED)
check(replies().join("|"), "actually, the answer is 42", "with several answering messages, the last one is the reply")

// An empty final message publishes nothing rather than an empty reply. An empty
// string stored in @roost-reply reads as present and is returned as the agent's
// answer.
fire = fresh()
await fire(START, TS, ended(said("", { thinking: null })), TE, END, SETTLED)
check(verbs(), "state,state", "an answering message with no text produces no reply call")

fire = fresh()
await fire(START, TS, TE, END, SETTLED)
check(verbs(), "state,state", "a settle with no message at all produces no reply call")

// A new turn drops whatever the previous one published, so one turn's text can
// never be served as the next turn's reply. The reset is on agent_start.
fire = fresh()
await fire(START, TS, ended(said("first turn")), TE, END, SETTLED, START, TS, TE, END, SETTLED)
check(replies().join("|"), "first turn", "a second turn with no answer of its own publishes nothing")
check(verbs(), "state,reply,state,state,state", "...and fires no second reply call")

// A multi-line reply survives argv intact. This is most of the point of
// recording a reply instead of scraping a full-screen TUI.
fire = fresh()
await fire(START, TS, ended(said("PLUM-ONE\nPLUM-TWO")), TE, END, SETTLED)
check(replies().join("|"), "PLUM-ONE\nPLUM-TWO", "a multi-line reply is passed through unchanged")

// --- `blocked`: a dialog, and only while a turn is stuck behind it -----------
//
// pi ships NO permission prompts — docs/usage.md:309 lists them among the
// things it intentionally omits — so on a stock install nothing here ever
// fires. It fires the moment a user installs a gate of their own, and pi ships
// examples/extensions/permission-gate.ts as the pattern to copy.
fire = fresh()
await fire(START, TS, OPEN, CLOSE, TE, END, SETTLED)
check(calls(), "working,blocked,working,done", "a dialog during a turn walks working -> blocked -> working -> done")

// The guard that makes `blocked` mean what spec §1 says it means: a human is
// being waited on AND THE AGENT CANNOT PROCEED. An extension COMMAND that asks
// a question while pi is idle waits on a human too, but no turn is stuck
// behind it — and `working` is the badge `roost wait-done` blocks on, so
// badging it would hang a waiter on a pane that is not working, and ping the
// human's desktop about a dialog they opened themselves.
fire = fresh()
await fire(OPEN, CLOSE)
check(calls(), "", "a dialog raised while no turn is running does not badge the pane")

fire = fresh()
await fire(START, TS, TE, END, SETTLED, OPEN, CLOSE)
check(calls(), "working,done", "...and one raised after the turn ended leaves the pane on done")

// A gate is free to ask twice — confirm, then input for a reason. The inner
// dialog closing must not un-block a pane whose outer dialog is still up.
fire = fresh()
await fire(START, TS, OPEN, OPEN, CLOSE, CLOSE, TE, END, SETTLED)
check(calls(), "working,blocked,working,done", "nested dialogs block once and release once, when the LAST one closes")

// The mirror risk, and the one that would be worse: a pane stuck on `blocked`
// forever. The counter is decremented in a `finally`, and it is clamped at
// zero so a stray close cannot drive it negative and make the next real dialog
// need two opens to register.
fire = fresh()
await fire(START, TS, CLOSE, CLOSE, OPEN, CLOSE, TE, END, SETTLED)
check(calls(), "working,blocked,working,done", "a stray dialog close cannot desensitise the counter — the next real dialog still blocks")

// --- T-pi-3: /reload re-uses pi's UI object, and a naive wrap stacks ---------
//
// ctx.ui is a getter returning ONE SHARED object for every extension
// (dist/core/extensions/runner.js:458). That sharing is what lets roost see a
// dialog another extension raised — and it means the wrap outlives the
// extension instance that installed it.
//
// Measured live on 0.81.1 with a wrap-once-per-session_start probe: /reload,
// then one dialog.
//
//   {"ev":"session_shutdown","mode":"tui"}
//   {"ev":"session_start","mode":"tui","hasUI":true,"sameObj":true}
//   {"ev":"__patched"}
//   {"ev":"__dialog_open","m":"confirm","depth":1}   <- the live instance
//   {"ev":"__dialog_open","m":"confirm","depth":1}   <- and the SHUT-DOWN one
//
// Two `roost state blocked` calls for one dialog, and one more per reload
// after that. A plain "already wrapped, skip" flag has the mirror bug, and it
// is the worse of the two: the surviving wrapper belongs to the dead instance,
// so the live adapter never hears about a dialog again and `blocked` silently
// stops working.
//
// fakeUI is pi's shared object, reduced to the four blocking dialogs. `calls`
// counts how many times the ORIGINAL was reached, which is the half that
// proves roost never swallowed or duplicated the human's dialog.
const fakeUI = () => {
  const seen = []
  return {
    seen,
    confirm: async (title) => { seen.push(`confirm:${title}`); return true },
    select: async () => { seen.push("select"); return "a" },
    input: async () => { seen.push("input"); return "typed" },
    editor: async () => { seen.push("editor"); return "edited" },
    notify: () => { seen.push("notify") },
  }
}

if (existsSync(log)) rmSync(log)
let ui = fakeUI()
const first = RoostState()
first.attach(ui)
await first.event("agent_start")
check(await ui.confirm("Run bash?", "echo MANGO"), true, "the wrapper returns the dialog's own answer unchanged — roost observes, it never decides")
check(calls(), "working,blocked,working", "a wrapped dialog badges the pane blocked, and releases it when the human answers")
check(ui.seen.join(","), "confirm:Run bash?", "...and the human's real dialog was opened exactly once")

// The reload: a second instance attaches to the SAME ui object.
const second = RoostState()
second.attach(ui)
await second.event("agent_start")
if (existsSync(log)) rmSync(log)
await ui.confirm("Run bash again?", "echo PLUM")
check(calls(), "blocked,working", "after a /reload one dialog produces ONE blocked and ONE release, not two of each")
check(ui.seen.length, 2, "...and the human's dialog is still opened exactly once, not wrapped twice")

// The half a single skip-if-wrapped flag gets wrong: the surviving wrapper
// must talk to the LIVE instance, not the shut-down one whose counters are
// frozen. `second` is the one that reported working above, so the badge could
// only have come from it.
if (existsSync(log)) rmSync(log)
await second.event("agent_settled")
check(calls(), "done", "the instance that survives the reload is the one driving the badge")

// All four dialog kinds are wrapped, and each returns its own value.
if (existsSync(log)) rmSync(log)
ui = fakeUI()
const third = RoostState()
third.attach(ui)
await third.event("agent_start")
const got = [await ui.select(), await ui.input(), await ui.editor()]
check(got.join(","), "a,typed,edited", "select, input and editor are wrapped too, and each returns its own answer")
check(calls(), "working,blocked,working,blocked,working,blocked,working", "each of them blocks the pane and releases it")

// notify is fire-and-forget: nobody waits on it, so it must not badge.
if (existsSync(log)) rmSync(log)
ui.notify("hello")
check(calls(), "", "notify is not a dialog and does not badge the pane")

// A dialog that throws — the human pressed ctrl+c, or the gate blew up — must
// still release the pane. The release is in a `finally` for this case: a pane
// stuck on `blocked` forever is worse than the bug it would be fixing.
if (existsSync(log)) rmSync(log)
ui = fakeUI()
ui.confirm = async () => { throw new Error("cancelled") }
const fourth = RoostState()
fourth.attach(ui)
await fourth.event("agent_start")
let dialogThrew = ""
try { await ui.confirm("x", "y") } catch (e) { dialogThrew = String(e.message) }
check(dialogThrew, "cancelled", "a dialog that throws still throws to its own caller")
check(calls(), "working,blocked,working", "...and the pane is released anyway")

// --- T1: a sub-agent runs as a SEPARATE PI PROCESS on the same pane ----------
//
// pi has no built-in sub-agents, but its shipped examples/extensions/subagent/
// implements them by spawning `pi --mode json -p --no-session`
// (index.ts:294, spawn at :335). A child inherits this pane's environment, so
// it inherits $TMUX_PANE, and it loads the same GLOBAL extensions — this file
// among them. Measured live on 0.81.1, running exactly that command from
// inside roost pane %114:
//
//   {"ev":"__factory","pid":9307,"TMUX_PANE":"%114","TMUX":"…/roost,44502,9",
//    "argv":["…/pi","--mode","json","-p","--no-session","Say exactly: CHILD"]}
//   {"ev":"session_start","pid":9307,"mode":"json","hasUI":false}
//   {"ev":"agent_start","pid":9307,"mode":"json","hasUI":false}
//   {"ev":"agent_settled","pid":9307,"mode":"json","hasUI":false}
//
// Ungated, every sub-agent badges its PARENT'S pane — `working` when it
// starts, `done` when it finishes while the parent is still working — and
// publishes its own answer as the pane's reply. That is opencode's T1 in a
// harsher form: two OS processes, so no in-process filter can see across them.
//
// This drives the DEFAULT EXPORT rather than RoostState(), because the gate
// lives in what gets registered with pi, and a fixture against the state
// machine alone would pass with the gate deleted.
const fakePi = () => {
  const handlers = new Map()
  const pi = { on: (name, fn) => handlers.set(name, fn) }
  const emit = async (name, event, ctx) => {
    const fn = handlers.get(name)
    if (fn) await fn(event, ctx)
  }
  return { pi, emit, handlers }
}
const CHILD = { mode: "json", hasUI: false, ui: fakeUI() }
const PARENT = { mode: "tui", hasUI: true, ui: fakeUI() }

if (existsSync(log)) rmSync(log)
let h = fakePi()
install(h.pi)
await h.emit("session_start", { reason: "startup" }, CHILD)
await h.emit("agent_start", {}, CHILD)
await h.emit("message_end", said("hello-from-subagent"), CHILD)
await h.emit("agent_settled", {}, CHILD)
check(verbs(), "", "a sub-agent's own pi process badges nothing and publishes nothing on its parent's pane")

// The same events with a UI attached — a human's own pane — must still work,
// or the gate would be a mute button.
if (existsSync(log)) rmSync(log)
h = fakePi()
install(h.pi)
await h.emit("session_start", { reason: "startup" }, PARENT)
await h.emit("agent_start", {}, PARENT)
await h.emit("message_end", said("the parent's own answer"), PARENT)
await h.emit("agent_settled", {}, PARENT)
check(calls(), "working,done", "a pane with a human attached to it is still badged")
check(replies().join("|"), "the parent's own answer", "...and still publishes its reply")

// session_start must not badge. spec §1: `idle` is a default, not a report —
// tmux/roost.conf leaves @agent_state with no global default, so an unstamped
// pane already renders as idle and stamping it spends a process spawn to say
// the same thing. Its handler exists only to install the dialog wrap.
if (existsSync(log)) rmSync(log)
h = fakePi()
install(h.pi)
const startUI = fakeUI()
await h.emit("session_start", { reason: "startup" }, { mode: "tui", hasUI: true, ui: startUI })
check(verbs(), "", "session_start reports no state — an adapter with nothing to say says nothing")
check(typeof startUI.confirm === "function", true, "...but it does install the dialog wrap")

// A missing roost must leave the pane unbadged, never throw into pi's event
// loop — including out of a wrapped dialog, which is a place a human is
// waiting. PATH without the shim is the honest way to stage that.
process.env.PATH = "/nonexistent-roost-dir"
let threw = ""
try {
  const a = RoostState()
  const u = fakeUI()
  a.attach(u)
  await a.event("agent_start")
  await u.confirm("x", "y")
  await a.event("message_end", said("hi"))
  await a.event("agent_settled")
} catch (e) {
  threw = String(e && e.message ? e.message : e)
}
check(threw, "", "a missing roost on PATH does not throw into pi")
process.env.PATH = `${dir}:${REAL_PATH}`

rmSync(dir, { recursive: true, force: true })
console.log(`  (${pass} passed, ${fail} failed in the pi extension harness)`)
process.exit(0)

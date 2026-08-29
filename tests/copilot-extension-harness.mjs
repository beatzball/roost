// Fire synthetic GitHub Copilot CLI events at adapters/copilot/extension.mjs and
// assert which `roost` calls come out, with a recording shim standing in for
// roost on PATH. Runs offline, in milliseconds, with no model call.
//
// Prints "  PASS:" / "  FAIL:" lines so tests/run.sh counts them like any bash
// test, and always exits 0 — run.sh treats a non-zero exit as a crash.
//
// The shim, the column layout and the \x1e newline escape are lifted verbatim
// from tests/opencode-plugin-harness.mjs, on purpose: two adapters asserting
// the same contract should fail the same way, and a reader who has read one
// file should not have to learn a second set of helpers to read the other.
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

const { RoostState } = await import(join(HERE, "..", "adapters", "copilot", "extension.mjs"))

// A fresh adapter instance per case, so one case's debounce state cannot leak
// into the next and make a later assertion pass for the wrong reason.
//
// fire() takes both kinds of signal, because Copilot delivers `blocked`
// through a CALLBACK and everything else through the event bus. A bare string
// stands for "the onPermissionRequest handler was invoked here", so a fixture
// can place it in the recorded order relative to the events around it — which
// is the whole point of the permission cases below.
const PERMISSION_REQUEST = "\0onPermissionRequest"
const fresh = () => {
  if (existsSync(log)) rmSync(log)
  const adapter = RoostState()
  const results = []
  const fire = async (...signals) => {
    for (const s of signals) {
      if (s === PERMISSION_REQUEST) results.push(await adapter.onPermissionRequest({ kind: "shell" }))
      else await adapter.event(s)
    }
  }
  fire.results = results
  return fire
}

// --- event constructors, shaped exactly as copilot 1.0.81 emits them ---------
//
// Every event is {type, data, id, timestamp, parentId}, and a SUB-AGENT's event
// carries one extra key: `agentId`. That single key is the whole subagent
// filter — see the T1 block below for the capture that establishes it.
const ev = (type, data = {}) => ({ type, data })
// The same event as it arrives from a sub-agent. `agentId` is the recorded one.
const sub = (event) => ({ ...event, agentId: SUBAGENT })
// The final answer of a model turn: content, and no tool requests.
const said = (content, messageId = "msg") => ev("assistant.message", { messageId, content, toolRequests: [] })
// A model turn that is calling a tool instead of answering. Live copilot emits
// content "" with a populated toolRequests here; both halves are recorded.
const calling = (messageId = "msg") =>
  ev("assistant.message", { messageId, content: "", toolRequests: [{ toolCallId: "tc_1" }] })

// Recorded ids, kept verbatim, so the shapes are the ones copilot actually
// emits rather than ones invented for this file.
const SUBAGENT = "7ec6d39a-acf6-478b-a352-98a17051c7f1"

// --- the five states --------------------------------------------------------

let fire = fresh()
await fire(ev("assistant.turn_start"))
check(calls(), "working", "assistant.turn_start reports working")
check(envNames().every((n) => n === "copilot"), true, "roost is called with ROOST_AGENT_NAME=copilot")

// copilot opens a NEW assistant.turn_start after every tool call, so one user
// prompt produces several. Recorded on 1.0.81, a single `rm` prompt:
//   06:40:20.338  assistant.turn_start   <- the model's first turn
//   06:40:53.773  assistant.turn_start   <- after the tool returned
// Without the debounce that is one process spawn per model turn for a state
// that never changed.
fire = fresh()
await fire(ev("assistant.turn_start"), ev("assistant.turn_start"), ev("assistant.turn_start"))
check(calls(), "working", "repeated assistant.turn_start events are debounced to one call")

fire = fresh()
await fire(ev("assistant.turn_start"), PERMISSION_REQUEST, ev("permission.completed"), ev("session.idle"))
check(calls(), "working,blocked,working,done", "a full permission turn walks working -> blocked -> working -> done")

// roost must NEVER decide a permission. The SDK's observe-only return value is
// {kind:"no-result"}; anything else answers a dialog that exists to ask the
// human. Verified live: with this returned, the TUI dialog stayed on screen and
// the human still chose (see the T5 block below).
check(JSON.stringify(fire.results), '[{"kind":"no-result"}]', "onPermissionRequest returns the SDK pass-through and never decides")

// ask_user is the OTHER way a copilot turn waits on a human, and it is a plain
// event — no handler gates it. Recorded on 1.0.81 (`d.log`):
//   06:44:58.684  elicitation.requested   <- the choice list opens
//   06:47:10.703  elicitation.completed   <- 2m12s later, the human answered
fire = fresh()
await fire(ev("assistant.turn_start"), ev("elicitation.requested"), ev("elicitation.completed"), ev("session.idle"))
check(calls(), "working,blocked,working,done", "an ask_user elicitation also blocks the pane, and completing it releases it")

fire = fresh()
await fire(ev("assistant.turn_start"), ev("session.error", { errorType: "query", message: "Could not connect" }))
check(calls(), "working,error", "session.error reports error")

fire = fresh()
await fire(ev("session.background_tasks_changed"), ev("model.call_start"), ev("assistant.reasoning"), ev("hook.start"), ev("model.turn_retry"))
check(calls(), "", "unmapped events produce no call at all")

// --- T5: the permission handler is what makes `blocked` reachable at all -----
//
// `permission.requested` is declared in copilot's shipped
// schemas/session-events.schema.json AND documented in its shipped SDK docs
// under "Top 10 Most Useful Event Types". An adapter written from those two
// sources subscribes to it and never fires.
//
// Measured twice, on 1.0.81, with `rm -f deleteme.txt` and the TUI dialog open
// on screen both times:
//
//   probe with session.on() ONLY, no handler registered (`b.log`):
//     ... tool.execution_start, then 6x session.background_tasks_changed ...
//     permission.requested count: 0
//     the ONLY permission event of the whole run was one permission.completed,
//     AFTER the human answered — the badge would light at the exact moment the
//     human stopped being blocked.
//
//   probe with onPermissionRequest registered (`a.log`):
//     06:40:36.358  EVENT tool.execution_start
//     06:40:36.358  HOOK  onPreToolUse
//     06:40:36.376  ON_PERMISSION_REQUEST  kind=shell   <- badge -> blocked
//     06:40:36.376  EVENT permission.requested          <- and now it fires too
//                   ... dialog on screen, human thinking for 17s ...
//     06:40:53.725  EVENT permission.completed          <- badge -> working
//
// So both directions have to be asserted, and this is the pair. Getting it
// wrong in the safe direction means the badge never says `blocked`; getting it
// wrong in the unsafe direction means roost answers a dialog meant for a human.
fire = fresh()
await fire(ev("assistant.turn_start"), ev("permission.requested"), ev("session.idle"))
check(calls(), "working,done", "the permission.requested EVENT alone never badges blocked — the handler is the signal, and this fixture is what stops someone 'simplifying' to the event")

// --- the startup consent arrives as a permission.completed ------------------
//
// Copilot asks the human to approve the extension's elevated permissions, and
// their answer is announced on the bus as a permission.completed — recorded on
// 1.0.81 in the same millisecond as the join, before any turn exists:
//
//   06:40:12.278  JOINED
//   06:40:12.278  EVENT permission.completed  {"requestId":"e50ca450-...",
//                                              "result":{"kind":"approved"}}
//
// An unconditional `permission.completed -> working` therefore badges a pane
// that has not been asked to do anything. `working` is the badge `roost
// wait-done` blocks on, so a fresh pane would hang a waiter until its first
// real turn ended.
//
// The clear is scoped to the state it exists to clear: permission.completed
// means "the human answered", and the only thing that needs answering is our
// own `blocked`.
fire = fresh()
await fire(ev("permission.completed", { requestId: "e50ca450", result: { kind: "approved" } }))
check(calls(), "", "the extension's own startup consent does not badge a pane that has not started a turn")

// --- T1: a sub-agent's events arrive on the same bus ------------------------
//
// Copilot's `task` tool does NOT open a child session the way opencode does —
// the sub-agent runs on the SAME session, and its events are told apart by one
// extra envelope key, `agentId`. Recorded live on 1.0.81 (`c.log`), a turn that
// delegated `echo hello-from-subagent`, with the capture's line numbers:
//
//    16  06:41:46.885  user.message                                (parent)
//    22  06:41:46.889  assistant.turn_start                        (parent)
//    31  06:42:03.913  assistant.message   "I'll start a background task…"
//    39  06:42:03.940  subagent.started    agentId=7ec6d39a-…
//    49  06:42:03.959  user.message        agentId=7ec6d39a-…      (the child)
//    51  06:42:03.962  assistant.turn_start agentId=7ec6d39a-…
//    59  06:42:20.900  assistant.message   agentId=7ec6d39a-…  content=""
//   102  06:42:22.018  assistant.message   agentId=7ec6d39a-…  "hello-from-subagent"
//   118  06:42:22.029  assistant.turn_start agentId=7ec6d39a-…
//   119  06:42:22.029  assistant.turn_end   agentId=7ec6d39a-…
//   120  06:42:22.029  subagent.completed   agentId=7ec6d39a-…
//   130  06:42:23.302  assistant.message   "The sub-agent printed: …"   (parent)
//   138  06:42:23.321  assistant.idle                              (parent)
//   139  06:42:23.322  session.idle                                (parent)
//
// Two things in that capture decide the design, and they are why this filter is
// one line instead of opencode's session set:
//
//   1. `agentId` is present on EVERY sub-agent event and absent from EVERY
//      parent event. Counted over the whole capture, both directions.
//   2. The sub-agent emits NO session.idle and NO assistant.idle. So unlike
//      opencode, copilot's badge is not at risk of an early `done` — the risk
//      is entirely to the REPLY, at line 102, where the child's own answer
//      would otherwise be published as the pane's.
//
// Filtering by IGNORING an agentId-bearing event, rather than by tracking which
// sub-agents are still running, is deliberate and is spec §5 T1's rule: a
// counter that fails to reach zero leaves the pane muted for the rest of its
// life, and there is nothing here that can get stuck.
fire = fresh()
await fire(
  ev("assistant.turn_start"),
  said("I'll start a background task agent using the task tool.", "6e351715"),
  sub(ev("subagent.started")),
  sub(ev("user.message", { content: "run the bash command…" })),
  sub(ev("assistant.turn_start")),
  sub(said("", "6503d4ea")),
  sub(said("hello-from-subagent", "8044cf1a")),
  sub(ev("assistant.turn_start")),
  sub(ev("assistant.turn_end")),
  sub(ev("subagent.completed")),
  said("The sub-agent printed:\n\n```\nhello-from-subagent\n```", "69b1fa69"),
  ev("assistant.idle"),
  ev("session.idle")
)
check(replies().join("|"), "The sub-agent printed:\n\n```\nhello-from-subagent\n```", "a sub-agent's answer is not published as the pane's reply")
check(calls(), "working,done", "...and the sub-agent's turn events do not disturb the badge")

// The half that matters when the parent adds nothing of its own. Publishing the
// sub-agent's text here would be a confident wrong answer; publishing nothing
// leaves `roost read` falling back to the screen with its notice, which is the
// honest outcome — the pane's own agent did not answer.
fire = fresh()
await fire(
  ev("assistant.turn_start"),
  sub(ev("subagent.started")),
  sub(said("hello-from-subagent", "8044cf1a")),
  sub(ev("subagent.completed")),
  ev("session.idle")
)
check(replies().join("|"), "", "a turn where only the sub-agent spoke publishes no reply")
check(verbs(), "state,state", "...and fires no reply call at all")

// The mute is scoped to the sub-agent's own events, not switched on for good
// once a sub-agent has run — or the pane would never publish a reply again.
fire = fresh()
await fire(
  ev("assistant.turn_start"),
  sub(ev("subagent.started")),
  sub(said("hello-from-subagent", "8044cf1a")),
  sub(ev("subagent.completed")),
  ev("session.idle"),
  ev("assistant.turn_start"),
  said("a later, unrelated turn", "aaaa"),
  ev("session.idle")
)
check(replies().join("|"), "a later, unrelated turn", "the pane can still publish a reply after a sub-agent has run")

// The one thing a sub-agent DOES speak for the pane with. Its permission dialog
// is answered by the human sitting at this pane, so the badge has to say so.
//
// This survives the agentId filter by construction rather than by an exception,
// and the capture is why: a sub-agent's permission signals carry NO agentId.
// Recorded on 1.0.81 (`d.log`), a sub-agent told to run `rm -f subdel.txt`:
//
//   06:44:01.931  EVENT subagent.started      agentId=…
//   06:44:18.979  ON_PERMISSION_REQUEST  kind=shell         (no agentId)
//   06:44:18.979  EVENT permission.requested  _keys=[type,data,id,timestamp,parentId]
//   06:44:30.373  EVENT permission.completed  _keys=[type,data,id,timestamp,parentId]
//
// The handler is a callback, not a bus event, so it has no envelope to filter
// at all — and permission.completed, which clears the badge, was measured
// agentId-free in the sub-agent case too. Had it carried one, the filter would
// have swallowed the clear and pinned the pane on `blocked` for good.
fire = fresh()
await fire(
  ev("assistant.turn_start"),
  sub(ev("subagent.started")),
  PERMISSION_REQUEST,
  ev("permission.completed"),
  sub(ev("subagent.completed")),
  ev("session.idle")
)
check(calls(), "working,blocked,working,done", "a sub-agent's permission dialog still badges the pane blocked, and is still cleared")

// --- T3: the idle that follows an error -------------------------------------
//
// Recorded live on 1.0.81 against an unreachable provider (a port bound and
// released, so nothing is listening), with the capture's line numbers:
//
//   23  06:35:43.357  EVENT assistant.turn_start
//   32  06:35:43.369  HOOK  onErrorOccurred          <- attempt 1 failed
//   34  06:35:44.372  EVENT model.turn_retry
//   43  06:35:44.397  HOOK  onErrorOccurred          <- attempt 2
//   45  06:35:46.401  EVENT model.turn_retry
//   53  06:35:46.418  HOOK  onErrorOccurred          <- attempt 3
//   56  06:35:50.421  EVENT model.turn_retry
//   64  06:35:50.441  HOOK  onErrorOccurred          <- attempt 4
//   67  06:35:58.444  EVENT model.turn_retry
//   75  06:35:58.461  HOOK  onErrorOccurred          <- attempt 5
//   78  06:36:06.463  EVENT model.turn_retry
//   86  06:36:06.487  HOOK  onErrorOccurred          <- attempt 6, the last
//   92  06:36:06.489  HOOK  onSessionEnd  reason="error"
//   93  06:36:06.489  EVENT session.error  {"errorType":"query", …}
//   96  06:36:06.489  EVENT assistant.idle           <- unfiltered, this stamped `done`
//   97  06:36:06.490  EVENT session.idle             <- and so did this
//
// Two separate findings live in that one capture.
//
// The first is T3, and it is the same bug opencode shipped in #13: a turn that
// died on the provider still ends, so its trailing idle maps to `done` and the
// pane reports a dead turn as finished. A wrong `done` is the worst wrong badge
// there is — every other one makes you look, and this one makes you stop
// looking.
//
// The second is the reason `error` is wired to session.error and to nothing
// else. Copilot announces a failure on the bus SIX times in this one turn —
// model.call_failure per attempt, five of which it then retried — and fires
// onErrorOccurred alongside each one. An adapter that badges on any of those
// turns the first transient blip into a red pane and a desktop notification.
// Only session.error and model.turn_failed fired exactly once, at the real end.
// This is spec §5 T7 in copilot's clothing: a signal that looks like failure
// and is not evidence the turn is over. Every DEAD_PROVIDER fixture below
// replays the failure events at full strength for that reason.
const DEAD_PROVIDER = [
  ev("assistant.turn_start"),
  ev("model.call_failure"), ev("model.turn_retry"),   // attempt 1 failed, copilot retries
  ev("model.call_failure"), ev("model.turn_retry"),   // attempt 2
  ev("model.call_failure"), ev("model.turn_retry"),   // attempt 3
  ev("model.call_failure"), ev("model.turn_retry"),   // attempt 4
  ev("model.call_failure"), ev("model.turn_retry"),   // attempt 5
  ev("model.call_failure"), ev("model.turn_failed"),  // attempt 6, the last one
  ev("session.error", { errorType: "query", message: "Could not connect to local model provider at http://127.0.0.1:58749/v1." }),
  ev("assistant.idle"),
  ev("session.idle"),
]

fire = fresh()
await fire(...DEAD_PROVIDER)
check(calls(), "working,error", "a turn that died on the provider ends error — its trailing session.idle does not overwrite that with done")

// The other half of the fix, and the more important one to keep green: a badge
// that sticks on error forever is a worse bug than the one above. The exact
// clearing condition is the NEXT turn's assistant.turn_start, and the capture
// proves no event from the same turn can reach it — line 23 is the only
// assistant.turn_start in the whole dead turn, and it is 23 seconds BEFORE the
// session.error at line 93.
fire = fresh()
await fire(...DEAD_PROVIDER, ev("assistant.turn_start"), said("recovered"), ev("session.idle"))
check(calls(), "working,error,working,done", "the very next healthy turn still reaches done — the suppression is released by the turn that follows, not held for the session")

fire = fresh()
await fire(...DEAD_PROVIDER, ...DEAD_PROVIDER)
check(calls(), "working,error,working,error", "a second dead turn badges working at its start and error again at its end, rather than sitting silently on the first turn's error")

// Repeated idles after a dead turn must stay suppressed. Copilot emits
// assistant.idle and session.idle back to back, and a badge that a duplicate
// could un-suppress would be a bug that only ever appeared in the field.
fire = fresh()
await fire(...DEAD_PROVIDER, ev("session.idle"), ev("session.idle"))
check(calls(), "working,error", "a repeated session.idle after a dead turn does not leak a done through")

// The recovery case the suppression must NOT catch: retries that then SUCCEED
// are a turn that finished. Keying the suppression on session.error rather than
// on the badge already reading `error` is what keeps this green.
fire = fresh()
await fire(ev("assistant.turn_start"), ev("model.call_failure"), ev("model.turn_retry"), ev("model.call_failure"), ev("model.turn_retry"), said("it worked in the end"), ev("session.idle"))
check(calls(), "working,done", "a turn that retried and then SUCCEEDED still reports done — two model.call_failure events fired on the way and neither is evidence the turn is over")

// The single-blip case, stated on its own because it is the one that would be
// noticed in the field: copilot healed after ONE failed attempt, and a pane
// that flashed red and pinged the desktop for it is worse than no badge.
fire = fresh()
await fire(ev("assistant.turn_start"), ev("model.call_failure"), ev("model.turn_retry"), said("recovered on attempt 2"), ev("session.idle"))
check(calls(), "working,done", "one failed model call that copilot then retried never badges error")

// The second clear, belt and braces: a permission dialog is proof the turn
// reached the model, so whatever the previous turn died of is over.
fire = fresh()
await fire(...DEAD_PROVIDER, PERMISSION_REQUEST, ev("permission.completed"), said("after the dialog"), ev("session.idle"))
check(calls(), "working,error,blocked,working,done", "a permission dialog after a dead turn also releases the error, and that turn can reach done")

// A turn that errors has no answer, and holding the half-built one would let it
// attach to the NEXT turn — a stale reply served as if it were fresh.
fire = fresh()
await fire(ev("assistant.turn_start"), said("half an answer"), ev("model.call_failure"), ev("session.error", { errorType: "query" }), ev("assistant.idle"), ev("session.idle"))
check(replies().join("|"), "", "a turn that errors publishes no reply")

// --- the reply channel ------------------------------------------------------
//
// Recorded on 1.0.81 (`a.log`), one prompt that needed a tool. The shape that
// matters is the FIRST assistant.message: copilot announces a tool-calling turn
// through the same event as an answer, with content "" and a populated
// toolRequests, ~18s before the real reply lands.
//
//   22  06:40:20.338  assistant.turn_start
//   31  06:40:36.337  assistant.message   content=""  toolRequests=[1]
//   40  06:40:36.376  ON_PERMISSION_REQUEST
//   45  06:40:53.725  permission.completed
//   76  06:40:53.773  assistant.turn_start          <- second model turn
//   85  06:40:54.604  assistant.message   content="File removed successfully."  toolRequests=[]
//   93  06:40:54.610  assistant.idle
//   95  06:40:54.611  session.idle
fire = fresh()
await fire(
  ev("assistant.turn_start"),
  calling("6ec31427"),
  PERMISSION_REQUEST,
  ev("permission.completed"),
  ev("assistant.turn_start"),
  said("File removed successfully.", "59b21592"),
  ev("assistant.idle"),
  ev("session.idle")
)
check(replies().join("|"), "File removed successfully.", "the answering assistant.message is published as the reply")
check(verbs(), "state,state,state,reply,state", "the reply is published BEFORE done is reported")
check(calls(), "working,blocked,working,done", "publishing a reply does not disturb the state machine")

// A tool-calling message must not be published even when it DOES narrate. The
// model is free to say "let me check that" while requesting a tool, and that
// sentence is not the turn's answer — the answer comes after the tool returns.
fire = fresh()
await fire(
  ev("assistant.turn_start"),
  ev("assistant.message", { messageId: "m1", content: "let me check that", toolRequests: [{ toolCallId: "tc_1" }] }),
  ev("assistant.turn_start"),
  said("the answer is 42", "m2"),
  ev("session.idle")
)
check(replies().join("|"), "the answer is 42", "a narrating tool-call message is not the reply — the message that requests no tool is")

// Several answering messages across one prompt: keep the LAST, which is also
// what Claude Code's last_assistant_message returns for the same shape, so
// `roost read` means one thing regardless of which harness produced the text.
fire = fresh()
await fire(
  ev("assistant.turn_start"),
  said("first, a partial thought", "m1"),
  said("actually, the answer is 42", "m2"),
  ev("session.idle")
)
check(replies().join("|"), "actually, the answer is 42", "with several answering messages, the last one is the reply")

// An empty final message publishes nothing rather than an empty reply. An empty
// string stored in @roost-reply reads as present and is returned as the agent's
// answer.
fire = fresh()
await fire(ev("assistant.turn_start"), said("", "m1"), ev("session.idle"))
check(verbs(), "state,state", "an empty answering message produces no reply call")

fire = fresh()
await fire(ev("assistant.turn_start"), ev("session.idle"))
check(verbs(), "state,state", "an idle with no text produces no reply call")

// A new turn drops whatever the previous one published, so one turn's text can
// never be served as the next turn's reply.
fire = fresh()
await fire(
  ev("assistant.turn_start"), said("first turn", "m1"), ev("session.idle"),
  ev("assistant.turn_start"), ev("session.idle")
)
check(replies().join("|"), "first turn", "a second turn with no answer of its own publishes nothing")
check(verbs(), "state,reply,state,state,state", "...and fires no second reply call")

// A multi-line reply survives argv intact. This is most of the point of
// recording a reply instead of scraping a full-screen TUI.
fire = fresh()
await fire(ev("assistant.turn_start"), said("PLUM-ONE\nPLUM-TWO", "m1"), ev("session.idle"))
check(replies().join("|"), "PLUM-ONE\nPLUM-TWO", "a multi-line reply is passed through unchanged")

// A missing roost must leave the pane unbadged, never throw into copilot's
// event loop. PATH without the shim is the honest way to stage that.
process.env.PATH = "/nonexistent-roost-dir"
let threw = ""
try {
  const a = RoostState()
  await a.event(ev("assistant.turn_start"))
  await a.onPermissionRequest({ kind: "shell" })
} catch (e) {
  threw = String(e && e.message ? e.message : e)
}
check(threw, "", "a missing roost on PATH does not throw into copilot")
process.env.PATH = `${dir}:${REAL_PATH}`

rmSync(dir, { recursive: true, force: true })
console.log(`  (${pass} passed, ${fail} failed in the copilot extension harness)`)
process.exit(0)

// A stand-in permission gate for tests/live/pi-smoke.sh, and NOT part of the
// adapter.
//
// pi ships no permission prompts -- docs/usage.md:309 lists them among the
// things it intentionally omits -- so on a stock install there is nothing for
// the adapter's `blocked` badge to see. Whether roost should ship a gate of its
// own so pi panes can block like Claude and opencode panes do is a product
// decision for a human, and this file does not make it: it exists so the smoke
// test can prove the mechanism works the moment a user brings their own gate,
// and it lives under tests/ so nothing installs it by accident.
//
// It is deliberately in the shape of pi's own
// examples/extensions/permission-gate.ts, because that is what a user copying
// the documented pattern would end up with -- and the point of the assertion is
// that roost sees ANOTHER extension's dialog, not one it raised itself.
export default function (pi: any) {
  pi.on("tool_call", async (event: any, ctx: any) => {
    if (event?.toolName !== "bash") return
    if (!ctx?.hasUI) return
    const ok = await ctx.ui.confirm("Run bash?", String(event?.input?.command ?? ""))
    if (!ok) return { block: true, reason: "Blocked by the human" }
  })
}

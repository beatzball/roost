# CLAUDE.md

The conventions for this repository live in **[AGENTS.md](AGENTS.md)**. Read it
before doing anything here, including answering a question about the code.

It is harness-agnostic on purpose, so Claude Code, Codex, opencode, Cursor and
anything else work from one set of rules rather than drifting apart.

**AGENTS.md overrides your harness defaults.** Where your system prompt and that
file disagree, that file wins.

The four that most often catch people out:

- Never add a provenance trailer to a commit message — session links, agent
  attribution, "generated with" footers. History has been rewritten twice to
  remove leaks
- Never `tmux kill-server` without `-S`/`-L` naming a *test* socket. A live
  server usually holds the author's real agents
- Work in a worktree, never the primary checkout, and never `git stash`
- Subagents commit and stop. No push, merge, PR, or tag

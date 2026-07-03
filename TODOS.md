# Ibis — TODOs

A running list of deferred work. Reviewed periodically. Each item records what
we want, why we don't have it yet, and what to watch for the unblock.

---

## Cross-agent orientation injection (blocked on upstream)

**What we want:** When Ibis launches an agent into a project, tell the agent — in
its context — that it is running in Ibis and how to use the Ibis tools (open
files, render rich output via `open_content`, propose edits through the review
gate, prefer showing results in Ibis over dumping to the terminal). This should
work for **all** supported agents: Claude, Codex, Antigravity.

**What we have today:** Orientation is injected **only for Claude**, via
`claude --append-system-prompt "<orientation>"` at launch (see
`MCPService.launchCommand` / `agentOrientation` in
`ibis/Models/MCPServerController.swift`). Cross-agent behavioral guidance also
rides in the MCP **tool descriptions**, which every MCP client surfaces to the
model — so Codex/Antigravity still learn what the tools do, just without the
higher-level framing preamble.

**Why we don't have it cross-agent:**

- **MCP `instructions` (the protocol-native channel).** The MCP spec has a
  top-level `instructions` field on the `initialize` result that clients inject
  into context. **SwiftMCP does not support it** — verified against a fresh
  clone: neither `v1.9.0` (what we ship) nor `main` includes `instructions` in
  `InitializeResult` or sets it in the initialize handler. Would require forking
  SwiftMCP (add the field + a `@MCPServer` param) or an upstream PR — and even
  then, whether a given client injects it is client-dependent.
- **Per-agent CLI flag.** Only Claude Code ships `--append-system-prompt`.
  - Codex: no such flag. Open feature requests
    (github.com/openai/codex issues #11588, #11117). Its only channels are
    `AGENTS.md` or an undocumented `-c system_prompt=` that *replaces* (unsafe).
  - Antigravity (`agy`): no such flag either; instructions come via `AGENTS.md`,
    skills, or hooks. `-p` is non-interactive.
- **Writing `AGENTS.md` / `CLAUDE.md`.** Rejected on principle: those are files
  the user authors and checks into git, and a collaborator may not use Ibis.
  Ibis writing config files (`.mcp.json`, `.codex/config.toml`,
  `.agents/mcp_config.json`) is normal IDE behavior; mutating source-controlled
  instruction files the user owns is not, and isn't trustworthy.

**What we're tracking (unblock triggers):**

- SwiftMCP adds `instructions` to `InitializeResult` (watch releases past
  `v1.9.0`). → Emit orientation as MCP server instructions for every client that
  honors it.
- Codex ships `--append-system-prompt` (issues #11588 / #11117). → Add a Codex
  branch to `MCPService.launchCommand`, mirroring Claude.
- Antigravity adds an equivalent flag. → Same.

**Definition of done:** Launching any supported agent from Ibis puts the Ibis
orientation in that agent's context, with no writes to user-authored,
git-tracked files.

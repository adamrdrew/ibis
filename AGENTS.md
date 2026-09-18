# Ibis contributor guidance

Read `CLAUDE.md` completely before changing this project. It is the canonical
architecture, build, testing, style, and hard-won-gotchas guide for every coding
agent, despite its historical filename.

For Codex specifically:

- Use the Ibis MCP tools to keep the human's editor in sync: open requested
  files with `open_file`, show rich reports with `open_content`, and call
  `notify` when work finishes or needs attention.
- When the review tools are exposed, make changes through `propose_patch` or
  `propose_edit`; otherwise use the workspace editing tools normally.
- Prefer the configured Xcode MCP server for builds and diagnostics. If its
  selected tool groups do not expose macOS build actions, use `xcodebuild` from
  the repository root and report that fallback.
- Never edit `ibis.xcodeproj/project.pbxproj` directly. New files are discovered
  automatically by the synchronized root group.

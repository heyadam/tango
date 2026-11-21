# tango for Claude Code

Sketch a screen that lives in your code in tango, play with it, and carry the changes back.

```bash
claude --plugin-dir /path/to/tango/Integrations/claude-code
```

- `/tango:sketch ProfileScreen.swift` builds the screen in the open tango document from your code.
- Change what you like in tango: spacing, colors, and above all how things move.
- `/tango:apply` writes what you changed into the code, for you to review as a diff.

tango must be running, with "Let coding agents control tango" on in Settings. The app never reads your code; the agent does, and the code stays the source of truth.

Codex and other agents: connect the MCP server (`codex mcp add tango --url http://127.0.0.1:47821/mcp`) and ask in words; the server's `get_reference` explains both steps.

---
name: browse
description: Chrome DevTools debugging via haiku subagent — console, network, DOM, screenshots. Isolates expensive MCP responses from main context.
context: fork
agent: browser
background: false
model: haiku
---

# Browse — Chrome DevTools Debugging

Debug frontend issues using Chrome DevTools MCP in an isolated forked context.

## How It Works

The `chrome-devtools` MCP is **not registered**. It is declared inline in `agents/browser.md`, so it starts when this skill's forked `browser` subagent starts and stops when it returns: idle sessions carry no `npx` + `node` pair (~124 MiB each). Tool schemas are deferred; load them via ToolSearch. The fork also keeps MCP responses (~5-20k tokens for screenshots, DOM, network) out of the main thread.

## Available Tools

Load tools on demand via ToolSearch, e.g. `ToolSearch("select:mcp__chrome-devtools__navigate_page")`: `navigate_page`, `take_screenshot`, `list_console_messages`, `list_network_requests`, `evaluate_script`, `click`, `fill`.

## Workflow

1. **Navigate** to the target URL
2. **Check console** for errors
3. **Check network** for failed requests
4. **Screenshot** if visual validation needed
5. **Evaluate** JS if DOM inspection needed

## Output Format

Return a concise findings report to the main agent:
```
## Browse: [URL]

**Console errors:** [count] — [summary]
**Network failures:** [count] — [summary]
**Visual:** [description or "looks correct"]
**Action needed:** [yes/no + what]
```

Keep response under 1500 characters. List findings, not process.

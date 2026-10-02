---
name: browse
description: Chrome DevTools debugging via haiku subagent — console, network, DOM, screenshots. Isolates expensive MCP responses from main context.
context: fork
background: false
model: haiku
---

# Browse — Chrome DevTools Debugging

Debug frontend issues using Chrome DevTools MCP in an isolated forked context.

## How It Works

Chrome DevTools MCP is registered globally but uses **deferred tool loading** (~400 tokens for tool names, schemas only loaded on demand via ToolSearch). This skill runs in a `context: fork` to keep MCP call responses (~5-20k tokens for screenshots, DOM, network) out of the main thread.

## Available Tools

Load tools on demand via ToolSearch:
```
ToolSearch("select:mcp__chrome-devtools__navigate_page")
ToolSearch("select:mcp__chrome-devtools__take_screenshot")
ToolSearch("select:mcp__chrome-devtools__list_console_messages")
ToolSearch("select:mcp__chrome-devtools__list_network_requests")
ToolSearch("select:mcp__chrome-devtools__evaluate_script")
ToolSearch("select:mcp__chrome-devtools__click")
ToolSearch("select:mcp__chrome-devtools__fill")
```

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

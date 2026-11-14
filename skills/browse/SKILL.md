---
name: browse
description: Browser checks on the shared headless Chrome via a haiku subagent — screenshots, DOM, console, network, performance. Keeps screenshots and page dumps out of the main context.
context: fork
agent: browser
background: false
model: haiku
---

# Browse — checks on the shared Chrome

Drive a page in a real browser from an isolated forked context.

## How It Works

One headless Chrome serves every browser agent on the machine (`shared-chrome ensure` starts it on the first use; it stops by itself 60 s after the last context). The `browser` subagent drives it with **playwright-cli**, one isolated context per run (own cookies and storage), viewport **1600x1100** by default. A task that needs another size says so (a repo's design bar names it) and the agent resizes before its first screenshot. The `chrome-devtools` MCP is declared in `agents/browser.md`, attached to the same Chrome, and used only for performance traces, Lighthouse and CSS inspection. Nothing is registered per session; the fork also keeps screenshots and DOM dumps (5-20k tokens) out of the main thread.

Not for basalt-ui's own layout and quality suites (they start their own Chrome inside test slots) and not for the research Chrome on port 9222 (`agw web`).

## Workflow

1. **Navigate** to the target URL
2. **Console** and **network** for errors and failed requests
3. **Screenshot** if visual validation is needed (size checked in the PNG)
4. **Evaluate** JS or take a snapshot if DOM inspection is needed
5. **Detach**: closes the agent's context

## Output Format

Return a concise findings report to the main agent:
```
## Browse: [URL]

**Console errors:** [count] — [summary]
**Network failures:** [count] — [summary]
**Visual:** [description or "looks correct"] ([screenshot path], [WxH])
**Action needed:** [yes/no + what]
```

Keep response under 1500 characters. List findings, not process.

---
name: research
description: Deep technical research via sideclaw MCP tool — Context7, WebSearch, WebFetch with cross-verification and quota-aware routing
---

# Research — via sideclaw MCP

Call `mcp__sideclaw__research` with `query` set to the user's research question.
Optionally pass `cwd` (defaults to $HOME) and `authMode` (default `auto` — flips to IU endpoint at >=70% Max quota).

Heavy fetch content stays in the worker subprocess — only the structured findings (`summary`, `findings`, `recommendation`, `confidence`, `sources`) return to the caller.

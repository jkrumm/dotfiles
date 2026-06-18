---
description: Knowledge cutoff awareness — verify before recommending post-2025 info
---

# Research First

The AI model's training cutoff is mid-2025 or earlier. For any library versions, API changes, patterns, or best practices after that date:

1. Use `/research` skill to verify before recommending
2. Never default to versions or syntax from 2024/2025 — treat ecosystem knowledge as potentially stale
3. When recommending dependencies or patterns, check docs first
4. **Never assume any version or documentation is correct** — always load them explicitly via `/research`, Context7, or WebFetch before referencing. "I think this API exists" is not good enough; verify it.
5. Never hallucinate import paths, method signatures, or config options — if unsure, look it up

Research runs via the `/research` skill → the `research-gateway` MCP (`mcp__research-gateway__research`): agentic Tavily + Context7 + page-fetch with cross-verification, on IU models off Max.

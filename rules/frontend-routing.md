---
description: Which frontend guidance applies where — basalt-ui 2.x consumers, basalt-ui 1.x apps, standalone HTML reports and one-off visualizations, non-basalt React apps
paths: ["**/*.tsx", "**/*.jsx", "**/*.html", "**/*.css"]
---

# Frontend Routing

Pick the first row that matches the repo or artifact. Rows are mutually exclusive.

## basalt-ui 2.x (package.json depends on `basalt-ui` ^2)

- Authority: the shipped `.claude/rules/basalt-*.md`, the `basalt-design`, `basalt-charts` and
  `basalt-app` skills, the `basalt-design-reviewer` subagent and its `AGENTS.md` block.
- These supersede `/dataviz`, `/frontend-design`, `visx-charts.md` and the memoization advice
  in `react-best-practices.md`. Charts are TanStack Charts (`@tanstack/charts`).
- The React Compiler is on: no manual `useMemo`, `useCallback` or `memo` for performance.

## basalt-ui 1.x (today: shutterflow, email-gateway, image-gateway)

- basalt's 1.x shipped rules apply.
- Charts are visx per `visx-charts.md` until the repo migrates to 2.x.

## Standalone HTML report, artifact or one-off visualization

- Use the bundled `/dataviz` skill, but with basalt's look so every output reads as one system.
- Colours and type come from basalt's tokens, not `/dataviz`'s placeholder palette:
  - `bunx basalt-ui tokens:css` emits the `--vx-*` variables.
  - `bunx basalt-ui fonts:css` emits the font faces.
- Keep basalt's restraint: no decorative gradients, no "bold aesthetic".
- Every number carries a unit and context.
- Every micro-visual encodes a target or a limit.

## Non-basalt React app (e.g. modelpick, visx)

- `tanstack-*.md`, `react-best-practices.md` and `visx-charts.md` apply as written.

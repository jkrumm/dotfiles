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
  - `bunx basalt-ui tokens:css` emits the CSS variables: `--vx-*` on 2.x (latest release), `--basalt-*` from 3.0 (on master, unreleased). Read the prefix off the installed version's output.
  - `bunx basalt-ui fonts:css` emits the font faces.
- Keep basalt's restraint: no decorative gradients, no "bold aesthetic".
- Every number carries a unit and context.
- Every micro-visual encodes a target or a limit.

## Non-basalt React app (e.g. modelpick, visx)

- `tanstack-*.md`, `react-best-practices.md` and `visx-charts.md` apply as written.
- `web-platform.md` applies as written; for a native capability it does not cover (popover, anchor
  positioning, scroll-driven animation, dates, sanitization) run the `modern-web-guidance` skill.

## Web-platform guidance in every row

- `web-platform.md` (IME-safe Enter, autofill, validation timing, top-layer motion, view transitions,
  reduced motion, colour scheme) is distilled from GoogleChrome/modern-web-guidance. It sits below
  basalt: in a basalt 2.x app the shipped rules and Base UI primitives win, and the
  `modern-web-guidance` skill is not run (its "execute first" mandate would route around
  `basalt/import-boundary`).
- Standalone HTML reports take `web-platform.md` for the platform facts and basalt's tokens for the look.

## Official agent guidance per library (checked 2026-11-15)

Fetch on demand with `agw web read <url> --ask "<question>"`; an official index beats the vendored rules where they disagree.

- **Skills in the npm package** (version-locked, the authority for the installed version): TanStack Router and Start (`node_modules/@tanstack/react-router/skills`, `react-start/skills`), TanStack Table (`react-table/skills`). Read the `SKILL.md` there; no install step. `@tanstack/intent` writes into the consuming repo's AGENTS.md, so it is a per-repo decision, not a global one.
- **shadcn/ui**: first-party skill, per repo: `pnpm dlx skills add shadcn/ui` in a shadcn app (the skill runs `shadcn info --json`); MCP `npx shadcn@latest mcp`.
- **`llms.txt` only** (no skill): react.dev (incl. React Compiler), base-ui.com (also `llms-full.txt`), vite.dev, bun.sh, `tanstack.com/{query,virtual,form,table}/latest`, elysiajs.com (v2: next.elysiajs.com), orm.drizzle.team, ui.shadcn.com.
- **Drizzle**: skill and `drizzle-kit mcp` exist only on the `1.0.0-rc` line; our apps are on 0.45.x, so not applicable until the rc is adopted.
- **Tailwind 4**: nothing official (`tailwindcss.com/llms.txt` is 404); the docs and basalt's rules are the source.

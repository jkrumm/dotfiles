---
name: dataviz
description: Design and style professional, aesthetic data visualizations and analytics dashboards — visx charts + Mantine chrome with a centralized, enforced color system. Use when building or restyling charts, dashboards, or metric UIs, choosing a chart palette, or when existing charts look "childish"/inconsistent/over-colored.
---

This skill guides the design of data visualizations and analytics dashboards that read as **professional, calm, and intentional** — the opposite of the over-saturated, multi-colored default that charting libraries ship. It pairs aesthetic judgment with a concrete, centralized, lint-enforced implementation pattern for visx + Mantine.

Use it when the user is building or restyling charts, picking a palette, or complains that charts look childish, inconsistent across tabs, or "AI default."

## Aesthetic direction (decide first)

Professional dataviz is **restraint**, not decoration. Commit to these before touching code:

- **One muted hue family, reused everywhere.** Pick a designed, UI-tuned palette (default: **Blueprint v6** — https://blueprintjs.com/docs/#core/colors). Never raw Material / AntD / Tailwind primaries; they read as childish and clash. Use a *small harmonious subset* of the family across every page so tabs feel like one app.
- **Single hue per metric.** Each metric owns ONE color, stable across all views (e.g. HRV always violet, bench always blue). Reach for multiple colors only when data is genuinely categorical (sleep stages, source breakdown). A line chart almost never needs more than one hue + neutrals.
- **Neutral structure, colored signal.** Lines/axes/grids in muted neutrals; color is reserved for the data and for status (good/warn/bad). A single neutral line with a soft tinted area reads more premium than a rainbow.
- **Gradients on areas, not on everything.** A soft single-hue vertical gradient under a line (hue at the peak → transparent at the baseline) is the canonical "modern" move. Keep stacked-area bands opaque (transparency leaks lower bands).
- **Quiet chrome.** Hairline grids (~6–8% neutral), thin crosshairs, restrained tooltips with a card surface and one accent swatch per row. Generous whitespace.

## The implementation pattern (centralize + enforce)

Aesthetics only survive if they're impossible to bypass. The architecture:

1. **One palette data file** (`palette.ts`): the hex palette (`BP`) + every series/status/semantic/neutral entry as a per-theme `{ light, dark }` **pair**. Pure data — no React, no UI-lib import. Series colors are NOT theme-agnostic: a hue keeps identity but shifts shade (lighter on dark to avoid glow, deeper on light). This file also feeds the **Mantine theme** (reskin every accent from the same `BP`), so chrome and charts share one identity with zero call-site edits.
2. **CSS custom properties** (`theme-vars.ts`): emit the pairs as `--vx-*` vars under the light/dark selector the UI lib toggles (`[data-mantine-color-scheme]`). Theme resolution becomes pure CSS — no JS branching, works in non-component files too.
3. **Thin tokens** (`tokens.ts`): `VX.*` are just `var(--vx-*)` strings + non-color sizing. Opacity via `alpha(token, a)` = `color-mix(in srgb, token a%, transparent)`, never `rgba()`.
4. **Enforcement guard**: a tiny script scanning chart + app source for raw hex / `rgb()` / `hsl()` (allow a `theme-allow` escape comment, exempt the palette/token files), wired into `lint`. A markdown rule drifts; a failing build doesn't. oxlint has no `no-restricted-syntax`, so this guard is how you get teeth.

Full conventions (primitives contract, kinds vs bespoke, the Rule of Three, gradient defaults) live in the global rule `~/.claude/rules/visx-charts.md` — read it before adding a chart. The realized reference implementation is `~/SourceRoot/argo/packages/charts`.

## Dark vs light tuning

Same hue, different shade — never the same hex in both. On dark backgrounds, saturated mid-tones glow/bleed: step **one shade lighter** and slightly desaturated. On light, go **one shade deeper** for contrast. Neutrals flip too: grid/line opacity and tooltip surfaces differ per scheme. Encode this as the `{light,dark}` pair in `palette.ts`; never compute it at the call site.

## Iterate visually, then bake

Static HTML POCs don't translate 1:1 to visx/Mantine. Instead ship a **DEV-only theme lab**: a floating panel that overrides `--vx-*` on the root element live (charts restyle with no re-render thanks to the CSS-var layer), persists to localStorage, and exports the chosen values as JSON to bake back into `palette.ts`. This closes the loop: tune by eye in the real app → copy → commit. Argo's lives at `apps/dashboard/src/components/theme-lab-panel.tsx`.

## Checklist before declaring a chart "done"

- Every color comes from a token (`VX.*` / palette) — guard is green, zero raw hex.
- One hue per metric; categorical multi-color only where justified.
- Neutral line/axis/grid; soft gradient area on plain metric lines.
- Tooltip = `ChartCard`/`ChartTooltip` primitives, not hand-rolled markup; one swatch per row.
- Looks right in BOTH themes (toggle and check glow on dark, contrast on light).
- New colors went into `palette.ts` as `{light,dark}` pairs, not inline.

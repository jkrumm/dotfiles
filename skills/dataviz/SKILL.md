---
name: dataviz
description: Design and style professional, aesthetic data visualizations and analytics dashboards — visx charts + Mantine chrome with a centralized, enforced color system. Use when building or restyling charts, dashboards, or metric UIs, choosing a chart palette, or when existing charts look "childish"/inconsistent/over-colored.
---

This skill guides the design of data visualizations and analytics dashboards that read as **professional, calm, and intentional** — the opposite of the over-saturated, multi-colored default that charting libraries ship. It pairs aesthetic judgment with a concrete, centralized, lint-enforced implementation pattern for visx + Mantine.

Use it when the user is building or restyling charts, picking a palette, or complains that charts look childish, inconsistent across tabs, or "AI default."

## Check for a project DESIGN.md first (the law)

Before applying any of the generic guidance below, look for a **`DESIGN.md` at the repo root**
(the emerging Google-spec convention: YAML token front matter + Markdown prose; sibling to
`AGENTS.md`/`CLAUDE.md`). If it exists, **it is the law** — this skill is only the _method_. Load
it, obey its palette/token/restraint rules and its earned-color policy verbatim, and never
introduce a color, scale, or pattern it forbids. This skill's defaults (single hue per metric,
neutral structure) are what a _good_ DESIGN.md encodes — but the project file wins on every
conflict. **In a basalt-ui consumer** the precedence is `consumer DESIGN.md > the shipped
basalt-* rules > this skill` — `basalt-charts.md`/`basalt-tokens.md` are law there, not this file.
The reference instantiation is `~/SourceRoot/argo/DESIGN.md`.

## Aesthetic direction (decide first)

Professional dataviz is **restraint**, not decoration. Commit to these before touching code:

- **One muted hue family, reused everywhere.** Pick a designed, UI-tuned palette (default: **Blueprint v6** — https://blueprintjs.com/docs/#core/colors). Never raw Material / AntD / Tailwind primaries; they read as childish and clash. Use a *small harmonious subset* of the family across every page so tabs feel like one app.
- **Single hue per metric.** Each metric owns ONE color, stable across all views (e.g. HRV always violet, bench always blue). Reach for multiple colors only when data is genuinely categorical (sleep stages, source breakdown). A line chart almost never needs more than one hue + neutrals.
- **Neutral structure, colored signal.** Lines/axes/grids in muted neutrals; color is reserved for the data and for status (good/warn/bad). A single neutral line with a soft tinted area reads more premium than a rainbow.
- **Gradients on areas, not on everything.** A soft single-hue vertical gradient under a line (hue at the peak → transparent at the baseline) is the canonical "modern" move. Keep stacked-area bands opaque (transparency leaks lower bands).
- **Quiet chrome.** Hairline grids (~6–8% neutral), thin crosshairs, restrained tooltips with a card surface and one accent swatch per row. Generous whitespace.

## The implementation pattern (centralize + enforce)

Aesthetics only survive if they're impossible to bypass. The architecture:

1. **One palette data file**: every series/status/semantic/neutral entry as a per-theme
   `{ light, dark }` **pair**. Pure data — no React, no UI-lib import. **The palette is DERIVED,
   not hand-authored** where the project has a derive engine (basalt-ui: `tokens/derive.ts` from
   one accent seed + bounded knobs) — never hand-edit a hex in that file to "fix" a drift; retune
   the derive config instead (`createBasaltTheme(overrides?, { derive })`). Where no derive engine
   exists, the pair is still hand-authored data, just not a hex edited to chase a one-off look.
   This file also feeds the **Mantine theme**, so chrome and charts share one identity.
2. **CSS custom properties**: emit the pairs as `--vx-*` vars under the light/dark selector the UI
   lib toggles. Theme resolution becomes pure CSS — no JS branching, works in non-component files.
3. **Thin tokens**: `VX.*` are just `var(--vx-*)` strings + non-color sizing. Opacity via
   `alpha(token, a)` = `color-mix(in srgb, token a%, transparent)`, never `rgba()`.
4. **Enforcement guard**: a script scanning chart + app source for raw hex/`rgb()`/`hsl()` (allow
   a documented escape comment, exempt the palette/token files), wired into lint. A markdown rule
   drifts; a failing build doesn't.

**In a basalt-ui consumer**, this pattern already ships — `basalt-ui/tokens` + `basalt check-theme`
+ `agent/rules/basalt-charts.md`/`basalt-tokens.md`. Don't re-roll it; read those before adding a
chart. Elsewhere, the global rule `~/.claude/rules/visx-charts.md` covers the primitives contract,
kinds vs bespoke, and the Rule of Three.

## Dark vs light tuning

Same hue, different shade — never the same hex in both. On dark backgrounds, saturated mid-tones glow/bleed: step **one shade lighter** and slightly desaturated. On light, go **one shade deeper** for contrast. Neutrals flip too: grid/line opacity and tooltip surfaces differ per scheme. Encode this as the `{light,dark}` pair in `palette.ts`; never compute it at the call site.

## Iterate visually, then bake

Static HTML POCs don't translate 1:1 to visx/Mantine. Instead ship a **DEV-only theme lab**: a floating panel that overrides `--vx-*` on the root element live (charts restyle with no re-render thanks to the CSS-var layer), persists to localStorage, and exports the chosen values as JSON to bake back into `palette.ts`. This closes the loop: tune by eye in the real app → copy → commit. Argo's lives at `apps/dashboard/src/components/theme-lab-panel.tsx`.

## Checklist before declaring a chart "done"

- Every color comes from a token (`VX.*` / palette) — guard is green, zero raw hex.
- One hue per metric; categorical multi-color only where justified.
- Neutral line/axis/grid; soft gradient area on plain metric lines.
- Tooltip = the shared card/legend/tooltip primitives, not hand-rolled markup; one swatch per row.
- Looks right in BOTH themes (toggle and check glow on dark, contrast on light).
- New colors went into the palette data as `{light,dark}` pairs, not inline — and not a hand-edited hex where a derive engine owns the palette.

---
description: visx charting conventions — ChartCard/ChartLegend/ChartTooltip primitives, kind-registry, centralized CSS-variable palette + tokens, theme reactivity
paths: ["**/charts/**", "**/*chart*.tsx", "**/*chart*.ts", "**/*Chart*.tsx", "**/*Chart*.ts"]
---

# Visx Charts — Library Conventions

Applies to any project using [visx](https://airbnb.io/visx) for charting. Keeps charts visually consistent and makes AI contributions predictable. Project-specific primitives/tokens live alongside the project — this file captures the discipline.

## Why visx (and not Recharts)

Visx exposes low-level primitives so we can build exactly the chart we want. The trade-off is that each chart duplicates structure unless we enforce shared building blocks. **Primitives + a small kind-registry is the contract, not optional polish.**

## Every chart has

1. **ChartCard** wrapper — never a raw AntD `<Card>`. Gives title + info-tooltip + extra slot, consistent margin.
2. **ChartLegend** — never hand-rolled legend markup. Supports `line | bar | split | splitLine` shapes and optional highlight state.
3. **ChartTooltip** + `TooltipHeader` + `TooltipRow` + `TooltipBody` — never import `@visx/tooltip` directly.
4. **AxisLeftNumeric** + **AxisBottomDate** — never raw `<AxisLeft>`/`<AxisBottom>` (they miss theme tokens + smart ticks).
5. **HoverOverlay** for mouse capture, **HoverContext** for cross-chart crosshair sync, **useChartTooltip** for tip state. Wrap a group of date-aligned charts in a sync provider (basalt-ui: `<ChartHoverSync>`) to cast a ghost crosshair across all siblings on hover; without it the cursor stays per-chart.
6. **Theme-aware colors** via `useVxTheme()` (re-renders on toggle) + `VX` tokens. **Never** raw hex literals in chart files. **Never** `localStorage.getItem('theme')`.

**Exemption:** sparklines (tiny inline charts without legend/tooltip) live under `charts/sparklines/` and don't have to compose `ChartCard`/`ChartLegend`/`ChartTooltip` — but still must use VX tokens and `useVxTheme`.

## How to add a new chart

1. **Is it the second instance of an existing pattern?** Extract a kind component into `charts/kinds/` and migrate both call sites. (Rule of Three: don't extract on the first, don't wait past the third.)
2. **Is it genuinely unique (like a dual-panel MACD)?** Stay bespoke — compose the primitives directly. Keep it in the page's chart file, not in `charts/kinds/`.
3. **Does it add a new color?** Add a `{light,dark}` pair to `palette.ts`, wire the var in `theme-vars.ts`, expose the `VX.*` ref in `tokens.ts` — never inline a hex. New non-color sizing goes straight in `tokens.ts`.

## Tokens & palette (CSS-variable architecture)

The mature pattern is **one palette data file → CSS custom properties → thin token refs**. Three layers, separated:

1. **Palette data** (`palette.ts`): a designed hue set (e.g. Blueprint v6 — muted, UI-tuned, never raw Material/AntD/Tailwind defaults) plus every semantic/series/status entry as a per-theme `{ light, dark }` **pair**. Pure data: no React, no UI-lib import, no browser API. This is the single source of truth — the app's UI-chrome theme (Mantine/etc.) is reskinned from the *same* file so charts and chrome share one identity.
2. **CSS variables** (`theme-vars.ts`): emits the pairs as `--vx-*` custom properties under the light/dark selectors the UI lib already toggles (e.g. `[data-mantine-color-scheme]`). Resolution is then pure CSS.
3. **Tokens** (`tokens.ts`): `VX.*` are just `var(--vx-*)` strings (colors) plus non-color sizing constants.

Consequences worth internalizing:

- Series colors are **not** theme-agnostic — a hue keeps its identity but shifts shade across themes (lighter on dark to avoid glow/bleed, deeper on light). The pair lives in `palette.ts`, not in two `fooDark`/`fooLight` keys on `VX`.
- Because tokens are CSS vars, `VX.*` works identically in components **and** non-component files (`constants.ts`, `formulas.ts`) — no hook required. `useVxTheme()` is kept only as a back-compat convenience returning the same var refs.
- Apply opacity with an `alpha(token, a)` helper (`color-mix(in srgb, token a%, transparent)`), never `rgba()` — the hue must keep resolving per scheme.
- A **single palette source** makes a DEV-only theme lab trivial: override `--vx-*` on the root element to retune the whole app live, persist to localStorage, export values to bake back in.

## Kind components

A "kind" is a recurring chart shape reusable across datasets. Props are declarative; bespoke escape hatches (`renderExtraTooltipRows`, etc.) are fine but shouldn't grow into god-object configs.

**Characteristic props of a good kind:**
- `data`, `width`, `height`, `chartId`
- `getX`, `getY` accessors (generic over point type)
- Zones / thresholds / refLines as plain arrays
- `seriesLabel`, `formatValue`, `tooltipLabel?`
- No `children` render-prop unless you genuinely need it — config-first.

**Anti-pattern:** a single `<Chart type="..." config={...} />` component that switches by kind. That's the Recharts trap. Prefer N small kinds.

**Shipped kinds (basalt-ui):** beyond the line/bar/area/donut basics, basalt-ui ships `MultiLine` (N series on a shared y-axis — legend-hover dimming, dashed MA companions, per-point markers, zones/refLines, fixed or auto domain; also z-score/σ via a symmetric domain + zero refLine), `DualPanel` (line pane + signed-histogram pane on one x-scale and cursor, optional fill-between), and `Heatmap` (category×category intensity grid with per-cell tooltip + optional gradient legend strip).

## Dark/light mode

Theme reactivity is **pure CSS**: the `--vx-*` variables are redeclared under the light/dark selector, so toggling the UI lib's color scheme restyles every chart with no React re-render. Charts read `VX.*` (var refs) directly; `useVxTheme()` returns the same refs for back-compat. Don't branch on color scheme in JS, and never read `localStorage.getItem('theme')`.

## Area gradients

Soft single-hue fills under a line read as "modern" and are cheap to centralize: one `AreaGradient` primitive emitting a vertical `<linearGradient>` whose stops are `color-mix` of a CSS-var color, with global strength knobs (`--vx-area-top` / `--vx-area-bottom`). Default the fill **on** for plain metric lines and **off** when the chart already carries zone/threshold fills (avoid double-fill clutter). Keep stacked-area bands opaque — fading them to transparent leaks lower bands and hurts readability.

## Guardrails

- `no-restricted-imports` bans `@visx/tooltip` in chart files (enforce in lint config).
- **Enforce the palette mechanically.** oxlint has no `no-restricted-syntax`, so add a tiny guard script (scan chart + app source for raw hex / `rgb()` / `hsl()`, allow a `theme-allow` escape comment) and wire it into `lint`. A markdown rule alone drifts — a failing build doesn't. Exempt the palette/token files themselves.
- **Enforce "no raw axes" mechanically too.** Raw `<AxisLeft>`/`<AxisBottom>`/`<AxisRight>` in a `/charts/` file is now a build failure (basalt-ui: the `basalt check-theme` `raw-visx-axis` guard; escape via `theme-allow`) — use the tokenized axis primitives. Previously markdown-only.
- `ChartCard`/`ChartLegend`/`ChartTooltip` contract is social/markdown-enforced. It's easier to compose them than work around them.

## Rule of thumb

> If the new chart doesn't fit the primitives, add a kind — don't loosen the primitives.

---
description: visx charting conventions for a non-basalt-ui repo — primitives, kind-registry, centralized CSS-variable palette, theme reactivity. In a basalt-ui consumer, `basalt-charts.md` (shipped by the package) supersedes this file entirely.
paths: ["**/charts/**", "**/*chart*.tsx", "**/*chart*.ts", "**/*Chart*.tsx", "**/*Chart*.ts"]
---

# Visx Charts — Library Conventions (non-basalt-ui repos)

**If this repo installs `basalt-ui`, stop here** — `agent/rules/basalt-charts.md` (shipped by the
package via `basalt-ui init`/`sync`) is the doctrine for that repo; it names `CartesianChart` as
the one mandatory assembly primitive and this file's older `ChartHoverSync`/`useChartTooltip`
shapes do not apply there.

For any other project using [visx](https://airbnb.io/visx): low-level primitives mean each chart
duplicates structure unless shared building blocks are enforced. **Primitives + a small
kind-registry is the contract, not optional polish.**

## Every chart has

1. A **card wrapper** — never a raw library `<Card>`. Title + info-tooltip + extra slot.
2. A **legend component** — never hand-rolled legend markup.
3. A **tooltip component** that portals outside the SVG — never render a `<div>`-based tooltip
   inside `<svg>` (it mounts in the SVG namespace, throws nothing, and never paints).
4. **Tokenized axis primitives** — never raw `<AxisLeft>`/`<AxisBottom>` (they miss theme tokens
   and smart ticks).
5. **Theme-aware colors** via CSS custom properties (`--vx-*` or your own prefix), resolved in pure
   CSS under the light/dark selector — never a React re-render on scheme toggle, never
   `localStorage.getItem('theme')`, never a raw hex literal in a chart file.

**Exemption:** sparklines (tiny inline charts without legend/tooltip) don't have to compose the
card/legend/tooltip contract — but still use the token system.

## Palette architecture (three layers)

Palette data (pure `{light,dark}` pairs, no React/UI-lib/browser API) → CSS variables (emitted
under the light/dark selector) → thin token refs (`var(--x-*)` strings, usable in components AND
non-component files). One source of truth; the app's UI-chrome theme is reskinned from the same
file so charts and chrome share one identity. Opacity via `color-mix(in srgb, token a%,
transparent)`, never `rgba()`.

## How to add a new chart

1. Second instance of an existing pattern? Extract a kind, migrate both call sites (Rule of Three).
2. Genuinely unique? Stay bespoke, composing the primitives directly.
3. Adds a new color? A `{light,dark}` pair in the palette data, wired through — never inline a hex.

## Guardrails

Enforce the palette and the "no raw axes" rule mechanically (a lint rule or a small guard script
scanning for raw hex/`rgb()`/`hsl()` and raw axis primitives, with a documented escape comment) —
a markdown rule alone drifts, a failing build doesn't.

> If the new chart doesn't fit the primitives, add a kind — don't loosen the primitives.

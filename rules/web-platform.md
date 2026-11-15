---
description: Web-platform rules models get wrong in React/HTML/CSS — IME-safe Enter, autofill tokens, validation timing, top-layer animation, view transitions, content-visibility, reduced motion, text wrap, colour scheme
paths: ["**/*.tsx", "**/*.jsx", "**/*.css", "**/*.html"]
source: GoogleChrome/modern-web-guidance@4dd9683 (2026-11-10)
---

# Web Platform

Distilled from the Chrome/Edge/Firefox/MDN guide corpus (208 guides); kept: what models still write wrong. The long tail (carousels, passkeys, WebGL, anchor positioning, popover, dates) is not here: run the `modern-web-guidance` skill.
Routing: `frontend-routing.md`. In a basalt-ui 2.x app the shipped `basalt-*` rules win; where a primitive exists (Base UI dialog, `useCommittedField`, `FormField`) use it, not these raw patterns.
Support: Baseline Widely needs no fallback; anything newer needs the guide's fallback unless the repo's AGENTS.md states a browser policy.

## Input

- **IME-safe Enter**: every custom `keydown` that acts on Enter (textarea, search box, rename field, command palette) returns early on `e.nativeEvent.isComposing || e.keyCode === 229`. Safari fires `compositionend` before the confirming Enter, so `isComposing` alone fails there. Migrating `keyCode === 13` to `key === 'Enter'` drops the immunity: add both checks. `Cmd/Ctrl+Enter` needs none. Keep a real `<button type="submit">`.
- **Autofill**: every field carries `autocomplete`. Sign-in: email `username`, password `current-password`. Sign-up: `email`, `new-password`. Payment `cc-*`, address tokens. PIN or code: `inputMode="numeric"` (OTP: `autocomplete="one-time-code"`). One `name` input, not first/last, unless split storage is needed. Stable `name` and `id`, or password managers skip the field.
- **Validation timing**: show errors after blur or submit, never on the first keystroke. CSS form: `:user-invalid` (Baseline Widely), not `:invalid`. Error text carries an icon or the word "error" and says how to fix it (not colour alone); its id joins `aria-describedby` only while invalid; format hints sit above the input so autocomplete popovers and mobile keyboards do not cover them. `pattern` is a full match.

## Motion and layers

- **Top-layer entry/exit** (dialog, popover): transition `display` and `overlay`, with `transition-behavior: allow-discrete` as its own declaration (inside the `transition` shorthand, older browsers drop the whole declaration). `@starting-style` is entry only; the exit is the transition to the closed base state. Put it inside or after the open-state selector.
- **Reduced motion**: nest `@media (prefers-reduced-motion: reduce)` in the rule it changes, shorten to a fade, keep the final state (nothing left at `opacity: 0`). No global `animation-duration: 0.01ms`. Never flash more than 3×/s, whatever the preference.
- **View transitions**: directional slides key on `html:active-view-transition-type(forward|backward)`; animate `transform`, not inset; `::view-transition-group(root)` takes a non-linear easing. Same-document is Baseline Newly; cross-document lacks Firefox.

## Rendering and loading

- **`content-visibility: auto`** only on heavy blocks below the fold, always with `contain-intrinsic-size` (else height collapses and the scrollbar jumps); on the initial viewport it delays first render. Check keyboard reach afterwards. `hidden` removes content from find-in-page: use `hidden="until-found"`.
- **Speculation Rules are for multi-page apps.** An SPA (every TanStack Router app) gets nothing from them: use router intent preloading. In an MPA exclude state-changing URLs (`/logout`, add-to-cart) and prefer document rules.
- **`scheduler.yield()`** only for a measured long task (INP), in a loop with a 50 ms deadline. Safari lacks it: feature-detect, fall back to `setTimeout`.
- **`text-wrap: balance`** on short headings only, never `*`; `pretty` is costly and lacks Firefox, never global.
- **Colour scheme**: `color-scheme: light dark` on `:root` plus `<meta name="color-scheme">` in `<head>` (viewport canvas and root scrollbar follow the root, not `body`); `light-dark()` needs a fallback. Never transition `scrollbar-color` (WebKit flickers).

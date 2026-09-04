# The look — One Zinc terminal, One Dark/Catppuccin Latte herdr chrome

Condensed reference lives in `CLAUDE.md` → "The look". This is the full rationale
and measurement data behind it.

Three programs paint one screen and none of them can see the other two. herdr
paints its **chrome** (sidebar, borders, tab row) from its own built-in theme;
the outer terminal paints **pane content** from its ANSI palette; starship
paints the **prompt** inside that. All three follow macOS appearance.

**`make theme` applies all three and reloads herdr live.** Run it on both
machines — it is a subset of `make setup`, idempotent, and safe to repeat.
Applying only one layer is how they drift apart.

| Layer | File | Setting |
|-|-|-|
| Terminal | `config/ghostty/config` → `~/.config/ghostty/config` | `theme = dark:one-zinc-dark,light:one-zinc-light` |
| herdr | `config/herdr/config.toml` | `name = "one-dark"`, `auto_switch = true`, `light_name = "catppuccin-latte"` |
| Prompt | `config/starship.toml` | ANSI color *names* — resolve through whichever is active |

**One Zinc = Atom One's hues, muted to ~72% saturation, on basalt-ui's zinc
surfaces.** Two design systems used for what each is good at: basalt-ui's zinc
ramp is a true neutral (no blue cast like One Dark's `#282c34`, no plum like
Catppuccin's `#1e1e2e`), while Atom One's hues are what herdr's chrome already
renders. Backgrounds are middle-ground on purpose — `#1f1f23` dark (between
basalt's zinc-900 `#18181b` and zinc-800 `#27272a`), `#f2f2f5` light (basalt's
own `--vx-surface-bg`). **Never black, never white**; `#09090b` was tried and
lasted one commit.

How the sidebar actually renders — measured in a pty capture with three
workspaces, one focused, per theme, not assumed:

| Theme | Focused row | Unfocused rows |
|-|-|-|
| `one-dark` | bg `#282C34`, fg `#ABB2BF`, **bold** | no bg, fg `#969CA8`, regular |
| `one-light` | bg `#F5F5F6`, fg `#383A42`, **bold** | no bg, fg `#686B77`, regular |
| `catppuccin-latte` | bg `#E6E9EF`, fg `#4C4F69`, **bold** | no bg, fg `#6C6F85`, regular |

Six decisions that are not taste:

- **The focused row has three cues, not one** — background, brighter foreground,
  and bold. The sidebar is never painted in any theme, so that background lands
  on the *terminal's* background, but because it is one cue of three it is
  allowed to be subtle: 1.17 dark. **An earlier revision believed the background
  was the only cue and drove the terminal to `#09090b` to maximise that one
  ratio.** That is where the black-black terminal came from. Verify with a pty
  capture before trading anything else away for it.
- **Light mode is `catppuccin-latte`, and it is a taste call made *against* the
  numbers** — do not later read it as the measured optimum. one-light's
  `surface_dim` is `#F5F5F6`: against the one-zinc-light terminal (`#f2f2f5`)
  that is **1.03**, so the focused row is painted and invisible and light mode
  runs on bold alone. Dark survives the same weakness (1.17) because a dark
  block on a near-black terminal still reads; a near-white block on a near-white
  terminal does not. Every light theme herdr ships, focused row vs `#f2f2f5`
  (and the row label's contrast on it): `kanagawa-lotus` #d5cea3 **1.43**/4.66,
  `tokyo-night-day` #d2d3da **1.34**/3.92, `gruvbox-light` #f2e5bc 1.12/9.23,
  `solarized-light` #eee8d5 1.10/3.64, `catppuccin-latte` #e6e9ef 1.09/6.57,
  `rose-pine-dawn` #f2e9e1 1.07/7.92, `one-light` #f5f5f6 1.03/10.41. Latte
  therefore does **not** fix the invisible row — it is one-light's problem in
  lavender — but it keeps labels near-neutral, where tokyo-night-day's `#3760BF`
  turns every one blue and contradicts the no-blue-cast premise, and
  kanagawa-lotus puts warm beige on cool zinc. Only those two actually separate
  the row, and each costs a hue. **Dark stays `one-dark`**: pairing latte with
  its own mocha would be a regression, mocha's `#1e1e2e` against the `#1f1f23`
  terminal being 1.00 — the row vanishing outright rather than being subtle.
- **`[theme.custom]` cannot fix this per-mode.** herdr does expose the sidebar
  colours (`panel_bg`, `surface0/1`, `surface_dim`, `overlay0/1`, `accent`,
  `text`, `subtext0`, `mauve`, `green`, `yellow`, `red`, `blue`, `teal`, `peach`)
  — the focused row is `surface_dim` — but it is a **single global block applied
  to whichever theme is active**, so it cannot hold one value for light and
  another for dark. That "no single colour works on both canvases" is now
  measured rather than asserted, and it holds for the opposite reason to the one
  implied: sweeping every grey, the best worst-case is `#707076`, which makes the
  *row* far more visible than either theme manages (3.34 / 4.40 against 1.17 /
  1.03) while collapsing the row's own **label** from 6.57 / 10.41 to 2.30 — the
  focused row becomes the least legible line in the sidebar. Worse trade. So the
  terminal background, which ghostty switches per mode, stays the differentiator.
- **`nord`, `dracula` and `vesper` are not options** — herdr ships no light
  sibling for any of them, so `auto_switch` has nothing to switch to. The pairs
  that do exist: one-dark/one-light, tokyo-night/tokyo-night-day,
  catppuccin/catppuccin-latte, gruvbox/gruvbox-light, solarized/solarized-light,
  kanagawa/kanagawa-lotus, rose-pine/rose-pine-dawn. `dark_name` and `light_name`
  need not be siblings — that is what makes the pairing above possible.
- **Appearance follows the MacBook's live switch on `desk`.** The herdr client
  runs locally inside Ghostty, which reports the colour scheme over DEC mode
  2031; the client forwards raw stdin bytes (`ClientMessage::Input`) and the
  server parses them, so `auto_switch` sees the report. herdr 0.8.0 forwards live
  2031 updates *into panes*, so an agent in a pane follows the Mac too. `name` is
  the static fallback for a terminal that never sends the report.
- **herdr does not use its `terminal` theme** (inherit the host ANSI palette),
  the obvious-looking choice: it emits only basic ANSI codes there, so palette 8
  would have to serve as both the row highlight and the comment gray. A named
  theme needs no negotiation and renders identically over any transport.
- **starship uses ANSI names, herdr's one override uses hex — asymmetric on
  purpose.** starship's names resolve through the active palette, so they follow
  the switch for free. herdr's inline sidebar token styles accept strict hex
  only, so the single `branch` override (`#358a5c`) has to clear both surfaces it
  can land on — the sidebar is transparent in both themes, so those are the
  terminal's two backgrounds: 3.86 on `#1f1f23`, 3.80 on `#f2f2f5`, the best
  worst-case of the greens tried. It is styled at all because herdr renders
  `branch` in the theme's mauve slot, and that is universal — `#C678DD` one-dark,
  `#CBA6F7` catppuccin, `#BB9AF7` tokyo-night, `#B48EAD` nord. **No theme choice
  avoids the purple; only an explicit style does.** `mauve` itself is left
  unoverridden — this is the only place it showed up, and a targeted override
  beats a global one whose other uses are unknown.

Theme files are **copied** into `~/.config/ghostty/themes/`, not symlinked.
Ghostty theme names are **exact filenames**. `one-zinc-dark` resolves because the
file is named that; bundled themes with spaces and capitals must be written in
full (`Catppuccin Mocha`, never `catppuccin-mocha`, which errors and falls back
to no theme at all). Verify with `ghostty +validate-config --config-file=…` —
but note it validates *syntax*, not theme **values**: a bad hex falls back to
defaults silently, which is why `make theme` also asserts the theme files exist
and are non-empty.
- **Font is `JetBrainsMono Nerd Font Mono`, the "Mono" family specifically.**
  herdr's state icons and starship's glyphs are Nerd Font codepoints (tofu
  without it), and the Mono variant forces single-width glyphs so an icon can't
  push herdr's column-aligned sidebar rows out of alignment. The plain
  `font-jetbrains-mono` cask stays declared because the Nerd Font one does *not*
  register a family named "JetBrains Mono" — dropping it would silently break
  any editor still configured with that name.

Applying a herdr config change to a live server without dropping panes:
`herdr server reload-config` (or `prefix+shift+R` inside herdr). `make
herdr-setup` does it for you. Validate first with `herdr config check` — but
know exactly what it does and does not catch, measured on 0.8.2:

- Unknown keys and TOML errors: caught (always were).
- An unknown **built-in theme name**: caught since 0.8.2 (#2452), and it names
  the valid set. This file previously said it was not — that was true on 0.7.5.
- A bad **hex in `[theme.custom]`**: still silently accepted, still falls back
  to a default. `mauve = "notahexcolor"` returns `config: ok`.
- **It exits 0 even on `config: issues found`.** Do not gate a script on its
  return code — read the output. That is why `make theme` asserts the theme
  files exist and are non-empty rather than trusting this command.

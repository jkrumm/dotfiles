# The look — One Zinc terminal, basalt-ui chrome in the Herdr app

Condensed reference lives in `AGENTS.md` → "The look". This is the full rationale.

Three programs paint one screen and none of them can see the other two. The Herdr app
paints its **chrome** (sidebar, bars, popups) from a theme file; the outer terminal
paints **terminal content** from its ANSI palette; starship paints the **prompt**
inside that. All three follow macOS appearance.

**`make theme` applies the terminal and prompt layers**; the app layer is
`make herdr-app-setup` (`docs/herdr-core.md` §Desktop layout). Run both on the MacBook
and `make theme` on the mini; applying one layer is how they drift apart.

| Layer | File | Setting |
|-|-|-|
| Terminal | `config/ghostty/config` → `~/.config/ghostty/config` | `theme = dark:one-zinc-dark,light:one-zinc-light` |
| Herdr app | `config/herdr-app/themes/one-zinc-{dark,light}.json` (symlinked, pickable in Settings) | the `jk` layout names `one-zinc-{light,dark}` and follows the system. Each file holds the terminal palette (the same One Zinc pair) plus a `colors` map for the chrome taken from basalt-ui's semantic tokens (background, card, sidebar, border, accent; oklch converted to hex). `basalt-ui-*` is the Blueprint palette |
| Prompt | `config/starship.toml` | ANSI color *names*, so they resolve through whichever palette is active |
| opencode | `config/opencode/tui.json` → `config/opencode/themes/one-zinc.json` | `theme = "one-zinc"`; one file, `{dark, light}` per token |

Classic herdr's layer (`config/herdr/config.toml`: `one-dark` / `catppuccin-latte`, applied and
reloaded by `make theme`) and its sidebar contrast measurements retire with classic herdr in Wave 7;
the numbers are in this file's git history.

opencode is the one layer with no terminal-independent switch of its own: its
`one-zinc` theme picks dark/light from the mode the **terminal** reports, and an
unattached core terminal answers OSC 10/11 with fixed dark colours and pushes no `?997`
on a switch (`docs/herdr-core.md` fact 6, re-checked on core 0.1.15), so it sat dark
forever. `scripts/claude-appearance.sh` therefore sends the `CSI ?997;Nn` report plus the
OSC 11 **and** OSC 10 answers (opentui's `RendererThemeMode` ignores the report on its own,
it only re-queries, and infers the mode from both colour answers together) as raw input over
`terminal.attach` (`scripts/hc-raw-input.ts`, because `hc send` always adds Enter) to every
live terminal running `claude` or `opencode` when the Mac's appearance changes. The `oc`
wrapper replays it into its own terminal at 0.4 s so it beats opencode's first paint. The push
runs locally and on the mini (`docs/macbook.md` §Light/dark). A `/theme` pick still persists
into `theme_mode_lock` and wins over the push, so leave opencode's theme on **Auto**.
`make theme` does not touch it (nothing to copy).

**One Zinc = Atom One's hues, muted to ~72% saturation, on basalt-ui's zinc
surfaces.** Two design systems used for what each is good at: basalt-ui's zinc
ramp is a true neutral (no blue cast like One Dark's `#282c34`, no plum like
Catppuccin's `#1e1e2e`), while Atom One's hues carry the syntax and ANSI colours.
Backgrounds are middle-ground on purpose: `#1f1f23` dark (between basalt's zinc-900
`#18181b` and zinc-800 `#27272a`), `#f2f2f5` light (basalt's own `--vx-surface-bg`).
**Never black, never white**; `#09090b` was tried and lasted one commit. It came from
believing one cue (a focused row's background) was the only one and driving the
terminal darker to maximise its contrast; verify with a capture before trading
anything else away for a single ratio.

Theme files are **copied** into `~/.config/ghostty/themes/`, not symlinked.
Ghostty theme names are **exact filenames**. `one-zinc-dark` resolves because the
file is named that; bundled themes with spaces and capitals must be written in
full (`Catppuccin Mocha`, never `catppuccin-mocha`, which errors and falls back
to no theme at all). Verify with `ghostty +validate-config --config-file=…` —
but note it validates *syntax*, not theme **values**: a bad hex falls back to
defaults silently, which is why `make theme` also asserts the theme files exist
and are non-empty.
- **Font is `JetBrainsMono Nerd Font Mono`, the "Mono" family specifically.**
  starship's glyphs and the app's status icons are Nerd Font codepoints (tofu
  without it), and the Mono variant forces single-width glyphs so an icon can't
  push aligned rows out of alignment. The plain
  `font-jetbrains-mono` cask stays declared because the Nerd Font one does *not*
  register a family named "JetBrains Mono" — dropping it would silently break
  any editor still configured with that name.

## Operating notes (moved from AGENTS.md)

**The look** — `make theme` applies the terminal + prompt layers (and, until Wave 7,
classic herdr's); the Herdr app's theme is `make herdr-app-setup`. Run both on the
machines they apply to, since applying one layer is how they drift.
opencode is the fourth layer and is **file-based, not a make target** — it
carries both modes in one `one-zinc.json`, so `make theme` has nothing to copy
and `/theme` flips it live. It follows the appearance through the Claude Code
push rather than a config file, so leave its `/theme` pick on **Auto** (see `docs/opencode.md`).

Layer table: above.

**Never black, never white** — middle-ground zinc (`#1f1f23` / `#f2f2f5`).
Font must be **`JetBrainsMono Nerd Font Mono`** — the Mono variant forces
single-width glyphs so icons can't break alignment. Ghostty validates syntax but
**silently accepts a bad theme hex**, so `make theme` asserts the theme files exist
and are non-empty.

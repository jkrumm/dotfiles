---
name: img
allowed-tools: Bash(agw schema --index *)
description: Personal image stack: generate or edit images with agw image, look at one with agw image-read, remove a background ("make this transparent", "cut out"), make favicon, PWA, apple-touch-icon or macOS/iOS app icon sets, upload to the public CDN with transform URLs, share privately via presigned links. Use whenever an image needs a URL (article, blog post, vault note, README, OpenGraph tag) or the user says "upload this image", "CDN link", "private image", "generate an image", "host this screenshot", "resize this", or asks where an image lives.
---

# Image stack

Verbs of agw for images, live from the CLI (if you see the command and not its output, run it). `imgcli --help` lists the
publishing verbs and their flags (5 KB: run it, do not guess). To look at an image rather than make one, `image-read` takes
the file and a question:

!`agw schema --index image image-enhance image-icon image-read 2>&1 || echo "agw is not on this machine"`

```
prompt ──gen──▶ local file ──upload──▶ img/      public CDN (imgproxy, unsigned URLs)
(agw image,      (~/Pictures/imgcli/)  └─private─▶ private/  presigned URLs only (max 7 days)
 the mini)                              one B2 bucket, two prefixes
```

- **Local truth** — files on disk: `~/Pictures/imgcli/` (what `gen` writes), photo trees, the studio app's `~/Pictures/ImageGen/` on the MacBook.
- **`img/` — public CDN.** imgproxy over a private B2 bucket behind Cloudflare. Unsigned URLs: anything here is public, and an unguessable key *is* the access control.
- **`private/` — never public.** Same bucket, but imgproxy's key and `ALLOWED_SOURCES` are locked to `img/`, so nothing under `private/` is reachable through the CDN. Shared only via S3 presigned URLs that expire (SigV4 maximum **7 days**).

Consumers take URLs, never raw files. **gen** = prompt → local, then optionally `--public` (CDN) or `--private` (presigned). **upload** = local → CDN. **private** = local → `private/` + presigned URL.

The tool is `scripts/imgcli` (→ `~/.local/bin/imgcli` via `make setup`). Everything resolves through secrets-run (never bare `op`), refs in `dotfiles-private/headless.refs` (`make secrets-seed` after a rotation), never hardcoded — this repo is public. Infra: `vps/apps/imgproxy/` (CDN), `agent-workflows` (`agw image` generation, `agw image-icon` icon build).

| Key (1Password, scopes only) | Scope | Used by |
|-|-|-|
| `op://common/b2-images-write` | `img/`, write, no delete | `upload`, `sync`, `ls`, `info`, `url`, `gen --public` |
| `op://common/b2-images-private` | `private/`, list/read/write, no delete | `private`, `private-url`, `private-ls`, `gen --private` |
| `op://common/b2-images-admin` | `img/` incl. deleteFiles | `rm` only |
| `op://common/backblaze-s3` | bucket coordinates | every B2 command |

**`rm` is MacBook-only by design**: the admin key is deliberately not in the mini's headless cache, so a headless agent cannot delete. On the mini `rm` dies with a one-line message saying so — do not seed the key to "fix" it. The private lane has no delete at all.

## Which command

| Intent | Command | Lands in |
|-|-|-|
| Generate or edit an image from a prompt | `imgcli gen` | local; `--public` adds the CDN, `--private` a presigned link |
| Remove the background from an existing image | `imgcli cutout <file>` | `<file>-cutout.png` next to it |
| Favicon / PWA / iOS / macOS icon set | `imgcli icon "<prompt>"` or `--from <file or .svg>` | `~/Pictures/imgcli/icons-<stamp>/` |
| Numbered contact sheet of options (png, jpeg, webp, svg) | `imgcli sheet <file>...` | `~/Pictures/imgcli/`; `--artifact <repo> --title <t>` files a Console Report, `--private` a presigned URL |
| One-off public asset (blog image, OG tag, README) | `imgcli upload` (alias `publish`) | CDN `img/` |
| Share an image with someone, not the world | `imgcli private` | `private/` + presigned URL |
| New link for an existing private image | `imgcli private-url <key>` | re-presign |
| What is in the private prefix | `imgcli private-ls` | reads `private/` |
| Bulk upload of a curated folder | `imgcli sync` | CDN, structure preserved |
| Remove an object from the CDN | `imgcli rm` | MacBook only (`--yes` skips the prompt) |

`imgcli transforms` is the verified processing-option list — read it before hand-writing a URL.

## gen

`gen` runs `agw image` (gpt-image-2.5, mini-only — no agw, no gen; `--edit <file>` is `--images`, the prompt describes the change). It sends no model, so quality routes it: `low`/`medium`/`auto` generates to `gpt-image-2.5-flare`, `high`/`xhigh`/`max` and every edit to `gpt-image-2.5-sunburst`. The cost is recorded as a platform run (`id` in the JSON is the agw runId; `agw run status <id>`), the PNGs are copied from agw's 30-day artifact store to `~/Pictures/imgcli/gen-<stamp>-<id>-<i>.png`. `--public` uploads each through the same code path as `upload` (prefix `--prefix`, default `gen/`) and prints the CDN URL plus a `![]()` embed; `--private` puts it under `private/` and prints a presigned URL (`--expires`, default 7d). The two are mutually exclusive. `--enhance` first runs the brief through the planner: its playbook-conditioned prompt and derived size/quality/n apply unless a flag overrides, assumptions and warnings go to stderr, and a `hard` policy warning aborts before anything is paid for.

**Quality is the cost lever** — per 1024×1024 image `low` ≈ $0.006, `medium` ≈ $0.013, `high` ≈ $0.053 (~9×), `xhigh` ≈ $0.094, `max` ≈ $0.21 (~36×). Draft at `low`, promote the winner. Both 2.5 models have a real alpha channel: for real alpha pass `gen --background transparent` (png output, real RGBA) and say "transparent background" in the prompt; prompt text asking for transparency on an opaque request still gets a painted checkerboard. `--enhance` carries the plan's chosen background through automatically. The interactive studio is the optional ImageGen Mac app from the `image-gateway` repo (MacBook, through agw's image door); `gen` is the agent lane.

## cutout & icon

`cutout` is `agw image --file` (mini-only); `icon` generates its source with `agw image` and builds the set with `agw image-icon` (sharp, svgo, Replicate upscale/cutout/vectorize). **Fresh art needs no cutout** — `gen --background transparent` (and `icon "<prompt>"`, which always asks for it) returns native alpha. `cutout` is for images that already exist opaque: photos, screenshots, old generations. It uses Replicate through the same IU host: `recraft` ($0.01, keeps resolution, the default) or `bria` ($0.018, caps output at 1024px).

`icon` writes the whole set: `favicon.ico` (16/32/48), `favicon.svg` (vectorized via recraft, $0.01 — omitted with a reason when gradient-heavy art would produce a bloated SVG), `icon-192.png`, `icon-512.png`, `icon-mask.png` (maskable, subject inside the 409px safe zone), `apple-touch-icon.png` (180, opaque on `--bg`), `icon-1024.png` (opaque, Xcode single-size/App Store), `AppIcon.icns` (macOS), plus `head.html` (the `<link>` tags) and `manifest.webmanifest` (icons array — add `name`/`theme_color` yourself). Sources under 512 px are upscaled first (real-esrgan, $0.002, keeps alpha) — recraft cutout and vectorize both reject inputs under 256 px. `--from` art without transparency is cut out automatically (`--cutout auto`). Opaque targets (apple-touch, maskable, 1024) are flattened onto `--bg`, default white — pick a brand colour when the subject is light.

## Logos and app icons

1. **Raster first, through `gen`.** Never hand-compute vector geometry for an expressive mark: it came out generic or broken every time. SVG is a later flat derivative, because metallic or gradient art cannot be vectorised (`icon` omits `favicon.svg` for it).
2. **Breadth, then depth.** Breadth: about 12 whole prompts that differ in style and composition, each opening with its style, `--n 2`, stating the exact subject count, how much of the tile it fills, and "no text". Depth: `gen --edit` on the owner's pick, naming what changes (scale, head size, light) and what stays; edits kept the design reliably. `gen` runs may go in parallel.
3. **Check count and subject yourself.** One direction returned three arrows when two were asked.
4. **Show a numbered contact sheet**, each option also at 64, 32 and 16 px, as a Console artifact: `imgcli sheet <file>... --labels live,a,b --artifact <repo> --title "<title>"`, the live mark as number 1. It uploads one picture per option and files the Report (a `## N. label` heading and a picture each). Give the owner the Console address it prints, never a presigned URL: he comments on a picture or at a spot on it there, and a presigned URL of 400 characters pasted into a terminal reply cannot be opened. The pictures are presigned, so the Report shows them for 7 days. `--private` alone prints one presigned URL for the whole sheet, for a reader outside the Console.
5. **The owner picks.** Your own judgement of the logo is not approval, and nothing replaces the live mark before his pick.
6. **Combining references:** `gen --edit` takes one file, so name the qualities of the others in words.
7. **Full export, after the pick.** Make a flat one-colour version: `gen --edit` on the pick, "solid white on black, same outline, thin even gaps at crossings". That flat file is the source of `favicon.ico` and `favicon.svg` (a metallic or gradient pick vectorises badly and shrinks to mush at 16 px); the full-colour pick stays the source of the large targets. Export with `imgcli icon --from <file> --bg <brand colour>`; a flat one-colour source vectorises cleanly and can be made adaptive (`prefers-color-scheme` in the SVG).
8. **A full package holds:** `favicon.ico` (16/32/48) and adaptive `favicon.svg`, PWA `icon-192`/`icon-512`, maskable `icon-mask`, `apple-touch-icon` (180), `icon-1024` (iOS and the App Store), `AppIcon.icns` (macOS), and a social card (1200×630, built separately from the pick, e.g. `gen --edit` or the `rs:fill:1200:630/f:jpg` URL). The phone, maskable and App Store icons are **full bleed**: no transparency, no rounded corners, the background runs to the edge because the system applies its own mask (maskable keeps the subject inside the safe zone).
9. **Look at every target before shipping** (open each file, view each size, on a light and a dark tab): a mark that is right at 1024 can be wrong at 16 or inside a mask.
10. **Even arrows, cheaply:** a fixed-up mirror — keep the better half, make a 180° rotated copy, join them — gives exactly even arrows when the owner wants that. Use it on the flat version, not the pick.
11. **Refining a shipped flat mark runs two lanes at once**, on one numbered sheet. Vector: a small script that writes the mark's SVG from named parameters (band, head size, sweep, overlap, gap) and renders each variant on the real tile at 320, 64, 32 and 16 px; a crossing is an SVG `mask` of the other shape stroked by the gap. It keeps tile, colour and symmetry exact and costs nothing, but only varies what the parameters describe. Raster: `gen --edit` on the master for shapes the parameters cannot reach. `imgcli sheet` takes the SVGs and the PNGs together, so both lanes sit on one sheet, and `imgcli icon --from mark.svg` builds the set from the vector pick. An edit of a tiled master lost the tile and softened every edge (6 of 6, 2026-11-20), so read it for the shape only and rebuild the pick as vector. Step 1 still holds for a new mark.
12. **Bolder at 1024 is weaker at 16.** Interlocked arrows close into a ring at 16 px; put the live mark on the sheet as number 1 and compare at 16 first.
13. **An installed app keeps the icon it was installed with.** A Dock web app or home-screen PWA does not follow a new manifest icon: after shipping, check that the server serves the new file (hash it against the repo), then remove and re-add the installed app.
14. **Shipping a mark is one change that touches every surface.** The tab (`favicon.ico`, the SVG favicon), the PWA (192, 512), Android (maskable, the subject inside a circle of 80 % of the width: draw the circle and look), the iPhone (apple-touch, full bleed), macOS (`.icns`), the link-preview card, every copy of the bare glyph in the repo (`rg` for the file name), and GitHub: the mark at the top of the README and the social preview card (1280 × 640; repository Settings, an upload by hand, GitHub has no API for it, so name it to the owner as his one step).
15. **Keep the geometry as parameters in the repo** (software-factory `scripts/brand.ts`): a script writes every SVG, so the next round changes a number, not a path.
16. **Open the `.icns` before shipping it:** `iconutil -c iconset` and look at `icon_16x16.png` and `icon_32x32.png`. They came out as noise from `imgcli icon` (agent-workflows issue 2510); until that is fixed, replace both with their `@2x` neighbours resized and rebuild with `iconutil -c icns`.

## Prefixes, naming, URLs

| Prefix | For | Naming |
|-|-|-|
| `fuji/` · `blog/` | camera exports · article images | filename kept (stem sanitized to `[A-Za-z0-9_-]`) |
| `gen/` · `misc/` | generated / ad-hoc · everything else | random 16-char name (`--name` only supplies the extension). `gen/` is the `gen --public` default, `misc/` the `upload` default |
| `private/<yyyy>/<mm>/` | `imgcli private` | random 16-char name |

`upload` skips a key that already exists and says so (`uploaded: false`) — success, not an error. Keys never include the bucket's `img/` (nor `private/` for the private commands); both forms are accepted as input. `--expires` takes `90s`, `30m`, `12h`, `7d`, `1w` or plain seconds; anything above 7 days is rejected. CDN URL shape `https://<cdn>/<options>/<key>`: `rs:fit:1600` in-page, `rs:fill:400:400/g:sm` thumbnail, `rs:fill:1200:630/f:jpg` OpenGraph, nothing for the original. Pin formats with `f:jpg`, never `@jpg` (not edge-cached).

## For agent use

Every command takes `--json`; prefer `imgcli info <key> --json`'s `renditions` map over hand-built URLs.

```bash
imgcli gen "…" --quality low --json    # → {"id","model","size","quality","cost_usd","latency_ms","public","private","images":[{"file","id"}],"plan"?}
imgcli gen "…" --public --json         # → images:[{"file","id","key","cdnUrl","markdown"}]
imgcli gen "…" --private --json        # → images:[{"file","id","key","url","expiresAt"}]
# images[].id is the agw runId (a string, shared by every image of one call), not a per-image id.
imgcli upload ~/x.png blog/ --json     # → {"uploaded","key","url","dimensions","bytes"}
imgcli private ~/x.png --json          # → {"key","url","expiresAt","bytes"}
imgcli sheet a.png b.svg --labels live,b --artifact <repo> --title "…" --json
                                       # → {"id","sheets":[{"file","ground","width","height","url"?,"expiresAt"?}],"images":[{"number","file","label"}],"artifact"?:{"id","title","url"}}; url is null when FACTORY_CONSOLE_URL is unset
imgcli cutout ~/x.png --json           # → {"id","model","file","width","height","cost_usd","latency_ms"}
imgcli icon "…" --bg "#1e3a8a" --json # → {"id","dir","source","steps":[{"step","model","cost_usd","latency_ms"}],"svg_skipped_reason","cost_usd","files":[…],"html","manifest"}
```

For anything the CLI does not wrap, the gateway exposes `<base>/openapi/json` (same bearer).

## Constraints

- Sources: jpg/jpeg/png/webp/avif/heic/raf, at most 50 MB and 100 MP (dimensions via `sips`, so the pixel check is macOS-only); `sync` bypasses these checks.
- `upload` and `private` store `width`/`height` as object metadata, which is what `info` reads for `source_dimensions`; objects from `sync` or other tools show `null` — expected.
- EXIF/GPS is stripped from everything served through the CDN; originals keep theirs. A presigned URL serves the original bytes, EXIF included.
- The bucket also holds database backups under another prefix; every key here is scoped to `img/` or `private/` — never widen one to "fix" a permission error.

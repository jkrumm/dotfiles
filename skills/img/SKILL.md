---
name: img
description: Manage the personal image stack — generate images on the image-gateway, upload to the public CDN with transform URLs, and share privately via time-limited presigned links. Use whenever an image needs a URL (public or private) for an article, blog post, vault note, README, OpenGraph tag, or a one-off share; when an image must be generated or edited from a prompt; when a background must be removed ("make this transparent", "cut out"); when a favicon, PWA icon, apple-touch-icon or macOS/iOS app icon set is needed; or when the user says "upload this image", "CDN link", "private image", "share this image privately", "generate an image", "host this screenshot", "resize this", mentions "image-gateway", or asks where an image lives.
---

# Image stack

```
prompt ──gen──▶ local file ──upload──▶ img/      public CDN (imgproxy, unsigned URLs)
(image-gateway,  (~/Pictures/imgcli/)  └─private─▶ private/  presigned URLs only (max 7 days)
 VPS)                                   one B2 bucket, two prefixes
```

- **Local truth** — files on disk: `~/Pictures/imgcli/` (what `gen` writes), photo trees, the studio app's `~/Pictures/ImageGen/` on the MacBook.
- **`img/` — public CDN.** imgproxy over a private B2 bucket behind Cloudflare. Unsigned URLs: anything here is public, and an unguessable key *is* the access control.
- **`private/` — never public.** Same bucket, but imgproxy's key and `ALLOWED_SOURCES` are locked to `img/`, so nothing under `private/` is reachable through the CDN. Shared only via S3 presigned URLs that expire (SigV4 maximum **7 days**).

Consumers take URLs, never raw files. **gen** = prompt → local, then optionally `--public` (CDN) or `--private` (presigned). **upload** = local → CDN. **private** = local → `private/` + presigned URL.

The tool is `scripts/imgcli` (→ `~/.local/bin/imgcli` via `make setup`). Everything resolves through `secrets-run` (never bare `op`), refs in `dotfiles-private/headless.refs` (`make secrets-seed` after a rotation), never hardcoded — this repo is public. Infra: `vps/apps/imgproxy/` (CDN), `image-gateway/gateway/` (generation).

| Key (1Password, scopes only) | Scope | Used by |
|-|-|-|
| `op://common/b2-images-write` | `img/`, write, no delete | `upload`, `sync`, `ls`, `info`, `url`, `gen --public` |
| `op://common/b2-images-private` | `private/`, list/read/write, no delete | `private`, `private-url`, `private-ls`, `gen --private` |
| `op://common/b2-images-admin` | `img/` incl. deleteFiles | `rm` only |
| `op://common/backblaze-s3` | bucket coordinates | every B2 command |
| `op://vps/image-gateway` | gateway `BASE_URL`/`API_SECRET` | `gen` |

**`rm` is MacBook-only by design**: the admin key is deliberately not in the mini's headless cache, so a headless agent cannot delete. On the mini `rm` dies with a one-line message saying so — do not seed the key to "fix" it. The private lane has no delete at all.

## Which command

| Intent | Command | Lands in |
|-|-|-|
| Generate or edit an image from a prompt | `imgcli gen` | local; `--public` adds the CDN, `--private` a presigned link |
| Remove the background from an existing image | `imgcli cutout <file>` | `<file>-cutout.png` next to it |
| Favicon / PWA / iOS / macOS icon set | `imgcli icon "<prompt>"` or `--from <file>` | `~/Pictures/imgcli/icons-<stamp>/` |
| One-off public asset (blog image, OG tag, README) | `imgcli upload` (alias `publish`) | CDN `img/` |
| Share an image with someone, not the world | `imgcli private` | `private/` + presigned URL |
| New link for an existing private image | `imgcli private-url <key>` | re-presign |
| What is in the private prefix | `imgcli private-ls` | reads `private/` |
| Bulk upload of a curated folder | `imgcli sync` | CDN, structure preserved |
| Remove an object from the CDN | `imgcli rm` | MacBook only (`--yes` skips the prompt) |

```bash
imgcli gen     "<prompt>" [--size WxH|auto] [--n 1-10] [--quality low|medium|high|xhigh|max|auto]
               [--background transparent|opaque|auto] [--edit <file>] [--enhance] [--public [--prefix gen/]] [--private [--expires <dur>]] [--copy] [--open] [--json]
imgcli cutout  <file> [--model recraft|bria] [--out <file.png>] [--json]
imgcli icon    "<prompt>" | --from <file> [--quality medium] [--bg #rrggbb] [--cutout auto|always|never] [--out <dir>] [--json]
imgcli upload  <file> [prefix/] [--name N] [--copy] [--open] [--json]      # publish = alias
imgcli private <file> [--expires <dur>] [--copy] [--json]
imgcli private-url <key> [--expires <dur>] [--copy] [--json]  ·  private-ls [prefix/] [--json]
imgcli ls [prefix/] · info <key> · url <key> [transform ...] · transforms · rm <key> [--yes] · sync <dir> <prefix/>
```

`imgcli transforms` is the verified processing-option list — read it before hand-writing a URL.

## gen

`POST /generate` on the image-gateway (gpt-image-2.5, VPS, tailnet-only — `gen` sends no model, so the gateway auto-routes: `low`/`medium`/`auto` generates to `gpt-image-2.5-flare`, `high`/`xhigh`/`max` and every edit to `gpt-image-2.5-sunburst`), or `POST /edit` with `--edit <file>` (png/jpeg/webp reference; the prompt describes the change). Each image lands at `~/Pictures/imgcli/gen-<stamp>-<id>-<i>.png`. `--public` uploads each through the same code path as `upload` (prefix `--prefix`, default `gen/`) and prints the CDN URL plus a `![]()` embed; `--private` puts it under `private/` and prints a presigned URL (`--expires`, default 7d). The two are mutually exclusive. `--enhance` first runs the brief through `POST /enhance`, the studio's Plan step: its playbook-conditioned prompt and derived size/quality/n apply unless a flag overrides, assumptions and warnings go to stderr, and a `hard` policy warning aborts before anything is paid for.

**Quality is the cost lever** — per 1024×1024 image `low` ≈ $0.006, `medium` ≈ $0.013, `high` ≈ $0.053 (~9×), `xhigh` ≈ $0.094, `max` ≈ $0.21 (~36×). Draft at `low`, promote the winner. Transparency is available again: both 2.5 models have a real alpha channel, so the gateway accepts `background: "transparent"` with `png`/`webp` output (`jpeg` + transparent is rejected). For real alpha pass `gen --background transparent` (png output, real RGBA) and say "transparent background" in the prompt; prompt text asking for transparency on an opaque request still gets a painted checkerboard. `--enhance` carries the plan's chosen background through automatically. The interactive studio is the optional ImageGen Mac app from the `image-gateway` repo (MacBook); `gen` is the agent lane.

## cutout & icon

Both run on the gateway, so every client gets identical output. **Fresh art needs no cutout** — `gen --background transparent` (and `icon "<prompt>"`, which always asks for it) returns native alpha. `cutout` is for images that already exist opaque: photos, screenshots, old generations. It uses Replicate through the same IU proxy: `recraft` ($0.01, keeps resolution, the default) or `bria` ($0.018, caps output at 1024px).

`icon` writes the whole set: `favicon.ico` (16/32/48), `icon-192.png`, `icon-512.png`, `icon-mask.png` (maskable, subject inside the 409px safe zone), `apple-touch-icon.png` (180, opaque on `--bg`), `icon-1024.png` (opaque, Xcode single-size/App Store), `AppIcon.icns` (macOS), plus `head.html` (the `<link>` tags) and `manifest.webmanifest` (icons array — add `name`/`theme_color` yourself). There is no SVG favicon: there is no vector source. `--from` art without transparency is cut out automatically (`--cutout auto`). Opaque targets (apple-touch, maskable, 1024) are flattened onto `--bg`, default white — pick a brand colour when the subject is light.

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
# images[].id is the gateway generation id (a string, shared by every image of one call), not a per-image id.
imgcli upload ~/x.png blog/ --json     # → {"uploaded","key","url","dimensions","bytes"}
imgcli private ~/x.png --json          # → {"key","url","expiresAt","bytes"}
```

For anything the CLI does not wrap, the gateway exposes `<base>/openapi/json` (same bearer).

## Constraints

- Sources: jpg/jpeg/png/webp/avif/heic/raf, at most 50 MB and 100 MP (dimensions via `sips`, so the pixel check is macOS-only); `sync` bypasses these checks.
- `upload` and `private` store `width`/`height` as object metadata, which is what `info` reads for `source_dimensions`; objects from `sync` or other tools show `null` — expected.
- EXIF/GPS is stripped from everything served through the CDN; originals keep theirs. A presigned URL serves the original bytes, EXIF included.
- The bucket also holds database backups under another prefix; every key here is scoped to `img/` or `private/` — never widen one to "fix" a permission error.

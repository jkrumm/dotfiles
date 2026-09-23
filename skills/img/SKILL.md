---
name: img
description: Manage the personal image stack — generate images on the image-gen gateway, upload to the public CDN with transform URLs, and the private image-share layer. Use whenever an image needs a URL (public or private) for an article, blog post, vault note, README, OpenGraph tag, or a one-off share; when an image must be generated or edited from a prompt; or when the user says "upload this image", "share this image", "private image", "publish image", "generate an image", "host this screenshot", "get me a CDN link", "resize this", mentions "image-share" or "image-gen", or asks where an image lives.
---

# Image stack

```
prompt ──gen──▶ local file ──share──▶ private layer ──publish──▶ public CDN
(image-gen        (~/Pictures/imgcli/,   (image-share,             (B2 img/ +
 gateway, VPS)     photo trees)           homelab)                  imgproxy)
```

- **Local truth** — files on disk: `~/Pictures/imgcli/` (what `gen` writes), photo trees, the studio app's `~/Pictures/ImageGen/` on the MacBook.
- **Private layer** — `image-share`, bearer-auth'd Elysia service on the homelab: indexes the photo trees, owns an ingest root, serves token-role share pages, exposes the admin/agent API.
- **Public CDN** — imgproxy over a private B2 `img/` prefix behind Cloudflare. Unsigned URLs: anything here is public, and an unguessable key *is* the access control.

Consumers take URLs from the last two layers, never raw files. **share** = local → private. **publish** = local → private → public, always staged through the private layer. **gen** = prompt → local, then `share` (default) or `publish` (`--public`).

The tool is `scripts/imgcli` (→ `~/.local/bin/imgcli` via `make setup`). Secrets resolve through `secrets-run`: `op://homelab/image-share/{BASE_URL,API_SECRET}` and `op://vps/image-gen-gateway/{BASE_URL,API_SECRET}`, both in `dotfiles-private/headless.refs` (`make secrets-seed` after a rotation), never hardcoded — this repo is public. Infra: `vps/apps/imgproxy/` (CDN), `homelab` (image-share deploy), `image-gen/gateway/` (generation).

## Which command

| Intent | Command | Lands in |
|-|-|-|
| Generate or edit an image from a prompt | `imgcli gen` | local + private; `--public` adds the CDN |
| One-off public asset (blog image, OG tag, README) | `imgcli upload` | CDN, routed through image-share |
| Durable private copy, maybe linked later | `imgcli share` | private layer |
| Final image headed for a note or article | `imgcli publish` | private layer, then CDN |
| Already-indexed image to the CDN, no local file | `imgcli publish --id` | CDN |
| Browse the private index (find an id) | `imgcli library` | reads private layer |
| Hand a friend a link to specific image(s) | `imgcli link` | private layer (share + token) |
| Bulk mirror of a curated folder | `imgcli sync` | CDN, **legacy direct-B2 lane** |
| Remove an object from the CDN | `imgcli rm` | CDN (really deletes; `--yes` skips the prompt) |

```bash
imgcli gen     "<prompt>" [--size WxH|auto] [--n 1-10] [--quality low|medium|high|auto]
               [--edit <file>] [--enhance] [--public] [--prefix gen/] [--dir <d>] [--copy] [--open] [--json]
imgcli upload  <file> [prefix/] [--name N] [--copy] [--open] [--json]
imgcli share   <file> [--dir <dir>] [--copy] [--json]
imgcli publish <file> [prefix/] [--dir <dir>] [--copy] [--open] [--json]   |   --id <imageId> [prefix/]
imgcli library [--root fuji|raws|share] [--dir <d>] [--stem <s>] [--min-rating n] [--page n] [--limit n] [--recursive] [--json]
imgcli link    <imageId>... [--role view|download|full] [--label <text>] [--expires <ISO date>] [--json]
imgcli ls [prefix/] · info <key> · url <key> [transform ...] · transforms · rm <key> [--yes] · sync <dir> <prefix/>
```

`imgcli transforms` is the verified processing-option list — read it before hand-writing a URL.

## gen

`POST /generate` on the image-gen gateway (gpt-image-2.5, VPS, tailnet-only — `gen` sends no model, so the gateway auto-routes: `low`/`medium`/`auto` generates to `gpt-image-2.5-flare`, `high`/`xhigh`/`max` and every edit to `gpt-image-2.5-sunburst`), or `POST /edit` with `--edit <file>` (png/jpeg/webp reference; the prompt describes the change). Each image lands at `~/Pictures/imgcli/gen-<stamp>-<id>-<i>.png`, is ingested privately under `--dir` (default `gen`), and with `--public` is published under `--prefix` (default `gen/`) with a CDN URL plus a `![]()` embed. `--enhance` first runs the brief through `POST /enhance`, the studio's Plan step: its playbook-conditioned prompt and derived size/quality/n apply unless a flag overrides, assumptions and warnings go to stderr, and a `hard` policy warning aborts before anything is paid for.

**Quality is the cost lever** — per 1024×1024 image `low` ≈ $0.006, `medium` ≈ $0.013, `high` ≈ $0.053 (~9×), `xhigh` ≈ $0.094, `max` ≈ $0.21 (~36×). Draft at `low`, promote the winner. Transparency is available again: both 2.5 models have a real alpha channel, so the gateway accepts `background: "transparent"` with `png`/`webp` output (`jpeg` + transparent is rejected). `gen` has no background flag, so it always gets an opaque image — and prompt text asking for a "transparent background" on an opaque request still gets a painted checkerboard; use the studio for real alpha. The interactive studio is the ImageGen Tauri app on the MacBook (`image-gen` repo); `gen` is the agent lane.

## Prefixes, naming, URLs

| Prefix | For | Naming |
|-|-|-|
| `fuji/` · `blog/` | camera exports · article images | filename preserved |
| `gen/` · `misc/` | generated / ad-hoc · everything else | random 16-char name, server-side (`--name` ignored). `gen/` is the `publish`/`gen` default, `misc/` the `upload` default |

`upload` and `publish` skip a key that already exists and say so (`uploaded: false` / `skipped`) — that is success, not an error. `publish` re-ingests on every run and needs **both** credential sets (`cmd_publish` calls `load_config` for `CDN_BASE`, then `load_share_config`). The private layer's `--dir` is an ingest-root subdirectory, not a CDN prefix. Keys never include the bucket's `img/`. URL shape `https://<cdn>/<options>/<key>`: `rs:fit:1600` in-page, `rs:fill:400:400/g:sm` thumbnail, `rs:fill:1200:630/f:jpg` OpenGraph, nothing for the original. Pin formats with `f:jpg`, never `@jpg` (not edge-cached).

## For agent use

Every command takes `--json`; prefer `imgcli info <key> --json`'s `renditions` map over hand-built URLs.

```bash
imgcli gen "…" --quality low --json    # → {"id","model","size","quality","cost_usd","latency_ms","public","images":[{"file","id","relPath","adminFileUrl"}],"plan"?}
imgcli gen "…" --public --json         # → images:[{"file","id","key","cdnUrl","markdown"}]
imgcli upload ~/x.png blog/ --json     # → {"uploaded","key","url","dimensions","bytes"}
imgcli share ~/x.png --json            # → {"id","root","relPath","adminFileUrl"}
imgcli publish ~/x.png blog/ --json    # → {"id","key","cdnUrl","markdown","renditions":{...}}
imgcli library --root share --json    # → {"data":[{"id","relPath","kind","rating",...}],"total"}
imgcli link 15916 15915 --json         # → {"shareId","role","url"}
```

Anything not wrapped (revoking tokens, updating a share): `GET <base>/api` for discovery, `<base>/openapi/json` for the contract, same bearer — the gateway likewise.

## Constraints

- Service-routed lanes (`upload`, `share`, `publish`, `gen`) reject sources over 50 MB / 100 MP; only `sync` (direct-B2, migration a known follow-up) bypasses that.
- EXIF/GPS is stripped from everything served through the CDN; originals keep theirs. `info` shows `source_dimensions: null` for service-routed uploads — expected.
- The bucket also holds database backups under another prefix; the upload key is scoped to `img/` server-side — never widen it to "fix" a permission error.

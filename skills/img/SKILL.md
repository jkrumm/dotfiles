---
name: img
description: Manage the personal image stack — public CDN uploads/transform URLs and the private image-share layer. Use whenever an image needs a URL (public or private) for an article, blog post, vault note, README, OpenGraph tag, or a one-off share; or when the user says "upload this image", "share this image", "private image", "publish image", "host this screenshot", "get me a CDN link", "resize this", mentions "image-share", or asks where an image lives.
---

# Image stack

Three layers, two verbs.

```
local truth  ──share──▶  private layer  ──publish──▶  public CDN
(~/Pictures/ImageGen/,     (image-share,                (B2 img/ +
 photo trees)               homelab)                     imgproxy)
```

- **Local truth** — files on disk. `~/Pictures/ImageGen/`, photo trees, anything not yet uploaded anywhere.
- **Private layer** — `image-share`, a bearer-auth'd Elysia service on the homelab. It indexes the photo trees and owns its own ingest root, serves token-role share pages for handing a link to someone without making the image public, and exposes an admin/agent API.
- **Public CDN** — imgproxy over a private B2 `img/` prefix, fronted by Cloudflare. Unsigned URLs; anything landing here is effectively public.

Consumers (vault notes, websites, agents) always consume URLs from one of the last two layers — never raw files.

**Two verbs:**
- **share** = local → private. Ingests a file into image-share; gives you a durable homelab copy you can later hand out via a share-page link.
- **publish** = local → private → public. Ingests into image-share, then pushes that same image to the CDN. Always staged through the private layer first — there is no direct local → CDN path for this verb (that's what `upload` is for).

The tool is `scripts/imgcli` (in this skill directory). Secrets resolve through
`secrets-run`, so it works on both the MacBook and the headless mini.

**Infra side:** `~/SourceRoot/vps/apps/imgproxy/` (design, security model, Cloudflare caveats — `vps/docs/image-cdn.md`) for the CDN; `~/SourceRoot/homelab` for the image-share deploy config.

## Which command

| Intent | Command | Lands in |
|-|-|-|
| One-off public asset (blog image, OG tag, README) | `imgcli upload` | CDN only |
| Durable private copy, maybe shared via a link later | `imgcli share` | private layer only |
| Generated/final image headed for a note or article | `imgcli publish` | private layer, then CDN |
| Bulk mirror of a curated folder | `imgcli sync` | CDN only |

`upload`/`sync` talk to the CDN directly and are unrelated to image-share — use them for anything that was never meant to live in the private index.

## Commands

```bash
imgcli upload  <file> [prefix/] [--name N] [--copy] [--open] [--json]
imgcli sync    <dir> <prefix/>          # mirror a folder, skip unchanged
imgcli ls      [prefix/] [--json]
imgcli info    <key> [--json]           # size, source dimensions, ready-made renditions
imgcli url     <key> [transform ...]
imgcli transforms                       # full processing-option reference

imgcli share   <file> [--dir <dir>] [--copy] [--json]
imgcli publish <file> [prefix/] [--dir <dir>] [--copy] [--open] [--json]
```

Run `imgcli transforms` before hand-writing a URL — it is the verified list of
what this deployment actually supports.

### share

Ingests a file into image-share's private root (`POST /api/images`, multipart,
optional `--dir` subdirectory). Returns the ingest id, its `relPath` inside the
private root, and an admin file URL for viewing it directly on the homelab.
Nothing reaches the public CDN.

### publish

Same ingest call as `share`, then publishes that image to the CDN
(`POST /api/publish`) under one of the four CDN prefixes (defaults to `gen/`).
Returns the CDN key, the full CDN URL, and a ready `![]()` markdown embed using
an `rs:fit:800/f:jpg` rendition — paste straight into a note or article. If the
image was already published before, image-share reports it under `skipped`
with its existing key; `imgcli publish` treats that as success and reports the
existing URL rather than erroring.

## URL shape

```
https://<cdn>/rs:fit:800/f:jpg/blog/photo.jpg
             └── options ───┘ └── key ──┘
```

Options are slash-separated and optional; omit them entirely for the original.
The key never includes the bucket's `img/` prefix (though `img/blog/x.jpg` is
accepted and normalised).

Common recipes:

| Need | URL |
|-|-|
| In-page image | `/rs:fit:1600/<key>` |
| Thumbnail | `/rs:fill:400:400/g:sm/<key>` |
| OpenGraph / social | `/rs:fill:1200:630/f:jpg/<key>` |
| Original | `/<key>` |

Use `f:jpg` — not the `@jpg` extension form — when pinning a format for
OpenGraph, RSS, or email. `@jpg` works but is not edge-cached.

## Prefixes

Apply to `upload`, `sync`, and `publish` — the private layer's own `--dir`
option is unrelated (it's a subdirectory of the ingest root, not a CDN
prefix).

| Prefix | For | Naming |
|-|-|-|
| `fuji/` | curated camera exports | filename preserved |
| `blog/` | article images | filename preserved |
| `gen/` | generated / ad-hoc | random 16-char name assigned (`publish` default) |
| `misc/` | everything else | random 16-char name assigned (`upload` default) |

Random names are the point for `gen/` and `misc/`: URLs are unsigned, so an
unguessable key *is* the access control. Put anything sensitive there, never
under a readable path.

The private layer uses a different access-control model: image-share is
bearer-auth'd end to end (index, ingest, admin file URLs), and anything shared
externally goes out through token-role share pages, not an unsigned key.

## For agent use

Every command takes `--json`. `imgcli info <key> --json` returns the object's
metadata plus a `renditions` map of ready-to-use URLs — prefer it over
constructing URLs by hand.

```bash
imgcli upload  ~/shot.png blog/ --json     # → {"key","url","dimensions","bytes"}
imgcli ls      blog/ --json                # → [{"key","url","bytes","modified"}]
imgcli share   ~/shot.png --json           # → {"id","root","relPath","adminFileUrl"}
imgcli publish ~/shot.png blog/ --json     # → {"id","key","cdnUrl","markdown","renditions":{...}}
```

Source dimensions are recorded as object metadata at upload time, so `info` is a
single cheap request. Files uploaded by other means (`sync`, `aws s3 cp`) show
`source_dimensions: null` — that is expected, not an error.

**Advanced private-layer ops** (creating/revoking share links, browsing the
index) are not wrapped by `imgcli`. Point an agent at the service directly:
`GET <base>/api` for discovery and `<base>/openapi/json` for the full contract,
both authenticated with the same bearer `imgcli share`/`publish` use. Base URL
and bearer resolve from `op://homelab/image-share/{BASE_URL,API_SECRET}` —
never hardcode either (this repo is public).

**Headless mini:** `share`/`publish` need those two refs cached before they'll
work there — add them to `dotfiles-private/headless.refs` and run
`make secrets-seed` (biometric, present-human) first. Every other `imgcli`
command is unaffected.

## Constraints worth knowing

- **Uploads cannot delete.** The credential has no `deleteFiles` capability, on
  purpose. Removing an object needs a separate key; ask before adding one.
- **The bucket also holds database backups** under a different prefix. The
  upload key is scoped to `img/` server-side and cannot see them. Do not
  "fix" a permission error by widening that key.
- **EXIF/GPS is stripped** from everything served through the CDN. Originals in
  the bucket keep their metadata.
- **Max source:** 100 MP, 50 MB. Larger files upload fine but fail to render.
- **Publish is one-way staging, not a mirror.** Re-running `publish` on the
  same file re-ingests it (a new private-layer copy) before publishing; it
  does not deduplicate against a prior local file, only against a prior
  image-share id already published under that prefix.

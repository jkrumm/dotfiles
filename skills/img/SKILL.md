---
name: img
description: Upload images to the personal image CDN and mint transform URLs (resize, crop, format). Use whenever an image needs a public URL — for an article, blog post, vault note, README, OpenGraph tag, or when the user says "upload this image", "host this screenshot", "get me a CDN link", "resize this", or asks where an image lives. Also use to list or inspect what is already on the CDN.
---

# Image CDN

Upload images to a private B2 bucket and serve them through imgproxy +
Cloudflare, with on-the-fly resizing and format conversion. Every rendition is
edge-cached for a year.

The tool is `scripts/imgcli` (in this skill directory). Secrets resolve through
`secrets-run`, so it works on both the MacBook and the headless mini.

**Infra side:** `~/SourceRoot/vps/apps/imgproxy/` — design, security model, and
the Cloudflare caveats live in `~/SourceRoot/vps/docs/image-cdn.md`.

## Commands

```bash
imgcli upload <file> [prefix/] [--name N] [--copy] [--open] [--json]
imgcli sync   <dir> <prefix/>          # mirror a folder, skip unchanged
imgcli ls     [prefix/] [--json]
imgcli info   <key> [--json]           # size, source dimensions, ready-made renditions
imgcli url    <key> [transform ...]
imgcli transforms                      # full processing-option reference
```

Run `imgcli transforms` before hand-writing a URL — it is the verified list of
what this deployment actually supports.

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

| Prefix | For | Naming |
|-|-|-|
| `fuji/` | curated camera exports | filename preserved |
| `blog/` | article images | filename preserved |
| `gen/` | generated / ad-hoc | random 16-char name assigned |
| `misc/` | everything else (default) | random 16-char name assigned |

Random names are the point for `gen/` and `misc/`: URLs are unsigned, so an
unguessable key *is* the access control. Put anything sensitive there, never
under a readable path.

## For agent use

Every command takes `--json`. `imgcli info <key> --json` returns the object's
metadata plus a `renditions` map of ready-to-use URLs — prefer it over
constructing URLs by hand.

```bash
imgcli upload ~/shot.png blog/ --json   # → {"key","url","dimensions","bytes"}
imgcli ls blog/ --json                  # → [{"key","url","bytes","modified"}]
```

Source dimensions are recorded as object metadata at upload time, so `info` is a
single cheap request. Files uploaded by other means (`sync`, `aws s3 cp`) show
`source_dimensions: null` — that is expected, not an error.

## Constraints worth knowing

- **Uploads cannot delete.** The credential has no `deleteFiles` capability, on
  purpose. Removing an object needs a separate key; ask before adding one.
- **The bucket also holds database backups** under a different prefix. The
  upload key is scoped to `img/` server-side and cannot see them. Do not
  "fix" a permission error by widening that key.
- **EXIF/GPS is stripped** from everything served through the CDN. Originals in
  the bucket keep their metadata.
- **Max source:** 100 MP, 50 MB. Larger files upload fine but fail to render.

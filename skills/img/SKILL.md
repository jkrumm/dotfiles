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
- **publish** = local → private → public. Ingests into image-share, then pushes that same image to the CDN. Always staged through the private layer first — there is no direct local → CDN path for this verb (that's what `upload` is for). `publish --id` skips the ingest step for an image already indexed.

The tool is `scripts/imgcli` (in this skill directory), symlinked onto `PATH` at
`~/.local/bin/imgcli` by `make setup` (`_setup-imgcli` in the repo Makefile — same
lane as `secrets-run`). Secrets resolve through `secrets-run`, so it works on both
the MacBook and the headless mini.

**Infra side:** `~/SourceRoot/vps/apps/imgproxy/` (design, security model, Cloudflare caveats — `vps/docs/image-cdn.md`) for the CDN; `~/SourceRoot/homelab` for the image-share deploy config.

## Which command

| Intent | Command | Lands in |
|-|-|-|
| One-off public asset (blog image, OG tag, README) | `imgcli upload` | CDN only |
| Durable private copy, maybe shared via a link later | `imgcli share` | private layer only |
| Generated/final image headed for a note or article | `imgcli publish` | private layer, then CDN |
| Already-indexed image headed for the CDN, no local file | `imgcli publish --id` | private layer (already there), then CDN |
| Browse what's indexed in the private layer | `imgcli library` | reads private layer |
| Hand a friend a link to specific image(s) | `imgcli link` | private layer (share + token) |
| Bulk mirror of a curated folder | `imgcli sync` | CDN only, **legacy direct-B2 lane** |
| Remove an object from the CDN | `imgcli rm` | CDN only |

`upload` is service-routed (`POST /api/b2/upload`) so the CDN index
(`GET /api/b2`) is never stale for it. `sync` is the **one remaining
direct-B2 lane** — a bulk mirror of a curated folder, unrelated to
image-share, pending its own migration to the service.

## Commands

```bash
imgcli upload  <file> [prefix/] [--name N] [--copy] [--open] [--json]
imgcli sync    <dir> <prefix/>          # legacy direct-B2 mirror, skip unchanged
imgcli ls      [prefix/] [--json]
imgcli info    <key> [--json]           # size, source dimensions, ready-made renditions
imgcli url     <key> [transform ...]
imgcli transforms                       # full processing-option reference
imgcli rm      <key> [--yes] [--json]   # delete from the CDN

imgcli share    <file> [--dir <dir>] [--copy] [--json]
imgcli publish  <file> [prefix/] [--dir <dir>] [--copy] [--open] [--json]
imgcli publish  --id <imageId> [prefix/] [--copy] [--open] [--json]
imgcli library  [--root fuji|raws|share] [--dir <d>] [--stem <s>] [--min-rating n] [--page n] [--limit n] [--recursive] [--json]
imgcli link     <imageId> [<imageId>...] [--role view|download|full] [--label <text>] [--expires <ISO date>] [--json]
```

Run `imgcli transforms` before hand-writing a URL — it is the verified list of
what this deployment actually supports.

### upload

Multipart `POST /api/b2/upload` against image-share, which puts the object
straight into the bucket and upserts its own `b2_objects` mirror — the same
table the admin Public page and `GET /api/b2` read from. Prefix must be one of
`fuji|blog|gen|misc`; readable prefixes keep `--name` (or the source
filename); opaque prefixes (`gen/`, `misc/`) always get a random 16-char name
**server-side**, regardless of `--name` — an unguessable key is the access
control behind the CDN's unsigned URLs, and the client no longer decides it.
Skips (does not overwrite) a key that already exists and reports that
clearly: `uploaded` is `false` and `reason` explains why, in both human and
`--json` output.

### sync

The one remaining **direct-to-B2** lane — talks to the bucket over the S3 API
with the same credential `ls`/`info`/`url` use, unrelated to image-share.
Kept for bulk mirrors of a curated folder (e.g. a whole camera export) where
routing every file through a multipart upload call isn't worth it. Migrating
it to a service-routed batch endpoint is a known follow-up, not yet done.

### rm

`DELETE /api/b2/:key` through image-share. Prompts for confirmation unless
`--yes`. image-share holds its own scoped `image-share-b2` key with
`deleteFiles` capability, so this actually deletes the object. The direct-B2
upload credential (`sync`/`ls`/`info`/`url`) still has no `deleteFiles`
capability by design and never will — that's a separate, more narrowly scoped
key held only by the service.

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

`imgcli publish --id <imageId> [prefix/]` skips the ingest step entirely — for
an image already sitting in the index (found via `imgcli library`), publish
straight from its id with no local file involved.

### library

Read-only browse of the private index (`GET /api/library/images`), filterable
by `--root` (`fuji|raws|share`), `--dir`, `--stem` (matches the filename stem),
`--min-rating`, and `--recursive` to include sub-directories. Defaults to
page 1 of 50 rows and notes when more exist; page through with `--page`/
`--limit`. Use it to find the `imageId` for `publish --id` or `link`.

### link

The payoff verb: hand a friend a ready-to-send link in one command. Creates a
`selection` share (`POST /api/shares`) over one or more image ids and mints a
token for it, printing the `share.jkrumm.com/<slug>?token=...` URL. Defaults
to `--role view`; a non-default role or an explicit `--label` mints an
additional token via `POST /api/shares/:id/tokens` rather than reusing the
share's default view token. `--expires` takes an ISO date (`2026-12-31`) or
full ISO 8601 datetime.

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
under a readable path. As of the service-routed `upload`, this naming happens
**server-side** (`image-share/lib/naming.ts`) — `--name`/the source filename
is ignored for these two prefixes even if supplied.

The private layer uses a different access-control model: image-share is
bearer-auth'd end to end (index, ingest, admin file URLs), and anything shared
externally goes out through token-role share pages, not an unsigned key.

## For agent use

Every command takes `--json`. `imgcli info <key> --json` returns the object's
metadata plus a `renditions` map of ready-to-use URLs — prefer it over
constructing URLs by hand.

```bash
imgcli upload  ~/shot.png blog/ --json     # → {"uploaded","key","url","dimensions","bytes"} or {"uploaded":false,"key","url","reason"}
imgcli ls      blog/ --json                # → [{"key","url","bytes","modified"}]
imgcli rm      blog/shot.png --yes --json  # → {"deleted":true,"key"}
imgcli share   ~/shot.png --json           # → {"id","root","relPath","adminFileUrl"}
imgcli publish ~/shot.png blog/ --json     # → {"id","key","cdnUrl","markdown","renditions":{...}}
imgcli publish --id 15916 gen/ --json      # → same shape, no local file needed
imgcli library --root share --json        # → {"data":[{"id","root","relPath","dir","stem","kind","rating","captureAt",...}],"total"}
imgcli link    15916 15915 --role view --json  # → {"shareId","role","url"}
```

Source dimensions are recorded in `upload`'s own output for display, but are
**no longer attached as object metadata** now that upload is service-routed —
`info` on a service-uploaded key will show `source_dimensions: null` (expected,
not an error), same as objects uploaded via `sync` or outside `imgcli`
entirely.

**Advanced private-layer ops** beyond what's wrapped above (revoking tokens,
updating a share, browsing dirs) are not wrapped by `imgcli`. Point an agent at
the service directly: `GET <base>/api` for discovery and `<base>/openapi/json`
for the full contract, both authenticated with the same bearer every
private-layer command uses. Base URL and bearer resolve from
`op://homelab/image-share/{BASE_URL,API_SECRET}` — never hardcode either (this
repo is public).

**Headless mini:** every private-layer command (`share`, `publish`, `library`,
`link`, `rm`, and now `upload`) needs those two refs cached before they'll work
there — add them to `dotfiles-private/headless.refs` and run
`make secrets-seed` (biometric, present-human) first. `sync`, `ls`, `info`,
`url` are unaffected (they use the separate direct-B2 credential).

## Constraints worth knowing

- **`rm` actually deletes.** image-share holds its own scoped `image-share-b2`
  key with `deleteFiles` capability, so `DELETE /api/b2/:key` removes the
  object from B2. The direct-B2 upload credential (`sync`/`ls`/`info`/`url`)
  still has no `deleteFiles` capability by design and never will.
- **The bucket also holds database backups** under a different prefix. The
  upload key is scoped to `img/` server-side and cannot see them. Do not
  "fix" a permission error by widening that key.
- **EXIF/GPS is stripped** from everything served through the CDN. Originals in
  the bucket keep their metadata.
- **Max source: 100 MP, 50 MB.** Service-routed lanes (`upload`, `share`,
  `publish`) reject anything over 50 MB with a 400. Only `sync` — the direct-B2
  lane — bypasses that check.
- **Publish is one-way staging, not a mirror.** Re-running `publish` on the
  same file re-ingests it (a new private-layer copy) before publishing; it
  does not deduplicate against a prior local file, only against a prior
  image-share id already published under that prefix.
- **`sync` is the one lane still on direct-B2 credentials.** It's for bulk
  mirrors of a curated folder and is unrelated to image-share; migrating it to
  a service-routed batch endpoint is a known follow-up, not yet scheduled.

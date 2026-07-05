---
name: brain
description: Read and write the second brain — an OKF-native private knowledge base at ~/SourceRoot/brain. Use whenever the user mentions "brain", "second brain", "knowledge base", "note", "remember", "look up", "find note", "capture", or "okf". Also use for any request to save, retrieve, or organize personal knowledge that belongs in the brain rather than in a repo-specific doc.
---

# Brain — second-brain interaction skill

Interact with the private knowledge base at `~/SourceRoot/brain` (`jkrumm/brain`). Two layers:

- **`knowledge/`** — the OKF agent memory. Terse, structured, cross-linked concept docs. Agents read and write it by traversing the tree. The canonical store.
- **`compiled/`** — human-readable pieces in the author's voice, distilled from `knowledge/` via `/distill`. Derived output.

There is no database and no API — it is a filesystem. The full contract is in the repo's `AGENTS.md`; this skill encodes the behavioral instructions. Validation uses `bun scripts/okf-lint.mjs`.

## Prerequisites

The brain repo must be cloned at `~/SourceRoot/brain`. If it does not exist, tell the user:

> The brain repo is not found at `~/SourceRoot/brain`. Clone it from `jkrumm/brain` (private GitHub repo) and try again.

## How to read

1. Start at `/Users/jkrumm/SourceRoot/brain/index.md` and follow links in `[text](/knowledge/x.md)` form.
2. Default-traverse `knowledge/` and `compiled/`. Use `type` and `tags` to route.
3. **Never** default-traverse `inbox/` — read it only on an explicit ingestion request.
4. For broad searches, delegate to the Explore subagent scoped to `knowledge/` (or `compiled/`) rather than reading files inline.

## How to write knowledge

- Prefer editing an existing concept over creating an orphan. Check for an existing doc first.
- Frontmatter: `type` + `description` required; add `title`, `tags`, `timestamp` (ISO 8601) where meaningful.
- Links: only `[text](/knowledge/x.md)` form (leading slash, `.md`). Every new doc gets ≥1 outbound link.
- Update the nearest `index.md`. Append a line to root `log.md`.
- Run `bun scripts/okf-lint.mjs` before committing; 0 errors required. Passing is necessary, not sufficient — judgment stays human.

## How to capture

For a quick capture (a stray thought, a URL, a one-line reminder), write it to `inbox/` as a dated staging file (e.g. `inbox/2026-07-05-idea.md`) with `type: Capture` + `timestamp` + `description`. Do not distill it inline — captures are promoted deliberately (see Ingestion).

## How to compile (human-readable output)

Compiled pieces are produced by `/distill` against `voice.md`, one named piece at a time. **Never auto-generate `compiled/` docs in bulk.** Each carries `status: personal|draft|published` + `source` (link to the knowledge doc it was distilled from). The voice pass, first-person content, and publish decision are always the human's — never automated.

## Ingestion (the careful contract)

Content enters the brain deliberately, in reviewed batches — **never via an autonomous loop** (v1 was scrapped for that; see `docs/post-mortem-v1.md`). When the user explicitly asks to ingest or migrate:

1. Connectors (`scripts/karakeep-pull.mjs`, Notion extraction, the Obsidian vault) drop **raw** captures into `inbox/` only.
2. Promote one concept at a time: read the capture, decide keep/skip (log skips with a reason — no silent drops), distill into a `knowledge/` concept doc with full frontmatter + links, then remove or mark the inbox source.
3. Show the user the `git diff` before it lands. Small batches, hand-reviewed.

Do not touch `inbox/` or run ingestion unless explicitly asked.

## Obsidian vault is a separate source

The Obsidian vault at `~/Obsidian/Vault` is a **migration source**, not the brain. Migrate from it in small hand-reviewed batches on explicit request; never bulk-import. Do not assume vault files live in the brain repo or vice versa, and do not touch the vault unless the task is explicitly about it.

## Safety

- Scope commits to one concern. Review `git diff --stat` before pushing.
- There is no auto-sync. Commit deliberately (or via `/commit`) when a write is done, and push to back up to GitHub.
- Never commit secrets, real hostnames, or real IPs — use placeholders.

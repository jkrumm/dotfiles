---
name: brain
description: Read and write the second brain — a git-backed Obsidian vault at ~/SourceRoot/brain (PARA structure + a top-level wiki/ knowledge tree). Use whenever the user mentions "brain", "second brain", "knowledge base", "note", "remember", "look up", "find note", "capture", "wiki", or "okf". Also use for any request to save, retrieve, or organize personal knowledge that belongs in the brain rather than in a repo-specific doc.
---

# Brain — second-brain interaction skill

Interact with the private knowledge base at `~/SourceRoot/brain` (`jkrumm/brain`): one folder that is **both** an Obsidian vault and the git-backed second brain, shared by Claude Code (this skill) and Hermes (`obsidian` skill). The full traversal + write + ingestion contract is in the repo's `AGENTS.md` — read it before any non-trivial write; this skill encodes the behavioral instructions. Validation uses `node .scripts/vault-lint.mjs`.

Two layers, two physical trees:

- **Agentic knowledge — `wiki/`.** A top-level, domain-organized tree (e.g. `wiki/health/peptides/`) of atomic, terse, **English**, cross-linked concept notes agents read and write by traversal. **Strict** discipline: `type` + `description` frontmatter, `[[wikilinks]]` that resolve, a per-level `index.md` MOC.
- **Curated human surface — `03_Projects`, `04_Areas`.** The pages the user reads and writes (Area/Project folder notes as overviews, plus human pages), any language, that link *down* into `wiki/` for depth. **Light** discipline: dead links fail and folder notes act as MOCs — no `type`/`description`, and `status` is the user's free field. A page may be distilled from `wiki/` via `/distill`; the voice pass and publish decision are always human. There is no PARA `Resources` tier — reference material is a `wiki/` concept note or a page under an Area.

`00_Inbox`, `01_Journal`, `02_Daily`, `09_Templates` keep a loose capture schema (`title`/`date`/`tags`) and are excluded from lint/MOC checks.

## Prerequisites

The brain repo must be cloned at `~/SourceRoot/brain`. If it does not exist, tell the user:

> The brain repo is not found at `~/SourceRoot/brain`. Clone it from `jkrumm/brain` (private GitHub repo) and try again.

## Agent door

The first-party `obsidian-cli` (`/usr/local/bin/obsidian`) is metadata-aware — prefer it: `search`, `backlinks`, `orphans`, `deadends`, `eval` (Dataview). Fall back to plain filesystem reads/writes when Obsidian isn't running.

## How to read

1. Start at `/Users/jkrumm/SourceRoot/brain/index.md` and follow `[[wikilinks]]`.
2. Route by folder and by `type`/`tags` frontmatter. Each `wiki/` domain level has an `index.md` MOC; each curated Area/Project has a folder note (`{name}.md`) as its local MOC — open the MOC before reading children individually.
3. **Never** default-traverse `inbox/` or `00_Inbox/` — read them only on an explicit ingestion request.
4. For broad search, use `obsidian search` / `obsidian backlinks` (or `obsidian orphans` / `obsidian deadends` for graph health) rather than reading many files inline; delegate wide fan-out reads to the Explore subagent.

## How to write knowledge (`wiki/`)

- Prefer editing an existing concept over creating an orphan. Check with `obsidian search` first.
- Frontmatter: `type` + `description` required on every `wiki/` note; add `title`, `tags`, `timestamp` (ISO 8601) where meaningful.
- Links: `[[wikilinks]]` only. Every new note gets ≥1 outbound link.
- Update the nearest `wiki/` `index.md` MOC. Append a line to root `log.md`.
- Run `node .scripts/vault-lint.mjs` before committing; 0 errors required. Passing is necessary, not sufficient — judgment stays human.

Curating a **human page** (`03_Projects`/`04_Areas`) is lighter: no forced schema, link *down* into `wiki/` rather than duplicating detail, keep links resolving, and prefer editing the existing folder note over adding a new page.

## How to capture

For a quick capture (a stray thought, a URL, a one-line reminder), write it to `00_Inbox/` as a dated staging file with the loose capture schema (`title`, `date`, `tags`). Do not distill it inline — captures are promoted deliberately (see Ingestion).

## How to compile (human-readable output)

Compiled pieces live on the curated surface (an Area/Project folder note, or a human page), produced by `/distill` against `voice.md`, one named piece at a time. **Never auto-generate them in bulk.** Each may carry `status` + a `source` wikilink to the `wiki/` note(s) it distills. The voice pass, first-person content, and publish decision are always the human's — never automated.

## Ingestion (the careful contract)

**AGENTS.md → Ingestion is canonical** — read it before any migration. The full promotion runbook, the three wikilink cases, provenance/no-re-migration, and "migration preserves, does not recommend" all live there. The non-negotiables:

- **Never an autonomous loop.** v1 was scrapped for exactly that (`.docs/post-mortem-v1.md`). Promote one concept at a time, human-reviewed.
- Connectors and the vault drop **raw** captures into `00_Inbox/` only — never straight into an evergreen Area/Project/Resource. Log every skip with a reason in `log.md`; no silent drops.
- Show the user the `git diff` before it lands. Small batches.
- Do not touch `00_Inbox/`/`inbox/` or run ingestion unless explicitly asked.

## Safety

- Scope commits to one concern. Review `git diff --stat` before pushing.
- LiveSync (CouchDB) provides continuous cross-device backup, orthogonal to git; git remains the deliberate review + history gate. Commit deliberately (or via `/commit`) when a write is done, and push.
- Never commit secrets, real hostnames, or real IPs — use placeholders.

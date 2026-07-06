---
name: brain
description: Read and write the second brain — a git-backed Obsidian vault at ~/SourceRoot/brain (PARA structure, OKF-flavored). Use whenever the user mentions "brain", "second brain", "knowledge base", "note", "remember", "look up", "find note", "capture", or "okf". Also use for any request to save, retrieve, or organize personal knowledge that belongs in the brain rather than in a repo-specific doc.
---

# Brain — second-brain interaction skill

Interact with the private knowledge base at `~/SourceRoot/brain` (`jkrumm/brain`): one folder that is **both** an Obsidian vault and the git-backed second brain, shared by Claude Code (this skill) and Hermes (`obsidian` skill). The full traversal + write + ingestion contract is in the repo's `AGENTS.md` — read it before any non-trivial write; this skill encodes the behavioral instructions. Validation uses `node scripts/vault-lint.mjs`.

Two layers, mapped onto PARA's evergreen dirs (`03_Projects`, `04_Areas`, `05_Resources`):

- **Agentic knowledge** — the child notes under an Area/Project (frontmatter `type` + `description`, `[[wikilinks]]`). Terse, structured, cross-linked. The canonical store agents read and write by traversal.
- **Compiled / voiced** — the Area/Project folder note (`{name}.md`, Folder Notes plugin), carrying `status: personal|draft|published`. Polished, first-person, produced by `/distill`. Voice pass and publish decision are always human.

This schema/MOC/wikilink discipline applies only to evergreen dirs. `00_Inbox`, `01_Journal`, `02_Daily`, `09_Templates` keep a loose capture schema (`title`/`date`/`tags`) and are excluded from lint/MOC checks.

## Prerequisites

The brain repo must be cloned at `~/SourceRoot/brain`. If it does not exist, tell the user:

> The brain repo is not found at `~/SourceRoot/brain`. Clone it from `jkrumm/brain` (private GitHub repo) and try again.

## Agent door

The first-party `obsidian-cli` (`/usr/local/bin/obsidian`) is metadata-aware — prefer it: `search`, `backlinks`, `orphans`, `deadends`, `eval` (Dataview). Fall back to plain filesystem reads/writes when Obsidian isn't running.

## How to read

1. Start at `/Users/jkrumm/SourceRoot/brain/index.md` and follow `[[wikilinks]]`.
2. Route by folder (PARA) and by `type`/`tags` frontmatter. Each evergreen Area/Project has a folder note (`{name}.md`) acting as a local MOC — open it to see the children before reading them individually.
3. **Never** default-traverse `inbox/` or `00_Inbox/` — read them only on an explicit ingestion request.
4. For broad search, use `obsidian search` / `obsidian backlinks` (or `obsidian orphans` / `obsidian deadends` for graph health) rather than reading many files inline; delegate wide fan-out reads to the Explore subagent.

## How to write knowledge

- Prefer editing an existing concept over creating an orphan. Check with `obsidian search` first.
- Frontmatter: `type` + `description` required on evergreen child notes; add `title`, `tags`, `timestamp` (ISO 8601) where meaningful.
- Links: `[[wikilinks]]` only. Every new note gets ≥1 outbound link.
- Update the nearest folder-note MOC. Append a line to root `log.md`.
- Run `node scripts/vault-lint.mjs` before committing; 0 errors required. Passing is necessary, not sufficient — judgment stays human.

## How to capture

For a quick capture (a stray thought, a URL, a one-line reminder), write it to `00_Inbox/` as a dated staging file with the loose capture schema (`title`, `date`, `tags`). Do not distill it inline — captures are promoted deliberately (see Ingestion).

## How to compile (human-readable output)

Compiled pieces are the Area/Project folder note (`{name}.md`), produced by `/distill` against `voice.md`, one named piece at a time. **Never auto-generate folder notes in bulk.** Each carries `status: personal|draft|published` + recommended `source` (wikilink to the child note(s) it distills). The voice pass, first-person content, and publish decision are always the human's — never automated.

## Ingestion (the careful contract)

**AGENTS.md → Ingestion is canonical** — read it before any migration. The full promotion runbook, the three wikilink cases, provenance/no-re-migration, and "migration preserves, does not recommend" all live there. The non-negotiables:

- **Never an autonomous loop.** v1 was scrapped for exactly that (`docs/post-mortem-v1.md`). Promote one concept at a time, human-reviewed.
- Connectors and the vault drop **raw** captures into `00_Inbox/` only — never straight into an evergreen Area/Project/Resource. Log every skip with a reason in `log.md`; no silent drops.
- Show the user the `git diff` before it lands. Small batches.
- Do not touch `00_Inbox/`/`inbox/` or run ingestion unless explicitly asked.

## Safety

- Scope commits to one concern. Review `git diff --stat` before pushing.
- LiveSync (CouchDB) provides continuous cross-device backup, orthogonal to git; git remains the deliberate review + history gate. Commit deliberately (or via `/commit`) when a write is done, and push.
- Never commit secrets, real hostnames, or real IPs — use placeholders.

---
name: brain
description: Read and write the second brain — an OKF-native private knowledge base at ~/SourceRoot/brain. Use whenever the user mentions "brain", "second brain", "knowledge base", "note", "remember", "look up", "find note", "capture", or "okf". Also use for any request to save, retrieve, or organize personal knowledge that belongs in the brain rather than in a repo-specific doc.
---

# Brain — second-brain interaction skill

Interact with the private knowledge base at `~/SourceRoot/brain` (`jkrumm/brain`). Agents both read and write by traversing the file tree — there is no database and no API. The full traversal contract is in the repo's `AGENTS.md`; this skill encodes the behavioral instructions.

## Prerequisites

The brain repo must be cloned at `~/SourceRoot/brain`. If it does not exist, tell the user:

> The brain repo is not found at `~/SourceRoot/brain`. Clone it from `jkrumm/brain` (private GitHub repo) and try again.

Validation uses `bun scripts/okf-lint.mjs` — Bun must be available.

## How to read

1. Start at `/Users/jkrumm/SourceRoot/brain/index.md` and follow bundle-relative absolute links (e.g. `[x](/notes/x.md)`).
2. Use `type` and `tags` frontmatter to route: `type` tells you what kind of document you are looking at; `tags` help you filter within a directory.
3. Never default-traverse `journal/` or `inbox/`. Only read these directories on an explicit request (e.g. "check today's journal", "process the inbox").
4. For broad searches across the repo, delegate to the Explore subagent rather than reading files inline. Scope the search to the relevant directory (`notes/`, `wiki/`, `content/`) unless the user explicitly asks for a full-repo search.

## How to write

- Prefer editing existing concepts and fixing cross-links over creating orphans. Before creating a new note, check whether an existing concept document already covers the topic and can be extended.
- Every new note gets frontmatter with `type` + `description` + at least one outbound link to another concept or to the nearest `index.md`. Include `timestamp` (ISO 8601) when the content has a temporal anchor.
- Update the nearest `index.md` — if you added, renamed, or removed a concept document in a directory, the index must reflect it.
- Append a line to `log.md` with the date, a one-line summary of the change, and a link to the affected file(s).
- Cross-link with bundle-relative absolute paths (e.g. `/notes/some-concept.md`). These are stable across file moves, unlike relative links.
- Before committing, run the quality gate: `cd ~/SourceRoot/brain && bun scripts/okf-lint.mjs`. If it fails, fix the issues before committing. Do not commit a write that fails the lint.

## How to capture

For quick captures (a stray thought, a URL, a one-line reminder):

1. Write directly to `inbox/` as a staging markdown file named by date-topic (e.g. `inbox/2026-07-05-idea.md`).
2. Frontmatter: `type: Capture`, `timestamp` (ISO 8601), and a `description` summarizing the capture.

For promotion from inbox to a permanent note:

1. Distill the capture into a concept document in `notes/` with full OKF frontmatter.
2. Add cross-links to related concepts and the nearest `index.md`.
3. Update the index, append to `log.md`, and either delete the inbox file or add a `migrated-to: /notes/<target>.md` frontmatter field.

## How to find

| What | Where | Traversal rule |
|-|-|-|
| Evergreen concept documents | `notes/` | Default-traversed |
| Curated human reference (future Argo surface) | `wiki/` | Default-traversed |
| Blog drafts | `content/` | Read only when frontmatter has `status: published` |
| Daily notes | `journal/` | Explicit request only |
| Inbox / staging captures | `inbox/` | Explicit request only |

When the user asks to "find" or "look up" something without specifying a scope, default to searching `notes/` and `wiki/`. Only search `inbox/` or `journal/` if the user explicitly names them or the context makes it obvious (e.g. "what did I journal about yesterday?").

## Observation: Obsidian vault is separate

The Obsidian vault at `~/Obsidian/Vault` is a separate surface — it syncs via LiveSync, is not versioned with git, and is not the brain. Do not assume files in the Obsidian vault live in the brain repo or vice versa. If the user wants to migrate content from the vault into the brain, that is an explicit migration task — ask before touching vault files.

## Safety

- Scope commits to one logical concern. Review `git diff --stat` before pushing.
- The brain-sync LaunchAgent (`com.jkrumm.brain-sync`) snapshots the repo every 10 minutes via `launchd/`. Do not fight it — if you see a dirty working tree from a sync snapshot, let it complete or wait for the next cycle. Your writes will be snapshotted on the next cycle.
- Never commit the `inbox/` or `journal/` directories from automated tooling unless the user asks. These are staging areas.

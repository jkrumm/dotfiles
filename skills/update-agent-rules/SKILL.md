---
name: update-agent-rules
description: Update agent rules (React, TanStack, Elysia best practices) from upstream GitHub repos. Use this skill when the user wants to update, sync, check versions, add new rule sets, or troubleshoot the rules setup. Also trigger when the user mentions "agent skills", "agent rules", "react rules", "tanstack rules", "elysia rules", or asks about the rules architecture.
---

# Update Agent Rules

Manages best-practice rules sourced from community agent-skills repos. These rules give Claude context-aware guidance when writing React/TanStack frontend code and Elysia backend code.

## Architecture

Two layers — lightweight index files auto-load during development, full reference files available on demand for deep reviews.

### Layer 1: Index Rules (auto-load via `paths:`)

Location: `~/SourceRoot/dotfiles/rules/`

| File | Source Repo | Paths | Rules |
|-|-|-|-|
| `react-best-practices.md` | `vercel-labs/agent-skills` | `**/*.tsx`, `**/*.jsx` | 69 rules — async, bundle, server, client, re-render, rendering, JS perf, advanced |
| `tanstack-query.md` | `DeckardGer/tanstack-agent-skills` | `**/routeTree.gen.ts`, `**/routes/**/*.ts(x)`, `**/router.tsx` | 21 rules — query keys, caching, mutations, error handling, prefetching, SSR |
| `tanstack-router.md` | `DeckardGer/tanstack-agent-skills` | `**/routeTree.gen.ts`, `**/routes/**/*.ts(x)`, `**/router.tsx` | 15 rules — type safety, route org, data loading, search params, navigation |
| `tanstack-start.md` | `DeckardGer/tanstack-agent-skills` | `**/routeTree.gen.ts`, `**/routes/**/*.ts(x)`, `**/router.tsx` | 13+4 rules — server functions, security, middleware, auth + integration patterns |
| `elysia.md` | `elysiajs/skills` | `**/api/**/*.ts`, `**/server/**/*.ts` | Key concepts — method chaining, encapsulation, validation, MVC, plugins |

`react-best-practices.md` stays on the broad `.tsx`/`.jsx` glob — it's genuinely React/Next.js-generic, not tied to any router. The three TanStack files scope to `routeTree.gen.ts`/`routes/`/`router.tsx` instead: that combination is essentially unique to a TanStack Router/Start project, whereas `**/*.tsx` alone matches Next.js, Remix, CRA, or any incidental `.tsx` file — which was firing all three TanStack rule sets in repos that never touch TanStack.

Frontend rules load on their scoped paths (~5K tokens). Elysia rule loads on backend `.ts` files in `api/` or `server/` dirs (~3.5K tokens). Zero cross-contamination.

### Layer 2: Full Reference (manual reads)

Location: `~/SourceRoot/dotfiles/reference/`

```
reference/
  react-best-practices/   # 69 .md files with code examples (bad → good)
  tanstack-query/          # 21 .md files
  tanstack-router/         # 15 .md files
  tanstack-start/          # 13 .md files
  tanstack-integration/    #  4 .md files
  elysia/                  # 52 files across 5 subdirs
    references/            # 11 .md — core docs (route, validation, lifecycle, plugin, etc.)
    plugins/               # 11 .md — official plugin docs (cors, jwt, openapi, otel, etc.)
    integrations/          # 15 .md — drizzle, better-auth, tanstack-start, etc.
    patterns/              #  1 .md — MVC pattern
    examples/              # 14 .ts — code examples
```

These are the original files from the upstream repos — unmodified. Frontend rules total ~81K tokens. Elysia reference total ~152KB. The `/review` skill reads these when reviewing code.

**Elysia live docs:** For the latest API (beyond local reference), fetch `https://elysiajs.com/llms.txt` and follow specific topic URLs.

### Version Tracking

Each index rule file has a `source:` field in its YAML frontmatter:

```yaml
source: vercel-labs/agent-skills@73140fc (2026-04-02)
source: DeckardGer/tanstack-agent-skills@0e8bcdc (2026-04-03)
source: elysiajs/skills@8fd8031 (2026-01-20)
```

Format: `{org}/{repo}@{short-sha} ({date})`. Compare against upstream to check for updates.

## Update Process

### 1. Check for upstream changes

```bash
# Clone fresh copies
cd /tmp
git clone --depth 1 https://github.com/vercel-labs/agent-skills.git
git clone --depth 1 https://github.com/DeckardGer/tanstack-agent-skills.git
git clone --depth 1 https://github.com/elysiajs/skills.git elysia-skills

# Compare commit hashes against source: fields in rules/
git -C /tmp/agent-skills log -1 --format="%h %ci"
git -C /tmp/tanstack-agent-skills log -1 --format="%h %ci"
git -C /tmp/elysia-skills log -1 --format="%h %ci"
```

If the hashes match what's in the `source:` frontmatter, no update needed.

### 2. Update reference files (full rules)

Copy the original rule files — no modifications:

```bash
DOTFILES_DIR=~/SourceRoot/dotfiles

# React best practices
rm -rf "$DOTFILES_DIR/reference/react-best-practices"
mkdir -p "$DOTFILES_DIR/reference/react-best-practices"
cp /tmp/agent-skills/skills/react-best-practices/rules/*.md "$DOTFILES_DIR/reference/react-best-practices/"
rm -f "$DOTFILES_DIR/reference/react-best-practices/_template.md" "$DOTFILES_DIR/reference/react-best-practices/_sections.md"

# TanStack (all 4 packages)
for skill in tanstack-query tanstack-router tanstack-start tanstack-integration; do
  rm -rf "$DOTFILES_DIR/reference/$skill"
  mkdir -p "$DOTFILES_DIR/reference/$skill"
  cp "/tmp/tanstack-agent-skills/skills/$skill/rules/"*.md "$DOTFILES_DIR/reference/$skill/"
done

# Elysia (preserves subdirectory structure)
rm -rf "$DOTFILES_DIR/reference/elysia"
for subdir in references plugins integrations patterns examples; do
  mkdir -p "$DOTFILES_DIR/reference/elysia/$subdir"
done
cp /tmp/elysia-skills/elysia/references/*.md "$DOTFILES_DIR/reference/elysia/references/"
cp /tmp/elysia-skills/elysia/plugins/*.md "$DOTFILES_DIR/reference/elysia/plugins/"
cp /tmp/elysia-skills/elysia/integrations/*.md "$DOTFILES_DIR/reference/elysia/integrations/"
cp /tmp/elysia-skills/elysia/patterns/*.md "$DOTFILES_DIR/reference/elysia/patterns/"
cp /tmp/elysia-skills/elysia/examples/*.ts "$DOTFILES_DIR/reference/elysia/examples/"
```

### 3. Update index rules

Read the upstream SKILL.md files — they contain the quick-reference lists:

```
/tmp/agent-skills/skills/react-best-practices/SKILL.md
/tmp/tanstack-agent-skills/skills/tanstack-query/SKILL.md
/tmp/tanstack-agent-skills/skills/tanstack-router/SKILL.md
/tmp/tanstack-agent-skills/skills/tanstack-start/SKILL.md
/tmp/tanstack-agent-skills/skills/tanstack-integration/SKILL.md
/tmp/elysia-skills/elysia/SKILL.md
```

For each, diff against the existing index rule in `rules/`. Look for:
- New rules added (new lines in Quick Reference sections)
- Rules removed or renamed
- Priority changes
- Category restructuring

Update the index files in `rules/` to reflect changes. Preserve the Claude Code frontmatter:

```yaml
---
description: <keep existing or update if scope changed>
paths: <keep the existing scoped globs — preserve per-file, see the table above>
source: {org}/{repo}@{new-short-sha} ({new-date})
---
```

The tanstack-start index file also includes tanstack-integration rules at the bottom — update both sections.

The elysia index file distills the SKILL.md to key concepts (method chaining, encapsulation, validation, MVC, plugins) and points to reference files + llms.txt for deep dives. It uses `paths: ["**/api/**/*.ts", "**/server/**/*.ts"]` to scope to backend workspaces.

### 4. Verify and clean up

```bash
# Verify file counts match upstream
for d in react-best-practices tanstack-query tanstack-router tanstack-start tanstack-integration; do
  echo "$d: $(ls ~/SourceRoot/dotfiles/reference/$d/*.md | wc -l | tr -d ' ') files"
done
for subdir in references plugins integrations patterns examples; do
  echo "elysia/$subdir: $(ls ~/SourceRoot/dotfiles/reference/elysia/$subdir/* | wc -l | tr -d ' ') files"
done

# Verify rules are visible via symlink
ls ~/.claude/rules/react-best-practices.md ~/.claude/rules/tanstack-query.md ~/.claude/rules/tanstack-router.md ~/.claude/rules/tanstack-start.md ~/.claude/rules/elysia.md

# Clean up
rm -rf /tmp/agent-skills /tmp/tanstack-agent-skills /tmp/elysia-skills
```

### 5. Commit

Commit in dotfiles with: `docs: update frontend agent rules from upstream`

## Adding a New Rule Set

To add rules from a new agent-skills repo:

1. Clone the repo, inspect its `skills/` directory structure
2. Copy original rule files to `reference/{name}/`
3. Create an index rule file in `rules/{name}.md` from the repo's SKILL.md — add `paths:` and `source:` frontmatter
4. Verify symlink visibility via `~/.claude/rules/`
5. Commit in dotfiles

## Troubleshooting

**Rules not loading on expected files:** Check `~/.claude/rules/` symlink points to `~/SourceRoot/dotfiles/rules/`. Run `make setup` if broken.

**Rules firing in unrelated repos:** `paths:` only matches file globs — it can't detect actual dependency usage, so a blanket `**/*.tsx` fires in any React-ish repo regardless of whether it uses that specific library. Scope to a file/directory convention that's essentially unique to the framework (e.g. `routeTree.gen.ts` for TanStack Router/Start) instead of the file extension alone.

**Too much context:** The index files total ~5K tokens. If this grows with new rule sets, prefer scoped paths over `**/*.tsx` from the start.

**Review skill not finding reference files:** Ensure paths in the review skill match `~/SourceRoot/dotfiles/reference/`. The reference directory is NOT in `~/.claude/rules/` — it lives only in the dotfiles repo.

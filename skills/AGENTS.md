# skills

**Adding a global skill:** `skills/{name}/SKILL.md` → `make setup`. **Per-repo
skill:** `.claude/skills/{name}/SKILL.md`, committed, no symlink. **Global rule:**
`rules/{name}.md` — the whole dir is symlinked; no `paths:` means always-on.

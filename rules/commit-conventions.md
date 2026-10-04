---
description: Conventional commits format and amend rules — loaded by /commit and when a commit message is open
paths: ["**/COMMIT_EDITMSG"]
---

# Commit Conventions

Format: `{type}({scope}): {description}`

- Concise but descriptive, focus on "why" over "what"
- Use `/commit` skill for intelligent commit generation
- **basalt-ui**: ALWAYS separate commit (NPM published package)
- Full-stack features: keep together (don't split by frontend/backend)
- IuRoot: use ticket arg for EP-XX; SourceRoot: no tickets

## Amend Rule (Critical)

**NEVER create single-line/trivial fix commits.** Always fold follow-up fixes into the commit that introduced the issue using `/commit --amend`.

If running manually (feature branch only):
```bash
git add <files>
git commit --amend --no-edit
git push --force-with-lease
```
This applies to: CI failures, lint fixes, export order, missing deps, config tweaks caused by your own changes. Single-fix commits are noise.

## Iteration

- Multiple logical changes → `/commit --split`
- CodeRabbit/SonarQube fixes → `/commit --amend`

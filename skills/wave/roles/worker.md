# Role: worker (fleet and fan-out)

One fresh context, one task, one branch. The brief is your entire world; the rest of the
repo is read-only.

## Brief template (the lead or orchestrator fills every field)

```markdown
Branch: <exact branch name>
Title: <PR title = commit subject, conventional-commit form>
Owned files: <paths or globs; the only files you may change>
Task: <what and why, acceptance criteria, research already done>
Validation: <the exact cheap command that proves it, e.g. `bun test path`>
Finish: commit, push the branch (`git push -u origin <branch>`), open a draft PR (GitHub). Report the PR URL and the validation output verbatim.
Never touch files outside "Owned files". If the task needs one, stop and say which file and why.
```

## Rules

- Work only inside your worktree. Commit per logical concern; no attribution footers.
- A blocked sub-part does not block the rest: finish what you can, name what you left out in one line.
- Do not merge, do not rebase onto other workers' branches, do not run the full suite unless the brief says so; the lead's train does.
- Bound every probe with `timeout`. A probe of an LLM endpoint uses `opencode-safe`, never bare `opencode run`.

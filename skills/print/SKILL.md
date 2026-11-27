---
name: print
description: Print a file on the Mac's printer, check the queue or toner, or cancel a print job, through the one print command (two-sided long edge by default). Use whenever a document has to be printed or a print job checked or cancelled. Never hand-write an lp or cancel command.
---

# Print

One command for every print, on both Macs. In zsh type `command print`: the builtin `print` shadows the bare name and only echoes its arguments.

```bash
command print --check                    # queue: state, toner, queued jobs
command print <file> --dry-run           # the lp argv, submits nothing
command print <file> [--pages 1-3] [--copies N] [--simplex]
command print --status | --cancel <jobId> | --cancel-all
command print --help                     # every flag and the JSON contract
```

- Two-sided, long edge is the default. `--simplex` only when asked.
- Every call prints one JSON line; exit 0 means `ok: true`.
- Dry-run first when unsure. A proof never prints a real page: `--dry-run`, `--check`, `--status`, or `--hold` then `--cancel <jobId>`.
- Cancel only your own jobs.

The full contract (device capabilities, the rules) belongs to the CLI's repo: tinycast-extensions `.claude/skills/print/SKILL.md`.

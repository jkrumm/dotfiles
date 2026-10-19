---
name: prose
description: Polish a finished human-facing draft through the agent-gateway prose tool — lint, cross-lab review, Opus rewrite, keep gate. Use after drafting articles, vault pages, docs/README, landing or UI copy, or briefings against brain/voice.md, or when the user says "prose", "polish this", "de-slop", "run it through prose". Not for chat replies, code comments, or commit messages.
---

# Prose — via `agw prose`

One call runs a finished draft through agent-gateway's `prose` tool: mechanical lint → cross-lab review → Opus rewrite → **keep gate**. It returns the rewrite, or the **original** when the gate judged the rewrite worse. ~20-90 s, ~$0.05 per call.

## When

After drafting against `~/SourceRoot/brain/voice.md`: articles, vault pages, docs/README, landing and UI copy, briefings. Not chat replies, code comments, commit messages, or anything you have not drafted yet — it polishes, it does not write from facts.

## How

1. Write the draft to a temp file (`mktemp`), nothing but the text to polish. Custom components, callouts and shortcodes are **not preserved** — exclude them from the file and splice the result back around them.
2. Run the CLI (prefer it over the MCP tool; it works when the MCP server is disconnected):

```bash
agw prose /tmp/draft.md --medium article --language en --out /tmp/draft.out.md
```

| Flag | Use |
|-|-|
| `--medium article\|vault\|docs\|briefing\|landing\|ui\|chat` | Pick the real destination; it sets the register and lint profile |
| `--language en\|de` | The draft's language |
| `--register <r>` | Override the medium's default register |
| `--brief <text>` | Reader and goal in a sentence when the medium alone does not say |
| `--context <file>` | The document outline — **always** when sending one section of a larger doc |
| `--no-verdict-first` | The order is deliberate (e.g. compare-then-decide); otherwise the rewrite leads with the verdict |
| `--out <file>` / `-` / `--json` | Text goes to stdout or `--out`; stdin via `-`; `--json` for the structured result |

Exit non-zero = job failure; say so, do not fall back to claiming it was polished. MCP alternative: `mcp__agent-gateway__prose` returns `{ jobId }` → `mcp__agent-gateway__job_wait({ jobId })`.

## Reading the result

stderr carries a one-line summary (`kept`, `keptReason`, `costUsd`) then the reviewer notes.

- **Kept original** (`kept` = original) = the gate rejected the rewrite. Keep the original. **Do not loop** — a second call on the same text buys the same verdict.
- **Reviewer notes are advisory.** Apply the ones that hold, ignore the rest.
- **`invented_content` notes mean check facts** — the rewrite may have added a claim, number or first-person opinion. Verify against the source or strip it before using the text.
- Output format mirrors input (markdown in → markdown out, html in → html out).
- Diff the result against the draft before replacing anything; the human still owns the final read.

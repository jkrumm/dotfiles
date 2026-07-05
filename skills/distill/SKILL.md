---
name: distill
description: Write, draft, and polish prose through a human-owned 7-step pipeline. Use whenever the user says "distill", "write article", "draft", "summarize into", "create content", "synthesize", or "publish". Also use for any task where the output is a piece of long-form writing — the pipeline keeps prose quality out of coding sessions.
model: opus
---

# Distill — prose writing pipeline

A human-owned 7-step pipeline for producing writing that sounds like the author, not the model. This skill runs on Opus because prose quality demands the best model. It is not a content generator — it is a scaffold that keeps the human in control at every gate.

Output lands in the brain repo at `~/SourceRoot/brain/content/<project>/` with `status: draft` frontmatter. Publishing is always the human's decision.

## Pipeline

### 1. Brief

The human sets the brief. Without it the model fills with defaults, and defaults are generic. Ask for:

- **Reader** — who is this for? One real person or a tight group.
- **Goal** — what should the reader think, feel, or do after reading?
- **Angle** — the specific lens or contrarian take. What makes this not a Wikipedia article?
- **Format** — blog post, essay, technical deep-dive, email, etc.
- **Length** — approximate word count or section count.

Do not proceed past this step until the brief is explicit. If the human pushes back with "just start," push back: a missing brief costs more time in revisions than 90 seconds upfront.

### 2. Outline

The human owns the structure. The model may offer 2-3 outline options to react to, but the human picks and shapes the final structure. Key principle: **deliberate asymmetry** — not every section gets equal weight. The best outlines have short punchy sections next to dense ones.

Deliver the outline as a nested list of section headings with one-line summaries. Wait for the human to approve or reshape before moving on.

### 3. Seed

The human writes seed sentences per section — the specific claims, examples, or observations that only they can supply. These are the non-obvious bits: the anecdote, the counterintuitive data point, the hard-won lesson. Without seeds the model fills those slots with generic framing.

Seeds do not need to be polished. A fragment or bullet is fine. The model's job is to expand around them, not replace them.

### 4. Draft

Expand around the seeds using `voice.md` as a style guide. Load it from the brain repo: `~/SourceRoot/brain/voice.md`. If the voice guide is still a placeholder (check the `STATUS` field), warn the human:

> The voice guide at `~/SourceRoot/brain/voice.md` is still a placeholder — results will be generic. Consider finalizing the voice guide first for better output.

Formulaic or background sections are fine where needed (context the reader genuinely lacks), but keep them tight. The seeds carry the weight. Write in the author's voice, not the model's defaults.

### 5. Voice Pass

**This step is human-owned. The model never performs it.** Remind the human to:

- Read the draft aloud.
- Cut 10-20% of the word count — every sentence that survives should carry weight.
- Replace consensus phrasing ("it's important to note," "in today's fast-paced world," "unprecedented") with the author's actual speech patterns.
- Check that the seeds are still the loudest parts.

The model's role here is to remind and then wait. Do not offer to "help with the voice pass."

### 6. De-slop Gate

Score the draft against the 5-dimension rubric below. The model can score and produce a breakdown; the human confirms. Below 35/50 means revise before proceeding. Each dimension is scored 0-10.

| Dimension | What it measures |
|-|-|
| **Directness** | Sentences that lead with the point. No throat-clearing, no hedging, no "it is worth noting that." |
| **Rhythm** | Varied sentence length. Short sentences land. Long ones build. Paragraphs breathe. |
| **Trust** | The reader feels the author knows something specific. Concrete over abstract. Numbers over adjectives. |
| **Authenticity** | Sounds like a person, not a committee. Opinions are owned. Jargon is defined or earned. |
| **Density** | Information per sentence. No filler, no throat-clearing, no recapping what the reader just read. |

Scoring guide:
- 8-10: Consistently strong across the piece.
- 5-7: Mixed — some passages hit, others drift toward generic.
- 0-4: The dimension is largely absent or actively working against the piece.

Report the score as a table with a one-line note per dimension. If the total is below 35, flag the weakest dimensions and suggest a targeted revision pass.

### 7. Human Polish + Fact-Check

Never skipped. Remind the human:

- Every factual claim is their responsibility. The model cannot verify facts.
- The "I" rule: any sentence containing "I," "my," "we," "our," or an opinion must have been written or explicitly approved by the human. The model may draft opinions as placeholders, but the human must replace or confirm them.
- Links, citations, dates, and technical claims need manual verification.

## Constraints

- Never write first-person content. Placeholder opinions are marked with a `[CONFIRM: ...]` inline tag for the human to replace.
- Never skip the voice-pass gate. If the human wants to skip it, flag that the voice pass is the single highest-leverage step for making the output sound like them.
- Never publish. The model writes to `content/<project>/` with `status: draft`. The human decides when and where to publish.
- Output always goes to the brain repo at `~/SourceRoot/brain/content/<project>/`. If the project directory does not exist, create it and add an `index.md` listing the draft.
- After writing, run `cd ~/SourceRoot/brain && bun scripts/okf-lint.mjs` and fix any issues before declaring the step complete.

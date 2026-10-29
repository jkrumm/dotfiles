---
name: podcast
description: Turn notes (a brain note, a file, pasted text) into a long-form two-host podcast episode — German by default, Gemini multi-speaker TTS, chapters + cover — and publish it into Audiobookshelf via `agw podcast`. Use when the user says "podcast", "als Podcast", "Audio-Briefing", "zum Anhören", "Hörfassung", or wants a plan/article/research turned into something to listen to on a drive.
---

# Podcast — `agw podcast`

`agw podcast` (agent-workflows, audio process on the mini) owns the whole
pipeline: research (brain search + past episodes + the research workflow) → an
editorial pass that decides format, roles, tone, humor and length *for this
episode* → writers' room (outline, parallel segment writers, three reviewers,
revision, metadata) → two-host script → multi-speaker TTS → ffmpeg mastering
(−16 LUFS, ID3, chapters, cover) → Audiobookshelf upload → transcript note in
the brain under `Areas/Podcasts/` → Slack notice. Mini-only (needs `agw`).
Models live in the route table, not here: agent-workflows
`packages/audio/src/workflows/podcast/README.md` (§Models and wires).

It is an **async run**: expect 15–25 min for a 20-minute episode. The CLI waits
up to `AGW_WAIT_BUDGET_S` (110 s), then exits **10 = still running**, which is
not an error.

```bash
AGW_PURPOSE=prod agw podcast \
  --source-paths '["Areas/Travel/Northern Spain 2026/Northern Spain 2026.md"]' \
  --brief "…" --minutes 20 --publish --series "Brain Sonderausgabe"
agw run wait <runId>                    # on exit 10; repeat until it returns
agw run status <runId>                  # one-shot state
agw podcast-publish <runId> --commit    # re-run only the upload + brain note
```

Other flags: `--title`, `--language de|en`, `--no-cover`, `--no-research`,
`--pin-minutes`, `--no-brain-note`. Source text that is not in the vault (a
URL's content, an article) goes on stdin (`agw podcast … < file.md`).

## Flow

1. **Point it at the source, don't re-gather it.** A brain note goes in by
   vault-relative path via `--source-paths` (JSON array); the room reads it
   itself and runs its own research loop. Only material that is NOT in the
   vault goes through stdin. Never paste a note that `--source-paths` can name.
2. **Write the brief.** One or two sentences: who listens and what they want.
   Johannes is usually the listener and the author of the notes, so say so:
   `--brief "Johannes plant genau diese Reise mit dem Camper; sprich ihn direkt
   an und gib konkrete Ratschläge."` Build long briefs from a file
   (`--brief "$(cat brief.txt)"`), not inline multi-paragraph quoting.
3. **Length + target.** `--minutes` is a hint the editor may deviate from
   (`--pin-minutes` forces it), clamped 3..60: 15–25 for a drive briefing, 8–10
   for a summary. Add `--publish` unless the user only wants the file.
4. **Run it, report the runId at once** if the user is waiting, then wait on it.
5. **Hand over** from `agw run status <runId> --format json`; everything lives
   under `output.`: `output.title`, `output.produce.durationSeconds`,
   `output.produce.chapters[].title`, `output.produce.abs.url` (playable in
   Plappa), `output.produce.mp3Path`, `output.produce.coverPath`,
   `output.produce.brainNote.path`, `output.produce.publish`, and the episode
   price `output.cost.totalUsd` (`output.cost.researchUsd` separately). The
   top-level `cost` is a number for the parent run's own steps only — never
   report it as the price. The transcript is the brain note in the vault.
6. **Iterate on the script, not the audio.** A different angle means changing
   `--brief`/`--title`/`--minutes` and running again (a new episode); read the
   transcript note first, the script is the larger share of the cost.

## Errors

- Run `failed`: quote the top-level `error.message` verbatim. Rerun once with the same arguments
  only for a transport hiccup (socket closed, timeout, 502/503); anything else is
  reported, not retried.
- `status: done` with `output.produce.abs: null` and `output.produce.publish.ok === false` is
  produced but NOT published: quote `output.produce.publish.error`, then
  `agw podcast-publish <runId> --commit`. Rerunning `agw podcast` makes a new
  episode.
- `not configured` on publish: the audio process has no `ABS_*` env — a host
  fix, not a rerun.
- Audio is kept 30 days; `podcast-publish` on an older episode fails at the read.

---
name: podcast
description: Turn notes (a brain note, a file, pasted text) into a long-form two-host podcast episode — German by default, ElevenLabs v3, chapters + cover — and publish it into Audiobookshelf via audio-gateway. Use when the user says "podcast", "als Podcast", "Audio-Briefing", "zum Anhören", "Hörfassung", or wants a plan/article/research turned into something to listen to on a drive.
---

# Podcast — via audio-gateway's podcast pipeline

audio-gateway (`~/SourceRoot/audio-gateway`) owns the whole pipeline, running as
a **second instance on the mini** (`:7719`, `com.jkrumm.audio-gateway`) because
the pipeline now researches the brain (a git checkout that only exists here)
before writing — the VPS container keeps STT/TTS only. Research (brain search +
past episodes + the research gateway, tool-calling) feeds an editorial pass that
decides format, roles, tone, humor and length for *this* episode — there is no
fixed formula. The writers' room (story pass → parallel segment writers → three
reviewers → per-segment revision → metadata; Opus 5 plans, Opus 4.6 owns the
voice, Gemini 3.8 Flash + GPT-5.6 Luna review, Luna writes the metadata)
produces the two-host script, every turn is synthesized on ElevenLabs v3 with
its host's voice and per-host loudness matching, ffmpeg masters it (loudnorm
−16 LUFS, ID3 tags, chapter markers, embedded cover), the image-gen gateway
paints the cover, and Audiobookshelf's upload + scan API files it as an episode
of a podcast (show) in the `Podcasts` library. The finished transcript is also
written back into the brain under `Areas/Podcasts/`. It is an **async job**:
submit → poll → fetch. Budget 15–25 min of wall-clock for a 20-minute episode
and roughly 5–6 USD (≈2 USD ElevenLabs, the rest writer/reviewer/research
tokens).

The CLI wraps the HTTP API and is the door from Claude Code:

```bash
cd ~/SourceRoot/audio-gateway
bun run podcast -- --source <file.md> [--path <brain-relative note path>]... \
  [--brief "…"] [--title "…"] [--minutes 20] [--series "Brain Sonderausgabe"] \
  [--language de] [--publish] [--no-cover] [--no-research] [--pin-minutes] \
  [--no-brain-note] [--base-url http://localhost:7719] [--out ./out] [--json]
bun run podcast -- status <id>          # one-shot job state
bun run podcast -- list                 # latest jobs
bun run podcast -- publish <id>         # (re-)publish a finished job to Audiobookshelf
```

`--source -` reads stdin; `--path` (repeatable) has the gateway read a
brain-relative note itself, making `--source` optional. `--no-research` skips
the research stage, `--pin-minutes` stops the editor deviating from
`--minutes`, `--no-brain-note` skips the transcript note. `--base-url` defaults
to `$PODCAST_BASE_URL`, else `http://localhost:7719` — the mini instance; from
the MacBook use `https://podcasts.mini.jkrumm.com`. The CLI polls until
`done`/`failed`, prints stage progress (and the episode's `profile` — format,
lead, humor, minutes — once the editorial pass has run), downloads
`episode.mp3`, `cover.png` and `script.json` into `--out` (default
`./out/podcasts/<id>/`), and prints the Audiobookshelf link when published.

## Flow

1. **Get the source.** A brain note → read it with `/brain` (or `cat` the file
   under `~/SourceRoot/brain/…`); a URL or article → fetch it to a temp file;
   pasted text → write it to a temp file. Pass the *whole* text — the writer
   only speaks facts that are in the source, so thin input makes a thin episode.
2. **Write the brief.** One or two sentences: who the listener is and what they
   want. Johannes is usually the listener and usually the author of the notes,
   so say so: `--brief "Johannes plant genau diese Reise mit dem Camper; sprich
   ihn direkt an und gib konkrete Ratschläge."` The hosts then talk *to* him
   about *his* plan instead of narrating a travelogue.
3. **Pick length + target.** `--minutes` is a hint the editor may deviate from
   (pass `--pin-minutes` to force it) — 15–25 for a drive briefing, 8–10 for a
   quick summary. `--publish` unless the user only wants the file. The mini
   instance (`http://localhost:7719`, the CLI's default) is the one with brain
   access and `ABS_*` configured — always use it for real episodes.
4. **Run it.** Report the job id immediately if the user is waiting on chat;
   the CLI blocks until done. Then hand over: title, duration, chapter list,
   the Audiobookshelf link (playable in Plappa), cost, and the local
   `episode.mp3` path.
5. **Iterate on the script, not the audio.** If the user wants a different
   angle, change `--brief`/`--title`/`--minutes` and re-run — with the strong
   writer models the script is now the larger share of the cost, so review the
   transcript before re-running. `GET /v1/podcasts/<id>/script?format=md` (or `script.json` in `--out`)
   is the transcript to review.

## Knobs (gateway env, see audio-gateway `config.ts`)

| Var | Default | Meaning |
|-|-|-|
| `PODCAST_RESEARCH_MODEL` / `PODCAST_EDITORIAL_MODEL` | `gpt-5.6-luna` / `claude-opus-5` | tool-calling researcher (brain, past episodes, research gateway) / decides format, roles, tone, humor, length per episode |
| `PODCAST_OUTLINE_MODEL` / `PODCAST_WRITE_MODEL` | `claude-opus-5` / `claude-opus-4-6` | story pass / the voice owner (segments + every revision) |
| `PODCAST_REVIEW_MODELS` / `PODCAST_METADATA_MODEL` | `gemini-3.8-flash,gpt-5.6-luna` / `gpt-5.6-luna` | three review lenses × each model, notes only / title, show notes, cover prompt, chapter titles, topics |
| `PODCAST_SHOW_BIBLE` | `./docs/show-bible.md` | binding house style injected into every writer and reviewer prompt |
| `BRAIN_DIR` / `RESEARCH_API_KEY` | `/Users/jkrumm/SourceRoot/brain` / — | unset either and research + the brain note are skipped |
| `PODCAST_TTS_MODEL` | `elevenlabs/v3` | per-turn synthesis |
| `PODCAST_VOICES` / `PODCAST_HOST_NAMES` | `Mark,Sarah` / `Jonas,Lena` | host A, host B |
| `PODCAST_STABILITY` / `PODCAST_SPEEDS` | `0.5` / `0.94,1` | v3 stability preset (0 / 0.5 / 1) · per-host speed |
| `PODCAST_SERIES` | `Brain Sonderausgabe` | default show name in Audiobookshelf |
| `ABS_URL` / `ABS_API_KEY` / `ABS_LIBRARY` | — / — / `Podcasts` | publishing target; unset = publish disabled |
| `IMAGE_GEN_URL` / `IMAGE_GEN_API_KEY` | — | cover generation; unset = no cover |

## Errors

- `failed` with `error` mentioning `Replicate` → ElevenLabs lane hiccup; re-run
  once. Repeated → `/otel` on `audio.podcast` spans.
- `no podcast library named …` → `ABS_LIBRARY` doesn't match a mediaType=podcast
  library on that Audiobookshelf; list them with `GET /api/libraries`.
- `not configured` on publish → the gateway you hit has no `ABS_*` env; use
  `bun run podcast -- publish <id>` against a gateway that has it, or download
  the mp3 and upload by hand.

Same job, from Hermes: the `podcast` skill in `hermes-agent` curls the same
`/v1/podcasts` API.

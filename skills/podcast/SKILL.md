---
name: podcast
description: Turn notes (a brain note, a file, pasted text) into a long-form two-host podcast episode — German by default, ElevenLabs v3, chapters + cover — and publish it into Audiobookshelf via audio-gateway. Use when the user says "podcast", "als Podcast", "Audio-Briefing", "zum Anhören", "Hörfassung", or wants a plan/article/research turned into something to listen to on a drive.
---

# Podcast — via audio-gateway's podcast pipeline

audio-gateway (`~/SourceRoot/audio-gateway`) owns the whole pipeline: a two-pass
LLM writer (outline → per-segment dialogue) produces a two-host conversation
script, every turn is synthesized on ElevenLabs v3 with its host's voice, ffmpeg
masters it (loudnorm −16 LUFS, ID3 tags, chapter markers, embedded cover), the
image-gen gateway paints the cover, and Audiobookshelf's upload + scan API files
it as an episode of a podcast (show) in the `Podcasts` library. It is an
**async job**: submit → poll → fetch. Budget ~1 min of wall-clock per 3 min of
audio; a 20-minute episode costs roughly 2–4 USD (ElevenLabs chars dominate).

The CLI wraps the HTTP API and is the door from Claude Code:

```bash
cd ~/SourceRoot/audio-gateway
bun run podcast -- --source <file.md> [--brief "…"] [--title "…"] [--minutes 20] \
  [--series "Hermes Briefings"] [--language de] [--publish] [--no-cover] \
  [--base-url https://audio-gateway.jkrumm.com] [--out ./out] [--json]
bun run podcast -- status <id>          # one-shot job state
bun run podcast -- list                 # latest jobs
bun run podcast -- publish <id>         # (re-)publish a finished job to Audiobookshelf
```

`--source -` reads stdin. `--base-url` defaults to `$PODCAST_BASE_URL`, else
`http://localhost:7714` (a local `bun run dev` gateway). The CLI polls until
`done`/`failed`, prints stage progress, downloads `episode.mp3`, `cover.png` and
`script.json` into `--out` (default `./out/podcasts/<id>/`), and prints the
Audiobookshelf link when published.

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
3. **Pick length + target.** `--minutes` 15–25 for a drive briefing, 8–10 for
   a quick summary. `--publish` unless the user only wants the file. Prod
   gateway (`--base-url https://audio-gateway.jkrumm.com`) is the default choice
   once it has `ABS_*` configured; a local `bun run dev` gateway works when the
   secrets are in the local env.
4. **Run it.** Report the job id immediately if the user is waiting on chat;
   the CLI blocks until done. Then hand over: title, duration, chapter list,
   the Audiobookshelf link (playable in Plappa/Prologue), cost, and the local
   `episode.mp3` path.
5. **Iterate on the script, not the audio.** If the user wants a different
   angle, change `--brief`/`--title`/`--minutes` and re-run — the script is the
   cheap part (one LLM outline + N segment calls); synthesis is the expensive
   part. `GET /v1/podcasts/<id>/script?format=md` (or `script.json` in `--out`)
   is the transcript to review.

## Knobs (gateway env, see audio-gateway `config.ts`)

| Var | Default | Meaning |
|-|-|-|
| `PODCAST_SCRIPT_MODEL` | `claude-sonnet-5` | outline + dialogue writer |
| `PODCAST_TTS_MODEL` | `elevenlabs/v3` | per-turn synthesis |
| `PODCAST_VOICES` / `PODCAST_HOST_NAMES` | `Mark,Sarah` / `Jonas,Lena` | host A, host B |
| `PODCAST_STABILITY` | `0.45` | v3 stability; lower = more tag-responsive |
| `PODCAST_SERIES` | `Hermes Briefings` | default show name in Audiobookshelf |
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

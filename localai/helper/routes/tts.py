"""Long-form TTS orchestration via Fish S2 Pro.

POST /v1/tts/synthesize
  Body (JSON):
    text:            str   — text to speak (any length)
    lang_hint:       str?  — "de" | "en" | None (auto-detect)
    max_chunk_chars: int?  — paragraph/sentence chunk size, default 1800

  Response (JSON):
    title:        str   — 3-8 word title for filename
    audio_b64:    str   — base64 MP3
    duration_secs: float
    chunks:       int
    lang:         str   — detected language code

Pipeline:
  1. Detect language (heuristic — German chars + word list)
  2. Rewrite for speech (Haiku) — only when ≥2 markdown markers
  3. Title (Haiku) for filename
  4. Hierarchical chunking — paragraphs first, then pysbd-segmented sentences
     within an oversized paragraph. Each chunk carries its trailing-break
     type ("paragraph"|"sentence"|"end") so the assembler can pick the right
     pause length.
  5. Synthesize each chunk via Fish S2 Pro (:8002), passing voice="de"|"en"
     and post_process=False (post-processing happens once after concat).
     max_new_tokens scales with chunk length: ceil(chars * 2.5) + 512.
  6. 5 ms linear fades on chunk edges; break-aware silence between chunks
     (300 ms after a sentence break, 600 ms after a paragraph break).
  7. Single ffmpeg pass over the concatenated audio: smile EQ + loudnorm
     for German, loudnorm-only for English. Then WAV → MP3 → base64 JSON.

Voice references and the smile EQ chain live in `localai/fish-s2-pro/`.
The chain string is mirrored here (see _SMILE_EQ_CHAIN) because the two
processes can't share a Python import — keep them in sync if either changes.

Credentials: ANTHROPIC_API_KEY + ANTHROPIC_BASE_URL injected by
start-localai-helper.sh from macOS Keychain. If absent, Haiku calls
are skipped and fallbacks apply (no rewrite, title = first words).
"""

import asyncio
import base64
import io
import math
import os
import re
import subprocess
import tempfile

import httpx
import numpy as np
import pysbd
import soundfile as sf
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

router = APIRouter()

_FISH_URL = os.getenv("LOCALAI_FISH_URL", "http://127.0.0.1:8002")

_ANTHROPIC_KEY = os.getenv("ANTHROPIC_API_KEY", "")
_ANTHROPIC_URL = os.getenv("ANTHROPIC_BASE_URL", "https://api.anthropic.com")
_HAIKU = "claude-haiku-4-5-20251001"

# Fish output sample rate. mlx-speech's Fish S2 Pro codec is 44.1 kHz native
# (the HF model card's "24 kHz" claim is wrong — verified against
# mlx_speech/models/fish_s2_pro/codec_config.py and the S2 paper §3.1).
_SAMPLE_RATE = 44100

# Mirror of localai/fish-s2-pro/server.py:SMILE_EQ_CHAIN. Static EQ filters
# only — loudnorm runs separately as a single pass after concat to avoid
# per-chunk loudness drift. Keep this string in sync with the fish server.
_SMILE_EQ_CHAIN = (
    "highpass=f=70,"
    "equalizer=f=600:t=q:w=2.5:g=-3,"
    "equalizer=f=5500:t=q:w=2.5:g=3,"
    "equalizer=f=12000:t=q:w=2:g=1.5"
)
# EBU R128 target — Spotify/Apple briefing convention.
_LOUDNORM = "loudnorm=I=-16:TP=-1.5:LRA=11"

# Pause lengths between concatenated chunks. Calibrated to spoken German
# news cadence: a sentence break is a beat, a paragraph break is a breath.
_PAUSE_AFTER = {
    "sentence": 0.30,
    "paragraph": 0.60,
    "end": 0.0,
}
# Linear fade applied at each chunk edge to suppress codec boundary pops.
_EDGE_FADE_MS = 5

_DE_CHARS = frozenset("äöüÄÖÜß")
_DE_WORDS = frozenset(
    # high-frequency German tokens that are not English homographs
    "ich ist das der die und mit für auf sie wir aber nicht auch nach "
    "wie wenn war hat wird bin kann noch mehr sehr durch dann über "
    "zum zur vom bis aus bei alle schon jetzt hier gibt mein sein "
    "im am ein eine einen einer eines kein keine "
    "heute morgen gestern dies diese dieser dieses jenen jener "
    "drei vier fünf sechs sieben acht neun zehn "
    "ja nein doch genau klar gut schlecht "
    "haben hatten waren sind seid wart "
    "läuft funktioniert oder also immer wieder nichts etwas "
    "uhr stunde minute sekunde freitag samstag sonntag montag "
    "dienstag mittwoch donnerstag januar februar märz april mai juni "
    "juli august september oktober november dezember".split()
)


class TTSRequest(BaseModel):
    text: str
    lang_hint: str | None = None
    # M2 Pro 32 GB Metal allocator caps single buffers at ~20 GB. Fish's
    # attention scratch grows past that around the 1300-char mark, crashing
    # the worker (libc++abi: [metal::malloc] Attempting to allocate >20 GB).
    # 800 chars produces ~50 s of audio per chunk and stays comfortably under
    # the cap on every Mac we run on. Bigger Apple Silicon (M2/M3 Max with
    # more unified memory) can override this per-request.
    max_chunk_chars: int = 800
    # Per-request override of the silence inserted between paragraph-boundary
    # chunks. Default (None) keeps the standard ~0.6s breath. Use this for
    # multi-section briefings where a noticeably longer beat between sections
    # improves comprehension (~1.5–2.5s feels natural without sounding stalled).
    paragraph_pause_secs: float | None = None
    # Longform mode: skip the 4000-char rewrite cap. The Haiku rewriter sees
    # the full input, adds prosody tags AND inserts <<<CHUNK>>> markers at
    # natural delivery beats. The chunker splits on those markers (with a
    # sentence-boundary safety net for anything > max_chunk_chars). Use for
    # multi-chapter podcasts / longform narration where the standard pipeline
    # silently truncates past 4000 chars.
    longform: bool = False
    # Playback speed multiplier applied via ffmpeg atempo in post-process.
    # 1.0 = no change. 0.95-0.97 takes the edge off Fish's slightly rushed
    # default cadence on longform without losing intelligibility. Range
    # clamped at synthesis time to ffmpeg atempo's safe band [0.5, 2.0].
    speed: float = 1.0


class TTSResponse(BaseModel):
    title: str
    audio_b64: str
    duration_secs: float
    chunks: int
    lang: str


# ---------- language detection ----------


def _detect_lang(text: str) -> str:
    """Strong-signal language detection. de_chars (umlauts) are a *weak*
    signal — German proper nouns like "München", "Düsseldorf",
    "Telefonseelsorge" inflate the count without the surrounding text being
    German. de_words (function words from _DE_WORDS: ist, der, die, und,
    auch, etc.) are a *strong* signal — only native German prose hits them
    at meaningful density. Native German prose lands at 15-25% function-word
    density; English prose with proper nouns lands near 0%.

    The previous heuristic (threshold-of-1 on either signal) flipped any
    English text containing a single umlaut to German, which then
    mispronounced every English word in every chunk. Now we trust de_chars
    only on short text (avoids regressing "Fish S2 Pro läuft."); on longer
    text we require non-trivial function-word density.
    """
    words = re.findall(r"\b\w+\b", text.lower())
    de_chars = sum(1 for c in text if c in _DE_CHARS)
    de_words = sum(1 for w in words if w in _DE_WORDS)
    if de_chars + de_words == 0:
        return "en"
    total_words = len(words) or 1
    # Short text (< 20 words) with any German signal → German. Preserves the
    # "Fish S2 Pro läuft." behavior that motivated the original threshold.
    if total_words < 20:
        return "de"
    # Longer text → require function-word density ≥ 5%. Native German
    # easily clears this; English with proper nouns doesn't.
    de_words_density = de_words / total_words * 100
    return "de" if de_words_density >= 5.0 else "en"


# ---------- markdown handling ----------


def _needs_rewrite(text: str) -> bool:
    markers = 0
    if re.search(r"^[-*] ", text, re.MULTILINE):
        markers += 1
    if re.search(r"^#{1,4} ", text, re.MULTILINE):
        markers += 1
    if "```" in text:
        markers += 1
    if re.search(r"https?://", text):
        markers += 1
    return markers >= 2


def _strip_markdown(text: str) -> str:
    text = re.sub(r"```[\s\S]*?```", " ", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"\*(.+?)\*", r"\1", text)
    text = re.sub(r"`(.+?)`", r"\1", text)
    text = re.sub(r"^#{1,4}\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^\s*[-*]\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


# ---------- sentence-aware chunking ----------

# pysbd is heavy to instantiate (regex compilation) — keep one Segmenter per
# language for the process lifetime.
_SEGMENTERS: dict[str, pysbd.Segmenter] = {}


def _segmenter(lang: str) -> pysbd.Segmenter:
    seg = _SEGMENTERS.get(lang)
    if seg is None:
        # pysbd supports language="de"/"en" with abbreviation lists tuned per
        # language. clean=False preserves whitespace so we can re-join cleanly.
        seg = pysbd.Segmenter(language=lang if lang in {"de", "en"} else "en", clean=False)
        _SEGMENTERS[lang] = seg
    return seg


def _split_sentences(text: str, lang: str) -> list[str]:
    sentences = [s.strip() for s in _segmenter(lang).segment(text) if s and s.strip()]
    return sentences or [text]


def _chunk_text(
    text: str,
    lang: str,
    max_chars: int,
    *,
    preserve_paragraphs: bool = False,
) -> list[tuple[str, str]]:
    """Hierarchical splitter: paragraphs first, then sentences within.

    Returns ``[(chunk_text, trailing_break_type), …]`` where the break type is
    "paragraph" if the next chunk starts a new paragraph, "sentence" if it
    continues the current paragraph, and "end" for the last chunk.

    Rationale: paragraph boundaries deserve a longer pause (breath) than
    mid-paragraph sentence boundaries (beat). Tracking the type per chunk lets
    the assembler insert appropriately scaled silence.

    ``preserve_paragraphs=True`` skips the phase-2 greedy merge of short
    paragraphs into the previous chunk. Use this when the caller has placed
    paragraph breaks deliberately (e.g. a multi-section briefing) and wants
    each paragraph to be synthesized — and paused after — as its own beat.
    """
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text.strip()) if p.strip()]
    if not paragraphs:
        return [(text, "end")]

    # Phase 1: split each paragraph into sub-chunks ≤ max_chars on sentence
    # boundaries. Keep paragraph identity so phase 2 can attach break types.
    para_chunks: list[list[str]] = []
    for para in paragraphs:
        if len(para) <= max_chars:
            para_chunks.append([para])
            continue
        sentences = _split_sentences(para, lang)
        bucket = ""
        sub: list[str] = []
        for s in sentences:
            if not s:
                continue
            # Sentence longer than max_chars on its own — emit it solo. Fish
            # handles oversized chunks via its own context window; better one
            # long chunk than a mid-sentence break.
            if len(s) > max_chars and not bucket:
                sub.append(s)
                continue
            join = (bucket + " " + s).strip() if bucket else s
            if len(join) <= max_chars:
                bucket = join
            else:
                if bucket:
                    sub.append(bucket)
                bucket = s
        if bucket:
            sub.append(bucket)
        para_chunks.append(sub)

    # Phase 2: greedily merge whole paragraphs across the chunk boundary when
    # the previous paragraph fit in a single sub-chunk and the combined size
    # stays within max_chars. This keeps short paragraphs (a single date line,
    # a one-sentence reminder) from each becoming their own model call.
    chunks: list[tuple[str, str]] = []
    i = 0
    while i < len(para_chunks):
        sub = para_chunks[i]
        # Merge with previous if previous was a single sub-chunk and so is sub
        # — unless the caller asked us to preserve paragraph identity.
        if (
            not preserve_paragraphs
            and chunks
            and len(sub) == 1
            and chunks[-1][1] == "paragraph"
            and len(chunks[-1][0]) + 2 + len(sub[0]) <= max_chars
        ):
            prev_text, _ = chunks[-1]
            chunks[-1] = (prev_text + "\n\n" + sub[0], "paragraph")
        else:
            for j, c in enumerate(sub):
                # Mid-paragraph splits get a sentence break; the last sub of
                # a paragraph gets a paragraph break (overwritten to "end" at
                # the very end below).
                brk = "paragraph" if j == len(sub) - 1 else "sentence"
                chunks.append((c, brk))
        i += 1

    # Final chunk should signal end-of-stream (no trailing silence).
    if chunks:
        last_text, _ = chunks[-1]
        chunks[-1] = (last_text, "end")
    return chunks or [(text, "end")]


# ---------- audio helpers ----------


def _silence(secs: float) -> np.ndarray:
    n = max(0, int(secs * _SAMPLE_RATE))
    return np.zeros(n, dtype=np.float32)


def _fade_edges(audio: np.ndarray, ms: int = _EDGE_FADE_MS) -> np.ndarray:
    """In-place 5ms linear fade in + out. Suppresses codec boundary clicks."""
    n = max(1, int(ms * _SAMPLE_RATE / 1000))
    n = min(n, len(audio) // 2)
    if n <= 0:
        return audio
    ramp = np.linspace(0.0, 1.0, n, dtype=np.float32)
    audio[:n] *= ramp
    audio[-n:] *= ramp[::-1]
    return audio


def _budget_max_new_tokens(chars: int) -> int:
    """Audio-token budget at the codec's 21.5 Hz frame rate.

    Spoken German runs ~14 chars/sec; codec emits 21.5 audio tokens/sec.
    Empirical multipliers (Fish S2 paper + mlx-speech profiling):
      chars * 1.54 — plain narration
      chars * 2.20 — heavy prosody tagging
    We use 2.0 + 384 absolute headroom to cover both regimes without
    leaving so much slack that a misbehaving generation can run for
    20+ minutes before the runtime gives up. Cap at 2400 (~1.9 min audio,
    matches the 800-char chunk default and the M2 Pro Metal envelope).

    The runtime breaks on EOS — over-budget cycles cost nothing if the
    model stops cleanly. Under-budget hard-cuts mid-word with no error.
    """
    return min(2400, math.ceil(chars * 2.0) + 384)


# ---------- Haiku helpers ----------


async def _haiku(system: str, user: str, max_tokens: int = 128) -> str:
    if not _ANTHROPIC_KEY:
        return ""
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            r = await client.post(
                f"{_ANTHROPIC_URL.rstrip('/')}/v1/messages",
                headers={
                    "x-api-key": _ANTHROPIC_KEY,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": _HAIKU,
                    "max_tokens": max_tokens,
                    "system": system,
                    "messages": [{"role": "user", "content": user}],
                },
            )
            r.raise_for_status()
            return r.json()["content"][0]["text"].strip()
    except Exception:
        return ""


_SPEAKABLE_SYSTEM_DE = """Du wandelst Nachrichten in natürliche, gesprochene deutsche Prosa um und reicherst sie mit Fish S2 Pro Prosodie-Tags an. Antworte AUSSCHLIESSLICH mit dem umgeschriebenen Text — keine Erklärungen, keine Anführungszeichen.

GRUNDREGELN:
- Sprache: Deutsch beibehalten. Keine Begrüßung, keine Anrede mit Namen.
- Markdown entfernen: Aufzählungen zu fließenden Sätzen, Bold/Italic strippen, Headlines weg, URLs weg, Code in einfache Worte umschreiben.
- Alle Informationen erhalten — nichts kürzen.
- Klingen wie gesprochen, nicht wie geschrieben (kürzere Sätze, natürliche Konnektoren wie "dann", "und außerdem", "übrigens").

PROSODIE-TAGS — verwende sie aktiv. Tags wirken auf den FOLGENDEN Text bis zum nächsten Tag oder starkem Satzzeichen.

ANKER (genau EINMAL ganz am Anfang setzen, bestimmt den Grundton):
- [professional broadcast tone] [warm] — Standard für Briefings, Updates, Status, Tagesüberblick. Default für deutsche Sprachnachrichten.
- [narrator tone] — etwas erzählender, für längere Geschichten oder Recaps.
- [serious] — für Warnungen, Alerts, kritische Statusmeldungen.

UNIVERSELL SICHER (großzügig einsetzen, sie tragen den Großteil der Lebendigkeit):
- [emphasis] — betont das nächste Wort/die Phrase. Setze 2–4 Mal pro Absatz auf das WICHTIGSTE Wort jedes Satzes (eine Zahl, ein Name, ein Schlüsselverb). NICHT auf jeden Satz.
- [pause] — ~1 Sekunde echter Beat. Setze einen [pause] zwischen jedem Themenwechsel (Wetter → Termine → Inbox → Infrastruktur etc.) und vor jeder Pointe. Etwa einer pro 2–3 Sätze. (Hinweis: [short pause] wirkt im Deutschen kaum hörbar — immer [pause] benutzen.)

EMOTIONALE TAGS (deutsche Tier-2-Stimme: am Satzanfang klingen sie leicht gekünstelt — nutze sie nur, wenn der Inhalt sie wirklich verlangt):
- [excited] — bei guten Nachrichten, Erfolgen, Plänen ("Heute Abend wird es großartig").
- [delight] — bei netten Überraschungen, freudigen Momenten.
- [sigh] — bei Frust, Aufgabe, Resignation ("Das hätten wir uns sparen können").
- [serious] — bei Warnungen mitten im Text.
- [chuckle] / [laughing] — bei tatsächlich Lustigem; spürbar weicher Effekt im Deutschen, also wirklich nur bei Witzen.
- [whisper] / [low voice] — für Insider-Bemerkungen, vertrauliche Asides.

PLATZIERUNG:
- Nicht 3+ Tags direkt hintereinander (außer dem Anker am Anfang).
- Was Satzzeichen schon machen, NICHT taggen (Fragezeichen hebt die Stimme bereits).
- Bei reinen Aufzählungen: Konnektoren wie "erstens, zweitens, drittens" einbauen, dann [emphasis] auf das jeweilige Hauptwort.

BEISPIELE:

Eingabe: "Wetter München: 18°C, sonnig. Standup 9:30, Architektur-Review um 11. Inbox: 1 Erinnerung, 2 Newsletter."
Ausgabe: [professional broadcast tone] [warm] In München heute [emphasis] achtzehn Grad und Sonne. [pause] Im Kalender steht zuerst der Standup um neun Uhr dreißig, danach das [emphasis] Architektur-Review um elf. [pause] In der Inbox eine Erinnerung und zwei Newsletter — nichts Dringendes.

Eingabe: "Alle Server up, garmin-sync ist seit drei Tagen unhealthy. HR-Dashboard repariert."
Ausgabe: [professional broadcast tone] [warm] Alle Server laufen, [pause] mit einer Ausnahme: garmin-sync ist jetzt den [emphasis] dritten Tag in Folge unhealthy. Das HR-Dashboard ist [emphasis] wieder repariert."""

_SPEAKABLE_SYSTEM_EN = """You convert messages into natural spoken English prose enriched with Fish S2 Pro prosody tags. Reply with ONLY the rewritten text — no commentary, no quotes.

GROUND RULES:
- Keep language: English. No greeting, no addressing the listener by name.
- Strip markdown: bullets become flowing sentences, no bold/italic, drop headers, omit URLs, describe code in plain words.
- Preserve every piece of information.
- Sound spoken, not written (shorter sentences, natural connectors like "then", "also", "by the way").

PROSODY TAGS — use them actively. Each tag affects the text that FOLLOWS until the next tag or strong punctuation.

ANCHORS (place EXACTLY ONCE at the very start to set overall register):
- [professional broadcast tone] [warm] — default for briefings, updates, status, daily summaries.
- [narrator tone] — slightly more theatrical, for stories or longer recaps.
- [serious] — for warnings, alerts, critical status.

ALWAYS-SAFE (use generously — these carry most of the life):
- [emphasis] — stresses the next word/phrase. 2–4 per paragraph on the MOST important word in each sentence (a number, a name, a key verb). Not on every sentence.
- [pause] — ~1 s real beat. One between every topic change (weather → calendar → inbox → infra) and before any punchline. ~1 per 2–3 sentences. ([short pause] is barely audible in practice — use [pause].)

EMOTIONAL TAGS (Tier-1 English: full set works naturally — use them when the content has the actual emotion):
- [excited] — good news, plans, wins.
- [delight] — pleasant surprises.
- [chuckle] / [laughing] — actual jokes.
- [sigh] — frustration, exhaustion.
- [whisper] / [low voice] — confidential asides.
- [sad] / [shocked] / [serious] — when content matches.

PLACEMENT:
- Don't stack 3+ tags adjacent (except the opening anchor).
- Don't tag what punctuation already does (a question mark already raises pitch).
- For raw lists: add connectors ("first, second, third") then [emphasis] on the headword.

EXAMPLES:

Input: "Munich weather: 18°C sunny. Standup at 9:30, architecture review at 11. Inbox: 1 reminder, 2 newsletters."
Output: [professional broadcast tone] [warm] Munich today: [emphasis] eighteen degrees and sunny. [pause] On the calendar, standup at nine thirty, then the [emphasis] architecture review at eleven. [pause] Inbox has one reminder and two newsletters — nothing urgent.

Input: "All servers up, garmin-sync unhealthy 3rd day. HR dashboard fixed."
Output: [professional broadcast tone] [warm] All servers up, [pause] with one exception: garmin-sync is now on its [emphasis] third day unhealthy. The HR dashboard is [emphasis] back online."""


async def _rewrite_for_speech(text: str, lang: str) -> str:
    """Rewrite for speech with prosody tags (no chunk markers).

    Uses the same batched + parallel infrastructure as longform mode, just
    with the standard system prompt and no <<<CHUNK>>> separator between
    batches — the downstream _chunk_text handles algorithmic chunking on
    the concatenated result. Inputs that fit in one batch (typical
    briefings, ~2500 chars) make a single Haiku call; longer inputs split
    on paragraph boundaries and rewrite in parallel.

    No truncation cap — the previous text[:4000] silently dropped content
    past 4000 chars on any caller. Now scales to any length without
    sacrificing fidelity.
    """
    if not _ANTHROPIC_KEY:
        return _strip_markdown(text)
    system = _SPEAKABLE_SYSTEM_DE if lang == "de" else _SPEAKABLE_SYSTEM_EN
    batches = _batch_paragraphs(text, _LONGFORM_BATCH_CHARS)
    async with httpx.AsyncClient(timeout=180.0) as client:
        results = await asyncio.gather(
            *[_rewrite_batch(client, b, system) for b in batches]
        )
    # Concatenate batches with paragraph separators so _chunk_text's
    # paragraph-aware splitter can still find natural break points. No
    # <<<CHUNK>>> markers — that's the longform path's job.
    joined = "\n\n".join(r for r in results if r)
    return joined or _strip_markdown(text)


# ---------- longform mode ----------

# Marker the longform rewriter inserts at natural delivery beats. Chosen to be
# obviously non-textual so the splitter can't false-positive on user prose.
_LONGFORM_CHUNK_MARKER = "<<<CHUNK>>>"

_LONGFORM_SYSTEM_EN = """You convert long-form text into spoken English with Fish S2 Pro prosody tags AND chunk markers for piecewise synthesis. Reply with ONLY the rewritten text — no commentary, no quotes.

GROUND RULES:
- Keep language: English. No greeting, no addressing the listener by name.
- PRESERVE EVERY PIECE OF INFORMATION. This is a longform rewrite, NOT a summary. Do not condense, do not drop sentences, do not paraphrase aggressively. The input may be 30,000+ characters; your output should be similar length plus tags and markers.
- Strip markdown: bullets become flowing sentences, no bold/italic, drop headers, omit URLs verbatim (describe what they point to instead), describe code/file paths in plain words.
- Sound spoken, not written: shorter sentences, natural connectors ("then", "also", "by the way"), occasional rhetorical phrases.

PROSODY TAGS — use them actively. Each tag affects the text that FOLLOWS until the next tag or strong punctuation.

ANCHOR (place EXACTLY ONCE at the very start to set overall register):
- [narrator tone] [warm] — default for longform podcasts and walkthroughs.
- [professional broadcast tone] [warm] — for status-heavy or briefing-style longform.

ALWAYS-SAFE (use generously — these carry most of the life):
- [emphasis] — stresses the next word/phrase. 2–4 per paragraph on the MOST important word in each sentence (a number, a name, a key verb). Not on every sentence.
- [pause] — ~1 s real beat. One between every meaningful topic shift, before any punchline. ~1 per 2–3 sentences. ([short pause] is barely audible — use [pause].)

EMOTIONAL TAGS (use only when content calls for it):
- [excited] — wins, plans, breakthroughs.
- [delight] — pleasant surprises.
- [chuckle] — actual humor.
- [sigh] — frustration, exhaustion.
- [whisper] / [low voice] — confidential asides, contrarian observations.
- [serious] — warnings, risks.

TAG PLACEMENT:
- Don't stack 3+ tags adjacent (except the opening anchor).
- Don't tag what punctuation already does (a question mark already raises pitch).
- For raw lists: add connectors ("first, second, third") then [emphasis] on the headword.

TECHNICALITIES — abstract spelling-heavy detail. Listeners cannot reread audio; reading character-by-character feels robotic.
- Terminal commands ("ffmpeg -i input.m4a -c:a libopus -b:a 24k -ac 1") → describe what they do in one phrase: "an ffmpeg command re-encodes the audio to Opus." Skip the flags. If the listener needs the exact syntax, they're at a keyboard, not in the car.
- Long alphanumeric IDs, hash strings, certificate fingerprints, container IDs, commit SHAs → either skip or abstract: "a certificate fingerprint", "the relevant commit". Never read out 40-character hex strings.
- Paper / preprint numbers ("arXiv 2502.08177", "doi:10.1145/...") → "a 2025 arXiv paper", "a CHI 2024 paper". Read the year and venue, drop the identifier.
- File paths ("~/Obsidian/Vault/Journal/JOURNAL.md") → name the purpose: "the journal schema document", "the helper config file". Drop the path.
- API endpoint URLs → name the service: "the homelab API", "the OpenAI image endpoint". Drop the URL.
- Acronyms that the listener already knows (HRV, RHR, SDK, API, LLM) → keep as-is; don't expand.
- Acronyms or technical-spell-outs in the source ("M-D" for ".md", "T-S-R-P", "P-N-G") → only retain if essential to comprehension. "the schema document" beats "JOURNAL dot M-D" every time.
- Numbers in prose: prefer spoken forms ("twenty-four kilobits per second" not "24 kbps"); skip exhaustive units when context is clear.

The principle: a podcast listener should never need to rewind to parse a string of characters. If you'd write it as code in a doc, abstract it for audio.

CHUNK MARKERS (this is the longform-specific part — critical):
- Insert <<<CHUNK>>> on its own line between natural delivery beats.
- A chunk is a coherent unit of thought — usually 1–4 sentences, target 300–700 characters, never more than 800.
- Place chunk boundaries at:
  * Topic transitions ("Now, on to —", "Chapter five —", "Here's the thing —")
  * Strong punctuation that ends a thought
  * Paragraph boundaries in the input
  * Approximately every 300–700 characters of output
- NEVER place a chunk boundary mid-sentence.
- NEVER place a chunk boundary inside a tag (e.g. between [emphasis] and the word it modifies).
- The opening anchor tag belongs at the start of the FIRST chunk.
- Chunk boundaries are how Fish synthesizes piecewise — chunks too long crash the worker; chunks too short sound choppy. Stay in the 300–700 char band.
- Per-chunk voice is auto-selected from chunk content. So a chunk that is heavily English (technical paragraph in an otherwise German narration, or vice-versa) renders in the right voice — group such content into its own chunk to get clean pronunciation.

OUTPUT SHAPE:
[narrator tone] [warm] First chunk text with [emphasis] tags and natural [pause] beats.
<<<CHUNK>>>
Second chunk text continues the thought naturally.
<<<CHUNK>>>
…and so on through the entire input.

EXAMPLES (small):

Input: "Welcome back. This is the rundown. Chapter one — the setup. You're sitting on a Mac Mini M2 Pro. Hermes runs on it. Briefings, watchdog, evening reports."
Output: [narrator tone] [warm] Welcome back. This is the [emphasis] rundown.
<<<CHUNK>>>
Chapter [emphasis] one — the setup. [pause] You're sitting on a [emphasis] Mac Mini M2 Pro. Hermes runs on it. [pause] Briefings, watchdog, evening reports.
"""

_LONGFORM_SYSTEM_DE = """Du wandelst Langform-Text in gesprochenes Deutsch um, angereichert mit Fish S2 Pro Prosodie-Tags UND Chunk-Markern für stückweise Synthese. Antworte AUSSCHLIESSLICH mit dem umgeschriebenen Text — keine Erklärungen, keine Anführungszeichen.

GRUNDREGELN:
- Sprache: Deutsch beibehalten. Keine Begrüßung, keine Anrede mit Namen.
- ALLE INFORMATIONEN ERHALTEN. Dies ist eine Langform-Umschreibung, KEINE Zusammenfassung. Nichts kürzen, nichts weglassen, nicht aggressiv paraphrasieren. Der Input kann 30.000+ Zeichen haben; der Output sollte ähnlich lang sein plus Tags und Marker.
- Markdown entfernen: Aufzählungen zu fließenden Sätzen, kein Bold/Italic, keine Headers, URLs weg (in Worten beschreiben), Code/Pfade in einfache Worte umschreiben.
- Klingen wie gesprochen, nicht wie geschrieben.

PROSODIE-TAGS (siehe englisches Pendant — gleiche Tags, gleiche Platzierungsregeln):
- ANKER einmal am Anfang: [narrator tone] [warm] für Podcasts/Walkthroughs, [professional broadcast tone] [warm] für status-lastige Langform.
- [emphasis] auf das wichtigste Wort, 2–4 pro Absatz.
- [pause] ~1 Sekunde, etwa einer pro 2–3 Sätze, vor Pointen und Themenwechseln.
- Emotional-Tags ([excited], [sigh], [chuckle], [whisper], [serious]) sparsam und nur passend.

TECHNIKALIEN — buchstabier-lastige Details abstrahieren. Hörer können Audio nicht nachlesen; Zeichen-für-Zeichen vorgelesen wirkt robotisch.
- Terminal-Befehle ("ffmpeg -i input.m4a -c:a libopus") → beschreibe den Zweck: "Ein ffmpeg-Befehl kodiert die Audio in Opus um." Flags weglassen.
- Lange alphanumerische IDs, Hash-Strings, Zertifikat-Fingerprints, Commit-SHAs → entweder weglassen oder abstrahieren: "ein Zertifikat-Fingerprint", "der relevante Commit". Niemals 40-stellige Hex-Strings vorlesen.
- Paper- / Preprint-Nummern ("arXiv 2502.08177") → "ein arXiv-Paper aus 2025", "ein CHI 2024 Paper". Jahr und Venue lesen, ID weglassen.
- Dateipfade ("~/Obsidian/Vault/Journal/JOURNAL.md") → den Zweck nennen: "das Journal-Schema-Dokument", "die Helper-Config".
- API-Endpunkt-URLs → den Service nennen: "die Homelab-API", "der OpenAI Image-Endpunkt".
- Bekannte Akronyme (HRV, API, LLM) → beibehalten, nicht ausschreiben.
- Buchstabier-Akronyme im Source ("J-O-U-R-N-A-L dot M-D", "T-S-R-P") → nur beibehalten wenn unverzichtbar.
- Zahlen in Prosa: gesprochene Form ("vierundzwanzig Kilobit pro Sekunde" statt "24 kbps").

Prinzip: Ein Podcast-Hörer sollte nie zurückspulen müssen, um eine Zeichenkette zu parsen.

CHUNK-MARKER (entscheidender Teil):
- Setze <<<CHUNK>>> in eigener Zeile zwischen natürlichen Lieferpausen.
- Ein Chunk ist eine zusammenhängende Gedankeneinheit — meist 1–4 Sätze, Ziel 300–700 Zeichen, nie mehr als 800.
- Chunk-Grenzen platzieren bei:
  * Themenwechseln ("Jetzt zu —", "Kapitel fünf —", "Aber hier ist die Sache —")
  * Starken Satzzeichen, die einen Gedanken abschließen
  * Absatzgrenzen im Input
  * Etwa alle 300–700 Zeichen Output
- NIE mitten im Satz einen Chunk-Marker setzen.
- NIE einen Chunk-Marker innerhalb eines Tags setzen.
- Der Anker-Tag gehört in den Anfang des ERSTEN Chunks.
- Pro-Chunk wird die Stimme automatisch aus dem Chunk-Inhalt gewählt. Stark gemischtsprachige Passagen (z.B. ein technischer englischer Block in deutscher Erzählung) als eigenen Chunk gruppieren, damit jede Sprache in der richtigen Stimme rendert.

OUTPUT-FORM (gleich wie Englisch):
[narrator tone] [warm] Erster Chunk mit [emphasis] Tags und [pause] Beats.
<<<CHUNK>>>
Zweiter Chunk setzt den Gedanken fort.
<<<CHUNK>>>
…und so weiter durch den ganzen Input.
"""


# Each rewriter sub-call sees at most this many input chars. 3500 keeps Haiku's
# output well under its 16k-token cap (3500 chars in → ~5000 tagged chars out
# ≈ 1500 tokens), and parallel sub-calls amortize round-trip latency. Splits
# happen on paragraph boundaries so prosody continuity isn't broken mid-thought.
_LONGFORM_BATCH_CHARS = 3500


def _batch_paragraphs(text: str, max_chars: int) -> list[str]:
    """Greedy paragraph-aligned batching. Each batch ≤ max_chars unless a
    single paragraph exceeds it (in which case it ships solo — the rewriter
    handles oversized paragraphs fine, it just can't be merged with neighbors).
    """
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text.strip()) if p.strip()]
    if not paragraphs:
        return [text]
    batches: list[str] = []
    bucket = ""
    for para in paragraphs:
        candidate = (bucket + "\n\n" + para) if bucket else para
        if len(candidate) <= max_chars or not bucket:
            bucket = candidate
        else:
            batches.append(bucket)
            bucket = para
    if bucket:
        batches.append(bucket)
    return batches


async def _rewrite_batch(client: httpx.AsyncClient, batch: str, system: str) -> str:
    """Single Haiku rewrite call. Returns batch unchanged on error so a partial
    failure degrades gracefully instead of dropping content."""
    try:
        r = await client.post(
            f"{_ANTHROPIC_URL.rstrip('/')}/v1/messages",
            headers={
                "x-api-key": _ANTHROPIC_KEY,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": _HAIKU,
                # 3500 input chars ≈ 875 tokens; output with tags ~1500–2200
                # tokens. 8k cap is comfortable headroom.
                "max_tokens": 8192,
                "system": system,
                "messages": [{"role": "user", "content": batch}],
            },
        )
        r.raise_for_status()
        return r.json()["content"][0]["text"].strip()
    except Exception:
        return batch


async def _rewrite_for_speech_longform(text: str, lang: str) -> str:
    """Full-input rewrite that adds prosody tags AND <<<CHUNK>>> markers.

    No 4000-char truncation. Splits the input into paragraph-aligned batches
    of ~3500 chars and rewrites each in parallel via Haiku 4.5. Each batch's
    output stays well under Haiku's 16k-token cap, so nothing gets silently
    truncated. Concatenates with <<<CHUNK>>> at batch boundaries so the
    splitter sees a clean break between batches.

    Falls back per-batch to the original text on error so a partial failure
    degrades to algorithmic chunking on that portion only.
    """
    if not _ANTHROPIC_KEY:
        return text
    system = _LONGFORM_SYSTEM_DE if lang == "de" else _LONGFORM_SYSTEM_EN
    batches = _batch_paragraphs(text, _LONGFORM_BATCH_CHARS)
    async with httpx.AsyncClient(timeout=180.0) as client:
        results = await asyncio.gather(
            *[_rewrite_batch(client, b, system) for b in batches]
        )
    # Stitch batches with an explicit chunk marker. The model usually places
    # one at the end of each batch, but enforcing it here guarantees the
    # batch boundary is a synthesis boundary regardless of model variance.
    sep = f"\n{_LONGFORM_CHUNK_MARKER}\n"
    return sep.join(r for r in results if r)


def _split_on_chunk_markers(
    text: str, lang: str, max_chars: int
) -> list[tuple[str, str]]:
    """Split LLM-tagged text on <<<CHUNK>>> markers. Each split is a paragraph
    break (so paragraph_pause_secs applies). Anything past max_chars gets a
    sentence-boundary safety pass so Fish's Metal allocator doesn't crash on
    chunks the model made too long.
    """
    parts = [p.strip() for p in text.split(_LONGFORM_CHUNK_MARKER) if p.strip()]
    if not parts:
        return [(text, "end")]
    chunks: list[tuple[str, str]] = []
    for part in parts:
        if len(part) <= max_chars:
            chunks.append((part, "paragraph"))
            continue
        # Oversized — split on sentences. All sub-chunks except the last keep
        # the "sentence" break (no extra paragraph pause inside one logical
        # chunk); the last sub-chunk gets the paragraph break so the inter-
        # chunk pause still fires.
        sentences = _split_sentences(part, lang)
        bucket = ""
        subs: list[str] = []
        for s in sentences:
            if not s:
                continue
            join = (bucket + " " + s).strip() if bucket else s
            if len(join) <= max_chars:
                bucket = join
            else:
                if bucket:
                    subs.append(bucket)
                bucket = s
        if bucket:
            subs.append(bucket)
        for j, sub in enumerate(subs):
            brk = "paragraph" if j == len(subs) - 1 else "sentence"
            chunks.append((sub, brk))
    if chunks:
        last_text, _ = chunks[-1]
        chunks[-1] = (last_text, "end")
    return chunks or [(text, "end")]


# ---------- standard helpers ----------


async def _make_title(text: str, lang: str) -> str:
    lang_name = "German" if lang == "de" else "English"
    result = await _haiku(
        system=(
            f"Generate a concise 3-8 word title in {lang_name} for this spoken memo. "
            "Reply ONLY with the title — no quotes, no punctuation at the end."
        ),
        user=text[:400],
        max_tokens=24,
    )
    return re.sub(r'[<>:"/\\|?*]', "", result).strip() or "Voice memo"


# ---------- synthesis ----------


async def _synth_chunk(
    chunk: str,
    lang: str,
    client: httpx.AsyncClient,
) -> np.ndarray:
    r = await client.post(
        f"{_FISH_URL}/v1/audio/speech",
        json={
            "model": "fish-s2-pro",
            "input": chunk,
            "voice": lang,
            "response_format": "wav",
            "max_new_tokens": _budget_max_new_tokens(len(chunk)),
            # Skip per-chunk EQ — we apply it once after concat to avoid
            # boundary loudness drift and save N-1 ffmpeg fork+exec cycles.
            "post_process": False,
        },
        # Cold M2 Pro can take ~3 audio-tokens/sec on the first chunks before
        # MLX kernels are fully warm; budget cap × worst-case rate ≈ 1600 s.
        # Set timeout above that so a hot-cap generation completes rather
        # than dying mid-stream.
        timeout=1800.0,
    )
    r.raise_for_status()
    audio, _ = sf.read(io.BytesIO(r.content), dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1).astype(np.float32)
    return _fade_edges(np.ascontiguousarray(audio))


def _post_process(combined: np.ndarray, lang: str, speed: float = 1.0) -> bytes:
    """Single ffmpeg pass: atempo (if speed != 1.0) + smile EQ (DE only)
    + loudnorm. Returns MP3 bytes. atempo runs first so EQ + loudnorm see
    the final-rate audio."""
    chain_parts: list[str] = []
    if abs(speed - 1.0) > 1e-3:
        chain_parts.append(f"atempo={speed}")
    if lang == "de":
        chain_parts.append(_SMILE_EQ_CHAIN)
    chain_parts.append(_LOUDNORM)
    af = ",".join(chain_parts)

    wav_buf = io.BytesIO()
    sf.write(wav_buf, combined, _SAMPLE_RATE, format="WAV", subtype="PCM_16")
    proc = subprocess.run(
        [
            "ffmpeg", "-loglevel", "error",
            "-i", "pipe:0",
            "-af", af,
            "-ar", str(_SAMPLE_RATE),
            "-ac", "1",
            "-codec:a", "libmp3lame", "-q:a", "4",
            "-f", "mp3", "pipe:1",
        ],
        input=wav_buf.getvalue(),
        capture_output=True,
        timeout=180,
    )
    if proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"ffmpeg post-process failed: {proc.stderr.decode()[-300:]}",
        )
    return proc.stdout


# How long the Fish pipeline has to produce final audio before the request
# falls back to Supertonic. A briefing on a healthy Mac renders in 30–60 s
# including Haiku rewrite + chunking + per-chunk synth + ffmpeg loudnorm.
# 120 s gives 2× headroom. Past that, Fish is wedged (Metal weights evicted
# under memory pressure) and the cron's 600 s idle watchdog is closing in —
# better to ship lower-quality audio than fail the whole job.
_FISH_DEADLINE_SECS = 120.0


@router.post("/v1/tts/synthesize", response_model=TTSResponse)
async def synthesize(req: TTSRequest) -> TTSResponse:
    """Primary TTS endpoint. Tries Fish-S2-Pro (highest Elo open-weights TTS)
    with a hard deadline; on timeout or Fish-side connection error, falls back
    to Supertonic-3 via routes.tts_fast.synthesize_fast. Both paths return the
    same TTSResponse shape so callers stay engine-agnostic.

    Fish failures we fall back from:
      - asyncio.TimeoutError       — Fish wedged past _FISH_DEADLINE_SECS
      - httpx.RequestError         — connection refused / read timeout / DNS
      - httpx.HTTPStatusError      — Fish returned 5xx

    We do NOT fall back from HTTPException (user input errors, 4xx from Haiku
    rewrite, etc.) — those propagate so the caller sees the real cause.
    """
    try:
        return await asyncio.wait_for(
            _synthesize_fish(req),
            timeout=_FISH_DEADLINE_SECS,
        )
    except (asyncio.TimeoutError, httpx.RequestError, httpx.HTTPStatusError) as exc:
        # Import locally to avoid a circular import at module load
        # (tts_fast imports TTSResponse + _detect_lang from this module).
        from routes.tts_fast import synthesize_fast
        print(
            f"[tts] Fish path failed ({type(exc).__name__}: {exc}); "
            f"falling back to Supertonic-3 — request: {len(req.text)} chars, "
            f"lang_hint={req.lang_hint}"
        )
        # Fish is wedged. Translate the input to English and synthesize in
        # Sam's voice — much better degradation than reading German text in
        # an English-tuned embedding, which sounds like mispronounced German.
        # The trade-off: a request that explicitly wanted German content
        # (e.g. a morning briefing) gets it in English when Fish is down.
        # Acceptable because the alternative is unintelligible audio, and a
        # real German briefing requires Fish to be healthy anyway.
        return await synthesize_fast(
            req.text,
            lang_hint=req.lang_hint,
            speed=0.95,
            english_only=True,
            polish=True,
            paragraph_pause_secs=req.paragraph_pause_secs,
        )


async def _synthesize_fish(req: TTSRequest) -> TTSResponse:
    """Original Fish-S2-Pro pipeline. Extracted so the public synthesize
    endpoint can wrap it with a deadline + fallback. Behavior unchanged from
    the pre-fallback version."""
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")

    # 1. Language detection
    lang = req.lang_hint or _detect_lang(text)

    # 2. Speakable rewrite. Two paths:
    #
    #    Standard mode — Haiku rewrites the first 4000 chars only, injecting
    #    prosody tags. The output is then chunked algorithmically by
    #    _chunk_text. Default for briefings, watchdog, evening report.
    #
    #    Longform mode (req.longform=True) — Haiku rewrites the full input,
    #    no truncation, and inserts <<<CHUNK>>> markers at semantic delivery
    #    beats. _split_on_chunk_markers splits on those markers and applies
    #    a sentence-boundary safety net for any chunk > max_chunk_chars.
    #    Use for multi-chapter podcasts where the standard path silently
    #    truncates past 4000 chars.
    if len(text) >= 80 and _ANTHROPIC_KEY:
        if req.longform:
            spoken = await _rewrite_for_speech_longform(text, lang)
        else:
            spoken = await _rewrite_for_speech(text, lang)
    else:
        spoken = _strip_markdown(text)

    # 3. Title (single Haiku call)
    if len(spoken) > 50 and _ANTHROPIC_KEY:
        title = await _make_title(spoken, lang)
    else:
        title = re.sub(r'[<>:"/\\|?*]', "", spoken[:40]).strip() or "Voice memo"

    # 4. Chunk. Longform splits on the markers the rewriter inserted.
    # Standard mode chunks at paragraph + sentence boundaries algorithmically.
    if req.longform:
        chunks = _split_on_chunk_markers(spoken, lang, req.max_chunk_chars)
    else:
        chunks = _chunk_text(
            spoken,
            lang,
            req.max_chunk_chars,
            preserve_paragraphs=req.paragraph_pause_secs is not None,
        )

    # 5. Synthesize sequentially. Fish has an internal synth lock; concurrent
    # requests would just queue inside the server, so serializing here saves
    # the round-trip overhead.
    #
    # Per-chunk language detection — the request-level `lang` decided which
    # rewriter system prompt and which Haiku title call to use, but each
    # chunk's voice is selected from the chunk's own content. This lets a
    # German briefing with a heavily English technical paragraph render that
    # paragraph in the English voice (correct pronunciation), and vice
    # versa. Falls back to the request-level lang if the chunk has no
    # language signal at all.
    audio_parts: list[np.ndarray] = []
    pause_overrides = dict(_PAUSE_AFTER)
    if req.paragraph_pause_secs is not None and req.paragraph_pause_secs >= 0:
        pause_overrides["paragraph"] = float(req.paragraph_pause_secs)
    async with httpx.AsyncClient() as http:
        for chunk_text, brk in chunks:
            chunk_lang = _detect_lang(chunk_text) or lang
            part = await _synth_chunk(chunk_text, chunk_lang, http)
            audio_parts.append(part)
            pause = pause_overrides.get(brk, 0.0)
            if pause > 0:
                audio_parts.append(_silence(pause))

    # 6. Concatenate → ffmpeg post-process (atempo + EQ + loudnorm) → MP3
    combined = np.concatenate(audio_parts) if audio_parts else _silence(0.1)
    # Clamp speed to ffmpeg atempo's documented safe band. Outside [0.5, 2.0]
    # atempo chains internally and quality degrades.
    speed = max(0.5, min(2.0, float(req.speed)))
    duration_secs = round(len(combined) / _SAMPLE_RATE / speed, 2)
    mp3_bytes = await asyncio.to_thread(_post_process, combined, lang, speed)
    audio_b64 = base64.b64encode(mp3_bytes).decode()

    return TTSResponse(
        title=title,
        audio_b64=audio_b64,
        duration_secs=duration_secs,
        chunks=len(chunks),
        lang=lang,
    )

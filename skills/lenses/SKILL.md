---
name: lenses
description: Examine an undertaking through expert lenses before anything is decided. Seam form for a system that exists: 8 to 20 lenses, one per seam, each a visible session in a Herdr tab reading the code and the system's own record, two challengers, one plan. Wide form for a new concept across many fields: 40 to 90 lenses as workflow workers, audited web sources, a staged synthesis. Use when the user asks for a step back, a review of every area, "every angle", rejects a plan as shallow, or says "lenses". Only on the user's explicit ask.
---

# Lenses: one question per expert, answers in files, one session decides

One planning agent compresses. Asked about twenty areas, it returns a summary with the depth of its shallowest one.
This skill separates the work: you write **questions**, one specialist per angle writes **answers** into its own file,
and one session **decides** across them.

**Not for** a question one `/research` run answers, a decision inside one area, or a plan the user wants in an hour.

## Which form

| | Seam form | Wide form |
|-|-|-|
| Subject | a system that exists and runs | a new concept across many fields |
| Lenses | 8 to 20, one per seam of the system | 40 to 90 in about nine groups |
| Worker | one interactive session per lens in a Herdr tab, on the model the user names | Workflow agents, out of sight |
| Evidence | the code and the system's own record first, the web for comparison | web sources, audited against their pages |
| Memo | at most 2,500 words, read in full by the session that plans | about 4,600 words, read by a synthesis run |
| Ends with | two challengers, at most three further lenses, one plan page | gap rounds, a handover, a staged synthesis |
| Cost | about 100 minutes and one session per lens | tens of millions of tokens, hours |

Sized by the subject: the owner called 40 to 60 lenses on an existing system "ein bisschen zu aggressiv" (2026-11-26).

## Files

| File | Use |
|-|-|
| `reference/seam-brief.md` | seam form: template of the shared brief and of one lens file; "How to work" and "The memo" stay as they are |
| `reference/wide-form.md` | wide form: the steps, the rules and what the first run taught |
| `reference/lens-brief.md` | wide form: template of the brief every expert reads first |
| `reference/synthesis.md` | wide form: shape of the handover page and of the synthesis run |
| `scripts/lenses.mjs`, `scripts/lens-workflow.js` | wide form: stubs, index, check, sections; the Workflow script |

A run lives where the project's reasoning lives: `brain/wiki/<domain>/lenses-<yyyy-mm>/`, with the brain's rules
(`/brain`): frontmatter, wikilinks, unique file names, `node .scripts/vault-lint.mjs` before every commit.

## Seam form

First run, software-factory, 2026-11-26 (`~/SourceRoot/brain/wiki/software-factory/lenses-2026-11/`): 19 lenses in five
waves (5, 5, 4, 2 challengers, 3 further), about 95 minutes of wall-clock, each wave done in 15 to 20 minutes, memos
of 2,500 to 2,900 words. About 160 proposals became a plan of 37 rows, six spikes and nine owner decisions. Nine
figures and eleven sentences of the confirmed concept were refuted and corrected.

1. **A confirmed concept first.** The lenses hold each area against one model the owner has confirmed (his pictures,
   his thesis). Put its text in the run folder. Without it every lens invents its own yardstick.
2. **Cut by seam, not by chapter.** One lens per contract of the system (how work enters, how it ships, what reaches
   the owner, what a worker is), never per chapter of its docs. Per lens: an expert role, what it **owns** alone, one
   **must answer** question, what belongs to neighbours, the files to start from, six to eight seed questions that
   ask for counts with their window, and **leads to test**.
3. **Leads are hypotheses.** What you already believe goes into the lens file as "From one earlier reading. Each may
   be wrong; confirm or refute it with evidence." In the first run about a quarter were refuted. A lens handed a
   conclusion returns it confirmed.
4. **Waves by dependency.** What limits comes before what is limited: language, core, measurement and the hard
   mechanics first; what goes in and what reaches the owner second; the work itself third. Write a wave's files when
   the wave before it is done: copy in the lines earlier memos wrote under "Claims about neighbours" for that lens,
   and correct any lead an earlier memo refuted.
5. **One session per lens, in a Herdr tab.** The `herdr` skill has the placement labels. The prompt names the lens
   file and nothing else, because the shell that starts the session expands the prompt. Start one, look at its
   screen, then the rest. Five at once at most. Which launcher and model is the user's word for this run.
6. **Wait on the file, not on the session.** A session reports done between turns while its explorers run. The memo's
   frontmatter turns `status: done` as its last act: a `Monitor` loop that greps for it emits one line per memo and
   one line for a terminal that left `working`.
7. **As each memo lands:** read it in full, check two of its cited lines against the code, publish it to the owner
   if the project has a place for that (a factory Report in one collection), tell him its verdicts in a few lines.
   He reads findings one by one; do not hold them for the plan.
8. **Two challengers, after the areas.** *Simplicity* counts the proposals by kind, names the smallest set that
   carries the concept, what to cut or shrink, which proposals are one change, and the first week. *Contradictions*
   settles figures that disagree and proposals that collide, lists the concept's sentences to correct, folds every
   "Yours to decide" into one list and marks what is not the owner's, and names at most three angles nobody took.
   Their section lists are in `reference/seam-brief.md`.
9. **Further lenses:** only the angles *Contradictions* names with a risk that would change the plan, at most three.
10. **One plan page.** What was found (ten lines), the order (one picture), the owner's decisions as an approval
    table (as it is, tendency, what it opens), the rows by stage, spikes with a pass mark and the build each
    authorises, what is deferred and what brings it back, what is left afterwards. A GPT critique before he sees it
    (`astra`). Then correct the concept in place. File nothing before he has read the plan.

### Rules of the seam form

- **Lenses only read.** No code change, no commit, no write command of the system under review, no touch of a
  running worker. Each writes its own memo file and nothing else.
- **The record is shared.** Read-only SQL: one connection per lens, a statement timeout, a LIMIT, never from an
  explorer. Three lenses met "too many connections" in the first run.
- **Private names stay out of memos.** A work repo is `work-repo-N`; scan a memo that touched one before you publish.
- **Evidence marks:** *code* (file and line), *record* (command and window), *source* (URL read today), *assumed*.
  An unmarked claim counts as assumed.
- **Close tabs one wave back,** so a memo's session can still be asked while the next wave reads it.
- **Do not anchor on earlier memos' figures.** Later lenses corrected several; the *Contradictions* memo says which
  value holds.

## Wide form

For a new concept across many fields: 40 to 90 lenses in about nine groups, Workflow agents on Opus, an audit of cited
claims against their pages, gap rounds, a handover and a staged synthesis in a fresh session. First run WeatherOrb,
2026-11-14: 86 lenses, 20 to 30 minutes and 240,000 to 350,000 subagent tokens each, stopped twice by the 5-hour
limit. Read `reference/wide-form.md` before you start one: its steps, its rules and what the first run taught.
Invoking it is the user's opt-in to the Workflow tool.

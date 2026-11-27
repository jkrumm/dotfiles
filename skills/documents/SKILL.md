---
name: documents
description: "The paper-document system end to end: scanning on the Brother MFC (Tinycast Scanner, scan CLI), the Eingang/Scans inbox on the Dokumente share, the finances pipeline that classifies and files a scan (fin doc inbox), the index notes in the brain, review decisions, finding a filed document, printing. Use when the user mentions scanning, a scanned paper, the inbox, a document waiting in review, where a paper is filed, finding or printing a document, or the scanner or printer itself."
---

# Documents: paper in, filed, findable

Three repos own one pipeline. This page is the map; each step's rules live in its owner's doc, named in the last column.
Read that doc before changing or debugging a step.

| Step | Where it runs | What happens | Owner and reference |
|-|-|-|-|
| 1. Scan | MacBook | Tinycast **Scanner** (`sn`) or the scan commands drive the Brother over eSCL. Pages wait as a *pending scan* in `~/.local/state/scan/pending/` until **Submit Scan** | tinycast-extensions, `AGENTS.md` § Scanner |
| 2. Inbox | the Dokumente share | Submit copies `scan-<date>-<time>.pdf` into `Dokumente/Eingang/Scans/`; a double-sided stack is two files, `…-vorne.pdf` and `…-hinten.pdf` | same |
| 3. Pipeline | mini, every 5 min (`com.jkrumm.finances-inbox`) | waits 30 s after the last write, collates the pair, turns pages upright, OCR, splits a stack into documents, classifies, files | finances, `docs/inbox.md` |
| 4. Result | share, brain, vault | original + `.txt` under `Dokumente/<folder by kind>/`, an index note `Areas/Documents/<year>/<name>.md` in the brain, a queued vault row; the scan moves to `Eingang/Scans/done/` | finances, `docs/inbox.md` § Where it lands |
| 5. Unclear | share | the file goes to `Eingang/Scans/review/` with `<name>.why.txt` (reason, proposal, how to decide) and one ntfy notice | finances, `docs/inbox.md` § Deciding a review row |

The share is mounted at `/Volumes/SSD` on the MacBook and `~/HomeLab/SSD` on the mini. The scanner state (pending scan,
log, kept failures) exists only on the MacBook.

## Rules that are easy to get wrong

- **Nothing reaches the inbox without Submit.** The scanner reports a feeder that stopped mid-stack as a clean success,
  so the page count is the only check. Compare it with the sheets before submitting; Scan More appends the rest.
- **Never start a scan from an unattended script or a test.** It needs paper in the feeder and a person. Reading state is
  always fine.
- **While `Eingang/Scans/.fin-inbox.lock` exists a run is filing: do not move, rename or delete inbox files.** Never write
  into `done/`.
- **A file in `review/` is decided, not edited.** Move it back into the inbox under a name that carries the decision
  (`<name>.single.pdf`, `<name>.split-9-12.pdf`, `.kind-<kind>`, `.date-YYYY-MM-DD`, `.issuer-<Name_With_Underscores>`),
  or on the mini run `fin doc inbox file <review-file>` with the same values as flags. The Scanner view's review tiles do
  the two common moves (one document, the proposed split).
- **A filed document is corrected with `fin doc inbox fix <share-path>`**, never by renaming on the share: the brain note,
  the text file and the vault row carry its path.
- **Blank pages and skew are the pipeline's business.** The scan PDF holds the scanner's JPEGs untouched; a blank back
  stays in `-hinten` so the pairing cannot shift.
- **Document contents are private.** Never paste text of a filed document into another repo, an Issue or a web request.

## Find a document

1. Search the index notes: `rg -il "<word>" ~/SourceRoot/brain/Areas/Documents` (frontmatter `kind`, `issuer`, `date`,
   `tax_year`, `tags`, `share_path`, `text_path`; the body is a four-sentence summary). Pull the brain first: a clone lags.
2. Read the extracted text at `<Dokumente>/<text_path>`.
3. Open or print the original at `<Dokumente>/<share_path>`.

With the vault unlocked on the mini the finances `fin` skill has the richer route (`fin doc list`, full-text search).

## Commands

```bash
# Scanner state and inbox, read-only (MacBook)
S=~/SourceRoot/tinycast-extensions/extension/scripts/scan.ts
export SCAN_INBOX=/Volumes/SSD/Dokumente/Eingang/Scans   # every call but --status and --discard needs it
bun $S --status                       # pending scan, a running scan's progress, the last result
bun $S --documents --brain-dir ~/SourceRoot/brain --dokumente-dir /Volumes/SSD/Dokumente   # review, waiting, recently filed
bun $S --check                        # inbox mounted, scanner reachable and idle, paper in the feeder
tail -40 ~/.local/state/scan/scan.log # every page of every scan, the scanner's final job record

# With the owner at the scanner
bun $S --mode feeder|fronts|backs|flatbed|more
bun $S --submit | --discard

# Printing, either machine (skill: print)
command print <file> [--pages 1-3] [--simplex]
```

Every scan CLI call prints one JSON line. The launcher aliases are `sn` (Scanner), `sd` scan, `sf`/`sb` fronts and backs,
`sm` more, `ss` submit, `sx` discard, `pr` (Printer), `ps` print the Finder selection.

## When something looks wrong

| Symptom | Look at |
|-|-|
| Fewer pages than sheets | `scan.log`: the device's `imagesCompleted` equals what it fed. Fan the stack, scan the rest with Scan More |
| "all pages look blank" | the stack went in upside down; the PDF is kept in `~/.local/state/scan/blank/` |
| Submitted, nothing filed after 10 minutes | is the file still in the inbox (pipeline did not run: `jobs-grade` on the mini), in `review/` (read the `.why.txt`), or a lone `-vorne` waiting 30 minutes for its `-hinten` |
| Filed under the wrong kind, date or issuer | `fin doc inbox fix` on the mini |
| A filed note is missing in the Scanner view | the MacBook's brain clone lags; pull it |

---
name: documents
allowed-tools: Bash(paper --help *)
description: "Paper documents end to end through the `paper` CLI: scan with the owner at the Brother scanner, the Eingang/Scans inbox and its review items (decide one), find a filed document by issuer, kind, date or words, print a file or a filed document (one- or two-sided, landscape, envelopes, labels, toner, cancel). Use when the user mentions scanning, a scanned paper, the inbox, a document in review, where a paper is filed, finding a document, or printing."
---

# Documents: paper in, filed, findable, printed

One CLI, `paper`, on both Macs. Every call prints one JSON line; exit 0 is `ok: true`, 1 a refusal (`message`), 2 a usage error. Verbs, live from the CLI
(descriptions cut at a column; `paper <verb> --help` has the flags and output fields, and `paper doctor` is the health check):

!`{ paper --help 2>&1 || echo "paper is not on this machine"; } | cut -c1-118`

## Who owns which step

| Step | Where | Owner |
|-|-|-|
| Scan: pages wait as a *pending scan* until Submit | state on the mini, once | paper |
| Inbox: `Dokumente/Eingang/Scans/`, `scan-<date>-<time>.pdf`, pairs `-vorne` / `-hinten` | the Dokumente share | paper writes, finances reads |
| Pipeline every 5 min: collate, turn, OCR, split, classify, file; unclear files go to `review/` with a `.why.txt` | mini | finances, `docs/inbox.md` |
| Index: one note per document, `Areas/Documents/<year>/<name>.md` in the brain | brain | finances writes, paper reads |
| Print: the CUPS queue of the same device | each Mac has its own | paper |

On the MacBook `scan`, `inbox` and `docs` run on the mini (`host` in `~/.config/paper/config.json`), so `paper scan status` gives the same answer on both
Macs. If the mini does not answer, the call fails with one JSON line naming it; it never scans locally. `print` always runs on the machine you type it on.

## Scan, with the owner at the scanner

1. `paper scan check`: scanner reachable and idle, paper in the feeder, nothing pending that refuses it. Read-only.
2. Start only when the owner says the stack is in: `paper scan start --mode feeder` (also `fronts`, `backs`, `flatbed`, `more`; `--wait` blocks for the result).
3. `paper scan status` shows progress, `lastResult` and `actions`, the allowed next steps each with its command.
4. Count the pages against the sheets, then `paper scan submit`. The scanner reports a feeder that stopped mid-stack as a clean success, so the count is the only check; `more` appends the rest. `paper scan discard` drops the pending scan.

Nothing reaches the inbox without Submit. A symptom list is in `paper scan log` (every page, the device's final job record).

## Decide a review item

`paper inbox list` shows each review file with its `reason`, the pipeline's `proposal` (kind, date, a `split` with its `starts`) and the `sides` of a collated pair.
Decide with `paper inbox decide <review-file> --single`, `--split 9,10,12`, or the values `--kind --issuer --date --title --object`; the move carries the decision and the
pipeline files it on its next run. Values describe one document and are refused with `--split`. A filed document that is wrong is corrected on the mini with
`fin doc inbox fix <share-path>`, never by renaming on the share: the brain note, the text file and the vault row carry its path.

While `Eingang/Scans/.fin-inbox.lock` exists a run is filing: do not move, rename or delete inbox files, and never write into `done/`.

## Find a document

`paper docs list` filters by kind, issuer, year, tax year, tag or words, newest first. `paper docs show <id>` is one record. Read the content from the file
`paper docs text <id>` names; `paper docs path <id>` is the original on this machine's mount, and `paper docs fetch <id>` copies it to a local path for a caller that cannot read the share.
After a filing, nothing shows for up to 5 minutes (the pipeline interval) and a pair waits 30 s after its last write; a lone `-vorne` waits 30 minutes for its `-hinten`.

## Print

- `paper print check` first: state, toner (`tonerPercent`, `tonerLow`), queued jobs. `paper print capabilities` says which flags the queue accepts.
- `paper print <file>` or `paper print --doc <id>` for a filed document. The edge follows the file: two-sided long edge by default, short edge when the first page is landscape,
  one-sided when the job fits one sheet side; the reply says which and why. `--simplex` only when asked, `--pages 1-3`, `--copies N`, `--n-up N`.
- Envelopes and labels: `--media EnvDL|EnvC5|Env10` or `--media-type envelope|labels`; both imply the manual tray and one-sided, and the owner loads the tray first.
- `paper print status [<jobId>]` follows a job; `paper print cancel <jobId>` stops it. A file named `check`, `status`, `capabilities` or `cancel` needs `./` in front.

## Never

- **Start a scan from an unattended script, a test or a hook.** It needs paper in the feeder and a person at the machine. Reading state is always fine.
- **Print as a proof.** Prove with `paper print <file> --dry-run`, `paper print check`, or `--hold` then `paper print cancel <jobId>`. No `lp` or `cancel` by hand.
- **Paste document contents anywhere.** No text, issuer or name of a filed document in another repo, an Issue, a commit, a log or a web request.
- **Rename, move or edit inbox files by hand.** A review file is decided with `paper inbox decide`; `inbox decide` never runs against the real review folder in a test.

Why a step is built the way it is: `~/SourceRoot/paper/AGENTS.md`, `docs/scanner.md`, `docs/printer.md`; the pipeline: finances `docs/inbox.md`.

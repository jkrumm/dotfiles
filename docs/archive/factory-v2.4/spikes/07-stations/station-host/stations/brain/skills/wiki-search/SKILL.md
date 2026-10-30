---
name: wiki-search
description: How to find and read notes in the vault wiki with rg and cat. Use before answering any vault question.
---

# Searching the wiki

1. List candidate notes: `rg -il "<term>" /Users/jkrumm/SourceRoot/brain/wiki`
2. Narrow with context: `rg -n -i "<term>" /Users/jkrumm/SourceRoot/brain/wiki/<subdir>`
3. Read a note in full: `cat /Users/jkrumm/SourceRoot/brain/wiki/<subdir>/<note>.md`

Try two or three spellings of the term (for example `version pin` and `pinned`). Combine spellings with
repeated `-e` flags (`rg -il -e pin -e pinned <wiki>`), never with a `|` in the pattern: pipes are refused.
Prefer notes
under `wiki/engineering` for tooling questions. Cite only notes you read.

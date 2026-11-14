#!/usr/bin/env node
// fallow-ignore-file unused-file -- a CLI entry point: the skill and its agents run it, nothing imports it
// Tooling for a lens research directory (see ../SKILL.md). No dependencies.
//
//   lenses.mjs --dir <dir> stubs <catalogue.txt>... [--force]   write the stub memo of every lens in the catalogue
//   lenses.mjs --dir <dir> index                                rebuild index.md from the memos' frontmatter
//   lenses.mjs --dir <dir> list                                 one line per memo: number, group, status, audit, words, title
//   lenses.mjs --dir <dir> check                                structure faults per memo; exit 1 when any exist
//   lenses.mjs --dir <dir> section <name> [filters]             print one section of many memos to stdout
//   lenses.mjs --dir <dir> args [filters] [--width n]           the JSON args for scripts/lens-workflow.js
//
// Sections: assignment, seeds, digest, questions, findings, options, guarantees, kpis, experiments, risks, challenges,
// handoffs, owner, corrections, sources.  Filters: --group <key>, --lens L24,L36.
//
// <dir>/lenses.json configures the run:
//   { "title": "Lens research, November 2026", "tags": ["weatherorb", "lens-2026-11"], "date": "2026-11-14",
//     "index": "wiki/weatherorb/lenses-2026-11/index", "parent": "wiki/weatherorb/index|WeatherOrb (wiki)",
//     "intro": "One paragraph: who asked for what, and when.",
//     "groups": [["product", "Mission and product"], ["meta", "Adversarial and staging"]] }
//
// A catalogue is plain text, one block per lens:
//   ## L24 | multiresolution-blend-math | Multi-resolution blend mathematics | blend
//   role: Applied mathematician for multi-scale analysis.
//   scope: What this lens owns, in two or three sentences.
//   not: L25 how weights are chosen; L27 the time dimension
//   prior: `docs/design/05-seams.md`; the memo [[l30-prior-art|L30]]
//   q: A seed question.            (six or more)

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync } from 'node:fs'
import { join, resolve } from 'node:path'

const argv = process.argv.slice(2)
const VALUE_FLAGS = ['--dir', '--group', '--lens', '--width']
const flag = (name) => (argv.includes(name) ? argv[argv.indexOf(name) + 1] : null)
const DIR = resolve(flag('--dir') ?? '.')
const [cmd, ...rest] = argv.filter((a, i) => !a.startsWith('--') && !VALUE_FLAGS.includes(argv[i - 1]))

const SECTIONS = {
  assignment: 'Assignment',
  seeds: 'Seed questions',
  digest: 'Digest',
  questions: 'Questions this lens adds',
  findings: 'Findings',
  options: 'Options and verdicts',
  guarantees: 'What the design must guarantee',
  kpis: 'KPIs and checks',
  experiments: 'Experiments',
  risks: 'Risks and failure modes',
  challenges: 'Challenges to rulings',
  handoffs: 'Handoffs',
  owner: 'Questions for the owner',
  corrections: 'Corrections',
  sources: 'Sources',
}
const REQUIRED = ['digest', 'questions', 'findings', 'options', 'guarantees', 'kpis', 'experiments', 'risks', 'challenges', 'handoffs', 'owner', 'sources']
const USAGE = `usage: lenses.mjs --dir <dir> stubs <catalogue>... | index | list | check | section <name> | args\nsections: ${Object.keys(SECTIONS).join(', ')}`

const die = (msg) => {
  console.error(msg)
  process.exit(2)
}
const words = (s) => s.split(/\s+/).filter(Boolean).length
const norm = (s) => s.toLowerCase().replace(/[^a-z]+/g, ' ').trim()
const firstSentence = (s) => s.split(/(?<=[.:])\s/)[0].replace(/[.:]$/, '')

function config() {
  const p = join(DIR, 'lenses.json')
  if (!existsSync(p)) die(`no lenses.json in ${DIR} (see the header of this script)`)
  const c = JSON.parse(readFileSync(p, 'utf8'))
  const missing = ['title', 'tags', 'date', 'index', 'groups'].find((k) => !c[k])
  if (missing) die(`lenses.json lacks "${missing}"`)
  return c
}

// ── memos ────────────────────────────────────────────────────────────────────────────────────────────────────────────

function unquote(v) {
  if (v.startsWith("'")) return v.slice(1, -1).replace(/''/g, "'")
  if (!v.startsWith('"')) return v
  try {
    return JSON.parse(v)
  } catch {
    return v.slice(1, -1)
  }
}

const scalar = (head, key) => unquote((head.match(new RegExp(`^${key}:\\s*(.+)$`, 'm')) ?? ['', ''])[1].trim())

function sectionsOf(body) {
  const sections = {}
  const order = []
  const parts = body.split(/^## (.+)$/m)
  for (let i = 1; i < parts.length; i += 2) {
    const key = Object.keys(SECTIONS).find((k) => norm(parts[i]).startsWith(norm(SECTIONS[k])))
    if (!key) continue
    sections[key] = parts[i + 1].trim()
    order.push(key)
  }
  return { sections, order }
}

function memo(file, cfg) {
  const text = readFileSync(join(DIR, file), 'utf8')
  const end = text.indexOf('\n---', 3)
  const head = text.slice(0, end)
  const body = text.slice(end + 4)
  const tags = [...head.matchAll(/^\s+-\s+(\S+)\s*$/gm)].map((m) => m[1])
  return {
    file,
    slug: file.replace(/\.md$/, ''),
    n: `L${file.slice(1, 3)}`,
    title: scalar(head, 'title').replace(/^Lens L\d\d · /, ''),
    description: scalar(head, 'description'),
    status: scalar(head, 'status') || 'unknown',
    audit: scalar(head, 'audit'),
    group: tags.find((t) => cfg.groups.some(([g]) => g === t)) ?? cfg.groups.at(-1)[0],
    body,
    words: words(body.slice(Math.max(0, body.search(/^## Digest/m)))),
    ...sectionsOf(body),
  }
}

const load = (cfg) =>
  existsSync(DIR)
    ? readdirSync(DIR)
        .filter((f) => /^l\d\d-.*\.md$/.test(f))
        .sort()
        .map((f) => memo(f, cfg))
    : []

function select(lenses) {
  const group = flag('--group')
  const only = flag('--lens')?.toUpperCase().split(',')
  return lenses.filter((l) => (!group || l.group === group) && (!only || only.includes(l.n)))
}

// ── catalogue and stubs ──────────────────────────────────────────────────────────────────────────────────────────────

function catalogueHeader(line) {
  const [n, slug, title, group] = line.slice(3).split('|').map((s) => s.trim())
  return { n, slug, title, group, q: [] }
}

function catalogueField(lens, line, file) {
  const m = line.match(/^(role|scope|not|prior|q): (.*)$/)
  if (!m || !lens) die(`${file}: unparsed line: ${line.slice(0, 80)}`)
  if (m[1] === 'q') lens.q.push(m[2])
  else lens[m[1]] = m[2]
}

const nonEmptyLines = (file) =>
  readFileSync(file, 'utf8')
    .split('\n')
    .map((r) => r.trimEnd())
    .filter(Boolean)

function readCatalogue(files) {
  const out = []
  for (const file of files) {
    for (const line of nonEmptyLines(file)) {
      if (line.startsWith('## ')) out.push(catalogueHeader(line))
      else catalogueField(out.at(-1), line, file)
    }
  }
  return out
}

const CATALOGUE_RULES = [
  [(l) => !/^L\d\d$/.test(l.n), (l) => `bad lens number "${l.n}" (L01 to L99)`],
  [(l, seen) => seen.has(l.n), (l) => `${l.n} appears twice`],
  [(l) => ['slug', 'title', 'role', 'scope', 'not', 'prior'].some((k) => !l[k]), (l) => `${l.n} lacks a slug, title, role, scope, not or prior line`],
  [(l) => l.q.length < 6, (l) => `${l.n} has only ${l.q.length} seed questions`],
  [(l, _seen, cfg) => !cfg.groups.some(([g]) => g === l.group), (l) => `${l.n} has unknown group "${l.group}"`],
]

function catalogue(files, cfg) {
  const out = readCatalogue(files)
  const seen = new Set()
  for (const l of out) {
    const broken = CATALOGUE_RULES.find(([test]) => test(l, seen, cfg))
    if (broken) die(broken[1](l))
    seen.add(l.n)
    l.file = `${l.n.toLowerCase()}-${l.slug}`
  }
  return out
}

const stubText = (l, cfg, link) => `---
type: Research
title: ${JSON.stringify(`Lens ${l.n} · ${l.title}`)}
description: ${JSON.stringify(`Pending. ${firstSentence(l.scope)}.`)}
tags:
${[...cfg.tags, l.group].map((t) => `  - ${t}`).join('\n')}
timestamp: ${cfg.date}
status: pending
---

# ${l.n} · ${l.title}

Part of [[${cfg.index}|${cfg.title}]]. The shared brief is [[lens-brief]]; it binds this memo.

## Assignment

**Expert:** ${l.role}

**Scope:** ${l.scope}

**Not yours** (one line under Handoffs instead): ${l.not.replace(/L\d\d/g, link)}.

**Prior material:** ${l.prior}.

## Seed questions

${l.q.map((q, i) => `${i + 1}. ${q}`).join('\n')}

## Digest

Pending.
`

function stubs(cfg) {
  if (!rest.length) die('stubs needs at least one catalogue file')
  const cat = catalogue(rest, cfg)
  const known = new Map([...load(cfg).map((l) => [l.n, l.slug]), ...cat.map((l) => [l.n, l.file])])
  const link = (n) => (known.has(n) ? `[[${known.get(n)}|${n}]]` : die(`a "not:" line names ${n}, which no catalogue or memo defines`))
  mkdirSync(DIR, { recursive: true })
  const fresh = cat.filter((l) => argv.includes('--force') || !existsSync(join(DIR, `${l.file}.md`)))
  for (const l of fresh) writeFileSync(join(DIR, `${l.file}.md`), stubText(l, cfg, link))
  console.log(`${fresh.length} stubs written; the catalogue holds ${cat.length} lenses and ${cat.reduce((a, l) => a + l.q.length, 0)} seed questions`)
}

// ── index ────────────────────────────────────────────────────────────────────────────────────────────────────────────

function indexLine(l) {
  const scope = l.sections.assignment?.match(/\*\*Scope:\*\*\s*(.+)/)?.[1] ?? ''
  return `- [[${l.slug}|${l.n} · ${l.title}]]: ${l.status === 'done' ? l.description : `(pending) ${firstSentence(scope)}.`}`
}

function index(cfg, lenses) {
  const done = lenses.filter((l) => l.status === 'done').length
  const handover = existsSync(join(DIR, 'synthesis-handover.md')) ? '\n- [[synthesis-handover|The synthesis handover]]: how the memos become decisions and documents.' : ''
  const head = `---
type: Index
title: ${JSON.stringify(cfg.title)}
description: ${JSON.stringify(`${lenses.length} expert lenses, one memo each, in ${cfg.groups.length} groups: ${cfg.groups.map(([, t]) => t.toLowerCase()).join('; ')}.`)}
tags:
  - moc
${cfg.tags.map((t) => `  - ${t}`).join('\n')}
timestamp: ${cfg.date}
---

# ${cfg.title}

${cfg.intro ?? ''}${cfg.parent ? ` Parent: [[${cfg.parent}]].` : ''}

- [[lens-brief|The shared brief]]: what every expert read first, and the sections every memo has.${handover}
- \`## Digest\` holds each memo's five to eight statements that matter most.
- \`node ~/.claude/skills/lenses/scripts/lenses.mjs --dir <this folder> section <name> [--group <key>] [--lens L24,L36]\`
  prints one section of many memos (digest, options, guarantees, kpis, experiments, risks, challenges, handoffs,
  owner); \`index\` rebuilds this page, \`check\` lists structure faults.
- State: ${done} of ${lenses.length} memos written. The line behind each lens is the memo's main verdict once it is done,
  and its scope before.
`
  const groups = cfg.groups
    .map(([g, title], i) => [`\n## ${i + 1} · ${title}\n`, ...lenses.filter((l) => l.group === g).map(indexLine)])
    .filter((block) => block.length > 1)
    .flat()
  writeFileSync(join(DIR, 'index.md'), [head, ...groups].join('\n') + '\n')
  console.log(`index written: ${done}/${lenses.length} done`)
}

// ── check ────────────────────────────────────────────────────────────────────────────────────────────────────────────

const missingSections = (l) => REQUIRED.filter((k) => !(k in l.sections))
const unescapedPipe = (row) => /^\s*\|/.test(row) && /\[\[[^\]|\\]+\|[^\]]+\]\]/.test(row)

const MEMO_RULES = [
  [(l) => /^pending/i.test(l.description), () => 'description still pending'],
  [(l) => missingSections(l).length > 0, (l) => `missing sections: ${missingSections(l).join(', ')}`],
  [(l) => !missingSections(l).length && l.order.filter((k) => REQUIRED.includes(k)).join() !== REQUIRED.join(), () => 'sections out of order'],
  [(l) => words(l.sections.digest ?? '') > 230, (l) => `digest ${words(l.sections.digest)} words`],
  [(l) => l.words < 1500 || l.words > 6500, (l) => `${l.words} words from the Digest on`],
  [(l) => l.body.split('\n').some(unescapedPipe), () => 'unescaped wikilink pipe in a table row'],
  [(l) => !l.audit, () => 'not audited'],
]

const faults = (l) => (l.status === 'done' ? MEMO_RULES.filter(([test]) => test(l)).map(([, say]) => say(l)) : [`status ${l.status}`])

function check(lenses) {
  const bad = lenses.map((l) => [l, faults(l)]).filter(([, found]) => found.length)
  for (const [l, found] of bad) console.log(`${l.n} ${l.file}: ${found.join('; ')}`)
  console.log(`${lenses.length - bad.length}/${lenses.length} memos without faults`)
  process.exit(bad.length ? 1 : 0)
}

// ── views and workflow args ──────────────────────────────────────────────────────────────────────────────────────────

function section(lenses) {
  const name = rest[0]
  if (!SECTIONS[name]) die(USAGE)
  for (const l of select(lenses).filter((x) => x.sections[name])) console.log(`# ${l.n} · ${l.title} (${l.group}, ${l.file})\n\n${l.sections[name]}\n`)
}

// Pending memos run fresh; a memo that is written but carries no audit line is checked, audited and repaired.
function workflowArgs(cfg, lenses) {
  const todo = select(lenses).filter((l) => l.status !== 'done' || !l.audit)
  const state = (l) => (l.status === 'done' ? 'written' : 'fresh')
  console.log(
    JSON.stringify({
      dir: DIR,
      total: lenses.length,
      date: cfg.date,
      width: Number(flag('--width') ?? 10),
      lenses: todo.map((l) => ({ n: l.n, file: l.file, title: l.title, state: state(l) })),
    }),
  )
}

const list = (lenses) => lenses.forEach((l) => console.log([l.n, l.group, l.status, l.audit ? 'audited' : '-', l.words, l.title].join('\t')))

const COMMANDS = {
  stubs: (cfg) => stubs(cfg),
  index: (cfg) => index(cfg, load(cfg)),
  list: (cfg) => list(load(cfg)),
  check: (cfg) => check(load(cfg)),
  section: (cfg) => section(load(cfg)),
  args: (cfg) => workflowArgs(cfg, load(cfg)),
}

if (!COMMANDS[cmd]) die(USAGE)
COMMANDS[cmd](config())

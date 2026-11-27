#!/usr/bin/env bun
// Fails when a markdown text that steers agents quotes a CLI command or flag the CLI does not have.
// Reads the quoted commands of the agent-facing CLIs (CLIS below) from code spans and fenced shell blocks and resolves each
// against the live CLI's own help. A CLI that is not installed is skipped with one line, never a failure.
//
//   bun scripts/cli-refs.ts                 scan this repo
//   bun scripts/cli-refs.ts --root <dir>    scan another repo (AGENTS.md, config/global.CLAUDE.md, rules/, skills/, agents/, docs/, .claude/{rules,skills})
//   bun scripts/cli-refs.ts --json          {findings, skipped, files, commands} on stdout
//
// Two more checks ride on the same run. Rule rows: every CLI in the table of rules/clis.md has an adapter in CLIS, a list command
// that exits 0 where the CLI is installed, and every adapter has a row. Injected commands: every !`cmd` line and ```! block under
// skills/ is run twice, once as is and once with the directories of its CLI removed from PATH; both exit 0, and a skill's
// normal runs print at most INJECT_MAX bytes together. Injected lines are not quotes: the run proves them.
//
// Exit 0 clean · 1 a finding · 2 usage error. A deliberate historical mention carries `<!-- cli-refs: ignore -->` on its line
// or alone on the line above (above a code fence: the whole block).
//
// Help is asked as `<cli> --help` and, for the CLIs marked `deep`, `<cli> <verb> --help`: only CLIs whose help never runs a verb.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs"
import { join, relative } from "node:path"

type Spec = {
  verbs: boolean // the CLI has verbs; false: its first word is an argument (jobrun <label>)
  deep: boolean // `<cli> <verb> --help` is safe and complete: ask it per verb
  noHelp?: string[] // verbs never asked (a verb whose --help would read stdin or run a wrapped command)
  extra?: string[] // verbs the top help does not list in command position
  helpFlags?: string[] // flags put before --help of the top help and a group's, not a verb's (factory's --all: its session-restricted listing hides the owner's verbs)
  valueFlags?: string[] // flags before the verb that take a value (`--format plain`)
  globalFlags?: string[]
  passthrough?: boolean // an unknown first word is forwarded to another program, so it is no finding
  helpVerbs?: string[] // verbs whose own help is asked although the CLI is not deep (the verb's flags are in its help alone)
}

// The one table: which CLIs are checked and how each is asked. Add a CLI here and nowhere else.
export const CLIS: Record<string, Spec> = {
  agw: { verbs: true, deep: false, extra: ["schema"], helpVerbs: ["schema"] },
  factory: {
    verbs: true,
    deep: true,
    noHelp: ["hook"],
    helpFlags: ["--all"],
    // verbs the help lists in no command position: `also` group, and `issue new` (filed by the owner's skill, absent from every listing)
    extra: ["follow", "deploy-lock", "merge-lock", "retro", "version", "issue new", "slot run"],
    valueFlags: ["--format"],
    globalFlags: ["--format"],
  },
  hc: { verbs: true, deep: true, valueFlags: ["--on"] },
  "playwright-cli": {
    verbs: true,
    deep: true,
    noHelp: ["close", "close-all", "kill-all", "detach", "delete-data", "install", "install-browser"],
  },
  epx: { verbs: true, deep: true },
  "chrome-devtools": { verbs: true, deep: true },
  rd: { verbs: true, deep: true },
  "shared-chrome": { verbs: true, deep: true },
  "claude-account": { verbs: true, deep: true },
  "secrets-run": { verbs: true, deep: true },
  jobrun: { verbs: false, deep: false },
  "agent-note": { verbs: false, deep: false }, // <machine>:<terminal> is its first word, not a verb
  paper: { verbs: true, deep: true },
  home: { verbs: true, deep: false, passthrough: true },
}

export const IGNORE = "cli-refs: ignore"
const LABEL: Record<Finding["kind"], string> = {
  "unknown-flag": "no such flag",
  "unknown-command": "no such command",
  "rule-row": "rule row",
  injected: "injected command",
}
const TIMEOUT_MS = 25_000
const SPAWNS = 8
const WORD = /^[a-z][a-z0-9_-]*$/
const SHELL_LANGS = new Set(["", "bash", "sh", "zsh", "shell", "console", "shell-session"])

export const RULE_FILE = "rules/clis.md"
export const INJECT_MAX = 4_000
export const FALLBACK = "is not on this machine"

export type Finding = {
  file: string
  line: number
  kind: "unknown-command" | "unknown-flag" | "rule-row" | "injected"
  cli: string
  what: string
  text: string
}
type Quote = { file: string; line: number; cli: string; rest: string; text: string }
type Result = { code: number; out: string; err: string }

// ── files ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

function walk(dir: string, skip: (path: string) => boolean): string[] {
  if (!existsSync(dir)) return []
  const out: string[] = []
  for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name)
    if (skip(path)) continue
    if (statSync(path).isDirectory()) out.push(...walk(path, skip))
    else if (name.endsWith(".md")) out.push(path)
  }
  return out
}

export function collectFiles(root: string): string[] {
  const skip = (p: string) => /(^|\/)(node_modules|worktrees|archive|\.git)$/.test(p) && !p.endsWith(`${root}`)
  const files = [join(root, "AGENTS.md"), join(root, "config/global.CLAUDE.md")].filter(existsSync)
  for (const dir of ["rules", "skills", "agents", "docs", ".claude/rules", ".claude/skills"]) files.push(...walk(join(root, dir), skip))
  // a nested AGENTS.md (apps/x/AGENTS.md) is part of the repo's agent texts too
  const nested = (dir: string, depth: number) => {
    for (const name of readdirSync(dir).sort()) {
      const path = join(dir, name)
      if (/^(node_modules|worktrees|archive|docs)$|^\./.test(name) || !statSync(path).isDirectory()) continue
      if (existsSync(join(path, "AGENTS.md"))) files.push(join(path, "AGENTS.md"))
      if (depth < 3) nested(path, depth + 1)
    }
  }
  nested(root, 1)
  return [...new Set(files)]
}

// ── quotes ────────────────────────────────────────────────────────────────────────────────────────────────────────────

const SEGMENT = /\s\|\|\s|\s&&\s|\s\|\s|;\s/
const WRAPPERS = /^(?:(?:\$|sudo|time|nohup|exec|command|then|do|else)\s+)+/
const ENV = /^(?:[A-Za-z_]\w*=\S*\s+)+/

// One shell line (or span) → the commands of the checked CLIs it starts, each with the text after the CLI's name.
function commandsOf(text: string): { cli: string; rest: string }[] {
  const found: { cli: string; rest: string }[] = []
  const inner = [...text.matchAll(/\$\(([^()]*)\)/g)].map((m) => m[1]!)
  for (let seg of [text.replace(/\$\([^()]*\)/g, " "), ...inner].flatMap((t) => t.replace(/\\\|/g, "|").split(SEGMENT))) {
    seg = seg.trim().replace(WRAPPERS, "").replace(ENV, "")
    const name = seg.split(/\s/, 1)[0]!
    if (!Object.hasOwn(CLIS, name)) continue
    found.push({ cli: name, rest: seg.slice(name.length).trim() })
  }
  return found
}

export function extract(file: string, text: string): Quote[] {
  const lines = text.split("\n")
  const quotes: Quote[] = []
  // the marker covers its own line; a line holding nothing but the marker covers the line below it (a trailing marker does not)
  const ignored = (n: number) => lines[n]!.includes(IGNORE) || (n > 0 && lines[n - 1]!.trim() === `<!-- ${IGNORE} -->`)
  const add = (n: number, source: string, cmdText: string) => {
    for (const c of commandsOf(cmdText)) quotes.push({ file, line: n + 1, ...c, text: source.trim().slice(0, 140) })
  }
  let fence: { mark: string; shell: boolean; ignored: boolean } | null = null
  for (let n = 0; n < lines.length; n++) {
    const line = lines[n]!
    const open = line.match(/^\s*(`{3,}|~{3,})\s*([\w!-]*)/)
    if (fence) {
      if (open && open[1]!.startsWith(fence.mark) && !open[2]) fence = null
      else if (fence.shell && !fence.ignored && !ignored(n) && !/^\s*#/.test(line)) {
        // a command continued with a trailing backslash is one command, reported at its first line
        let joined = line.replace(/\s#\s.*$/, "")
        let m = n
        while (/\\\s*$/.test(joined) && m + 1 < lines.length) joined = `${joined.replace(/\\\s*$/, "")} ${lines[++m]!.trim()}`
        add(n, line, joined)
        n = m
      }
      continue
    }
    if (open) {
      fence = { mark: open[1]!, shell: SHELL_LANGS.has(open[2]!.toLowerCase()), ignored: ignored(n) }
      continue
    }
    if (ignored(n)) continue
    for (const span of line.matchAll(/`([^`\n]+)`/g)) {
      const at = span.index!
      if (line[at - 1] === "!" && (at === 1 || /\s/.test(line[at - 2]!))) continue // an injected command: run by the injection check
      add(n, span[1]!, span[1]!)
    }
  }
  return quotes
}

// ── help ──────────────────────────────────────────────────────────────────────────────────────────────────────────────

type Env = Record<string, string | undefined>

class Asker {
  private cache = new Map<string, Promise<string | null>>()
  private running = 0
  private waiting: (() => void)[] = []
  constructor(readonly env: Env) {}

  which(cli: string): string | null {
    return Bun.which(cli, { PATH: this.env.PATH ?? "" })
  }

  helpFlags(cli: string): string[] {
    return CLIS[cli]?.helpFlags ?? []
  }

  private async slot<T>(fn: () => Promise<T>): Promise<T> {
    while (this.running >= SPAWNS) await new Promise<void>((r) => this.waiting.push(r))
    this.running++
    try {
      return await fn()
    } finally {
      this.running--
      this.waiting.shift()?.()
    }
  }

  // One shell command as the harness would run an injected line: stdout and stderr together, the exit code, never a hang.
  exec(command: string, env: Env = this.env): Promise<{ code: number; out: string }> {
    return this.slot(async () => {
      const proc = Bun.spawn(["/bin/bash", "-c", command], { stdin: "ignore", stdout: "pipe", stderr: "pipe", env: env as Record<string, string> })
      const timer = setTimeout(() => proc.kill(), TIMEOUT_MS)
      try {
        const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()])
        return { code: await proc.exited, out: `${out}${err}` }
      } finally {
        clearTimeout(timer)
      }
    })
  }

  get path(): string {
    return this.env.PATH ?? ""
  }

  // `<cli> <path…> --help`: stdout + stderr, null when the CLI is missing or says nothing. A CLI that answers an unknown path with
  // its top help (factory does) gives a verb nothing of its own: `verbHelp` is null then.
  async verbHelp(cli: string, path: string[]): Promise<string | null> {
    const [own, top] = await Promise.all([this.help(cli, path), this.help(cli, [])])
    return own === top ? null : own
  }

  help(cli: string, path: string[]): Promise<string | null> {
    const key = [cli, ...path].join(" ")
    let hit = this.cache.get(key)
    if (!hit) {
      hit = this.slot(async () => {
        const bin = this.which(cli)
        if (!bin) return null
        const proc = Bun.spawn([bin, ...path, ...(path.length <= 1 ? this.helpFlags(cli) : []), "--help"], { stdin: "ignore", stdout: "pipe", stderr: "pipe", env: this.env as Record<string, string> })
        const timer = setTimeout(() => proc.kill(), TIMEOUT_MS)
        try {
          const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()])
          await proc.exited
          const text = `${out}\n${err}`.trim()
          return text || null
        } finally {
          clearTimeout(timer)
        }
      })
      this.cache.set(key, hit)
    }
    return hit
  }
}

type Table = { paths: Set<string>; lines: Map<string, string[]>; text: string }

// The command table of a top help: every line at indent ≤ 4 whose leading words (after an optional `<cli> `, before a
// 2+-space gap, a placeholder or a flag) are a command path. `a|b` alternatives are separate paths.
export function parseTable(cli: string, text: string, extra: string[] = []): Table {
  const paths = new Set<string>(extra)
  const lines = new Map<string, string[]>()
  for (const raw of text.split("\n")) {
    const indent = raw.match(/^ */)![0].length
    if (indent > 4) continue
    let body = raw.trim().split(/ {2,}/, 1)[0]!
    if (body.startsWith(`${cli} `)) body = body.slice(cli.length + 1)
    let heads = [[] as string[]]
    for (const tok of body.split(/\s+/)) {
      const alts = tok.split("|")
      if (!alts.every((a) => WORD.test(a))) break
      heads = heads.flatMap((h) => alts.map((a) => [...h, a])).slice(0, 64)
      if (heads[0]!.length >= 3) break
    }
    for (const h of heads) {
      if (!h.length) continue
      // keep each prefix too, so `factory issue` is a group of `factory issue new`
      const key = h.join(" ")
      paths.add(key)
      lines.set(key, [...(lines.get(key) ?? []), raw])
    }
  }
  return { paths, lines, text }
}

// A verb help's `Commands:` section: the words in command position, nothing else (prose lines stay out).
export function subCommands(help: string, group = ""): Set<string> {
  const subs = new Set<string>()
  // a group's help lists its verbs as `<group> <verb> <args>` lines, with no Commands: header (factory issue --help)
  if (group) for (const raw of help.split("\n")) {
    const line = raw.trim()
    if (!line.startsWith(`${group} `)) continue
    const word = line.slice(group.length + 1).split(/\s+/, 1)[0]!
    if (WORD.test(word)) subs.add(word)
  }
  let inside = false
  for (const raw of help.split("\n")) {
    if (/^\s*(sub)?commands:\s*$/i.test(raw)) {
      inside = true
      continue
    }
    if (!inside) continue
    if (!raw.trim()) break
    const word = raw.trim().split(/\s+/, 1)[0]!
    if (WORD.test(word)) subs.add(word)
  }
  return subs
}

const hasPrefix = (paths: Set<string>, words: string[]) => {
  const key = words.join(" ")
  for (const p of paths) if (p === key || p.startsWith(`${key} `)) return true
  return false
}

// ── check ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

const escape = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
const mentions = (corpus: string, flag: string) => new RegExp(`(?<![\\w-])${escape(flag)}(?![\\w-])`).test(corpus)

// The tokens of a quoted command that can be a verb or flag: quoted strings, substitutions, redirections and everything after
// a ` -- ` (the wrapped program's own words) are not the CLI's.
function words(rest: string): string[] {
  const cut = rest
    .replace(/"[^"]*"|'[^']*'|\$\([^)]*\)/g, " ")
    .replace(/\s\d?>>?\S*|\s<\S+/g, " ")
    .split(/\s--(?:\s|$)/, 1)[0]!
  return cut.split(/\s+/).filter(Boolean)
}

export async function check(q: Quote, asker: Asker): Promise<Finding[]> {
  const spec = CLIS[q.cli]!
  const top = await asker.help(q.cli, [])
  if (!top) return []
  const table = parseTable(q.cli, top, spec.extra)
  const toks = words(q.rest)
  const finding = (kind: Finding["kind"], what: string): Finding => ({ file: q.file, line: q.line, kind, cli: q.cli, what, text: q.text })
  const asks = (path: string[]) => (spec.deep && !spec.noHelp?.includes(path[0]!)) || (path.length === 1 && !!spec.helpVerbs?.includes(path[0]!))

  // One word after the path so far: part of the command, an argument of it, or a verb the CLI does not have.
  const step = async (cur: string[], w: string): Promise<"ok" | "arg" | "unknown"> => {
    if (hasPrefix(table.paths, [...cur, w])) return "ok"
    if (!cur.length || !table.paths.has(cur.join(" "))) return "unknown"
    if (!asks(cur)) return "arg"
    const subs = subCommands((await asker.verbHelp(q.cli, cur)) ?? "", cur.join(" "))
    if (!subs.size) return "arg"
    if (!subs.has(w)) return "unknown"
    table.paths.add([...cur, w].join(" "))
    return "ok"
  }

  let i = 0
  while (i < toks.length && toks[i]!.startsWith("-")) i += spec.valueFlags?.includes(toks[i]!) ? 2 : 1
  const cur: string[] = []
  const out: Finding[] = []
  const alternatives: string[][] = []
  while (spec.verbs && i < toks.length) {
    const alts = toks[i]!.split("|")
    if (!alts.every((a) => WORD.test(a))) break
    const verdicts = await Promise.all(alts.map((a) => step(cur, a)))
    if (alts.length > 1) {
      // `read|write|edit`: every alternative must exist; the flags are then any of theirs
      alts.forEach((a, k) => verdicts[k] === "unknown" && out.push(finding("unknown-command", `${q.cli} ${[...cur, a].join(" ")}`)))
      if (verdicts.every((v) => v === "ok")) alternatives.push(...alts.map((a) => [...cur, a]))
      break
    }
    if (verdicts[0] === "unknown") {
      if (!(cur.length === 0 && spec.passthrough)) out.push(finding("unknown-command", `${q.cli} ${[...cur, alts[0]!].join(" ")}`))
      return out
    }
    if (verdicts[0] === "arg") break
    cur.push(alts[0]!)
    i++
  }
  if (out.length) return out

  // flags: the verb's own help, the verb's lines of the top help, the global lines; the whole top help when no verb resolved
  const paths = alternatives.length ? alternatives : cur.length ? [cur] : []
  let corpus = paths.length ? "" : top
  for (const path of paths) {
    const own = table.lines.get(path.join(" "))
    corpus += `\n${own ? own.join("\n") : top}` // a verb the help lists in no line of its own (agw schema): the whole help
    if (asks(path)) {
      const verbHelp = await asker.verbHelp(q.cli, path)
      if (verbHelp) corpus += `\n${verbHelp}`
    }
  }
  if (paths.length) corpus += `\n${top.split("\n").filter((l) => /^\s*-/.test(l)).join("\n")}\n${(spec.globalFlags ?? []).join(" ")}`
  const flags = new Set<string>()
  for (const t of toks) for (const m of t.matchAll(/(?<![\w-])(--[a-z][A-Za-z0-9-]*)/g)) flags.add(m[1]!)
  for (const f of flags) {
    if (f === "--help" || f === "--version" || mentions(corpus, f)) continue
    if (f.startsWith("--no-") && mentions(corpus, `--${f.slice(5)}`)) continue
    out.push(finding("unknown-flag", `${q.cli}${cur.length ? ` ${cur.join(" ")}` : ""} ${f}`))
  }
  return out
}

// ── rule rows ─────────────────────────────────────────────────────────────────────────────────────────────────────────

export type RuleRow = { line: number; clis: string[]; lists: string[]; text: string }

const spans = (cell: string) => [...cell.matchAll(/`([^`]+)`/g)].map((m) => m[1]!)

// The table of rules/clis.md: a row is `| CLIs | for | list commands | skill |`; the header and separator carry no code span.
export function parseRuleRows(text: string): RuleRow[] {
  const rows: RuleRow[] = []
  text.split("\n").forEach((raw, n) => {
    if (!raw.startsWith("|")) return
    const cells = raw.split("|").slice(1, -1).map((c) => c.trim())
    const clis = spans(cells[0] ?? "")
    if (clis.length) rows.push({ line: n + 1, clis, lists: spans(cells[2] ?? ""), text: raw.slice(0, 140) })
  })
  return rows
}

export async function checkRuleRows(root: string, asker: Asker): Promise<{ findings: Finding[]; skipped: string[]; rows: number }> {
  const path = join(root, RULE_FILE)
  const findings: Finding[] = []
  const skipped: string[] = []
  if (!existsSync(path)) return { findings, skipped, rows: 0 }
  const rows = parseRuleRows(readFileSync(path, "utf8"))
  const bad = (row: RuleRow, cli: string, what: string): Finding => ({ file: RULE_FILE, line: row.line, kind: "rule-row", cli, what, text: row.text })
  const listed = new Set<string>()
  for (const row of rows) {
    for (const cli of row.clis) {
      listed.add(cli)
      if (!Object.hasOwn(CLIS, cli)) findings.push(bad(row, cli, `${cli}: a row names a CLI with no adapter in CLIS`))
      if (!row.lists.some((l) => l.split(/\s/, 1)[0] === cli)) findings.push(bad(row, cli, `${cli}: no list command for it in the row`))
    }
    for (const list of row.lists) {
      const cli = list.split(/\s/, 1)[0]!
      if (!row.clis.includes(cli)) {
        findings.push(bad(row, cli, `${list}: the list command is not of a CLI in the row`))
        continue
      }
      if (!asker.which(cli)) {
        skipped.push(`${cli}: not installed, its list command was not run`)
        continue
      }
      const r = await asker.exec(list)
      if (r.code !== 0) findings.push(bad(row, cli, `${list}: the list command exits ${r.code}`))
    }
  }
  for (const cli of Object.keys(CLIS)) {
    if (!listed.has(cli)) findings.push({ file: RULE_FILE, line: 1, kind: "rule-row", cli, what: `${cli}: has an adapter and no row`, text: cli })
  }
  return { findings, skipped, rows: rows.length }
}

// ── injected commands ─────────────────────────────────────────────────────────────────────────────────────────────────

export type Injection = { file: string; line: number; command: string }

// Claude Code runs a line of the form !`cmd` (after whitespace or at the line start) and a ```! block before the skill text
// reaches the model. A fence of another language is code, not an injection.
export function injections(file: string, text: string): Injection[] {
  const found: Injection[] = []
  const lines = text.split("\n")
  for (let n = 0; n < lines.length; n++) {
    const open = lines[n]!.match(/^\s*(`{3,}|~{3,})\s*([\w!-]*)/)
    if (open) {
      const body: string[] = []
      let m = n + 1
      while (m < lines.length && !new RegExp(`^\\s*${open[1]![0] === "`" ? "`" : "~"}{${open[1]!.length},}\\s*$`).test(lines[m]!)) body.push(lines[m++]!)
      if (open[2] === "!" && body.join("").trim()) found.push({ file, line: n + 1, command: body.join("\n") })
      n = m
      continue
    }
    for (const m of lines[n]!.matchAll(/(?:^|\s)!`([^`\n]+)`/g)) found.push({ file, line: n + 1, command: m[1]! })
  }
  return found
}

// The directories that hold the CLIs a command starts, minus the system ones: removed from PATH, the CLI is gone.
function pathWithout(command: string, path: string): string {
  const system = new Set(["/bin", "/usr/bin", "/sbin", "/usr/sbin"])
  const gone = new Set<string>()
  for (const line of command.split("\n")) {
    for (let seg of line.split(SEGMENT)) {
      seg = seg.trim().replace(WRAPPERS, "").replace(ENV, "")
      const bin = seg.split(/\s/, 1)[0]!
      const at = bin && Bun.which(bin, { PATH: path })
      if (at && !system.has(at.slice(0, at.lastIndexOf("/")))) gone.add(at.slice(0, at.lastIndexOf("/")))
    }
  }
  return [...path.split(":").filter((d) => d && !gone.has(d)), "/usr/bin", "/bin"].join(":")
}

export async function checkInjected(root: string, files: string[], asker: Asker): Promise<{ findings: Finding[]; count: number }> {
  const findings: Finding[] = []
  const all = files
    .filter((f) => /(^|\/)skills\//.test(relative(root, f)))
    .flatMap((f) => injections(relative(root, f), readFileSync(f, "utf8")))
  const bad = (i: Injection, what: string): Finding => ({ file: i.file, line: i.line, kind: "injected", cli: i.command.split(/\s/, 1)[0]!, what, text: i.command.slice(0, 140) })
  const sizes = new Map<string, number>()
  await Promise.all(
    all.map(async (i) => {
      const without = await asker.exec(i.command, { ...asker.env, PATH: pathWithout(i.command, asker.path) })
      if (without.code !== 0) findings.push(bad(i, `exits ${without.code} when its CLI is not on PATH: end it with || echo "<cli> ${FALLBACK}"`))
      const normal = await asker.exec(i.command)
      if (normal.code !== 0) findings.push(bad(i, `exits ${normal.code}: a failing command aborts the whole skill`))
      else if (normal.out.includes(FALLBACK) && asker.which(i.command.split(/\s/, 1)[0]!)) findings.push(bad(i, "printed its fallback line although the CLI is on PATH"))
      sizes.set(i.file, (sizes.get(i.file) ?? 0) + Buffer.byteLength(normal.out))
    }),
  )
  for (const [file, bytes] of sizes) {
    if (bytes > INJECT_MAX) findings.push({ file, line: 1, kind: "injected", cli: "", what: `injects ${bytes} bytes, over ${INJECT_MAX}`, text: file })
  }
  return { findings, count: all.length }
}

// ── run ───────────────────────────────────────────────────────────────────────────────────────────────────────────────

export async function run(argv: string[], opts: { env?: Env; cwd?: string } = {}): Promise<Result> {
  let root = join(import.meta.dir, "..")
  let json = false
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--json") json = true
    else if (argv[i] === "--root" && argv[i + 1]) root = argv[++i]!
    else return { code: 2, out: "", err: `cli-refs: unknown argument ${argv[i]}\nusage: cli-refs [--root <dir>] [--json]\n` }
  }
  if (!existsSync(root) || !statSync(root).isDirectory()) return { code: 2, out: "", err: `cli-refs: no such directory ${root}\n` }

  const asker = new Asker(opts.env ?? (process.env as Env))
  const files = collectFiles(root)
  const quotes = files.flatMap((f) => extract(relative(root, f), readFileSync(f, "utf8")))

  const skipped: string[] = []
  const usable = new Set<string>()
  for (const cli of new Set(quotes.map((q) => q.cli))) {
    if (!asker.which(cli)) skipped.push(`${cli}: not installed, skipped`)
    else if (!(await asker.help(cli, []))) skipped.push(`${cli}: --help printed nothing, skipped`)
    else usable.add(cli)
  }
  const checked = quotes.filter((q) => usable.has(q.cli))
  const findings = (await Promise.all(checked.map((q) => check(q, asker)))).flat()
  findings.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.what.localeCompare(b.what))

  const rule = await checkRuleRows(root, asker)
  const inject = await checkInjected(root, files, asker)
  findings.push(...rule.findings, ...inject.findings)
  skipped.push(...rule.skipped)
  findings.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.what.localeCompare(b.what))

  const seen = new Set<string>()
  const unique = findings.filter((f) => {
    const key = `${f.file}:${f.line}:${f.what}`
    return !seen.has(key) && seen.add(key)
  })
  if (json) {
    const body = { findings: unique, skipped, files: files.length, commands: checked.length, ruleRows: rule.rows, injected: inject.count }
    return { code: unique.length ? 1 : 0, out: `${JSON.stringify(body, null, 2)}\n`, err: "" }
  }
  const err = unique
    .map((f) => `${f.file}:${f.line}: ${LABEL[f.kind]}: ${f.what}  | ${f.text}`)
    .concat(skipped.map((s) => `cli-refs: ${s}`))
    .join("\n")
  const summary = `cli-refs: ${checked.length} quoted commands in ${files.length} files, ${unique.length} stale; ${rule.rows} rule rows, ${inject.count} injected commands`
  return { code: unique.length ? 1 : 0, out: `${summary}\n`, err: err ? `${err}\n` : "" }
}

if (import.meta.main) {
  const r = await run(process.argv.slice(2))
  process.stdout.write(r.out)
  process.stderr.write(r.err)
  process.exit(r.code)
}

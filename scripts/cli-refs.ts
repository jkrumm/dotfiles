#!/usr/bin/env bun
// Fails when a markdown text that steers agents quotes a CLI command or flag the CLI does not have.
// Reads the quoted commands of the agent-facing CLIs (CLIS below) from code spans and fenced shell blocks and resolves each
// against the live CLI's own help. A CLI that is not installed is skipped with one line, never a failure.
//
//   bun scripts/cli-refs.ts                 scan this repo
//   bun scripts/cli-refs.ts --root <dir>    scan another repo (AGENTS.md, config/global.CLAUDE.md, rules/, skills/, agents/, docs/, .claude/{rules,skills})
//   bun scripts/cli-refs.ts --json          {findings, skipped, files, commands} on stdout
//
// Exit 0 clean · 1 a finding · 2 usage error. A deliberate historical mention carries `<!-- cli-refs: ignore -->` on its line
// or the line above (above a code fence: the whole block).
//
// Help is asked as `<cli> --help` and, for the CLIs marked `deep`, `<cli> <verb> --help`: only CLIs whose help never runs a verb.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs"
import { join, relative } from "node:path"

type Spec = {
  verbs: boolean // the CLI has verbs; false: its first word is an argument (jobrun <label>)
  deep: boolean // `<cli> <verb> --help` is safe and complete: ask it per verb
  noHelp?: string[] // verbs never asked (a verb whose --help would read stdin or run a wrapped command)
  extra?: string[] // verbs the top help does not list in command position
  valueFlags?: string[] // flags before the verb that take a value (`--format plain`)
  globalFlags?: string[]
  passthrough?: boolean // an unknown first word is forwarded to another program, so it is no finding
}

// The one table: which CLIs are checked and how each is asked. Add a CLI here and nowhere else.
export const CLIS: Record<string, Spec> = {
  agw: { verbs: true, deep: false, extra: ["schema"] },
  factory: {
    verbs: true,
    deep: true,
    noHelp: ["hook", "follow", "slot", "deploy-lock", "merge-lock"],
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
  home: { verbs: true, deep: false, passthrough: true },
}

export const IGNORE = "cli-refs: ignore"
const TIMEOUT_MS = 25_000
const SPAWNS = 8
const WORD = /^[a-z][a-z0-9_-]*$/
const SHELL_LANGS = new Set(["", "bash", "sh", "zsh", "shell", "console", "shell-session"])

export type Finding = { file: string; line: number; kind: "unknown-command" | "unknown-flag"; cli: string; what: string; text: string }
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
const WRAPPERS = /^(?:(?:\$|sudo|time|nohup|exec|then|do|else)\s+)+/
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
  const ignored = (n: number) => lines[n]!.includes(IGNORE) || (n > 0 && lines[n - 1]!.includes(IGNORE))
  const add = (n: number, source: string, cmdText: string) => {
    for (const c of commandsOf(cmdText)) quotes.push({ file, line: n + 1, ...c, text: source.trim().slice(0, 140) })
  }
  let fence: { mark: string; shell: boolean; ignored: boolean } | null = null
  for (let n = 0; n < lines.length; n++) {
    const line = lines[n]!
    const open = line.match(/^\s*(`{3,}|~{3,})\s*([\w-]*)/)
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
    for (const span of line.matchAll(/`([^`\n]+)`/g)) add(n, span[1]!, span[1]!)
  }
  return quotes
}

// ── help ──────────────────────────────────────────────────────────────────────────────────────────────────────────────

type Env = Record<string, string | undefined>

class Asker {
  private cache = new Map<string, Promise<string | null>>()
  private running = 0
  private waiting: (() => void)[] = []
  constructor(private env: Env) {}

  which(cli: string): string | null {
    return Bun.which(cli, { PATH: this.env.PATH ?? "" })
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
        const proc = Bun.spawn([bin, ...path, "--help"], { stdin: "ignore", stdout: "pipe", stderr: "pipe", env: this.env as Record<string, string> })
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
export function subCommands(help: string): Set<string> {
  const subs = new Set<string>()
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
  const asks = (path: string[]) => spec.deep && !spec.noHelp?.includes(path[0]!)

  // One word after the path so far: part of the command, an argument of it, or a verb the CLI does not have.
  const step = async (cur: string[], w: string): Promise<"ok" | "arg" | "unknown"> => {
    if (hasPrefix(table.paths, [...cur, w])) return "ok"
    if (!cur.length || !table.paths.has(cur.join(" "))) return "unknown"
    if (!asks(cur)) return "arg"
    const subs = subCommands((await asker.verbHelp(q.cli, cur)) ?? "")
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

  const seen = new Set<string>()
  const unique = findings.filter((f) => {
    const key = `${f.file}:${f.line}:${f.what}`
    return !seen.has(key) && seen.add(key)
  })
  if (json) {
    const body = { findings: unique, skipped, files: files.length, commands: checked.length }
    return { code: unique.length ? 1 : 0, out: `${JSON.stringify(body, null, 2)}\n`, err: "" }
  }
  const err = unique
    .map((f) => `${f.file}:${f.line}: ${f.kind === "unknown-flag" ? "no such flag" : "no such command"}: ${f.what}  | ${f.text}`)
    .concat(skipped.map((s) => `cli-refs: ${s}`))
    .join("\n")
  const summary = `cli-refs: ${checked.length} quoted commands in ${files.length} files, ${unique.length} stale`
  return { code: unique.length ? 1 : 0, out: `${summary}\n`, err: err ? `${err}\n` : "" }
}

if (import.meta.main) {
  const r = await run(process.argv.slice(2))
  process.stdout.write(r.out)
  process.stderr.write(r.err)
  process.exit(r.code)
}

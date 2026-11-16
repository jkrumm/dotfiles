#!/usr/bin/env bun
// Measures what the texts of this repo put into an agent's context, against the byte budgets of rules/writing-for-agents.md
// (§Budgets). Reads files only: no session, no network.
//
//   bun scripts/context-load.ts                 one line per text: bytes<TAB>budget<TAB>kind<TAB>path, then the always-loaded total
//   bun scripts/context-load.ts --repos [dir]   adds one line per AGENTS.md of every repo under dir (default ~/SourceRoot)
//   bun scripts/context-load.ts --json          the same rows as JSON
//   bun scripts/context-load.ts --check         exit 1 when an every-turn text of this repo is over budget
//
// Skill descriptions are counted in characters, every other text in bytes (`wc -c`).
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { join, relative } from "node:path"

// Budgets: rules/writing-for-agents.md §Budgets is the source; change them there first.
export const BUDGET = {
  agentsMdRoot: 12_000,
  agentsMdNested: 8_000,
  globalClaudeMd: 12_000,
  alwaysRule: 2_000,
  skillDescription: 600,
  pathsRule: 8_000,
  skillBody: 8_000,
} as const

export type Load = "always" | "reach"
export type Row = { bytes: number; budget: number | null; kind: string; path: string; load: Load }

const ROOT = join(import.meta.dir, "..")

function readText(path: string): string {
  return readFileSync(path, "utf8")
}

// Claude Code reads frontmatter leniently (an unquoted colon in a description is fine), so a strict YAML parser would reject
// files the harness loads. This reads top-level `key: value` pairs, folds indented continuation lines and block scalars.
function split(text: string): { fm: Record<string, string>; body: string } {
  const m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/)
  if (!m) return { fm: {}, body: text }
  const fm: Record<string, string> = {}
  let key: string | null = null
  for (const raw of m[1]!.split("\n")) {
    const start = !/^\s/.test(raw) && raw.match(/^([\w-]+):\s*(.*)$/)
    if (start) {
      key = start[1]!
      fm[key] = /^[>|][+-]?$/.test(start[2]!) ? "" : start[2]!
    } else if (key && raw.trim()) {
      fm[key] = `${fm[key]} ${raw.trim()}`.trim()
    }
  }
  for (const k of Object.keys(fm)) fm[k] = fm[k]!.replace(/^(["'])([\s\S]*)\1$/, "$2")
  return { fm, body: m[2]! }
}

const bytes = (s: string) => Buffer.byteLength(s, "utf8")
const chars = (s: string) => [...s].length
const mdFiles = (dir: string) =>
  existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(".md")).sort().map((f) => join(dir, f)) : []

export function collectOwn(root: string): Row[] {
  const rows: Row[] = []
  const rel = (p: string) => relative(root, p)
  const add = (bytes: number, budget: number | null, kind: string, path: string, load: Load) =>
    rows.push({ bytes, budget, kind, path: rel(path), load })

  const global = join(root, "config/global.CLAUDE.md")
  if (existsSync(global)) add(statSync(global).size, BUDGET.globalClaudeMd, "global-claude-md", global, "always")

  for (const file of mdFiles(join(root, "rules"))) {
    const text = readText(file)
    const always = !("paths" in split(text).fm)
    add(bytes(text), always ? BUDGET.alwaysRule : BUDGET.pathsRule, always ? "rule-always" : "rule-paths", file, always ? "always" : "reach")
  }

  const skillsDir = join(root, "skills")
  const skillFiles = existsSync(skillsDir)
    ? readdirSync(skillsDir).sort().map((d) => join(skillsDir, d, "SKILL.md")).filter((f) => existsSync(f))
    : []
  for (const file of skillFiles) {
    const { fm, body } = split(readText(file))
    const description = [fm.description, fm.when_to_use].filter((v) => typeof v === "string").join(" ")
    add(chars(description), BUDGET.skillDescription, "skill-description", file, "always")
    add(bytes(body), BUDGET.skillBody, "skill-body", file, "reach")
  }

  for (const file of mdFiles(join(root, "agents"))) add(statSync(file).size, null, "agent", file, "reach")
  return rows
}

// The AGENTS.md files of one repo: the root file by path, nested ones from the tracked tree (node_modules and worktrees stay out).
const at = (label: string, rest: string) => (label ? `${label}/${rest}` : rest)

export function collectAgentsMd(repo: string, label: string): Row[] {
  const rows: Row[] = []
  const rootFile = join(repo, "AGENTS.md")
  if (existsSync(rootFile)) {
    rows.push({ bytes: statSync(rootFile).size, budget: BUDGET.agentsMdRoot, kind: "agents-md-root", path: at(label, "AGENTS.md"), load: "always" })
  }
  const listed = Bun.spawnSync(["git", "-C", repo, "ls-files", "--", "*/AGENTS.md"])
  if (listed.exitCode !== 0) return rows
  for (const nested of listed.stdout.toString().split("\n").filter(Boolean).sort()) {
    const file = join(repo, nested)
    if (!existsSync(file)) continue
    rows.push({ bytes: statSync(file).size, budget: BUDGET.agentsMdNested, kind: "agents-md-nested", path: at(label, nested), load: "reach" })
  }
  return rows
}

export function collectRepos(dir: string): Row[] {
  const repos = readdirSync(dir)
    .filter((name) => !name.startsWith(".") && existsSync(join(dir, name, ".git")))
    .sort()
  return repos.flatMap((name) => collectAgentsMd(join(dir, name), name)).sort((a, b) => b.bytes - a.bytes)
}

export const alwaysTotal = (rows: Row[]) => rows.filter((r) => r.load === "always").reduce((sum, r) => sum + r.bytes, 0)
const over = (r: Row) => r.budget !== null && r.bytes > r.budget

export type Verdict = { failures: Row[]; warnings: Row[] }

// Failures: this repo's every-turn texts over budget. Warnings: its on-reach texts and its AGENTS.md files over budget.
export function verdict(root: string): Verdict {
  const own = collectOwn(root)
  const agentsMd = collectAgentsMd(root, "")
  return {
    failures: own.filter((r) => r.load === "always" && over(r)),
    warnings: [...own.filter((r) => r.load === "reach" && over(r)), ...agentsMd.filter(over)],
  }
}

const line = (r: Row) => `${r.bytes}\t${r.budget ?? "-"}\t${r.kind}\t${r.path}`
const unit = (r: Row) => (r.kind === "skill-description" ? "characters" : "bytes")
const describe = (r: Row) => `${r.path}: ${r.bytes} ${unit(r)} over ${r.budget} (${r.kind})`

export function run(argv: string[]): { code: number; out: string; err: string } {
  const flag = (name: string) => argv.indexOf(name)
  const valueOf = (name: string, fallback: string) => {
    const i = flag(name)
    const next = argv[i + 1]
    return i >= 0 && next && !next.startsWith("--") ? next : fallback
  }
  const root = valueOf("--root", ROOT)

  if (flag("--check") >= 0) {
    const { failures, warnings } = verdict(root)
    const err = [
      ...warnings.map((r) => `warning: ${describe(r)}`),
      ...failures.map((r) => `over budget: ${describe(r)}`),
    ].join("\n")
    const out = failures.length ? "" : `  ✓ every-turn context within budget (${alwaysTotal(collectOwn(root))} of this repo's always-loaded texts)\n`
    return { code: failures.length ? 1 : 0, out, err: err ? `${err}\n` : "" }
  }

  const own = collectOwn(root)
  const repos = flag("--repos") >= 0 ? collectRepos(valueOf("--repos", join(homedir(), "SourceRoot"))) : []
  const total: Row = { bytes: alwaysTotal(own), budget: null, kind: "always-loaded-total", path: ".", load: "always" }

  if (flag("--json") >= 0) {
    return { code: 0, out: `${JSON.stringify({ own, repos, total: total.bytes }, null, 2)}\n`, err: "" }
  }
  const out = [...own.map(line), line(total), ...repos.map(line)].join("\n")
  return { code: 0, out: `${out}\n`, err: "" }
}

if (import.meta.main) {
  const { code, out, err } = run(process.argv.slice(2))
  process.stdout.write(out)
  process.stderr.write(err)
  process.exit(code)
}

import { describe, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { BUDGET, alwaysTotal, collectOwn, run } from "./context-load.ts"

const SCRIPT = join(import.meta.dir, "context-load.ts")
const REAL_ROOT = join(import.meta.dir, "..")

function fixture(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), "context-load-"))
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(join(root, path, ".."), { recursive: true })
    writeFileSync(join(root, path), text)
  }
  return root
}

const skill = (description: string, body = "body\n") => `---\nname: s\ndescription: ${description}\n---\n${body}`
const BASE = {
  "config/global.CLAUDE.md": "# global\n",
  "rules/small.md": "# small\n",
  "skills/s/SKILL.md": skill("short"),
}

describe("--check", () => {
  test("passes on a fixture within every budget", () => {
    const { code, err } = run(["--check", "--root", fixture(BASE)])
    expect(code).toBe(0)
    expect(err).toBe("")
  })

  test("an always-on rule of 2,001 bytes fails, 2,000 passes", () => {
    const at = run(["--check", "--root", fixture({ ...BASE, "rules/big.md": "x".repeat(BUDGET.alwaysRule) })])
    expect(at.code).toBe(0)
    const over = run(["--check", "--root", fixture({ ...BASE, "rules/big.md": "x".repeat(BUDGET.alwaysRule + 1) })])
    expect(over.code).toBe(1)
    expect(over.err).toContain("rules/big.md: 2001 bytes over 2000")
  })

  test("a skill description of 601 characters fails, 600 passes", () => {
    const at = run(["--check", "--root", fixture({ ...BASE, "skills/s/SKILL.md": skill("d".repeat(BUDGET.skillDescription)) })])
    expect(at.code).toBe(0)
    const over = run(["--check", "--root", fixture({ ...BASE, "skills/s/SKILL.md": skill("d".repeat(BUDGET.skillDescription + 1)) })])
    expect(over.code).toBe(1)
    expect(over.err).toContain("skills/s/SKILL.md: 601 characters over 600")
  })

  test("description and when_to_use count together, in characters not bytes", () => {
    const wide = "—".repeat(300)
    const text = `---\nname: s\ndescription: ${wide}\nwhen_to_use: ${wide}\n---\nbody\n`
    const rows = collectOwn(fixture({ ...BASE, "skills/s/SKILL.md": text })).filter((r) => r.kind === "skill-description")
    expect(rows[0]?.bytes).toBe(601)
  })

  test("an unquoted colon in a description does not break the reader", () => {
    const text = "---\nname: s\ndescription: Find things: fast, and: more\n---\nbody\n"
    const rows = collectOwn(fixture({ ...BASE, "skills/s/SKILL.md": text })).filter((r) => r.kind === "skill-description")
    expect(rows[0]?.bytes).toBe("Find things: fast, and: more".length)
  })

  test("a rule with paths: is on-reach, over 8,000 only warns", () => {
    const rule = `---\npaths: ["**/*.ts"]\n---\n${"x".repeat(BUDGET.pathsRule)}`
    const { code, err } = run(["--check", "--root", fixture({ ...BASE, "rules/lazy.md": rule })])
    expect(code).toBe(0)
    expect(err).toContain("warning: rules/lazy.md")
  })

  test("an over-budget skill body and this repo's root AGENTS.md only warn", () => {
    const files = { ...BASE, "skills/s/SKILL.md": skill("short", "x".repeat(BUDGET.skillBody + 1)), "AGENTS.md": "x".repeat(BUDGET.agentsMdRoot + 1) }
    const { code, err } = run(["--check", "--root", fixture(files)])
    expect(code).toBe(0)
    expect(err).toContain("warning: skills/s/SKILL.md")
    expect(err).toContain("warning: AGENTS.md")
  })

  test("the tree as shipped passes", () => {
    const { code, err } = run(["--check", "--root", REAL_ROOT])
    expect(err).not.toContain("over budget")
    expect(code).toBe(0)
  })
})

describe("table", () => {
  test("rows are bytes<TAB>budget<TAB>kind<TAB>path and the total is the always-loaded sum", () => {
    const lines = run(["--root", fixture(BASE)]).out.trim().split("\n")
    for (const l of lines) expect(l.split("\t")).toHaveLength(4)
    const expected = "# global\n".length + "# small\n".length + "short".length
    expect(lines.find((l) => l.includes("always-loaded-total"))?.split("\t")[0]).toBe(String(expected))
  })

  test("the always-loaded total of this repo equals wc -c of its global file and always-on rules plus its description characters", () => {
    const rules = readdirSync(join(REAL_ROOT, "rules")).filter((f) => f.endsWith(".md"))
    const alwaysRules = rules.filter((f) => !/^---\n[\s\S]*?^paths:/m.test(readFileSync(join(REAL_ROOT, "rules", f), "utf8").split("\n---\n")[0]!))
    const wc = (p: string) => Number(Bun.spawnSync(["wc", "-c", join(REAL_ROOT, p)]).stdout.toString().trim().split(/\s+/)[0])
    const fileSum = wc("config/global.CLAUDE.md") + alwaysRules.reduce((sum, f) => sum + wc(`rules/${f}`), 0)
    const descriptions = collectOwn(REAL_ROOT).filter((r) => r.kind === "skill-description").reduce((sum, r) => sum + r.bytes, 0)
    expect(alwaysTotal(collectOwn(REAL_ROOT))).toBe(fileSum + descriptions)
  })

  test("--json carries the same rows", () => {
    const { out } = run(["--json", "--root", fixture(BASE)])
    const parsed = JSON.parse(out) as { own: { kind: string }[]; total: number }
    expect(parsed.own.map((r) => r.kind)).toEqual(["global-claude-md", "rule-always", "skill-description", "skill-body"])
    expect(parsed.total).toBe(9 + 8 + 5)
  })
})

describe("--repos", () => {
  test("lists each repo's root and nested AGENTS.md, largest first", () => {
    const dir = mkdtempSync(join(tmpdir(), "context-load-repos-"))
    const git = (cwd: string, ...args: string[]) => Bun.spawnSync(["git", "-C", cwd, ...args])
    for (const [name, files] of Object.entries({ a: { "AGENTS.md": "x".repeat(10), "web/AGENTS.md": "y".repeat(30) }, b: { "AGENTS.md": "z".repeat(20) } })) {
      const repo = join(dir, name)
      mkdirSync(repo)
      git(repo, "init", "-q")
      for (const [path, text] of Object.entries(files)) {
        mkdirSync(join(repo, path, ".."), { recursive: true })
        writeFileSync(join(repo, path), text)
      }
      git(repo, "add", "-A")
    }
    mkdirSync(join(dir, "not-a-repo"))
    writeFileSync(join(dir, "not-a-repo/AGENTS.md"), "ignored")

    const { out } = run(["--root", fixture(BASE), "--repos", dir])
    const rows = out.trim().split("\n").map((l) => l.split("\t")).filter((c) => c[2]?.startsWith("agents-md"))
    expect(rows.map((c) => [c[0], c[2], c[3]])).toEqual([
      ["30", "agents-md-nested", "a/web/AGENTS.md"],
      ["20", "agents-md-root", "b/AGENTS.md"],
      ["10", "agents-md-root", "a/AGENTS.md"],
    ])
  })
})

describe("cli", () => {
  test("exits 1 and names the text when over budget; reads files only, fast", () => {
    const root = fixture({ ...BASE, "rules/big.md": "x".repeat(2001) })
    const started = performance.now()
    const proc = Bun.spawnSync(["bun", SCRIPT, "--check", "--root", root])
    expect(proc.exitCode).toBe(1)
    expect(proc.stderr.toString()).toContain("over budget: rules/big.md")
    expect(performance.now() - started).toBeLessThan(2000)
  })
})

import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"

const ROOT = join(import.meta.dir, "..")
const read = (p: string) => readFileSync(join(ROOT, p), "utf8")

function frontmatter(text: string): Record<string, unknown> {
  const m = text.match(/^---\n([\s\S]*?)\n---\n/)
  expect(m).not.toBeNull()
  return Bun.YAML.parse(m![1]) as Record<string, unknown>
}

describe("rules/browser.md loads by path", () => {
  const fm = frontmatter(read("rules/browser.md"))
  const globs = (fm.paths as string[]).map((g) => new Bun.Glob(g))
  const loads = (path: string) => globs.some((g) => g.match(path))

  test("it is a lazy rule: paths, no always-on", () => {
    expect(Array.isArray(fm.paths) && fm.paths.length > 0).toBe(true)
    expect(String(fm.description)).toContain("browser")
  })

  test.each([
    "playwright.config.ts",
    "e2e/playwright.config.ts",
    "web/playwright.config.ts",
    "tests/e2e/playwright.config.ts",
    "playwright.visual.config.mjs",
    "e2e/specs/upload.spec.ts",
    "tests/e2e/console.e2e.ts",
    "packages/basalt-ui/tests/layout/harness/engine.ts",
    "packages/basalt-ui/tests/quality/matrix/harness/index.ts",
    "agents/browser.md",
    "skills/browse/SKILL.md",
    "scripts/shared-chrome.ts",
  ])("editing %s loads the rule", (path) => {
    expect(loads(path)).toBe(true)
  })

  test.each(["README.md", "src/index.ts", "src/components/Button.test.tsx", "scripts/browser-reap.py", "docs/browser.md"])(
    "editing %s does not",
    (path) => {
      expect(loads(path)).toBe(false)
    },
  )

  test("it names the reason form the hygiene probe reads and points at the evidence", () => {
    const body = read("rules/browser.md")
    expect(body).toContain("// chrome: <reason>")
    expect(body).toContain("`docs/browser.md`")
    expect(read("docs/browser.md")).toContain("## Evaluated")
  })
})

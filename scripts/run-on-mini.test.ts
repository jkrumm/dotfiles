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

describe("rules/run-on-mini.md loads by path", () => {
  const fm = frontmatter(read("rules/run-on-mini.md"))
  const globs = (fm.paths as string[]).map((g) => new Bun.Glob(g))
  const loads = (path: string) => globs.some((g) => g.match(path))

  test("it is a lazy rule: paths, no always-on", () => {
    expect(Array.isArray(fm.paths) && fm.paths.length > 0).toBe(true)
    expect(String(fm.description)).toContain("Mac mini")
  })

  test.each([
    "compose.yaml",
    "compose.yml",
    "infra/compose.dev.yaml",
    "docker/docker-compose.yml",
    "docker-compose.override.yaml",
    "collector/com.jkrumm.linewatch-app.plist.template",
    "ops/com.jkrumm.weatherorb.sync.plist",
    "launchd/job.plist.tpl",
    "mini-services.yaml",
    "config/mini/services.yaml",
  ])("editing %s loads the rule", (path) => {
    expect(loads(path)).toBe(true)
  })

  test.each(["README.md", "src/index.ts", "Dockerfile", "services.yaml", "docs/mini-registry.md", "scripts/mini-registry.ts"])("editing %s does not", (path) => {
    expect(loads(path)).toBe(false)
  })

  test("it says it applies only to the mini and points a VPS or HomeLab compose file at rules/dockerfile.md", () => {
    const body = read("rules/run-on-mini.md")
    expect(body).toMatch(/Applies to what runs on the Mac mini/)
    expect(body).toContain("`rules/dockerfile.md`")
  })

  test("its paths are a subset of what an existing compose rule already reaches, plus plists and services files", () => {
    const docker = (frontmatter(read("rules/dockerfile.md")).paths as string[]).filter((g) => /compose/.test(g))
    for (const g of docker) expect(fm.paths).toContain(g)
  })
})

describe("skills/mini-service", () => {
  const text = read("skills/mini-service/SKILL.md")
  const fm = frontmatter(text)

  test("frontmatter: name is the directory, description names every trigger and is model-invoked", () => {
    expect(fm.name).toBe("mini-service")
    const d = String(fm.description)
    expect(d.length).toBeLessThanOrEqual(1024)
    for (const t of ["LaunchAgent", "background job", "compose file", "dev server door", "database", "keep running on the mini"]) expect(d).toContain(t)
    expect(fm["disable-model-invocation"]).toBeUndefined()
  })

  test("it walks the placement questions and ends on a checkable proof", () => {
    expect(text).toContain("## 1. Place it")
    expect(text).toContain("make -C ~/SourceRoot/dotfiles mini-ps")
    expect(text).toContain("factory door route-set")
  })

  test("the global instructions point at it", () => {
    expect(read("config/global.CLAUDE.md")).toContain("skill `mini-service`")
  })
})

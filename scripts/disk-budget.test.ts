import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { commit, findUnknown, lint, parseBudget, renderTable } from "./disk-budget.ts"

const SCRIPT = join(import.meta.dir, "disk-budget.ts")
let tmp: string
let home: string
let fakeFactory: string
let calls: string

const yaml = (rows: string) => `
volume: /
volume_gib: 100
system_gib: 10
max_commit_pct: 80
unknown_gib: 0.001
scan_depth: 3
scan: ["~"]
rows:
${rows}
`

const row = (path: string, owner: string, cap: number) => `  - { path: ${path}, owner: ${owner}, cap_gib: ${cap}, class: data, enforced_by: the app }`

function run(budgetText: string, env: Record<string, string> = {}) {
  const file = join(tmp, "budget.yaml")
  writeFileSync(file, budgetText)
  const r = Bun.spawnSync(["bun", SCRIPT, "check", "--file", file], {
    env: { ...process.env, HOME: home, DISK_BUDGET_STATE_DIR: join(tmp, "state"), DISK_BUDGET_FACTORY: fakeFactory, ...env },
  })
  return { rc: r.exitCode, out: r.stdout.toString() + r.stderr.toString() }
}
// One entry per factory call: a signal's text spans lines.
const logged = () => readFileSync(calls, "utf8").split("CALL ").filter(Boolean)
const status = () => JSON.parse(readFileSync(join(tmp, "state", "status.json"), "utf8"))
const bytes = (path: string, n: number) => {
  mkdirSync(join(path, ".."), { recursive: true })
  writeFileSync(path, Buffer.alloc(n, 1))
}
const resetState = () => {
  rmSync(join(tmp, "state"), { recursive: true, force: true })
  writeFileSync(calls, "")
}

beforeAll(() => {
  tmp = mkdtempSync(join(tmpdir(), "disk-budget-"))
  home = join(tmp, "home")
  mkdirSync(home)
  calls = join(tmp, "factory-calls")
  writeFileSync(calls, "")
  fakeFactory = join(tmp, "factory")
  // Logs its argv, one line per call; refuses a repo named unknown-repo the way the factory refuses a repo it does not know.
  writeFileSync(fakeFactory, '#!/bin/sh\nprintf "CALL %s\\n" "$*" >> "' + calls + '"\ncase "$*" in *"--repo unknown-repo"*) echo "no such repo" >&2; exit 1;; esac\n')
  chmodSync(fakeFactory, 0o755)
})
afterAll(() => rmSync(tmp, { recursive: true, force: true }))

describe("the committed table", () => {
  test("is valid, under the commit limit, and rendered into docs/disk.md", () => {
    expect(lint(join(import.meta.dir, "..", "config", "mini", "disk-budget.yaml"), join(import.meta.dir, "..", "docs", "disk.md"))).toEqual([])
  })
})

describe("the table", () => {
  test("a table whose caps over-commit the volume fails lint", () => {
    const file = join(tmp, "over.yaml")
    writeFileSync(file, yaml(row("~/a", "x", 40) + "\n" + row("~/b", "y", 40)))
    const errors = lint(file, join(tmp, "no-doc.md"))
    expect(errors.length).toBe(1)
    expect(errors[0]).toContain("over-commits")
  })

  test("caps plus the system share exactly at the limit pass", () => {
    const { budget } = parseBudget(yaml(row("~/a", "x", 70)))
    const c = commit(budget!)
    expect(c.total).toBe(80)
    expect(c.total <= c.limit).toBe(true)
  })

  test("a row inside another row, a duplicate, a bad class and a missing owner are refused", () => {
    const bad = yaml([row("~/a", "x", 1), row("~/a/b", "x", 1), row("~/a", "x", 1), '  - { path: ~/c, owner: "", cap_gib: 1, class: nope, enforced_by: x }'].join("\n"))
    const { errors } = parseBudget(bad)
    expect(errors.some((e) => e.includes("inside"))).toBe(true)
    expect(errors.some((e) => e.includes("duplicate"))).toBe(true)
    expect(errors.some((e) => e.includes("class"))).toBe(true)
    expect(errors.some((e) => e.includes("owner"))).toBe(true)
  })

  test("the rendered table lists every row once", () => {
    const { budget } = parseBudget(yaml(row("~/a", "x", 5) + "\n" + row("~/b", "y", 6)))
    const table = renderTable(budget!)
    expect(table).toContain("| `~/a` | x | 5 | data | the app |")
    expect(table).toContain("Caps 11.0 + system 10.0 = 21.0 GiB")
  })
})

describe("the unknown rule", () => {
  test("reports the shallowest uncovered path over the line, not a covered one or a container", () => {
    const sizes = new Map<string, number>([
      ["/h", 900], ["/h/row", 500], ["/h/row/inner", 400], ["/h/loose", 300], ["/h/loose/deep", 290], ["/h/small", 5],
    ])
    const found = findUnknown(sizes, [{ path: "/h/row", owner: "x", cap_gib: 1, class: "data", enforced_by: "x" }], 100)
    expect(found.map(([p]) => p)).toEqual(["/h/loose"])
  })
})

describe("the check", () => {
  test("a planted over-cap row files one signal naming its owner; the status file shows measured and cap for every row", () => {
    bytes(join(home, "big", "blob"), 2 * 1024 * 1024)
    bytes(join(home, "fine", "blob"), 16 * 1024)
    const { rc, out } = run(yaml([row("~/big", "ownerrepo", 0.001), row("~/fine", "other", 5), row("~/missing", "other", 5)].join("\n")))
    expect(rc).toBe(0)
    const sent = logged()
    expect(sent.length).toBe(1)
    expect(sent[0]).toContain("signal file")
    expect(sent[0]).toContain("--repo ownerrepo")
    expect(sent[0]).toContain("--from agent:dotfiles")
    expect(sent[0]).toContain("~/big")
    expect(sent[0]).toContain("cap 0.001 GiB")
    const rows = status().rows
    expect(rows.map((r: { path: string }) => r.path)).toEqual(["~/big", "~/fine", "~/missing"])
    expect(rows[0]).toMatchObject({ over: true, cap_gib: 0.001, signal: "filed" })
    expect(rows[0].measured_gib).toBeGreaterThan(0.001)
    expect(rows[1]).toMatchObject({ over: false, cap_gib: 5, signal: null })
    expect(rows[2]).toMatchObject({ present: false, measured_gib: 0 })
    expect(out).toContain("OVER ~/big")
  })

  test("a second run stays quiet while the row is over cap, files again once it has been under, and again after 14 days", () => {
    const over = yaml([row("~/big", "ownerrepo", 0.001), row("~/fine", "other", 5)].join("\n"))
    run(over)
    expect(logged().length).toBe(1)
    expect(status().rows[0].signal).toBe("open")

    run(yaml([row("~/big", "ownerrepo", 5), row("~/fine", "other", 5)].join("\n")))
    expect(JSON.parse(readFileSync(join(tmp, "state", "state.json"), "utf8")).filed).toEqual({})
    run(over)
    expect(logged().length).toBe(2)

    const statePath = join(tmp, "state", "state.json")
    const state = JSON.parse(readFileSync(statePath, "utf8"))
    state.filed["~/big"].at = new Date(Date.now() - 15 * 86_400_000).toISOString()
    writeFileSync(statePath, JSON.stringify(state))
    run(over)
    expect(logged().length).toBe(3)
  })

  test("a repo the factory refuses gets the signal on dotfiles with the owner in the title", () => {
    resetState()
    const { rc } = run(yaml(row("~/big", "unknown-repo", 0.001)))
    expect(rc).toBe(0)
    const sent = logged()
    expect(sent.length).toBe(2)
    expect(sent[1]).toContain("--repo dotfiles")
    expect(sent[1]).toContain("[owner unknown-repo]")
  })

  test("a path over the line that no row covers is reported and signalled on dotfiles", () => {
    resetState()
    bytes(join(home, "stray", "blob"), 2 * 1024 * 1024)
    const { rc, out } = run(yaml(row("~/fine", "other", 5)))
    expect(rc).toBe(0)
    expect(out).toContain("UNKNOWN ~/stray")
    expect(status().unknown.map((u: { path: string }) => u.path)).toContain(join(home, "stray"))
    expect(logged().some((l) => l.includes("--repo dotfiles") && l.includes("no row covers it"))).toBe(true)
  })

  test("a table that over-commits the volume fails the run", () => {
    resetState()
    const { rc, out } = run(yaml(row("~/fine", "other", 95)))
    expect(rc).toBe(1)
    expect(out).toContain("OVER-COMMITTED")
    expect(status().commit.over_committed).toBe(true)
  })
})

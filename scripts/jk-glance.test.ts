import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"

// The mod imports gpui and herdr, so it cannot load here. Its pure helpers sit between `// <glance>` and `// </glance>`
// with no imports; this runs the block on its own.
const src = readFileSync(join(import.meta.dir, "../config/herdr-app/mods/jk-glance/main.js"), "utf8")
const block = /\/\/ <glance>[^\n]*\n([\s\S]*?)\/\/ <\/glance>/.exec(src)?.[1]
if (!block) throw new Error("jk-glance: no <glance> block")
const lib = new Function(`${block}; return { parseNeeds, parseOverview, parsePoll, needsTotal, newestItem, needsLabel, runningLabel, consoleLink }`)() as any

const needs = (counts: object, items: object[] = []) => JSON.stringify({ at: 1, items, counts })

test("parseNeeds: valid, invalid, empty", () => {
  const n = lib.parseNeeds(needs({ decision: 1, review: 2, errand: 0, held_signal: 0 }, [{ id: "a", title: "T", ageMs: 5 }]))
  expect(n.counts).toEqual({ decision: 1, review: 2, errand: 0, held_signal: 0 })
  expect(lib.needsTotal(n)).toBe(3)
  expect(lib.parseNeeds("")).toBeNull()
  expect(lib.parseNeeds("not json")).toBeNull()
  expect(lib.parseNeeds("{}")).toBeNull()
  expect(lib.parseNeeds(null)).toBeNull()
  expect(lib.needsTotal(lib.parseNeeds(needs({})))).toBe(0)
})

test("parseOverview: valid, invalid, empty", () => {
  expect(lib.parseOverview('{"counts":{"working":2,"waiting":1,"queued":3,"asks":9}}')).toEqual({ working: 2, waiting: 1, queued: 3 })
  expect(lib.parseOverview('{"counts":{}}')).toEqual({ working: 0, waiting: 0, queued: 0 })
  expect(lib.parseOverview("")).toBeNull()
  expect(lib.parseOverview("nope")).toBeNull()
  expect(lib.parseOverview("{}")).toBeNull()
})

test("parsePoll: parts parse on their own", () => {
  const out = `${needs({ decision: 1 })}\n@@\nbroken\n@@\nhttps://c.example.com/\n`
  const p = lib.parsePoll(out)
  expect(p.needs).not.toBeNull()
  expect(p.overview).toBeNull()
  expect(p.base).toBe("https://c.example.com/")
  expect(lib.parsePoll("").base).toBeNull()
})

test("newestItem picks the smallest ageMs", () => {
  const n = lib.parseNeeds(needs({ decision: 2 }, [{ id: "old", ageMs: 90 }, { id: "new", ageMs: 10 }]))
  expect(lib.newestItem(n).id).toBe("new")
  expect(lib.newestItem(lib.parseNeeds(needs({})))).toBeNull()
})

test("labels for 0, 1 and many needs; running", () => {
  expect(lib.needsLabel(lib.parseNeeds(needs({})))).toBe("Nothing waits on you")
  expect(lib.needsLabel(null)).toBe("Nothing waits on you")
  expect(lib.needsLabel(lib.parseNeeds(needs({ decision: 1 })))).toBe("Needs you · 1")
  expect(lib.needsLabel(lib.parseNeeds(needs({ decision: 2, review: 3, errand: 1, held_signal: 1 })))).toBe("Needs you · 7")
  expect(lib.runningLabel({ working: 2, waiting: 0, queued: 4 })).toBe("Running · 2 working · 4 queued")
  expect(lib.runningLabel({ working: 1, waiting: 3, queued: 0 })).toBe("Running · 1 working · 0 queued · 3 waiting")
  expect(lib.runningLabel(null)).toBe("Running · 0 working · 0 queued")
})

test("consoleLink", () => {
  expect(lib.consoleLink("https://c.example.com///", "needs", null)).toBe("https://c.example.com/needs-you")
  expect(lib.consoleLink("http://c.example.com", "needs", { id: "a b/c?d" })).toBe("http://c.example.com/needs-you?item=a%20b%2Fc%3Fd")
  expect(lib.consoleLink("https://c.example.com/", "flow", { id: "x" })).toBe("https://c.example.com/flow")
  expect(lib.consoleLink("", "needs", null)).toBeNull()
  expect(lib.consoleLink(null, "flow", null)).toBeNull()
  expect(lib.consoleLink("javascript:alert(1)", "needs", null)).toBeNull()
  expect(lib.consoleLink("file:///etc/passwd", "flow", null)).toBeNull()
  expect(lib.consoleLink("ftp://c.example.com", "needs", null)).toBeNull()
})

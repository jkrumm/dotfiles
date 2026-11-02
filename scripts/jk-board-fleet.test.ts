import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"

// The mod imports gpui and herdr, so it cannot load here. Its pure helpers sit between `// <tree>` / `// <fleet>` and the
// closing markers with no imports; this runs both blocks together.
const src = readFileSync(join(import.meta.dir, "../config/herdr-app/mods/jk-board/main.js"), "utf8")
const block = (name: string) => {
  const m = new RegExp(`// <${name}>[^\\n]*\\n([\\s\\S]*?)// </${name}>`).exec(src)?.[1]
  if (!m) throw new Error(`jk-board: no <${name}> block`)
  return m
}
const lib = new Function(`${block("tree")}\n${block("fleet")}; return { parse, parseFleet, sortAsks, oneLine, age, assemble, sessionKind }`)() as {
  parse: (stdout: string) => { fleet: Fleet | null; hc: { address: string }[] | null }
  parseFleet: (text: string) => Fleet | null
  sortAsks: (asks: Ask[]) => Ask[]
  oneLine: (text: string, max?: number) => string
  age: (iso: string, now?: number) => string
  assemble: (fleet: Fleet, hc: { address: string; turn?: number }[] | null) => Assembled
  sessionKind: (s: Partial<Sess>) => string
}

interface Sess { id: string; state: string; terminal: string | null; parent: string | null; wait: string | null; role: string | null }
interface Ask { id: string; at: string; tier?: string }
interface Wave { n: number; status: string; title: string }
interface Repo { name: string; space: string; sessions: Sess[]; plan: { state: string; waves: Wave[] } | null }
interface Fleet { repos: Repo[]; asks: Ask[]; unplaced?: Sess[]; queue?: { spawns: { key: string; status: string; space: string }[] } }
interface Card { name: string; kind: string | null; sessions: Sess[]; all: Sess[]; spawns: unknown[] }
interface Assembled { shown: Card[]; paused: Card[]; planned: Card[]; kids: Map<string, { address: string; turn?: number }[]> }

const S = (id: string, state: string, terminal: string | null, parent: string | null = null, extra: Partial<Sess> = {}): Sess =>
  ({ id, state, terminal, parent, wait: null, role: null, ...extra })
const W = (n: number, status: string): Wave => ({ n, status, title: `w${n}` })
const R = (name: string, state: string | null, waves: Wave[], sessions: Sess[] = []): Repo =>
  ({ name, space: `/r/${name}`, sessions, plan: state ? { state, waves } : null })

test("parseFleet reads the model and refuses anything else", () => {
  expect(lib.parseFleet(JSON.stringify({ repos: [], asks: [] }))).not.toBeNull()
  expect(lib.parseFleet(JSON.stringify({ error: "not_ready" }))).toBeNull()
  expect(lib.parseFleet('{"repos": [')).toBeNull()
  expect(lib.parseFleet("")).toBeNull()
})

test("the poll splits on the marker line only, so forged text cannot cut the fleet part", () => {
  const fleet = JSON.stringify({ repos: [], asks: [{ id: "a", text: "@@HC@@" }] })
  const hc = JSON.stringify({ terminals: [{ address: "t1" }] })
  const both = lib.parse(`${fleet}\n\n@@HC@@\n${hc}\n`)
  expect(both.fleet?.asks).toHaveLength(1)
  expect(both.hc?.map((t) => t.address)).toEqual(["t1"])
  expect(lib.parse(`${fleet}\n`).hc).toBeNull() // hc did not answer: the fleet part still reads
  expect(lib.parse("").fleet).toBeNull()
})

test("the owner's asks come first, each group oldest first", () => {
  const asks: Ask[] = [
    { id: "a", at: "2026-11-02T10:00:00Z", tier: "one_click" },
    { id: "b", at: "2026-11-02T12:00:00Z", tier: "yours" },
    { id: "c", at: "2026-11-01T09:00:00Z", tier: "hand_off" },
    { id: "d", at: "2026-11-02T08:00:00Z" }, // no tier reads as yours
  ]
  expect(lib.sortAsks(asks).map((a) => a.id)).toEqual(["d", "b", "c", "a"])
})

test("an ask is cut to one line and an age is short", () => {
  expect(lib.oneLine("Wave 13\n  needs   you\n\nnow")).toBe("Wave 13 needs you now")
  expect(lib.oneLine("x".repeat(200), 10)).toBe("xxxxxxxxx…")
  const now = Date.parse("2026-11-02T12:00:00Z")
  expect(lib.age("2026-11-02T11:59:40Z", now)).toBe("now")
  expect(lib.age("2026-11-02T11:15:00Z", now)).toBe("45m")
  expect(lib.age("2026-11-02T04:00:00Z", now)).toBe("8h")
  expect(lib.age("2026-10-16T12:00:00Z", now)).toBe("17d")
  expect(lib.age("not a date", now)).toBe("")
})

test("a session's kind: blocked, stuck and a wait on the owner need the owner", () => {
  const kind = (state: string, wait: string | null = null) => lib.sessionKind({ state, wait })
  expect([kind("blocked"), kind("stuck"), kind("idle", "owner")]).toEqual(["needs", "needs", "needs"])
  expect([kind("working"), kind("starting")]).toEqual(["working", "working"])
  expect([kind("waiting", "workers"), kind("walled"), kind("idle")]).toEqual(["waiting", "waiting", "idle"])
})

test("repos sort into shown, paused and planned from the plan's state; a finished plan nobody works is dropped", () => {
  const fleet: Fleet = {
    asks: [],
    repos: [
      R("live", "running", [W(1, "active")], [S("live-w1", "working", "t1")]),
      R("idlesession", "done", [W(1, "done")], [S("idle-1", "idle", "t2")]),
      R("stale", "stale", [W(1, "active")]),
      R("recent", "planned", [W(1, "active")]), // an active wave the model has not called stale, nobody on it
      R("ahead", "planned", [W(1, "pending")]),
      R("later", "scheduled", [W(1, "scheduled")]),
      R("finished", "done", [W(1, "done")]),
      R("bare", null, []),
      R("queued", "planned", [W(1, "pending")]),
    ],
    queue: { spawns: [{ key: "q1", status: "queued", space: "/r/queued" }, { key: "q2", status: "failed", space: "/r/ahead" }] },
  }
  const a = lib.assemble(fleet, [])
  expect(a.shown.map((r) => r.name)).toEqual(["live", "idlesession", "queued"])
  expect(a.shown[2].spawns).toHaveLength(1)
  expect(a.paused.map((r) => r.name)).toEqual(["recent", "stale"])
  expect(a.planned.map((r) => r.name)).toEqual(["ahead", "later"]) // a failed spawn does not show a repo
})

test("a child shows in its parent's tree, not beside it; the turn comes from hc", () => {
  const fleet: Fleet = {
    asks: [],
    repos: [R("r", "running", [W(1, "active")], [S("lead", "working", "t1"), S("worker", "working", "t2", "lead"), S("other", "idle", "t3")])],
    unplaced: [S("elsewhere", "idle", "t4", "lead")],
  }
  const a = lib.assemble(fleet, [{ address: "t2", turn: 7 }])
  expect(a.shown[0].sessions.map((s) => s.id)).toEqual(["lead", "other"])
  expect(a.shown[0].all.map((s) => s.id)).toEqual(["lead", "worker", "other"]) // the card counts every session, working before idle
  expect(a.kids.get("t1")?.map((t) => [t.address, t.turn])).toEqual([["t4", undefined], ["t2", 7]]) // by name: elsewhere, worker
})

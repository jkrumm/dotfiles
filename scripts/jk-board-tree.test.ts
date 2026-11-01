import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"

// The mod imports gpui and herdr, so it cannot load here. Its pure helpers sit between `// <tree>` and `// </tree>`
// with no imports; this runs that block on its own.
const src = readFileSync(join(import.meta.dir, "../config/herdr-app/mods/jk-board/main.js"), "utf8")
const block = /\/\/ <tree>[^\n]*\n([\s\S]*?)\/\/ <\/tree>/.exec(src)?.[1]
if (!block) throw new Error("jk-board: no <tree> block")
const tree = new Function(`${block}; return { parseHc, childMap, treeRows, nestedPanes, hcKind }`)() as {
  parseHc: (text: string) => Term[] | null
  childMap: (terminals: Term[]) => Map<string, Term[]>
  treeRows: (kids: Map<string, Term[]>, root: string) => { t: Term; depth: number }[]
  nestedPanes: (panes: string[], terminals: Term[]) => Set<string>
  hcKind: (t: Term) => string
}

interface Term { address: string; name?: string; parent?: string; status?: string; turn?: number }
const T = (address: string, parent?: string, extra: Partial<Term> = {}): Term => ({ address, ...(parent ? { parent } : {}), ...extra })

test("parseHc reads hc ls --json and refuses anything else", () => {
  expect(tree.parseHc(JSON.stringify({ hidden_finished: 1, terminals: [T("t4h"), T("t4j", "t4h")] }))?.map((t) => t.address)).toEqual(["t4h", "t4j"])
  expect(tree.parseHc("not json")).toBeNull()
  expect(tree.parseHc("{}")).toBeNull()
  // An address that is not one never reaches a shell command.
  expect(tree.parseHc(JSON.stringify({ terminals: [T("t1"), T("t1; rm -rf /"), T("mini/t2")] }))?.map((t) => t.address)).toEqual(["t1"])
})

test("a tab's children are a tree: name order, nested depth, direct children first at depth 1", () => {
  const kids = tree.childMap([T("t1"), T("t3", "t1", { name: "b" }), T("t2", "t1", { name: "a" }), T("t4", "t2", { name: "g" })])
  expect(tree.treeRows(kids, "t1").map(({ t, depth }) => [t.address, depth])).toEqual([["t2", 1], ["t4", 2], ["t3", 1]])
  expect(tree.treeRows(kids, "t9")).toEqual([])
})

test("a cycle ends, and a deep chain is shown whole", () => {
  const cycle = tree.childMap([T("a", "b"), T("b", "a")])
  expect(tree.treeRows(cycle, "a").map((r) => r.t.address)).toEqual(["b"])
  const chain = tree.childMap(Array.from({ length: 12 }, (_, i) => T(`t${i + 1}`, `t${i}`)))
  expect(Math.max(...tree.treeRows(chain, "t0").map((r) => r.depth))).toBe(12)
})

test("a session under another listed session shows in its tree, not beside it", () => {
  const terms = [T("t1"), T("t2", "t1"), T("t3", "t2"), T("t4"), T("t5", "t9")]
  // t3 is under t1 through t2 (not listed itself), t5's parent is not listed, t4 is a tab.
  expect([...tree.nestedPanes(["t1", "t3", "t4", "t5"], terms)].sort()).toEqual(["t3"])
  expect([...tree.nestedPanes(["t1", "t2", "t3"], terms)].sort()).toEqual(["t2", "t3"])
})

test("every nested session is reachable from a tab row, and a cycle hides nobody", () => {
  const chain = Array.from({ length: 9 }, (_, i) => T(`t${i + 1}`, `t${i}`))
  const shown = new Set(tree.treeRows(tree.childMap(chain), "t0").map((r) => r.t.address))
  const panes = ["t0", ...chain.map((t) => t.address)]
  for (const addr of tree.nestedPanes(panes, chain)) expect(shown.has(addr)).toBe(true)
  expect([...tree.nestedPanes(["a", "b"], [T("a", "b"), T("b", "a")])]).toEqual([])
})

test("hc's status becomes a row kind", () => {
  expect(tree.hcKind(T("t1", undefined, { status: "working" }))).toBe("working")
  expect(tree.hcKind(T("t1", undefined, { status: "blocked" }))).toBe("needs")
  expect(tree.hcKind(T("t1", undefined, { status: "done" }))).toBe("idle")
  expect(tree.hcKind(T("t1"))).toBe("idle")
})

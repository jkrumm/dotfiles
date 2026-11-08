import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"

// The mod imports gpui and herdr, so it cannot load here. Its pure helpers sit between `// <tree>` / `// <issues>` and the
// closing markers with no imports; this runs both blocks together.
const src = readFileSync(join(import.meta.dir, "../config/herdr-app/mods/jk-board/main.js"), "utf8")
const block = (name: string) => {
  const m = new RegExp(`// <${name}>[^\\n]*\\n([\\s\\S]*?)// </${name}>`).exec(src)?.[1]
  if (!m) throw new Error(`jk-board: no <${name}> block`)
  return m
}
// The constants above the blocks (CMD reads HC_MARK at load) run first, so a misordered declaration throws here as it would in the app.
const head = src.slice(src.indexOf('from "herdr";\n') + 'from "herdr";\n'.length, src.indexOf("// <tree>"))
const names = "CMD, pollCmd, byProject, kanban, cardLines, clock, stamp, tip, parse, parseOverview, parseIssues, parseSessions, issueCmd, queueItemId, clearCmd, sortAsks, sortHealth, splitQueue, askIssue, askBadge, summaryLine, oneLine, age, duration, compact, modelShort, factsLine, quotaLine, metaLine, issueKind, sections, holdFor, terminalsMap, timelineTail, normTab, sessionKind, known"
const lib = new Function(`${head}\n${block("tree")}\n${block("issues")}; return { ${names} }`)() as Lib

type Fn<A extends unknown[], R> = (...args: A) => R
interface Lib {
  CMD: string
  pollCmd: Fn<[boolean?], string>
  byProject: Fn<[Card[], Map<string, Sess>], { repo: string; running: Card[]; queued: Card[] }[]>
  kanban: Fn<[Card[], Map<string, Sess>, string | null?], { id: string; label: string; cards: Card[] }[]>
  cardLines: Fn<[Partial<Card>], string[]>
  clock: Fn<[string], string>
  stamp: Fn<[string], string>
  tip: Fn<[unknown, number?, number?], string>
  parse: Fn<[string], { overview: Overview | null; issues: Card[] | null; sessions: Sess[] | null; hc: { address: string }[] | null }>
  parseOverview: Fn<[string], Overview | null>
  parseIssues: Fn<[string], Card[] | null>
  parseSessions: Fn<[string], Sess[] | null>
  issueCmd: Fn<[unknown], string | null>
  queueItemId: Fn<[unknown], string | null>
  clearCmd: Fn<[unknown, unknown], string | null>
  sortAsks: Fn<[Ask[]], Ask[]>
  sortHealth: Fn<[{ id: string; since: string }[]], { id: string }[]>
  splitQueue: Fn<[Ask[]], { fresh: Ask[]; stale: Ask[] }>
  askIssue: Fn<[Partial<Ask>], number | null>
  askBadge: Fn<[Overview | null], { count: number; urgent: boolean }>
  summaryLine: Fn<[Overview], string>
  oneLine: Fn<[string, number?], string>
  age: Fn<[string, number?], string>
  duration: Fn<[number], string>
  compact: Fn<[number], string>
  modelShort: Fn<[string], string>
  factsLine: Fn<[Card], string>
  quotaLine: Fn<[Card["quota"]], string>
  metaLine: Fn<[Card], string>
  issueKind: Fn<[Card, Sess | null], string>
  sections: Fn<[Card[], Map<string, Sess>], { running: Card[]; queued: Card[]; recent: Card[] }>
  holdFor: Fn<[{ key: string; hold: string | null }[], Card], string | null>
  terminalsMap: Fn<[Card[], Sess[]], Record<string, Record<string, unknown>>>
  timelineTail: Fn<[string, number?], { at: string; text: string }[] | null>
  normTab: Fn<[unknown], string>
  sessionKind: Fn<[Partial<Sess>], string>
  known: Fn<[unknown, Set<string>], string | null>
}

interface Ask { id: string; at: string; tier?: string; stale?: boolean; issue?: number }
interface Overview { counts: { humanQueue?: number }; asks: Ask[]; humanQueue?: Ask[] }
interface Sess {
  id: string; issue: number | null; role: string; title: string; summary: string; state: string; wait: string | null
  terminal: { id: string } | null; repo: string
}
interface Card {
  id: number; filedTitle: string; title: string; about: string; summary: string; state: string; reason: string | null; outcome: string | null
  phase: string | null; repoName: string; kind: string; size: string; lead: string | null; account: string | null
  quota: { account: string; fiveHourUsed: number | null; weeklyUsed: number | null } | null
  insights: { workingMs: number; turns: number; toolCalls: number; subagents: number; tokens: { output: number }; models: string[]; partial: boolean }
  createdAt: string; updatedAt: string; closedAt: string | null; waitingOnOwner: boolean
}

const C = (id: number, extra: Partial<Card> = {}): Card => ({
  id, filedTitle: `Filed ${id}`, title: `Title ${id}`, about: `About ${id}`, summary: `Summary ${id}`, state: "working", reason: null, outcome: null, phase: "ship",
  repoName: "repo", kind: "feature", size: "l", lead: `lead-${id}-1`, account: "me", quota: null,
  insights: { workingMs: 38 * 60000, turns: 20, toolCalls: 112, subagents: 10, tokens: { output: 61000 }, models: ["claude-sonnet-5-5"], partial: false },
  createdAt: "2026-11-06T00:00:00.000Z", updatedAt: "2026-11-06T07:00:00.000Z", closedAt: null, waitingOnOwner: false, ...extra,
})
const S = (id: string, issue: number | null, terminal: string | null, extra: Partial<Sess> = {}): Sess => ({
  id, issue, role: "lead", title: `Session ${id}`, summary: `About ${id}`, state: "working", wait: null,
  terminal: terminal ? { id: terminal } : null, repo: "/Users/x/SourceRoot/repo/.claude/worktrees/factory-1-1", ...extra,
})
const byId = (...s: Sess[]) => new Map(s.map((x) => [x.id, x]))

test("the three reads parse on their own, a bad one does not take the others down", () => {
  const overview = JSON.stringify({ counts: { humanQueue: 0 }, asks: [], queue: { effective: "run", spawns: [] } })
  const issues = JSON.stringify({ issues: [C(1)] })
  const sessions = JSON.stringify({ sessions: [S("lead-1-1", 1, "t187")] })
  const hc = JSON.stringify({ terminals: [{ address: "t187" }] })
  const full = lib.parse(`${overview}\n\n@@\n${issues}\n\n@@\n${sessions}\n\n@@HC@@\n${hc}\n`)
  expect(full.overview?.queue).toEqual({ effective: "run", spawns: [] })
  expect(full.issues?.map((c) => c.id)).toEqual([1])
  expect(full.sessions?.map((s) => s.id)).toEqual(["lead-1-1"])
  expect(full.hc?.map((t) => t.address)).toEqual(["t187"])

  const cut = lib.parse(`{"error":"not_ready"}\n\n@@\n${issues}\n\n@@\n{"sessions": [\n\n@@HC@@\nnope\n`)
  expect(cut.overview).toBeNull()
  expect(cut.issues).toHaveLength(1)
  expect(cut.sessions).toBeNull()
  expect(cut.hc).toBeNull()
  expect(lib.parse("")).toEqual({ overview: null, issues: null, sessions: null, hc: null })
})

test("forged text cannot cut a part: a JSON string holds no raw newline", () => {
  const overview = JSON.stringify({ counts: {}, asks: [{ id: "a", text: "x\n@@\ny\n@@HC@@\nz" }] })
  const out = lib.parse(`${overview}\n\n@@\n${JSON.stringify({ issues: [] })}\n\n@@\n${JSON.stringify({ sessions: [] })}\n\n@@HC@@\n${JSON.stringify({ terminals: [] })}\n`)
  expect(out.overview?.asks).toHaveLength(1)
  expect(out.hc).toEqual([])
})

test("the command reads overview, issues and sessions in one secrets-run (json flag first), then the marker, then hc", () => {
  const { CMD } = lib
  expect(CMD).toContain("secrets-run run --env-file=.env.tpl --")
  for (const sub of ["read overview", "read issues --state all --limit 40", "read sessions --live"]) expect(CMD).toContain(`factory --format json ${sub}`)
  expect(CMD.indexOf("read overview")).toBeLessThan(CMD.indexOf("read issues"))
  expect(CMD.indexOf("read sessions")).toBeLessThan(CMD.indexOf("echo '@@HC@@'"))
  expect(CMD.indexOf("echo '@@HC@@'")).toBeLessThan(CMD.indexOf("hc ls --json"))
  expect(CMD).not.toContain("factory fleet")
  expect(lib.pollCmd()).toBe(CMD)
})

test("hot polling reads the same command: the overview is built from the Issues, there is no snapshot to refresh", () => {
  expect(lib.pollCmd(true)).toBe(lib.CMD)
  expect(lib.CMD).not.toContain("fleet --refresh")
  expect(lib.CMD.match(/secrets-run run/g)).toHaveLength(1)
})

test("the Issue id reaches the shell as an integer or not at all", () => {
  expect(lib.issueCmd(147)).toContain("factory --format json read issue 147")
  for (const bad of ["147; rm -rf /", "1", 0, -3, 1.5, null, undefined, NaN]) expect(lib.issueCmd(bad)).toBeNull()
})

test("the old tab name reads as issues", () => {
  expect([lib.normTab("waves"), lib.normTab("issues"), lib.normTab(null), lib.normTab("uptime")]).toEqual(["issues", "issues", "issues", "uptime"])
})

test("asks: the owner's first, then by time; a decision ask leads to its Issue", () => {
  const asks: Ask[] = [
    { id: "late", at: "2026-11-06T05:00:00Z" },
    { id: "click", at: "2026-11-06T01:00:00Z", tier: "one_click" },
    { id: "early", at: "2026-11-06T02:00:00Z", tier: "yours" },
  ]
  expect(lib.sortAsks(asks).map((a) => a.id)).toEqual(["early", "late", "click"])
  expect(lib.askIssue({ id: "decision:112:1:ask:f022bb8c-d15e", session: null } as Ask)).toBe(112)
  expect(lib.askIssue({ id: "queue:2026", issue: 7 })).toBe(7)
  expect(lib.askIssue({ id: "queue:20261105T010249-8812" })).toBeNull()
  expect(lib.askIssue({ id: "decision:x:1" })).toBeNull()
})

test("human queue: stale ones are listed apart; the badge counts asks plus the open queue, never health", () => {
  const q: Ask[] = [
    { id: "old", at: "2026-10-15T13:14:28Z", stale: true },
    { id: "new", at: "2026-11-05T20:00:09Z", stale: false },
    { id: "mid", at: "2026-11-05T00:57:49Z", stale: true },
  ]
  const { fresh, stale } = lib.splitQueue(q)
  expect(fresh.map((x) => x.id)).toEqual(["new"])
  expect(stale.map((x) => x.id)).toEqual(["old", "mid"])
  const ask: Ask = { id: "a", at: "2026-11-06T03:12:55Z", tier: "one_click" }
  expect(lib.askBadge({ counts: { humanQueue: 1 }, asks: [ask], humanQueue: q })).toEqual({ count: 2, urgent: false })
  expect(lib.askBadge({ counts: {}, asks: [], humanQueue: q })).toEqual({ count: 1, urgent: false }) // no count from the server: derived
  expect(lib.askBadge({ counts: { humanQueue: 0 }, asks: [{ ...ask, tier: undefined }] })).toEqual({ count: 1, urgent: true })
  expect(lib.askBadge(null)).toEqual({ count: 0, urgent: false })
})

test("health sorts oldest first", () => {
  expect(lib.sortHealth([{ id: "b", since: "2026-11-06T05:00:00Z" }, { id: "a", since: "2026-11-06T02:00:00Z" }]).map((h) => h.id)).toEqual(["a", "b"])
})

test("summary line", () => {
  const ov = { counts: { working: 3, waiting: 1, queued: 6, watching: 0 }, asks: [], queue: { effective: "run" } } as unknown as Overview
  expect(lib.summaryLine(ov)).toBe("3 working · 1 waiting · 6 queued · queue: run")
  expect(lib.summaryLine({ counts: { working: 1, watching: 2 }, asks: [] } as unknown as Overview)).toBe("1 working · 0 waiting · 2 watching · 0 queued")
})

test("working time, tokens, model names", () => {
  expect([0, 20_000, 38 * 60000, 60 * 60000, 125 * 60000, 7.4 * 3600000, 26 * 3600000].map(lib.duration)).toEqual(["", "<1m", "38m", "1h", "2h 5m", "7h 24m", "26h"])
  expect([0, 940, 1234, 61000, 3_400_000].map(lib.compact)).toEqual(["0", "940", "1.2k", "61k", "3.4M"])
  expect([lib.modelShort("claude-sonnet-5-5"), lib.modelShort("claude-opus-4-1"), lib.modelShort("gpt-5"), lib.modelShort("claude-x1")]).toEqual(["sonnet", "opus", "gpt-5", "x1"])
})

test("age and one-line text", () => {
  const now = Date.parse("2026-11-06T08:00:00Z")
  expect([lib.age("2026-11-06T07:59:40Z", now), lib.age("2026-11-06T07:15:00Z", now), lib.age("2026-11-05T08:00:00Z", now), lib.age("2026-11-01T08:00:00Z", now), lib.age("nope", now)])
    .toEqual(["now", "45m", "24h", "5d", ""])
  expect(lib.oneLine("a\n  b\t c")).toBe("a b c")
  expect(lib.oneLine("x".repeat(20), 10)).toBe(`${"x".repeat(9)}…`)
})

test("facts and quota lines", () => {
  expect(lib.factsLine(C(1))).toBe("feature (size l) · sonnet · 20 turns · 112 tool calls · 10 subagents · 61k tokens out")
  const partial = C(1, { insights: { ...C(1).insights, partial: true, models: [] } })
  expect(lib.factsLine(partial)).toBe("feature (size l) · 20 turns · 112 tool calls · 10 subagents · 61k tokens out · partial")
  expect(lib.factsLine(C(1, { size: "", insights: {} as Card["insights"] }))).toBe("feature")
  expect(lib.quotaLine({ account: "me2", fiveHourUsed: 1.2, weeklyUsed: 83 })).toBe("me2 5h 1% · 7d 83%")
  expect(lib.quotaLine({ account: "iu", fiveHourUsed: null, weeklyUsed: 35 })).toBe("iu 7d 35%")
  expect(lib.quotaLine(null)).toBe("")
})

test("meta line: phase, else state with its reason; unknown enums read as other", () => {
  expect(lib.metaLine(C(1))).toBe("ship · me")
  expect(lib.metaLine(C(2, { phase: null, state: "waiting", reason: "decision" }))).toBe("waiting: decision · me")
  expect(lib.metaLine(C(3, { phase: null, state: "closed", outcome: "done", account: null }))).toBe("closed: done")
  expect(lib.metaLine(C(4, { phase: null, state: "hibernating", reason: "cosmic", account: null }))).toBe("other: other")
  expect(lib.metaLine(C(5, { phase: null, state: "queued", account: null }))).toBe("queued")
})

test("issue dot: owner needs first, then the lead's state; queued and closed are idle", () => {
  const lead = S("lead-1-1", 1, "t1")
  expect(lib.issueKind(C(1, { waitingOnOwner: true }), lead)).toBe("needs")
  for (const reason of ["decision", "blocked", "wall"]) expect(lib.issueKind(C(1, { state: "waiting", reason }), null)).toBe("needs")
  expect(lib.issueKind(C(1), { ...lead, state: "stuck" })).toBe("needs")
  expect(lib.issueKind(C(1), { ...lead, state: "idle", wait: "owner" })).toBe("needs")
  expect(lib.issueKind(C(1), lead)).toBe("working")
  expect(lib.issueKind(C(1), { ...lead, state: "waiting", wait: "workers" })).toBe("waiting")
  expect(lib.issueKind(C(1), { ...lead, state: "idle" })).toBe("idle")
  expect(lib.issueKind(C(1, { state: "queued", lead: null }), null)).toBe("idle")
  expect(lib.issueKind(C(1, { state: "closed" }), lead)).toBe("idle")
  expect(lib.issueKind(C(1, { state: "watching", lead: null }), null)).toBe("waiting")
  expect(lib.issueKind(C(1, { state: "mystery", lead: null }), null)).toBe("idle")
})

test("sections: running by urgency then recency, queued oldest first, recent newest first and capped", () => {
  const leads = byId(S("lead-1-1", 1, "t1"), S("lead-2-1", 2, "t2", { state: "idle" }), S("lead-3-1", 3, "t3"), S("lead-4-1", 4, "t4", { state: "blocked" }))
  const cards = [
    C(1, { updatedAt: "2026-11-06T06:00:00Z" }),
    C(2, { updatedAt: "2026-11-06T07:50:00Z" }),
    C(3, { updatedAt: "2026-11-06T07:00:00Z" }),
    C(4, { updatedAt: "2026-11-06T01:00:00Z" }),
    C(5, { state: "queued", lead: null, createdAt: "2026-11-06T04:00:00Z" }),
    C(6, { state: "queued", lead: null, createdAt: "2026-11-06T03:00:00Z" }),
    C(7, { state: "waiting", lead: null, waitingOnOwner: true, updatedAt: "2026-11-06T02:00:00Z" }),
    C(8, { state: "settling", lead: null, updatedAt: "2026-11-06T07:59:00Z" }),
    C(9, { state: "mystery", lead: null, updatedAt: "2026-11-06T00:00:00Z" }),
    ...Array.from({ length: 10 }, (_, i) => C(20 + i, { state: "closed", lead: null, closedAt: `2026-11-0${i % 9 + 1}T00:00:00Z` })),
  ]
  const { running, queued, recent } = lib.sections(cards, leads)
  expect(running.map((c) => c.id)).toEqual([7, 4, 3, 1, 8, 2, 9]) // needs (7, 4 by recency), working (3, 1), waiting (8), idle (2, 9)
  expect(queued.map((c) => c.id)).toEqual([6, 5])
  expect(recent).toHaveLength(8)
  expect(recent.map((c) => c.closedAt)).toEqual([...recent.map((c) => c.closedAt)].sort().reverse())
})

test("a queued Issue with a live lead is running; the hold reason matches the Issue's own spawn only", () => {
  const { running, queued } = lib.sections([C(1, { state: "queued" })], byId(S("lead-1-1", 1, "t1")))
  expect([running.length, queued.length]).toEqual([1, 0])
  const spawns = [{ key: "lead-14-1", hold: "account" }, { key: "lead-140-1", hold: null }, { key: "lead-1-1", hold: "quota" }]
  expect(lib.holdFor(spawns, C(1))).toBe("quota")
  expect(lib.holdFor(spawns, C(14))).toBe("account")
  expect(lib.holdFor(spawns, C(140))).toBeNull()
  expect(lib.holdFor(spawns, C(4))).toBeNull()
})

test("the header feed: app terminal address to the Issue's words plus the session's role, nothing else", () => {
  const cards = [C(147, { filedTitle: "Trends page answers from cache", title: "Trends from cache", summary: "PR rebase-merged", phase: "ship", repoName: "dash" })]
  const sessions = [
    S("worker-147-2", 147, "t19a", { role: "worker", title: "Cache worker", state: "idle" }),
    S("lead-147-1", 147, "t187", { title: "Trends page daily cache" }),
    S("plan-x", null, "t13x", { role: "plan", title: "Planning", summary: "Looking at it", repo: "/Users/x/SourceRoot/dotfiles" }),
    S("lead-9-1", 9, null),
    S("lead-8-1", 8, "bad;id"),
  ]
  const map = lib.terminalsMap(cards, sessions)
  expect(Object.keys(map)).toEqual(["mini/t13x", "mini/t187", "mini/t19a"])
  expect(map["mini/t187"]).toEqual({
    issue: 147, title: "Trends page answers from cache", short: "Trends from cache", summary: "PR rebase-merged", phase: "ship",
    role: "lead", state: "working", repo: "dash",
  })
  expect(map["mini/t19a"]).toMatchObject({ issue: 147, short: "Trends from cache", role: "worker", state: "idle" })
  expect(map["mini/t13x"]).toEqual({ issue: null, title: "Planning", short: "Planning", summary: "Looking at it", phase: null, role: "plan", state: "working", repo: "dotfiles" })
  expect(JSON.stringify(map)).not.toContain("insights")
  // Same input, same bytes: the board publishes only on a change.
  expect(JSON.stringify(lib.terminalsMap(cards, [...sessions].reverse()))).toBe(JSON.stringify(map))
  // An Issue missing from the list falls back to the session's own text.
  expect(lib.terminalsMap([], [S("lead-5-1", 5, "t5")])["mini/t5"]).toMatchObject({ issue: 5, title: "Session lead-5-1", phase: null })
})

test("timeline tail: the last lines, one line each", () => {
  const timeline = Array.from({ length: 8 }, (_, i) => ({ at: `2026-11-06T07:1${i}:00Z`, kind: "phase", text: `step\n${i}`, session: null }))
  const tail = lib.timelineTail(JSON.stringify({ id: 1, timeline }))
  expect(tail?.map((l) => l.text)).toEqual(["step 3", "step 4", "step 5", "step 6", "step 7"])
  expect(lib.timelineTail("{}")).toBeNull()
  expect(lib.timelineTail("nope")).toBeNull()
})

test("unknown enum values read as other, known ones pass", () => {
  const set = new Set(["a"])
  expect([lib.known("a", set), lib.known("zzz", set), lib.known(null, set)]).toEqual(["a", "other", null])
  expect(lib.sessionKind({ state: "dead" })).toBe("idle")
  expect(lib.sessionKind({ state: "from-the-future" })).toBe("idle")
})

test("card lines: about, then the status, each once and never the title", () => {
  expect(lib.cardLines(C(1))).toEqual(["About 1", "Summary 1"])
  expect(lib.cardLines(C(1, { about: "  Same.  ", summary: "same." }))).toEqual(["Same."])
  expect(lib.cardLines(C(1, { about: "title 1", summary: "Working on it" }))).toEqual(["Working on it"])
  expect(lib.cardLines(C(1, { about: "", summary: "" }))).toEqual([])
  expect(lib.cardLines({ title: "T" })).toEqual([])
})

test("times by hand: HH:MM and Mon D, HH:MM, no seconds", () => {
  const iso = "2026-11-06T07:05:09Z"
  const d = new Date(iso)
  const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`
  expect(lib.clock(iso)).toBe(hm)
  expect(lib.clock(iso)).toMatch(/^\d{2}:\d{2}$/)
  expect(lib.stamp(iso)).toBe(`${["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getMonth()]} ${d.getDate()}, ${hm}`)
  expect([lib.clock("nope"), lib.clock(""), lib.stamp("nope")]).toEqual(["", "", ""])
})

test("tooltip text: collapsed, cut on a word with an ellipsis, wrapped on word boundaries", () => {
  expect(lib.tip("")).toBe("")
  expect(lib.tip(null)).toBe("")
  expect(lib.tip("  a \n\n b\t c ")).toBe("a b c")
  const long = Array.from({ length: 60 }, (_, i) => `word${i}`).join(" ")
  const out = lib.tip(long)
  const lines = out.split("\n")
  expect(lines.length).toBeGreaterThan(1)
  for (const l of lines) expect(l.length).toBeLessThanOrEqual(44)
  const flat = out.replace(/\n/g, " ")
  expect(flat.length).toBeLessThanOrEqual(200)
  expect(flat.endsWith("…")).toBe(true)
  expect(long.startsWith(flat.slice(0, -1).trimEnd())).toBe(true)
  expect(long[flat.length - 1]).toBe(" ") // cut on a word boundary
  expect(lib.tip("one two three four", 9, 100)).toBe("one two\nthree\nfour")
  expect(lib.tip("short text")).toBe("short text")
  expect(lib.tip("x".repeat(300), 44, 50)).toBe(`${"x".repeat(49)}…`) // no space to cut at
})

test("by project: most urgent repo first then name; running keeps its order, queued follows; closed is left out", () => {
  const leads = byId(S("lead-1-1", 1, "t1", { state: "idle" }), S("lead-2-1", 2, "t2"), S("lead-3-1", 3, "t3", { state: "blocked" }))
  const cards = [
    C(1, { repoName: "zeta" }), C(2, { repoName: "beta", updatedAt: "2026-11-06T06:00:00Z" }), C(3, { repoName: "alpha" }),
    C(4, { repoName: "beta", state: "queued", lead: null, createdAt: "2026-11-06T02:00:00Z" }),
    C(5, { repoName: "gamma", state: "queued", lead: null }), C(6, { repoName: "aaa", state: "queued", lead: null }),
    C(7, { repoName: "beta", lead: "lead-7-1", updatedAt: "2026-11-06T07:30:00Z" }),
    C(8, { repoName: "closedrepo", state: "closed", lead: null }),
  ]
  const out = lib.byProject(cards, leads)
  expect(out.map((p) => p.repo)).toEqual(["alpha", "beta", "aaa", "gamma", "zeta"]) // needs, working, then the idle ones (a queued card is idle) by name
  const beta = out.find((p) => p.repo === "beta")
  expect(beta?.running.map((c) => c.id)).toEqual([7, 2])
  expect(beta?.queued.map((c) => c.id)).toEqual([4])
  expect(lib.byProject([], new Map())).toEqual([])
})

test("kanban: each column's rule, the repo filter, DONE capped and newest first, QUEUED oldest first", () => {
  const leads = byId(S("lead-1-1", 1, "t1", { state: "blocked" }), S("lead-2-1", 2, "t2"), S("lead-3-1", 3, "t3", { state: "waiting", wait: "workers" }),
    S("lead-4-1", 4, "t4", { state: "idle" }), S("lead-5-1", 5, "t5"), S("lead-6-1", 6, "t6"))
  const cards = [
    C(1), C(2, { updatedAt: "2026-11-06T05:00:00Z" }), C(6, { updatedAt: "2026-11-06T06:00:00Z", repoName: "other" }), C(3), C(4),
    C(5, { state: "queued" }), // queued with a live lead: not QUEUED, its dot is idle, so WAITING
    C(7, { state: "queued", lead: null, createdAt: "2026-11-06T04:00:00Z" }), C(8, { state: "queued", lead: null, createdAt: "2026-11-06T03:00:00Z", repoName: "other" }),
    C(9, { state: "waiting", lead: null, waitingOnOwner: true }),
    ...Array.from({ length: 12 }, (_, i) => C(20 + i, { state: "closed", lead: null, closedAt: `2026-11-${String(i + 1).padStart(2, "0")}T00:00:00Z` })),
  ]
  const ids = (cols: ReturnType<typeof lib.kanban>, id: string) => cols.find((c) => c.id === id)?.cards.map((c) => c.id)
  const all = lib.kanban(cards, leads)
  expect(all.map((c) => c.label)).toEqual(["NEEDS YOU", "WORKING", "WAITING", "QUEUED", "DONE"])
  expect(ids(all, "needs")).toEqual([9, 1]) // equal activity: higher id first
  expect(ids(all, "working")).toEqual([6, 2]) // 6 (06:00) before 2 (05:00)
  expect(ids(all, "waiting")).toEqual([5, 4, 3]) // a workers wait, and idle open Issues with a live lead
  expect(ids(all, "queued")).toEqual([8, 7])
  expect(ids(all, "done")).toEqual([31, 30, 29, 28, 27, 26, 25, 24, 23, 22])
  const other = lib.kanban(cards, leads, "other")
  expect(ids(other, "working")).toEqual([6])
  expect(ids(other, "queued")).toEqual([8])
  expect(ids(other, "done")).toEqual([])
  expect(lib.kanban([], new Map()).every((c) => c.cards.length === 0)).toBe(true)
})

test("queue item id: bare or queue:-prefixed ask-human ids only, nothing else reaches a shell", () => {
  expect(lib.queueItemId("queue:20261106T230519-25755")).toBe("20261106T230519-25755")
  expect(lib.queueItemId("20261106T230519-25755")).toBe("20261106T230519-25755")
  expect(lib.queueItemId("queue:foo; rm -rf /")).toBeNull()
  expect(lib.queueItemId("queue:20261106T230519-25755; rm -rf /")).toBeNull()
  expect(lib.queueItemId("queue:")).toBeNull()
  expect(lib.queueItemId(undefined)).toBeNull()
})

test("clear command: ask-human resolve on a validated id, done or denied only", () => {
  expect(lib.clearCmd("queue:20261106T230519-25755", "done")).toBe(
    'PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; ask-human resolve 20261106T230519-25755 --as done --note "cleared from the board: done"',
  )
  expect(lib.clearCmd("20261106T230519-25755", "denied")).toBe(
    'PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; ask-human resolve 20261106T230519-25755 --as denied --note "cleared from the board: dropped"',
  )
  expect(lib.clearCmd("queue:20261106T230519-25755", "superseded")).toBeNull()
  expect(lib.clearCmd("queue:20261106T230519-25755", "done; id")).toBeNull()
  expect(lib.clearCmd("queue:foo; rm -rf /", "done")).toBeNull()
})

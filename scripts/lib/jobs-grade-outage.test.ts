import { describe, expect, test } from "bun:test"
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { type Graded, type JobState, type OutageWindow, HOLD_AFTER_BACK_MS, OUTAGE_SLACK_MS, RESTART_WINDOW_MS, gradeOne, outageHold, parseLineOutages, readOutageWindows, readSpool, reportJobs, restartWindow, summarize } from "./jobs-grade.ts"

const NOW = Date.parse("2026-11-15T12:00:00Z")
const MIN = 60_000
// The production 3 s fetch timeout flaked the loopback call at host load 25-60: the test asserts the answer, not the deadline.
const SLOW_HOST_MS = 60_000
const ago = (min: number) => new Date(NOW - min * MIN).toISOString()
const loaded = () => true

function job(p: Partial<JobState> = {}): JobState {
  return {
    label: "com.jkrumm.t", run_id: "r", started: ago(1), finished: ago(1), rc: 0, duration_ms: 1000,
    every: 300, owner: "dotfiles", owner_sha: null, last_ok: ago(1), consecutive_fail: 0, fails_24h: 0,
    fail_times: [], tail: [], runs: [], ...p,
  }
}
const run = (id: string, startedMin: number, rc: number) => ({ run_id: id, started: ago(startedMin), rc, duration_ms: 1 })

describe("line outage / host restart: failures it caused are held, not filed", () => {
  // the line was down from 40 to 10 min ago; three runs failed inside it
  const line: OutageWindow = { start: NOW - 40 * MIN, end: NOW - 10 * MIN, kind: "line" }
  const failedInside = {
    rc: 6, consecutive_fail: 3, last_ok: ago(45), fail_times: [ago(25), ago(20), ago(15)], fails_24h: 3,
    runs: [run("a", 26, 6), run("b", 21, 6), run("c", 16, 6)],
  }
  const opts = (outages: OutageWindow[], now = NOW) => ({ now, loaded, outages })

  test("a streak that finished inside an ended outage is held until the line has been back for one run", () => {
    const row = gradeOne(job(failedInside), opts([line]))
    expect(row.grade).toBe("failing")
    expect(row.held).toContain("line outage")
    expect(summarize([row]).line).toContain("(held)")
  })
  test("without windows (linewatch unknown) the same job grades as before", () => {
    expect(gradeOne(job(failedInside), { now: NOW, loaded }).held).toBeUndefined()
    expect(gradeOne(job(failedInside), opts([])).held).toBeUndefined()
  })
  test("an outage that is still going on holds", () => {
    expect(gradeOne(job(failedInside), opts([{ ...line, end: null }])).held).toContain("still going on")
  })
  test("a failure before the outage, or one after it, breaks the hold: it outlasts the outage", () => {
    const before = { ...failedInside, consecutive_fail: 4, fail_times: [ago(90), ...failedInside.fail_times] }
    expect(gradeOne(job(before), opts([line])).held).toBeUndefined()
    const after = { ...failedInside, consecutive_fail: 4, fail_times: [...failedInside.fail_times, ago(2)], runs: [...failedInside.runs, run("d", 3, 6)] }
    expect(gradeOne(job(after), opts([line])).held).toBeUndefined()
  })
  test("a run since the line came back that is still red releases the hold even when its failure sits inside the slack", () => {
    const s = job({
      ...failedInside, consecutive_fail: 4,
      fail_times: [...failedInside.fail_times, new Date((line.end as number) + OUTAGE_SLACK_MS / 2).toISOString()],
      runs: [...failedInside.runs, { run_id: "d", started: new Date((line.end as number) + 1000).toISOString(), rc: 6, duration_ms: 1 }],
    })
    expect(outageHold(s, [line], NOW)).toBeNull()
  })
  test(`the hold ends ${HOLD_AFTER_BACK_MS / MIN} min after the line returned even if the job has not run since`, () => {
    const s = job(failedInside)
    expect(outageHold(s, [line], (line.end as number) + HOLD_AFTER_BACK_MS - 1)).not.toBeNull()
    expect(outageHold(s, [line], (line.end as number) + HOLD_AFTER_BACK_MS + 1)).toBeNull()
  })
  test("a host restart is a window too", () => {
    const boot = restartWindow(NOW, 30 * 60) // booted 30 min ago: the window is 30..20 min ago
    expect((boot.end as number) - boot.start).toBe(RESTART_WINDOW_MS)
    const inside = job({ rc: 1, consecutive_fail: 3, fail_times: [ago(29), ago(26), ago(23)], fails_24h: 3, runs: [run("a", 30, 1)] })
    expect(gradeOne(inside, opts([boot])).held).toContain("host restart")
  })
  test("more failures than the record places are not guessed at", () => {
    expect(gradeOne(job({ ...failedInside, consecutive_fail: 9 }), opts([line])).held).toBeUndefined()
  })
  test("failures inside a window do not make a job flap", () => {
    const green = { rc: 0, consecutive_fail: 0, runs: [run("a", 5, 0), run("b", 4, 1), run("c", 3, 0)] }
    const flappy = { ...green, fail_times: [ago(25), ago(20), ago(15)], fails_24h: 3 }
    expect(gradeOne(job(flappy), { now: NOW, loaded }).grade).toBe("flapping")
    expect(gradeOne(job(flappy), opts([line])).grade).toBe("ok")
    const oneOutside = { ...green, fail_times: [ago(300), ago(20), ago(15)], fails_24h: 3 }
    expect(gradeOne(job(oneOutside), opts([line])).grade).toBe("ok")
    const threeOutside = { ...green, fail_times: [ago(420), ago(300), ago(180), ago(20)], fails_24h: 4 }
    expect(gradeOne(job(threeOutside), opts([line])).grade).toBe("flapping")
  })

  const tmpState = () => join(mkdtempSync(join(tmpdir(), "outage-")), "sub/report.json")
  const T0 = NOW
  const filing = (filed: string[]) => (now: number) => ({ now, file: async (s: { title: string }) => { filed.push(s.title); return true }, ntfy: async () => {} })

  test("held across ticks, the next run is green: nothing is ever filed", async () => {
    const state = tmpState()
    const filed: string[] = []
    const deps = filing(filed)
    for (let i = 0; i < 3; i++) await reportJobs([gradeOne(job(failedInside), opts([line], T0 + i * 5 * MIN))], state, deps(T0 + i * 5 * MIN))
    for (let i = 3; i < 8; i++) {
      const at = T0 + i * 5 * MIN
      const recovered = job({ rc: 0, consecutive_fail: 0, fail_times: failedInside.fail_times, fails_24h: 0, started: new Date(at - MIN).toISOString(), last_ok: new Date(at - MIN).toISOString() })
      const row = gradeOne(recovered, opts([line], at))
      expect(row.grade).toBe("ok")
      await reportJobs([row], state, deps(T0 + i * 5 * MIN))
    }
    expect(filed).toEqual([])
  })
  test("held, then the first run since the line returned is red: exactly one finding", async () => {
    const state = tmpState()
    const filed: string[] = []
    const deps = filing(filed)
    for (let i = 0; i < 2; i++) await reportJobs([gradeOne(job(failedInside), opts([line], T0 + i * 5 * MIN))], state, deps(T0 + i * 5 * MIN))
    expect(filed).toEqual([])
    const red = job({ ...failedInside, consecutive_fail: 4, fail_times: [...failedInside.fail_times, ago(1)], runs: [...failedInside.runs, run("d", 2, 6)] })
    for (let i = 2; i < 8; i++) {
      const row = gradeOne({ ...red, started: new Date(T0 + i * 5 * MIN - MIN).toISOString() }, opts([line], T0 + i * 5 * MIN))
      expect(row.held).toBeUndefined()
      await reportJobs([row], state, deps(T0 + i * 5 * MIN))
    }
    expect(filed).toEqual(["Background job com.jkrumm.t needs a fix"])
  })

  test("parseLineOutages reads linewatch rows; anything else is unknown, never 'no outage'", () => {
    expect(parseLineOutages({ outages: [{ startedAt: 5, endedAt: 9 }, { startedAt: 12, endedAt: null }] })).toEqual([{ start: 5, end: 9, kind: "line" }, { start: 12, end: null, kind: "line" }])
    expect(parseLineOutages({ outages: [] })).toEqual([])
    expect(parseLineOutages({})).toBeNull()
    expect(parseLineOutages({ outages: [{ endedAt: 1 }] })).toBeNull()
    expect(parseLineOutages("x")).toBeNull()
  })
  test("readOutageWindows: linewatch answers, answers garbage or is down; the restart window is always there", async () => {
    const saved = process.env.LINEWATCH_URL
    const server = Bun.serve({ port: 0, fetch: (req) => new URL(req.url).pathname === "/api/outages" ? Response.json({ outages: [{ startedAt: NOW - 1000, endedAt: null }] }) : new Response("no", { status: 500 }) })
    const port = server.port
    try {
      process.env.LINEWATCH_URL = `http://127.0.0.1:${port}`
      const up = await readOutageWindows(NOW, 3600, SLOW_HOST_MS)
      expect(up.map((w) => w.kind)).toEqual(["restart", "line"])
      expect(up[1].end).toBeNull()
      process.env.LINEWATCH_URL = `http://127.0.0.1:${port}/nope`
      expect((await readOutageWindows(NOW, 3600, SLOW_HOST_MS)).map((w) => w.kind)).toEqual(["restart"])
      await server.stop(true)
      process.env.LINEWATCH_URL = `http://127.0.0.1:${port}`
      expect((await readOutageWindows(NOW, 3600, SLOW_HOST_MS)).map((w) => w.kind)).toEqual(["restart"])
    } finally {
      await server.stop(true)
      if (saved === undefined) delete process.env.LINEWATCH_URL
      else process.env.LINEWATCH_URL = saved
    }
  }, SLOW_HOST_MS * 2)
})

describe("--report: an undeliverable alert is spooled and replayed once", () => {
  const T0 = NOW
  const row = (label: string): Graded => ({ ...gradeOne(job({ label }), { now: NOW, loaded }), grade: "failing", reason: "3 consecutive failures" })
  const stateFile = () => join(mkdtempSync(join(tmpdir(), "spool-")), "sub/report.json")
  const spoolOf = (statePath: string, at = T0 + 100 * MIN) => readSpool(join(statePath, "..", "spool"), at)

  test("down, then up: delivered once, oldest first, with its original time", async () => {
    const path = stateFile()
    const filed: { title: string; text: string }[] = []
    const ntfy: string[] = []
    let up = false
    const deps = (now: number) => ({ now, file: async (s: { title: string; text: string }) => { if (up) filed.push(s); return up }, ntfy: async (t: string) => { ntfy.push(t) } })
    const a = row("com.jkrumm.a")
    const b = row("com.jkrumm.b")
    await reportJobs([a], path, deps(T0))
    await reportJobs([a], path, deps(T0 + 5 * MIN)) // a is due, the factory is down: spooled, ntfy fallback
    await reportJobs([a, b], path, deps(T0 + 10 * MIN))
    await reportJobs([a, b], path, deps(T0 + 15 * MIN)) // b is due now, still down
    expect(spoolOf(path).map((s) => s.entry.key)).toEqual(["com.jkrumm.a", "com.jkrumm.b"])
    expect(spoolOf(path)[0].entry.at).toBe(T0 + 5 * MIN) // a repeat does not move the original time
    expect(filed).toEqual([])
    expect(ntfy).toHaveLength(2)

    up = true
    expect(await reportJobs([a, b], path, deps(T0 + 20 * MIN))).toBe("ok")
    expect(filed.map((s) => s.title)).toEqual(["Background job com.jkrumm.a needs a fix", "Background job com.jkrumm.b needs a fix"])
    expect(filed[0].text).toContain(new Date(T0 + 5 * MIN).toISOString())
    expect(filed[0].text).toContain("factory was unreachable")
    expect(spoolOf(path)).toEqual([])
    expect(JSON.parse(readFileSync(path, "utf8"))["com.jkrumm.a"].filedAt).toBe(T0 + 20 * MIN)
    await reportJobs([a, b], path, deps(T0 + 25 * MIN))
    expect(filed).toHaveLength(2) // replayed once
  })
  test("after one refusal the factory is not tried again in the same run: a down factory costs one timeout, not one per alert", async () => {
    const path = stateFile()
    let calls = 0
    const deps = (now: number) => ({ now, file: async () => { calls++; return false }, ntfy: async () => {} })
    const rows = [row("com.jkrumm.a"), row("com.jkrumm.b"), row("com.jkrumm.c")]
    await reportJobs(rows, path, deps(T0))
    calls = 0
    await reportJobs(rows, path, deps(T0 + 5 * MIN))
    expect(calls).toBe(1)
    expect(spoolOf(path)).toHaveLength(3)
  })
  test("a line outage skips ntfy (it cannot get out) but still spools; the alert replays when the factory answers", async () => {
    const path = stateFile()
    const ntfy: string[] = []
    const filed: string[] = []
    let up = false
    const deps = (now: number, lineDown: boolean) => ({ now, lineDown, file: async (s: { title: string }) => { if (up) filed.push(s.title); return up }, ntfy: async (t: string) => { ntfy.push(t) } })
    await reportJobs([row("com.jkrumm.a")], path, deps(T0, true))
    expect(await reportJobs([row("com.jkrumm.a")], path, deps(T0 + 5 * MIN, true))).toBe("unchanged")
    expect(ntfy).toEqual([])
    expect(spoolOf(path)).toHaveLength(1)
    up = true
    await reportJobs([], path, deps(T0 + 10 * MIN, false))
    expect(filed).toEqual(["Background job com.jkrumm.a needs a fix"])
  })
  test("a group alert (undelivered push) is spooled and replayed the same way", async () => {
    const path = stateFile()
    const pushRow = (label: string): Graded => ({ ...row(label), grade: "undelivered", reason: "push target slow or down" })
    const filed: string[] = []
    let up = false
    const deps = (now: number) => ({ now, file: async (s: { title: string }) => { if (up) filed.push(s.title); return up }, ntfy: async () => {} })
    await reportJobs([pushRow("com.jkrumm.x")], path, deps(T0))
    await reportJobs([pushRow("com.jkrumm.x")], path, deps(T0 + 5 * MIN))
    expect(spoolOf(path).map((s) => s.entry.key)).toEqual(["push:Uptime Kuma"])
    up = true
    await reportJobs([], path, deps(T0 + 10 * MIN))
    expect(filed).toHaveLength(1)
  })
  test("expired and torn spool files are dropped, never replayed", async () => {
    const path = stateFile()
    const down = (now: number) => ({ now, file: async () => false, ntfy: async () => {} })
    await reportJobs([row("com.jkrumm.a")], path, down(T0))
    await reportJobs([row("com.jkrumm.a")], path, down(T0 + 5 * MIN))
    const dir = join(path, "..", "spool")
    writeFileSync(join(dir, "00000000000001-torn.json"), "{")
    const filed: string[] = []
    const later = T0 + 4 * 24 * 60 * MIN
    await reportJobs([], path, { now: later, file: async (s) => { filed.push(s.title); return true }, ntfy: async () => {} })
    expect(filed).toEqual([])
    expect(readSpool(dir, later)).toEqual([])
  })
})

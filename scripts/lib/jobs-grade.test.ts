import { describe, expect, test } from "bun:test"
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { type Expected, type Graded, type JobState, awakeSeconds, cronEvery, judgeAgainstAwake, gradeAll, gradeOne, parseJobrunArgs, readCronStates, readExpected, readRetired, renderTable, REPORT_AFTER_GRADES, REPORT_EVERY_MS, reportJobs, reportPlan, signalFor, summarize, windowSeconds } from "./jobs-grade.ts"

const NOW = Date.parse("2026-10-16T12:00:00Z")
const ago = (s: number) => new Date(NOW - s * 1000).toISOString()
const loaded = () => true

function job(p: Partial<JobState> = {}): JobState {
  return {
    label: "com.jkrumm.t", run_id: "r", started: ago(60), finished: ago(59), rc: 0, duration_ms: 1000,
    every: 300, owner: "dotfiles", owner_sha: null, last_ok: ago(59), consecutive_fail: 0, fails_24h: 0,
    fail_times: [], tail: [], runs: [], ...p,
  }
}
const grade = (p: Partial<JobState>, l: (x: string) => boolean = loaded) => gradeOne(job(p), { now: NOW, loaded: l }).grade

describe("jobs-grade", () => {
  test("healthy interval job is ok", () => expect(grade({})).toBe("ok"))
  test("unloaded wins over everything", () => expect(grade({ consecutive_fail: 9 }, () => false)).toBe("unloaded"))
  test("one or two failures are still ok (launchd retries next tick)", () => {
    expect(grade({ rc: 1, consecutive_fail: 2 })).toBe("ok")
  })
  test("3 consecutive failures = failing", () => expect(grade({ rc: 1, consecutive_fail: 3 })).toBe("failing"))
  test("window is max(3x every, 30 min)", () => {
    expect(windowSeconds(300)).toBe(1800)
    expect(windowSeconds(900)).toBe(2700)
    expect(windowSeconds(86400)).toBe(86400 + 7200)
  })
  test("interval job: failing last run and no success inside the window = failing", () => {
    expect(grade({ rc: 1, consecutive_fail: 1, started: ago(60), last_ok: ago(1801) })).toBe("failing")
    expect(grade({ rc: 1, consecutive_fail: 1, started: ago(60), last_ok: ago(1700) })).toBe("ok")
  })
  test("never succeeded + failing + no last_ok = failing", () => {
    expect(grade({ rc: 1, consecutive_fail: 1, last_ok: null })).toBe("failing")
  })
  test("no run inside the window = stale", () => {
    expect(grade({ started: ago(1801), last_ok: ago(1800) })).toBe("stale")
    expect(grade({ started: ago(1799), last_ok: ago(1799) })).toBe("ok")
  })
  test("daily job: 1 missed run + 2 h", () => {
    const d = { every: 86400 }
    expect(grade({ ...d, started: ago(86400 + 7199), last_ok: ago(86400 + 7199) })).toBe("ok")
    expect(grade({ ...d, started: ago(86400 + 7201), last_ok: ago(86400 + 7201) })).toBe("stale")
  })
  test("daily job: a failed run is failing at once, even when it also went stale", () => {
    expect(grade({ every: 86400, rc: 1, consecutive_fail: 1 })).toBe("failing")
    expect(grade({ every: 86400, rc: 1, consecutive_fail: 1, started: ago(3 * 86400) })).toBe("failing")
  })
  test("flapping: >= 3 failures in 24 h even when interleaved with successes", () => {
    expect(grade({ fails_24h: 3 })).toBe("flapping")
    expect(grade({ fails_24h: 2 })).toBe("ok")
  })
  test("flapping clears once the latest 3 runs are green; interleaved failures keep it", () => {
    const run = (rc: number, i: number) => ({ run_id: `r${i}`, started: ago(900 - i * 300), rc, duration_ms: 1 })
    expect(grade({ fails_24h: 12, runs: [0, 0, 0].map(run) })).toBe("ok")
    expect(grade({ fails_24h: 12, runs: [1, 0, 0].map(run) })).toBe("flapping")
    expect(grade({ fails_24h: 12, runs: [0, 1, 0, 0].map(run) })).toBe("flapping")
    expect(grade({ fails_24h: 12, runs: [0, 0].map(run) })).toBe("flapping")
  })
  test("failing outranks flapping; stale outranks flapping", () => {
    expect(grade({ fails_24h: 5, rc: 1, consecutive_fail: 3 })).toBe("failing")
    expect(grade({ fails_24h: 5, started: ago(9999) })).toBe("stale")
  })
  test("no cadence: only failure and loaded state are graded", () => {
    expect(grade({ every: null, started: ago(10 * 86400) })).toBe("ok")
    expect(grade({ every: null, rc: 1, consecutive_fail: 3 })).toBe("failing")
  })
  test("clock injection moves the verdict", () => {
    const s = job({ started: ago(100) })
    expect(gradeOne(s, { now: NOW, loaded }).grade).toBe("ok")
    expect(gradeOne(s, { now: NOW + 3600_000, loaded }).grade).toBe("stale")
  })
  test("never succeeded renders 'ever', not a giant number", () => {
    const g = gradeOne(job({ rc: 1, consecutive_fail: 1, last_ok: null }), { now: NOW, loaded })
    expect(g.reason).toContain("no success for ever")
  })
  test("a parseable file with missing numeric fields is surfaced, not graded ok", () => {
    const dir = mkdtempSync(join(tmpdir(), "jg-"))
    writeFileSync(join(dir, "c.json"), JSON.stringify({ label: "c", started: ago(1) }))
    expect(gradeAll(dir, { now: NOW, loaded })[0].grade).toBe("failing")
  })
  test("a state file missing owner/every/last_ok shape is corrupt, and renderTable survives it", () => {
    const dir = mkdtempSync(join(tmpdir(), "jg-"))
    const { owner: _o, ...noOwner } = job({ label: "x" })
    writeFileSync(join(dir, "x.json"), JSON.stringify(noOwner))
    writeFileSync(join(dir, "y.json"), JSON.stringify({ ...job({ label: "y" }), every: "300" }))
    writeFileSync(join(dir, "z.json"), JSON.stringify({ ...job({ label: "z" }), last_ok: "garbage" }))
    const rows = gradeAll(dir, { now: NOW, loaded })
    expect(rows.map((r) => r.grade)).toEqual(["failing", "failing", "failing"])
    expect(() => renderTable(rows)).not.toThrow()
  })
  test("a graded row carries owner_sha, the last runs and the output tail (the job brief quotes them)", () => {
    const runs = [{ run_id: "r1", started: ago(60), rc: 1, duration_ms: 5 }]
    const row = gradeOne(job({ rc: 1, consecutive_fail: 3, owner_sha: "abc123", runs, tail: ["boom"] }), { now: NOW, loaded })
    expect([row.owner_sha, row.runs, row.tail]).toEqual(["abc123", runs, ["boom"]])
  })
  test("summarize relays one verdict: exit 0 all ok, 2 otherwise", () => {
    const ok = gradeOne(job(), { now: NOW, loaded })
    const bad = gradeOne(job({ label: "b", rc: 1, consecutive_fail: 3 }), { now: NOW, loaded })
    expect(summarize([])).toEqual({ line: "jobs ok (0)", code: 0 })
    expect(summarize([ok])).toEqual({ line: "jobs ok (1)", code: 0 })
    expect(summarize([ok, bad])).toEqual({ line: "jobs WARN (2): b=failing", code: 2 })
  })
  test("an older state file without runs and fails_24h >= 3 grades flapping instead of throwing", () => {
    const { runs: _runs, ...old } = job({ fails_24h: 3 })
    const g = gradeOne(old as JobState, { now: NOW, loaded })
    expect(g.grade).toBe("flapping")
  })
  test("gradeAll reads the state dir, skipping torn files", () => {
    const dir = mkdtempSync(join(tmpdir(), "jg-"))
    writeFileSync(join(dir, "a.json"), JSON.stringify(job({ label: "a" })))
    writeFileSync(join(dir, "b.json"), "{torn")
    writeFileSync(join(dir, "note.txt"), "x")
    const rows = gradeAll(dir, { now: NOW, loaded })
    expect(rows.map((r) => [r.label, r.grade])).toEqual([["a", "ok"], ["b", "failing"]])
    expect(rows[1].reason).toContain("unreadable")
    expect(renderTable(rows)).toContain("ok")
    expect(gradeAll(join(dir, "missing"), { now: NOW, loaded })).toEqual([])
    expect(renderTable([])).toBe("no jobs recorded")
  })
})

describe("expected set (never-recorded gap)", () => {
  const exp = (p: Partial<Expected> = {}): Expected => ({ label: "com.jkrumm.new", owner: "dotfiles", every: 300, installedAt: NOW - 60_000, ...p })
  const run = (e: Expected, l: (x: string) => boolean = loaded) => gradeAll(mkdtempSync(join(tmpdir(), "jg-")), { now: NOW, loaded: l, expected: [e] })[0]

  test("parseJobrunArgs reads label, owner and every; ignores non-jobrun plists", () => {
    const a = ["/Users/x/.local/bin/jobrun", "com.jkrumm.t", "--owner", "dotfiles", "--every", "300", "--", "/bin/true"]
    expect(parseJobrunArgs(a)).toEqual({ label: "com.jkrumm.t", owner: "dotfiles", every: 300 })
    expect(parseJobrunArgs(["/bin/bash", "x.sh"])).toBeNull()
    expect(parseJobrunArgs(["jobrun", "--owner", "x", "--", "y"])).toBeNull()
    expect(parseJobrunArgs(["jobrun", "l", "--", "y", "--every", "5"])?.every).toBeNull() // after `--` is the command's
  })
  test("a declared job with no state file is never invisible", () => {
    expect(run(exp({ installedAt: NOW - 1801_000 })).grade).toBe("stale")
    expect(run(exp({ installedAt: NOW - 1801_000 }), () => false).grade).toBe("unloaded")
  })
  test("inside its first window a not-yet-run job is ok (fresh install, daily job)", () => {
    expect(run(exp()).grade).toBe("ok")
    expect(run(exp({ every: 86400, installedAt: NOW - 3600_000 })).grade).toBe("ok")
    expect(run(exp({ every: 86400, installedAt: NOW - (86400 + 7201) * 1000 })).grade).toBe("stale")
  })
  test("one label declared twice is one row", () => {
    expect(gradeAll(mkdtempSync(join(tmpdir(), "jg-")), { now: NOW, loaded, expected: [exp(), exp()] })).toHaveLength(1)
  })
  test("a state file wins over the declaration; no duplicate row", () => {
    const dir = mkdtempSync(join(tmpdir(), "jg-"))
    writeFileSync(join(dir, "com.jkrumm.new.json"), JSON.stringify(job({ label: "com.jkrumm.new" })))
    const rows = gradeAll(dir, { now: NOW, loaded, expected: [exp()] })
    expect(rows.map((r) => [r.label, r.grade])).toEqual([["com.jkrumm.new", "ok"]])
  })
  test("readExpected derives the set from real plists", () => {
    const dir = mkdtempSync(join(tmpdir(), "jp-"))
    const plist = (label: string, args: string[]) =>
      `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>${label}</string><key>ProgramArguments</key><array>${args.map((a) => `<string>${a}</string>`).join("")}</array></dict></plist>`
    writeFileSync(join(dir, "a.plist"), plist("a", ["/h/.local/bin/jobrun", "a", "--owner", "dotfiles", "--every", "600", "--", "/bin/true"]))
    writeFileSync(join(dir, "b.plist"), plist("b", ["/bin/true"]))
    writeFileSync(join(dir, "c.plist"), "not a plist")
    expect(readExpected(dir).map((e) => [e.label, e.owner, e.every])).toEqual([["a", "dotfiles", 600]])
    expect(readExpected(join(dir, "missing"))).toEqual([])
  })
})

describe("on-demand jobs (no plist, no cadence)", () => {
  const onDemand = (p: Partial<JobState> = {}) => job({ label: "com.jkrumm.iris-release-mac", every: null, started: ago(10 * 86400), last_ok: ago(10 * 86400), ...p })
  const never = () => false
  const gradeD = (s: JobState, expected: Expected[] = []) => gradeOne(s, { now: NOW, loaded: never, expected })

  test("a successful on-demand run grades ok even though launchd does not know it", () => {
    expect(gradeD(onDemand()).grade).toBe("ok")
  })
  test("a failed on-demand run grades failing with the rc at once, however old", () => {
    const g = gradeD(onDemand({ rc: 2, consecutive_fail: 1 }))
    expect(g.grade).toBe("failing")
    expect(g.reason).toContain("rc=2")
  })
  test("a plist-declared label that is not loaded stays unloaded", () => {
    const e: Expected = { label: "com.jkrumm.iris-release-mac", owner: "iris", every: null, installedAt: NOW }
    expect(gradeD(onDemand(), [e]).grade).toBe("unloaded")
  })
  test("a state file with a cadence but no plist stays unloaded; so does a caller that gives no plist scan", () => {
    expect(gradeD(onDemand({ every: 300 })).grade).toBe("unloaded")
    expect(gradeOne(onDemand(), { now: NOW, loaded: never }).grade).toBe("unloaded")
  })
  test("gradeAll: on-demand rows next to a plist job", () => {
    const dir = mkdtempSync(join(tmpdir(), "jg-"))
    writeFileSync(join(dir, "com.jkrumm.iris-release-mac.json"), JSON.stringify(onDemand({ rc: 2, consecutive_fail: 1 })))
    writeFileSync(join(dir, "com.jkrumm.iris-probe.json"), JSON.stringify(onDemand({ label: "com.jkrumm.iris-probe" })))
    const rows = gradeAll(dir, { now: NOW, loaded: never, expected: [] })
    expect(rows.map((r) => [r.label, r.grade])).toEqual([["com.jkrumm.iris-probe", "ok"], ["com.jkrumm.iris-release-mac", "failing"]])
  })
})

describe("hermes cron adapter", () => {
  const write = (jobs: unknown) => {
    const p = join(mkdtempSync(join(tmpdir(), "cron-")), "jobs.json")
    writeFileSync(p, typeof jobs === "string" ? jobs : JSON.stringify({ jobs }))
    return p
  }
  const cron = (over: Record<string, unknown> = {}) => ({
    id: "abc", name: "Brain drift audit", enabled: true, schedule_display: "0 9 * * 6", last_status: "ok",
    last_run_at: ago(3600), last_error: null, ...over,
  })
  const none = join(tmpdir(), "no-such-state-dir")

  test("cronEvery: longest gap of a fixed-time expression, null for anything else", () => {
    expect(cronEvery("30 6 * * *")).toBe(86400)
    expect(cronEvery("0 9 * * 6")).toBe(7 * 86400)
    expect(cronEvery("0 7 * * 1-5")).toBe(3 * 86400) // Friday -> Monday
    expect(cronEvery("0 22 * * 1-4")).toBe(4 * 86400)
    expect(cronEvery("0 9 * * 0,7")).toBe(7 * 86400)
    expect(cronEvery("*/5 * * * *")).toBeNull()
    expect(cronEvery("0 9 1 * *")).toBeNull()
    expect(cronEvery(undefined)).toBeNull()
  })

  test("an ok job is ok, a failed one is failing with its error as the tail", () => {
    const failed = cron({ id: "z", name: "Evening report", last_status: "error", last_error: "HTTP 404" })
    const rows = gradeAll(none, { now: NOW, loaded, cron: readCronStates(write([cron(), failed])) })
    expect(rows.map((r) => [r.label, r.grade, r.owner])).toEqual([
      ["hermes-cron.brain-drift-audit", "ok", "hermes-agent"],
      ["hermes-cron.evening-report", "failing", "hermes-agent"],
    ])
    expect(rows[1].tail?.[0]).toContain("HTTP 404")
  })

  test("a cron job is loaded exactly when the gateway is", () => {
    const seen: string[] = []
    const rows = gradeAll(none, { now: NOW, cron: readCronStates(write([cron()])), loaded: (l) => (seen.push(l), l !== "ai.hermes.gateway") })
    expect(seen).toEqual(["ai.hermes.gateway"])
    expect(rows[0].grade).toBe("unloaded")
  })

  test("a missed scheduled run is stale", () => {
    const rows = gradeAll(none, { now: NOW, loaded, cron: readCronStates(write([cron({ schedule_display: "30 6 * * *", last_run_at: ago(30 * 3600) })])) })
    expect(rows[0].grade).toBe("stale")
  })

  test("disabled and never-run jobs are skipped; a missing file is no jobs; a corrupt one fails visibly", () => {
    expect(readCronStates(write([cron({ enabled: false }), cron({ last_run_at: null, last_status: null })]))).toEqual([])
    expect(readCronStates(join(tmpdir(), "nope.json"))).toEqual([])
    const bad = gradeAll(none, { now: NOW, loaded, cron: readCronStates(write("{not json")) })
    expect(bad[0].grade).toBe("failing")
  })

  test("a failure on a schedule we cannot read still grades failing", () => {
    for (const schedule_display of ["every 2h", "*/5 * * * *", "0 9 1 * *"]) {
      const rows = gradeAll(none, { now: NOW, loaded, cron: readCronStates(write([cron({ schedule_display, last_status: "error" })]), NOW) })
      expect(rows[0].grade).toBe("failing")
    }
  })

  test("registry shape drift and bad entries are visible rows, never a throw or a silent gap", () => {
    for (const body of ['{"jobs":{}}', "{}", "[]", "null"]) {
      expect(gradeAll(none, { now: NOW, loaded, cron: readCronStates(write(body)) })[0].grade).toBe("failing")
    }
    const rows = gradeAll(none, { now: NOW, loaded, cron: readCronStates(write([null, 7, "x", cron()])) })
    expect(rows.filter((r) => r.grade === "failing")).toHaveLength(3)
    expect(rows.some((r) => r.label === "hermes-cron.brain-drift-audit" && r.grade === "ok")).toBe(true)
  })

  test("two names that slug alike are two jobs, and fails_24h follows the injected clock", () => {
    const rows = readCronStates(write([cron({ id: "a", last_status: "error" }), cron({ id: "b", last_status: "error" })]), NOW)
    expect(new Set(rows.map((r) => r.label)).size).toBe(2)
    expect(rows[0].fails_24h).toBe(1)
    expect(readCronStates(write([cron({ last_status: "error", last_run_at: ago(2 * 86400) })]), NOW)[0].fails_24h).toBe(0)
  })
})

describe("--notify: staleness against awake time", () => {
  const stale = gradeOne(job({ started: ago(7200), last_ok: ago(7200), finished: ago(7199), every: 300 }), { now: NOW, loaded })
  const failing = gradeOne(job({ rc: 1, consecutive_fail: 3 }), { now: NOW, loaded })

  test("parses sysctl kern.waketime", () => {
    expect(awakeSeconds("{ sec = 1760616000, usec = 123 } Fri Oct 16 12:00:00 2026", 1760616600_000)).toBe(600)
    expect(awakeSeconds("garbage", NOW)).toBeNull()
  })
  test("stale is dropped while awake for less than its window, kept after", () => {
    expect(stale.grade).toBe("stale")
    expect(judgeAgainstAwake([stale], 60)).toEqual([])
    expect(judgeAgainstAwake([stale], windowSeconds(300))).toEqual([stale])
  })
  test("failing is never dropped, an unreadable wake time drops nothing", () => {
    expect(judgeAgainstAwake([failing], 0)).toEqual([failing])
    expect(judgeAgainstAwake([stale], null)).toEqual([stale])
  })
})

describe("--report: signals to the factory, not ntfy", () => {
  const row = (label: string, g: Graded["grade"], reason = "r", owner = "dotfiles"): Graded => ({ ...gradeOne(job({ label, owner }), { now: NOW, loaded }), grade: g, reason })
  const T0 = NOW
  const MIN = 60_000

  test("a job not ok for one grade is not reported yet", () => {
    const { due, next } = reportPlan({}, [row("a", "failing")], T0)
    expect(due).toEqual([])
    expect(next.a.bad).toBe(1)
  })
  test(`a job not ok for ${REPORT_AFTER_GRADES} consecutive grades is due`, () => {
    const one = reportPlan({}, [row("a", "failing")], T0)
    const two = reportPlan(one.next, [row("a", "failing")], T0 + 5 * MIN)
    expect(two.due.map((r) => r.label)).toEqual(["a"])
  })
  test("an ok grade in between resets the streak", () => {
    const one = reportPlan({}, [row("a", "failing")], T0)
    const ok = reportPlan(one.next, [row("a", "ok")], T0 + 5 * MIN)
    expect(ok.next.a ?? { bad: 0 }).toMatchObject({ bad: 0 })
    expect(reportPlan(ok.next, [row("a", "failing")], T0 + 10 * MIN).due).toEqual([])
  })
  test("a reported job is not due again inside a day, then amends", () => {
    const prev = { a: { bad: 50, filedAt: T0, ntfyAt: null } }
    expect(reportPlan(prev, [row("a", "failing")], T0 + 3600_000).due).toEqual([])
    expect(reportPlan(prev, [row("a", "failing")], T0 + REPORT_EVERY_MS + 1).due.map((r) => r.label)).toEqual(["a"])
  })
  test("a flapping job costs at most one report a day, however often it flaps", () => {
    let state = {} as ReturnType<typeof reportPlan>["next"]
    let reports = 0
    for (let i = 0; i < 288; i++) { // 24 h of 5-min grades, alternating flapping / ok
      const plan = reportPlan(state, [row("f", i % 4 < 2 ? "flapping" : "ok")], T0 + i * 5 * MIN)
      state = plan.next
      for (const r of plan.due) { state[r.label].filedAt = T0 + i * 5 * MIN; reports++ }
    }
    expect(reports).toBe(1)
  })
  test("recovery keeps its stamps for a day (a relapse is not a second signal) then forgets the job", () => {
    const prev = { a: { bad: 4, filedAt: T0, ntfyAt: null } }
    expect(reportPlan(prev, [row("a", "ok")], T0 + MIN).next.a?.filedAt).toBe(T0)
    expect(reportPlan(prev, [row("a", "ok")], T0 + 3 * REPORT_EVERY_MS).next.a).toBeUndefined()
  })
  test("the signal is addressed to the owner repo with one stable title per job", () => {
    const a = signalFor(row("com.jkrumm.t", "failing", "3 consecutive failures (rc=124)", "dotfiles"))
    const b = signalFor(row("com.jkrumm.t", "stale", "last run 90 min ago", "dotfiles"))
    expect(a.repo).toBe("dotfiles")
    expect(a.title).toBe(b.title)
    expect(a.title).toContain("com.jkrumm.t")
    expect(a.text).toContain("rc=124")
    expect(signalFor(row("x", "failing", "r", "?")).repo).toBe("dotfiles")
    expect(signalFor(row("hermes-cron.x", "failing", "r", "hermes-agent")).repo).toBe("hermes-agent")
  })

  const bad = [row("com.jkrumm.t", "failing", "3 consecutive failures")]
  function tmpState() { return join(mkdtempSync(join(tmpdir(), "report-")), "sub/report.json") }

  test("factory reachable: a signal is filed after 2 grades and ntfy is NEVER posted", async () => {
    const state = tmpState()
    const filed: { repo: string; title: string }[] = []
    let ntfyCalls = 0
    const deps = (now: number) => ({ now, file: async (s: { repo: string; title: string; text: string }) => { filed.push(s); return true }, ntfy: async () => { ntfyCalls++ } })
    expect(await reportJobs(bad, state, deps(T0))).toBe("unchanged")
    expect(filed).toEqual([])
    expect(await reportJobs(bad, state, deps(T0 + 5 * MIN))).toBe("ok")
    expect(filed.map((s) => `${s.repo}:${s.title}`)).toEqual(["dotfiles:Background job com.jkrumm.t needs a fix"])
    expect(await reportJobs(bad, state, deps(T0 + 10 * MIN))).toBe("unchanged")
    expect(filed).toHaveLength(1)
    expect(ntfyCalls).toBe(0)
    expect(JSON.parse(readFileSync(state, "utf8"))["com.jkrumm.t"].filedAt).toBe(T0 + 5 * MIN)
  })
  test("factory unreachable: ntfy fallback once, retried against the factory next tick, ntfy not repeated within a day", async () => {
    const state = tmpState()
    const ntfy: string[] = []
    let up = false
    const deps = (now: number) => ({ now, file: async () => up, ntfy: async (t: string) => { ntfy.push(t) } })
    await reportJobs(bad, state, deps(T0))
    expect(await reportJobs(bad, state, deps(T0 + 5 * MIN))).toBe("ok")
    expect(ntfy).toHaveLength(1)
    expect(ntfy[0]).toContain("com.jkrumm.t=failing")
    expect(ntfy[0]).toContain("factory unreachable")
    expect(await reportJobs(bad, state, deps(T0 + 10 * MIN))).toBe("unchanged")
    expect(ntfy).toHaveLength(1)
    up = true // the factory comes back: the signal lands, still no second ntfy
    expect(await reportJobs(bad, state, deps(T0 + 15 * MIN))).toBe("ok")
    expect(ntfy).toHaveLength(1)
    expect(JSON.parse(readFileSync(state, "utf8"))["com.jkrumm.t"].filedAt).toBe(T0 + 15 * MIN)
  })
  test("factory and ntfy both down: failed, and the job is retried next tick", async () => {
    const state = tmpState()
    const deps = (now: number) => ({ now, file: async () => false, ntfy: async () => { throw new Error("http 403") } })
    await reportJobs(bad, state, deps(T0))
    expect(await reportJobs(bad, state, deps(T0 + 5 * MIN))).toBe("failed")
    const stamp = JSON.parse(readFileSync(state, "utf8"))["com.jkrumm.t"]
    expect(stamp.filedAt).toBeNull()
    expect(stamp.ntfyAt).toBeNull()
    expect(await reportJobs(bad, state, deps(T0 + 10 * MIN))).toBe("failed")
  })
  test("a stale row judged against a short awake time is not reported", async () => {
    const stale = gradeOne(job({ label: "com.jkrumm.slept", started: ago(7200), last_ok: ago(7200), finished: ago(7199), every: 300 }), { now: NOW, loaded })
    expect(stale.grade).toBe("stale")
    const state = tmpState()
    const filed: string[] = []
    const deps = (now: number) => ({ now, file: async (s: { title: string }) => { filed.push(s.title); return true }, ntfy: async () => {} })
    const rows = judgeAgainstAwake([stale, ...bad], 60)
    await reportJobs(rows, state, deps(T0))
    await reportJobs(rows, state, deps(T0 + 5 * MIN))
    expect(filed).toEqual(["Background job com.jkrumm.t needs a fix"])
  })
  test("the real factory binary path: a stub `factory` receives the signal flags", async () => {
    const dir = mkdtempSync(join(tmpdir(), "factory-stub-"))
    const log = join(dir, "args.log")
    const bin = join(dir, "factory")
    writeFileSync(bin, `#!/bin/sh\nprintf '%s\\n' "$@" > "${log}"\nexit ${"${STUB_RC:-0}"}\n`, { mode: 0o755 })
    const saved = { ...process.env }
    process.env.JOBS_GRADE_FACTORY_BIN = bin
    try {
      const state = tmpState()
      await reportJobs(bad, state, { now: T0, ntfy: async () => { throw new Error("must not be called") } })
      expect(await reportJobs(bad, state, { now: T0 + 5 * MIN, ntfy: async () => { throw new Error("must not be called") } })).toBe("ok")
      const args = readFileSync(log, "utf8").split("\n")
      expect(args.slice(0, 7)).toEqual(["signal", "file", "--from", "agent:dotfiles", "--repo", "dotfiles", "--title"])
      expect(args[7]).toBe("Background job com.jkrumm.t needs a fix")
    } finally {
      process.env = saved
    }
  })
})

describe("retired jobs (stopped on purpose)", () => {
  const never = () => false
  const retired = new Map([["com.jkrumm.t", "V1 frozen"]])

  test("readRetired maps each <label>.retired marker to its text; state files and a missing dir are ignored", () => {
    const dir = mkdtempSync(join(tmpdir(), "jg-"))
    writeFileSync(join(dir, "com.jkrumm.t.retired"), "V1 frozen\n")
    writeFileSync(join(dir, "com.jkrumm.empty.retired"), "")
    writeFileSync(join(dir, "com.jkrumm.live.json"), "{}")
    expect(readRetired(dir)).toEqual(new Map([["com.jkrumm.empty", ""], ["com.jkrumm.t", "V1 frozen"]]))
    expect(readRetired(join(dir, "missing"))).toEqual(new Map())
  })
  test("a marked job that is not loaded grades retired, with the reason", () => {
    const g = gradeOne(job({ consecutive_fail: 9 }), { now: NOW, loaded: never, retired })
    expect(g.grade).toBe("retired")
    expect(g.reason).toContain("V1 frozen")
  })
  test("a marked job that is loaded again grades normally", () => {
    expect(gradeOne(job({ consecutive_fail: 9 }), { now: NOW, loaded, retired }).grade).toBe("failing")
  })
  test("an unmarked job that is not loaded stays unloaded", () => {
    expect(gradeOne(job({ label: "com.jkrumm.other" }), { now: NOW, loaded: never, retired }).grade).toBe("unloaded")
  })
  test("a marked plist-declared job with no state file grades retired", () => {
    const e: Expected = { label: "com.jkrumm.t", owner: "weatherorb", every: 300, installedAt: NOW - 3600_000 }
    const rows = gradeAll(mkdtempSync(join(tmpdir(), "jg-")), { now: NOW, loaded: never, expected: [e], retired })
    expect(rows.map((r) => r.grade)).toEqual(["retired"])
  })
  test("retired is not a warning and is never reported", () => {
    const rows = gradeAll(mkdtempSync(join(tmpdir(), "jg-")), { now: NOW, loaded: never, expected: [{ label: "com.jkrumm.t", owner: "weatherorb", every: 300, installedAt: NOW }], retired })
    expect(summarize(rows)).toEqual({ line: "jobs ok (1)", code: 0 })
    let state = {} as ReturnType<typeof reportPlan>["next"]
    for (let i = 0; i < 5; i++) {
      const plan = reportPlan(state, rows, NOW + i * 300_000)
      expect(plan.due).toEqual([])
      state = plan.next
    }
  })
})

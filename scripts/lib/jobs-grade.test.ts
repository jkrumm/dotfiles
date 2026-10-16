import { describe, expect, test } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { type JobState, gradeAll, gradeOne, renderTable, summarize, windowSeconds } from "./jobs-grade.ts"

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
  test("summarize relays one verdict: exit 0 all ok, 2 otherwise", () => {
    const ok = gradeOne(job(), { now: NOW, loaded })
    const bad = gradeOne(job({ label: "b", rc: 1, consecutive_fail: 3 }), { now: NOW, loaded })
    expect(summarize([])).toEqual({ line: "jobs ok (0)", code: 0 })
    expect(summarize([ok])).toEqual({ line: "jobs ok (1)", code: 0 })
    expect(summarize([ok, bad])).toEqual({ line: "jobs WARN (2): b=failing", code: 2 })
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

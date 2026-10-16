import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { type JobState, gradeAll } from "./lib/jobs-grade.ts"
import { acquireLock, nextState, parseArgs, writeAtomic } from "./jobrun.ts"

const SCRIPT = join(import.meta.dir, "jobrun.ts")
let dir: string

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), "jobrun-"))
})
afterAll(() => rmSync(dir, { recursive: true, force: true }))

function jobrun(args: string[], env: Record<string, string> = {}) {
  const r = Bun.spawnSync(["bun", SCRIPT, ...args], {
    env: { ...process.env, JOBRUN_STATE_DIR: dir, JOBRUN_SOURCEROOT: join(dir, "src"), ...env },
    stdout: "pipe", stderr: "pipe",
  })
  return { rc: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() }
}
async function jobrunAsync(args: string[], env: Record<string, string> = {}) {
  const p = Bun.spawn(["bun", SCRIPT, ...args], { env: { ...process.env, JOBRUN_STATE_DIR: dir, JOBRUN_SOURCEROOT: join(dir, "src"), ...env }, stdout: "ignore", stderr: "ignore" })
  return { rc: await p.exited }
}
const state = (label: string) => JSON.parse(readFileSync(join(dir, `${label}.json`), "utf8")) as JobState

describe("parseArgs", () => {
  test("full form", () => {
    const a = parseArgs(["l", "--owner", "dotfiles", "--every", "300", "--timeout", "20", "--lock", "x", "--kuma", "op://a/b/c", "--", "echo", "hi"])
    expect(a).toEqual({ label: "l", owner: "dotfiles", every: 300, timeout: 20, lock: "x", kuma: "op://a/b/c", cmd: ["echo", "hi"] })
  })
  test("rejects missing owner, missing command, bad label, bad number", () => {
    expect(() => parseArgs(["l", "--", "true"])).toThrow(/owner/)
    expect(() => parseArgs(["l", "--owner", "d"])).toThrow(/usage/)
    expect(() => parseArgs(["a/b", "--owner", "d", "--", "true"])).toThrow(/label/)
    expect(() => parseArgs(["l", "--owner", "d", "--every", "0", "--", "true"])).toThrow(/positive/)
    expect(() => parseArgs(["l", "--owner", "d", "--evry", "5", "--", "true"])).toThrow(/unknown option/)
    expect(() => parseArgs(["l", "--owner", "../x", "--", "true"])).toThrow(/bad owner/)
  })
})

describe("state + atomic write", () => {
  test("writeAtomic leaves no tmp file and replaces content", () => {
    const p = join(dir, "atomic", "x.json")
    writeAtomic(p, "1")
    writeAtomic(p, "2")
    expect(readFileSync(p, "utf8")).toBe("2")
    expect(Array.from(new Bun.Glob("*.tmp").scanSync(join(dir, "atomic")))).toEqual([])
  })
  test("nextState counters: fail, fail, ok resets; last_ok survives failures", () => {
    const a = { label: "c", owner: "o", every: 60, timeout: null, lock: null, kuma: null, cmd: ["x"] }
    const t0 = Date.parse("2026-10-16T10:00:00Z")
    const run = (rc: number, at: number) => ({ run_id: `r${at}`, started: at, finished: at + 1000, rc, tail: [], sha: null })
    const s1 = nextState(null, a, run(0, t0))
    const s2 = nextState(s1, a, run(1, t0 + 60_000))
    const s3 = nextState(s2, a, run(1, t0 + 120_000))
    expect([s2.consecutive_fail, s3.consecutive_fail, s3.fails_24h]).toEqual([1, 2, 2])
    expect(s3.last_ok).toBe(s1.last_ok)
    const s4 = nextState(s3, a, run(0, t0 + 180_000))
    expect([s4.consecutive_fail, s4.fails_24h]).toEqual([0, 2])
  })
  test("an interrupted run (jobrun told to stop) is not counted as a failure", () => {
    const a = { label: "c", owner: "o", every: 60, timeout: null, lock: null, kuma: null, cmd: ["x"] }
    const t0 = Date.parse("2026-10-16T10:00:00Z")
    const ok = nextState(null, a, { run_id: "a", started: t0, finished: t0 + 1, rc: 0, tail: [], sha: null })
    const intr = nextState(ok, a, { run_id: "b", started: t0 + 100, finished: t0 + 200, rc: 143, tail: [], sha: null, interrupted: true })
    expect([intr.consecutive_fail, intr.fails_24h, intr.rc, intr.last_ok]).toEqual([0, 0, 143, ok.last_ok])
  })
  test("fail_times older than 24 h age out; runs keeps the last 5", () => {
    const a = { label: "c", owner: "o", every: 60, timeout: null, lock: null, kuma: null, cmd: ["x"] }
    let s: JobState | null = null
    const t0 = Date.parse("2026-10-16T00:00:00Z")
    for (let i = 0; i < 7; i++) s = nextState(s, a, { run_id: `r${i}`, started: t0 + i * 1000, finished: t0 + i * 1000 + 1, rc: 1, tail: [], sha: null })
    expect(s?.runs.length).toBe(5)
    const later = nextState(s, a, { run_id: "z", started: t0 + 2 * 86_400_000, finished: t0 + 2 * 86_400_000 + 1, rc: 0, tail: [], sha: null })
    expect(later.fails_24h).toBe(0)
  })
})

describe("lock", () => {
  const holder = (name: string, info: object) => {
    mkdirSync(join(dir, "locks", name), { recursive: true })
    writeFileSync(join(dir, "locks", name, "holder.json"), JSON.stringify(info))
  }
  test("second holder is refused, release frees it", () => {
    const rel = acquireLock(dir, "l1")
    expect(rel).not.toBeNull()
    expect(acquireLock(dir, "l1")).toBeNull()
    rel?.()
    const again = acquireLock(dir, "l1")
    expect(again).not.toBeNull()
    again?.()
  })
  test("a dead holder is stolen", () => {
    holder("dead", { pid: 999999, lstart: "x" })
    const stolen = acquireLock(dir, "dead")
    expect(stolen).not.toBeNull()
    stolen?.()
  })
  test("pid reuse: live pid with a different start time is stale", () => {
    holder("reused", { pid: process.pid, lstart: "Thu Jan  1 00:00:00 1970" })
    const stolen = acquireLock(dir, "reused")
    expect(stolen).not.toBeNull()
    stolen?.()
  })
  test("debris without holder.json is stale", () => {
    mkdirSync(join(dir, "locks", "debris"), { recursive: true })
    const stolen = acquireLock(dir, "debris")
    expect(stolen).not.toBeNull()
    stolen?.()
  })
  test("a stolen-then-released lock is not removed by the previous owner", () => {
    const first = acquireLock(dir, "own")
    holder("own", { pid: 999999, lstart: "x" }) // someone else's record now sits there
    first?.()
    expect(existsSync(join(dir, "locks", "own"))).toBe(true)
    rmSync(join(dir, "locks", "own"), { recursive: true })
  })
  test("unknown start time is held, never stolen", () => {
    holder("unknown", { pid: process.pid, lstart: null })
    expect(acquireLock(dir, "unknown")).toBeNull()
    rmSync(join(dir, "locks", "unknown"), { recursive: true })
  })
  test("bad lock names are rejected (no path escape)", () => {
    for (const n of ["../x", "a/b", "..", ".", "/etc"]) expect(() => acquireLock(dir, n)).toThrow(/bad lock name/)
  })
  test("an unwritable state dir throws instead of reading as 'held'", () => {
    const ro = mkdtempSync(join(tmpdir(), "jobrun-ro-"))
    mkdirSync(join(ro, "locks"))
    chmodSync(join(ro, "locks"), 0o500)
    try {
      expect(() => acquireLock(ro, "x")).toThrow()
    } finally {
      chmodSync(join(ro, "locks"), 0o700)
    }
  })
})

describe("jobrun end to end", () => {
  test("success: timestamps every line, writes state, rc 0", () => {
    const r = jobrun(["ok", "--owner", "dotfiles", "--every", "300", "--", "sh", "-c", "echo hello; echo oops >&2"])
    expect(r.rc).toBe(0)
    expect(r.out).toMatch(/^\d{4}-\d\d-\d\dT[\d:.]+Z hello$/m)
    expect(r.out).toMatch(/Z oops$/m)
    const s = state("ok")
    expect([s.rc, s.consecutive_fail, s.owner, s.every]).toEqual([0, 0, "dotfiles", 300])
    expect(s.last_ok).not.toBeNull()
    expect(s.tail).toEqual(expect.arrayContaining([expect.stringContaining("hello")]))
  })
  test("failure rc propagates and counts", () => {
    jobrun(["bad", "--owner", "o", "--", "sh", "-c", "exit 3"])
    const r = jobrun(["bad", "--owner", "o", "--", "sh", "-c", "exit 3"])
    expect(r.rc).toBe(3)
    expect(state("bad").consecutive_fail).toBe(2)
  })
  test("tail keeps only the last 40 lines", () => {
    jobrun(["long", "--owner", "o", "--", "sh", "-c", "i=0; while [ $i -lt 100 ]; do echo l$i; i=$((i+1)); done"])
    const s = state("long")
    expect(s.tail.length).toBe(40)
    expect(s.tail[39]).toContain("l99")
  })
  test("deadline: TERM kills the whole group, rc 124, state recorded", () => {
    const t = Date.now()
    const r = jobrun(["slow", "--owner", "o", "--timeout", "1", "--", "sh", "-c", "sleep 30 & sleep 30"])
    expect(r.rc).toBe(124)
    expect(Date.now() - t).toBeLessThan(8000)
    expect(state("slow").rc).toBe(124)
  })
  test("deadline escalates to KILL when TERM is ignored", () => {
    const t = Date.now()
    const r = jobrun(["stubborn", "--owner", "o", "--timeout", "1", "--", "sh", "-c", "trap '' TERM; while :; do sleep 1; done"])
    expect(r.rc).toBe(124)
    expect(Date.now() - t).toBeLessThan(20000)
  }, 30000)
  test("lock held by a live process: skip with rc 0 and no state", () => {
    const rel = acquireLock(dir, "shared")
    const r = jobrun(["locked", "--owner", "o", "--lock", "shared", "--", "true"])
    rel?.()
    expect(r.rc).toBe(0)
    expect(r.out).toContain("held")
    expect(existsSync(join(dir, "locked.json"))).toBe(false)
  })
  test("a grandchild holding the pipes open does not block the finish", () => {
    const t = Date.now()
    const r = jobrun(["gc", "--owner", "o", "--", "sh", "-c", "sleep 30 & echo started"])
    expect(r.rc).toBe(0)
    expect(Date.now() - t).toBeLessThan(10000)
    expect(state("gc").rc).toBe(0)
  }, 15000)
  test("unknown command: rc 127, recorded as a failure", () => {
    const r = jobrun(["nocmd", "--owner", "o", "--", "/nonexistent/binary"])
    expect(r.rc).toBe(127)
    expect(state("nocmd").rc).toBe(127)
  })
  test("usage errors exit 64 and write nothing", () => {
    expect(jobrun(["x", "--", "true"]).rc).toBe(64)
  })
  test("--kuma pushes only on success, URL via secrets-run (fake)", async () => {
    const hits: string[] = []
    const srv = Bun.serve({ port: 0, fetch: (req) => (hits.push(new URL(req.url).search), new Response("ok")) })
    const fake = join(dir, "fake-secrets-run")
    writeFileSync(fake, `#!/bin/sh\n[ "$1" = read ] && echo "http://127.0.0.1:${srv.port}/api/push/tok"\n`)
    chmodSync(fake, 0o755)
    const env = { JOBRUN_SECRETS_RUN: fake }
    try {
      expect((await jobrunAsync(["kok", "--owner", "o", "--kuma", "op://v/i/f", "--", "true"], env)).rc).toBe(0)
      expect(hits.length).toBe(1)
      expect(hits[0]).toContain("status=up")
      expect((await jobrunAsync(["kfail", "--owner", "o", "--kuma", "op://v/i/f", "--", "false"], env)).rc).toBe(1)
      expect(hits.length).toBe(1)
    } finally {
      srv.stop(true)
    }
  })
  test("--kuma with an unresolvable ref fails loudly but still records the run", () => {
    const fake = join(dir, "broken-secrets-run")
    writeFileSync(fake, "#!/bin/sh\nexit 1\n")
    chmodSync(fake, 0o755)
    const r = jobrun(["knoref", "--owner", "o", "--kuma", "op://v/i/f", "--", "true"], { JOBRUN_SECRETS_RUN: fake })
    expect(r.rc).toBe(1)
    expect(state("knoref").rc).toBe(0)
  })
  test("jobrun state is graded by jobs-grade (producer/consumer contract)", () => {
    jobrun(["contract", "--owner", "o", "--every", "300", "--", "true"])
    const rows = gradeAll(dir, { now: Date.now(), loaded: () => true })
    expect(rows.find((x) => x.label === "contract")?.grade).toBe("ok")
  })
})

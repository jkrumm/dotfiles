import { describe, expect, test } from "bun:test"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  type Cache, type Registry, type SpawnResult, type Spawner, accountFromConfigDir, emptyCache, markExhausted, mergeSample, needsRefresh, pick, pickLine,
  claimRefresh, homeIds, recordSample, refreshBeforePick, refreshEnv, runRefresh, sampleFromClaudeJson, shellLine, updateCache,
} from "./lib/claude-accounts.ts"

const NOW = 1_800_000_000_000
const H = 3600
const reg = (bEnabled = true): Registry => ({
  accounts: {
    a: { dir: null, plan: "max20x", units: { session: 4, weekly: 2 }, homeLanes: ["interactive", "agent-gateway:review", "headless"], enabled: true },
    b: { dir: "/home/x/.claude-b", plan: "max5x", units: { session: 1, weekly: 1 }, homeLanes: ["wave", "fan", "agent-gateway:*"], enabled: bEnabled },
  },
})
const sample = (s: number, w: number, o: { age?: number; wReset?: number } = {}) => ({
  s, w, s_reset: NOW / 1000 + 3 * H, w_reset: o.wReset ?? NOW / 1000 + 100 * H, ts: NOW - (o.age ?? 60_000), src: "t",
})
const cacheOf = (a?: ReturnType<typeof sample>, b?: ReturnType<typeof sample>): Cache => {
  let c = emptyCache()
  if (a) c = mergeSample(c, "a", a)
  if (b) c = mergeSample(c, "b", b)
  return c
}

describe("pick rule v1", () => {
  test("home eligible", () => {
    expect(pick(reg(), cacheOf(sample(10, 10), sample(10, 10)), "wave", NOW)).toMatchObject({ picked: "b", reason: "home" })
    expect(pick(reg(), cacheOf(sample(10, 10), sample(10, 10)), "interactive", NOW)).toMatchObject({ picked: "a", reason: "home" })
    expect(pick(reg(), cacheOf(sample(10, 10), sample(10, 10)), "agent-gateway:review", NOW).picked).toBe("a")
    expect(pick(reg(), cacheOf(sample(10, 10), sample(10, 10)), "agent-gateway:dispatch", NOW).picked).toBe("b")
  })
  test("expiring capacity beats home for bulk lanes only", () => {
    const a = sample(10, 40, { wReset: NOW / 1000 + 5 * H })
    expect(pick(reg(), cacheOf(a, sample(10, 10)), "wave", NOW)).toMatchObject({ picked: "a", reason: "expiring-capacity" })
    expect(pick(reg(), cacheOf(a, sample(10, 10)), "interactive", NOW).reason).toBe("home")
  })
  test("expiring capacity needs weekly < 70", () => {
    const a = sample(10, 75, { wReset: NOW / 1000 + 5 * H })
    expect(pick(reg(), cacheOf(a, sample(10, 10)), "wave", NOW).picked).toBe("b")
  })
  test("spill to the other account when home is over a threshold", () => {
    expect(pick(reg(), cacheOf(sample(10, 10), sample(90, 10)), "wave", NOW)).toMatchObject({ picked: "a", reason: "spill", stale: false })
    expect(pick(reg(), cacheOf(sample(10, 95), sample(10, 10)), "interactive", NOW)).toMatchObject({ picked: "b", reason: "spill" })
  })
  test("interactive falls back to a, bulk goes to iu", () => {
    const c = cacheOf(sample(99, 99), sample(99, 99))
    expect(pick(reg(), c, "interactive", NOW)).toMatchObject({ picked: "a", reason: "interactive-fallback" })
    expect(pick(reg(), c, "wave", NOW)).toMatchObject({ picked: "iu", reason: "no-eligible-account" })
  })
  test("disabled b is never picked", () => {
    expect(pick(reg(false), cacheOf(sample(10, 10), sample(0, 0)), "wave", NOW)).toMatchObject({ picked: "a", reason: "spill", stale: false })
  })
  test("stale sample (10 min - 6 h) is used as stale-ok, never sends bulk to iu", () => {
    const c = cacheOf(sample(10, 10, { age: 11 * 60_000 }), sample(10, 10))
    expect(pick(reg(), c, "interactive", NOW)).toMatchObject({ picked: "a", reason: "home", stale: true })
    expect(pick(reg(false), c, "wave", NOW)).toMatchObject({ picked: "a", reason: "spill", stale: true })
    expect(pick(reg(), cacheOf(sample(10, 10, { age: 5 * H * 1000 }), sample(10, 10, { age: 5 * H * 1000 })), "wave", NOW)).toMatchObject({ picked: "b", reason: "home", stale: true })
  })
  test("stale sample over a threshold is ineligible", () => {
    const c = cacheOf(sample(95, 10, { age: 60 * 60_000 }))
    expect(pick(reg(false), c, "wave", NOW)).toMatchObject({ picked: "iu", reason: "no-eligible-account" })
  })
  test("sample older than 6 h is ineligible", () => {
    expect(pick(reg(false), cacheOf(sample(10, 10, { age: 7 * H * 1000 })), "wave", NOW).picked).toBe("iu")
  })
  test("never-sampled account is ineligible", () => {
    expect(pick(reg(), cacheOf(undefined, sample(10, 10)), "interactive", NOW)).toMatchObject({ picked: "b", reason: "spill" })
    expect(pick(reg(), cacheOf(), "wave", NOW)).toMatchObject({ picked: "iu", reason: "no-eligible-account" })
    expect(pick(reg(), cacheOf(), "interactive", NOW)).toMatchObject({ picked: "a", reason: "interactive-fallback" })
  })
  test("refresh-then-pick: a stale account becomes fresh and is picked as home", () => {
    const stale = cacheOf(sample(10, 10, { age: 11 * 60_000 }), sample(10, 10, { age: 11 * 60_000 }))
    expect(needsRefresh(reg(), stale, NOW)).toEqual(["a", "b"])
    expect(pick(reg(), stale, "wave", NOW)).toMatchObject({ reason: "home", stale: true })
    const refreshed = mergeSample(mergeSample(stale, "a", sample(10, 10)), "b", sample(10, 10))
    expect(pick(reg(), refreshed, "wave", NOW)).toMatchObject({ picked: "b", reason: "home", stale: false })
  })
  test("refresh skipped by the 5-min budget falls back to stale-ok", () => {
    const stale = { ...cacheOf(sample(10, 10, { age: 11 * 60_000 })), refreshed: { a: NOW - 60_000 } }
    expect(needsRefresh(reg(false), stale, NOW)).toEqual([])
    expect(pick(reg(false), stale, "wave", NOW)).toMatchObject({ picked: "a", reason: "spill", stale: true })
  })
  test("exhausted mark holds until resets_at", () => {
    const c = markExhausted(cacheOf(sample(10, 10), sample(10, 10)), "b", NOW / 1000 + 600)
    expect(pick(reg(), c, "wave", NOW)).toMatchObject({ picked: "a", reason: "spill", stale: false })
    expect(pick(reg(), c, "wave", NOW + 601_000)).toMatchObject({ picked: "b", reason: "home", stale: true }) // mark expired; samples now stale-ok
  })
  test("auth_failed account is skipped", () => {
    const c = { ...cacheOf(sample(10, 10), sample(10, 10)), auth_failed: { b: true } }
    expect(pick(reg(), c, "wave", NOW).picked).toBe("a")
  })
})

describe("cache + helpers", () => {
  test("freshest sample wins", () => {
    const c = mergeSample(cacheOf(sample(50, 50)), "a", { ...sample(1, 1), ts: NOW - 120_000 })
    expect(c.samples.a.s).toBe(50)
  })
  test("shellLine", () => {
    expect(shellLine(reg(), { picked: "a", reason: "", stale: false })).toBe("unset CLAUDE_CONFIG_DIR")
    expect(shellLine(reg(), { picked: "b", reason: "", stale: false })).toBe("export CLAUDE_CONFIG_DIR='/home/x/.claude-b'")
    expect(shellLine(reg(), { picked: "iu", reason: "", stale: false })).toBeNull()
  })
  test("accountFromConfigDir: unset -> a", () => {
    expect(accountFromConfigDir(reg(), undefined)).toBe("a")
    expect(accountFromConfigDir(reg(), "")).toBe("a")
    expect(accountFromConfigDir(reg(), "/home/x/.claude-b")).toBe("b")
    expect(accountFromConfigDir(reg(), "/somewhere/else")).toBeNull() // set but unregistered: unknown, not "a"
  })
  test("sampleFromClaudeJson", () => {
    const s = sampleFromClaudeJson({
      cachedUsageUtilization: { fetchedAtMs: NOW, accountUuid: "u", utilization: { five_hour: { utilization: 11, resets_at: "2026-10-24T13:50:00+00:00" }, seven_day: { utilization: 85, resets_at: "2026-10-28T16:00:00+00:00" } } },
    })
    expect(s).toMatchObject({ s: 11, w: 85, ts: NOW, s_reset: Date.parse("2026-10-24T13:50:00Z") / 1000 })
    expect(sampleFromClaudeJson({})).toBeNull()
  })
  test("needsRefresh: stale + not recently tried, enabled only", () => {
    const stale = cacheOf(sample(1, 1, { age: 11 * 60_000 }), sample(1, 1, { age: 11 * 60_000 }))
    expect(needsRefresh(reg(false), stale, NOW)).toEqual(["a"])
    expect(needsRefresh(reg(), cacheOf(sample(1, 1)), NOW)).toEqual(["b"])
    expect(needsRefresh(reg(false), { ...stale, refreshed: { a: NOW - 60_000 } }, NOW)).toEqual([])
  })
  test("pickLine shape", () => {
    const l = pickLine(reg(), cacheOf(sample(1, 2)), "wave", { picked: "a", reason: "spill", stale: true }, NOW)
    expect(l).toMatchObject({ lane: "wave", picked: "a", reason: "spill", stale: true, a: { s: 1, w: 2 }, b: { s: null, w: null } })
  })
})

describe("review fixes", () => {
  test("expiring capacity: a past reset does not qualify, a future one does", () => {
    const past = sample(10, 40, { wReset: NOW / 1000 - 60 })
    expect(pick(reg(), cacheOf(past, sample(10, 10)), "wave", NOW)).toMatchObject({ picked: "b", reason: "home" })
    const future = sample(10, 40, { wReset: NOW / 1000 + 60 })
    expect(pick(reg(), cacheOf(future, sample(10, 10)), "wave", NOW)).toMatchObject({ picked: "a", reason: "expiring-capacity" })
  })
  test("partial record keeps the previous non-null fields", () => {
    const c = recordSample(cacheOf(sample(10, 40, { wReset: NOW / 1000 + 9 })), "a", { s: 20 }, NOW)
    expect(c.samples.a).toMatchObject({ s: 20, w: 40, w_reset: NOW / 1000 + 9, src: "statusline" })
    expect(c.samples.a.ts).toBe(NOW - 60_000) // a retained field keeps the old ts: not presented as fresh
    expect(recordSample(emptyCache(), "a", { s: 5 }, NOW).samples.a).toMatchObject({ s: 5, w: null, s_reset: null, ts: NOW })
    const full = recordSample(cacheOf(sample(10, 40)), "a", { s: 1, w: 2, s_reset: 3, w_reset: 4 }, NOW)
    expect(full.samples.a.ts).toBe(NOW)
  })
  test("shellLine quotes spaces and quotes", () => {
    const r = reg()
    r.accounts.b.dir = "/home/x/my dir/it's"
    expect(shellLine(r, { picked: "b", reason: "", stale: false })).toBe(`export CLAUDE_CONFIG_DIR='/home/x/my dir/it'\\''s'`)
  })
  test("refresh env strips credentials and blanks the base url", () => {
    const e = refreshEnv({ ANTHROPIC_API_KEY: "k", ANTHROPIC_AUTH_TOKEN: "t", CLAUDE_CODE_OAUTH_TOKEN: "o", CLAUDE_CONFIG_DIR: "/x", PATH: "/bin" }, null)
    expect(e).toEqual({ ANTHROPIC_BASE_URL: "", PATH: "/bin" })
    expect(refreshEnv({}, "/d").CLAUDE_CONFIG_DIR).toBe("/d")
  })
})


describe("recordSample auth", () => {
  test("clears auth_failed for that account only", () => {
    const c = recordSample({ ...emptyCache(), auth_failed: { a: true, b: true } }, "a", { s: 1 }, NOW)
    expect(c.auth_failed).toEqual({ a: false, b: true })
  })
})

describe("pickLine", () => {
  test("accounts come from the registry", () => {
    const r = reg()
    r.accounts.c = { ...r.accounts.b }
    const l = pickLine(r, cacheOf(sample(1, 2)), "wave", { picked: "a", reason: "home", stale: false }, NOW)
    expect(Object.keys(l).filter((k) => !["ts", "lane", "picked", "reason", "stale"].includes(k))).toEqual(["a", "b", "c"])
  })
})

const mem = (init: Cache) => {
  let c = init
  return { update: (fn: (c: Cache) => Cache) => { c = fn(c) }, get cache() { return c } }
}
const staleA = () => cacheOf(sample(10, 10, { age: 11 * 60_000 }))
const ok: SpawnResult = { status: 0, stdout: "{}", stderr: "" }

describe("claimRefresh", () => {
  test("stamps the due ids; a second claim gets nothing (at most one refresh)", () => {
    const m = mem(staleA())
    expect(claimRefresh(m.update, reg(false), ["a"], NOW)).toEqual(["a"])
    expect(m.cache.refreshed.a).toBe(NOW)
    expect(claimRefresh(m.update, reg(false), ["a"], NOW + 1000)).toEqual([])
  })
  test("only claims the ids asked for, and only enabled ones", () => {
    const m = mem(cacheOf(sample(1, 1, { age: 11 * 60_000 }), sample(1, 1, { age: 11 * 60_000 })))
    expect(claimRefresh(m.update, reg(false), ["a", "b"], NOW)).toEqual(["a"])
  })
  test("nothing claimed leaves the cache object untouched", () => {
    const m = mem(cacheOf(sample(1, 1)))
    const before = m.cache
    expect(claimRefresh(m.update, reg(), ["a"], NOW, (c) => mergeSample(c, "b", sample(2, 2)))).toEqual([])
    expect(m.cache).toBe(before)
  })
})

describe("updateCache (locked)", () => {
  const lib = join(import.meta.dir, "lib", "claude-accounts.ts")
  const dir = mkdtempSync(join(tmpdir(), "ca-lock-"))
  const path = join(dir, "usage.json")
  const run = (code: string) =>
    Bun.spawn(["bun", "-e", `import * as L from ${JSON.stringify(lib)}; ${code}`], { env: { ...process.env, CLAUDE_ACCOUNTS_CACHE: path }, stdout: "pipe", stderr: "pipe" })

  test("concurrent processes lose no update", async () => {
    const ps = Array.from({ length: 8 }, (_, i) => run(`L.updateCache((c) => ({ ...c, refreshed: { ...c.refreshed, k${i}: ${i + 1} } }))`))
    for (const p of ps) expect(await p.exited).toBe(0)
    const refreshed = JSON.parse(readFileSync(path, "utf8")).refreshed
    expect(Object.keys(refreshed).sort()).toEqual(Array.from({ length: 8 }, (_, i) => `k${i}`).sort())
  })
  test("two concurrent claimers: exactly one wins the refresh", async () => {
    const code = `const reg = { accounts: { a: { dir: null, plan: "x", units: { session: 1, weekly: 1 }, homeLanes: [], enabled: true } } }; console.log(JSON.stringify(L.claimRefresh(L.updateCache, reg, ["a"], Date.now())))`
    updateCache((c) => ({ ...c, samples: { a: { ...sample(1, 1), ts: Date.now() - 20 * 60_000 } }, refreshed: {} }), path)
    const ps = Array.from({ length: 6 }, () => run(code))
    const outs = await Promise.all(ps.map(async (p) => (await p.exited, (await new Response(p.stdout).text()).trim())))
    expect(outs.filter((o) => o === '["a"]').length).toBe(1)
    expect(outs.filter((o) => o === "[]").length).toBe(5)
  })
  test("a stale lock from a dead process is broken", () => {
    const lock = `${path}.lock`
    mkdirSync(lock)
    const old = new Date(Date.now() - 120_000)
    utimesSync(lock, old, old)
    updateCache((c) => ({ ...c, refreshed: { ...c.refreshed, after: 1 } }), path)
    expect(JSON.parse(readFileSync(path, "utf8")).refreshed.after).toBe(1)
    rmSync(dir, { recursive: true, force: true })
  })
})

describe("runRefresh", () => {
  function harness(spawn: Spawner, o: { cache?: Cache; read?: () => ReturnType<typeof sample> | null; during?: (m: ReturnType<typeof mem>) => void } = {}) {
    const m = mem(o.cache ?? { ...staleA(), refreshed: { a: NOW } }) // pre-claimed
    const spawned: string[] = []
    runRefresh({
      reg: reg(false), claudeBin: "claude", baseEnv: {}, timeoutS: 75, now: () => NOW, ids: ["a"],
      spawn: (c, a, e) => { spawned.push(e.env.CLAUDE_CONFIG_DIR ?? "unset"); o.during?.(m); return spawn(c, a, e) },
      readSample: () => o.read?.() ?? null, update: m.update,
    })
    return { m, spawned }
  }
  test("success merges the new sample and clears the auth verdict", () => {
    const { m, spawned } = harness(() => ok, { read: () => sample(33, 44), cache: { ...staleA(), refreshed: { a: NOW }, auth_failed: { a: true } } })
    expect(spawned).toEqual(["unset"])
    expect(m.cache.samples.a).toMatchObject({ s: 33, w: 44 })
    expect(m.cache.auth_failed.a).toBe(false)
    expect(m.cache.refreshed.a).toBe(NOW)
  })
  test("missing binary rolls the budget stamp back and sets no auth verdict", () => {
    const { m } = harness(() => ({ status: null, stdout: "", stderr: "", error: { code: "ENOENT", message: "spawn claude ENOENT" } }))
    expect(m.cache.refreshed.a).toBeUndefined()
    expect(m.cache.auth_failed.a).toBeUndefined()
  })
  test("auth failure marks auth_failed and keeps the stamp", () => {
    const { m } = harness(() => ({ status: 1, stdout: "", stderr: "Not logged in · Please run /login" }))
    expect(m.cache.auth_failed.a).toBe(true)
    expect(m.cache.refreshed.a).toBe(NOW)
  })
  test("timeout keeps the stamp and the previous auth verdict", () => {
    const { m } = harness(() => ({ status: null, stdout: "", stderr: "", error: { code: "ETIMEDOUT", message: "timed out" } }), { cache: { ...staleA(), refreshed: { a: NOW }, auth_failed: { a: true } } })
    expect(m.cache.refreshed.a).toBe(NOW)
    expect(m.cache.auth_failed.a).toBe(true)
  })
  test("a statusline record written during the spawn is not lost", () => {
    const { m } = harness(() => ok, {
      read: () => sample(33, 44, { age: 5000 }),
      during: (mm) => mm.update((c) => recordSample(c, "a", { s: 77, w: 78, s_reset: 1, w_reset: 2 }, NOW - 1000)),
    })
    expect(m.cache.samples.a).toMatchObject({ s: 77 })
  })
})

describe("refreshBeforePick", () => {
  function run(cache: Cache, lane = "wave", enabledB = false) {
    const m = mem(cache)
    const calls = { sync: [] as string[][], detach: [] as string[][] }
    const r = refreshBeforePick({
      reg: reg(enabledB), lane, now: NOW, cache,
      claim: (ids) => claimRefresh(m.update, reg(enabledB), ids, NOW),
      runSync: (ids) => calls.sync.push(ids), detach: (ids) => calls.detach.push(ids),
    })
    return { r, calls, m }
  }
  test("stale sample: no blocking refresh, claimed and detached", () => {
    const { r, calls, m } = run(staleA())
    expect(r).toEqual({ sync: [], background: ["a"] })
    expect(calls).toEqual({ sync: [], detach: [["a"]] })
    expect(m.cache.refreshed.a).toBe(NOW)
  })
  test("budget already spent schedules nothing", () => {
    expect(run({ ...staleA(), refreshed: { a: NOW - 60_000 } }).r).toEqual({ sync: [], background: [] })
  })
  test("fresh sample schedules nothing", () => {
    expect(run(cacheOf(sample(10, 10))).r).toEqual({ sync: [], background: [] })
  })
  test("no sample on a bulk lane: synchronous; stale neighbour in the background", () => {
    const { r, calls } = run(cacheOf(undefined, sample(10, 10, { age: 11 * 60_000 })), "wave", true)
    expect(r).toEqual({ sync: ["a"], background: ["b"] })
    expect(calls).toEqual({ sync: [["a"]], detach: [["b"]] })
  })
  test("interactive returns before any claim: no lock, no write, no refresh", () => {
    let claimed = false
    const r = refreshBeforePick({
      reg: reg(), lane: "interactive", now: NOW, cache: emptyCache(),
      claim: () => { claimed = true; return ["a"] }, runSync: () => { throw new Error("sync") }, detach: () => { throw new Error("detach") },
    })
    expect(r).toEqual({ sync: [], background: [] })
    expect(claimed).toBe(false)
  })
  test("a sample older than 6 h counts as no sample", () => {
    expect(run(cacheOf(sample(10, 10, { age: 7 * H * 1000 }))).r).toEqual({ sync: ["a"], background: [] })
  })
})

describe("home lanes", () => {
  test("exact lane match beats a wildcard", () => {
    expect(homeIds(reg(), "agent-gateway:review")).toEqual(["a"])
    expect(homeIds(reg(), "agent-gateway:dispatch")).toEqual(["b"])
    expect(homeIds(reg(), "wave")).toEqual(["b"])
    expect(homeIds(reg(), "nope")).toEqual([])
  })
  test("review lane with a ineligible spills to b, not home", () => {
    const c = cacheOf(sample(99, 10), sample(10, 10))
    expect(pick(reg(), c, "agent-gateway:review", NOW)).toMatchObject({ picked: "b", reason: "spill" })
  })
})

describe("lock owner token", () => {
  const dir = mkdtempSync(join(tmpdir(), "ca-tok-"))
  const lib = join(import.meta.dir, "lib", "claude-accounts.ts")
  const path = join(dir, "usage.json")
  const run = (code: string) =>
    Bun.spawn(["bun", "-e", `import * as L from ${JSON.stringify(lib)}; ${code}`], { env: { ...process.env, CLAUDE_ACCOUNTS_CACHE: path }, stdout: "pipe", stderr: "pipe" })

  test("release leaves a lock whose token is no longer ours", () => {
    updateCache((c) => { writeFileSync(join(`${path}.lock`, "owner"), "someone-else"); return c }, path)
    expect(existsSync(`${path}.lock`)).toBe(true)
    rmSync(`${path}.lock`, { recursive: true })
  })
  test("racing stale-lock breakers: every update lands, no lock or grave left", async () => {
    mkdirSync(`${path}.lock`)
    writeFileSync(join(`${path}.lock`, "owner"), "dead.1")
    const old = new Date(Date.now() - 120_000)
    utimesSync(`${path}.lock`, old, old)
    const ps = Array.from({ length: 8 }, (_, i) => run(`L.updateCache((c) => ({ ...c, refreshed: { ...c.refreshed, r${i}: 1 } }))`))
    for (const p of ps) expect(await p.exited).toBe(0)
    expect(Object.keys(JSON.parse(readFileSync(path, "utf8")).refreshed).length).toBe(8)
    expect(readdirSync(dir).filter((f) => f.includes("lock"))).toEqual([])
    rmSync(dir, { recursive: true, force: true })
  })
})

describe("CLI (isolated HOME)", () => {
  const CLI = join(import.meta.dir, "claude-account.ts")
  const home = mkdtempSync(join(tmpdir(), "ca-cli-"))
  const bin = join(home, "bin")
  const marker = join(home, "claude-ran")
  mkdirSync(bin)
  writeFileSync(join(bin, "claude"), `#!/bin/sh\ntouch ${marker}\nexit 0\n`)
  chmodSync(join(bin, "claude"), 0o755)
  const cache = join(home, "usage.json")
  const base = { ...(process.env as Record<string, string>), HOME: home, CLAUDE_ACCOUNTS_CACHE: cache, CLAUDE_ACCOUNTS_PICKS: join(home, "picks.jsonl"), PATH: `${bin}:${process.env.PATH}` }
  delete (base as Record<string, string | undefined>).CLAUDE_CONFIG_DIR
  const cli = (args: string[], env: Record<string, string> = {}) => {
    const t = Date.now()
    const r = Bun.spawnSync(["bun", CLI, ...args], { env: { ...base, ...env }, stdout: "pipe", stderr: "pipe" })
    return { rc: r.exitCode, out: r.stdout.toString().trim(), err: r.stderr.toString(), ms: Date.now() - t }
  }
  const seedCache = (ageMs: number) => {
    rmSync(marker, { force: true })
    rmSync(`${cache}.lock`, { recursive: true, force: true })
    writeFileSync(cache, JSON.stringify({ ...emptyCache(), samples: { a: { s: 5, w: 5, s_reset: null, w_reset: null, ts: Date.now() - ageMs, src: "t" } } }))
  }
  const holdLock = () => { mkdirSync(`${cache}.lock`); writeFileSync(join(`${cache}.lock`, "owner"), "held") }

  test("interactive pick with a held lock answers at once and does not touch the cache", () => {
    seedCache(20 * 60_000)
    holdLock()
    const r = cli(["pick", "--lane", "interactive"])
    expect(r).toMatchObject({ rc: 0, out: "unset CLAUDE_CONFIG_DIR" })
    expect(r.ms).toBeLessThan(2500)
  })
  test("a pick on a busy lock (> 3 s) still prints a line", () => {
    seedCache(20 * 60_000)
    holdLock()
    const r = cli(["pick", "--lane", "wave"])
    expect(r.rc).toBe(0)
    expect(r.out).toBe("unset CLAUDE_CONFIG_DIR")
    expect(r.ms).toBeGreaterThan(2500)
  }, 20_000)
  test("account / --badge: unregistered dir prints ?, unset prints the id", () => {
    expect(cli(["account"]).out).toBe("a")
    expect(cli(["account", "--badge"]).out).toBe("") // one enabled account: no badge
    expect(cli(["account"], { CLAUDE_CONFIG_DIR: "/nowhere" }).out).toBe("?")
    expect(cli(["account", "--badge"], { CLAUDE_CONFIG_DIR: "/nowhere" }).out).toBe("?")
  })
  test("refresh --ids applies the due filter; --claimed bypasses the claim", () => {
    seedCache(60_000) // fresh sample: not due
    expect(cli(["refresh", "--ids", "a"]).rc).toBe(0)
    expect(existsSync(marker)).toBe(false)
    expect(cli(["refresh", "--ids", "b"]).rc).toBe(0) // disabled
    expect(existsSync(marker)).toBe(false)
    expect(cli(["refresh", "--claimed", "b"]).rc).toBe(0) // disabled, even when claimed
    expect(existsSync(marker)).toBe(false)
    expect(cli(["refresh", "--claimed", "a"]).rc).toBe(0)
    expect(existsSync(marker)).toBe(true)
    seedCache(20 * 60_000) // stale: due -> claimed, stamped, spawned
    expect(cli(["refresh", "--ids", "a"]).rc).toBe(0)
    expect(existsSync(marker)).toBe(true)
    expect(JSON.parse(readFileSync(cache, "utf8")).refreshed.a).toBeGreaterThan(0)
    rmSync(home, { recursive: true, force: true })
  })
})

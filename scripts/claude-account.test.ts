import { describe, expect, test } from "bun:test"
import {
  type Cache, type Registry, type SpawnResult, type Spawner, accountFromConfigDir, emptyCache, markExhausted, mergeSample, needsRefresh, pick, pickLine,
  recordSample, refreshEnv, runRefresh, sampleFromClaudeJson, shellLine,
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
    const l = pickLine(cacheOf(sample(1, 2)), "wave", { picked: "a", reason: "spill", stale: true }, NOW)
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
    expect(c.samples.a).toMatchObject({ s: 20, w: 40, w_reset: NOW / 1000 + 9, ts: NOW, src: "statusline" })
    expect(recordSample(emptyCache(), "a", { s: 5 }, NOW).samples.a).toMatchObject({ s: 5, w: null, s_reset: null })
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

describe("runRefresh", () => {
  const stale = () => cacheOf(sample(10, 10, { age: 11 * 60_000 }))
  function harness(spawn: Spawner, opts: { cache?: Cache; read?: (id: string) => ReturnType<typeof sample> | null; between?: () => void } = {}) {
    let stored = opts.cache ?? stale()
    const spawned: string[] = []
    runRefresh({
      reg: reg(false), claudeBin: "claude", baseEnv: {}, timeoutS: 20, now: () => NOW,
      spawn: (cmd, args, o) => { spawned.push(o.env.CLAUDE_CONFIG_DIR ?? "unset"); opts.between?.(); return spawn(cmd, args, o) },
      readSample: (id) => (spawned.length ? (opts.read?.(id) ?? null) : null), load: () => stored, write: (c) => { stored = c },
    })
    return { get cache() { return stored }, spawned }
  }
  const ok: SpawnResult = { status: 0, stdout: "{}", stderr: "" }

  test("success stamps the budget and merges the new sample", () => {
    const h = harness(() => ok, { read: () => sample(33, 44) })
    expect(h.spawned).toEqual(["unset"])
    expect(h.cache.refreshed.a).toBe(NOW)
    expect(h.cache.samples.a).toMatchObject({ s: 33, w: 44 })
  })
  test("missing binary: no budget stamp, no auth verdict", () => {
    const h = harness(() => ({ status: null, stdout: "", stderr: "", error: { code: "ENOENT", message: "spawn claude ENOENT" } }))
    expect(h.cache.refreshed.a).toBeUndefined()
    expect(h.cache.auth_failed.a).toBeUndefined()
  })
  test("auth failure marks auth_failed and stamps", () => {
    const h = harness(() => ({ status: 1, stdout: "", stderr: "Not logged in · Please run /login" }))
    expect(h.cache.auth_failed.a).toBe(true)
    expect(h.cache.refreshed.a).toBe(NOW)
  })
  test("timeout stamps but leaves the auth verdict alone", () => {
    const h = harness(() => ({ status: null, stdout: "", stderr: "", error: { code: "ETIMEDOUT", message: "timed out" } }), { cache: { ...stale(), auth_failed: { a: true } } })
    expect(h.cache.refreshed.a).toBe(NOW)
    expect(h.cache.auth_failed.a).toBe(true)
  })
  test("a statusline record written during the spawn is not lost", () => {
    let stored: Cache = stale()
    let spawnedYet = false
    runRefresh({
      reg: reg(false), claudeBin: "claude", baseEnv: {}, timeoutS: 20, now: () => NOW,
      spawn: () => { spawnedYet = true; stored = recordSample(stored, "a", { s: 77, w: 78, s_reset: 1, w_reset: 2 }, NOW - 1000); return ok },
      readSample: () => (spawnedYet ? sample(33, 44, { age: 5000 }) : null), load: () => stored, write: (c) => { stored = c },
    })
    expect(stored.samples.a).toMatchObject({ s: 77 }) // newer than the refreshed sample (ts NOW-1000 vs NOW-5000)
    expect(stored.refreshed.a).toBe(NOW)
  })
})

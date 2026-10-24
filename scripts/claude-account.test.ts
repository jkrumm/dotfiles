import { describe, expect, test } from "bun:test"
import { type Cache, type Registry, accountFromConfigDir, emptyCache, markExhausted, mergeSample, needsRefresh, pick, pickLine, sampleFromClaudeJson, shellLine } from "./lib/claude-accounts.ts"

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
    expect(pick(reg(), cacheOf(sample(10, 10), sample(10, 10)), "wave", NOW)).toEqual({ picked: "b", reason: "home" })
    expect(pick(reg(), cacheOf(sample(10, 10), sample(10, 10)), "interactive", NOW)).toEqual({ picked: "a", reason: "home" })
    expect(pick(reg(), cacheOf(sample(10, 10), sample(10, 10)), "agent-gateway:review", NOW).picked).toBe("a")
    expect(pick(reg(), cacheOf(sample(10, 10), sample(10, 10)), "agent-gateway:dispatch", NOW).picked).toBe("b")
  })
  test("expiring capacity beats home for bulk lanes only", () => {
    const a = sample(10, 40, { wReset: NOW / 1000 + 5 * H })
    expect(pick(reg(), cacheOf(a, sample(10, 10)), "wave", NOW)).toEqual({ picked: "a", reason: "expiring-capacity" })
    expect(pick(reg(), cacheOf(a, sample(10, 10)), "interactive", NOW).reason).toBe("home")
  })
  test("expiring capacity needs weekly < 70", () => {
    const a = sample(10, 75, { wReset: NOW / 1000 + 5 * H })
    expect(pick(reg(), cacheOf(a, sample(10, 10)), "wave", NOW).picked).toBe("b")
  })
  test("spill to the other account when home is over a threshold", () => {
    expect(pick(reg(), cacheOf(sample(10, 10), sample(90, 10)), "wave", NOW)).toEqual({ picked: "a", reason: "spill" })
    expect(pick(reg(), cacheOf(sample(10, 95), sample(10, 10)), "interactive", NOW)).toEqual({ picked: "b", reason: "spill" })
  })
  test("interactive falls back to a, bulk goes to iu", () => {
    const c = cacheOf(sample(99, 99), sample(99, 99))
    expect(pick(reg(), c, "interactive", NOW)).toEqual({ picked: "a", reason: "interactive-fallback" })
    expect(pick(reg(), c, "wave", NOW)).toEqual({ picked: "iu", reason: "no-eligible-account" })
  })
  test("disabled b is never picked", () => {
    expect(pick(reg(false), cacheOf(sample(10, 10), sample(0, 0)), "wave", NOW)).toEqual({ picked: "a", reason: "spill" })
  })
  test("stale sample (10 min - 6 h) is used as stale-ok, never sends bulk to iu", () => {
    const c = cacheOf(sample(10, 10, { age: 11 * 60_000 }), sample(10, 10))
    expect(pick(reg(), c, "interactive", NOW)).toEqual({ picked: "a", reason: "stale-ok" })
    expect(pick(reg(false), c, "wave", NOW)).toEqual({ picked: "a", reason: "stale-ok" })
    expect(pick(reg(), cacheOf(sample(10, 10, { age: 5 * H * 1000 }), sample(10, 10, { age: 5 * H * 1000 })), "wave", NOW)).toEqual({ picked: "b", reason: "stale-ok" })
  })
  test("stale sample over a threshold is ineligible", () => {
    const c = cacheOf(sample(95, 10, { age: 60 * 60_000 }))
    expect(pick(reg(false), c, "wave", NOW)).toEqual({ picked: "iu", reason: "no-eligible-account" })
  })
  test("sample older than 6 h is ineligible", () => {
    expect(pick(reg(false), cacheOf(sample(10, 10, { age: 7 * H * 1000 })), "wave", NOW).picked).toBe("iu")
  })
  test("never-sampled account is ineligible", () => {
    expect(pick(reg(), cacheOf(undefined, sample(10, 10)), "interactive", NOW)).toEqual({ picked: "b", reason: "spill" })
    expect(pick(reg(), cacheOf(), "wave", NOW)).toEqual({ picked: "iu", reason: "no-eligible-account" })
    expect(pick(reg(), cacheOf(), "interactive", NOW)).toEqual({ picked: "a", reason: "interactive-fallback" })
  })
  test("refresh-then-pick: a stale account becomes fresh and is picked as home", () => {
    const stale = cacheOf(sample(10, 10, { age: 11 * 60_000 }), sample(10, 10, { age: 11 * 60_000 }))
    expect(needsRefresh(reg(), stale, NOW)).toEqual(["a", "b"])
    expect(pick(reg(), stale, "wave", NOW).reason).toBe("stale-ok")
    const refreshed = mergeSample(mergeSample(stale, "a", sample(10, 10)), "b", sample(10, 10))
    expect(pick(reg(), refreshed, "wave", NOW)).toEqual({ picked: "b", reason: "home" })
  })
  test("refresh skipped by the 5-min budget falls back to stale-ok", () => {
    const stale = { ...cacheOf(sample(10, 10, { age: 11 * 60_000 })), refreshed: { a: NOW - 60_000 } }
    expect(needsRefresh(reg(false), stale, NOW)).toEqual([])
    expect(pick(reg(false), stale, "wave", NOW)).toEqual({ picked: "a", reason: "stale-ok" })
  })
  test("exhausted mark holds until resets_at", () => {
    const c = markExhausted(cacheOf(sample(10, 10), sample(10, 10)), "b", NOW / 1000 + 600)
    expect(pick(reg(), c, "wave", NOW)).toEqual({ picked: "a", reason: "spill" })
    expect(pick(reg(), c, "wave", NOW + 601_000)).toEqual({ picked: "b", reason: "stale-ok" }) // mark expired; samples now stale-ok
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
    expect(shellLine(reg(), { picked: "a", reason: "" })).toBe("unset CLAUDE_CONFIG_DIR")
    expect(shellLine(reg(), { picked: "b", reason: "" })).toBe("export CLAUDE_CONFIG_DIR=/home/x/.claude-b")
    expect(shellLine(reg(), { picked: "iu", reason: "" })).toBeNull()
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
    const l = pickLine(cacheOf(sample(1, 2)), "wave", { picked: "a", reason: "spill" }, NOW)
    expect(l).toMatchObject({ lane: "wave", picked: "a", reason: "spill", a: { s: 1, w: 2 }, b: { s: null, w: null } })
  })
})

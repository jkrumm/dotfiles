import { describe, expect, test } from "bun:test"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  type Cache, type Registry, type Sample, type SpawnResult, type Spawner, accountFromConfigDir, claimRefresh, dueIds, emptyCache, homeIds, loadCache, markExhausted,
  mergeSample, newestAge, pick, pickLine, recordSample, refreshBeforePick, refreshEnv, releaseClaim, runRefresh, isSample, loadRegistry, sampleFromClaudeJson, saveSample, setAuthFailed, shellLine,
} from "./lib/claude-accounts.ts"

const NOW = 1_800_000_000_000
const H = 3600
const reg = (bEnabled = true): Registry => ({
  accounts: {
    iu: { dir: null, plan: "max20x", units: { session: 4, weekly: 2 }, homeLanes: ["interactive", "agent-gateway:review", "headless"], enabled: true },
    me: { dir: "/home/x/.claude-me", plan: "max5x", units: { session: 1, weekly: 1 }, homeLanes: ["wave", "fan", "agent-gateway:*"], enabled: bEnabled },
  },
})
const sample = (s: number, w: number, o: { age?: number; wReset?: number } = {}): Sample => ({
  s, w, s_reset: NOW / 1000 + 3 * H, w_reset: o.wReset ?? NOW / 1000 + 100 * H, s_ts: NOW - (o.age ?? 60_000), w_ts: NOW - (o.age ?? 60_000), src: "t",
})
const cacheOf = (a?: Sample, b?: Sample): Cache => ({ ...emptyCache(), samples: { ...(a ? { iu: a } : {}), ...(b ? { me: b } : {}) } })
const tmp = () => mkdtempSync(join(tmpdir(), "ca-"))
const staleA = () => cacheOf(sample(10, 10, { age: 11 * 60_000 }))

describe("pick rule v1", () => {
  test("home eligible", () => {
    const c = cacheOf(sample(10, 10), sample(10, 10))
    expect(pick(reg(), c, "wave", NOW)).toEqual({ picked: "me", reason: "home", stale: false })
    expect(pick(reg(), c, "interactive", NOW)).toMatchObject({ picked: "iu", reason: "home" })
    expect(pick(reg(), c, "agent-gateway:review", NOW).picked).toBe("iu")
    expect(pick(reg(), c, "agent-gateway:dispatch", NOW).picked).toBe("me")
  })
  test("expiring capacity beats home for bulk lanes only", () => {
    const a = sample(10, 40, { wReset: NOW / 1000 + 5 * H })
    expect(pick(reg(), cacheOf(a, sample(10, 10)), "wave", NOW)).toMatchObject({ picked: "iu", reason: "expiring-capacity" })
    expect(pick(reg(), cacheOf(a, sample(10, 10)), "interactive", NOW).reason).toBe("home")
  })
  test("expiring capacity needs weekly < 70, and a reset still ahead", () => {
    expect(pick(reg(), cacheOf(sample(10, 75, { wReset: NOW / 1000 + 5 * H }), sample(10, 10)), "wave", NOW).picked).toBe("me")
    expect(pick(reg(), cacheOf(sample(10, 40, { wReset: NOW / 1000 - 60 }), sample(10, 10)), "wave", NOW)).toMatchObject({ picked: "me", reason: "home" })
    expect(pick(reg(), cacheOf(sample(10, 40, { wReset: NOW / 1000 + 60 }), sample(10, 10)), "wave", NOW)).toMatchObject({ picked: "iu", reason: "expiring-capacity" })
  })
  test("spill to the other account when home is over a threshold", () => {
    expect(pick(reg(), cacheOf(sample(10, 10), sample(90, 10)), "wave", NOW)).toMatchObject({ picked: "iu", reason: "spill" })
    expect(pick(reg(), cacheOf(sample(10, 95), sample(10, 10)), "interactive", NOW)).toMatchObject({ picked: "me", reason: "spill" })
  })
  test("interactive falls back to a, bulk goes to iu", () => {
    const c = cacheOf(sample(99, 99), sample(99, 99))
    expect(pick(reg(), c, "interactive", NOW)).toMatchObject({ picked: "iu", reason: "interactive-fallback" })
    expect(pick(reg(), c, "wave", NOW)).toMatchObject({ picked: "spill", reason: "no-eligible-account" })
  })
  test("disabled b is never picked", () => {
    expect(pick(reg(false), cacheOf(sample(10, 10), sample(0, 0)), "wave", NOW)).toMatchObject({ picked: "iu", reason: "spill" })
  })
  test("a stale sample (10 min - 6 h) is used with stale: true, never sends bulk to iu", () => {
    const c = cacheOf(sample(10, 10, { age: 11 * 60_000 }), sample(10, 10))
    expect(pick(reg(), c, "interactive", NOW)).toMatchObject({ picked: "iu", reason: "home", stale: true })
    expect(pick(reg(false), c, "wave", NOW)).toMatchObject({ picked: "iu", reason: "spill", stale: true })
    expect(pick(reg(), cacheOf(sample(10, 10, { age: 5 * H * 1000 }), sample(10, 10, { age: 5 * H * 1000 })), "wave", NOW)).toMatchObject({ picked: "me", reason: "home", stale: true })
  })
  test("stale sample over a threshold, or older than 6 h, is ineligible", () => {
    expect(pick(reg(false), cacheOf(sample(95, 10, { age: 60 * 60_000 })), "wave", NOW).picked).toBe("spill")
    expect(pick(reg(false), cacheOf(sample(10, 10, { age: 7 * H * 1000 })), "wave", NOW).picked).toBe("spill")
  })
  test("never-sampled account is ineligible", () => {
    expect(pick(reg(), cacheOf(undefined, sample(10, 10)), "interactive", NOW)).toMatchObject({ picked: "me", reason: "spill" })
    expect(pick(reg(), cacheOf(), "wave", NOW).picked).toBe("spill")
    expect(pick(reg(), cacheOf(), "interactive", NOW)).toMatchObject({ picked: "iu", reason: "interactive-fallback", stale: false })
  })
  test("exhausted mark holds until resets_at", () => {
    const c = { ...cacheOf(sample(10, 10), sample(10, 10)), exhausted: { me: NOW / 1000 + 600 } }
    expect(pick(reg(), c, "wave", NOW)).toMatchObject({ picked: "iu", reason: "spill" })
    expect(pick(reg(), c, "wave", NOW + 601_000)).toMatchObject({ picked: "me", reason: "home", stale: true })
  })
  test("auth_failed account is skipped", () => {
    expect(pick(reg(), { ...cacheOf(sample(10, 10), sample(10, 10)), auth_failed: { me: true } }, "wave", NOW).picked).toBe("iu")
  })
  test("each window is judged by its own timestamp", () => {
    // s is 7 h old (ignored: unknown), w is fresh and under the threshold -> eligible, stale
    const x: Sample = { ...sample(99, 10), s_ts: NOW - 7 * H * 1000 }
    expect(pick(reg(false), cacheOf(x), "wave", NOW)).toMatchObject({ picked: "iu", stale: true })
    // w is 7 h old, s fresh and over the threshold -> ineligible
    expect(pick(reg(false), cacheOf({ ...sample(95, 10), w_ts: NOW - 7 * H * 1000 }), "wave", NOW).picked).toBe("spill")
    // a fresh s next to a 1 h old w: the sample is only as fresh as its stalest window
    expect(pick(reg(false), cacheOf({ ...sample(10, 10), w_ts: NOW - 3_600_000 }), "wave", NOW).stale).toBe(true)
  })
  test("home lanes: exact match beats a wildcard; review spills to b rather than counting it home", () => {
    expect(homeIds(reg(), "agent-gateway:review")).toEqual(["iu"])
    expect(homeIds(reg(), "agent-gateway:dispatch")).toEqual(["me"])
    expect(homeIds(reg(), "nope")).toEqual([])
    expect(pick(reg(), cacheOf(sample(99, 10), sample(10, 10)), "agent-gateway:review", NOW)).toMatchObject({ picked: "me", reason: "spill" })
  })
})

describe("helpers", () => {
  test("shellLine quotes the path", () => {
    const r = reg()
    expect(shellLine(r, { picked: "iu", reason: "", stale: false })).toBe("unset CLAUDE_CONFIG_DIR")
    expect(shellLine(r, { picked: "me", reason: "", stale: false })).toBe("export CLAUDE_CONFIG_DIR='/home/x/.claude-me'")
    expect(shellLine(r, { picked: "spill", reason: "", stale: false })).toBeNull()
    r.accounts.me.dir = "/home/x/my dir/it's"
    expect(shellLine(r, { picked: "me", reason: "", stale: false })).toBe(`export CLAUDE_CONFIG_DIR='/home/x/my dir/it'\\''s'`)
  })
  test("accountFromConfigDir", () => {
    expect(accountFromConfigDir(reg(), undefined)).toBe("iu")
    expect(accountFromConfigDir(reg(), "")).toBe("iu")
    expect(accountFromConfigDir(reg(), "/home/x/.claude-me")).toBe("me")
    expect(accountFromConfigDir(reg(), "/somewhere/else")).toBeNull()
  })
  test("refresh env strips credentials and blanks the base url", () => {
    expect(refreshEnv({ ANTHROPIC_API_KEY: "k", ANTHROPIC_AUTH_TOKEN: "t", CLAUDE_CODE_OAUTH_TOKEN: "o", CLAUDE_CONFIG_DIR: "/x", PATH: "/bin" }, null)).toEqual({ ANTHROPIC_BASE_URL: "", PATH: "/bin" })
    expect(refreshEnv({}, "/d").CLAUDE_CONFIG_DIR).toBe("/d")
  })
  test("pickLine accounts come from the registry", () => {
    const r = reg()
    r.accounts.c = { ...r.accounts.me }
    const l = pickLine(r, cacheOf(sample(1, 2)), "wave", { picked: "iu", reason: "home", stale: true }, NOW)
    expect(Object.keys(l).filter((k) => !["ts", "lane", "picked", "reason", "stale"].includes(k))).toEqual(["iu", "me", "c"])
    expect(l).toMatchObject({ stale: true, iu: { s: 1, w: 2 }, me: { s: null, w: null } })
  })
  test("sampleFromClaudeJson, and a payload that omits a window keeps what we know", () => {
    const blob = (utilization: object) => ({ cachedUsageUtilization: { fetchedAtMs: NOW, accountUuid: "u", utilization } })
    const full = sampleFromClaudeJson(blob({ five_hour: { utilization: 11, resets_at: "2026-10-24T13:50:00+00:00" }, seven_day: { utilization: 85, resets_at: "2026-10-28T16:00:00+00:00" } }))!
    expect(full).toMatchObject({ s: 11, w: 85, s_ts: NOW, w_ts: NOW, s_reset: Date.parse("2026-10-24T13:50:00Z") / 1000 })
    expect(sampleFromClaudeJson({})).toBeNull()
    expect(sampleFromClaudeJson(blob({ five_hour: null, seven_day: null }))).toBeNull()
    const onlyS = sampleFromClaudeJson(blob({ five_hour: { utilization: 20, resets_at: "2026-10-24T14:00:00+00:00" }, seven_day: null }))!
    expect(onlyS).toMatchObject({ s: 20, w: null, w_ts: null })
    const merged = mergeSample({ ...full, s_ts: NOW - 5000, w_ts: NOW - 5000 }, onlyS)
    expect(merged).toMatchObject({ s: 20, s_ts: NOW, w: 85, w_ts: NOW - 5000 })
  })
  test("mergeSample: an older window never overwrites a newer one", () => {
    const m = mergeSample(sample(50, 50), { ...sample(1, 1), s_ts: NOW - 120_000, w_ts: NOW - 120_000 })
    expect(m).toMatchObject({ s: 50, w: 50 })
  })
  test("an auth-failed account is neither due nor refreshed until a record clears the mark", () => {
    const c = { ...cacheOf(sample(1, 1, { age: 11 * 60_000 }), sample(1, 1, { age: 11 * 60_000 })), auth_failed: { me: true } }
    expect(dueIds(reg(), c, NOW)).toEqual(["iu"])
    const calls: string[][] = []
    refreshBeforePick({ reg: reg(), lane: "wave", now: NOW, cache: c, claim: (ids) => ids, runSync: (ids) => calls.push(ids), detach: (ids) => calls.push(ids) })
    expect(calls.flat()).not.toContain("me")
  })
  test("newestAge / dueIds", () => {
    expect(newestAge({ ...sample(1, 1), w_ts: NOW - 1000 }, NOW)).toBe(1000)
    expect(dueIds(reg(false), staleA(), NOW)).toEqual(["iu"])
    expect(dueIds(reg(), cacheOf(sample(1, 1)), NOW)).toEqual(["me"])
    expect(dueIds(reg(), cacheOf(sample(1, 1), sample(1, 1)), NOW)).toEqual([])
  })
})

describe("per-account files", () => {
  test("saveSample merges field-wise per window on disk", () => {
    const dir = tmp()
    saveSample("iu", sample(10, 20), dir)
    saveSample("iu", { s: null, w: 30, s_reset: null, w_reset: 1, s_ts: null, w_ts: NOW, src: "x" }, dir)
    expect(loadCache(dir).samples.iu).toMatchObject({ s: 10, w: 30, s_ts: NOW - 60_000, w_ts: NOW })
    rmSync(dir, { recursive: true })
  })
  test("partial record keeps the other window and its timestamp; a full one refreshes both", () => {
    const dir = tmp()
    saveSample("iu", sample(10, 40, { wReset: NOW / 1000 + 9 }), dir)
    recordSample("iu", { s: 20, s_reset: 5 }, NOW, dir)
    const x = loadCache(dir).samples.iu
    expect(x).toMatchObject({ s: 20, s_ts: NOW, w: 40, w_ts: NOW - 60_000, w_reset: NOW / 1000 + 9, src: "statusline" })
    recordSample("iu", { s: 1, w: 2, s_reset: 3, w_reset: 4 }, NOW + 1000, dir)
    expect(loadCache(dir).samples.iu).toMatchObject({ s: 1, w: 2, w_ts: NOW + 1000 })
    rmSync(dir, { recursive: true })
  })
  test("record clears auth_failed for that account only; exhausted keeps the max", () => {
    const dir = tmp()
    setAuthFailed("iu", true, NOW, dir)
    setAuthFailed("me", true, NOW, dir)
    recordSample("iu", { s: 1 }, NOW, dir)
    expect(loadCache(dir).auth_failed).toEqual({ me: true })
    markExhausted("iu", 100, dir)
    markExhausted("iu", 50, dir)
    expect(loadCache(dir).exhausted.iu).toBe(100)
    rmSync(dir, { recursive: true })
  })
  test("concurrent writers to different accounts and kinds lose nothing", async () => {
    const dir = tmp()
    const lib = join(import.meta.dir, "lib", "claude-accounts.ts")
    const run = (code: string) => Bun.spawn(["bun", "-e", `import * as L from ${JSON.stringify(lib)}; ${code}`], { env: { ...process.env, CLAUDE_ACCOUNTS_CACHE_DIR: dir }, stdout: "pipe", stderr: "pipe" })
    const ps = ["w", "x", "y", "z"].flatMap((id) => [run(`L.recordSample(${JSON.stringify(id)}, { s: 5, w: 6 }, Date.now())`), run(`L.markExhausted(${JSON.stringify(id)}, 99)`)])
    for (const p of ps) expect(await p.exited).toBe(0)
    const c = loadCache(dir)
    expect(Object.keys(c.samples).sort()).toEqual(["w", "x", "y", "z"])
    expect(Object.keys(c.exhausted).sort()).toEqual(["w", "x", "y", "z"])
    expect(readdirSync(dir).filter((f) => f.endsWith(".tmp"))).toEqual([])
    rmSync(dir, { recursive: true })
  })
})

describe("claimRefresh (O_EXCL claim file)", () => {
  test("the first claim wins, a second inside the 5-min budget gets nothing", () => {
    const dir = tmp()
    expect(claimRefresh(reg(false), ["iu"], NOW, staleA(), dir)).toEqual(["iu"])
    expect(claimRefresh(reg(false), ["iu"], NOW + 1000, staleA(), dir)).toEqual([])
    rmSync(dir, { recursive: true })
  })
  test("a claim older than 5 min is stale and replaced; releasing gives it back", () => {
    const dir = tmp()
    claimRefresh(reg(false), ["iu"], NOW, staleA(), dir)
    expect(claimRefresh(reg(false), ["iu"], NOW + 6 * 60_000, staleA(), dir)).toEqual(["iu"])
    releaseClaim("iu", dir)
    expect(claimRefresh(reg(false), ["iu"], NOW + 6 * 60_000 + 1, staleA(), dir)).toEqual(["iu"])
    rmSync(dir, { recursive: true })
  })
  test("only due, enabled, requested ids are claimed", () => {
    const dir = tmp()
    const stale2 = cacheOf(sample(1, 1, { age: 11 * 60_000 }), sample(1, 1, { age: 11 * 60_000 }))
    expect(claimRefresh(reg(false), ["iu", "me"], NOW, stale2, dir)).toEqual(["iu"])
    expect(claimRefresh(reg(), ["iu"], NOW, cacheOf(sample(1, 1)), dir)).toEqual([])
    rmSync(dir, { recursive: true })
  })
  test("two concurrent claimers: exactly one wins", async () => {
    const dir = tmp()
    const lib = join(import.meta.dir, "lib", "claude-accounts.ts")
    const code = `const reg = { accounts: { iu: { dir: null, plan: "x", units: { session: 1, weekly: 1 }, homeLanes: [], enabled: true } } }; console.log(JSON.stringify(L.claimRefresh(reg, ["iu"], Date.now(), L.emptyCache())))`
    const ps = Array.from({ length: 6 }, () => Bun.spawn(["bun", "-e", `import * as L from ${JSON.stringify(lib)}; ${code}`], { env: { ...process.env, CLAUDE_ACCOUNTS_CACHE_DIR: dir }, stdout: "pipe", stderr: "pipe" }))
    const outs = await Promise.all(ps.map(async (p) => (await p.exited, (await new Response(p.stdout).text()).trim())))
    expect(outs.filter((o) => o === '["iu"]').length).toBe(1)
    expect(outs.filter((o) => o === "[]").length).toBe(5)
    rmSync(dir, { recursive: true })
  })
})

const ok: SpawnResult = { status: 0, stdout: "{}", stderr: "" }

describe("runRefresh", () => {
  function harness(spawn: Spawner, read: () => Sample | null = () => null) {
    const dir = tmp()
    claimRefresh(reg(false), ["iu"], NOW, staleA(), dir) // pre-claimed by the caller
    const spawned: string[] = []
    runRefresh({
      reg: reg(false), claudeBin: "claude", baseEnv: {}, timeoutS: 75, now: () => NOW, ids: ["iu"], dir,
      spawn: (c, a, e) => { spawned.push(e.env.CLAUDE_CONFIG_DIR ?? "unset"); return spawn(c, a, e) }, readSample: read,
    })
    const claimed = !claimRefresh(reg(false), ["iu"], NOW + 1000, staleA(), dir).length
    const cache = loadCache(dir)
    rmSync(dir, { recursive: true })
    return { cache, spawned, claimHeld: claimed }
  }
  test("success saves the sample, keeps the claim as the budget", () => {
    const h = harness(() => ok, () => sample(33, 44))
    expect(h.spawned).toEqual(["unset"])
    expect(h.cache.samples.iu).toMatchObject({ s: 33, w: 44 })
    expect(h.claimHeld).toBe(true)
  })
  test("missing binary releases the claim and sets no auth verdict", () => {
    const h = harness(() => ({ status: null, stdout: "", stderr: "", error: { code: "ENOENT", message: "spawn claude ENOENT" } }))
    expect(h.claimHeld).toBe(false)
    expect(h.cache.auth_failed.iu).toBeUndefined()
  })
  test("auth failure marks auth_failed and keeps the claim", () => {
    const h = harness(() => ({ status: 1, stdout: "", stderr: "Not logged in · Please run /login" }))
    expect(h.cache.auth_failed.iu).toBe(true)
    expect(h.claimHeld).toBe(true)
  })
  test("timeout keeps the claim and records no auth verdict", () => {
    const h = harness(() => ({ status: null, stdout: "", stderr: "", error: { code: "ETIMEDOUT", message: "timed out" } }))
    expect(h.claimHeld).toBe(true)
    expect(h.cache.auth_failed.iu).toBeUndefined()
  })
})

describe("refreshBeforePick", () => {
  function run(cache: Cache, lane = "wave", enabledB = false) {
    const dir = tmp()
    const calls = { sync: [] as string[][], detach: [] as string[][] }
    const r = refreshBeforePick({
      reg: reg(enabledB), lane, now: NOW, cache,
      claim: (ids) => claimRefresh(reg(enabledB), ids, NOW, cache, dir),
      runSync: (ids) => calls.sync.push(ids), detach: (ids) => calls.detach.push(ids),
    })
    const files = readdirSync(dir)
    rmSync(dir, { recursive: true })
    return { r, calls, files }
  }
  test("stale sample: no blocking refresh, claimed and detached", () => {
    const { r, calls, files } = run(staleA())
    expect(r).toEqual({ sync: [], background: ["iu"] })
    expect(calls).toEqual({ sync: [], detach: [["iu"]] })
    expect(files).toEqual(["iu.refresh.claim"])
  })
  test("fresh sample schedules nothing", () => {
    expect(run(cacheOf(sample(10, 10))).r).toEqual({ sync: [], background: [] })
  })
  test("no usable sample on a bulk lane: synchronous; a stale neighbour in the background", () => {
    const { r, calls } = run(cacheOf(undefined, sample(10, 10, { age: 11 * 60_000 })), "wave", true)
    expect(r).toEqual({ sync: ["iu"], background: ["me"] })
    expect(calls).toEqual({ sync: [["iu"]], detach: [["me"]] })
  })
  test("a sample older than 6 h counts as no sample", () => {
    expect(run(cacheOf(sample(10, 10, { age: 7 * H * 1000 }))).r).toEqual({ sync: ["iu"], background: [] })
  })
  test("interactive returns before any claim: nothing is written", () => {
    let claimed = false
    const r = refreshBeforePick({
      reg: reg(), lane: "interactive", now: NOW, cache: emptyCache(),
      claim: () => { claimed = true; return ["iu"] }, runSync: () => { throw new Error("sync") }, detach: () => { throw new Error("detach") },
    })
    expect(r).toEqual({ sync: [], background: [] })
    expect(claimed).toBe(false)
  })
})

describe("CLI (isolated HOME)", () => {
  const CLI = join(import.meta.dir, "claude-account.ts")
  const home = tmp()
  const bin = join(home, "bin")
  const marker = join(home, "claude-ran")
  const dir = join(home, "cache")
  mkdirSync(bin)
  writeFileSync(join(bin, "claude"), `#!/bin/sh\ntouch ${marker}\nexit 0\n`)
  chmodSync(join(bin, "claude"), 0o755)
  const registry = join(home, "registry.json")
  writeFileSync(registry, JSON.stringify(reg(false))) // iu only: the second account is disabled
  const base = { ...(process.env as Record<string, string>), HOME: home, CLAUDE_ACCOUNTS_REGISTRY: registry, CLAUDE_ACCOUNTS_CACHE_DIR: dir, CLAUDE_ACCOUNTS_PICKS: join(home, "picks.jsonl"), PATH: `${bin}:${process.env.PATH}` }
  delete (base as Record<string, string | undefined>).CLAUDE_CONFIG_DIR
  const cli = (args: string[], env: Record<string, string> = {}) => {
    const t = Date.now()
    const r = Bun.spawnSync(["bun", CLI, ...args], { env: { ...base, ...env }, stdout: "pipe", stderr: "pipe" })
    return { rc: r.exitCode, out: r.stdout.toString().trim(), err: r.stderr.toString(), ms: Date.now() - t }
  }
  const seed = (ageMs: number) => {
    rmSync(marker, { force: true })
    rmSync(dir, { recursive: true, force: true })
    const ts = Date.now() - ageMs
    saveSample("iu", { s: 5, w: 5, s_reset: null, w_reset: null, s_ts: ts, w_ts: ts, src: "t" }, dir)
  }

  test("pick prints the line; interactive and wave both give unset", () => {
    seed(60_000)
    expect(cli(["pick", "--lane", "wave"])).toMatchObject({ rc: 0, out: "unset CLAUDE_CONFIG_DIR" })
    expect(cli(["pick", "--lane", "interactive"])).toMatchObject({ rc: 0, out: "unset CLAUDE_CONFIG_DIR" })
  })
  test("pick with an unreadable registry still answers, and says why on stderr", () => {
    const r = cli(["pick", "--lane", "wave"], { CLAUDE_ACCOUNTS_REGISTRY: join(home, "missing.json") })
    expect(r).toMatchObject({ rc: 4, out: "unset CLAUDE_CONFIG_DIR" })
    expect(r.err).toContain("registry unreadable")
    expect(cli(["pick", "--lane", "wave", "--why"], { CLAUDE_ACCOUNTS_REGISTRY: join(home, "missing.json") }).out).toContain("reason=registry-error")
  })
  test("a pick with an unwritable cache dir still prints a line", () => {
    seed(20 * 60_000)
    writeFileSync(join(home, "notadir"), "")
    const r = cli(["pick", "--lane", "wave"], { CLAUDE_ACCOUNTS_CACHE_DIR: join(home, "notadir") })
    expect(r.out).toBe("spill") // nothing readable -> the bulk spill signal, never silence
    expect(r.rc).toBe(3)
    expect(r.err).toContain("refresh skipped")
  })
  test("usage --json keeps its shape", () => {
    seed(60_000)
    const j = JSON.parse(cli(["usage", "--json"]).out)
    expect(Object.keys(j.accounts[0]).sort()).toEqual(
      ["age_s", "auth_ok", "enabled", "exhausted_until", "five_hour", "five_hour_age_s", "five_hour_resets_at", "id", "plan", "seven_day", "seven_day_age_s", "seven_day_resets_at", "source"].sort(),
    )
    expect(j.default_account).toBe("iu")
    expect(j.accounts[0]).toMatchObject({ id: "iu", five_hour: 5, seven_day: 5, auth_ok: true })
  })
  test("account / --badge: unregistered dir prints ?, unset prints the id", () => {
    expect(cli(["account"]).out).toBe("iu")
    expect(cli(["account", "--badge"]).out).toBe("")
    expect(cli(["account"], { CLAUDE_CONFIG_DIR: "/nowhere" }).out).toBe("?")
    expect(cli(["account", "--badge"], { CLAUDE_CONFIG_DIR: "/nowhere" }).out).toBe("?")
  })
  test("env: valid account, unknown id, disabled account", () => {
    expect(cli(["env", "iu"])).toMatchObject({ rc: 0, out: "unset CLAUDE_CONFIG_DIR" })
    expect(cli(["env", "nope"]).rc).toBe(2)
    expect(cli(["env"]).rc).toBe(2)
    const both = join(home, "both.json")
    writeFileSync(both, JSON.stringify(reg(true)))
    expect(cli(["env", "me"], { CLAUDE_ACCOUNTS_REGISTRY: both })).toMatchObject({ rc: 0, out: "export CLAUDE_CONFIG_DIR='/home/x/.claude-me'" })
    expect(cli(["env", "me"]).rc).toBe(2) // disabled in the default fixture
  })
  test("record and exhausted write their own files", () => {
    seed(60_000)
    expect(cli(["record", "--account", "iu", "--s", "33", "--s-reset", "1800000000"]).rc).toBe(0)
    expect(cli(["exhausted", "--account", "iu", "--until", "1800000999"]).rc).toBe(0)
    const c = loadCache(dir)
    expect(c.samples.iu).toMatchObject({ s: 33, w: 5 })
    expect(c.exhausted.iu).toBe(1800000999)
  })
  test("refresh --ids applies the due filter; --claimed bypasses the claim", () => {
    seed(60_000)
    expect(cli(["refresh", "--ids", "iu"]).rc).toBe(0)
    expect(existsSync(marker)).toBe(false)
    expect(cli(["refresh", "--claimed", "me"]).rc).toBe(0) // disabled, even when claimed
    expect(existsSync(marker)).toBe(false)
    expect(cli(["refresh", "--claimed", "iu"]).rc).toBe(0)
    expect(existsSync(marker)).toBe(true)
    seed(20 * 60_000)
    expect(cli(["refresh", "--ids", "iu"]).rc).toBe(0)
    expect(existsSync(marker)).toBe(true)
    expect(existsSync(join(dir, "iu.refresh.claim"))).toBe(true)
    rmSync(home, { recursive: true, force: true })
  })
})

describe("type guards", () => {
  const dir = tmp()
  const regFile = (accounts: unknown) => {
    const p = join(dir, `reg-${Math.random().toString(36).slice(2)}.json`)
    writeFileSync(p, JSON.stringify({ accounts }))
    return p
  }
  const good = { dir: null, plan: "p", units: { session: 1, weekly: 1 }, homeLanes: ["x"], enabled: true }
  test("loadRegistry accepts a good registry and rejects malformed accounts", () => {
    expect(Object.keys(loadRegistry(regFile({ iu: good })).accounts)).toEqual(["iu"])
    expect(() => loadRegistry(regFile({ iu: { ...good, enabled: "yes" } }))).toThrow(/malformed/)
    expect(() => loadRegistry(regFile({ iu: { ...good, homeLanes: "wave" } }))).toThrow(/malformed/)
    expect(() => loadRegistry(regFile({ iu: { ...good, units: {} } }))).toThrow(/malformed/)
    expect(() => loadRegistry(regFile({ "a/b": good }))).toThrow(/bad account id/)
    expect(() => loadRegistry(regFile({ spill: good }))).toThrow(/bad account id/) // the pick's no-headroom signal
    expect(() => loadRegistry(regFile({ me: { ...good, dir: "~/.claude-me" } }))).toThrow(/default/)
    expect(() => loadRegistry(regFile(null))).toThrow()
  })
  test("loadCache drops malformed sample files", () => {
    const d = tmp()
    saveSample("iu", sample(1, 2), d)
    writeFileSync(join(d, "b.sample.json"), JSON.stringify({ s: "lots" }))
    writeFileSync(join(d, "c.sample.json"), "not json")
    expect(Object.keys(loadCache(d).samples)).toEqual(["iu"])
    expect(isSample({ ...sample(1, 2), s_ts: "x" })).toBe(false)
    rmSync(d, { recursive: true })
  })
  test("claimRefresh: an unreadable claim is a lost race, other ids still proceed", () => {
    const d = tmp()
    mkdirSync(join(d, "iu.refresh.claim")) // EEXIST, and readFileSync on a directory throws
    const r = reg()
    const stale2 = cacheOf(sample(1, 1, { age: 11 * 60_000 }), sample(1, 1, { age: 11 * 60_000 }))
    expect(claimRefresh(r, ["iu", "me"], NOW, stale2, d)).toEqual(["me"])
    rmSync(d, { recursive: true })
  })
})

import { describe, expect, test } from "bun:test"
import { createHash } from "node:crypto"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  type Cache, type HttpGet, type Registry, type Sample, type SpawnResult, type Spawner, accountFromConfigDir, claimRefresh, dueIds, emptyCache, homeIds, loadCache, markExhausted,
  mergeSample, newestAge, pick, sessionAccount, pickLine, recordSample, refreshBeforePick, refreshEnv, releaseClaim, runRefresh, isSample, loadRegistry, sampleFromClaudeJson, sampleFromOAuthUsage, saveSample, setAuthFailed, shellLine, keychainService, tokenFromCredentials, oauthUsageHeaders, latestSessionId,
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

describe("pick rule v1.1 pace guard", () => {
  const D = 24 * H
  const iuOver = sample(10, 88, { wReset: NOW / 1000 + 3.9 * D }) // pace 44
  const meCalm = sample(10, 2, { wReset: NOW / 1000 + 6.5 * D }) // pace 7
  test("over-pace home yields to an under-pace other, every lane", () => {
    expect(pick(reg(), cacheOf(iuOver, meCalm), "interactive", NOW)).toMatchObject({ picked: "me", reason: "pace" })
    expect(pick(reg(), cacheOf(iuOver, meCalm), "agent-gateway:review", NOW)).toMatchObject({ picked: "me", reason: "pace" })
  })
  test("both over pace -> home", () => {
    const meOver = sample(10, 60, { wReset: NOW / 1000 + 6.5 * D })
    expect(pick(reg(), cacheOf(iuOver, meOver), "interactive", NOW)).toMatchObject({ picked: "iu", reason: "home" })
  })
  test("other ineligible -> home", () => {
    expect(pick(reg(), cacheOf(iuOver, sample(95, 2, { wReset: NOW / 1000 + 6.5 * D })), "interactive", NOW)).toMatchObject({ picked: "iu", reason: "home" })
  })
  test("home without a weekly reset is never over pace", () => {
    expect(pick(reg(), cacheOf({ ...sample(10, 88), w_reset: null }, meCalm), "interactive", NOW)).toMatchObject({ picked: "iu", reason: "home" })
  })
  test("bulk lane already on me is unaffected", () => {
    expect(pick(reg(), cacheOf(iuOver, meCalm), "wave", NOW)).toMatchObject({ picked: "me", reason: "home" })
  })
  test("expiring capacity still wins for bulk lanes", () => {
    expect(pick(reg(), cacheOf(iuOver, sample(10, 2, { wReset: NOW / 1000 + 5 * H })), "wave", NOW)).toMatchObject({ picked: "me", reason: "expiring-capacity" })
  })
})

describe("sessionAccount", () => {
  const line = (session: string, account: string | null) => JSON.stringify({ event: "session_env", data: { session, account } })
  test("newest session_env line for the session wins; unknown and malformed ids give null", () => {
    const d = tmp()
    writeFileSync(join(d, "2026-10-23.jsonl"), `${line("abc-1", "iu")}\n`)
    writeFileSync(join(d, "2026-10-24.jsonl"), `${line("abc-1", "me")}\nnot json\n${line("zzz-9", "iu")}\n`)
    expect(sessionAccount("abc-1", d)).toBe("me")
    expect(sessionAccount("zzz-9", d)).toBe("iu")
    expect(sessionAccount("nope-0", d)).toBeNull()
    expect(sessionAccount("../x", d)).toBeNull()
    expect(sessionAccount("abc-1", join(d, "missing"))).toBeNull()
  })
  test("a newer line without an account wins over an older account (resumed on the default dir)", () => {
    const d = tmp()
    writeFileSync(join(d, "2026-10-23.jsonl"), `${line("abc-1", "me")}\n`)
    writeFileSync(join(d, "2026-10-24.jsonl"), `${line("abc-1", null)}\n`)
    expect(sessionAccount("abc-1", d)).toBeNull()
  })
})

describe("latestSessionId", () => {
  test("newest transcript by mtime in the cwd's project dir; encoding, missing dir and non-transcripts", () => {
    const projects = tmp()
    const cwd = "/Users/x/.herdr/worktrees/my_repo.v2"
    const d = join(projects, "-Users-x--herdr-worktrees-my-repo-v2")
    mkdirSync(d, { recursive: true })
    writeFileSync(join(d, "aaaa-1.jsonl"), "")
    writeFileSync(join(d, "bbbb-2.jsonl"), "")
    writeFileSync(join(d, "notes.txt"), "")
    utimesSync(join(d, "aaaa-1.jsonl"), 2000, 2000)
    utimesSync(join(d, "bbbb-2.jsonl"), 1000, 1000)
    utimesSync(join(d, "notes.txt"), 9000, 9000)
    expect(latestSessionId(projects, cwd)).toBe("aaaa-1")
    expect(latestSessionId(projects, "/nowhere")).toBeNull()
    rmSync(projects, { recursive: true })
  })
})

describe("pick rule v1.2 session balance", () => {
  test("home 5h much fuller than the other -> the emptier window", () => {
    expect(pick(reg(), cacheOf(sample(60, 10), sample(5, 10)), "interactive", NOW)).toMatchObject({ picked: "me", reason: "session" })
    expect(pick(reg(), cacheOf(sample(5, 10), sample(60, 10)), "wave", NOW)).toMatchObject({ picked: "iu", reason: "session" })
  })
  test("a stale 5h reading never triggers the move", () => {
    const old = { ...sample(5, 10), s_ts: NOW - 7 * H * 1000 }
    expect(pick(reg(), cacheOf(sample(60, 10), old), "interactive", NOW)).toMatchObject({ picked: "iu", reason: "home" })
  })
  test("within the margin the home account stays", () => {
    expect(pick(reg(), cacheOf(sample(30, 10), sample(15, 10)), "interactive", NOW)).toMatchObject({ picked: "iu", reason: "home" })
  })
  test("an over-pace other never receives the session move", () => {
    const meOver = sample(0, 80, { wReset: NOW / 1000 + 6.5 * 24 * H })
    expect(pick(reg(), cacheOf(sample(60, 10), meOver), "interactive", NOW)).toMatchObject({ picked: "iu", reason: "home" })
  })
})

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
  test("an auth-failed account is retried after the cooldown, in the background only; --ids bypasses it", async () => {
    const stale = (at: number) => ({ ...cacheOf(sample(1, 1, { age: 11 * 60_000 }), sample(1, 1, { age: 11 * 60_000 })), auth_failed: { me: true }, auth_failed_at: { me: at } })
    expect(dueIds(reg(), stale(NOW - 60_000), NOW)).toEqual(["iu"]) // marked a minute ago: cooling down
    expect(dueIds(reg(), stale(NOW - 31 * 60_000), NOW)).toEqual(["iu", "me"]) // cooldown over: due again
    expect(dueIds(reg(), stale(NOW - 60_000), NOW, true)).toEqual(["iu", "me"]) // manual retry
    const calls = { sync: [] as string[][], detach: [] as string[][] }
    const run = (c: Cache) => refreshBeforePick({ reg: reg(), lane: "wave", now: NOW, cache: c, claim: (ids) => ids, runSync: (ids) => { calls.sync.push(ids) }, detach: (ids) => { calls.detach.push(ids) } })
    expect(await run(stale(NOW - 31 * 60_000))).toEqual({ sync: [], background: ["iu", "me"] }) // a retry never blocks a pick
    expect(await run(stale(NOW - 60_000))).toEqual({ sync: [], background: ["iu"] })
  })
  test("a failed refresh restarts the cooldown; a successful one clears the mark", () => {
    const dir = tmp()
    setAuthFailed("me", true, NOW, dir)
    setAuthFailed("me", true, NOW + 10 * 60_000, dir)
    expect(loadCache(dir).auth_failed_at.me).toBe(NOW + 10 * 60_000)
    setAuthFailed("me", false, NOW + 11 * 60_000, dir)
    expect(loadCache(dir).auth_failed.me).toBeUndefined()
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
  test("all: claims every enabled account whatever its sample age, the 5-min budget still holds", () => {
    const dir = tmp()
    const fresh = cacheOf(sample(1, 1), sample(1, 1))
    expect(claimRefresh(reg(), ["iu", "me"], NOW, fresh, dir)).toEqual([]) // not due
    expect(claimRefresh(reg(), ["iu", "me"], NOW, fresh, dir, false, true)).toEqual(["iu", "me"])
    expect(claimRefresh(reg(), ["iu", "me"], NOW + 1000, fresh, dir, false, true)).toEqual([]) // claimed a second ago
    expect(claimRefresh(reg(false), ["iu", "me"], NOW + 6 * 60_000, fresh, dir, false, true)).toEqual(["iu"]) // disabled stays out
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

// Captured shape of GET /api/oauth/usage (2026-10-25, trimmed): extra keys and null windows are part of the contract.
const OAUTH_BODY = {
  five_hour: { utilization: 3.0, resets_at: "2026-10-24T23:49:59.964874+00:00", limit_dollars: null, used_dollars: null, remaining_dollars: null, locked_reason: null },
  seven_day: { utilization: 89.0, resets_at: "2026-10-28T15:59:59.964894+00:00", limit_dollars: null, used_dollars: null, remaining_dollars: null, locked_reason: null },
  seven_day_oauth_apps: null, seven_day_opus: null, seven_day_sonnet: null,
  iguana_necktie: { utilization: 0.0, resets_at: "2026-11-05T07:59:00+00:00", limit_dollars: 250, used_dollars: 0.0, remaining_dollars: 250.0, locked_reason: null },
}
const TOKEN = "sk-ant-oat01-SECRET-TOKEN-VALUE"
const CREDS = JSON.stringify({ claudeAiOauth: { accessToken: TOKEN, refreshToken: "r", expiresAt: 1 }, mcpOAuth: {} })

describe("OAuth usage source", () => {
  test("keychainService: default dir is the bare name, others the first 8 hex of sha256(abs dir)", () => {
    expect(keychainService(null)).toBe("Claude Code-credentials")
    const want = `Claude Code-credentials-${createHash("sha256").update("/home/x/.claude-me").digest("hex").slice(0, 8)}`
    expect(keychainService("/home/x/.claude-me")).toBe(want)
    expect(keychainService("/home/x/.claude-me/")).toBe(want) // resolve() drops the trailing slash
  })
  test("tokenFromCredentials reads claudeAiOauth.accessToken and rejects everything else", () => {
    expect(tokenFromCredentials(CREDS)).toBe(TOKEN)
    expect(tokenFromCredentials("not json")).toBeNull()
    expect(tokenFromCredentials("{}")).toBeNull()
    expect(tokenFromCredentials(JSON.stringify({ claudeAiOauth: { accessToken: "" } }))).toBeNull()
    expect(tokenFromCredentials(JSON.stringify({ claudeAiOauth: { accessToken: 5 } }))).toBeNull()
  })
  test("request shape matches fetch_usage.py", () => {
    expect(oauthUsageHeaders("T")).toEqual({ Authorization: "Bearer T", "anthropic-beta": "oauth-2025-04-20", Accept: "application/json" })
  })
  test("sampleFromOAuthUsage maps utilization/resets_at, stamps both windows with now", () => {
    expect(sampleFromOAuthUsage(OAUTH_BODY, NOW)).toEqual({
      s: 3, s_reset: Math.round(Date.parse("2026-10-24T23:49:59.964874+00:00") / 1000), s_ts: NOW,
      w: 89, w_reset: Math.round(Date.parse("2026-10-28T15:59:59.964894+00:00") / 1000), w_ts: NOW, src: "oauth",
    })
  })
  test("a window the body omits stays null; nothing usable or a non-object is no sample", () => {
    const onlyW = sampleFromOAuthUsage({ seven_day: { utilization: 10, resets_at: "2026-10-28T16:00:00+00:00" } }, NOW)!
    expect(onlyW).toMatchObject({ s: null, s_ts: null, s_reset: null, w: 10, w_ts: NOW })
    expect(sampleFromOAuthUsage({ five_hour: null, seven_day: null }, NOW)).toBeNull()
    expect(sampleFromOAuthUsage({ error: { type: "rate_limit_error" } }, NOW)).toBeNull()
    expect(sampleFromOAuthUsage(null, NOW)).toBeNull()
    expect(sampleFromOAuthUsage("x", NOW)).toBeNull()
    expect(sampleFromOAuthUsage([OAUTH_BODY], NOW)).toBeNull()
    expect(sampleFromOAuthUsage({ five_hour: "high", seven_day: [] }, NOW)).toBeNull()
    expect(sampleFromOAuthUsage({ five_hour: { resets_at: "2026-10-24T23:49:59+00:00" }, seven_day: { utilization: "9", resets_at: "2026-10-28T16:00:00+00:00" } }, NOW)).toBeNull() // missing / non-numeric utilization
    expect(sampleFromOAuthUsage({ five_hour: { utilization: 3, resets_at: 1800000000 } }, NOW)).toBeNull() // resets_at must be a string
    expect(sampleFromOAuthUsage({ five_hour: { utilization: 3, resets_at: "2026-10-24T23:49:59+00:00" }, seven_day: { utilization: "9" } }, NOW)).toMatchObject({ s: 3, w: null }) // one bad window does not drop the good one
  })
})

describe("runRefresh", () => {
  interface Setup {
    keychain?: SpawnResult
    http?: HttpGet
    auth?: SpawnResult
    claudeStart?: SpawnResult // overrides the `auth status` answer entirely (ENOENT, timeout)
  }
  const kcOk: SpawnResult = { status: 0, stdout: CREDS + "\n", stderr: "" }
  const http200: HttpGet = async () => ({ status: 200, json: OAUTH_BODY })
  const loggedIn = (v: boolean): SpawnResult => ({ status: 0, stdout: JSON.stringify({ loggedIn: v }), stderr: "" })

  async function harness(t: Setup, o: { ids?: string[]; preAuthFailed?: string[]; seed?: Sample } = {}) {
    const dir = tmp()
    const ids = o.ids ?? ["iu"]
    claimRefresh(reg(), ids, NOW, cacheOf(sample(1, 1, { age: 11 * 60_000 }), sample(1, 1, { age: 11 * 60_000 })), dir) // pre-claimed by the caller
    for (const id of o.preAuthFailed ?? []) setAuthFailed(id, true, NOW - 3600_000, dir)
    if (o.seed) for (const id of ids) saveSample(id, o.seed, dir)
    const calls: { cmd: string; args: string[]; configDir: string | undefined }[] = []
    const urls: { url: string; headers: Record<string, string>; timeoutMs: number }[] = []
    const logs: string[] = []
    const results = await runRefresh({
      reg: reg(), claudeBin: "claude", baseEnv: { PATH: "/bin" }, now: () => NOW, ids, dir, log: (m) => logs.push(m),
      spawn: (cmd, args, e) => {
        calls.push({ cmd, args, configDir: e.env.CLAUDE_CONFIG_DIR })
        if (cmd === "/usr/bin/security") return t.keychain ?? kcOk
        return t.claudeStart ?? t.auth ?? ok
      },
      httpGet: async (url, headers, timeoutMs) => {
        urls.push({ url, headers, timeoutMs })
        return (t.http ?? http200)(url, headers, timeoutMs)
      },
    })
    const claimHeld = !claimRefresh(reg(), ["iu"], NOW + 1000, cacheOf(sample(1, 1, { age: 11 * 60_000 })), dir).length
    const cache = loadCache(dir)
    const files = readdirSync(dir).map((f) => readFileSync(join(dir, f), "utf8")).join("\n")
    rmSync(dir, { recursive: true })
    return { results, cache, calls, urls, logs, claimHeld, files }
  }

  test("endpoint sample: saved, fresh, claim kept as the budget, claude never spawned", async () => {
    const h = await harness({})
    expect(h.results).toEqual({ iu: "fresh" })
    expect(h.cache.samples.iu).toMatchObject({ s: 3, w: 89, s_ts: NOW, src: "oauth" })
    expect(h.calls.map((c) => c.cmd)).toEqual(["/usr/bin/security"])
    expect(h.calls[0].args).toEqual(["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    expect(h.urls).toEqual([{ url: "https://api.anthropic.com/api/oauth/usage", headers: oauthUsageHeaders(TOKEN), timeoutMs: 10_000 }])
    expect(h.claimHeld).toBe(true)
  })
  test("a non-default account reads its own suffixed Keychain service", async () => {
    const h = await harness({}, { ids: ["me"] })
    expect(h.calls[0].args[2]).toBe(keychainService("/home/x/.claude-me"))
    expect(h.results).toEqual({ me: "fresh" })
  })
  test("a sample clears a recorded auth failure", async () => {
    const h = await harness({}, { preAuthFailed: ["iu"] })
    expect(h.cache.auth_failed.iu).toBeUndefined()
  })
  test("the token never reaches the logs or the cache files", async () => {
    const bad = await harness({ http: async () => { throw new Error(`boom ${TOKEN}`) } })
    const ok200 = await harness({})
    for (const h of [bad, ok200]) {
      expect(h.logs.join("\n")).not.toContain(TOKEN)
      expect(h.files).not.toContain(TOKEN)
    }
  })
  test("no sample + `auth status` loggedIn=true clears the auth mark and answers auth-ok", async () => {
    const h = await harness({ keychain: { status: 44, stdout: "", stderr: "The specified item could not be found" }, auth: loggedIn(true) }, { preAuthFailed: ["iu"], seed: sample(1, 1, { age: 2 * H * 1000 }) })
    expect(h.results).toEqual({ iu: "auth-ok" })
    expect(h.cache.auth_failed.iu).toBeUndefined()
    expect(h.calls.map((c) => c.args[0])).toEqual(["find-generic-password", "auth"])
    expect(h.urls).toEqual([]) // no token, no request
  })
  test("no sample + loggedIn=false sets the auth mark", async () => {
    const h = await harness({ keychain: { status: 44, stdout: "", stderr: "" }, auth: loggedIn(false) })
    expect(h.results).toEqual({ iu: "auth-failed" })
    expect(h.cache.auth_failed.iu).toBe(true)
    expect(h.claimHeld).toBe(true)
  })
  test("auth status runs under that account's CLAUDE_CONFIG_DIR (unset for the default)", async () => {
    const me = await harness({ keychain: { status: 44, stdout: "", stderr: "" }, auth: loggedIn(true) }, { ids: ["me"] })
    expect(me.calls[1]).toMatchObject({ args: ["auth", "status"], configDir: "/home/x/.claude-me" })
    const iu = await harness({ keychain: { status: 44, stdout: "", stderr: "" }, auth: loggedIn(true) })
    expect(iu.calls[1].configDir).toBeUndefined()
  })
  test.each([
    ["HTTP 429", async () => ({ status: 429, json: { error: "rate" } })],
    ["HTTP 401", async () => ({ status: 401, json: { error: "unauthorized" } })],
    ["unparseable body", async () => ({ status: 200, json: null })],
    ["network error", async () => { throw new Error("ECONNRESET") }],
  ] as [string, HttpGet][])("endpoint failure (%s) leaves the auth mark alone and falls through to the verdict", async (_n, http) => {
    const unknown = await harness({ http, auth: { status: 0, stdout: "", stderr: "" } }, { preAuthFailed: ["iu"] })
    expect(unknown.results).toEqual({ iu: "unresolved" })
    expect(unknown.cache.auth_failed.iu).toBe(true) // untouched: only a verdict or a sample moves it
    expect(unknown.cache.samples.iu).toBeUndefined()
    const ok2 = await harness({ http, auth: loggedIn(true) }, { seed: sample(1, 1, { age: 2 * H * 1000 }) })
    expect(ok2.results).toEqual({ iu: "auth-ok" })
    expect(ok2.cache.auth_failed.iu).toBeUndefined()
  })
  test("logged in but no sample and the stored one older than 6 h (or missing) is `stale`, and the log names the account and age", async () => {
    const down: HttpGet = async () => ({ status: 404, json: null })
    const old = await harness({ http: down, auth: loggedIn(true) }, { seed: sample(1, 1, { age: 7 * H * 1000 }) })
    expect(old.results).toEqual({ iu: "stale" })
    expect(old.cache.auth_failed.iu).toBeUndefined() // the login is fine; only the feed is dying
    expect(old.logs.join("\n")).toMatch(/refresh iu: logged in .* 7 h old/)
    const none = await harness({ http: down, auth: loggedIn(true) })
    expect(none.results).toEqual({ iu: "stale" })
    expect(none.logs.join("\n")).toContain("missing")
    const young = await harness({ http: down, auth: loggedIn(true) }, { seed: sample(1, 1, { age: 5 * H * 1000 }) })
    expect(young.results).toEqual({ iu: "auth-ok" })
  })
  test("endpoint failure alone never sets the auth mark", async () => {
    const h = await harness({ http: async () => ({ status: 401, json: null }), auth: { status: 0, stdout: "", stderr: "" } })
    expect(h.cache.auth_failed.iu).toBeUndefined()
  })
  test("keychain denied (locked) is no sample and no auth mark", async () => {
    const h = await harness({ keychain: { status: 36, stdout: "", stderr: "User interaction is not allowed." }, auth: { status: 0, stdout: "", stderr: "" } })
    expect(h.results).toEqual({ iu: "unresolved" })
    expect(h.cache.auth_failed.iu).toBeUndefined()
    expect(h.logs.join("\n")).toContain("User interaction is not allowed.")
  })
  test("missing claude binary releases the claim, no verdict", async () => {
    const h = await harness({ keychain: { status: 44, stdout: "", stderr: "" }, claudeStart: { status: null, stdout: "", stderr: "", error: { code: "ENOENT", message: "spawn claude ENOENT" } } })
    expect(h.results).toEqual({ iu: "unresolved" })
    expect(h.claimHeld).toBe(false)
    expect(h.cache.auth_failed.iu).toBeUndefined()
  })
  test("any other spawn error releases the claim and logs its code", async () => {
    const h = await harness({ keychain: { status: 44, stdout: "", stderr: "" }, claudeStart: { status: null, stdout: "", stderr: "", error: { code: "EACCES", message: "spawn claude EACCES" } } })
    expect(h.results).toEqual({ iu: "unresolved" })
    expect(h.claimHeld).toBe(false)
    expect(h.logs.join("\n")).toContain("EACCES")
  })
  test("`auth status` timeout keeps the claim, no verdict", async () => {
    const h = await harness({ keychain: { status: 44, stdout: "", stderr: "" }, claudeStart: { status: null, stdout: "", stderr: "", error: { code: "ETIMEDOUT", message: "timed out" } } })
    expect(h.results).toEqual({ iu: "unresolved" })
    expect(h.claimHeld).toBe(true)
    expect(h.cache.auth_failed.iu).toBeUndefined()
  })
  test("each account is classified on its own", async () => {
    const dir = tmp()
    const r = await runRefresh({
      reg: reg(), claudeBin: "claude", baseEnv: {}, now: () => NOW, ids: ["iu", "me"], dir,
      spawn: (cmd, a, e) => (cmd === "/usr/bin/security" ? (a[2] === "Claude Code-credentials" ? { status: 0, stdout: CREDS, stderr: "" } : { status: 44, stdout: "", stderr: "" }) : e.env.CLAUDE_CONFIG_DIR ? loggedIn(false) : ok),
      httpGet: async () => ({ status: 200, json: OAUTH_BODY }),
    })
    rmSync(dir, { recursive: true })
    expect(r).toEqual({ iu: "fresh", me: "auth-failed" })
  })
})

describe("statusline record proves the login", () => {
  test("a record carrying rate_limits clears a failed mark; the mark can be set again by a verdict", () => {
    const dir = tmp()
    setAuthFailed("me", true, NOW, dir)
    expect(loadCache(dir).auth_failed.me).toBe(true)
    recordSample("me", { s: 12, w: 30, s_reset: NOW / 1000 + 100, w_reset: NOW / 1000 + 1000 }, NOW + 1000, dir)
    expect(loadCache(dir).auth_failed.me).toBeUndefined()
    setAuthFailed("me", true, NOW + 2000, dir)
    expect(loadCache(dir).auth_failed.me).toBe(true)
    rmSync(dir, { recursive: true })
  })
})

describe("refreshBeforePick", () => {
  async function run(cache: Cache, lane = "wave", enabledB = false) {
    const dir = tmp()
    const calls = { sync: [] as string[][], detach: [] as string[][] }
    const r = await refreshBeforePick({
      reg: reg(enabledB), lane, now: NOW, cache,
      claim: (ids) => claimRefresh(reg(enabledB), ids, NOW, cache, dir),
      runSync: (ids) => { calls.sync.push(ids) }, detach: (ids) => { calls.detach.push(ids) },
    })
    const files = readdirSync(dir)
    rmSync(dir, { recursive: true })
    return { r, calls, files }
  }
  test("stale sample: no blocking refresh, claimed and detached", async () => {
    const { r, calls, files } = await run(staleA())
    expect(r).toEqual({ sync: [], background: ["iu"] })
    expect(calls).toEqual({ sync: [], detach: [["iu"]] })
    expect(files).toEqual(["iu.refresh.claim"])
  })
  test("fresh sample schedules nothing", async () => {
    expect((await run(cacheOf(sample(10, 10)))).r).toEqual({ sync: [], background: [] })
  })
  test("no usable sample on a bulk lane: synchronous; a stale neighbour in the background", async () => {
    const { r, calls } = await run(cacheOf(undefined, sample(10, 10, { age: 11 * 60_000 })), "wave", true)
    expect(r).toEqual({ sync: ["iu"], background: ["me"] })
    expect(calls).toEqual({ sync: [["iu"]], detach: [["me"]] })
  })
  test("a sample older than 6 h counts as no sample", async () => {
    expect((await run(cacheOf(sample(10, 10, { age: 7 * H * 1000 })))).r).toEqual({ sync: ["iu"], background: [] })
  })
  test("interactive returns before any claim: nothing is written", async () => {
    let claimed = false
    const r = await refreshBeforePick({
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
  writeFileSync(join(bin, "security"), "#!/bin/sh\nexit 44\n") // no Keychain token: the endpoint is never called from tests
  chmodSync(join(bin, "security"), 0o755)
  const registry = join(home, "registry.json")
  writeFileSync(registry, JSON.stringify(reg(false))) // iu only: the second account is disabled
  const base = { ...(process.env as Record<string, string>), HOME: home, CLAUDE_ACCOUNTS_REGISTRY: registry, CLAUDE_ACCOUNTS_CACHE_DIR: dir, CLAUDE_ACCOUNTS_PICKS: join(home, "picks.jsonl"), CLAUDE_ACCOUNTS_SECURITY_BIN: join(bin, "security"), PATH: `${bin}:${process.env.PATH}` }
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

  test("latest: newest transcript of the cwd under $HOME/.claude/projects; exit 1 when there is none", () => {
    const cwd = join(home, "work", "proj")
    const pd = join(home, ".claude", "projects", cwd.replace(/[^A-Za-z0-9]/g, "-"))
    mkdirSync(pd, { recursive: true })
    writeFileSync(join(pd, "11111111-aaaa.jsonl"), "")
    expect(cli(["latest", cwd]).out).toBe("11111111-aaaa")
    expect(cli(["latest", join(home, "elsewhere")]).rc).toBe(1)
  })

  test("pick prints the line; interactive and wave both give unset", () => {
    seed(60_000)
    expect(cli(["pick", "--lane", "wave"])).toMatchObject({ rc: 0, out: "unset CLAUDE_CONFIG_DIR" })
    expect(cli(["pick", "--lane", "interactive"])).toMatchObject({ rc: 0, out: "unset CLAUDE_CONFIG_DIR" })
  })
  test("pick --dry answers like pick but writes no picks line and refreshes nothing", () => {
    seed(20 * 60_000) // stale: a real pick would spawn a background refresh
    const picks = join(home, "picks.jsonl")
    rmSync(picks, { force: true })
    expect(cli(["pick", "--lane", "wave", "--dry", "--why"])).toMatchObject({ rc: 0 })
    expect(existsSync(picks)).toBe(false)
    expect(existsSync(marker)).toBe(false)
    seed(60_000) // fresh: the real pick must not leave a detached refresh behind for the next test
    expect(cli(["pick", "--lane", "wave"]).rc).toBe(0)
    expect(existsSync(picks)).toBe(true)
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
    expect(JSON.parse(readFileSync(join(dir, "iu.statusline.json"), "utf8")).ts).toBeGreaterThan(0)
    expect(c.exhausted.iu).toBe(1800000999)
  })
  test("refresh --ids retries an auth-failed account inside the cooldown; a plain refresh does not", () => {
    seed(20 * 60_000)
    setAuthFailed("iu", true, Date.now(), dir)
    expect(cli(["refresh"]).rc).toBe(0)
    expect(existsSync(marker)).toBe(false)
    expect(cli(["refresh", "--ids", "iu"]).rc).toBe(0)
    expect(existsSync(marker)).toBe(true)
  })
  test("refresh --all exits 1 when the account got neither a fresh sample nor a verdict", () => {
    seed(60_000)
    const r = cli(["refresh", "--all"]) // the fake claude exits 0 and fetches nothing
    expect(r.rc).toBe(1)
    expect(r.err).toContain("no fresh sample and no auth verdict for iu")
  })
  test("refresh --all: logged in without an endpoint sample exits 1 when the stored sample is older than 6 h, 0 when younger", () => {
    const loggedInBin = join(home, "bin-loggedin")
    mkdirSync(loggedInBin, { recursive: true })
    writeFileSync(join(loggedInBin, "claude"), `#!/bin/sh\necho '{"loggedIn":true}'\n`)
    chmodSync(join(loggedInBin, "claude"), 0o755)
    const env = { PATH: `${loggedInBin}:${bin}:${process.env.PATH}` }
    seed(7 * 3600_000)
    const old = cli(["refresh", "--all"], env)
    expect(old.rc).toBe(1)
    expect(old.err).toMatch(/refresh iu: logged in .* 7 h old/)
    expect(old.err).toContain("iu logged in but still without a fresh sample")
    seed(5 * 3600_000)
    rmSync(join(dir, "iu.refresh.claim"), { force: true })
    expect(cli(["refresh", "--all"], env).rc).toBe(0)
  })
  test("--account / env reject prototype keys", () => {
    for (const id of ["constructor", "__proto__", "toString"]) {
      expect(cli(["record", "--account", id, "--s", "1"]).rc).toBe(2)
      expect(cli(["exhausted", "--account", id, "--until", "1800000999"]).rc).toBe(2)
      expect(cli(["env", id]).rc).toBe(2)
    }
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

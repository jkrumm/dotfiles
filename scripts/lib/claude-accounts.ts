// Claude account registry, quota cache and picker rule v1 (docs/claude-accounts.md).
// Pure logic + small file helpers; scripts/claude-account.ts is the CLI over it.
import { closeSync, fsyncSync, linkSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync, writeSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join, resolve } from "node:path"

/** Account whose config dir is the default ~/.claude (CLAUDE_CONFIG_DIR unset). */
export const DEFAULT_ACCOUNT_ID = "iu"
/** pick() result when no account is usable: the caller spills to its IU path (not an account id). */
export const SPILL = "spill"
export const SESSION_MAX = 85
export const WEEKLY_MAX = 90
export const FRESH_MS = 10 * 60_000
export const STALE_OK_MS = 6 * 3600_000
/** a dead login is re-probed (in the background) at most this often */
export const AUTH_RETRY_MS = 30 * 60_000
export const REFRESH_MIN_MS = 5 * 60_000
export const EXPIRING_S = 24 * 3600
/** Weekly% may run this many points ahead of the elapsed share of the 7-day window before an account counts as over pace. */
export const PACE_MARGIN = 15
const WEEK_S = 7 * 24 * 3600
export const EXPIRING_WEEKLY_MAX = 70

export interface Account {
  dir: string | null
  plan: string
  units: { session: number; weekly: number }
  homeLanes: string[]
  enabled: boolean
}
export interface Registry {
  accounts: Record<string, Account>
}

/**
 * One account's quota sample. Percent 0-100, resets epoch seconds. Each window carries its own timestamp (epoch ms):
 * s/s_reset belong to the 5h window (s_ts), w/w_reset to the weekly one (w_ts), so a carried-over window is never
 * judged fresher than it is.
 */
export interface Sample {
  s: number | null
  w: number | null
  s_reset: number | null
  w_reset: number | null
  s_ts: number | null
  w_ts: number | null
  src: string
}
/** In-memory view assembled from the per-account files under cacheDir(). */
export interface Cache {
  samples: Record<string, Sample>
  /** Exhausted marks: account id -> epoch seconds until which it is out. */
  exhausted: Record<string, number>
  /** Accounts whose last refresh found no usable login. */
  auth_failed: Record<string, boolean>
  /** epoch ms of the last auth failure per id (the retry cooldown starts there) */
  auth_failed_at: Record<string, number>
}
/** `stale`: the picked account was chosen on a sample older than FRESH_MS (reason keeps the routing rule). */
export interface PickResult {
  picked: string
  reason: string
  stale: boolean
}

export const emptyCache = (): Cache => ({ samples: {}, exhausted: {}, auth_failed: {}, auth_failed_at: {} })

export const registryPath = () => process.env.CLAUDE_ACCOUNTS_REGISTRY ?? join(import.meta.dir, "..", "..", "config", "claude-accounts.json")
export const cacheDir = () => process.env.CLAUDE_ACCOUNTS_CACHE_DIR ?? join(homedir(), ".cache", "claude-accounts")
export const picksPath = () => process.env.CLAUDE_ACCOUNTS_PICKS ?? join(homedir(), ".local", "share", "claude-accounts", "picks.jsonl")

export const expandHome = (p: string) => (p === "~" ? homedir() : p.startsWith("~/") ? join(homedir(), p.slice(2)) : p)

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v)
const numOrNull = (v: unknown) => v === null || isNum(v)

function validAccount(a: unknown): a is Account {
  const x = a as Account | null
  return (
    !!x && typeof x === "object" &&
    (x.dir === null || typeof x.dir === "string") &&
    typeof x.plan === "string" &&
    !!x.units && isNum(x.units.session) && isNum(x.units.weekly) &&
    Array.isArray(x.homeLanes) && x.homeLanes.every((l) => typeof l === "string") &&
    typeof x.enabled === "boolean"
  )
}

export function loadRegistry(path = registryPath()): Registry {
  const raw = JSON.parse(readFileSync(path, "utf8"))
  if (!raw || typeof raw.accounts !== "object" || raw.accounts === null) throw new Error(`${path}: missing accounts`)
  for (const [id, a] of Object.entries(raw.accounts)) {
    if (!ID.test(id) || id === SPILL) throw new Error(`${path}: bad account id '${id}'`)
    if (!validAccount(a)) throw new Error(`${path}: account '${id}' is malformed`)
  }
  if (!Object.values(raw.accounts).some((a) => (a as Account).dir === null)) throw new Error(`${path}: no account owns the default ~/.claude (dir: null)`)
  return { accounts: raw.accounts }
}

/** Absolute config dir of an account; null = default ~/.claude (env unset). */
export const accountDir = (a: Account): string | null => (a.dir === null ? null : resolve(expandHome(a.dir)))

/** Where the account's `.claude.json` lives: the default one sits in $HOME, others inside their dir. */
export function claudeJsonPath(a: Account): string {
  const d = accountDir(a)
  return d === null ? join(homedir(), ".claude.json") : join(d, ".claude.json")
}

/**
 * Registry id for a CLAUDE_CONFIG_DIR value. Unset or empty -> the default account; a set dir that no account
 * owns -> null (an unknown identity must not be attributed to the default account).
 */
export function accountFromConfigDir(reg: Registry, configDir: string | undefined): string | null {
  if (!configDir) return defaultAccountId(reg)
  const want = resolve(expandHome(configDir))
  for (const [id, a] of Object.entries(reg.accounts)) if (accountDir(a) === want) return id
  return null
}
export const defaultAccountId = (reg: Registry) => Object.entries(reg.accounts).find(([, a]) => a.dir === null)?.[0] ?? DEFAULT_ACCOUNT_ID

export function writeAtomic(path: string, data: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const tmp = `${path}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`
  const fd = openSync(tmp, "w")
  try {
    writeSync(fd, data)
    fsyncSync(fd)
  } finally {
    closeSync(fd)
  }
  renameSync(tmp, path)
}

// ── Per-account cache files ────────────────────────────────────────────────────────────────────────────────────
// <id>.sample.json · <id>.exhausted.json · <id>.auth.json · <id>.statusline.json (last statusline feed) · <id>.refresh.claim. Every writer replaces only its own
// small file atomically, so there is no lock: two accounts or two kinds never contend, and a lost update on one
// file only costs freshness (the next feed rewrites it).

const ID = /^[A-Za-z0-9_-]+$/
const file = (dir: string, id: string, kind: string) => {
  if (!ID.test(id)) throw new Error(`bad account id '${id}'`)
  return join(dir, `${id}.${kind}`)
}
const readJson = (path: string): unknown => {
  try {
    return JSON.parse(readFileSync(path, "utf8"))
  } catch {
    return null
  }
}

export function loadCache(dir = cacheDir()): Cache {
  const c = emptyCache()
  let names: string[] = []
  try {
    names = readdirSync(dir)
  } catch {
    return c
  }
  for (const name of names) {
    const m = /^([A-Za-z0-9_-]+)\.(sample|exhausted|auth)\.json$/.exec(name)
    if (!m) continue
    const [, id, kind] = m
    const j = readJson(join(dir, name)) as Record<string, unknown> | null
    if (!j) continue
    if (kind === "sample") {
      if (isSample(j)) c.samples[id] = j // a malformed file is dropped, the next feed rewrites it
    }
    else if (kind === "exhausted" && isNum(j.until)) c.exhausted[id] = j.until
    else if (kind === "auth" && j.failed === true) {
      c.auth_failed[id] = true
      if (isNum(j.ts)) c.auth_failed_at[id] = j.ts
    }
  }
  return c
}

export function isSample(v: unknown): v is Sample {
  const x = v as Sample | null
  return !!x && typeof x === "object" && numOrNull(x.s) && numOrNull(x.w) && numOrNull(x.s_reset) && numOrNull(x.w_reset) && numOrNull(x.s_ts) && numOrNull(x.w_ts) && typeof x.src === "string"
}

const hasS = (x: Sample) => x.s !== null
const hasW = (x: Sample) => x.w !== null

/**
 * Field-wise merge, per window: an incoming window that is absent (null) keeps what we know; a present one wins
 * unless the stored one has a newer timestamp.
 */
export function mergeSample(prev: Sample | null, inc: Sample): Sample {
  if (!prev) return inc
  const takeS = hasS(inc) && !(hasS(prev) && (prev.s_ts ?? 0) > (inc.s_ts ?? 0))
  const takeW = hasW(inc) && !(hasW(prev) && (prev.w_ts ?? 0) > (inc.w_ts ?? 0))
  return {
    s: takeS ? inc.s : prev.s, s_reset: takeS ? inc.s_reset : prev.s_reset, s_ts: takeS ? inc.s_ts : prev.s_ts,
    w: takeW ? inc.w : prev.w, w_reset: takeW ? inc.w_reset : prev.w_reset, w_ts: takeW ? inc.w_ts : prev.w_ts,
    src: takeS || takeW ? inc.src : prev.src,
  }
}

export function saveSample(id: string, inc: Sample, dir = cacheDir()): void {
  const path = file(dir, id, "sample.json")
  writeAtomic(path, JSON.stringify(mergeSample(readJson(path) as Sample | null, inc)))
}

export function markExhausted(id: string, untilS: number, dir = cacheDir()): void {
  const path = file(dir, id, "exhausted.json")
  const cur = (readJson(path) as { until?: number } | null)?.until ?? 0
  writeAtomic(path, JSON.stringify({ until: Math.max(untilS, cur) }))
}

/** Records the auth verdict; a no-op when it already says the same. */
export function setAuthFailed(id: string, failed: boolean, nowMs: number, dir = cacheDir()): void {
  const path = file(dir, id, "auth.json")
  const cur = (readJson(path) as { failed?: boolean } | null)?.failed === true
  if (!failed && !cur) return // a repeated failure still rewrites the mark: its ts restarts the retry cooldown
  writeAtomic(path, JSON.stringify({ failed, ts: nowMs }))
}

/**
 * Statusline feed: a window the payload omits keeps its previous value and timestamp (so it is never presented as
 * fresh). A live statusline proves the login works, so it also clears a recorded auth failure.
 */
export function recordSample(id: string, part: { s?: number | null; w?: number | null; s_reset?: number | null; w_reset?: number | null }, nowMs: number, dir = cacheDir()): void {
  const has = (v: number | null | undefined): v is number => typeof v === "number"
  saveSample(id, {
    s: part.s ?? null, s_reset: has(part.s) ? (part.s_reset ?? null) : null, s_ts: has(part.s) ? nowMs : null,
    w: part.w ?? null, w_reset: has(part.w) ? (part.w_reset ?? null) : null, w_ts: has(part.w) ? nowMs : null,
    src: "statusline",
  }, dir)
  setAuthFailed(id, false, nowMs, dir)
  // The sample's `src` flips to "usage" when a refresh lands later, so the verify suite reads this stamp for "a statusline fed it".
  writeAtomic(file(dir, id, "statusline.json"), JSON.stringify({ ts: nowMs }))
}

/** ISO string or epoch (s or ms) -> epoch seconds. */
export function toEpochS(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return Math.round(v > 1e12 ? v / 1000 : v)
  if (typeof v === "string" && v) {
    if (/^\d+$/.test(v)) return toEpochS(Number(v))
    const t = Date.parse(v)
    return Number.isNaN(t) ? null : Math.round(t / 1000)
  }
  return null
}

type Window = { utilization?: number; resets_at?: unknown } | null | undefined

/** Parse `cachedUsageUtilization` out of a `.claude.json` blob; a window the payload omits stays null (merge keeps what we know). */
export function sampleFromClaudeJson(json: unknown, src = "usage"): Sample | null {
  const c = (json as { cachedUsageUtilization?: { fetchedAtMs?: number; utilization?: Record<string, Window> } })?.cachedUsageUtilization
  if (!c || typeof c.fetchedAtMs !== "number" || !c.utilization) return null
  const pct = (x: Window) => (typeof x?.utilization === "number" ? x.utilization : null)
  const f = c.utilization.five_hour
  const d = c.utilization.seven_day
  const s = pct(f)
  const w = pct(d)
  if (s === null && w === null) return null
  return {
    s, s_reset: s === null ? null : toEpochS(f?.resets_at), s_ts: s === null ? null : c.fetchedAtMs,
    w, w_reset: w === null ? null : toEpochS(d?.resets_at), w_ts: w === null ? null : c.fetchedAtMs,
    src,
  }
}

/** Age (ms) of each window the sample actually has; a window without a timestamp counts as infinitely old. */
const windowAges = (x: Sample | undefined, nowMs: number): number[] => {
  if (!x) return []
  const age = (ts: number | null) => (ts === null ? Infinity : nowMs - ts)
  return [...(hasS(x) ? [age(x.s_ts)] : []), ...(hasW(x) ? [age(x.w_ts)] : [])]
}
/** Oldest window (the sample is only as fresh as its stalest window); Infinity when there is none. */
export const sampleAge = (x: Sample | undefined, nowMs: number) => (windowAges(x, nowMs).length ? Math.max(...windowAges(x, nowMs)) : Infinity)
/** Newest window, for display. */
export const newestAge = (x: Sample | undefined, nowMs: number) => (windowAges(x, nowMs).length ? Math.min(...windowAges(x, nowMs)) : Infinity)
/** True when at least one window is young enough to judge by. */
const usable = (x: Sample | undefined, nowMs: number) => windowAges(x, nowMs).some((a) => a < STALE_OK_MS)

const matchesLane = (pattern: string, lane: string) => pattern === lane || (pattern.endsWith(":*") && lane.startsWith(pattern.slice(0, -1)))

/** Accounts whose home lanes claim `lane`: exact matches win outright, wildcards only count when nobody matches exactly. */
export function homeIds(reg: Registry, lane: string): string[] {
  const ids = Object.keys(reg.accounts)
  const exact = ids.filter((id) => reg.accounts[id].homeLanes.includes(lane))
  return exact.length ? exact : ids.filter((id) => reg.accounts[id].homeLanes.some((h) => matchesLane(h, lane)))
}

/** The pick rests on a sample with a window older than FRESH_MS. */
export const isStaleOk = (cache: Cache, id: string, nowMs: number) => usable(cache.samples[id], nowMs) && sampleAge(cache.samples[id], nowMs) >= FRESH_MS

/** Enabled, logged in, not exhausted, and every window young enough to judge (< 6 h) is below its threshold. Each window is judged by its own timestamp. */
export function eligible(reg: Registry, cache: Cache, id: string, nowMs: number): boolean {
  const a = Object.hasOwn(reg.accounts, id) ? reg.accounts[id] : undefined
  if (!a?.enabled || cache.auth_failed[id]) return false
  const x = cache.samples[id]
  if (!x || !usable(x, nowMs)) return false
  if (hasS(x) && nowMs - (x.s_ts ?? 0) < STALE_OK_MS && x.s! >= SESSION_MAX) return false
  if (hasW(x) && nowMs - (x.w_ts ?? 0) < STALE_OK_MS && x.w! >= WEEKLY_MAX) return false
  const until = cache.exhausted[id]
  if (until && until * 1000 > nowMs) return false
  return true
}

/** Percent of x's 7-day window already elapsed (0..100); null without a weekly reset to measure against. */
export function pace(x: Sample | undefined, nowMs: number): number | null {
  if (!x || !hasW(x) || x.w_reset === null) return null
  return 100 * Math.min(1, Math.max(0, 1 - (x.w_reset * 1000 - nowMs) / (WEEK_S * 1000)))
}

/** Eligible and burning weekly capacity faster than the window elapses (by more than PACE_MARGIN). */
export function overPace(reg: Registry, cache: Cache, id: string, nowMs: number): boolean {
  if (!eligible(reg, cache, id, nowMs)) return false
  const x = cache.samples[id]
  const p = pace(x, nowMs)
  return p !== null && x.w! > p + PACE_MARGIN
}

/** Rule v1.1 (docs/claude-accounts.md §The picker). Ties and ordering follow registry order. */
export function pick(reg: Registry, cache: Cache, lane: string, nowMs: number): PickResult {
  const r = pickRaw(reg, cache, lane, nowMs)
  return { ...r, stale: r.reason !== "interactive-fallback" && r.picked !== SPILL && isStaleOk(cache, r.picked, nowMs) }
}

function pickRaw(reg: Registry, cache: Cache, lane: string, nowMs: number): Omit<PickResult, "stale"> {
  const ids = Object.keys(reg.accounts)
  const ok = ids.filter((id) => eligible(reg, cache, id, nowMs))
  const bulk = lane !== "interactive"

  if (bulk) {
    const expiring = ok
      .filter((id) => {
        const x = cache.samples[id]
        const msLeft = x.w_reset === null || !hasW(x) ? null : x.w_reset * 1000 - nowMs
        return msLeft !== null && msLeft > 0 && msLeft < EXPIRING_S * 1000 && (x.w ?? 0) < EXPIRING_WEEKLY_MAX
      })
      .sort((p, q) => cache.samples[p].w_reset! - cache.samples[q].w_reset!)
    if (expiring.length) return { picked: expiring[0], reason: "expiring-capacity" }
  }
  const homes = homeIds(reg, lane)
  const home = ids.find((id) => ok.includes(id) && homes.includes(id))
  if (home && overPace(reg, cache, home, nowMs)) {
    const calm = ok.find((id) => id !== home && !overPace(reg, cache, id, nowMs))
    if (calm) return { picked: calm, reason: "pace" }
  }
  if (home) return { picked: home, reason: "home" }
  const other = ok[0]
  if (other) return { picked: other, reason: "spill" }
  if (!bulk) return { picked: defaultAccountId(reg), reason: "interactive-fallback" }
  return { picked: SPILL, reason: "no-eligible-account" }
}

export interface PickLine {
  ts: string
  lane: string
  picked: string
  reason: string
  stale: boolean
  [account: string]: unknown
}

/** One JSONL line per pick; per-account {s,w} keyed by registry id. */
export function pickLine(reg: Registry, cache: Cache, lane: string, p: PickResult, nowMs: number): PickLine {
  const accounts = Object.fromEntries(Object.keys(reg.accounts).map((id) => [id, { s: cache.samples[id]?.s ?? null, w: cache.samples[id]?.w ?? null }]))
  return { ts: new Date(nowMs).toISOString(), lane, picked: p.picked, reason: p.reason, stale: p.stale, ...accounts }
}

const shQuote = (v: string) => `'${v.replaceAll("'", `'\\''`)}'`

/** Shell fragment for a pick; null for the IU spill signal. */
export function shellLine(reg: Registry, p: PickResult): string | null {
  if (p.picked === SPILL) return null
  const dir = accountDir(reg.accounts[p.picked])
  return dir === null ? "unset CLAUDE_CONFIG_DIR" : `export CLAUDE_CONFIG_DIR=${shQuote(dir)}`
}

/** Enabled accounts whose sample is missing or has a window older than 10 min (the budget is checked at claim time). */
export function dueIds(reg: Registry, cache: Cache, nowMs: number, ignoreAuthMark = false): string[] {
  // An auth-failed account is re-probed only after AUTH_RETRY_MS (a dead login must not be hammered every pick);
  // a successful refresh or a statusline record clears the mark. `refresh --ids` bypasses it (manual retry).
  const authBlocked = (id: string) => !ignoreAuthMark && cache.auth_failed[id] && nowMs - (cache.auth_failed_at[id] ?? 0) <= AUTH_RETRY_MS
  return Object.keys(reg.accounts).filter((id) => reg.accounts[id].enabled && !authBlocked(id) && sampleAge(cache.samples[id], nowMs) > FRESH_MS)
}

/**
 * Claim the per-account refresh: exclusive create of <id>.refresh.claim (content = claim time). A claim younger than
 * REFRESH_MIN_MS is the 5-min budget; an older one is stale and replaced. Racing replacers may both win: one
 * duplicate refresh at worst.
 */
export function claimRefresh(reg: Registry, ids: string[], nowMs: number, cache: Cache, dir = cacheDir(), ignoreAuthMark = false, all = false): string[] {
  mkdirSync(dir, { recursive: true })
  // Exclusive create WITH content: write a private temp file, then hard-link it into place (fails with EEXIST if
  // the claim exists), so a concurrent reader never sees a claim without its timestamp.
  const create = (path: string) => {
    const tmp = `${path}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`
    writeFileSync(tmp, String(nowMs))
    try {
      linkSync(tmp, path)
    } finally {
      unlinkSync(tmp)
    }
  }
  // `all` (the daily login keepalive): every enabled account, whatever its sample age; the claim budget still applies.
  const candidates = all ? Object.keys(reg.accounts).filter((id) => reg.accounts[id].enabled) : dueIds(reg, cache, nowMs, ignoreAuthMark)
  return candidates.filter((id) => {
    if (!ids.includes(id)) return false
    const path = file(dir, id, "refresh.claim")
    try {
      create(path)
      return true
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e
    }
    let at: number
    try {
      at = Number(readFileSync(path, "utf8").trim())
    } catch {
      return false // the claim vanished or is unreadable: someone else is on it
    }
    if (Number.isFinite(at) && nowMs - at <= REFRESH_MIN_MS) return false
    try {
      unlinkSync(path)
      create(path)
      return true
    } catch {
      return false // lost the replacement race
    }
  })
}

export function releaseClaim(id: string, dir = cacheDir()): void {
  try {
    unlinkSync(file(dir, id, "refresh.claim"))
  } catch {
    // already gone
  }
}

export interface SpawnResult {
  status: number | null
  stdout: string
  stderr: string
  /** Set when the process could not start (ENOENT) or was killed by the timeout. */
  error?: { code?: string; message: string }
}
export type Spawner = (cmd: string, args: string[], opts: { env: Record<string, string>; timeoutMs: number }) => SpawnResult

/** Credentials that would make the spawned binary bill API credits or bypass the account's own login. */
const STRIPPED_ENV = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]

export function refreshEnv(base: Record<string, string | undefined>, dir: string | null): Record<string, string> {
  const env = { ...base } as Record<string, string>
  for (const k of STRIPPED_ENV) delete env[k]
  env.ANTHROPIC_BASE_URL = ""
  if (dir === null) delete env.CLAUDE_CONFIG_DIR
  else env.CLAUDE_CONFIG_DIR = dir
  return env
}

export const REFRESH_TIMEOUT_S = 75

export interface RefreshDeps {
  reg: Registry
  spawn: Spawner
  claudeBin: string
  baseEnv: Record<string, string | undefined>
  readSample: (id: string) => Sample | null
  dir?: string
  now: () => number
  timeoutS: number
  /** Accounts to refresh. They are already claimed (budget stamped) by the caller. */
  ids: string[]
  log?: (msg: string) => void
}

/**
 * `claude -p /usage` for already-claimed accounts. Each result touches only that account's own files. A binary that
 * could not start gives the claim back (it was not an attempt); a timeout keeps it and leaves the auth verdict alone.
 * Returns each account's outcome: `fresh` (sample fetched this run), `auth-failed` (verdict recorded) or `unresolved`.
 */
export type RefreshResult = "fresh" | "auth-failed" | "unresolved"

export function runRefresh(d: RefreshDeps): Record<string, RefreshResult> {
  const results: Record<string, RefreshResult> = {}
  for (const id of d.ids) {
    results[id] = "unresolved" // neither a fresh sample nor an auth verdict, until proven otherwise
    const env = refreshEnv(d.baseEnv, accountDir(d.reg.accounts[id]))
    const startedAt = d.now()
    const r = d.spawn(d.claudeBin, ["-p", "/usage", "--output-format", "json"], { env, timeoutMs: d.timeoutS * 1000 })
    if (r.error?.code === "ENOENT") {
      d.log?.(`refresh ${id}: cannot start claude (${r.error.message})`)
      releaseClaim(id, d.dir)
      continue
    }
    const sample = r.status === 0 && !r.error ? d.readSample(id) : null
    // `claude -p /usage` exits 0 with no fetch when the login is dead, leaving the previous cachedUsageUtilization in
    // place: only a sample fetched during this run proves the login works.
    if (sample && Math.max(sample.s_ts ?? 0, sample.w_ts ?? 0) >= startedAt) {
      saveSample(id, sample, d.dir)
      setAuthFailed(id, false, d.now(), d.dir)
      results[id] = "fresh"
      continue
    }
    if (sample) saveSample(id, sample, d.dir)
    d.log?.(`refresh ${id}: rc=${r.status} ${r.error?.message ?? (r.stderr || r.stdout).trim().slice(0, 200)}`)
    if (r.error?.code === "ETIMEDOUT" || r.error?.message?.includes("timed out")) continue // a timeout says nothing about the login
    if (/login|auth|credential/i.test(`${r.stdout}${r.stderr}`) || loggedOut(d, id, env)) {
      setAuthFailed(id, true, d.now(), d.dir)
      results[id] = "auth-failed"
    }
  }
  return results
}

/** `claude auth status` (0 tokens): true only when the binary says loggedIn is false. */
function loggedOut(d: RefreshDeps, id: string, env: Record<string, string>): boolean {
  const r = d.spawn(d.claudeBin, ["auth", "status"], { env, timeoutMs: 30_000 })
  try {
    return (JSON.parse(r.stdout) as { loggedIn?: unknown }).loggedIn === false
  } catch {
    return false
  }
}

export interface BeforePick {
  reg: Registry
  lane: string
  now: number
  cache: Cache
  /** Claims the due ids atomically (budget stamped); returns the ones this caller won. */
  claim: (ids: string[]) => string[]
  /** Blocking refresh of already-claimed ids (account has no usable sample). */
  runSync: (ids: string[]) => void
  /** Detached, fire-and-forget refresh of already-claimed ids. */
  detach: (ids: string[]) => void
}

/**
 * Refresh policy of `pick`: the interactive lane returns before any claim. Other lanes never block while a usable
 * sample exists; only an account with no usable sample refreshes synchronously, every other due account in the
 * background. Ids are claimed first.
 */
export function refreshBeforePick(b: BeforePick): { sync: string[]; background: string[] } {
  if (b.lane === "interactive") return { sync: [], background: [] } // no claim: an interactive pick touches nothing
  const due = dueIds(b.reg, b.cache, b.now)
  const claimed = due.length ? b.claim(due) : []
  // a due auth-failed account is a retry: never block a pick on it
  const sync = claimed.filter((id) => !b.cache.auth_failed[id] && !usable(b.cache.samples[id], b.now))
  const background = claimed.filter((id) => !sync.includes(id))
  if (background.length) b.detach(background)
  if (sync.length) b.runSync(sync)
  return { sync, background }
}

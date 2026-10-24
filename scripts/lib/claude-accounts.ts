// Claude account registry, quota cache and picker rule v1 (docs/claude-accounts.md).
// Pure logic + small file helpers; scripts/claude-account.ts is the CLI over it.
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join, resolve } from "node:path"

/** Account whose config dir is the default ~/.claude (CLAUDE_CONFIG_DIR unset). */
export const DEFAULT_ACCOUNT_ID = "a"
export const SESSION_MAX = 85
export const WEEKLY_MAX = 90
export const FRESH_MS = 10 * 60_000
export const STALE_OK_MS = 6 * 3600_000
export const REFRESH_MIN_MS = 5 * 60_000
export const EXPIRING_S = 24 * 3600
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

/** One quota sample. Percent 0-100, resets as epoch seconds, ts as epoch ms. */
export interface Sample {
  s: number | null
  w: number | null
  s_reset: number | null
  w_reset: number | null
  ts: number
  src: string
}
export interface Cache {
  samples: Record<string, Sample>
  /** Exhausted marks: account id -> epoch seconds until which it is out. */
  exhausted: Record<string, number>
  /** Last `claude -p /usage` attempt per account, epoch ms. */
  refreshed: Record<string, number>
  /** Accounts whose last refresh found no usable login. */
  auth_failed: Record<string, boolean>
}
/** `stale`: the picked account was chosen on a sample older than FRESH_MS (reason keeps the routing rule). */
export interface PickResult {
  picked: string
  reason: string
  stale: boolean
}

export const emptyCache = (): Cache => ({ samples: {}, exhausted: {}, refreshed: {}, auth_failed: {} })

export const registryPath = () => process.env.CLAUDE_ACCOUNTS_REGISTRY ?? join(import.meta.dir, "..", "..", "config", "claude-accounts.json")
export const cachePath = () => process.env.CLAUDE_ACCOUNTS_CACHE ?? join(homedir(), ".cache", "claude-accounts", "usage.json")
export const picksPath = () => process.env.CLAUDE_ACCOUNTS_PICKS ?? join(homedir(), ".local", "share", "claude-accounts", "picks.jsonl")

export const expandHome = (p: string) => (p === "~" ? homedir() : p.startsWith("~/") ? join(homedir(), p.slice(2)) : p)

export function loadRegistry(path = registryPath()): Registry {
  const raw = JSON.parse(readFileSync(path, "utf8"))
  if (!raw.accounts || typeof raw.accounts !== "object") throw new Error(`${path}: missing accounts`)
  return { accounts: raw.accounts }
}

/** Absolute config dir of an account; null = default ~/.claude (env unset). */
export const accountDir = (a: Account): string | null => (a.dir === null ? null : resolve(expandHome(a.dir)))

/** Where the account's `.claude.json` lives: the default one sits in $HOME, others inside their dir. */
export function claudeJsonPath(a: Account): string {
  const d = accountDir(a)
  return d === null ? join(homedir(), ".claude.json") : join(d, ".claude.json")
}

/** Registry id for a CLAUDE_CONFIG_DIR value; unset or empty -> the default account. */
export function accountFromConfigDir(reg: Registry, configDir: string | undefined): string {
  if (!configDir) return defaultAccountId(reg)
  const want = resolve(expandHome(configDir))
  for (const [id, a] of Object.entries(reg.accounts)) if (accountDir(a) === want) return id
  return defaultAccountId(reg)
}
export const defaultAccountId = (reg: Registry) => Object.entries(reg.accounts).find(([, a]) => a.dir === null)?.[0] ?? DEFAULT_ACCOUNT_ID

export function loadCache(path = cachePath()): Cache {
  try {
    return { ...emptyCache(), ...JSON.parse(readFileSync(path, "utf8")) }
  } catch {
    return emptyCache()
  }
}

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

/** Merge a sample in: the freshest timestamp wins, an older feed never overwrites a newer one. */
export function mergeSample(cache: Cache, id: string, s: Sample): Cache {
  const cur = cache.samples[id]
  if (cur && cur.ts > s.ts) return cache
  return { ...cache, samples: { ...cache.samples, [id]: s } }
}

export function markExhausted(cache: Cache, id: string, untilS: number): Cache {
  return { ...cache, exhausted: { ...cache.exhausted, [id]: Math.max(untilS, cache.exhausted[id] ?? 0) } }
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

/** Parse `cachedUsageUtilization` out of a `.claude.json` blob. */
export function sampleFromClaudeJson(json: unknown, src = "usage"): Sample | null {
  const c = (json as { cachedUsageUtilization?: { fetchedAtMs?: number; utilization?: Record<string, { utilization?: number; resets_at?: unknown } | null> } })?.cachedUsageUtilization
  if (!c || typeof c.fetchedAtMs !== "number" || !c.utilization) return null
  const f = c.utilization.five_hour
  const d = c.utilization.seven_day
  if (!f && !d) return null
  const pct = (x: { utilization?: number } | null | undefined) => (typeof x?.utilization === "number" ? x.utilization : null)
  return { s: pct(f), w: pct(d), s_reset: toEpochS(f?.resets_at), w_reset: toEpochS(d?.resets_at), ts: c.fetchedAtMs, src }
}

export const isHome = (a: Account, lane: string) => a.homeLanes.some((h) => h === lane || (h.endsWith(":*") && lane.startsWith(h.slice(0, -1))))

/** Last known sample still usable after a skipped or failed refresh: older than FRESH_MS, younger than STALE_OK_MS. */
export const isStaleOk = (cache: Cache, id: string, nowMs: number) => {
  const x = cache.samples[id]
  return !!x && nowMs - x.ts >= FRESH_MS && nowMs - x.ts < STALE_OK_MS
}

/** Enabled, logged in, not exhausted, has a sample (fresh or stale-ok) below both thresholds. */
export function eligible(reg: Registry, cache: Cache, id: string, nowMs: number): boolean {
  const a = reg.accounts[id]
  if (!a?.enabled || cache.auth_failed[id]) return false
  const x = cache.samples[id]
  if (!x || nowMs - x.ts >= STALE_OK_MS) return false
  if (x.s !== null && x.s >= SESSION_MAX) return false
  if (x.w !== null && x.w >= WEEKLY_MAX) return false
  const until = cache.exhausted[id]
  if (until && until * 1000 > nowMs) return false
  return true
}

/** Rule v1 (docs/claude-accounts.md §The picker). Ties and ordering follow registry order. */
export function pick(reg: Registry, cache: Cache, lane: string, nowMs: number): PickResult {
  const r = pickRaw(reg, cache, lane, nowMs)
  return { ...r, stale: r.reason !== "interactive-fallback" && r.picked !== "iu" && isStaleOk(cache, r.picked, nowMs) }
}

function pickRaw(reg: Registry, cache: Cache, lane: string, nowMs: number): Omit<PickResult, "stale"> {
  const ids = Object.keys(reg.accounts)
  const ok = ids.filter((id) => eligible(reg, cache, id, nowMs))
  const bulk = lane !== "interactive"

  if (bulk) {
    const expiring = ok
      .filter((id) => {
        const x = cache.samples[id]
        const msLeft = x.w_reset === null ? null : x.w_reset * 1000 - nowMs
        return msLeft !== null && msLeft > 0 && msLeft < EXPIRING_S * 1000 && (x.w ?? 0) < EXPIRING_WEEKLY_MAX
      })
      .sort((p, q) => cache.samples[p].w_reset! - cache.samples[q].w_reset!)
    if (expiring.length) return { picked: expiring[0], reason: "expiring-capacity" }
  }
  const home = ids.find((id) => ok.includes(id) && isHome(reg.accounts[id], lane))
  if (home) return { picked: home, reason: "home" }
  const other = ok[0]
  if (other) return { picked: other, reason: "spill" }
  if (!bulk) {
    const dflt = defaultAccountId(reg)
    return { picked: dflt, reason: "interactive-fallback" }
  }
  return { picked: "iu", reason: "no-eligible-account" }
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
  if (p.picked === "iu") return null
  const dir = accountDir(reg.accounts[p.picked])
  return dir === null ? "unset CLAUDE_CONFIG_DIR" : `export CLAUDE_CONFIG_DIR=${shQuote(dir)}`
}

/** Accounts due a `claude -p /usage`: enabled, newest sample >10 min old, last attempt >5 min ago. */
export function needsRefresh(reg: Registry, cache: Cache, nowMs: number): string[] {
  return Object.keys(reg.accounts).filter((id) => {
    if (!reg.accounts[id].enabled) return false
    const x = cache.samples[id]
    if (x && nowMs - x.ts <= FRESH_MS) return false
    return nowMs - (cache.refreshed[id] ?? 0) > REFRESH_MIN_MS
  })
}


/**
 * Statusline feed: omitted fields keep the previous sample's values. When any value is retained the old ts is
 * kept too, so a carried-over field is never presented as fresh. A live statusline proves the login works.
 */
export function recordSample(cache: Cache, id: string, part: Partial<Pick<Sample, "s" | "w" | "s_reset" | "w_reset">>, nowMs: number): Cache {
  const prev = cache.samples[id]
  const keep = <K extends "s" | "w" | "s_reset" | "w_reset">(k: K): Sample[K] => (part[k] ?? prev?.[k] ?? null) as Sample[K]
  const retained = (["s", "w", "s_reset", "w_reset"] as const).some((k) => part[k] == null && prev?.[k] != null)
  const next: Sample = { s: keep("s"), w: keep("w"), s_reset: keep("s_reset"), w_reset: keep("w_reset"), ts: retained ? prev.ts : nowMs, src: "statusline" }
  return { ...mergeSample(cache, id, next), auth_failed: { ...cache.auth_failed, [id]: false } }
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

const LOCK_WAIT_MS = 3000
const LOCK_STALE_MS = 30_000
const sleepMs = (ms: number) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)

/**
 * The only way to change the quota cache: take a mkdir lock (atomic), re-read the file, apply `fn` to the fresh
 * content, write atomically, release. A lock older than LOCK_STALE_MS belongs to a dead process and is broken.
 * Throws when the lock cannot be taken within LOCK_WAIT_MS; callers that are best-effort catch it.
 */
export function updateCache(fn: (c: Cache) => Cache, path = cachePath()): void {
  const lock = `${path}.lock`
  mkdirSync(dirname(path), { recursive: true })
  const deadline = Date.now() + LOCK_WAIT_MS
  for (;;) {
    try {
      mkdirSync(lock)
      break
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e
      try {
        if (Date.now() - statSync(lock).mtimeMs > LOCK_STALE_MS) rmSync(lock, { recursive: true, force: true })
      } catch {
        // released by its owner between our checks
      }
      if (Date.now() > deadline) throw new Error(`quota cache lock busy: ${lock}`)
      sleepMs(15)
    }
  }
  try {
    const cur = loadCache(path)
    const next = fn(cur)
    if (next !== cur) writeAtomic(path, JSON.stringify(next))
  } finally {
    rmSync(lock, { recursive: true, force: true })
  }
}

export type CacheUpdater = (fn: (c: Cache) => Cache) => void

/**
 * Atomically claim the per-account refresh: inside the lock, on the fresh cache (plus `seed`, e.g. the account's own
 * .claude.json sample), keep only ids that are still due and stamp them against the 5-min budget. Two concurrent
 * callers can never both claim the same account.
 */
export function claimRefresh(update: CacheUpdater, reg: Registry, ids: string[], nowMs: number, seed: (c: Cache) => Cache = (c) => c): string[] {
  let claimed: string[] = []
  update((c) => {
    const view = seed(c)
    claimed = needsRefresh(reg, view, nowMs).filter((id) => ids.includes(id))
    if (!claimed.length) return c
    return { ...view, refreshed: { ...view.refreshed, ...Object.fromEntries(claimed.map((id) => [id, nowMs])) } }
  })
  return claimed
}

export interface RefreshDeps {
  reg: Registry
  spawn: Spawner
  claudeBin: string
  baseEnv: Record<string, string | undefined>
  readSample: (id: string) => Sample | null
  update: CacheUpdater
  now: () => number
  timeoutS: number
  /** Accounts to refresh. They are already claimed (budget stamped) by the caller. */
  ids: string[]
  log?: (msg: string) => void
}

/**
 * `claude -p /usage` for already-claimed accounts, then one locked update: only the refreshed sample, auth verdict
 * and (when the binary could not start) the budget rollback are applied, so concurrent statusline records survive.
 */
export function runRefresh(d: RefreshDeps): void {
  const results: { id: string; started: boolean; sample: Sample | null; authFailed: boolean | null }[] = []
  for (const id of d.ids) {
    const r = d.spawn(d.claudeBin, ["-p", "/usage", "--output-format", "json"], {
      env: refreshEnv(d.baseEnv, accountDir(d.reg.accounts[id])),
      timeoutMs: d.timeoutS * 1000,
    })
    if (r.error?.code === "ENOENT") {
      d.log?.(`refresh ${id}: cannot start claude (${r.error.message})`)
      results.push({ id, started: false, sample: null, authFailed: null })
      continue
    }
    const sample = r.status === 0 && !r.error ? d.readSample(id) : null
    const authFailed = sample ? false : /login|auth|credential/i.test(`${r.stdout}${r.stderr}`) ? true : null // null: unknown, keep the old verdict
    if (!sample) d.log?.(`refresh ${id}: rc=${r.status} ${r.error?.message ?? (r.stderr || r.stdout).trim().slice(0, 200)}`)
    results.push({ id, started: true, sample, authFailed })
  }
  d.update((c) => {
    let out = c
    for (const r of results) {
      if (!r.started) {
        const { [r.id]: _undone, ...refreshed } = out.refreshed // not an attempt: give the budget back
        out = { ...out, refreshed }
        continue
      }
      if (r.authFailed !== null) out = { ...out, auth_failed: { ...out.auth_failed, [r.id]: r.authFailed } }
      if (r.sample) out = mergeSample(out, r.id, r.sample)
    }
    return out
  })
}

export interface BeforePick {
  reg: Registry
  lane: string
  now: number
  /** Claims the due ids atomically (budget stamped); returns the ones this caller won. */
  claim: (ids: string[]) => string[]
  /** Blocking refresh of already-claimed ids (account has no sample at all). */
  runSync: (ids: string[]) => void
  /** Detached, fire-and-forget refresh of already-claimed ids. */
  detach: (ids: string[]) => void
  cache: Cache
}

/**
 * Refresh policy of `pick`: never block while a usable sample exists, and never block the interactive lane.
 * Only a non-interactive pick on an account with no sample (or one past STALE_OK_MS) refreshes synchronously;
 * every other due account is refreshed in the background. Ids are claimed atomically first.
 */
export function refreshBeforePick(b: BeforePick): { sync: string[]; background: string[] } {
  const due = needsRefresh(b.reg, b.cache, b.now)
  const claimed = due.length ? b.claim(due) : []
  const noSample = (id: string) => !b.cache.samples[id] || b.now - b.cache.samples[id].ts >= STALE_OK_MS
  const sync = b.lane === "interactive" ? [] : claimed.filter(noSample)
  const background = claimed.filter((id) => !sync.includes(id))
  if (background.length) b.detach(background)
  if (sync.length) b.runSync(sync)
  return { sync, background }
}

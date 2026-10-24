// Claude account registry, quota cache and picker rule v1 (docs/claude-accounts.md).
// Pure logic + small file helpers; scripts/claude-account.ts is the CLI over it.
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join, resolve } from "node:path"

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
export type Pick = { picked: string; reason: string } | { picked: "iu"; reason: string }

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

/** Registry id for a CLAUDE_CONFIG_DIR value; unset or empty -> "a" (the default account). */
export function accountFromConfigDir(reg: Registry, configDir: string | undefined): string {
  if (!configDir) return defaultAccountId(reg)
  const want = resolve(expandHome(configDir))
  for (const [id, a] of Object.entries(reg.accounts)) if (accountDir(a) === want) return id
  return defaultAccountId(reg)
}
const defaultAccountId = (reg: Registry) => Object.entries(reg.accounts).find(([, a]) => a.dir === null)?.[0] ?? "a"

export function loadCache(path = cachePath()): Cache {
  try {
    return { ...emptyCache(), ...JSON.parse(readFileSync(path, "utf8")) }
  } catch {
    return emptyCache()
  }
}

export function writeAtomic(path: string, data: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const tmp = `${path}.${process.pid}.tmp`
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
export function pick(reg: Registry, cache: Cache, lane: string, nowMs: number): Pick {
  const r = pickRaw(reg, cache, lane, nowMs)
  return r.picked !== "iu" && r.reason !== "interactive-fallback" && isStaleOk(cache, r.picked, nowMs) ? { picked: r.picked, reason: "stale-ok" } : r
}

function pickRaw(reg: Registry, cache: Cache, lane: string, nowMs: number): Pick {
  const ids = Object.keys(reg.accounts)
  const ok = ids.filter((id) => eligible(reg, cache, id, nowMs))
  const bulk = lane !== "interactive"

  if (bulk) {
    const expiring = ok
      .filter((id) => {
        const x = cache.samples[id]
        return x.w_reset !== null && x.w_reset * 1000 - nowMs < EXPIRING_S * 1000 && (x.w ?? 0) < EXPIRING_WEEKLY_MAX
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
  a: { s: number | null; w: number | null }
  b: { s: number | null; w: number | null }
}

export function pickLine(cache: Cache, lane: string, p: Pick, nowMs: number): PickLine {
  const v = (id: string) => ({ s: cache.samples[id]?.s ?? null, w: cache.samples[id]?.w ?? null })
  return { ts: new Date(nowMs).toISOString(), lane, picked: p.picked, reason: p.reason, a: v("a"), b: v("b") }
}

/** Shell fragment for a pick; null for the IU spill signal. */
export function shellLine(reg: Registry, p: Pick): string | null {
  if (p.picked === "iu") return null
  const dir = accountDir(reg.accounts[p.picked])
  return dir === null ? "unset CLAUDE_CONFIG_DIR" : `export CLAUDE_CONFIG_DIR=${dir}`
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


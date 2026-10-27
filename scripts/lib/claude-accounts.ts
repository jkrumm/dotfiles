// Claude account registry, quota cache and picker rule v1 (docs/claude-accounts.md).
// Pure logic + small file helpers; scripts/claude-account.ts is the CLI over it.
import { createHash } from "node:crypto"
import { closeSync, fsyncSync, linkSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, statSync, unlinkSync, writeFileSync, writeSync } from "node:fs"
import { homedir, userInfo } from "node:os"
import { dirname, join, resolve } from "node:path"

/** Account whose config dir is the default ~/.claude (CLAUDE_CONFIG_DIR unset). */
export const DEFAULT_ACCOUNT_ID = "iu"
/** pick() result when no account is usable: the caller spills to its IU path (not an account id). */
export const SPILL = "spill"
export const SESSION_MAX = 85
export const WEEKLY_MAX = 90
/** Weekly ceiling while the window resets within EXPIRING_S: the last points are use-it-or-lose-it, so squeeze them. */
export const WEEKLY_MAX_EXPIRING = 98
export const FRESH_MS = 10 * 60_000
export const STALE_OK_MS = 6 * 3600_000
/** a dead login is re-probed (in the background) at most this often */
export const AUTH_RETRY_MS = 30 * 60_000
export const REFRESH_MIN_MS = 5 * 60_000
export const EXPIRING_S = 24 * 3600
/** Weekly% may run this many points ahead of the elapsed share of the 7-day window before an account counts as over pace. */
export const PACE_MARGIN = 15
/** Session% points the home account may run ahead of the other before a spawn moves to the emptier 5h window. */
export const SESSION_MARGIN = 20
const WEEK_S = 7 * 24 * 3600
export const EXPIRING_WEEKLY_MAX = 70

export interface Account {
  dir: string | null
  plan: string
  /** Capacity units; optional, defaults from the plan (see accountUnits). */
  units?: { session: number; weekly: number }
  homeLanes: string[]
  /** macOS app (as `open -a` names it) signed in to this account; where `claude-relogin` opens the authorize URL. Absent = system default. */
  loginBrowser?: string
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

/** The keepalive job's log: its stdout/stderr, and the stdio of the detached refresh a pick spawns. */
export const keepaliveLogPath = () => join(homedir(), "Library", "Logs", "claude-accounts-keepalive.log")

export const expandHome = (p: string) => (p === "~" ? homedir() : p.startsWith("~/") ? join(homedir(), p.slice(2)) : p)

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v)
const numOrNull = (v: unknown) => v === null || isNum(v)

function validAccount(a: unknown): a is Account {
  const x = a as Account | null
  return (
    !!x && typeof x === "object" &&
    (x.dir === null || typeof x.dir === "string") &&
    typeof x.plan === "string" &&
    (x.units === undefined || (!!x.units && isNum(x.units.session) && isNum(x.units.weekly))) &&
    Array.isArray(x.homeLanes) && x.homeLanes.every((l) => typeof l === "string") &&
    (x.loginBrowser === undefined || typeof x.loginBrowser === "string") &&
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

/** Capacity units of an account: the registry's own, else from the plan (max20x 4 / 2, anything else 1 / 1; measured ratios, docs/claude-accounts.md). */
export const accountUnits = (a: Account): { session: number; weekly: number } => a.units ?? (a.plan === "max20x" ? { session: 4, weekly: 2 } : { session: 1, weekly: 1 })

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
  // The sample's `src` flips to "oauth" when a refresh lands later, so the verify suite reads this stamp for "a statusline fed it".
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

/** Keychain service holding an account's Claude Code login: the default dir has the bare name, any other dir the first 8 hex of sha256(abs config dir). */
export const keychainService = (dir: string | null): string =>
  dir === null ? "Claude Code-credentials" : `Claude Code-credentials-${createHash("sha256").update(resolve(dir)).digest("hex").slice(0, 8)}`

/**
 * `security find-generic-password` args for an account's item. Claude Code files it under acct = $USER, so a process
 * that ran without USER leaves a second item (acct "unknown") under the same service; without `-a` the lookup may
 * return that stale twin (seen on the mini 2026-10-27: a 58 h expired copy behind every 401 and a false expiry WARN).
 */
export const keychainLookupArgs = (svc: string, env: Record<string, string | undefined>): string[] =>
  ["find-generic-password", "-s", svc, "-a", env.USER || userInfo().username, "-w"]

/** Access token out of the Keychain item's JSON (`claudeAiOauth.accessToken`); null for anything else. Never log the result. */
export function tokenFromCredentials(raw: string): string | null {
  try {
    const t = (JSON.parse(raw) as { claudeAiOauth?: { accessToken?: unknown } })?.claudeAiOauth?.accessToken
    return typeof t === "string" && t ? t : null
  } catch {
    return null
  }
}

// ── Login expiry ────────────────────────────────────────────────────────────────────────────────────────────────
// The Keychain item also carries `claudeAiOauth.refreshTokenExpiresAt` (grant + 30 d, epoch ms, not extended by
// rotation) and `expiresAt` (the 8 h access token). Only these two timestamps and the plan tier (`rateLimitTier`) are ever read out of it.

/** WARN at or below this many ms of refresh-token life left. */
export const LOGIN_WARN_MS = 7 * 86400_000
/** FAIL at or below this many ms left (or when already past). */
export const LOGIN_FAIL_MS = 2 * 86400_000

export interface LoginTimestamps {
  refreshTokenExpiresAt: number | null
  expiresAt: number | null
}

/** The two expiry timestamps out of the Keychain item's JSON; null when it is not a credentials blob. Never touches the tokens. */
export function expiryFromCredentials(raw: string): LoginTimestamps | null {
  try {
    const o = (JSON.parse(raw) as { claudeAiOauth?: Record<string, unknown> })?.claudeAiOauth
    if (!o || typeof o !== "object") return null
    const ms = (v: unknown) => (isNum(v) && v > 0 ? v : null)
    return { refreshTokenExpiresAt: ms(o.refreshTokenExpiresAt), expiresAt: ms(o.expiresAt) }
  } catch {
    return null
  }
}

/**
 * The Keychain item's `claudeAiOauth.rateLimitTier` (e.g. `default_claude_max_5x`): the plan marker, not a secret.
 * Null for anything but a short string. Never touches a token field.
 */
export function tierFromCredentials(raw: string): string | null {
  try {
    const t = (JSON.parse(raw) as { claudeAiOauth?: { rateLimitTier?: unknown } })?.claudeAiOauth?.rateLimitTier
    return typeof t === "string" && t && t.length <= 64 ? t : null
  } catch {
    return null
  }
}

/** `default_claude_max_20x` -> `max20x`; null when the tier carries no Max multiple. */
export function planFromTier(tier: string | null): string | null {
  const m = tier ? /max_(\d+)x/.exec(tier) : null
  return m ? `max${m[1]}x` : null
}

export type LoginGrade = "PASS" | "WARN" | "FAIL"

/** PASS > 7 d, WARN <= 7 d, FAIL <= 2 d or past; no timestamp (unreadable item) is a WARN, never a FAIL. */
export function gradeLogin(refreshTokenExpiresAt: number | null, nowMs: number): LoginGrade {
  if (refreshTokenExpiresAt === null) return "WARN"
  const left = refreshTokenExpiresAt - nowMs
  return left <= LOGIN_FAIL_MS ? "FAIL" : left <= LOGIN_WARN_MS ? "WARN" : "PASS"
}

export interface LoginRow {
  id: string
  /** the account owns the default ~/.claude (CLAUDE_CONFIG_DIR unset) */
  default: boolean
  /** what the login's remaining life says */
  grade: LoginGrade
  /**
   * What the graders (verify rows, heartbeat) act on: the grade, except that a non-default account never reaches FAIL
   * (the picker routes around a dead one, as auth/<id> already treats it). The default account keeps its grade.
   */
  severity: LoginGrade
  /** epoch ms of the refresh token's end of life; null when the item could not be read */
  refresh_expires_at: number | null
  access_expires_at: number | null
  /** the Keychain item's raw rateLimitTier, null when absent or unreadable */
  tier: string | null
  /** plan parsed from the tier (`max20x` / `max5x`), null when undetectable */
  plan_detected: string | null
  days_left: number | null
  expired: boolean
  detail: string
}

/**
 * Grade of every enabled account's login from its own Keychain item (read-only `security … -w`, 0 tokens, nothing
 * logged but timestamps and the plan tier). `ids` selects accounts instead, disabled ones included (a first login).
 */
export function readLoginExpiry(d: { reg: Registry; spawn: Spawner; securityBin?: string; baseEnv: Record<string, string | undefined>; now: number; ids?: string[] }): LoginRow[] {
  return Object.entries(d.reg.accounts).filter(([id, a]) => (d.ids ? d.ids.includes(id) : a.enabled)).map(([id, a]) => {
    const svc = keychainService(accountDir(a))
    const kc = d.spawn(d.securityBin ?? SECURITY_BIN, keychainLookupArgs(svc, d.baseEnv), { env: d.baseEnv as Record<string, string>, timeoutMs: KEYCHAIN_TIMEOUT_MS })
    const isDefault = a.dir === null
    const row = (grade: LoginGrade) => ({ id, default: isDefault, grade, severity: !isDefault && grade === "FAIL" ? ("WARN" as const) : grade })
    const unreadable = (why: string): LoginRow => ({ ...row("WARN"), refresh_expires_at: null, access_expires_at: null, tier: null, plan_detected: null, days_left: null, expired: false, detail: `login expiry unreadable (${why})` })
    if (kc.error || kc.status !== 0) return unreadable(`Keychain '${svc}': ${kc.error?.message ?? (kc.stderr.trim().slice(0, 120) || `rc=${kc.status}`)}`)
    const t = expiryFromCredentials(kc.stdout)
    if (!t) return unreadable(`Keychain '${svc}' is not a Claude login`)
    const tier = tierFromCredentials(kc.stdout)
    const plan = { tier, plan_detected: planFromTier(tier) }
    if (t.refreshTokenExpiresAt === null) return { ...unreadable("no refreshTokenExpiresAt in the Keychain item"), access_expires_at: t.expiresAt, ...plan }
    const left = t.refreshTokenExpiresAt - d.now
    const days = Math.round((left / 86400_000) * 10) / 10
    const expired = left <= 0
    const date = new Date(t.refreshTokenExpiresAt).toISOString().slice(0, 10)
    return {
      ...row(gradeLogin(t.refreshTokenExpiresAt, d.now)), refresh_expires_at: t.refreshTokenExpiresAt, access_expires_at: t.expiresAt, ...plan, days_left: days, expired,
      detail: expired ? `login expired ${date} (${-days} d ago): /login needed` : `login valid until ${date} (${days} d left)`,
    }
  })
}

// ── Re-login asks (keepalive path) ──────────────────────────────────────────────────────────────────────────────
// A dead or soon-dead login asks its owner for a re-login through a native approval dialog (claude-relogin --ask).
// At most one ask per account per 24 h and one dialog per machine per hour, never an auto-run: the dialog is the human's click.

export const RELOGIN_ASK_INTERVAL_MS = 24 * 3600_000
export const RELOGIN_CAP_INTERVAL_MS = 3600_000
const reloginStampPath = (dir: string, id: string) => file(dir, id, "relogin-ask.json")
const reloginCapPath = (dir: string) => join(dir, "relogin-ask.cap")

/**
 * Claim a time stamp file atomically: exclusive create (private temp file hard-linked into place, so a reader never
 * sees a stamp without its time). A stamp younger than `intervalMs` means someone already holds the slot; an older,
 * unreadable or future one is replaced (unlink + exclusive create: of two racing replacers exactly one wins).
 */
function claimStamp(path: string, nowMs: number, intervalMs: number): boolean {
  mkdirSync(dirname(path), { recursive: true })
  const create = (): boolean => {
    const tmp = `${path}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`
    writeFileSync(tmp, JSON.stringify({ ts: nowMs }))
    try {
      linkSync(tmp, path)
      return true
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e
      return false
    } finally {
      unlinkSync(tmp)
    }
  }
  if (create()) return true
  const ts = (readJson(path) as { ts?: unknown } | null)?.ts
  if (isNum(ts) && nowMs - ts >= 0 && nowMs - ts < intervalMs) return false
  try {
    unlinkSync(path)
  } catch {
    return false // someone else replaced it first
  }
  return create()
}
const releaseStamp = (path: string) => {
  try {
    unlinkSync(path)
  } catch {
    // already gone
  }
}

export interface ReloginCandidate {
  id: string
  reason: string
}

/**
 * Accounts that need a human: a refresh that ended `auth-failed`, or a login whose known end of life crossed the WARN
 * line (<= 7 d, incl. already expired). An unreadable item (no date) never asks: that proves nothing about the login.
 */
export function reloginCandidates(results: Record<string, RefreshResult>, logins: LoginRow[]): ReloginCandidate[] {
  const out: ReloginCandidate[] = []
  for (const [id, r] of Object.entries(results)) if (r === "auth-failed") out.push({ id, reason: "login is dead" })
  for (const l of logins) {
    if (l.grade === "PASS" || l.refresh_expires_at === null || out.some((c) => c.id === l.id)) continue
    out.push({ id: l.id, reason: l.expired ? "login expired" : `login ends in ${l.days_left} d` })
  }
  return out
}

export interface AskOutcome {
  /** the ask process started */
  asked: string[]
  /** the spawn threw: nothing is stamped, the next run retries */
  failed: string[]
  /** due, but the one-dialog-per-hour machine cap was taken: the next run retries */
  capped: string[]
}

/**
 * Asks (via `ask`) for every due candidate. Both slots are claimed atomically BEFORE the ask (the 24 h stamp per
 * account, the 1 h cap per machine), so two keepalive runs never ask twice; they are given back when the ask throws,
 * so the 24 h mute only ever follows an ask that really started. One account's failure never stops the others.
 */
export function askRelogins(d: {
  results: Record<string, RefreshResult>
  logins: LoginRow[]
  now: number
  dir?: string
  ask: (c: ReloginCandidate) => void
  log?: (msg: string) => void
}): AskOutcome {
  const dir = d.dir ?? cacheDir()
  const out: AskOutcome = { asked: [], failed: [], capped: [] }
  for (const c of reloginCandidates(d.results, d.logins)) {
    try {
      if (!claimStamp(reloginStampPath(dir, c.id), d.now, RELOGIN_ASK_INTERVAL_MS)) continue
      if (!claimStamp(reloginCapPath(dir), d.now, RELOGIN_CAP_INTERVAL_MS)) {
        releaseStamp(reloginStampPath(dir, c.id))
        out.capped.push(c.id)
        continue
      }
      try {
        d.ask(c)
        out.asked.push(c.id)
      } catch (e) {
        releaseStamp(reloginStampPath(dir, c.id))
        releaseStamp(reloginCapPath(dir))
        throw e
      }
    } catch (e) {
      out.failed.push(c.id)
      d.log?.(`re-login ask for ${c.id} failed: ${(e as Error).message}`)
    }
  }
  return out
}

export const OAUTH_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
/** Same request shape as scripts/fetch_usage.py fetch(). */
export const oauthUsageHeaders = (token: string): Record<string, string> => ({ Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20", Accept: "application/json" })
export const OAUTH_TIMEOUT_MS = 10_000
const KEYCHAIN_TIMEOUT_MS = 15_000
export const SECURITY_BIN = "/usr/bin/security"

/** Parse the `GET /api/oauth/usage` body (`five_hour` / `seven_day` with `utilization` percent + ISO `resets_at`); a window it omits stays null. */
export function sampleFromOAuthUsage(json: unknown, nowMs: number): Sample | null {
  if (!json || typeof json !== "object" || Array.isArray(json)) return null
  const j = json as Record<string, unknown>
  // a window counts only with a numeric utilization and a string resets_at; anything else is dropped (null)
  const window = (v: unknown): Window => {
    const w = v as { utilization?: unknown; resets_at?: unknown } | null
    return w && typeof w === "object" && typeof w.utilization === "number" && typeof w.resets_at === "string" ? { utilization: w.utilization, resets_at: w.resets_at } : null
  }
  return sampleFromClaudeJson({ cachedUsageUtilization: { fetchedAtMs: nowMs, utilization: { five_hour: window(j.five_hour), seven_day: window(j.seven_day) } } }, "oauth")
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

const weeklyMax = (x: Sample, nowMs: number) => (x.w_reset !== null && x.w_reset * 1000 - nowMs > 0 && x.w_reset * 1000 - nowMs < EXPIRING_S * 1000 ? WEEKLY_MAX_EXPIRING : WEEKLY_MAX)

/** Enabled, logged in, not exhausted, and every window young enough to judge (< 6 h) is below its threshold. Each window is judged by its own timestamp. */
export function eligible(reg: Registry, cache: Cache, id: string, nowMs: number): boolean {
  const a = Object.hasOwn(reg.accounts, id) ? reg.accounts[id] : undefined
  if (!a?.enabled || cache.auth_failed[id]) return false
  const x = cache.samples[id]
  if (!x || !usable(x, nowMs)) return false
  if (hasS(x) && nowMs - (x.s_ts ?? 0) < STALE_OK_MS && x.s! >= SESSION_MAX) return false
  if (hasW(x) && nowMs - (x.w_ts ?? 0) < STALE_OK_MS && x.w! >= weeklyMax(x, nowMs)) return false
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

/** Rule v1.4 (docs/claude-accounts.md §The picker). Among several candidates the best one wins; ties follow registry order. */
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
  // weekly points left below the account's own ceiling, scaled by its plan; a missing weekly window is open headroom
  const headroom = (id: string) => {
    const x = cache.samples[id]
    return (x && hasW(x) ? weeklyMax(x, nowMs) - x.w! : WEEKLY_MAX) * accountUnits(reg.accounts[id]).weekly
  }
  const mostHeadroom = (cands: string[]) => cands.reduce<string | undefined>((best, id) => (best === undefined || headroom(id) > headroom(best) ? id : best), undefined)
  const homes = homeIds(reg, lane)
  const home = mostHeadroom(ok.filter((id) => homes.includes(id)))
  if (home && overPace(reg, cache, home, nowMs)) {
    const calm = mostHeadroom(ok.filter((id) => id !== home && !overPace(reg, cache, id, nowMs)))
    if (calm) return { picked: calm, reason: "pace" }
  }
  if (home) {
    const hs = cache.samples[home]
    const freshS = (x: Sample) => hasS(x) && nowMs - (x.s_ts ?? 0) < STALE_OK_MS
    const emptier = ok
      .filter((id) => {
        const x = cache.samples[id]
        return id !== home && freshS(x) && freshS(hs) && !overPace(reg, cache, id, nowMs) && hs.s! - x.s! > SESSION_MARGIN
      })
      .reduce<string | undefined>((best, id) => {
        if (best === undefined) return id
        const d = cache.samples[id].s! - cache.samples[best].s!
        return d < 0 || (d === 0 && headroom(id) > headroom(best)) ? id : best
      }, undefined)
    if (emptier) return { picked: emptier, reason: "session" }
    return { picked: home, reason: "home" }
  }
  const other = mostHeadroom(ok)
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

export interface HttpResponse {
  status: number
  json: unknown
}
/** GET with a hard timeout; throws on network errors. */
export type HttpGet = (url: string, headers: Record<string, string>, timeoutMs: number) => Promise<HttpResponse>

export interface RefreshDeps {
  reg: Registry
  spawn: Spawner
  httpGet: HttpGet
  /** Override for tests; defaults to SECURITY_BIN. */
  securityBin?: string
  claudeBin: string
  baseEnv: Record<string, string | undefined>
  dir?: string
  now: () => number
  /** Accounts to refresh. They are already claimed (budget stamped) by the caller. */
  ids: string[]
  log?: (msg: string) => void
  /** The peer machine's `claude-account usage --json` body (parsed), fetched once per run; throws or answers null when unreachable. Absent = no import. */
  peerUsage?: () => unknown | Promise<unknown>
}

type LoginVerdict = { loggedIn: boolean | null; startFailed?: string }

/** `claude auth status` (0 tokens): the login verdict, null when the binary gave no usable answer. */
function loginVerdict(d: RefreshDeps, env: Record<string, string>): LoginVerdict {
  const r = d.spawn(d.claudeBin, ["auth", "status"], { env, timeoutMs: 30_000 })
  // any spawn error but a timeout means the binary never ran an attempt; a timeout says nothing and keeps the claim
  if (r.error && r.error.code !== "ETIMEDOUT") return { loggedIn: null, startFailed: `${r.error.code ?? "error"}: ${r.error.message}` }
  try {
    const v = (JSON.parse(r.stdout) as { loggedIn?: unknown }).loggedIn
    return { loggedIn: typeof v === "boolean" ? v : null }
  } catch {
    return { loggedIn: null }
  }
}

/** Access token of the account's Keychain item; null (with the reason logged) when it cannot be read. Never log the result. */
function keychainToken(d: RefreshDeps, id: string): string | null {
  const svc = keychainService(accountDir(d.reg.accounts[id]))
  const kc = d.spawn(d.securityBin ?? SECURITY_BIN, keychainLookupArgs(svc, d.baseEnv), { env: d.baseEnv as Record<string, string>, timeoutMs: KEYCHAIN_TIMEOUT_MS })
  const token = kc.status === 0 && !kc.error ? tokenFromCredentials(kc.stdout) : null
  if (!token) d.log?.(`refresh ${id}: no Keychain token (${svc}): ${kc.error?.message ?? (kc.stderr.trim().slice(0, 200) || `rc=${kc.status}`)}`)
  return token
}

/** One GET of the usage endpoint; the status is kept so the caller can tell an expired token (401) from the rest. */
async function fetchUsage(d: RefreshDeps, id: string, token: string): Promise<{ sample: Sample | null; status: number | null }> {
  try {
    const r = await d.httpGet(OAUTH_USAGE_URL, oauthUsageHeaders(token), OAUTH_TIMEOUT_MS)
    const sample = r.status === 200 ? sampleFromOAuthUsage(r.json, d.now()) : null
    if (!sample) d.log?.(`refresh ${id}: usage endpoint gave no sample (HTTP ${r.status})`)
    return { sample, status: r.status }
  } catch (e) {
    d.log?.(`refresh ${id}: usage endpoint failed: ${e instanceof Error ? e.name : typeof e}`) // name only: never echo a message that could carry request details
    return { sample: null, status: null }
  }
}

/**
 * Sample from the OAuth usage endpoint with the account's own Keychain token (read-only, 0 tokens, no window
 * priming). Every failure (locked Keychain, HTTP error incl. 429, bad body) is just "no sample": none of them
 * proves anything about the login. The one exception to "just fail" is HTTP 401: the access token of an idle
 * account expires and nothing renews it, but `claude auth status` (0 tokens) makes the binary renew it in the
 * Keychain, so a 401 runs it (`status`, shared with the caller's verdict), re-reads the token and retries the GET
 * once. The token is never logged or stored.
 */
async function oauthSample(d: RefreshDeps, id: string, status: () => LoginVerdict): Promise<Sample | null> {
  const token = keychainToken(d, id)
  if (!token) return null
  const first = await fetchUsage(d, id, token)
  if (first.status !== 401) return first.sample
  d.log?.(`refresh ${id}: usage endpoint HTTP 401, renewing the access token via \`claude auth status\``)
  if (status().startFailed) return null
  const renewed = keychainToken(d, id)
  return renewed ? (await fetchUsage(d, id, renewed)).sample : null
}

/**
 * Refresh of already-claimed accounts. The login verdict is decoupled from samples: the OAuth usage endpoint gives
 * a sample (which also proves the login); without one, `claude auth status` decides. Each result touches only that
 * account's own files. A binary that could not start gives the claim back (it was not an attempt); a timeout or an
 * unparsable answer keeps it and leaves the auth mark alone.
 * Outcome per account: `fresh` (sample fetched this run), `auth-ok` / `auth-failed` (verdict recorded), `stale`
 * (logged in, but the endpoint gave no sample and the stored one is older than STALE_OK_MS: the feed is silently
 * dying, so the keepalive must go red) or `unresolved`.
 */
export type RefreshResult = "fresh" | "auth-ok" | "stale" | "auth-failed" | "unresolved"

/**
 * Quota is per account, not per machine, so the peer machine's samples are as good as ours: an idle login whose
 * Keychain access token expired gets 401 on every usage GET (and `claude auth status` no longer renews it), while the
 * peer, where the account is busy, has fresh numbers. Each locally registered, enabled row of the peer's `usage --json`
 * becomes a `peer` sample (window timestamps rebuilt from the row's ages, so the original age is never laundered) and a
 * future `exhausted_until` becomes a mark; `mergeSample` keeps whichever window is newer. Auth state is never imported:
 * logins are per machine. Returns the ids that received a sample. A peer that is unreachable or garbled is one log line.
 */
async function importPeerSamples(d: RefreshDeps): Promise<Set<string>> {
  const imported = new Set<string>()
  if (!d.peerUsage) return imported
  let body: unknown
  try {
    body = await d.peerUsage()
  } catch (e) {
    d.log?.(`refresh: peer usage unavailable: ${(e instanceof Error ? e.message : String(e)).slice(0, 120)}`)
    return imported
  }
  const rows = (body as { accounts?: unknown } | null)?.accounts
  if (!Array.isArray(rows)) {
    d.log?.("refresh: peer usage unreadable, no samples imported")
    return imported
  }
  const now = d.now()
  const pct = (v: unknown) => (isNum(v) ? v : null)
  for (const r of rows as Record<string, unknown>[]) {
    const id = r?.id
    if (typeof id !== "string" || !Object.hasOwn(d.reg.accounts, id) || !d.reg.accounts[id].enabled) continue
    const win = (value: unknown, reset: unknown, age: unknown) => {
      const v = pct(value)
      return v === null ? { v, reset: null, ts: null } : { v, reset: pct(reset), ts: isNum(age) ? now - age * 1000 : null }
    }
    const s = win(r.five_hour, r.five_hour_resets_at, r.five_hour_age_s)
    const w = win(r.seven_day, r.seven_day_resets_at, r.seven_day_age_s)
    if (s.v !== null || w.v !== null) {
      saveSample(id, { s: s.v, s_reset: s.reset, s_ts: s.ts, w: w.v, w_reset: w.reset, w_ts: w.ts, src: "peer" }, d.dir)
      imported.add(id)
    }
    if (isNum(r.exhausted_until) && r.exhausted_until * 1000 > now) markExhausted(id, r.exhausted_until, d.dir)
  }
  return imported
}

export async function runRefresh(d: RefreshDeps): Promise<Record<string, RefreshResult>> {
  const results: Record<string, RefreshResult> = {}
  const imported = d.ids.length ? await importPeerSamples(d) : new Set<string>()
  for (const id of d.ids) {
    results[id] = "unresolved" // neither a fresh sample nor an auth verdict, until proven otherwise
    const env = refreshEnv(d.baseEnv, accountDir(d.reg.accounts[id]))
    let verdict: LoginVerdict | undefined
    const status = () => (verdict ??= loginVerdict(d, env)) // at most one `auth status` per account and run
    if (imported.has(id) && sampleAge(loadCache(d.dir).samples[id], d.now()) < FRESH_MS) {
      // A fresh peer sample replaces the endpoint GET, but says nothing about THIS machine's login: the verdict still runs.
      const v = status()
      if (v.startFailed) {
        d.log?.(`refresh ${id}: cannot start claude (${v.startFailed})`)
        releaseClaim(id, d.dir)
      } else if (v.loggedIn !== null) setAuthFailed(id, !v.loggedIn, d.now(), d.dir)
      results[id] = v.loggedIn === false ? "auth-failed" : "fresh"
      continue
    }
    const sample = await oauthSample(d, id, status)
    if (sample) {
      saveSample(id, sample, d.dir)
      setAuthFailed(id, false, d.now(), d.dir)
      results[id] = "fresh"
      continue
    }
    const v = status()
    if (v.startFailed) {
      d.log?.(`refresh ${id}: cannot start claude (${v.startFailed})`)
      releaseClaim(id, d.dir)
      continue
    }
    if (v.loggedIn === null) {
      d.log?.(`refresh ${id}: no sample and no auth verdict`)
      continue
    }
    setAuthFailed(id, !v.loggedIn, d.now(), d.dir)
    if (!v.loggedIn) {
      results[id] = "auth-failed"
      continue
    }
    const age = newestAge(loadCache(d.dir).samples[id], d.now()) // the same "usable" test the picker applies
    results[id] = age >= STALE_OK_MS ? "stale" : "auth-ok"
    if (results[id] === "stale") d.log?.(`refresh ${id}: logged in but the usage endpoint gave no sample and the stored one is ${Number.isFinite(age) ? `${Math.round(age / 3600_000)} h old` : "missing"}`)
  }
  return results
}

export interface BeforePick {
  reg: Registry
  lane: string
  now: number
  cache: Cache
  /** Claims the due ids atomically (budget stamped); returns the ones this caller won. */
  claim: (ids: string[]) => string[]
  /** Blocking refresh of already-claimed ids (account has no usable sample). */
  runSync: (ids: string[]) => void | Promise<void>
  /** Detached, fire-and-forget refresh of already-claimed ids. */
  detach: (ids: string[]) => void
}

/**
 * Refresh policy of `pick`, the same on every lane except for blocking: a due account (no sample, or a window older
 * than FRESH_MS) is claimed first (5-min budget), then refreshed detached in the background. Only a non-interactive
 * lane waits, and only for an account with no usable sample; the interactive lane never blocks and never spends
 * tokens (the refresh is the 0-token usage GET / `claude auth status`), so a pick stays instant.
 */
export async function refreshBeforePick(b: BeforePick): Promise<{ sync: string[]; background: string[] }> {
  const due = dueIds(b.reg, b.cache, b.now)
  const claimed = due.length ? b.claim(due) : []
  // a due auth-failed account is a retry: never block a pick on it
  const sync = b.lane === "interactive" ? [] : claimed.filter((id) => !b.cache.auth_failed[id] && !usable(b.cache.samples[id], b.now))
  const background = claimed.filter((id) => !sync.includes(id))
  if (background.length) b.detach(background)
  if (sync.length) await b.runSync(sync)
  return { sync, background }
}

/** Account a session ran on, from the newest `session_env` line for it in the hook logs (newest file first). */
export function sessionAccount(sessionId: string, logDir: string): string | null {
  if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) return null
  let files: string[]
  try {
    files = readdirSync(logDir).filter((f) => f.endsWith(".jsonl")).sort().reverse()
  } catch {
    return null
  }
  for (const f of files) {
    let lines: string[]
    try {
      lines = readFileSync(join(logDir, f), "utf8").split("\n")
    } catch {
      continue
    }
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].includes(sessionId) || !lines[i].includes("session_env")) continue
      try {
        const e = JSON.parse(lines[i])
        if (e.event === "session_env" && e.data?.session === sessionId) return typeof e.data.account === "string" ? e.data.account : null
      } catch {
        // a torn line is skipped
      }
    }
  }
  return null
}

/**
 * Id of the newest session transcript Claude Code keeps for a cwd: `<projectsDir>/<cwd with every non-alphanumeric
 * as '-'>/<id>.jsonl`, newest mtime first (what `claude --continue` resumes). `projects/` is shared by every
 * account. null when the dir or a transcript is missing.
 */
export function latestSessionId(projectsDir: string, cwd: string): string | null {
  const dir = join(projectsDir, cwd.replace(/[^A-Za-z0-9]/g, "-"))
  let best: { id: string; mtime: number } | null = null
  try {
    for (const f of readdirSync(dir)) {
      const m = /^([A-Za-z0-9_-]+)\.jsonl$/.exec(f)
      if (!m) continue
      let mtime: number
      try {
        mtime = statSync(join(dir, f)).mtimeMs
      } catch {
        continue // vanished between readdir and stat (a session cleaning up): skip it, keep the others
      }
      if (!best || mtime > best.mtime) best = { id: m[1], mtime }
    }
  } catch {
    return null
  }
  return best?.id ?? null
}

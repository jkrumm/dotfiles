#!/usr/bin/env bun
// claude-account — Claude account registry, picker and per-account quota cache (docs/claude-accounts.md).
//
//   claude-account pick --lane <lane> [--why]      (stale accounts refresh in the background; unsampled ones synchronously) stdout: `unset CLAUDE_CONFIG_DIR` | `export CLAUDE_CONFIG_DIR=<dir>` | `spill` (exit 3, no account has headroom); exit 4 = registry unreadable (still prints `unset CLAUDE_CONFIG_DIR`)
//   claude-account usage [--json]          both accounts, from the quota cache
//   claude-account refresh [--ids a,b] [--all]   OAuth usage endpoint sample (the account's own Keychain token, 10s HTTP timeout), else the `claude auth status` verdict, for enabled, due accounts (budget claimed atomically); --all exits 1 when an account got neither a fresh sample nor an auth verdict, or is logged in with its stored sample older than 6 h; --ids also retries an auth-failed account before its 30 min cooldown; --all ignores the 10 min freshness and the auth cooldown (login keepalive), the 5 min claim still applies
//   claude-account pick ... --dry          answer without refreshing and without a picks.jsonl line (verify suite)
//   claude-account record --account <id> --s <pct> [--s-reset <epoch>] [--w <pct>] [--w-reset <epoch>]
//                                          statusline feed (native rate_limits)
//   claude-account account [--badge]       registry id of this session (CLAUDE_CONFIG_DIR unset -> default); --badge: upper-case id, only with >1 enabled account
//   claude-account env <id>                shell line forcing an enabled account (c --account me); exit 2 if unknown or disabled
//   claude-account session <sessionId>     registry id the session ran on (hook log); exit 1 if unknown or disabled — `c --resume` pins to it
//   claude-account exhausted --account <id> --until <epoch>   limit-event mark, honoured until then
//
// Idle-account samples: one read-only GET of api.anthropic.com/api/oauth/usage with the account's own Keychain token
// (never copied, logged or written back); `claude -p /usage` no longer refreshes cachedUsageUtilization (2.1.310).
import { spawnSync } from "node:child_process"
import { appendFileSync, mkdirSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import {
  type Cache, type RefreshResult, type Registry, type Sample, type HttpGet, type Spawner, accountFromConfigDir, claimRefresh, defaultAccountId, claudeJsonPath, loadCache, loadRegistry, markExhausted,
  mergeSample, newestAge, pick, pickLine, picksPath, recordSample, refreshBeforePick, runRefresh, sampleFromClaudeJson, sessionAccount, shellLine, SPILL,
} from "./lib/claude-accounts.ts"

const SPILL_EXIT = 3
const REGISTRY_EXIT = 4 // pick answered `unset CLAUDE_CONFIG_DIR` (iu) because the registry was unreadable

function flag(argv: string[], name: string): string | null {
  const i = argv.indexOf(name)
  if (i < 0) return null
  const v = argv[i + 1]
  if (v === undefined || v.startsWith("--")) throw new Error(`${name} needs a value`)
  return v
}
function num(argv: string[], name: string): number | null {
  const v = flag(argv, name)
  if (v === null) return null
  const n = Number(v)
  if (!Number.isFinite(n)) throw new Error(`${name} must be a number`)
  return n
}
function account(reg: Registry, argv: string[]): string {
  const id = flag(argv, "--account")
  if (!id || !Object.hasOwn(reg.accounts, id)) throw new Error(`--account must be one of ${Object.keys(reg.accounts).join(", ")}`)
  return id
}

function readSample(reg: Registry, id: string): Sample | null {
  try {
    return sampleFromClaudeJson(JSON.parse(readFileSync(claudeJsonPath(reg.accounts[id]), "utf8")))
  } catch {
    return null // missing or unreadable .claude.json: the account simply has no sample
  }
}

/** Merge each enabled account's own .claude.json cachedUsageUtilization into the cache. */
function readClaudeJson(reg: Registry, cache: Cache): Cache {
  for (const [id, a] of Object.entries(reg.accounts)) {
    if (!a.enabled) continue
    const s = readSample(reg, id)
    if (s) cache = { ...cache, samples: { ...cache.samples, [id]: mergeSample(cache.samples[id] ?? null, s) } }
  }
  return cache
}

const claudeBin = () => Bun.which("claude") ?? join(homedir(), ".local", "bin", "claude")

const spawner: Spawner = (cmd, args, { env, timeoutMs }) => {
  const r = spawnSync(cmd, args, { env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: timeoutMs })
  const err = r.error as (Error & { code?: string }) | undefined
  return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "", error: err ? { code: err.code, message: err.message } : undefined }
}

const httpGet: HttpGet = async (url, headers, timeoutMs) => {
  const r = await fetch(url, { headers, redirect: "error", signal: AbortSignal.timeout(timeoutMs) })
  let json: unknown = null
  try {
    json = JSON.parse(await r.text())
  } catch {
    // an unreadable body is just "no sample"
  }
  return { status: r.status, json }
}

/**
 * Refresh accounts. `ids` restricts what to consider but still goes through the enabled + due filters and the
 * claim; `claimed` (internal: the detached child of a pick) was already claimed by the parent.
 */
async function refresh(reg: Registry, o: { ids?: string[]; claimed?: string[]; all?: boolean } = {}): Promise<Record<string, RefreshResult>> {
  const enabled = (id: string) => Object.hasOwn(reg.accounts, id) && reg.accounts[id].enabled
  const todo = o.claimed
    ? o.claimed.filter(enabled)
    : claimRefresh(reg, (o.ids ?? Object.keys(reg.accounts)).filter(enabled), Date.now(), readClaudeJson(reg, loadCache()), undefined, !!o.ids || !!o.all, !!o.all) // explicit --ids bypasses the auth-failed cooldown: the documented manual retry
  return runRefresh({
    reg, spawn: spawner, httpGet, securityBin: process.env.CLAUDE_ACCOUNTS_SECURITY_BIN, claudeBin: claudeBin(), baseEnv: process.env, ids: todo, now: Date.now, log: (m) => console.error(m),
  })
}

function usage(reg: Registry, json: boolean): void {
  const cache = readClaudeJson(reg, loadCache())
  const now = Date.now()
  const rows = Object.entries(reg.accounts).map(([id, a]) => {
    const x = cache.samples[id]
    const until = cache.exhausted[id]
    return {
      id, plan: a.plan, enabled: a.enabled,
      five_hour: x?.s ?? null, seven_day: x?.w ?? null, five_hour_resets_at: x?.s_reset ?? null, seven_day_resets_at: x?.w_reset ?? null,
      age_s: x ? Math.round(newestAge(x, now) / 1000) : null,
      five_hour_age_s: x && x.s !== null && x.s_ts !== null ? Math.round((now - x.s_ts) / 1000) : null,
      seven_day_age_s: x && x.w !== null && x.w_ts !== null ? Math.round((now - x.w_ts) / 1000) : null, source: x?.src ?? null,
      auth_ok: !cache.auth_failed[id], exhausted_until: until && until * 1000 > now ? until : null,
    }
  })
  if (json) return void console.log(JSON.stringify({ default_account: defaultAccountId(reg), accounts: rows }, null, 2))
  const reset = (e: number | null) => (e ? new Date(e * 1000).toISOString().slice(5, 16).replace("T", " ") : "-")
  for (const r of rows) {
    console.log(`${r.id} ${r.plan}${r.enabled ? "" : " (disabled)"}  5h ${r.five_hour ?? "-"}% ↺${reset(r.five_hour_resets_at)}  7d ${r.seven_day ?? "-"}% ↺${reset(r.seven_day_resets_at)}  age ${r.age_s ?? "-"}s  auth ${r.auth_ok ? "ok" : "FAILED"}${r.exhausted_until ? "  EXHAUSTED" : ""}`)
  }
}

async function main(argv: string[]): Promise<number> {
  const [cmd, ...rest] = argv
  let reg: Registry
  try {
    reg = loadRegistry()
  } catch (e) {
    if (cmd !== "pick") throw e
    console.error(`claude-account: registry unreadable: ${(e as Error).message}`)
    console.log("unset CLAUDE_CONFIG_DIR") // a pick must always answer: fall back to the default account...
    if (rest.includes("--why")) console.log("# picked=iu reason=registry-error stale=false")
    return REGISTRY_EXIT // ...but never silently: callers warn on 4
  }
  switch (cmd) {
    case "pick": {
      const lane = flag(rest, "--lane")
      if (!lane) throw new Error("usage: claude-account pick --lane <lane>")
      const now = Date.now()
      // Never block while a usable sample exists: stale accounts refresh in the background (budgeted),
      // only an account with no sample at all is refreshed synchronously first.
      const dry = rest.includes("--dry")
      try {
        const cache0 = readClaudeJson(reg, loadCache())
        if (!dry) await refreshBeforePick({
          reg, lane, now, cache: cache0,
          claim: (ids) => claimRefresh(reg, ids, now, cache0),
          runSync: async (ids) => void (await refresh(reg, { claimed: ids })),
          detach: (ids) => Bun.spawn([process.execPath, import.meta.path, "refresh", "--claimed", ids.join(",")], { stdio: ["ignore", "ignore", "ignore"], detached: true }).unref(),
        })
      } catch (e) {
        console.error(`claude-account: refresh skipped: ${(e as Error).message}`) // a pick must always answer; go on with the current cache
      }
      const cache = readClaudeJson(reg, loadCache())
      const p = pick(reg, cache, lane, now)
      if (!dry) {
        try {
          mkdirSync(dirname(picksPath()), { recursive: true })
          appendFileSync(picksPath(), JSON.stringify(pickLine(reg, cache, lane, p, now)) + "\n")
        } catch {
          // the pick log is a dataset, never a gate
        }
      }
      const line = shellLine(reg, p)
      console.log(line ?? SPILL)
      if (rest.includes("--why")) console.log(`# picked=${p.picked} reason=${p.reason} stale=${p.stale}`)
      return line === null ? SPILL_EXIT : 0
    }
    case "usage":
      usage(reg, rest.includes("--json"))
      return 0
    case "refresh": {
      const all = rest.includes("--all")
      const results = await refresh(reg, { ids: flag(rest, "--ids")?.split(","), claimed: flag(rest, "--claimed")?.split(","), all })
      // The keepalive's verdict: an account that got neither a fresh sample nor an auth verdict was not kept alive.
      const unresolved = Object.entries(results).filter(([, r]) => r === "unresolved").map(([id]) => id)
      const stale = Object.entries(results).filter(([, r]) => r === "stale").map(([id]) => id)
      if (all && stale.length) console.error(`claude-account: refresh --all: ${stale.join(", ")} logged in but still without a fresh sample (stored one older than 6 h or missing, see the lines above)`)
      if (all && unresolved.length) console.error(`claude-account: refresh --all: no fresh sample and no auth verdict for ${unresolved.join(", ")}`)
      if (all && (unresolved.length || stale.length)) return 1
      return 0
    }
    case "record": {
      const id = account(reg, rest)
      const part = { s: num(rest, "--s"), w: num(rest, "--w"), s_reset: num(rest, "--s-reset"), w_reset: num(rest, "--w-reset") }
      recordSample(id, part, Date.now())
      return 0
    }
    case "account": {
      const id = accountFromConfigDir(reg, process.env.CLAUDE_CONFIG_DIR) // null: set to a dir no account owns
      if (!rest.includes("--badge")) console.log(id ?? "?")
      else if (id === null) console.log("?")
      else if (Object.values(reg.accounts).filter((a) => a.enabled).length > 1) console.log(id.toUpperCase())
      return 0
    }
    case "env": {
      const id = rest[0]
      const a = id && Object.hasOwn(reg.accounts, id) ? reg.accounts[id] : undefined
      if (!a?.enabled) throw new Error(`env: '${id ?? ""}' is not an enabled account (${Object.keys(reg.accounts).filter((k) => reg.accounts[k].enabled).join(", ")})`)
      console.log(shellLine(reg, { picked: id, reason: "forced", stale: false }))
      return 0
    }
    case "session": {
      const id = rest[0] ? sessionAccount(rest[0], join(homedir(), ".claude", "logs")) : null
      if (!id || !Object.hasOwn(reg.accounts, id) || !reg.accounts[id].enabled) return 1
      console.log(id)
      return 0
    }
    case "exhausted": {
      const id = account(reg, rest)
      const until = num(rest, "--until")
      if (until === null) throw new Error("--until <epoch seconds> is required")
      markExhausted(id, until)
      return 0
    }
    default:
      console.error("usage: claude-account pick|usage|refresh|record|account|env|session|exhausted ...")
      return 2
  }
}

if (import.meta.main) {
  try {
    process.exit(await main(process.argv.slice(2)))
  } catch (e) {
    console.error(`claude-account: ${(e as Error).message}`)
    process.exit(2)
  }
}

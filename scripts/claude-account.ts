#!/usr/bin/env bun
// claude-account — Claude account registry, picker and per-account quota cache (docs/claude-accounts.md).
//
//   claude-account pick --lane <lane>      (stale accounts refresh in the background; unsampled ones synchronously, 75s) stdout: `unset CLAUDE_CONFIG_DIR` | `export CLAUDE_CONFIG_DIR=<dir>` | `iu` (exit 3)
//   claude-account usage [--json]          both accounts, from the quota cache
//   claude-account refresh [--ids a,b]     `claude -p /usage` (75s limit) for enabled, due accounts (budget claimed atomically)
//   claude-account record --account <id> --s <pct> [--s-reset <epoch>] [--w <pct>] [--w-reset <epoch>]
//                                          statusline feed (native rate_limits)
//   claude-account account [--badge]       registry id of this session (CLAUDE_CONFIG_DIR unset -> default); --badge: upper-case id, only with >1 enabled account
//   claude-account exhausted --account <id> --until <epoch>   limit-event mark, honoured until then
//
// We never read a token and make no call to api.anthropic.com/api/oauth/usage ourselves: the official
// binary fetches, and writes cachedUsageUtilization into the account's .claude.json.
import { spawnSync } from "node:child_process"
import { appendFileSync, mkdirSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import {
  type Cache, type Registry, type Sample, type Spawner, accountFromConfigDir, claimRefresh, claudeJsonPath, loadCache, loadRegistry, markExhausted, mergeSample,
  REFRESH_TIMEOUT_S, pick, pickLine, picksPath, recordSample, refreshBeforePick, runRefresh, sampleFromClaudeJson, shellLine, updateCache,
} from "./lib/claude-accounts.ts"

const IU_EXIT = 3

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
  if (!id || !reg.accounts[id]) throw new Error(`--account must be one of ${Object.keys(reg.accounts).join(", ")}`)
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
    if (s) cache = mergeSample(cache, id, s)
  }
  return cache
}

const claudeBin = () => Bun.which("claude") ?? join(homedir(), ".local", "bin", "claude")

const spawner: Spawner = (cmd, args, { env, timeoutMs }) => {
  const r = spawnSync(cmd, args, { env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: timeoutMs })
  const err = r.error as (Error & { code?: string }) | undefined
  return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "", error: err ? { code: err.code, message: err.message } : undefined }
}

const seed = (reg: Registry) => (c: Cache) => readClaudeJson(reg, c)

/**
 * Refresh accounts. `ids` restricts what to consider but still goes through the enabled + due filters and the
 * atomic claim; `claimed` (internal: the detached child of a pick) was already claimed by the parent.
 */
function refresh(reg: Registry, o: { ids?: string[]; claimed?: string[] } = {}, timeoutS = REFRESH_TIMEOUT_S): void {
  const enabled = (id: string) => !!reg.accounts[id]?.enabled
  const todo = o.claimed
    ? o.claimed.filter(enabled)
    : claimRefresh(updateCache, reg, (o.ids ?? Object.keys(reg.accounts)).filter(enabled), Date.now(), seed(reg))
  runRefresh({
    reg, spawn: spawner, claudeBin: claudeBin(), baseEnv: process.env, timeoutS, ids: todo,
    readSample: (id) => readSample(reg, id), update: updateCache, now: Date.now, log: (m) => console.error(m),
  })
}

/** Best-effort claim: a busy lock means someone else is mid-update, so skip refreshing rather than block a pick. */
function tryClaim(reg: Registry, ids: string[], now: number): string[] {
  try {
    return claimRefresh(updateCache, reg, ids, now, seed(reg))
  } catch {
    return []
  }
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
      age_s: x ? Math.round((now - x.ts) / 1000) : null, source: x?.src ?? null,
      auth_ok: !cache.auth_failed[id], exhausted_until: until && until * 1000 > now ? until : null,
    }
  })
  if (json) return void console.log(JSON.stringify({ accounts: rows }, null, 2))
  const reset = (e: number | null) => (e ? new Date(e * 1000).toISOString().slice(5, 16).replace("T", " ") : "-")
  for (const r of rows) {
    console.log(`${r.id} ${r.plan}${r.enabled ? "" : " (disabled)"}  5h ${r.five_hour ?? "-"}% ↺${reset(r.five_hour_resets_at)}  7d ${r.seven_day ?? "-"}% ↺${reset(r.seven_day_resets_at)}  age ${r.age_s ?? "-"}s  auth ${r.auth_ok ? "ok" : "FAILED"}${r.exhausted_until ? "  EXHAUSTED" : ""}`)
  }
}

function main(argv: string[]): number {
  const [cmd, ...rest] = argv
  const reg = loadRegistry()
  switch (cmd) {
    case "pick": {
      const lane = flag(rest, "--lane")
      if (!lane) throw new Error("usage: claude-account pick --lane <lane>")
      const now = Date.now()
      // Never block while a usable sample exists: stale accounts refresh in the background (budgeted),
      // only an account with no sample at all is refreshed synchronously first.
      try {
        refreshBeforePick({
          reg, lane, now, cache: readClaudeJson(reg, loadCache()),
          claim: (ids) => tryClaim(reg, ids, now),
          runSync: (ids) => refresh(reg, { claimed: ids }),
          detach: (ids) => Bun.spawn([process.execPath, import.meta.path, "refresh", "--claimed", ids.join(",")], { stdio: ["ignore", "ignore", "ignore"], detached: true }).unref(),
        })
      } catch (e) {
        console.error(`claude-account: refresh skipped: ${(e as Error).message}`) // a pick must always answer; go on with the current cache
      }
      const cache = readClaudeJson(reg, loadCache())
      const p = pick(reg, cache, lane, now)
      try {
        mkdirSync(dirname(picksPath()), { recursive: true })
        appendFileSync(picksPath(), JSON.stringify(pickLine(reg, cache, lane, p, now)) + "\n")
      } catch {
        // the pick log is a dataset, never a gate
      }
      const line = shellLine(reg, p)
      console.log(line ?? "iu")
      return line === null ? IU_EXIT : 0
    }
    case "usage":
      usage(reg, rest.includes("--json"))
      return 0
    case "refresh": {
      refresh(reg, { ids: flag(rest, "--ids")?.split(","), claimed: flag(rest, "--claimed")?.split(",") })
      return 0
    }
    case "record": {
      const id = account(reg, rest)
      const part = { s: num(rest, "--s"), w: num(rest, "--w"), s_reset: num(rest, "--s-reset"), w_reset: num(rest, "--w-reset") }
      updateCache((c) => recordSample(c, id, part, Date.now()))
      return 0
    }
    case "account": {
      const id = accountFromConfigDir(reg, process.env.CLAUDE_CONFIG_DIR) // null: set to a dir no account owns
      if (!rest.includes("--badge")) console.log(id ?? "?")
      else if (id === null) console.log("?")
      else if (Object.values(reg.accounts).filter((a) => a.enabled).length > 1) console.log(id.toUpperCase())
      return 0
    }
    case "exhausted": {
      const id = account(reg, rest)
      const until = num(rest, "--until")
      if (until === null) throw new Error("--until <epoch seconds> is required")
      updateCache((c) => markExhausted(c, id, until))
      return 0
    }
    default:
      console.error("usage: claude-account pick|usage|refresh|record|account|exhausted ...")
      return 2
  }
}

if (import.meta.main) {
  try {
    process.exit(main(process.argv.slice(2)))
  } catch (e) {
    console.error(`claude-account: ${(e as Error).message}`)
    process.exit(2)
  }
}

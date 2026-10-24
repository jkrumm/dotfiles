#!/usr/bin/env bun
// claude-account — Claude account registry, picker and per-account quota cache (docs/claude-accounts.md).
//
//   claude-account pick --lane <lane>      stdout: `unset CLAUDE_CONFIG_DIR` | `export CLAUDE_CONFIG_DIR=<dir>` | `iu` (exit 3)
//   claude-account usage [--json]          both accounts, from the quota cache
//   claude-account refresh                 `claude -p /usage` for enabled accounts whose cache is stale
//   claude-account record --account <id> --s <pct> [--s-reset <epoch>] [--w <pct>] [--w-reset <epoch>]
//                                          statusline feed (native rate_limits)
//   claude-account exhausted --account <id> --until <epoch>   limit-event mark, honoured until then
//
// We never read a token and make no call to api.anthropic.com/api/oauth/usage ourselves: the official
// binary fetches, and writes cachedUsageUtilization into the account's .claude.json.
import { spawnSync } from "node:child_process"
import { appendFileSync, mkdirSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import {
  type Cache, type Registry, type Sample, accountDir, cachePath, claudeJsonPath, loadCache, loadRegistry, markExhausted, mergeSample,
  needsRefresh, pick, pickLine, picksPath, sampleFromClaudeJson, shellLine, writeAtomic,
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

function refresh(reg: Registry): void {
  let cache = readClaudeJson(reg, loadCache())
  for (const id of needsRefresh(reg, cache, Date.now())) {
    const env: Record<string, string> = { ...(process.env as Record<string, string>), ANTHROPIC_BASE_URL: "" }
    const dir = accountDir(reg.accounts[id])
    if (dir === null) delete env.CLAUDE_CONFIG_DIR
    else env.CLAUDE_CONFIG_DIR = dir
    const r = spawnSync("timeout", ["60", claudeBin(), "-p", "/usage", "--output-format", "json"], { env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] })
    cache = { ...cache, refreshed: { ...cache.refreshed, [id]: Date.now() } }
    const s = readSample(reg, id)
    if (r.status === 0 && s) {
      cache = mergeSample(cache, id, s)
      cache = { ...cache, auth_failed: { ...cache.auth_failed, [id]: false } }
    } else {
      cache = { ...cache, auth_failed: { ...cache.auth_failed, [id]: /login|auth|credential/i.test(`${r.stdout}${r.stderr}`) } }
      console.error(`refresh ${id}: rc=${r.status} ${(r.stderr || r.stdout || "").trim().slice(0, 200)}`)
    }
  }
  writeAtomic(cachePath(), JSON.stringify(cache))
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
      const cache = readClaudeJson(reg, loadCache())
      const p = pick(reg, cache, lane, now)
      try {
        mkdirSync(dirname(picksPath()), { recursive: true })
        appendFileSync(picksPath(), JSON.stringify(pickLine(cache, lane, p, now)) + "\n")
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
    case "refresh":
      refresh(reg)
      return 0
    case "record": {
      const id = account(reg, rest)
      const s: Sample = { s: num(rest, "--s"), w: num(rest, "--w"), s_reset: num(rest, "--s-reset"), w_reset: num(rest, "--w-reset"), ts: Date.now(), src: "statusline" }
      writeAtomic(cachePath(), JSON.stringify(mergeSample(loadCache(), id, s)))
      return 0
    }
    case "exhausted": {
      const id = account(reg, rest)
      const until = num(rest, "--until")
      if (until === null) throw new Error("--until <epoch seconds> is required")
      writeAtomic(cachePath(), JSON.stringify(markExhausted(loadCache(), id, until)))
      return 0
    }
    default:
      console.error("usage: claude-account pick|usage|refresh|record|exhausted ...")
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

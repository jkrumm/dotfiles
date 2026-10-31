#!/usr/bin/env bun
// claude-account — Claude account registry, picker and per-account quota cache (docs/claude-accounts.md).
//
//   claude-account pick --lane <lane> [--why]      (any lane: a due account refreshes detached in the background; a non-interactive lane waits only for an account with no usable sample) stdout: `unset CLAUDE_CONFIG_DIR` | `export CLAUDE_CONFIG_DIR=<dir>` | `spill` (exit 3, no account has headroom); exit 4 = registry unreadable (still prints `unset CLAUDE_CONFIG_DIR`)
//   claude-account usage [--json]          both accounts, from the quota cache (a pure file read: no Keychain, no network)
//   claude-account expiry [--json] [--ids a,b]   per enabled account (--ids: the named accounts, disabled ones too: a first login): when its login (refresh token) ends, from its own Keychain item (read-only; only the two timestamps and the plan tier are read out; rows carry `tier` and `plan_detected`). Rows carry `grade` (PASS > 7 d, WARN <= 7 d or unreadable, FAIL <= 2 d or past), `default` (owns ~/.claude) and `severity` (the grade, but a non-default account never exceeds WARN) — what verify and the heartbeat act on
//   claude-account refresh [--ids a,b] [--all]   first imports the peer machine's samples (`usage --json` over ssh, once per run), then the OAuth usage endpoint sample (the account's own Keychain token, 10s HTTP timeout), else the `claude auth status` verdict, for enabled, due accounts (budget claimed atomically); --all exits 1 when an account got neither a fresh sample nor an auth verdict, or is logged in with its stored sample older than 6 h; --ids also retries an auth-failed account before its 30 min cooldown; --all ignores the 10 min freshness and the auth cooldown (login keepalive), the 5 min claim still applies
//   claude-account pick ... --dry          answer without refreshing and without a picks.jsonl line (verify suite)
//   claude-account record --account <id> --s <pct> [--s-reset <epoch>] [--w <pct>] [--w-reset <epoch>]
//                                          statusline feed (native rate_limits)
//   claude-account account [--badge]       registry id of this session (CLAUDE_CONFIG_DIR unset -> default); --badge: upper-case id, only with >1 enabled account
//   claude-account env <id>                shell line forcing an enabled account (c --account me); exit 2 if unknown or disabled
//   claude-account session <sessionId>     registry id the session ran on (hook log); exit 1 if unknown or disabled — `c --resume` pins to it
//   claude-account latest [dir]            id of the newest session transcript for dir (default cwd) — what `c --continue` pins to; exit 1 if none
//   claude-account health [--json] [--wake]   login / quota / waiting-ask health of this machine and its peer (MacBook <-> mini; the peer is read through its herdr-core, plain ssh only when no core answers, with a NOTE line); exit 1 on any fail. --wake: notify (MacBook, only when the picture changed) and re-push the peer's pending ask dialogs younger than 24 h — what sleepwatcher's wakeup.sh runs
//   claude-account exhausted --account <id> --until <epoch>   limit-event mark, honoured until then
//
// Idle-account samples: one read-only GET of api.anthropic.com/api/oauth/usage with the account's own Keychain token
// (never copied, logged or written back; on HTTP 401 `claude auth status` renews it first, one retry); `claude -p /usage` no longer refreshes cachedUsageUtilization (2.1.310).
import { spawn, spawnSync } from "node:child_process"
import { appendFileSync, closeSync, mkdirSync, openSync, readFileSync, writeFileSync } from "node:fs"
import { homedir, hostname } from "node:os"
import { dirname, join } from "node:path"
import { type HealthRow, type PendingAsk, gradeMachine, healthSignature, worst } from "./lib/claude-health.ts"
import {
  type Cache, type RefreshResult, type Registry, type Sample, type HttpGet, type Spawner, accountFromConfigDir, cacheDir, askRelogins, latestSessionId, claimRefresh, defaultAccountId, claudeJsonPath, keepaliveLogPath, loadCache, loadRegistry, markExhausted,
  mergeSample, newestAge, pick, pickLine, picksPath, readLoginExpiry, recordSample, refreshBeforePick, runRefresh, sampleFromClaudeJson, sessionAccount, shellLine, SPILL,
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
async function refresh(reg: Registry, o: { ids?: string[]; claimed?: string[]; all?: boolean; peer?: boolean } = {}): Promise<Record<string, RefreshResult>> {
  const enabled = (id: string) => Object.hasOwn(reg.accounts, id) && reg.accounts[id].enabled
  const todo = o.claimed
    ? o.claimed.filter(enabled)
    : claimRefresh(reg, (o.ids ?? Object.keys(reg.accounts)).filter(enabled), Date.now(), readClaudeJson(reg, loadCache()), undefined, !!o.ids || !!o.all, !!o.all) // explicit --ids bypasses the auth-failed cooldown: the documented manual retry
  return runRefresh({
    reg, spawn: spawner, httpGet, securityBin: process.env.CLAUDE_ACCOUNTS_SECURITY_BIN, claudeBin: claudeBin(), baseEnv: process.env, ids: todo, now: Date.now, log: (m) => console.error(m),
    peerUsage: o.peer === false ? undefined : fetchPeerUsage, // the synchronous pick-time refresh never waits on ssh
  })
}

/** Run a command detached and unwaited; its stdout/stderr append to the keepalive log (a failure there used to vanish). */
function spawnDetached(cmd: string[]): void {
  let fd: number | null = null
  try {
    mkdirSync(dirname(keepaliveLogPath()), { recursive: true })
    fd = openSync(keepaliveLogPath(), "a")
  } catch {
    // an unwritable log must not stop the child: fall back to discarding its output
  }
  try {
    const out = fd ?? "ignore"
    Bun.spawn(cmd, { stdio: ["ignore", out, out], detached: true }).unref()
  } finally {
    if (fd !== null) closeSync(fd)
  }
}
const spawnDetachedRefresh = (ids: string[]) => spawnDetached([process.execPath, import.meta.path, "refresh", "--claimed", ids.join(",")])

const loginExpiry = (reg: Registry, now: number, ids?: string[]) =>
  readLoginExpiry({ reg, spawn: spawner, securityBin: process.env.CLAUDE_ACCOUNTS_SECURITY_BIN, baseEnv: process.env, now, ids })

/**
 * Keepalive only: a dead login, or one inside its last 7 days, asks its owner once per 24 h for a re-login through a
 * native approval dialog (claude-relogin --ask, detached; the dialog is the human's click, nothing runs by itself).
 */
function askForRelogins(reg: Registry, results: Record<string, RefreshResult>): void {
  const script = process.env.CLAUDE_ACCOUNTS_RELOGIN ?? join(import.meta.dir, "claude-relogin.sh")
  const now = Date.now()
  try {
    const o = askRelogins({
      results, logins: loginExpiry(reg, now), now,
      ask: (c) => spawnDetached(["bash", script, c.id, "--ask", "--reason", c.reason]),
      log: (m) => console.error(`claude-account: ${m}`),
    })
    for (const id of o.asked) console.error(`claude-account: asked for a re-login of ${id} (dialog on the MacBook, next ask in 24 h)`)
    if (o.capped.length) console.error(`claude-account: re-login ask for ${o.capped.join(", ")} deferred (one dialog per hour)`)
  } catch (e) {
    console.error(`claude-account: re-login ask skipped: ${(e as Error).message}`) // an ask is a courtesy, never a failure of the keepalive
  }
}

function expiry(reg: Registry, json: boolean, ids?: string[]): void {
  const unknown = ids?.filter((id) => !Object.hasOwn(reg.accounts, id))
  if (unknown?.length) throw new Error(`--ids: unknown account ${unknown.join(", ")} (one of ${Object.keys(reg.accounts).join(", ")})`)
  const rows = loginExpiry(reg, Date.now(), ids)
  if (json) return void console.log(JSON.stringify({ accounts: rows }, null, 2))
  for (const r of rows) console.log(`${r.id}  ${r.grade}  ${r.detail}`)
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

// ── health (wake check) ─────────────────────────────────────────────────────────────────────────────────────────
const HOME_BIN = "$HOME/.local/bin/claude-account"
const PENDING_SH = `for f in "$HOME"/.local/state/human-queue/*.req; do [ -e "$f" ] && grep -q claude-relogin "$f" || continue; b="\${f%.req}"; [ -e "$b.res" ] || echo "$(basename "$b") $(stat -f %m "$f")"; done`
/** The other machine: the mini reaches the MacBook over `ssh iumac`, the MacBook the mini over `ssh mini`. */
function peerMachine() {
  const onMini = /mini/i.test(hostname())
  return { onMini, local: onMini ? "mini" : "macbook", peer: onMini ? { name: "macbook", ssh: ["iumac"] } : { name: "mini", ssh: ["mini"] } }
}
const SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
const sshBin = () => process.env.CLAUDE_ACCOUNTS_SSH ?? "ssh" // test seam: ssh reads the real ~/.ssh/config whatever $HOME says
const PEER_USAGE_TIMEOUT_MS = 20_000

/** The peer's `claude-account usage --json` (a pure file read there: it never refreshes, so no loop). Throws when unreachable or garbled. */
function fetchPeerUsage(): unknown {
  const r = spawnSync(sshBin(), [...SSH_OPTS, ...peerMachine().peer.ssh, `${HOME_BIN} usage --json`], { encoding: "utf8", timeout: PEER_USAGE_TIMEOUT_MS })
  if (r.error || r.status !== 0) throw new Error(`ssh ${peerMachine().peer.ssh.join(" ")} failed (${r.error?.message ?? `rc=${r.status}`})`)
  return JSON.parse(r.stdout)
}

const PEER_SCRIPT = `${HOME_BIN} usage --json; echo '@@'; ${HOME_BIN} expiry --json; echo '@@'; ${PENDING_SH}`

const parseJson = (t: string) => {
  try {
    return JSON.parse(t)
  } catch {
    return null
  }
}
function pendingFrom(text: string, nowMs: number): PendingAsk[] {
  return text.split("\n").flatMap((l) => {
    const m = /^([0-9T-]+) (\d+)$/.exec(l.trim())
    return m ? [{ id: m[1], ageMs: nowMs - Number(m[2]) * 1000 }] : []
  })
}
const hcBin = () => process.env.CLAUDE_ACCOUNTS_HC ?? "hc" // test seam, like CLAUDE_ACCOUNTS_SSH
const hcOk = (args: string[]) => spawnSync(hcBin(), args, { encoding: "utf8", timeout: 5_000 })
const shq = (v: string) => `'${v.replaceAll("'", `'\\''`)}'`
const CORE_LABEL = "com.jkrumm.herdr-core"
/**
 * Why a core and not ssh: an ssh session cannot read the mini's login Keychain (rc=36); the core is a launchd GUI-session
 * child and can. Two ways to reach the peer's: (1) this machine's core lists the peer connected (`hc exec --on`), else
 * (2) one ssh hop to the peer and that machine's own core (`hc exec` there). Neither ever starts a core: (1) asks
 * `server status` first, (2) checks launchd on the peer before it runs `hc` (an `hc` call starts a stray core otherwise).
 */
function peerViaCore(name: string, nowMs: number) {
  const status = hcOk(["server", "status", "--json"])
  if (status.error || status.status !== 0) return null
  const ls = hcOk(["machine", "ls", "--json"])
  if (ls.error || ls.status !== 0) return null
  const machines = (parseJson(ls.stdout) as { machines?: { name: string; state: string }[] } | null)?.machines ?? []
  if (!machines.some((m) => m.name === name && m.state === "connected")) return null
  const script = `PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; export PATH; ${PEER_SCRIPT}`
  const r = spawnSync(hcBin(), ["exec", "--on", name, "--timeout", "30", "sh", "-c", script], { encoding: "utf8", timeout: 35_000 })
  if (r.error || !r.stdout.includes("@@\n")) return null
  return parseSnapshot(r.stdout, nowMs)
}
/** (2) of the above: ssh to the peer, then its own core. null when the hop, the core (not running under launchd) or the read fails. */
function peerViaItsCore(ssh: string[], nowMs: number) {
  const script = `PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; export PATH; ${PEER_SCRIPT}`
  const remote = `PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; export PATH; launchctl print "gui/$(id -u)/${CORE_LABEL}" 2>/dev/null | grep -q "state = running" || exit 99; hc exec --timeout 30 sh -c ${shq(script)}`
  const r = spawnSync(sshBin(), [...SSH_OPTS, ...ssh, remote], { encoding: "utf8", timeout: 40_000 })
  if (r.error || r.status !== 0 || !r.stdout.includes("@@\n")) return null
  return parseSnapshot(r.stdout, nowMs)
}
function parseSnapshot(stdout: string, nowMs: number) {
  const [u = "", e = "", q = ""] = stdout.split("@@\n")
  const pending = pendingFrom(q, nowMs)
  return { usage: parseJson(u), expiry: parseJson(e), pending, pendingIds: pending }
}
/** One machine's `usage`, `expiry` and pending asks via a shell (local sh, or the peer's core, else ssh); null usage = unreachable. */
function machineSnapshot(argv: string[] | null, nowMs: number, peerName?: string): ReturnType<typeof parseSnapshot> & { via?: "core" | "ssh" } {
  if (!argv) {
    const r = spawnSync("sh", ["-c", PEER_SCRIPT.replaceAll(HOME_BIN, `"${process.execPath}" "${process.argv[1]}"`)], { encoding: "utf8", timeout: 30_000 })
    return r.status !== 0 && !r.stdout ? { usage: null, expiry: null, pending: null, pendingIds: [] as PendingAsk[] } : parseSnapshot(r.stdout, nowMs)
  }
  const viaCore = peerName ? (peerViaCore(peerName, nowMs) ?? peerViaItsCore(argv, nowMs)) : null
  if (viaCore) return { ...viaCore, via: "core" }
  const r = spawnSync(sshBin(), [...SSH_OPTS, ...argv, PEER_SCRIPT], { encoding: "utf8", timeout: 30_000 })
  if (r.status !== 0 && !r.stdout) return { usage: null, expiry: null, pending: null, pendingIds: [] as PendingAsk[], via: "ssh" }
  return { ...parseSnapshot(r.stdout, nowMs), via: "ssh" }
}

async function health(argv: string[]): Promise<number> {
  const now = Date.now()
  const { onMini, local, peer } = peerMachine()
  const mine = machineSnapshot(null, now)
  const theirs = machineSnapshot(peer.ssh, now, peer.name)
  const rows: HealthRow[] = [
    ...gradeMachine(local, mine),
    ...gradeMachine(peer.name, theirs),
  ]
  // The plain-ssh read cannot see the peer's Keychain: say so, whatever the format (stderr keeps --json parseable).
  if (theirs.via === "ssh") {
    const note = `NOTE ${peer.name}: its herdr-core was not reachable, so this read went over plain ssh; Keychain logins may show as unreadable here`
    if (argv.includes("--json")) console.error(note)
    else console.log(note)
  }
  if (argv.includes("--json")) console.log(JSON.stringify({ state: worst(rows), rows }, null, 2))
  else for (const r of rows) console.log(`${r.state.toUpperCase().padEnd(4)} ${r.machine}/${r.id} ${r.check}: ${r.detail}${r.fix ? `  -> ${r.fix}` : ""}`)
  if (argv.includes("--wake")) {
    if (!onMini) {
      // The dialogs the mini could not deliver while this Mac slept: push them again now that it is awake.
      for (const p of theirs.pendingIds) if (p.ageMs < 24 * 3600_000) {
        spawnLogged("ssh", [...SSH_OPTS, ...peer.ssh, `bash "$HOME/SourceRoot/dotfiles/scripts/ask-human.sh" push ${p.id}`])
      }
      notifyIfChanged(rows, now)
    }
  }
  return worst(rows) === "fail" ? 1 : 0
}
function spawnLogged(cmd: string, args: string[]) {
  const fd = openSync(keepaliveLogPath(), "a")
  spawn(cmd, args, { detached: true, stdio: ["ignore", fd, fd] }).unref()
  closeSync(fd)
}
function notifyIfChanged(rows: HealthRow[], nowMs: number) {
  const sig = healthSignature(rows)
  const stamp = join(cacheDir(), "health-notified.json")
  const prev = parseJson((() => { try { return readFileSync(stamp, "utf8") } catch { return "" } })()) as { sig?: string; ts?: number } | null
  if (!sig || (prev?.sig === sig && nowMs - (prev.ts ?? 0) < 12 * 3600_000)) return
  const bad = rows.filter((r) => r.state !== "ok").map((r) => `${r.machine}/${r.id}: ${r.detail}`).join("; ")
  spawnSync("osascript", ["-e", `display notification ${JSON.stringify(bad.slice(0, 200))} with title "Claude sessions" subtitle "open Tinycast > Claude usage to fix"`])
  try {
    mkdirSync(dirname(stamp), { recursive: true })
    writeFileSync(stamp, JSON.stringify({ sig, ts: nowMs }))
  } catch {
    // dedupe is best-effort
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
          runSync: async (ids) => void (await refresh(reg, { claimed: ids, peer: false })),
          detach: (ids) => spawnDetachedRefresh(ids),
        })
      } catch (e) {
        console.error(`claude-account: refresh skipped: ${(e as Error).message}`) // a pick must always answer; go on with the current cache
      }
      const cache = readClaudeJson(reg, loadCache())
      const p = pick(reg, cache, lane, now, dry ? undefined : Math.random) // --dry stays deterministic (verify and previews)
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
    case "expiry":
      expiry(reg, rest.includes("--json"), flag(rest, "--ids")?.split(","))
      return 0
    case "refresh": {
      const all = rest.includes("--all")
      const results = await refresh(reg, { ids: flag(rest, "--ids")?.split(","), claimed: flag(rest, "--claimed")?.split(","), all })
      // The keepalive's verdict: an account that got neither a fresh sample nor an auth verdict was not kept alive.
      const unresolved = Object.entries(results).filter(([, r]) => r === "unresolved").map(([id]) => id)
      const stale = Object.entries(results).filter(([, r]) => r === "stale").map(([id]) => id)
      if (all && stale.length) console.error(`claude-account: refresh --all: ${stale.join(", ")} logged in but still without a fresh sample (stored one older than 6 h or missing, see the lines above)`)
      if (all && unresolved.length) console.error(`claude-account: refresh --all: no fresh sample and no auth verdict for ${unresolved.join(", ")}`)
      if (all) askForRelogins(reg, results)
      if (all && (unresolved.length || stale.length)) return 1
      return 0
    }
    case "health":
      return health(rest)
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
    case "latest": {
      const id = latestSessionId(join(homedir(), ".claude", "projects"), rest[0] ?? process.cwd())
      if (!id) return 1
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
      console.error("usage: claude-account pick|usage|expiry|refresh|record|account|env|session|latest|exhausted ...")
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

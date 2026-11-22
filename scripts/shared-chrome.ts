#!/usr/bin/env bun
// shared-chrome — the one headless Chrome the browse path drives (`/browse`, agents/browser.md).
//
// Verbs and flags: `shared-chrome --help` (HELP below). An agent needs `ensure`, and `devtools` before a trace, Lighthouse or CSS read.
//
// One Chrome, its own profile (~/.local/share/shared-chrome), DevTools on 127.0.0.1 only. Every agent works in
// its own isolated browser context (playwright-cli `tab-new --isolated-context=<name>`), so cookies and storage
// stay apart while the process tree is shared. The port drives the browser for anything on this machine that
// can reach it, and the profile never signs in anywhere.
//
// The supervisor owns the idle rules (docs/mini-registry.md, on-demand tier):
//   - a context whose pages did not open, close, navigate or retitle for IDLE_MS is closed (the safety net:
//     playwright-cli's `attach --idle-timeout` detaches, and so closes, a session that ran no command);
//   - when no context is left for GRACE_MS, Chrome is stopped and the supervisor exits.
// A crashed Chrome ends the supervisor; the next `ensure` starts both again.
//
// The chrome-devtools CLI's background daemon is one per user, and `start`/`stop` act on whoever runs it, so an agent
// never runs either: `devtools` starts it when none runs, and the supervisor stops it whenever it stops Chrome
// (idle exit, `stop`, a crashed Chrome). It touches only a daemon whose arguments name this Chrome's URL; one attached
// elsewhere (`--autoConnect`, finances' chrome-live) is never restarted or stopped, and `devtools` then fails naming it.
import { spawn, spawnSync } from "node:child_process"
import { mkdirSync, openSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const env = process.env
const HOME = env.HOME ?? ""

/** Every verb the dispatch accepts, in help order; `caller` set = meant for a job, not for agents. */
export const VERB_HELP: { name: string; summary: string; caller?: string }[] = [
  { name: "ensure", summary: "start Chrome if it is not answering, print its DevTools URL on stdout, exit 0 (1 when it did not come up in 90 s)" },
  { name: "devtools", summary: "ensure Chrome, then the chrome-devtools daemon attached to it (starts it when none runs): the one verb to run before `chrome-devtools` traces, Lighthouse and CSS; exit 1 when the daemon is attached elsewhere (--autoConnect), which it never touches" },
  { name: "status", summary: "chrome up/down, supervisor pid, the chrome-devtools daemon, one line per browser context; exit 0 when up, 1 when down" },
  { name: "stop", summary: "stop the supervisor and with it Chrome and the chrome-devtools daemon; prints `stopped` (exit 0) or `still answering` (exit 1)" },
  { name: "run", summary: "the supervisor itself: owns the idle rules and exits when no context is left", caller: "launchd com.jkrumm.shared-chrome (`ensure` starts it); never by hand" },
]

export const HELP = `shared-chrome — the one headless Chrome the browse path drives (\`/browse\`, agents/browser.md)

Usage: shared-chrome <verb>        shared-chrome <verb> --help   same text; no verb is run by help

Verbs:
${VERB_HELP.filter((v) => !v.caller).map((v) => `  shared-chrome ${v.name}\n      ${v.summary}`).join("\n")}

Not for agents:
${VERB_HELP.filter((v) => v.caller).map((v) => `  shared-chrome ${v.name}\n      ${v.summary}\n      caller: ${v.caller}`).join("\n")}

No verb takes a flag. Chrome listens on 127.0.0.1 only; every agent works in its own isolated context
(playwright-cli \`tab-new --isolated-context=<name>\`). A context idle for 15 min is closed; Chrome stops 60 s after the last one.
The chrome-devtools daemon is one per user and shared-chrome owns it: agents never run its \`start\` or \`stop\`; it stops with Chrome.
Environment (defaults in CONFIG): SHARED_CHROME_PORT (9223), SHARED_CHROME_BIN, SHARED_CHROME_PROFILE, SHARED_CHROME_STATE,
SHARED_CHROME_LABEL, SHARED_CHROME_LOG, SHARED_CHROME_IDLE_MS, SHARED_CHROME_GRACE_MS, SHARED_CHROME_POLL_MS,
SHARED_CHROME_DEVTOOLS_BIN (chrome-devtools), SHARED_CHROME_PROBE_MS (15000), SHARED_CHROME_START_MS (120000: how long the
supervisor waits for a new Chrome to answer), SHARED_CHROME_ENSURE_MS (90000: how long ensure and devtools wait; capped 1 s below START_MS).
Exit: 0 ok · 1 verb failed or Chrome down (status) · 2 unknown verb.
`

export const CONFIG = {
  port: Number(env.SHARED_CHROME_PORT ?? 9223),
  bin: env.SHARED_CHROME_BIN ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  profile: env.SHARED_CHROME_PROFILE ?? join(HOME, ".local/share/shared-chrome"),
  stateDir: env.SHARED_CHROME_STATE ?? join(HOME, ".local/state/shared-chrome"),
  label: env.SHARED_CHROME_LABEL ?? "com.jkrumm.shared-chrome",
  log: env.SHARED_CHROME_LOG ?? join(HOME, "Library/Logs/shared-chrome.log"),
  idleMs: Number(env.SHARED_CHROME_IDLE_MS ?? 15 * 60_000),
  graceMs: Number(env.SHARED_CHROME_GRACE_MS ?? 60_000),
  pollMs: Number(env.SHARED_CHROME_POLL_MS ?? 30_000),
  devtoolsBin: env.SHARED_CHROME_DEVTOOLS_BIN ?? "chrome-devtools",
  probeMs: Number(env.SHARED_CHROME_PROBE_MS ?? 15_000), // a daemon busy with another agent's trace answers late, not never
  startMs: Number(env.SHARED_CHROME_START_MS ?? 120_000), // how long the supervisor waits for a new Chrome to answer before it kills it; a loaded machine starts Chrome in tens of seconds
  // ensureMs must stay below startMs, so `ensure` never hands out a Chrome the supervisor is about to kill
  ensureMs: Number(env.SHARED_CHROME_ENSURE_MS ?? 90_000),
}

// ---- chrome-devtools daemon (pure) ----------------------------------------------------------------------------

export type Daemon = { kind: "none" } | { kind: "ours"; pid: number; startedAt: number } | { kind: "foreign"; pid: number; args: string }

/** Read `chrome-devtools status`: running or not, its pid, and whether its arguments name `url` (this Chrome). */
export function daemonOf(statusOutput: string, url: string): Daemon {
  if (!/daemon is running/.test(statusOutput)) return { kind: "none" }
  const pid = Number(/pid=(\d+)/.exec(statusOutput)?.[1] ?? 0)
  const args = /^args=(.*)$/m.exec(statusOutput)?.[1] ?? ""
  const named = (a: string) => a === `--browser-url=${url}` || a === `--browserUrl=${url}` || a === `--browser-url ${url}`
  let list: string[] = []
  try {
    list = JSON.parse(args) as string[]
  } catch {
    /* an unreadable args line is not ours */
  }
  const startedAt = Date.parse(/start-date=(\S+)/.exec(statusOutput)?.[1] ?? "") // NaN when unreadable: never "older"
  return list.some(named) ? { kind: "ours", pid, startedAt } : { kind: "foreign", pid, args }
}

// ---- idle decision (pure) ------------------------------------------------------------------------------------

/** What one context looks like right now: `fp` changes whenever a page opens, closes, navigates or retitles. */
export interface Unit {
  id: string
  isDefault: boolean
  fp: string
  targetIds: string[]
}
export interface PlanState {
  units: Record<string, { fp: string; since: number }>
  emptySince: number
}
export interface Plan {
  state: PlanState
  disposeContexts: string[]
  closeTargets: string[]
  stop: boolean
}

export interface TargetInfo {
  targetId: string
  type: string
  url: string
  title: string
  browserContextId?: string
}

const BLANK = new Set(["", "about:blank", "chrome://newtab/"])

/** Group page targets into units. The default context's blank start tab is Chrome's own, not anyone's session. */
export function unitsOf(targets: TargetInfo[], isolatedIds: string[], defaultId?: string): Unit[] {
  const pages = targets.filter((t) => t.type === "page")
  const isDefault = (id: string) => (defaultId ? id === defaultId : !isolatedIds.includes(id))
  const ids = new Set<string>([...isolatedIds, ...pages.map((p) => p.browserContextId ?? "")])
  const out: Unit[] = []
  for (const id of ids) {
    const mine = pages.filter((p) => (p.browserContextId ?? "") === id)
    const def = isDefault(id)
    const relevant = def ? mine.filter((p) => !BLANK.has(p.url)) : mine
    if (def && relevant.length === 0) continue
    const fp = relevant
      .map((p) => `${p.targetId}|${p.url}|${p.title}`)
      .sort()
      .join("\n")
    out.push({ id, isDefault: def, fp, targetIds: relevant.map((p) => p.targetId) })
  }
  return out
}

/** `leaseAt`: when `ensure` last handed the URL out; its caller has not attached yet, so that counts as use. */
export function plan(prev: PlanState, units: Unit[], now: number, cfg: { idleMs: number; graceMs: number }, leaseAt = 0): Plan {
  const next: PlanState = { units: {}, emptySince: Math.max(prev.emptySince, leaseAt) }
  const disposeContexts: string[] = []
  const closeTargets: string[] = []
  let alive = 0
  for (const u of units) {
    const before = prev.units[u.id]
    const since = before && before.fp === u.fp ? before.since : now
    if (now - since >= cfg.idleMs) {
      if (u.isDefault) closeTargets.push(...u.targetIds)
      else disposeContexts.push(u.id)
      continue
    }
    next.units[u.id] = { fp: u.fp, since }
    alive++
  }
  if (alive > 0 || disposeContexts.length + closeTargets.length > 0) next.emptySince = now
  return { state: next, disposeContexts, closeTargets, stop: alive === 0 && now - next.emptySince >= cfg.graceMs }
}

// ---- CDP (just enough) ---------------------------------------------------------------------------------------

const endpoint = (port = CONFIG.port) => `http://127.0.0.1:${port}`

async function version(port = CONFIG.port): Promise<{ webSocketDebuggerUrl: string } | null> {
  try {
    const r = await fetch(`${endpoint(port)}/json/version`, { signal: AbortSignal.timeout(2000) })
    return r.ok ? ((await r.json()) as { webSocketDebuggerUrl: string }) : null
  } catch {
    return null
  }
}

async function withBrowser<T>(fn: (call: (method: string, params?: object) => Promise<any>) => Promise<T>): Promise<T> {
  const v = await version()
  if (!v) throw new Error("DevTools endpoint not answering")
  const ws = new WebSocket(v.webSocketDebuggerUrl)
  await new Promise<void>((res, rej) => {
    ws.onopen = () => res()
    ws.onerror = () => rej(new Error("websocket error"))
  })
  let id = 0
  const waiting = new Map<number, { res: (v: any) => void; rej: (e: Error) => void }>()
  ws.onmessage = (m) => {
    const msg = JSON.parse(String(m.data))
    const w = waiting.get(msg.id)
    if (!w) return
    waiting.delete(msg.id)
    if (msg.error) w.rej(new Error(`${msg.error.message}`))
    else w.res(msg.result)
  }
  const call = (method: string, params: object = {}) =>
    new Promise<any>((res, rej) => {
      const n = ++id
      const t = setTimeout(() => {
        waiting.delete(n)
        rej(new Error(`${method} timed out`))
      }, 5000)
      waiting.set(n, { res: (v) => (clearTimeout(t), res(v)), rej: (e) => (clearTimeout(t), rej(e)) })
      ws.send(JSON.stringify({ id: n, method, params }))
    })
  try {
    return await fn(call)
  } finally {
    ws.close()
  }
}

async function observe(): Promise<Unit[]> {
  return withBrowser(async (call) => {
    const ctx = await call("Target.getBrowserContexts")
    const { targetInfos } = await call("Target.getTargets")
    return unitsOf(targetInfos, ctx.browserContextIds ?? [], ctx.defaultBrowserContextId)
  })
}

// ---- processes -----------------------------------------------------------------------------------------------

const pidFile = () => join(CONFIG.stateDir, "supervisor.pid")
const alive = (pid: number) => {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}
/** The supervisor's pid, only while that pid still is a shared-chrome process (a stale file may name a reused pid). */
function supervisorPid(): number | null {
  try {
    const pid = Number(readFileSync(pidFile(), "utf8").trim())
    if (!(pid > 0 && alive(pid))) return null
    const cmd = spawnSync("/bin/ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8" }).stdout
    return cmd.includes("shared-chrome") ? pid : null
  } catch {
    return null
  }
}
// `ensure` leaves a lease: its caller attaches a turn later, and until then the supervisor must not count Chrome as unused.
const leaseFile = () => join(CONFIG.stateDir, "lease")
function writeLease() {
  mkdirSync(CONFIG.stateDir, { recursive: true })
  writeFileSync(leaseFile(), String(Date.now()))
}
function leaseAt(): number {
  try {
    return Number(readFileSync(leaseFile(), "utf8")) || 0
  } catch {
    return 0
  }
}
/** The process listening on the DevTools port: Chrome's browser process. */
function listenerPid(): number | null {
  const r = spawnSync("/usr/sbin/lsof", ["-nP", `-iTCP@127.0.0.1:${CONFIG.port}`, "-sTCP:LISTEN", "-t"], { encoding: "utf8" })
  const pid = Number(r.stdout.split("\n")[0])
  return pid > 0 ? pid : null
}

const log = (msg: string) => console.log(`${new Date().toISOString()} ${msg}`)

// ---- chrome-devtools daemon (process) ---------------------------------------------------------------------------

function devtools(args: string[], timeout = 60_000) {
  return spawnSync(CONFIG.devtoolsBin, args, { encoding: "utf8", timeout })
}

/** One `devtools` check-then-start at a time: two agents that both see no daemon would otherwise each start one. */
async function withDaemonLock<T>(fn: () => Promise<T>): Promise<T> {
  mkdirSync(CONFIG.stateDir, { recursive: true })
  const lock = join(CONFIG.stateDir, "devtools.lock")
  const end = Date.now() + 120_000
  for (;;) {
    try {
      mkdirSync(lock)
      break
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e // a read-only or full state dir is not contention
    }
    // A holder runs status, the probe, stop and start: 195 s at the worst. Older than that, it died.
    const age = (() => {
      try {
        return Date.now() - statSync(lock).mtimeMs
      } catch {
        return 0 // released between the two calls
      }
    })()
    if (age > 300_000) rmSync(lock, { recursive: true, force: true })
    else if (Date.now() > end) throw new Error("another shared-chrome devtools holds the lock")
    else await sleep(200)
  }
  try {
    return await fn()
  } finally {
    rmSync(lock, { recursive: true, force: true })
  }
}
let daemonProblem = ""
/** `null` when `chrome-devtools status` cannot be read (not installed, not runnable under this PATH, odd output): never "none". */
function daemon(): Daemon | null {
  const r = devtools(["status"])
  if (r.error || r.status !== 0 || !/daemon is (not )?running/.test(r.stdout)) {
    daemonProblem = r.error?.message ?? `exit ${r.status}: ${(r.stderr || r.stdout).trim().slice(0, 200)}`
    return null
  }
  return daemonOf(r.stdout, endpoint())
}
/** Stop the daemon if it is attached to this Chrome; a daemon attached elsewhere is left alone. */
function stopDaemon(): void {
  const d = daemon()
  if (!d) log(`cannot read the chrome-devtools daemon status, so it is left running: ${daemonProblem}`)
  if (d?.kind !== "ours") return
  log(`stopping the chrome-devtools daemon (pid ${d.pid})`)
  devtools(["stop"])
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function waitFor(cond: () => boolean | Promise<boolean>, ms: number, step = 200): Promise<boolean> {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (await cond()) return true
    await sleep(step)
  }
  return false
}

// ---- supervisor ----------------------------------------------------------------------------------------------

async function run(): Promise<number> {
  mkdirSync(CONFIG.stateDir, { recursive: true })
  const other = supervisorPid()
  if (other && other !== process.pid) {
    // One that is stopping Chrome right now (an ensure raced the idle stop) is not a reason to leave the caller
    // with no Chrome: wait for it to go, then start our own.
    if ((await version()) || !(await waitFor(() => supervisorPid() === null, 15_000, 100))) {
      log(`supervisor ${other} already runs`)
      return 0
    }
  }
  writeFileSync(pidFile(), String(process.pid))

  const adopted = (await version()) !== null
  // A Chrome whose supervisor died (SIGKILL) is taken over rather than left with no idle rule.
  let chromePid: number | null = adopted ? listenerPid() : null
  if (adopted) log(`adopted a running Chrome (pid ${chromePid})`)
  else {
    mkdirSync(CONFIG.profile, { recursive: true })
    const child = spawn(
      CONFIG.bin,
      [
        "--headless=new",
        `--remote-debugging-port=${CONFIG.port}`,
        "--remote-debugging-address=127.0.0.1",
        `--user-data-dir=${CONFIG.profile}`,
        "--no-first-run",
        "--no-default-browser-check",
        "about:blank",
      ],
      { stdio: "ignore" },
    )
    chromePid = child.pid ?? null
    log(`started Chrome (pid ${chromePid}) on 127.0.0.1:${CONFIG.port}`)
  }
  if (!chromePid) {
    log("no Chrome pid")
    rmSync(pidFile(), { force: true })
    return 1
  }
  const chromeProc: number = chromePid

  // Installed before anything waits: a `stop` that lands while Chrome is still coming up must end Chrome too.
  let stopping = false
  const stopChrome = async () => {
    stopDaemon()
    kill(chromeProc)
    if (!(await waitFor(() => !alive(chromeProc), 10_000, 100))) process.kill(chromeProc, "SIGKILL")
  }
  for (const sig of ["SIGTERM", "SIGINT"] as const) {
    process.on(sig, async () => {
      if (stopping) return
      stopping = true
      log(`${sig}: stopping Chrome`)
      await stopChrome()
      rmSync(pidFile(), { force: true })
      process.exit(0)
    })
  }
  if (!adopted) {
    const startedAt = Date.now()
    const answered = await waitFor(async () => (await version()) !== null, CONFIG.startMs)
    const seconds = Math.round((Date.now() - startedAt) / 1000)
    if (!answered) {
      log(`Chrome never answered on its DevTools port in ${seconds} s`)
      await stopChrome()
      rmSync(pidFile(), { force: true })
      return 1
    }
    if (seconds > 5) log(`Chrome answered after ${seconds} s`)
  }

  let state: PlanState = { units: {}, emptySince: Date.now() }
  let failures = 0
  while (!stopping) {
    await sleep(CONFIG.pollMs)
    if (!alive(chromeProc)) {
      log("Chrome exited; the next ensure starts it again")
      stopDaemon()
      rmSync(pidFile(), { force: true })
      return 1
    }
    try {
      const p = plan(state, await observe(), Date.now(), CONFIG, leaseAt())
      state = p.state
      failures = 0
      await withBrowser(async (call) => {
        for (const id of p.disposeContexts) {
          log(`idle ${CONFIG.idleMs / 1000}s: closing context ${id}`)
          await call("Target.disposeBrowserContext", { browserContextId: id }).catch((e) => log(`dispose ${id}: ${e.message}`))
        }
        for (const targetId of p.closeTargets) {
          log(`idle ${CONFIG.idleMs / 1000}s: closing page ${targetId}`)
          await call("Target.closeTarget", { targetId }).catch((e) => log(`close ${targetId}: ${e.message}`))
        }
      })
      // An ensure that landed during this poll holds Chrome open for its caller.
      if (p.stop && Date.now() - leaseAt() >= CONFIG.graceMs) {
        stopping = true
        log(`no context for ${CONFIG.graceMs / 1000}s: stopping Chrome`)
        await stopChrome()
        rmSync(pidFile(), { force: true })
        return 0
      }
    } catch (e) {
      // An answering port with a hung DevTools is a dead Chrome; three polls in a row is not a blip.
      log(`poll failed (${++failures}): ${(e as Error).message}`)
      if (failures >= 3) {
        await stopChrome()
        rmSync(pidFile(), { force: true })
        return 1
      }
    }
  }
  return 0
}

function kill(pid: number) {
  try {
    process.kill(pid, "SIGTERM")
  } catch {
    /* already gone */
  }
}

// ---- verbs ---------------------------------------------------------------------------------------------------

async function ensure(): Promise<number> {
  if (!(await ensureChrome())) return 1
  console.log(endpoint())
  return 0
}

async function ensureChrome(): Promise<boolean> {
  writeLease()
  if ((await version()) && supervisorPid()) return true
  const uid = process.getuid?.() ?? 501
  const k = spawnSync("/bin/launchctl", ["kickstart", `gui/${uid}/${CONFIG.label}`], { encoding: "utf8" })
  if (k.status !== 0) {
    // No LaunchAgent on this machine (or it is not loaded): run the supervisor detached, same code, same log.
    mkdirSync(join(CONFIG.log, ".."), { recursive: true })
    const out = openSync(CONFIG.log, "a")
    spawn(process.execPath, [import.meta.path, "run"], { detached: true, stdio: ["ignore", out, out], env }).unref()
  }
  const waitMs = Math.max(1000, Math.min(CONFIG.ensureMs, CONFIG.startMs - 1000))
  if (!(await waitFor(async () => (await version()) !== null && supervisorPid() !== null, waitMs, 250))) {
    console.error(
      `shared Chrome did not come up in ${Math.round(waitMs / 1000)} s; the supervisor keeps waiting up to ${Math.round(CONFIG.startMs / 1000)} s, so a retry may find it up; see ${CONFIG.log}`,
    )
    return false
  }
  return true
}

/** Chrome up, then a daemon attached to it. Start it when none runs; refuse one attached elsewhere. */
async function devtoolsVerb(): Promise<number> {
  if (!(await ensureChrome())) return 1
  try {
    return await withDaemonLock(startDaemonIfAbsent)
  } catch (e) {
    console.error((e as Error).message)
    return 1
  }
}

async function startDaemonIfAbsent(): Promise<number> {
  const url = endpoint()
  let d = daemon()
  if (!d) {
    console.error(`${CONFIG.devtoolsBin} status failed (${daemonProblem}); is it installed and on this PATH? make setup`)
    return 1
  }
  if (d.kind === "foreign") {
    console.error(
      `the chrome-devtools daemon (pid ${d.pid}) is attached elsewhere (args ${d.args}) and its owner holds it: ` +
        `shared-chrome never restarts or stops it. Retry when it has been stopped, or run \`${CONFIG.devtoolsBin} status\`.`,
    )
    return 1
  }
  // A daemon of ours that outlived its Chrome (a SIGKILLed supervisor, then a new Chrome) holds a dead connection:
  // replace it. One started before this Chrome did is stale however it answers; otherwise one that does not answer
  // in time is busy with someone's trace, not dead, and only a real failure counts.
  if (d.kind === "ours") {
    const chromeStart = Date.parse(spawnSync("/bin/ps", ["-o", "lstart=", "-p", String(listenerPid() ?? 0)], { encoding: "utf8" }).stdout)
    const stale = d.startedAt < chromeStart - 2000
    const probe = stale ? null : devtools(["list_pages"], CONFIG.probeMs)
    if (stale || (probe && !probe.error && probe.status !== 0)) {
      log(`the chrome-devtools daemon (pid ${d.pid}) does not answer: restarting it`)
      devtools(["stop"])
      d = { kind: "none" }
    }
  }
  if (d.kind === "none") {
    const r = devtools(["start", `--browserUrl=${url}`, "--usageStatistics=false", "--performanceCrux=false"])
    if (r.status !== 0) {
      console.error(`chrome-devtools start failed: ${(r.stderr || r.stdout).trim()}`)
      return 1
    }
  }
  const now = daemon()
  if (now?.kind !== "ours") {
    console.error("the chrome-devtools daemon is not attached to the shared Chrome after start")
    return 1
  }
  console.log(`chrome-devtools daemon (pid ${now.pid}) on ${url}`)
  return 0
}

async function status(): Promise<number> {
  const sup = supervisorPid()
  const up = (await version()) !== null
  console.log(`chrome:     ${up ? `up on ${endpoint()} (pid ${listenerPid() ?? "?"})` : "down"}`)
  console.log(`supervisor: ${sup ?? "none"}`)
  const d = daemon()
  console.log(
    `devtools:   ${!d ? `unreadable (${daemonProblem})` : d.kind === "none" ? "no daemon" : d.kind === "ours" ? `daemon pid ${d.pid} on the shared Chrome` : `daemon pid ${d.pid} attached elsewhere (not ours)`}`,
  )
  if (up) {
    for (const u of await observe()) console.log(`context ${u.id}${u.isDefault ? " (default)" : ""}: ${u.targetIds.length} page(s)`)
  }
  return up ? 0 : 1
}

async function stop(): Promise<number> {
  const sup = supervisorPid()
  if (sup) kill(sup)
  else {
    stopDaemon()
    const l = (await version()) ? listenerPid() : null
    if (l) kill(l)
  }
  const down = await waitFor(async () => (await version()) === null, 15_000)
  console.log(down ? "stopped" : "still answering")
  return down ? 0 : 1
}

const verbs: Record<string, () => Promise<number>> = { ensure, devtools: devtoolsVerb, status, stop, run }
/** The verbs the dispatch accepts (the drift test compares them with VERB_HELP). */
export const DISPATCHED = Object.keys(verbs)

if (import.meta.main) {
  const [verb, ...rest] = process.argv.slice(2)
  // Help never reaches a verb: it is answered before the dispatch, so no lease is written and no Chrome is started.
  const known = verb !== undefined && Object.hasOwn(verbs, verb)
  if (verb === undefined || verb === "help" || verb === "--help" || verb === "-h" || (known && rest.some((a) => a === "--help" || a === "-h"))) {
    process.stdout.write(HELP)
    process.exit(0)
  }
  const fn = Object.hasOwn(verbs, verb) ? verbs[verb] : undefined
  if (!fn) {
    console.error(`shared-chrome: unknown verb '${verb}' (${DISPATCHED.join("|")}); shared-chrome --help lists them`)
    process.exit(2)
  }
  process.exit(await fn())
}

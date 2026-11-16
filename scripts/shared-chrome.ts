#!/usr/bin/env bun
// shared-chrome — the one headless Chrome the browse path drives (`/browse`, agents/browser.md).
//
// Verbs and flags: `shared-chrome --help` (HELP below). `ensure` is the only verb an agent needs.
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
import { spawn, spawnSync } from "node:child_process"
import { mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const env = process.env
const HOME = env.HOME ?? ""

/** Every verb the dispatch accepts, in help order; `caller` set = meant for a job, not for agents. */
export const VERB_HELP: { name: string; summary: string; caller?: string }[] = [
  { name: "ensure", summary: "start Chrome if it is not answering, print its DevTools URL on stdout, exit 0 (1 when it did not come up in 25 s)" },
  { name: "status", summary: "chrome up/down, supervisor pid, one line per browser context; exit 0 when up, 1 when down" },
  { name: "stop", summary: "stop the supervisor and with it Chrome; prints `stopped` (exit 0) or `still answering` (exit 1)" },
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
Environment (defaults in CONFIG): SHARED_CHROME_PORT (9223), SHARED_CHROME_BIN, SHARED_CHROME_PROFILE, SHARED_CHROME_STATE,
SHARED_CHROME_LABEL, SHARED_CHROME_LOG, SHARED_CHROME_IDLE_MS, SHARED_CHROME_GRACE_MS, SHARED_CHROME_POLL_MS.
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
  if (!adopted && !(await waitFor(async () => (await version()) !== null, 20_000))) {
    log("Chrome never answered on its DevTools port")
    await stopChrome()
    rmSync(pidFile(), { force: true })
    return 1
  }

  let state: PlanState = { units: {}, emptySince: Date.now() }
  let failures = 0
  while (!stopping) {
    await sleep(CONFIG.pollMs)
    if (!alive(chromeProc)) {
      log("Chrome exited; the next ensure starts it again")
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
  writeLease()
  if ((await version()) && supervisorPid()) {
    console.log(endpoint())
    return 0
  }
  const uid = process.getuid?.() ?? 501
  const k = spawnSync("/bin/launchctl", ["kickstart", `gui/${uid}/${CONFIG.label}`], { encoding: "utf8" })
  if (k.status !== 0) {
    // No LaunchAgent on this machine (or it is not loaded): run the supervisor detached, same code, same log.
    mkdirSync(join(CONFIG.log, ".."), { recursive: true })
    const out = openSync(CONFIG.log, "a")
    spawn(process.execPath, [import.meta.path, "run"], { detached: true, stdio: ["ignore", out, out], env }).unref()
  }
  if (!(await waitFor(async () => (await version()) !== null && supervisorPid() !== null, 25_000, 250))) {
    console.error(`shared Chrome did not come up; see ${CONFIG.log}`)
    return 1
  }
  console.log(endpoint())
  return 0
}

async function status(): Promise<number> {
  const sup = supervisorPid()
  const up = (await version()) !== null
  console.log(`chrome:     ${up ? `up on ${endpoint()} (pid ${listenerPid() ?? "?"})` : "down"}`)
  console.log(`supervisor: ${sup ?? "none"}`)
  if (up) {
    for (const u of await observe()) console.log(`context ${u.id}${u.isDefault ? " (default)" : ""}: ${u.targetIds.length} page(s)`)
  }
  return up ? 0 : 1
}

async function stop(): Promise<number> {
  const sup = supervisorPid()
  if (sup) kill(sup)
  else {
    const l = (await version()) ? listenerPid() : null
    if (l) kill(l)
  }
  const down = await waitFor(async () => (await version()) === null, 15_000)
  console.log(down ? "stopped" : "still answering")
  return down ? 0 : 1
}

const verbs: Record<string, () => Promise<number>> = { ensure, status, stop, run }
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

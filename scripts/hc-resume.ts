#!/usr/bin/env bun
// hc-resume — restores Claude sessions into kept herdr-core terminals (replaces classic herdr's
// resume_agents_on_restore). hooks/hc-session-label.ts labels a terminal with jk.claude.session=<id>
// and jk.claude.config=<dir> (absent = the `iu` account). When a kept terminal's program is lost, the
// core replaces it with a login shell; this types `claude --resume <id>` into that shell.
//
// Triggers: its own start (the subscribe snapshot), every reconnect (stream EOF = core restart), a
// `restarted` event, a `missed` snapshot. Rules: one attempt at a time per terminal, at most one
// attempt per (terminal, session id), only into a terminal whose foreground is POSITIVELY a login shell
// (an unknown foreground is skipped and re-evaluated by the next snapshot).
//
// Pacing (docs/herdr-core.md §Resume pacing): after a reboot every kept terminal qualifies at once, and 25 `claude --resume`
// started in the same millisecond starved sshd and tailscale for 7 minutes (docs/incident-2026-11-13-mini-panic.md). So at most
// HC_RESUME_MAX_INFLIGHT sends are in flight (default 3) and consecutive starts are HC_RESUME_STAGGER_MS apart (default 3000),
// and the first start waits up to HC_RESUME_TAILNET_WAIT_MS (default 120000, 0 = off) for tailscale to be Running so
// reachability returns first. Pacing changes WHEN, never WHICH terminal or WHICH account.
//
// Never starts a core: `hc connect` STARTS one when none runs, so before every connect (with HC_SESSION
// unset, i.e. the real core) lib/core-up.sh must say a launchd-born core answers; otherwise it counts
// as "no core" and retries with backoff.
// Runs under launchd KeepAlive: com.jkrumm.hc-resume.
import { join } from "node:path"
import { splitLines } from "./hc-events"

type Json = Record<string, unknown>
export type Terminal = {
  address: string
  argv?: string[]
  foreground?: { argv?: string[] } | null
  /** Set by a running agent's own hook (`app: "claude-code"`); null on a bare shell. The foreground fact can be stale. */
  status?: { app?: string } | null
  labels?: Record<string, string>
}
/** What a link yields: a full snapshot (subscribe result, `missed`) or one restarted terminal. */
export type Msg = { kind: "snapshot" | "restarted"; terminals: Terminal[] }
export interface Link { messages: AsyncIterable<Msg>; close(): void }

export interface Deps {
  /** Connect and subscribe; rejects when no core runs. */
  open: () => Promise<Link>
  /** `session` is the id the line was built for: the real adapter re-checks it at send time. `argvFallback` is set only
   *  by a `restarted` trigger: the terminal's own argv may stand in for an ABSENT foreground fact. */
  send: (address: string, text: string, session: string, argvFallback?: boolean) => Promise<void>
  log?: (line: string) => void
  backoffMs?: [number, number]
  pacing?: Partial<Pacing>
  signal?: AbortSignal
}

const SESSION = "jk.claude.session"
const CONFIG = "jk.claude.config"
const SHELLS = new Set(["sh", "bash", "zsh", "fish", "dash", "ksh"])

/**
 * The foreground is POSITIVELY a login shell. Only a `restarted` record (`argvFallback`: the core just replaced
 * the program with the terminal's own login shell, the foreground fact is not there yet) may fall back to the
 * terminal's own argv, and only when the foreground key is absent. A snapshot or terminal.get without the
 * foreground fact, or with `foreground: null`, is unknown and never counts: the terminal's own argv says nothing
 * about what runs in it now (a live Claude session sits in a terminal whose argv is `/bin/zsh -l`).
 */
export function isLoginShell(t: Terminal, argvFallback = false): boolean {
  const argv = t.foreground ? t.foreground.argv : argvFallback && t.foreground === undefined ? t.argv : undefined
  if (!argv?.length) return false
  const head = argv[0]
  const name = head.replace(/^-/, "").split("/").pop() ?? ""
  if (!SHELLS.has(name)) return false
  return head.startsWith("-") || argv.slice(1).some((a) => a === "-l" || a === "--login")
}

const quote = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`

/** `--model` / `--effort` from the terminal's own argv, so a resumed session keeps what it ran on. */
export function modelFlags(argv: string[] = []): string[] {
  const out: string[] = []
  for (const flag of ["--model", "--effort"]) {
    for (let i = 0; i < argv.length; i++) {
      const a = argv[i]
      const v = a === flag ? argv[i + 1] : a.startsWith(`${flag}=`) ? a.slice(flag.length + 1) : undefined
      if (v === undefined) continue
      if (/^[\w.\-:[\]]+$/.test(v)) out.push(flag, quote(v))
      break
    }
  }
  return out
}

/** The line typed into the shell; null when the labels carry no usable session id. */
/**
 * A live agent has reported itself through its own hook (`status.app`). Only a `restarted` record, which proves the
 * program ended, may type regardless: a snapshot's or terminal.get's `foreground` can still name the login shell while a
 * Claude runs in it (seen live: the resume line landed in running sessions as a user message).
 */
export function hasLiveAgent(t: Terminal): boolean {
  return Boolean(t.status?.app)
}

export function resumeLine(labels: Record<string, string>, argv?: string[]): string | null {
  const id = labels[SESSION]
  if (!id || !/^[0-9a-f-]{8,64}$/i.test(id)) return null
  const dir = labels[CONFIG]
  const env = dir ? `env CLAUDE_CONFIG_DIR=${quote(dir)}` : "env -u CLAUDE_CONFIG_DIR"
  return [env, "claude", "--dangerously-skip-permissions", ...modelFlags(argv), "--resume", id].join(" ")
}

export const DEFAULT_MAX_INFLIGHT = 3
export const DEFAULT_STAGGER_MS = 3000
export const DEFAULT_TAILNET_WAIT_MS = 120000

export interface Pacing {
  /** Sends in flight at once (>= 1). */
  maxInFlight: number
  /** Minimum gap between two send starts. */
  staggerMs: number
  /** Awaited once before the first start; a rejection is ignored (never blocks the resume for good). */
  gate?: () => Promise<void>
}

/** Pacing from the environment; a missing or invalid value falls back to the default. */
export function pacingFromEnv(env: Record<string, string | undefined> = process.env): Pick<Pacing, "maxInFlight" | "staggerMs"> & { tailnetWaitMs: number } {
  const num = (v: string | undefined, d: number, min: number) => { const n = Number(v); return v !== undefined && v.trim() !== "" && Number.isInteger(n) && n >= min ? n : d }
  return {
    maxInFlight: num(env.HC_RESUME_MAX_INFLIGHT, DEFAULT_MAX_INFLIGHT, 1),
    staggerMs: num(env.HC_RESUME_STAGGER_MS, DEFAULT_STAGGER_MS, 0),
    tailnetWaitMs: num(env.HC_RESUME_TAILNET_WAIT_MS, DEFAULT_TAILNET_WAIT_MS, 0),
  }
}

const delay = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

/**
 * Resolves when `up()` says so, or after `timeoutMs` (resume goes ahead without the tailnet: a slow tailnet must not
 * keep sessions down). `up` throwing (no tailscale binary) also resolves at once: nothing to wait for.
 */
export async function waitForTailnet(up: () => Promise<boolean>, timeoutMs: number, intervalMs = 2000, log: (l: string) => void = () => {}): Promise<void> {
  if (timeoutMs <= 0) return
  const t0 = Date.now()
  for (;;) {
    try { if (await up()) { log(`tailnet up after ${Date.now() - t0} ms`); return } } catch { return }
    if (Date.now() - t0 + intervalMs > timeoutMs) { log(`tailnet not up after ${timeoutMs} ms: resuming anyway`); return }
    await delay(intervalMs)
  }
}

/**
 * `tailscale status --json` says BackendState Running, asked of the daemon scripts/lib/tailscale-cli.sh picks (the mini's
 * brew tailscaled on its explicit socket: a bare `tailscale` can reach the dormant app-bundle daemon and answer wrongly).
 * Throws when this machine has no tailscale CLI.
 */
export async function tailnetRunning(lib = join(import.meta.dir, "lib", "tailscale-cli.sh")): Promise<boolean> {
  const proc = Bun.spawn(["bash", "-c", 'source "$1"; [ -n "$TAILSCALE_BIN" ] || exit 127; ts_run status --json', "_", lib], { stdin: "ignore", stdout: "pipe", stderr: "ignore" })
  const timer = setTimeout(() => proc.kill(), 5000)
  try {
    const out = await new Response(proc.stdout).text()
    if ((await proc.exited) === 127) throw new Error("no tailscale CLI")
    return (JSON.parse(out) as Json).BackendState === "Running"
  } catch (e) {
    if ((e as Error).message === "no tailscale CLI") throw e
    return false
  } finally { clearTimeout(timer) }
}

export function createResumer(send: Deps["send"], log: (l: string) => void = () => {}, pacing: Partial<Pacing> = {}) {
  const maxInFlight = Math.max(1, pacing.maxInFlight ?? DEFAULT_MAX_INFLIGHT)
  const staggerMs = Math.max(0, pacing.staggerMs ?? DEFAULT_STAGGER_MS)
  const inflight = new Set<string>() // queued or sending: one attempt at a time per terminal
  const attempted = new Map<string, string>() // address -> session id last tried
  const pending = new Set<Promise<void>>() // sends running now (at most maxInFlight)
  type Job = { address: string; line: string; id: string; account: string; argvFallback: boolean }
  const queue: Job[] = []
  let pump: Promise<void> | null = null
  let lastStart = 0
  let gated = !pacing.gate

  function start(j: Job): void {
    const p = send(j.address, j.line, j.id, j.argvFallback)
      .then(() => log(`resume ${j.address} ${j.id} (${j.account})`))
      .catch((e) => {
        // Nothing was typed: let the next snapshot try again. "skipped" and real send errors keep the attempt.
        if (e instanceof RetryLater && attempted.get(j.address) === j.id) attempted.delete(j.address)
        log(`resume ${j.address} failed: ${(e as Error).message}`)
      })
      .finally(() => { inflight.delete(j.address); pending.delete(p) })
    pending.add(p)
  }

  /** Starts queued jobs: never more than maxInFlight at once, consecutive starts staggerMs apart, the first after the gate. */
  async function drain(): Promise<void> {
    if (!gated) { try { await pacing.gate!() } catch { /* never block the resume for good */ } gated = true }
    while (queue.length) {
      if (pending.size >= maxInFlight) { await Promise.race(pending); continue }
      const wait = lastStart + staggerMs - Date.now()
      if (wait > 0) { await delay(wait); continue }
      lastStart = Date.now()
      start(queue.shift()!)
    }
  }

  function consider(t: Terminal, argvFallback: boolean): void {
    const labels = t.labels ?? {}
    const id = labels[SESSION]
    if (!id || !isLoginShell(t, argvFallback)) return
    if (!argvFallback && hasLiveAgent(t)) return
    if (inflight.has(t.address) || attempted.get(t.address) === id) return
    const line = resumeLine(labels, t.argv)
    if (!line) { log(`skip ${t.address}: unusable session label`); return }
    inflight.add(t.address)
    attempted.set(t.address, id)
    queue.push({ address: t.address, line, id, account: labels[CONFIG] || "iu", argvFallback })
    kick()
  }

  function kick(): void {
    pump ??= drain().finally(() => { pump = null; if (queue.length) kick() })
  }

  return {
    handle(m: Msg): void {
      if (m.kind === "snapshot") for (const a of attempted.keys()) if (!m.terminals.some((t) => t.address === a)) attempted.delete(a)
      // A `restarted` event is a new loss: the previous attempt (if any) is history.
      for (const t of m.terminals) {
        if (m.kind === "restarted") attempted.delete(t.address)
        consider(t, m.kind === "restarted")
      }
    },
    /** Resolves when every queued send has started and finished. */
    async settled(): Promise<void> { while (pump || pending.size) await Promise.all([pump, ...pending]) },
  }
}

export async function run(deps: Deps): Promise<void> {
  const log = deps.log ?? (() => {})
  const [minB, maxB] = deps.backoffMs ?? [1000, 30000]
  const resumer = createResumer(deps.send, log, deps.pacing)
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
  let backoff = minB
  const onAbort = () => link?.close()
  let link: Link | undefined
  deps.signal?.addEventListener("abort", onAbort)

  while (!deps.signal?.aborted) {
    let got = false
    try {
      link = await deps.open()
      for await (const m of link.messages) { got = true; resumer.handle(m) }
      log(got ? "stream ended (core restart?), reconnecting" : "stream ended with no data")
    } catch (e) {
      log(`no core: ${(e as Error).message}`)
    }
    backoff = got ? minB : Math.min(backoff * 2, maxB)
    if (!deps.signal?.aborted) await sleep(backoff)
  }
  await resumer.settled()
}

// --- real hc adapter ---------------------------------------------------------------------------

/** Parse one `hc connect` line (seq filter state kept by the caller); null for anything not a trigger. */
export function parseLine(line: string, minSeq: { n: number }): Msg | null {
  let o: Json
  try { o = JSON.parse(line) } catch { return null }
  const params = (o.params ?? {}) as Json
  const result = o.result as Json | undefined
  if (result && Array.isArray(result.terminals)) { minSeq.n = Number(result.seq ?? 0); return { kind: "snapshot", terminals: result.terminals as Terminal[] } }
  if (o.method === "missed" && Array.isArray(params.terminals)) { minSeq.n = Number(params.seq ?? 0); return { kind: "snapshot", terminals: params.terminals as Terminal[] } }
  if (o.method === "event" && params.type === "restarted" && Number(params.seq) > minSeq.n) return { kind: "restarted", terminals: [params.data as Terminal] }
  return null
}

export function isSubscribeError(line: string): boolean {
  try { const o = JSON.parse(line) as Json; return o.id === 1 && o.error !== undefined } catch { return false }
}

/** Nothing was typed and the terminal may qualify later: the attempt does not count. */
export class RetryLater extends Error {}
/** The core guard refused before anything was typed. */
export class NotConnecting extends RetryLater {}

/** True when it is safe to `hc connect`: a scratch HC_SESSION, or lib/core-up.sh says a launchd-born core answers. */
export function coreAvailable(
  env: Record<string, string | undefined> = process.env,
  coreUp: () => number = () => Bun.spawnSync(["bash", join(import.meta.dir, "lib", "core-up.sh")], { stdout: "ignore", stderr: "ignore" }).exitCode ?? 1
): boolean {
  if (env.HC_SESSION) return true
  try { return coreUp() === 0 } catch { return false }
}

function spawnConnect(guard: () => boolean) {
  if (!guard()) throw new NotConnecting("no launchd-born core answers (scripts/lib/core-up.sh): not connecting (hc would start a core)")
  return Bun.spawn([process.env.HC_BIN || "hc", "connect"], { stdin: "pipe", stdout: "pipe", stderr: "ignore", env: process.env })
}

async function* lines(stream: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const decoder = new TextDecoder()
  let buf = ""
  for await (const chunk of stream) {
    const out: string[] = []
    buf = splitLines(buf + decoder.decode(chunk, { stream: true }), (l) => out.push(l))
    yield* out
  }
}

export async function openHc(guard: () => boolean = coreAvailable): Promise<Link> {
  const proc = spawnConnect(guard)
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "events.subscribe", params: {} }) + "\n")
  proc.stdin.flush()
  const minSeq = { n: 0 }
  async function* messages(): AsyncGenerator<Msg> {
    for await (const l of lines(proc.stdout)) {
      // A rejected subscription would leave the link open and deaf: end it so `run` reconnects with backoff.
      if (isSubscribeError(l)) { proc.kill(); return }
      const m = parseLine(l, minSeq)
      if (m) yield m
    }
  }
  return { messages: messages(), close: () => { proc.kill() } }
}

export const SEND_DEADLINE_MS = 15000

/** One request/response on a connection; the lines iterator is shared so the next call continues the stream. */
async function call(proc: ReturnType<typeof Bun.spawn>, it: AsyncGenerator<string>, id: number, method: string, params: Json): Promise<Json> {
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n")
  proc.stdin.flush()
  for (;;) {
    const { value, done } = await it.next()
    if (done) throw new Error("connection closed before the request was answered")
    let o: Json
    try { o = JSON.parse(value) } catch { continue }
    if (o.id !== id) continue
    if (o.error) throw new Error(JSON.stringify(o.error).slice(0, 300))
    return (o.result ?? {}) as Json
  }
}

/**
 * Re-read the terminal on a short-lived connection and send only if its foreground is positively a login shell carrying
 * the same session label (the subscribed connection answers no requests). A hard deadline kills the
 * connect process and rejects, so the caller's `inflight` always clears.
 */
export async function sendHc(address: string, text: string, session: string, deadlineMs = SEND_DEADLINE_MS, guard: () => boolean = coreAvailable, argvFallback = false): Promise<void> {
  const proc = spawnConnect(guard)
  let timedOut = false
  const timer = setTimeout(() => { timedOut = true; proc.kill() }, deadlineMs)
  try {
    const it = lines(proc.stdout)
    const t = (await call(proc, it, 3, "terminal.get", { terminal: address })) as unknown as Terminal
    if (t.labels?.[SESSION] !== session) throw new Error(`skipped: ${address} no longer carries session ${session}`)
    // Unknown foreground (null, or absent without the `restarted` fallback) is never typed into: a later snapshot decides.
    if (t.foreground === null || (t.foreground === undefined && !argvFallback)) throw new RetryLater(`foreground of ${address} unknown: not typing, a later snapshot decides`)
    if (!argvFallback && hasLiveAgent(t)) throw new Error(`skipped: ${address} runs a live ${t.status?.app} session`)
    if (!isLoginShell(t, argvFallback)) throw new Error(`skipped: ${address} is no longer at a login shell`)
    await call(proc, it, 2, "terminal.send", { terminal: address, text, caller: "hc-resume" })
  } catch (e) {
    if (timedOut) throw new Error(`send to ${address} timed out after ${deadlineMs} ms`)
    throw e
  } finally {
    clearTimeout(timer)
    proc.kill()
  }
}

if (import.meta.main) {
  const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`)
  const ac = new AbortController()
  for (const sig of ["SIGTERM", "SIGINT"] as const) process.on(sig, () => { ac.abort(); setTimeout(() => process.exit(0), 200) })
  log(`hc-resume started pid=${process.pid}`)
  const { tailnetWaitMs, ...pace } = pacingFromEnv()
  log(`pacing: max ${pace.maxInFlight} in flight, ${pace.staggerMs} ms apart, tailnet wait ${tailnetWaitMs} ms`)
  const gate = () => waitForTailnet(tailnetRunning, tailnetWaitMs, 2000, log)
  await run({ open: openHc, pacing: { ...pace, gate }, send: (a, t, s, fb) => sendHc(a, t, s, SEND_DEADLINE_MS, coreAvailable, fb), log, signal: ac.signal })
}

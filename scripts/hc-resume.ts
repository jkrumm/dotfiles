#!/usr/bin/env bun
// hc-resume — restores Claude sessions into kept herdr-core terminals (replaces classic herdr's
// resume_agents_on_restore). hooks/hc-session-label.ts labels a terminal with jk.claude.session=<id>
// and jk.claude.config=<dir> (absent = the `iu` account). When a kept terminal's program is lost, the
// core replaces it with a login shell; this types `claude --resume <id>` into that shell.
//
// Triggers: its own start (the subscribe snapshot), every reconnect (stream EOF = core restart), a
// `restarted` event, a `missed` snapshot. Rules: one attempt at a time per terminal, at most one
// attempt per (terminal, session id), only into a login shell.
//
// Never starts a core: `hc connect` STARTS one when none runs, so before every connect (with HC_SESSION
// unset, i.e. the real core) com.jkrumm.herdr-core must be `state = running` in launchd; otherwise it counts
// as "no core" and retries with backoff.
// Runs under launchd KeepAlive: com.jkrumm.hc-resume.
import { splitLines } from "./herdr-events"

type Json = Record<string, unknown>
export type Terminal = {
  address: string
  argv?: string[]
  foreground?: { argv?: string[] } | null
  labels?: Record<string, string>
}
/** What a link yields: a full snapshot (subscribe result, `missed`) or one restarted terminal. */
export type Msg = { kind: "snapshot" | "restarted"; terminals: Terminal[] }
export interface Link { messages: AsyncIterable<Msg>; close(): void }

export interface Deps {
  /** Connect and subscribe; rejects when no core runs. */
  open: () => Promise<Link>
  /** `session` is the id the line was built for: the real adapter re-checks it at send time. */
  send: (address: string, text: string, session: string) => Promise<void>
  log?: (line: string) => void
  backoffMs?: [number, number]
  signal?: AbortSignal
}

const SESSION = "jk.claude.session"
const CONFIG = "jk.claude.config"
const SHELLS = new Set(["sh", "bash", "zsh", "fish", "dash", "ksh"])

/**
 * Whatever is in the foreground is a login shell. With `argvFallback` (a `restarted` record or a fresh
 * terminal.get, where the foreground fact may not be there yet) the terminal's own program stands in;
 * a snapshot must carry the foreground fact.
 */
export function isLoginShell(t: Terminal, argvFallback = false): boolean {
  const argv = t.foreground ? t.foreground.argv : argvFallback ? t.argv : undefined
  if (!argv?.length) return false
  const head = argv[0]
  const name = head.replace(/^-/, "").split("/").pop() ?? ""
  if (!SHELLS.has(name)) return false
  return head.startsWith("-") || argv.slice(1).some((a) => a === "-l" || a === "--login")
}

const quote = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`

/** The line typed into the shell; null when the labels carry no usable session id. */
export function resumeLine(labels: Record<string, string>): string | null {
  const id = labels[SESSION]
  if (!id || !/^[0-9a-f-]{8,64}$/i.test(id)) return null
  const dir = labels[CONFIG]
  const env = dir ? `env CLAUDE_CONFIG_DIR=${quote(dir)}` : "env -u CLAUDE_CONFIG_DIR"
  return `${env} claude --dangerously-skip-permissions --resume ${id}`
}

export function createResumer(send: Deps["send"], log: (l: string) => void = () => {}) {
  const inflight = new Set<string>()
  const attempted = new Map<string, string>() // address -> session id last tried
  const pending = new Set<Promise<void>>()

  function consider(t: Terminal, argvFallback: boolean): void {
    const labels = t.labels ?? {}
    const id = labels[SESSION]
    if (!id || !isLoginShell(t, argvFallback)) return
    if (inflight.has(t.address) || attempted.get(t.address) === id) return
    const line = resumeLine(labels)
    if (!line) { log(`skip ${t.address}: unusable session label`); return }
    inflight.add(t.address)
    attempted.set(t.address, id)
    const p = send(t.address, line, id)
      .then(() => log(`resume ${t.address} ${id} (${labels[CONFIG] || "iu"})`))
      .catch((e) => {
        // Nothing was typed: let the next snapshot try again. "skipped" and real send errors keep the attempt.
        if (e instanceof NotConnecting && attempted.get(t.address) === id) attempted.delete(t.address)
        log(`resume ${t.address} failed: ${(e as Error).message}`)
      })
      .finally(() => { inflight.delete(t.address); pending.delete(p) })
    pending.add(p)
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
    /** Resolves when every started send has finished. */
    async settled(): Promise<void> { while (pending.size) await Promise.all([...pending]) },
  }
}

export async function run(deps: Deps): Promise<void> {
  const log = deps.log ?? (() => {})
  const [minB, maxB] = deps.backoffMs ?? [1000, 30000]
  const resumer = createResumer(deps.send, log)
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

/** The core guard refused before anything was typed: the attempt does not count. */
export class NotConnecting extends Error {}

export const CORE_LABEL = "com.jkrumm.herdr-core"

/** True when it is safe to `hc connect`: a scratch HC_SESSION, or the launchd core is running. */
export function coreAvailable(
  env: Record<string, string | undefined> = process.env,
  launchctl: (label: string) => string = (label) =>
    Bun.spawnSync(["launchctl", "print", `gui/${process.getuid?.() ?? 501}/${label}`], { stdout: "pipe", stderr: "ignore" }).stdout.toString()
): boolean {
  if (env.HC_SESSION) return true
  try { return /^\s*state = running$/m.test(launchctl(CORE_LABEL)) } catch { return false }
}

function spawnConnect(guard: () => boolean) {
  if (!guard()) throw new NotConnecting(`${CORE_LABEL} is not running: not connecting (hc would start a core)`)
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
 * Re-read the terminal on a short-lived connection and send only if it is still a login shell carrying
 * the same session label (the subscribed connection answers no requests). A hard deadline kills the
 * connect process and rejects, so the caller's `inflight` always clears.
 */
export async function sendHc(address: string, text: string, session: string, deadlineMs = SEND_DEADLINE_MS, guard: () => boolean = coreAvailable): Promise<void> {
  const proc = spawnConnect(guard)
  let timedOut = false
  const timer = setTimeout(() => { timedOut = true; proc.kill() }, deadlineMs)
  try {
    const it = lines(proc.stdout)
    const t = (await call(proc, it, 3, "terminal.get", { terminal: address })) as unknown as Terminal
    if (t.labels?.[SESSION] !== session) throw new Error(`skipped: ${address} no longer carries session ${session}`)
    if (!isLoginShell(t, true)) throw new Error(`skipped: ${address} is no longer at a login shell`)
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
  await run({ open: openHc, send: sendHc, log, signal: ac.signal })
}

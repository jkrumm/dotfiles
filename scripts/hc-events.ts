#!/usr/bin/env bun
// hc-events — the raw event record of herdr-core (successor of the retired classic herdr-events job).
// `events.subscribe` over `hc connect`; every event is appended, stamped with its receive time, to
// <dir>/YYYY-MM-DD.jsonl (the directory the retired herdr-events job wrote, so existing readers keep working). The files are data, not a log: never
// rotated, truncated or pruned. No consumers; this only records.
//
// Line shapes (docs/herdr-core.md fact 7):
//   {ts, event: <type>, terminal, seq, data}   one core event (`status`, `turn`, `labels`, `lost`, ...)
//   {ts, event: "recorder.snapshot", why, seq, terminals}   the subscribe result and every `missed` snapshot
//   {ts, event: "recorder.started", pid}
//   {ts, event: "recorder.gap", from, to, why, ...}   events may be missing between `from` and `to`:
//        why "closed"          the stream ended (core restart, hc died); written once the next subscription is up
//        why "missed"          the core dropped events for a slow reader (`missed`: from_seq .. to_seq)
//        why "unparsed line"   a line did not parse (a truncated line was seen once, fact 7)
//        why "idle"            nothing, not even a heartbeat (15 s), for idleMs
//   {ts, event: "recorder.unparsed" | "recorder.subscribe_failed" | "recorder.other", ...}
//
// Never starts a core: `hc connect` STARTS one when none runs, so before every connect (with HC_SESSION
// unset, i.e. the real core) com.jkrumm.herdr-core must be `state = running` in launchd; otherwise it counts
// as "no core" and retries with backoff (the first retry already writes the gap).
// Runs under launchd KeepAlive: com.jkrumm.hc-events.
import { appendFileSync, mkdirSync } from "node:fs"
import { join } from "node:path"

type Json = Record<string, unknown>

export const EVENTS_DIR = process.env.HERDR_EVENTS_DIR || join(process.env.HOME ?? "", ".local/share/herdr-events")
export const CORE_LABEL = "com.jkrumm.herdr-core"
export const IDLE_MS = 60_000 // heartbeats come every 15 s

export function dayFile(dir: string, d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0")
  return join(dir, `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}.jsonl`)
}

export function record(dir: string, line: Json, now = new Date()): void {
  appendFileSync(dayFile(dir, now), JSON.stringify({ ts: now.toISOString(), ...line }) + "\n")
}

/** Split a stream into lines; returns the unfinished tail. */
export function splitLines(buf: string, onLine: (l: string) => void): string {
  const parts = buf.split("\n")
  const tail = parts.pop() ?? ""
  for (const l of parts) if (l.trim()) onLine(l)
  return tail
}

export interface Link {
  /** One JSON-RPC line per item; ends when the stream ends. */
  lines: AsyncIterable<string>
  close(): void
}

export interface Deps {
  dir: string
  /** Connect and send `events.subscribe`; rejects when no core runs. */
  open: () => Promise<Link>
  log?: (line: string) => void
  backoffMs?: [number, number]
  idleMs?: number
  signal?: AbortSignal
}

type Next = IteratorResult<string> | "idle"

export async function run(deps: Deps): Promise<void> {
  const { dir, signal } = deps
  const log = deps.log ?? (() => {})
  const [minB, maxB] = deps.backoffMs ?? [1000, 30000]
  const idleMs = deps.idleMs ?? IDLE_MS
  mkdirSync(dir, { recursive: true })
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
  let backoff = minB
  let lostAt: Date | null = null
  let lostWhy = ""
  let lastSeq = 0

  while (!signal?.aborted) {
    let link: Link
    try {
      link = await deps.open()
    } catch (e) {
      lostAt ??= new Date()
      lostWhy = "closed"
      log(`no core: ${(e as Error).message}`)
      await sleep(backoff)
      backoff = Math.min(backoff * 2, maxB)
      continue
    }
    const onAbort = () => link.close()
    signal?.addEventListener("abort", onAbort)
    let acked = false

    const handle = (l: string): "drop" | undefined => {
      let o: Json
      try {
        o = JSON.parse(l)
        if (typeof o !== "object" || o === null) throw new Error("not an object")
      } catch {
        const now = new Date().toISOString()
        record(dir, { event: "recorder.unparsed", raw: l.slice(0, 2000) })
        record(dir, { event: "recorder.gap", from: now, to: now, why: "unparsed line" })
        return
      }
      const params = (o.params ?? {}) as Json
      // The subscribe answer is the first snapshot; it proves the core is really there: close the gap, reset backoff.
      if (o.id === 1) {
        if (o.error) {
          record(dir, { event: "recorder.subscribe_failed", error: o.error })
          return "drop"
        }
        const r = (o.result ?? {}) as Json
        if (acked) return
        acked = true
        lastSeq = Number(r.seq ?? 0)
        record(dir, lostAt
          ? { event: "recorder.gap", from: lostAt.toISOString(), to: new Date().toISOString(), why: lostWhy }
          : { event: "recorder.started", pid: process.pid })
        if (lostAt) record(dir, { event: "recorder.started", pid: process.pid })
        record(dir, { event: "recorder.snapshot", why: "subscribe", seq: r.seq, terminals: r.terminals })
        lostAt = null
        backoff = minB
        return
      }
      if (o.method === "heartbeat") return
      if (o.method === "missed") {
        const now = new Date().toISOString()
        record(dir, { event: "recorder.gap", from: now, to: now, why: "missed", from_seq: lastSeq, to_seq: params.seq })
        record(dir, { event: "recorder.snapshot", why: "missed", seq: params.seq, terminals: params.terminals })
        lastSeq = Number(params.seq ?? lastSeq)
        return
      }
      if (o.method === "event") {
        lastSeq = Number(params.seq ?? lastSeq)
        record(dir, { event: params.type, terminal: params.terminal, seq: params.seq, data: params.data })
        return
      }
      record(dir, { event: "recorder.other", method: o.method, params: o.params })
    }

    const it = link.lines[Symbol.asyncIterator]()
    let ended = "closed"
    let buf: Promise<Next> | null = null
    for (;;) {
      // An idle watchdog, not a cap: a live core sends a heartbeat every 15 s. `buf` keeps the pending read across a timeout race.
      buf ??= it.next()
      let timer: ReturnType<typeof setTimeout> | undefined
      const idle = new Promise<Next>((res) => { timer = setTimeout(() => res("idle"), idleMs) })
      let got: Next
      try { got = await Promise.race([buf, idle]) } catch { clearTimeout(timer); ended = "read error"; break }
      clearTimeout(timer)
      if (got === "idle") { ended = "idle"; break }
      buf = null
      if (got.done) break
      if (handle(got.value) === "drop") { ended = "subscribe error"; break }
    }
    signal?.removeEventListener("abort", onAbort)
    link.close()
    if (signal?.aborted) break
    lostAt ??= new Date()
    lostWhy = ended
    log(`stream ended (${ended}), reconnecting`)
    await sleep(backoff)
    backoff = acked ? minB : Math.min(backoff * 2, maxB)
  }
}

// --- real hc adapter ---------------------------------------------------------------------------

/** True when it is safe to `hc connect`: a scratch HC_SESSION, or the launchd core is running. */
export function coreAvailable(
  env: Record<string, string | undefined> = process.env,
  launchctl: (label: string) => string = (label) =>
    Bun.spawnSync(["launchctl", "print", `gui/${process.getuid?.() ?? 501}/${label}`], { stdout: "pipe", stderr: "ignore" }).stdout.toString()
): boolean {
  if (env.HC_SESSION) return true
  try { return /^\s*state = running$/m.test(launchctl(CORE_LABEL)) } catch { return false }
}

export async function openHc(guard: () => boolean = coreAvailable): Promise<Link> {
  if (!guard()) throw new Error(`${CORE_LABEL} is not running: not connecting (hc would start a core)`)
  const proc = Bun.spawn([process.env.HC_BIN || "hc", "connect"], { stdin: "pipe", stdout: "pipe", stderr: "ignore", env: process.env })
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "events.subscribe", params: {} }) + "\n")
  proc.stdin.flush()
  async function* lines(): AsyncGenerator<string> {
    const decoder = new TextDecoder() // streaming: a multi-byte character split across chunks must not become U+FFFD
    let buf = ""
    for await (const chunk of proc.stdout) {
      const out: string[] = []
      buf = splitLines(buf + decoder.decode(chunk, { stream: true }), (l) => out.push(l))
      yield* out
    }
  }
  return { lines: lines(), close: () => { proc.kill() } }
}

if (import.meta.main) {
  const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`)
  const ac = new AbortController()
  for (const s of ["SIGTERM", "SIGINT"] as const) process.on(s, () => { ac.abort(); setTimeout(() => process.exit(0), 200) })
  log(`hc-events started pid=${process.pid} dir=${EVENTS_DIR}`)
  await run({ dir: EVENTS_DIR, open: openHc, log, signal: ac.signal })
}

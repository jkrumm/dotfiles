#!/usr/bin/env bun
// herdr-events — the raw event record of the herdr server (factory Phase 0).
// Subscribes to every event type `herdr api schema` offers and appends each event, stamped with
// its receive time, to <dir>/YYYY-MM-DD.jsonl. The files are data, not a log: never rotated,
// truncated or pruned. No consumers — this only records.
//
// Two kinds of subscription: the type-only ones share one connection; `pane.agent_status_changed`
// takes a pane_id, so it gets one connection per live pane. `pane.output_matched` (needs a match
// spec) and `pane.scroll_changed` (a viewport firehose) are deliberately not recorded.
//
// Every disconnect writes `recorder.gap` on reconnect, so a hole in the record is visible as a
// line, not inferred from silence. Runs under launchd KeepAlive: com.jkrumm.herdr-events.
import { appendFileSync, mkdirSync } from "node:fs"
import { join } from "node:path"

type Json = Record<string, unknown>
type Conn = { write(s: string): void; end(): void }

export const SOCKET = process.env.HERDR_SOCKET_PATH || join(process.env.HOME ?? "", ".config/herdr/herdr.sock")
export const EVENTS_DIR = process.env.HERDR_EVENTS_DIR || join(process.env.HOME ?? "", ".local/share/herdr-events")

const SKIPPED = new Set(["pane.output_matched", "pane.scroll_changed"])
const PER_PANE = "pane.agent_status_changed"
// Used only when the schema cannot be read; the schema is the source of truth.
const FALLBACK_TYPES = [
  "workspace.created", "workspace.updated", "workspace.metadata_updated", "workspace.renamed", "workspace.moved",
  "workspace.reordered", "workspace.closed", "workspace.focused", "worktree.created", "worktree.opened",
  "worktree.removed", "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved", "pane.created",
  "pane.closed", "pane.updated", "pane.focused", "pane.moved", "pane.exited", "pane.agent_detected", "layout.updated",
]

/** Type-only subscription kinds from `herdr api schema --json` (everything but the per-pane and skipped ones). */
export function typesFromSchema(schema: unknown): string[] {
  const subs = (schema as any)?.schemas?.request?.$defs?.Subscription?.oneOf
  if (!Array.isArray(subs)) return []
  return subs
    .filter((s: any) => s?.required?.length === 1 && s.required[0] === "type")
    .map((s: any) => s.properties?.type?.const as string)
    .filter((t) => typeof t === "string" && !SKIPPED.has(t) && t !== PER_PANE)
}

export function dayFile(dir: string, d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0")
  return join(dir, `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}.jsonl`)
}

export function record(dir: string, line: Json, now = new Date()): void {
  appendFileSync(dayFile(dir, now), JSON.stringify({ ts: now.toISOString(), ...line }) + "\n")
}

/** Split a socket stream into lines; returns the unfinished tail. */
export function splitLines(buf: string, onLine: (l: string) => void): string {
  const parts = buf.split("\n")
  const tail = parts.pop() ?? ""
  for (const l of parts) if (l.trim()) onLine(l)
  return tail
}

export interface Deps {
  sock: string
  dir: string
  /** pane ids that exist right now */
  listPanes: () => Promise<string[]>
  eventTypes: () => Promise<string[]>
  backoffMs?: [number, number]
  signal?: AbortSignal
}

/** Open a subscription connection; resolves when it closes. `onEvent` gets each parsed envelope. */
function subscribe(sock: string, dir: string, subs: Json[], onEvent: (e: Json) => void, onOpen?: (c: Conn) => void): Promise<string> {
  return new Promise((resolve) => {
    let buf = ""
    const decoder = new TextDecoder() // streaming: a multi-byte character split across chunks must not become U+FFFD
    let done = false
    const finish = (why: string) => { if (!done) { done = true; resolve(why) } }
    Bun.connect({
      unix: sock,
      socket: {
        open(s) {
          s.write(JSON.stringify({ id: "rec", method: "events.subscribe", params: { subscriptions: subs } }) + "\n")
          onOpen?.({ write: (x) => s.write(x), end: () => s.end() })
        },
        data(s, d) {
          buf = splitLines(buf + decoder.decode(d, { stream: true }), (l) => {
            if (done) return
            let e: Json
            try { e = JSON.parse(l); if (typeof e !== "object" || e === null) throw new Error("not an object") } catch { record(dir, { event: "recorder.unparsed", raw: l.slice(0, 2000) }); return }
            // A rejected subscription would leave this connection open and deaf: record it and drop the
            // connection so the reconnect + gap path runs.
            if (e.error) {
              record(dir, { event: "recorder.subscribe_failed", error: e.error, subscriptions: subs.map((x) => x.type) })
              finish("subscribe error")
              s.end()
              return
            }
            onEvent(e)
          })
        },
        close() { finish("closed") },
        error(_s, e) { finish(`error: ${e.message}`) },
        connectError(_s, e) { finish(`connect: ${e.message}`) },
      },
    }).catch((e) => finish(`connect: ${(e as Error).message}`))
  })
}

export async function run(deps: Deps): Promise<void> {
  const { sock, dir, signal } = deps
  const [minB, maxB] = deps.backoffMs ?? [1000, 30000]
  mkdirSync(dir, { recursive: true })
  let backoff = minB
  let lostAt: Date | null = null
  let lostWhy = ""
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

  while (!signal?.aborted) {
    const types = await deps.eventTypes()
    const live = new Set<string>()
    const paneConns = new Map<string, Conn>()
    let mainOpen = false
    let ack = false
    const rec = (e: Json) => {
      // The ack of events.subscribe is a response, not an event: it carries "result", never "event".
      // The main connection's first ack proves the server is really there: close the gap, reset backoff.
      if (e.result) {
        if ((e.result as Json | undefined)?.type === "subscription_started" && !ack) {
          ack = true
          record(dir, {
            event: lostAt ? "recorder.gap" : "recorder.started",
            ...(lostAt ? { from: lostAt.toISOString(), to: new Date().toISOString(), why: lostWhy } : {}),
            pid: process.pid, types: types.length,
          })
          if (lostAt) record(dir, { event: "recorder.started", pid: process.pid, types: types.length })
          lostAt = null
          backoff = minB
        }
        return
      }
      record(dir, { event: e.event, data: e.data })
      const d = (e.data ?? {}) as Json
      if (e.event === "pane_created") { const id = (d.pane as Json | undefined)?.pane_id as string | undefined; if (id) { live.add(id); watchPane(id) } }
      if (e.event === "pane_closed" || e.event === "pane_exited") { const id = (d.pane_id ?? (d.pane as Json | undefined)?.pane_id) as string | undefined; if (id) { live.delete(id); paneConns.get(id)?.end() } }
    }
    const watchPane = (id: string, attempt = 0) => {
      if (!mainOpen || paneConns.has(id)) return
      void subscribe(sock, dir, [{ type: PER_PANE, pane_id: id }], rec, (c) => paneConns.set(id, c)).then(async (why) => {
        paneConns.delete(id)
        // A pane that is still live and whose main stream is up lost only its own stream: retry a few times.
        if (live.has(id) && mainOpen && attempt < 5) { await sleep(2000); watchPane(id, attempt + 1) }
        else if (live.has(id) && mainOpen) record(dir, { event: "recorder.pane_unwatched", pane_id: id, why })
      })
    }

    const mainDone = subscribe(sock, dir, types.map((type) => ({ type })), rec, () => {
      mainOpen = true
      void deps.listPanes().then((ids) => { for (const id of ids) { live.add(id); watchPane(id) } })
        .catch((e) => record(dir, { event: "recorder.pane_list_failed", error: String(e) }))
    })

    lostWhy = await mainDone
    mainOpen = false
    for (const c of paneConns.values()) c.end()
    if (signal?.aborted) break
    lostAt ??= new Date()
    await sleep(backoff)
    backoff = Math.min(backoff * 2, maxB)
  }
}

async function liveTypes(): Promise<string[]> {
  try {
    const p = Bun.spawn(["herdr", "api", "schema", "--json"], { stdout: "pipe", stderr: "ignore" })
    const t = typesFromSchema(JSON.parse(await new Response(p.stdout).text()))
    if (t.length) return t
  } catch {}
  return FALLBACK_TYPES
}

/** Throws on failure; the caller records `recorder.pane_list_failed`. */
async function livePanes(): Promise<string[]> {
  const p = Bun.spawn(["herdr", "pane", "list"], { stdout: "pipe", stderr: "ignore" })
  return (JSON.parse(await new Response(p.stdout).text()).result.panes as Json[]).map((x) => x.pane_id as string)
}

if (import.meta.main) {
  const ac = new AbortController()
  for (const s of ["SIGTERM", "SIGINT"] as const) process.on(s, () => { ac.abort(); setTimeout(() => process.exit(0), 200) })
  await run({ sock: SOCKET, dir: EVENTS_DIR, listPanes: livePanes, eventTypes: liveTypes, signal: ac.signal })
}

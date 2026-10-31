#!/usr/bin/env bun
// hc-raw-input — types raw bytes (stdin) into herdr-core terminals as a viewer would, over the framed
// `terminal.attach` stream. `hc send` always pastes and presses Enter, and `hc keys` takes key names, so
// neither can deliver a terminal report (`CSI ?997;2n`, an OSC answer) to a running program.
//
//   printf '\033[?997;2n' | hc-raw-input.ts t3 mini/t7     bytes to those terminals
//   printf …              | hc-raw-input.ts --agents       every live claude / opencode terminal
//   hc-raw-input.ts --self < bytes                         the terminal named by $HC_TERMINAL_ID
//
// Wire format (read off `hc attach` through a socket proxy, core 0.1.15; the schema only names the frames):
// after `hello {framed: true}` every message is `u32le channel | u8 type | u32le length | payload`. Channel 0
// carries JSON-RPC as type 0; an attach result names a channel whose type 0 frames are the program's input
// (client → core) and output (core → client). Type 1 grants output credit, type 2 closes the channel.
//
// The attach asks for the terminal's own size, so it never resizes it. It sends no `display`.
// Never starts a core: `hc connect` STARTS one when none runs, so with HC_SESSION unset the real core must be
// `state = running` in launchd, else this exits 3 and types nothing.
import { spawnSync } from "node:child_process"
import { basename } from "node:path"

export const DATA = 0
export const CREDIT = 1
export const CLOSE = 2

export function encodeFrame(channel: number, type: number, payload: Uint8Array | string = ""): Buffer {
  const body = typeof payload === "string" ? Buffer.from(payload) : Buffer.from(payload)
  const head = Buffer.alloc(9)
  head.writeUInt32LE(channel, 0)
  head.writeUInt8(type, 4)
  head.writeUInt32LE(body.length, 5)
  return Buffer.concat([head, body])
}

export interface Frame { channel: number; type: number; payload: Buffer }

/** Incremental frame parser: feed chunks, get whole frames. */
export function createFrameParser() {
  let buf = Buffer.alloc(0)
  return (chunk: Uint8Array): Frame[] => {
    buf = Buffer.concat([buf, chunk])
    const out: Frame[] = []
    while (buf.length >= 9) {
      const len = buf.readUInt32LE(5)
      if (buf.length < 9 + len) break
      out.push({ channel: buf.readUInt32LE(0), type: buf.readUInt8(4), payload: buf.subarray(9, 9 + len) })
      buf = buf.subarray(9 + len)
    }
    return out
  }
}

type Json = Record<string, unknown>
interface Terminal {
  address: string
  state?: string
  cols: number
  rows: number
  argv?: string[]
  foreground?: { argv?: string[]; name?: string } | null
  status?: { app?: string } | null
}

/** A live claude / opencode terminal: it reports so over OSC 7501, or it runs as the foreground program. */
export function isAgent(t: Terminal): boolean {
  if (t.state !== "live") return false
  if (/claude|opencode/.test(t.status?.app ?? "")) return true
  const fg = t.foreground
  const head = fg ? (fg.argv?.[0] ?? fg.name ?? "") : (t.argv?.[0] ?? "")
  return /^(claude|opencode)$/.test(basename(head))
}

/** The real core must be up in launchd before any connect; a scratch core (HC_SESSION) is the caller's. */
export function coreIsRunning(env = process.env): boolean {
  if (env.HC_SESSION) return true
  if (process.platform !== "darwin") return true
  const uid = process.getuid?.() ?? 501
  const r = spawnSync("launchctl", ["print", `gui/${uid}/com.jkrumm.herdr-core`], { encoding: "utf8" })
  return r.status === 0 && /state = running/.test(r.stdout)
}

/** One framed hc connection. */
async function open(timeoutMs: number) {
  const proc = Bun.spawn(["hc", "connect"], { stdin: "pipe", stdout: "pipe", stderr: "ignore" })
  const reader = proc.stdout.getReader()
  const parse = createFrameParser()
  const queue: Frame[] = []
  let raw = Buffer.alloc(0)
  let framed = false
  let notify: (() => void) | null = null
  const wake = () => { notify?.(); notify = null }
  let ended = false
  ;(async () => {
    try {
      for (;;) {
        const { value, done } = await reader.read()
        if (done) break
        if (!framed) {
          raw = Buffer.concat([raw, value])
          const nl = raw.indexOf(10)
          if (nl < 0) continue
          queue.push({ channel: -1, type: DATA, payload: raw.subarray(0, nl) })
          framed = true
          const rest = raw.subarray(nl + 1)
          if (rest.length) queue.push(...parse(rest))
        } else {
          queue.push(...parse(value))
        }
        wake()
      }
    } finally {
      ended = true
      wake()
    }
  })()
  const deadline = Date.now() + timeoutMs
  async function next(match: (f: Frame) => boolean): Promise<Frame> {
    for (;;) {
      const i = queue.findIndex(match)
      if (i >= 0) return queue.splice(i, 1)[0]
      if (ended) throw new Error("core closed the connection")
      const left = deadline - Date.now()
      if (left <= 0) throw new Error("timed out")
      await new Promise<void>((resolve) => {
        notify = resolve
        setTimeout(resolve, left)
      })
    }
  }
  const write = (b: Buffer) => { proc.stdin.write(b); proc.stdin.flush() }
  let id = 0
  async function call(method: string, params: Json): Promise<Json> {
    const myId = ++id
    write(encodeFrame(0, DATA, JSON.stringify({ jsonrpc: "2.0", id: myId, method, params })))
    const f = await next((x) => x.channel === 0 && x.payload.includes(`"id":${myId},`))
    const msg = JSON.parse(f.payload.toString())
    if (msg.error) throw new Error(`${method}: ${msg.error.message ?? JSON.stringify(msg.error)}`)
    return msg.result as Json
  }
  write(Buffer.from(`${JSON.stringify({ jsonrpc: "2.0", id: 0, method: "hello", params: { framed: true, generation: 1 } })}\n`))
  await next((f) => f.channel === -1)
  return {
    call,
    write,
    next,
    close() { try { proc.stdin.end() } catch {} proc.kill() },
  }
}

/** Types `bytes` into each address. Returns the addresses it reached; failures are listed, not thrown. */
export async function typeInto(addresses: string[], bytes: Buffer, timeoutMs = 8000) {
  const conn = await open(timeoutMs)
  const reached: string[] = []
  const failed: string[] = []
  try {
    for (const address of addresses) {
      try {
        const t = (await conn.call("terminal.get", { terminal: address })) as unknown as Terminal
        if (t.state !== "live") { failed.push(`${address}: not live`); continue }
        const att = (await conn.call("terminal.attach", { terminal: address, cols: t.cols, rows: t.rows })) as { channel: number }
        const ch = att.channel
        // No CREDIT frame: nothing here wants the output, so the core sends none (checked: input still lands).
        conn.write(encodeFrame(ch, DATA, bytes))
        conn.write(encodeFrame(ch, CLOSE))
        await conn.next((f) => f.channel === ch && f.type === CLOSE)
        reached.push(address)
      } catch (e) {
        failed.push(`${address}: ${(e as Error).message}`)
      }
    }
  } finally {
    conn.close()
  }
  return { reached, failed }
}

/** Addresses of live claude / opencode terminals on this core (linked machines come back as `machine/tN`). */
export async function agentAddresses(timeoutMs = 8000): Promise<string[]> {
  const conn = await open(timeoutMs)
  try {
    const r = (await conn.call("terminal.list", {})) as { terminals: Terminal[] }
    return r.terminals.filter(isAgent).map((t) => t.address)
  } finally {
    conn.close()
  }
}

async function readStdin(): Promise<Buffer> {
  const chunks: Buffer[] = []
  for await (const c of Bun.stdin.stream()) chunks.push(Buffer.from(c))
  return Buffer.concat(chunks)
}

if (import.meta.main) {
  const args = process.argv.slice(2)
  if (!args.length) {
    console.error("usage: hc-raw-input.ts <terminal>... | --agents | --self   (bytes on stdin)")
    process.exit(2)
  }
  if (!coreIsRunning()) {
    console.error("hc-raw-input: com.jkrumm.herdr-core is not running; not starting one")
    process.exit(3)
  }
  const bytes = await readStdin()
  if (!bytes.length) process.exit(0)
  let targets: string[]
  if (args[0] === "--agents") targets = await agentAddresses()
  else if (args[0] === "--self") {
    const self = process.env.HC_TERMINAL_ID
    if (!self) { console.error("hc-raw-input: HC_TERMINAL_ID is not set"); process.exit(2) }
    targets = [self]
  } else targets = args
  if (!targets.length) process.exit(0)
  const { reached, failed } = await typeInto(targets, bytes)
  for (const f of failed) console.error(`hc-raw-input: ${f}`)
  if (reached.length) console.log(reached.join(" "))
  process.exit(failed.length && !reached.length ? 1 : 0)
}

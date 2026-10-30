#!/usr/bin/env bun
// kuma-door — one tailnet port through which Uptime Kuma pulls the mini's service health.
// `GET /h/<name>` fetches the registry URL for <name> and returns its status plus a capped body.
// GET/HEAD only; nothing from the request (path, query, headers) ever reaches the upstream — the
// upstream URL is purely the registry's. Bound to 127.0.0.1; `tailscale serve` publishes it
// (row in dotfiles-private/tailscale-serve.mini.conf). Runs under launchd KeepAlive:
// com.jkrumm.kuma-door. Registry + validation: registry.ts.
import { loadRegistry, type Registry } from "./registry"

export type DoorOptions = { timeoutMs?: number; maxBodyBytes?: number; log?: (line: string) => void }

const TEXT = "text/plain; charset=utf-8"
const HEALTH_PREFIX = "/h/"
const NULL_BODY_STATUS = new Set([204, 205, 304]) // Response() throws on a body for these

export function createDoor(registry: Registry, opts: DoorOptions = {}) {
  const timeoutMs = opts.timeoutMs ?? 5000
  const maxBody = opts.maxBodyBytes ?? 4096
  const log = opts.log ?? ((line: string) => process.stderr.write(`${line}\n`))
  const upstreams = new Map(registry.services.map((s) => [s.name, s.url]))

  const reply = (status: number, body: string, extra: Record<string, string> = {}) =>
    new Response(body, { status, headers: { "content-type": TEXT, "cache-control": "no-store", ...extra } })

  async function relay(url: string): Promise<Response> {
    const ac = new AbortController()
    const timer = setTimeout(() => ac.abort(), timeoutMs)
    try {
      const res = await fetch(url, { method: "GET", redirect: "manual", signal: ac.signal })
      const { body, truncated } = await readCapped(res, maxBody)
      return new Response(NULL_BODY_STATUS.has(res.status) ? null : body, {
        status: res.status,
        headers: { "content-type": TEXT, "cache-control": "no-store", ...(truncated ? { "x-door-truncated": "1" } : {}) },
      })
    } catch (err) {
      return ac.signal.aborted ? reply(504, "upstream timeout\n") : reply(502, `upstream unreachable: ${describe(err)}\n`)
    } finally {
      clearTimeout(timer)
    }
  }

  return async function handle(req: Request): Promise<Response> {
    const t0 = performance.now()
    const path = new URL(req.url).pathname
    let label = "-"
    const res = await (async () => {
      if (req.method !== "GET" && req.method !== "HEAD") return reply(405, "method not allowed\n", { allow: "GET, HEAD" })
      if (path === "/healthz") {
        label = "healthz"
        return reply(200, "ok\n")
      }
      const name = path.startsWith(HEALTH_PREFIX) ? path.slice(HEALTH_PREFIX.length) : ""
      const url = upstreams.get(name)
      if (url === undefined) return reply(404, "not found\n")
      label = name
      return relay(url)
    })()
    log(`${req.method} ${label} ${res.status} ${Math.round(performance.now() - t0)}ms`)
    return res
  }
}

// Reads at most max bytes from the stream, then cancels it: a hostile or runaway upstream cannot
// make the door buffer more than the cap.
async function readCapped(res: Response, max: number): Promise<{ body: Uint8Array; truncated: boolean }> {
  if (!res.body) return { body: new Uint8Array(0), truncated: false }
  const reader = res.body.getReader()
  const chunks: Uint8Array[] = []
  let size = 0
  let truncated = false
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    if (size + value.length > max) {
      chunks.push(value.subarray(0, max - size))
      size = max
      truncated = true
      await reader.cancel()
      break
    }
    chunks.push(value)
    size += value.length
  }
  const body = new Uint8Array(size)
  let off = 0
  for (const c of chunks) { body.set(c, off); off += c.length }
  return { body, truncated }
}

function describe(err: unknown): string {
  return err instanceof Error ? err.name : "error"
}

if (import.meta.main) {
  let registry: Registry
  try {
    registry = loadRegistry()
  } catch (err) {
    process.stderr.write(`kuma-door: ${err instanceof Error ? err.message : String(err)}\n`)
    process.exit(1)
  }
  const port = Number(process.env.KUMA_DOOR_PORT) || registry.port
  const server = Bun.serve({ hostname: "127.0.0.1", port, fetch: createDoor(registry) })
  process.stderr.write(`kuma-door listening on 127.0.0.1:${server.port} (${registry.services.length} services)\n`)
  for (const s of ["SIGTERM", "SIGINT"] as const) process.on(s, () => { server.stop(true); process.exit(0) })
}

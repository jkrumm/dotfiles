#!/usr/bin/env bun
// mini-apps — the control endpoint behind the apps page (docs/mini-registry.md §Apps page).
//
//   GET  /_apps/status               the registry's rows (make mini-ps --format json), cached 5 s
//   POST /_apps/start/<name>         `mini-registry up <name>`   (same-origin POST only)
//   POST /_apps/stop/<name>          `mini-registry down <name>` (same-origin POST only; a core service is refused)
//   GET  /_wake/...                  the wake: Caddy's handle_errors sends a door's 502 here, with the door's Host
//   POST /_wake/start                the Start button of a manual service's wake page
//
// It holds no service list of its own and runs nothing the registry does not hold: a request value picks a registry
// entry by name, then `mini-registry` runs that entry's registered command as an argv array, never through a shell.
// Bound to 127.0.0.1; Caddy's wildcard tailnet block (scripts/caddy-tailnet.sh) is the only way in. Runs under launchd
// KeepAlive: com.jkrumm.mini-apps.
import { join } from "node:path"
import type { Row } from "../scripts/mini-registry"

export type Verb = "up" | "down"
export type Deps = {
  rows: () => Promise<Row[]>
  run: (verb: Verb, name: string) => Promise<{ rc: number; out: string }>
  log?: (line: string) => void
  now?: () => number
}

const NAME = /^[a-z0-9][a-z0-9.-]*$/
const ROW_TTL_MS = 5000
const FAILED_RETRY_MS = 30000

// The fields the page and the wake need; the rest of a row (priority bands, drift) stays with `make mini-ps`.
const PUBLIC = ["name", "tier", "kind", "profile", "state", "footprint_mib", "budget_mib", "over", "doors", "note", "can_start", "can_stop", "idle_minutes", "repo"] as const

export type WakeState = "starting" | "running" | "failed" | "manual" | "nostart"

// `<door>.mini.jkrumm.com`, `<door>.test`: the first label is the Caddy registry name of the door.
export function doorOfHost(host: string): string | null {
  const label = host.split(":")[0].toLowerCase().split(".")[0]
  return NAME.test(label) ? label : null
}

export function sameOrigin(req: Request): boolean {
  const origin = req.headers.get("origin")
  const host = req.headers.get("host")
  if (!origin || !host) return false
  const site = req.headers.get("sec-fetch-site")
  if (site && site !== "same-origin") return false
  try { return new URL(origin).host === host } catch { return false }
}

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)

export function wakePage(name: string, state: WakeState, logPath: string): string {
  const message: Record<WakeState, string> = {
    starting: `Starting ${name}…`,
    running: `${name} is running but its door answers 502. Reloading until it responds.`,
    failed: `${name} did not start. Its output is in ${logPath}.`,
    manual: `${name} is a manual service: it starts only from its button.`,
    nostart: `${name} has no start command in the registry (config/mini/services.yaml).`,
  }
  return `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(name)}</title>
<link rel="icon" href="data:,">
<style>
:root { color-scheme: dark light; --bg: #1f1f23; --fg: #d4d4d8; --dim: #a1a1aa; --line: #3f3f46; }
@media (prefers-color-scheme: light) { :root { --bg: #f2f2f5; --fg: #27272a; --dim: #52525b; --line: #d4d4d8; } }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--fg); font: 15px/1.5 ui-monospace, Menlo, monospace; }
main { max-width: 34rem; padding: 1.5rem; }
h1 { font-size: 1.1rem; margin: 0 0 .75rem; }
p { color: var(--dim); margin: 0 0 1rem; }
button { font: inherit; color: inherit; background: none; border: 1px solid var(--line); border-radius: 4px; padding: .4rem 1rem; cursor: pointer; }
button[hidden] { display: none; }
</style>
<main>
<h1>${escapeHtml(name)}</h1>
<p id="msg">${escapeHtml(message[state])}</p>
<button id="start" ${state === "manual" ? "" : "hidden"}>Start</button>
<button id="retry" ${state === "failed" ? "" : "hidden"}>Retry</button>
</main>
<script>
const NAME = ${JSON.stringify(name)};
let state = ${JSON.stringify(state)};
const msg = document.getElementById("msg");
const start = document.getElementById("start");
const retry = document.getElementById("retry");
// A door that answers without X-Wake is the app: reload into it.
async function tick() {
  if (state === "failed" || state === "manual" || state === "nostart") return;
  try {
    const res = await fetch(location.href, { cache: "no-store", redirect: "manual" });
    if (!res.headers.get("x-wake")) return location.reload();
    const next = res.headers.get("x-wake-state");
    if (next === "failed") { state = "failed"; msg.textContent = NAME + " did not start."; retry.hidden = false; return; }
  } catch {}
  setTimeout(tick, 2000);
}
start.addEventListener("click", async () => {
  start.hidden = true;
  msg.textContent = "Starting " + NAME + "…";
  const res = await fetch("/_wake/start", { method: "POST", headers: { "content-type": "text/plain" } });
  if (!res.ok) { msg.textContent = "Refused: " + (await res.text()); start.hidden = false; return; }
  state = "starting";
  tick();
});
retry.addEventListener("click", () => location.reload());
tick();
</script>
`
}

export function createApp(deps: Deps) {
  const log = deps.log ?? ((line: string) => process.stderr.write(`${line}\n`))
  const now = deps.now ?? Date.now
  let cache: { at: number; rows: Promise<Row[]> } | null = null
  const inflight = new Map<string, Promise<void>>()
  const failedAt = new Map<string, number>()

  // One probe at a time: concurrent pages and wakes share it.
  const rows = () => {
    if (!cache || now() - cache.at > ROW_TTL_MS) {
      const fresh = deps.rows()
      cache = { at: now(), rows: fresh }
      fresh.catch(() => { cache = null })
    }
    return cache.rows
  }

  const text = (status: number, body: string, headers: Record<string, string> = {}) =>
    new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store", ...headers } })
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

  // A verb runs one at a time per service: a second wake while the first start is in flight joins it.
  function begin(row: Row, caller: string): "starting" | "failed" {
    if (inflight.has(row.name)) return "starting"
    const failed = failedAt.get(row.name)
    if (failed !== undefined && now() - failed < FAILED_RETRY_MS) return "failed"
    log(`${caller} up ${row.name}`)
    const job = deps.run("up", row.name)
      .then(({ rc, out }) => {
        if (rc === 0) failedAt.delete(row.name)
        else { failedAt.set(row.name, now()); log(`up ${row.name} exited ${rc}: ${out.trim().slice(-300)}`) }
      })
      .catch((err) => { failedAt.set(row.name, now()); log(`up ${row.name} failed: ${String(err)}`) })
      .finally(() => { inflight.delete(row.name); cache = null })
    inflight.set(row.name, job)
    return "starting"
  }

  async function change(req: Request, verb: "start" | "stop", name: string, caller: string): Promise<Response> {
    if (!sameOrigin(req)) return text(403, "cross-origin request refused\n")
    const row = (await rows()).find((r) => r.name === name)
    if (!row) return text(404, "unknown service\n")
    if (verb === "stop" && row.tier === "core") return text(403, `${name} is core: not stopped from here\n`)
    if (!(verb === "start" ? row.can_start : row.can_stop)) return text(409, `${name}: no ${verb} command registered\n`)
    if (verb === "start") {
      if (row.state === "running") return json(200, { name, state: row.state })
      return json(202, { name, state: begin(row, caller) })
    }
    if (inflight.has(name)) return text(409, `${name} is starting\n`)
    log(`${caller} down ${name}`)
    const { rc, out } = await deps.run("down", name)
    cache = null
    if (rc !== 0) { log(`down ${name} exited ${rc}: ${out.trim().slice(-300)}`); return text(500, `${name}: stop failed\n`) }
    return json(200, { name, state: "stopped" })
  }

  async function wake(req: Request, host: string, caller: string): Promise<Response> {
    const door = doorOfHost(host)
    const row = door ? (await rows()).find((r) => r.doors.includes(door)) : undefined
    if (!door || !row) return text(502, `no service of the registry serves ${door ?? "this name"}\n`)
    const logPath = `~/Library/Logs/mini-apps/${row.name}.log`
    const page = (state: WakeState) =>
      new Response(req.method === "HEAD" ? null : wakePage(row.name, state, logPath), {
        status: 503,
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "retry-after": "2", "x-wake": "1", "x-wake-state": state },
      })
    if (row.tier === "core") return text(502, `${row.name} is a core service and is not running; it starts from its owner repo\n`)
    if (req.method === "POST") {
      // a start from the page's button: only a manual service is waiting for one
      if (new URL(req.url).pathname !== "/_wake/start") return text(503, `${row.name} is not running\n`)
      if (!sameOrigin(req)) return text(403, "cross-origin request refused\n")
      if (!row.can_start) return text(409, `${row.name}: no start command registered\n`)
      return json(202, { name: row.name, state: row.state === "running" ? "running" : begin(row, caller) })
    }
    if (row.state === "running") return page("running")
    if (!row.can_start) return page("nostart")
    // a manual service starts from its button; the page for it starts nothing, and polls only after the button
    if (row.tier === "manual") return inflight.has(row.name) ? page("starting") : page("manual")
    // only a GET starts a service: a HEAD (a prefetch, a probe) gets the page and its state
    if (req.method === "HEAD") return page(failedAt.has(row.name) && !inflight.has(row.name) ? "failed" : "starting")
    return page(begin(row, caller))
  }

  return async function handle(req: Request): Promise<Response> {
    const t0 = performance.now()
    const url = new URL(req.url)
    const path = url.pathname
    const caller = req.headers.get("x-forwarded-for")?.split(",")[0].trim() || "-"
    const res = await (async () => {
      if (path === "/healthz") return text(200, "ok\n")
      if (path === "/_apps/status") {
        if (req.method !== "GET") return text(405, "method not allowed\n", { allow: "GET" })
        const all = await rows()
        return json(200, { at: new Date(now()).toISOString(), services: all.map((r) => Object.fromEntries(PUBLIC.map((k) => [k, r[k]]))) })
      }
      const m = path.match(/^\/_apps\/(start|stop)\/([^/]+)$/)
      if (m) {
        if (req.method !== "POST") return text(405, "method not allowed\n", { allow: "POST" })
        if (!NAME.test(m[2])) return text(404, "unknown service\n")
        return change(req, m[1] as "start" | "stop", m[2], caller)
      }
      if (path === "/_wake" || path.startsWith("/_wake/")) {
        if (!["GET", "HEAD", "POST"].includes(req.method)) return text(405, "method not allowed\n", { allow: "GET, HEAD, POST" })
        return wake(req, req.headers.get("host") ?? "", caller)
      }
      return text(404, "not found\n")
    })().catch((err) => { log(`error ${path}: ${String(err)}`); return text(500, "internal error\n") })
    log(`${caller} ${req.method} ${path.split("/").slice(0, 3).join("/")} ${res.status} ${Math.round(performance.now() - t0)}ms`)
    return res
  }
}

// ---------------------------------------------------------------- production wiring

const REGISTRY = join(import.meta.dir, "..", "scripts", "mini-registry.ts")

async function spawnRegistry(args: string[], timeoutMs: number): Promise<{ rc: number; out: string }> {
  const p = Bun.spawn([process.execPath, REGISTRY, ...args], { stdout: "pipe", stderr: "pipe", timeout: timeoutMs })
  const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()])
  return { rc: await p.exited, out: out + err }
}

export const productionDeps: Deps = {
  rows: async () => {
    const { rc, out } = await spawnRegistry(["ps", "--format", "json"], 60000)
    if (rc !== 0) throw new Error(`mini-registry ps exited ${rc}: ${out.slice(-200)}`)
    return (JSON.parse(out) as { services: Row[] }).services
  },
  // a start waits for the door (60 s) after the probes
  run: (verb, name) => spawnRegistry([verb, name], 120000),
}

if (import.meta.main) {
  const port = Number(process.env.MINI_APPS_PORT) || 7797
  const server = Bun.serve({ hostname: "127.0.0.1", port, fetch: createApp(productionDeps), idleTimeout: 30 })
  process.stderr.write(`mini-apps listening on 127.0.0.1:${server.port}\n`)
  for (const s of ["SIGTERM", "SIGINT"] as const) process.on(s, () => { server.stop(true); process.exit(0) })
}

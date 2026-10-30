import { afterEach, beforeAll, expect, test } from "bun:test"
import { createDoor } from "./door"
import type { Registry } from "./registry"

type Seen = { method: string; path: string }
const servers: ReturnType<typeof Bun.serve>[] = []
const seen: Seen[] = []
const logs: string[] = []

// Fake loopback upstream: routes by path, records what reached it.
function upstream(routes: Record<string, () => Response | Promise<Response>>) {
  const s = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(req) {
      const u = new URL(req.url)
      seen.push({ method: req.method, path: u.pathname + u.search })
      const route = routes[u.pathname]
      return route ? route() : new Response("missing", { status: 404 })
    },
  })
  servers.push(s)
  return s
}

function door(services: Record<string, string>, opts: Parameters<typeof createDoor>[1] = {}) {
  const registry: Registry = {
    port: 8795,
    services: Object.entries(services).map(([name, url]) => ({ name, url, title: name })),
  }
  const handle = createDoor(registry, { log: (l) => logs.push(l), ...opts })
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: handle })
  servers.push(server)
  return `http://127.0.0.1:${server.port}`
}

beforeAll(() => { seen.length = 0 })
afterEach(() => {
  for (const s of servers.splice(0)) s.stop(true)
  seen.length = 0
  logs.length = 0
})

test("200 passthrough with fixed headers", async () => {
  const up = upstream({ "/health": () => new Response('{"status":"ok"}', { headers: { "content-type": "application/json", "set-cookie": "a=b" } }) })
  const base = door({ svc: `http://127.0.0.1:${up.port}/health` })
  const res = await fetch(`${base}/h/svc`)
  expect(res.status).toBe(200)
  expect(await res.text()).toBe('{"status":"ok"}')
  expect(res.headers.get("content-type")).toBe("text/plain; charset=utf-8")
  expect(res.headers.get("cache-control")).toBe("no-store")
  expect(res.headers.get("set-cookie")).toBeNull()
  expect(res.headers.get("x-door-truncated")).toBeNull()
})

test("503 passes through with its body", async () => {
  const up = upstream({ "/health": () => new Response('{"status":"degraded"}', { status: 503 }) })
  const base = door({ svc: `http://127.0.0.1:${up.port}/health` })
  const res = await fetch(`${base}/h/svc`)
  expect(res.status).toBe(503)
  expect(await res.text()).toBe('{"status":"degraded"}')
})

test("body is capped at 4096 bytes and flagged", async () => {
  const up = upstream({ "/big": () => new Response("x".repeat(10_000)) })
  const base = door({ svc: `http://127.0.0.1:${up.port}/big` })
  const res = await fetch(`${base}/h/svc`)
  expect((await res.text()).length).toBe(4096)
  expect(res.headers.get("x-door-truncated")).toBe("1")
})

test("a body of exactly the cap is not flagged", async () => {
  const up = upstream({ "/exact": () => new Response("y".repeat(4096)) })
  const base = door({ svc: `http://127.0.0.1:${up.port}/exact` })
  const res = await fetch(`${base}/h/svc`)
  expect((await res.text()).length).toBe(4096)
  expect(res.headers.get("x-door-truncated")).toBeNull()
})

for (const method of ["POST", "PUT", "DELETE"]) {
  test(`${method} is 405 with Allow and never reaches the upstream`, async () => {
    const up = upstream({ "/health": () => new Response("ok") })
    const base = door({ svc: `http://127.0.0.1:${up.port}/health` })
    const res = await fetch(`${base}/h/svc`, { method })
    expect(res.status).toBe(405)
    expect(res.headers.get("allow")).toBe("GET, HEAD")
    expect(seen).toEqual([])
  })
}

test("HEAD is answered", async () => {
  const up = upstream({ "/health": () => new Response("ok") })
  const base = door({ svc: `http://127.0.0.1:${up.port}/health` })
  const res = await fetch(`${base}/h/svc`, { method: "HEAD" })
  expect(res.status).toBe(200)
})

test("unknown name and malformed paths are 404 without touching the upstream", async () => {
  const up = upstream({ "/health": () => new Response("ok"), "/x": () => new Response("leak") })
  const base = door({ argo: `http://127.0.0.1:${up.port}/health` })
  for (const path of ["/h/nope", "/h/../x", "/h/argo/extra", "/h/argo/", "/h/", "/h", "/", "/x", "/h/ar%67o", "/h/ARGO"]) {
    const res = await fetch(`${base}${path}`)
    expect(`${path} ${res.status}`).toBe(`${path} 404`)
  }
  expect(seen).toEqual([])
})

test("/healthz is the door's own liveness", async () => {
  const base = door({ svc: "http://127.0.0.1:1/never" })
  const res = await fetch(`${base}/healthz`)
  expect(res.status).toBe(200)
  expect(await res.text()).toBe("ok\n")
})

test("upstream down is 502", async () => {
  const dead = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("") })
  const port = dead.port
  dead.stop(true)
  const base = door({ svc: `http://127.0.0.1:${port}/health` })
  const res = await fetch(`${base}/h/svc`)
  expect(res.status).toBe(502)
  expect((await res.text()).trim().split("\n")).toHaveLength(1)
})

test("upstream hang is 504 at the injected timeout", async () => {
  const up = upstream({ "/hang": () => new Promise<Response>(() => {}) })
  const base = door({ svc: `http://127.0.0.1:${up.port}/hang` }, { timeoutMs: 150 })
  const t0 = Date.now()
  const res = await fetch(`${base}/h/svc`)
  expect(res.status).toBe(504)
  expect(Date.now() - t0).toBeLessThan(2000)
})

test("a 3xx is passed as a status, without Location and not followed", async () => {
  const up = upstream({
    "/moved": () => new Response("moved", { status: 302, headers: { location: "/elsewhere" } }),
    "/elsewhere": () => new Response("followed"),
  })
  const base = door({ svc: `http://127.0.0.1:${up.port}/moved` })
  const res = await fetch(`${base}/h/svc`, { redirect: "manual" })
  expect(res.status).toBe(302)
  expect(res.headers.get("location")).toBeNull()
  expect(seen.map((s) => s.path)).toEqual(["/moved"])
})

test("a 204 upstream does not crash the door", async () => {
  const up = upstream({ "/none": () => new Response(null, { status: 204 }) })
  const base = door({ svc: `http://127.0.0.1:${up.port}/none` })
  expect((await fetch(`${base}/h/svc`)).status).toBe(204)
})

test("the request's query and path never reach the upstream", async () => {
  const up = upstream({ "/health": () => new Response("ok") })
  const base = door({ svc: `http://127.0.0.1:${up.port}/health?probe=1` })
  const res = await fetch(`${base}/h/svc?secret=hunter2&url=http://evil.example/`, { headers: { authorization: "Bearer x" } })
  expect(res.status).toBe(200)
  expect(seen).toEqual([{ method: "GET", path: "/health?probe=1" }])
})

test("one log line per request, without query strings", async () => {
  const up = upstream({ "/health": () => new Response("ok") })
  const base = door({ svc: `http://127.0.0.1:${up.port}/health` })
  await fetch(`${base}/h/svc?secret=hunter2`)
  expect(logs).toHaveLength(1)
  expect(logs[0]).toMatch(/^GET svc 200 \d+ms$/)
  expect(logs[0]).not.toContain("hunter2")
})

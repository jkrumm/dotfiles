import { describe, expect, test } from "bun:test"
import type { Row } from "../scripts/mini-registry"
import { createApp, doorOfHost, sameOrigin, type Verb } from "./app"

const row = (over: Partial<Row>): Row => ({
  name: "svc", tier: "on-demand", kind: "dev-server", state: "stopped", footprint_mib: null, budget_mib: 400, over: false, doors: ["svc"],
  pri: null, below_band: false, can_start: true, can_stop: true, repo: "r", ...over,
})

const ROWS: Row[] = [
  row({ name: "playground", doors: ["basalt-playground"] }),
  row({ name: "running-dev", doors: ["up-door"], state: "running", footprint_mib: 120 }),
  row({ name: "weather", tier: "manual", kind: "launchd", doors: ["weatherorb"] }),
  row({ name: "iris", tier: "core", kind: "launchd", doors: ["iris"], state: "stopped" }),
  row({ name: "no-cmd", doors: ["no-cmd"], can_start: false }),
  row({ name: "core-up", tier: "core", kind: "launchd", doors: [], state: "running", can_stop: true }),
]

function setup(opts: { rc?: number; hold?: Promise<void> } = {}) {
  const calls: [Verb, string][] = []
  const lines: string[] = []
  const app = createApp({
    rows: async () => ROWS,
    run: async (verb, name) => { calls.push([verb, name]); await opts.hold; return { rc: opts.rc ?? 0, out: "" } },
    log: (l) => lines.push(l),
  })
  return { app, calls, lines }
}

const post = (path: string, headers: Record<string, string> = {}) =>
  new Request(`http://apps.example${path}`, { method: "POST", headers: { host: "apps.example", origin: "http://apps.example", ...headers } })
const wakeReq = (host: string, method = "GET", path = "/_wake/", headers: Record<string, string> = {}) =>
  new Request(`http://${host}${path}`, { method, headers: { host, ...headers } })

describe("host and origin", () => {
  test("the first label of a door host names the door", () => {
    expect(doorOfHost("basalt-playground.mini.jkrumm.com")).toBe("basalt-playground")
    expect(doorOfHost("fpp.test:443")).toBe("fpp")
    expect(doorOfHost("")).toBeNull()
    expect(doorOfHost("../x.test")).toBeNull()
  })

  test("a change needs an Origin equal to Host", () => {
    expect(sameOrigin(post("/x"))).toBe(true)
    expect(sameOrigin(post("/x", { origin: "https://evil.example" }))).toBe(false)
    expect(sameOrigin(new Request("http://apps.example/x", { method: "POST", headers: { host: "apps.example" } }))).toBe(false)
    expect(sameOrigin(post("/x", { "sec-fetch-site": "cross-site" }))).toBe(false)
    expect(sameOrigin(post("/x", { "sec-fetch-site": "same-origin" }))).toBe(true)
  })
})

describe("/_apps", () => {
  test("status lists the registry rows with the fields the page needs", async () => {
    const { app } = setup()
    const res = await app(new Request("http://apps.example/_apps/status", { headers: { host: "apps.example" } }))
    const body = (await res.json()) as { services: Record<string, unknown>[] }
    expect(res.status).toBe(200)
    expect(body.services).toHaveLength(ROWS.length)
    expect(body.services[0]).toMatchObject({ name: "playground", tier: "on-demand", state: "stopped", can_start: true })
    expect(body.services[0]).not.toHaveProperty("pri")
  })

  test("start runs the registered up verb for a known name", async () => {
    const { app, calls, lines } = setup()
    const res = await app(post("/_apps/start/playground", { "x-forwarded-for": "100.64.0.9" }))
    expect(res.status).toBe(202)
    await Promise.resolve()
    expect(calls).toEqual([["up", "playground"]])
    expect(lines.some((l) => l.includes("100.64.0.9 up playground"))).toBe(true)
  })

  test("stop runs down and answers stopped", async () => {
    const { app, calls } = setup()
    const res = await app(post("/_apps/stop/running-dev"))
    expect(res.status).toBe(200)
    expect(calls).toEqual([["down", "running-dev"]])
  })

  test("a core service is never stopped from here", async () => {
    const { app, calls } = setup()
    expect((await app(post("/_apps/stop/core-up"))).status).toBe(403)
    expect(calls).toEqual([])
  })

  test("an unknown name is refused and nothing runs", async () => {
    const { app, calls } = setup()
    expect((await app(post("/_apps/start/nope"))).status).toBe(404)
    expect((await app(post("/_apps/start/..%2F..%2Fetc"))).status).toBe(404)
    expect((await app(post("/_apps/start/a;rm -rf x"))).status).toBe(404)
    expect(calls).toEqual([])
  })

  test("a verb the registry does not hold is refused", async () => {
    const { app, calls } = setup()
    expect((await app(post("/_apps/restart/playground"))).status).toBe(404)
    expect((await app(post("/_apps/start/no-cmd"))).status).toBe(409)
    expect(calls).toEqual([])
  })

  test("a change is POST only and same-origin only", async () => {
    const { app, calls } = setup()
    const get = new Request("http://apps.example/_apps/start/playground", { headers: { host: "apps.example" } })
    expect((await app(get)).status).toBe(405)
    expect((await app(post("/_apps/start/playground", { origin: "https://evil.example" }))).status).toBe(403)
    expect((await app(new Request("http://apps.example/_apps/start/playground", { method: "POST", headers: { host: "apps.example" } }))).status).toBe(403)
    expect(calls).toEqual([])
  })

  test("a service already running is not started again", async () => {
    const { app, calls } = setup()
    const res = await app(post("/_apps/start/running-dev"))
    expect(res.status).toBe(200)
    expect(calls).toEqual([])
  })
})

describe("the wake", () => {
  test("a stopped on-demand door starts its service and answers a page that polls", async () => {
    const { app, calls } = setup()
    const res = await app(wakeReq("basalt-playground.mini.example"))
    expect(res.status).toBe(503)
    expect(res.headers.get("x-wake")).toBe("1")
    expect(res.headers.get("x-wake-state")).toBe("starting")
    expect(await res.text()).toContain("Starting playground")
    expect(calls).toEqual([["up", "playground"]])
  })

  test("a second request while the start is in flight joins it", async () => {
    let release!: () => void
    const { app, calls } = setup({ hold: new Promise<void>((r) => { release = r }) })
    await app(wakeReq("basalt-playground.mini.example"))
    const again = await app(wakeReq("basalt-playground.mini.example"))
    expect(again.headers.get("x-wake-state")).toBe("starting")
    expect(calls).toHaveLength(1)
    release()
  })

  test("a start that failed is reported and not retried at once", async () => {
    const { app, calls } = setup({ rc: 1 })
    await app(wakeReq("basalt-playground.mini.example"))
    await new Promise((r) => setTimeout(r, 5))
    const next = await app(wakeReq("basalt-playground.mini.example"))
    expect(next.headers.get("x-wake-state")).toBe("failed")
    expect(calls).toHaveLength(1)
  })

  test("a manual service gets a page with a Start button and is not started", async () => {
    const { app, calls } = setup()
    const res = await app(wakeReq("weatherorb.mini.example"))
    expect(res.headers.get("x-wake-state")).toBe("manual")
    expect(await res.text()).toContain('<button id="start" >Start</button>')
    expect(calls).toEqual([])
  })

  test("the Start button starts a manual service, same-origin only", async () => {
    const { app, calls } = setup()
    const bad = wakeReq("weatherorb.mini.example", "POST", "/_wake/start", { origin: "https://evil.example" })
    expect((await app(bad)).status).toBe(403)
    expect(calls).toEqual([])
    const ok = wakeReq("weatherorb.mini.example", "POST", "/_wake/start", { origin: "http://weatherorb.mini.example" })
    expect((await app(ok)).status).toBe(202)
    expect(calls).toEqual([["up", "weather"]])
  })

  test("a door of a core service shows a plain 502 and starts nothing", async () => {
    const { app, calls } = setup()
    const res = await app(wakeReq("iris.mini.example"))
    expect(res.status).toBe(502)
    expect(res.headers.get("x-wake")).toBeNull()
    expect(calls).toEqual([])
  })

  test("a service with no start command says so and starts nothing", async () => {
    const { app, calls } = setup()
    const res = await app(wakeReq("no-cmd.mini.example"))
    expect(res.headers.get("x-wake-state")).toBe("nostart")
    expect(calls).toEqual([])
  })

  test("an unknown door is a 502 without the wake header", async () => {
    const { app, calls } = setup()
    const res = await app(wakeReq("nothing.mini.example"))
    expect(res.status).toBe(502)
    expect(res.headers.get("x-wake")).toBeNull()
    expect(calls).toEqual([])
  })

  test("a HEAD never starts anything", async () => {
    const { app, calls } = setup()
    const res = await app(wakeReq("basalt-playground.mini.example", "HEAD"))
    expect(res.status).toBe(503)
    expect(res.headers.get("x-wake")).toBe("1")
    expect(calls).toEqual([])
  })

  test("a request other than GET never starts anything", async () => {
    const { app, calls } = setup()
    const res = await app(wakeReq("basalt-playground.mini.example", "POST", "/_wake/"))
    expect(res.status).toBe(503)
    expect(res.headers.get("x-wake")).toBeNull()
    expect(calls).toEqual([])
  })
})

describe("the rest", () => {
  test("anything else is 404", async () => {
    const { app } = setup()
    expect((await app(new Request("http://x/other", { headers: { host: "x" } }))).status).toBe(404)
    expect((await app(new Request("http://x/healthz", { headers: { host: "x" } }))).status).toBe(200)
  })
})

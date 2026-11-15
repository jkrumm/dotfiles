import { describe, expect, test } from "bun:test"
import type { Row } from "../scripts/mini-registry"
import { lastRequests, mergeLast, planIdle } from "./idle"

const MIN = 60000
const NOW = 1_800_000_000_000

const row = (over: Partial<Row>): Row => ({
  name: "pg", tier: "on-demand", kind: "dev-server", state: "running", footprint_mib: 100, budget_mib: 400, over: false, doors: ["basalt-playground"],
  pri: null, below_band: false, can_start: true, can_stop: true, repo: "r", idle_minutes: 30, ...over,
})
const access = (host: string, uri: string, ts: number) => JSON.stringify({ ts: ts / 1000, request: { host, uri } })

describe("lastRequests", () => {
  test("keeps the newest request per door and skips the probes, the wake and the page itself", () => {
    const log = [
      access("basalt-playground.mini.example", "/", NOW - 50 * MIN),
      access("basalt-playground.mini.example", "/src/main.tsx", NOW - 10 * MIN),
      access("basalt-playground.mini.example", "/_up/x", NOW - 1 * MIN),
      access("fpp.mini.example:443", "/_wake/", NOW - 1 * MIN),
      access("fpp.test", "/", NOW - 20 * MIN),
      "not json",
      "",
    ].join("\n")
    const last = lastRequests(log)
    expect(last.get("basalt-playground")).toBe(NOW - 10 * MIN)
    expect(last.get("fpp")).toBe(NOW - 20 * MIN)
  })
})

describe("mergeLast", () => {
  test("a request that scrolled out of the log tail is remembered from an earlier run", () => {
    const merged = mergeLast({ a: NOW - 5 * MIN, gone: 1 }, new Map([["b", NOW - MIN]]), ["a", "b", "c"])
    expect(merged).toEqual({ a: NOW - 5 * MIN, b: NOW - MIN })
  })

  test("the newer of the remembered and the seen time wins", () => {
    expect(mergeLast({ a: NOW - 20 * MIN }, new Map([["a", NOW - 2 * MIN]]), ["a"])).toEqual({ a: NOW - 2 * MIN })
    expect(mergeLast({ a: NOW - 2 * MIN }, new Map([["a", NOW - 20 * MIN]]), ["a"])).toEqual({ a: NOW - 2 * MIN })
  })
})

describe("planIdle", () => {
  const plan = (rows: Row[], last: Record<string, number>, firstSeen: Record<string, number> = {}) =>
    planIdle({ rows, last: new Map(Object.entries(last)), firstSeen, now: NOW })

  test("a server with no request for its window stops", () => {
    const p = plan([row({})], { "basalt-playground": NOW - 31 * MIN }, { pg: NOW - 120 * MIN })
    expect(p.stop).toEqual(["pg"])
  })

  test("a recent request keeps it", () => {
    expect(plan([row({})], { "basalt-playground": NOW - 5 * MIN }, { pg: NOW - 120 * MIN }).stop).toEqual([])
  })

  test("a server just started counts from its start, not from an old request", () => {
    const p = plan([row({})], { "basalt-playground": NOW - 90 * MIN }, { pg: NOW - 2 * MIN })
    expect(p.stop).toEqual([])
  })

  test("a server never seen before is dated now", () => {
    const p = plan([row({})], {})
    expect(p.stop).toEqual([])
    expect(p.firstSeen).toEqual({ pg: NOW })
  })

  test("the window is per service", () => {
    const p = plan([row({ idle_minutes: 5 })], { "basalt-playground": NOW - 6 * MIN }, { pg: NOW - 60 * MIN })
    expect(p.stop).toEqual(["pg"])
  })

  test("any door of the service keeps it up", () => {
    const p = plan([row({ doors: ["fpp", "fpp-server"] })], { fpp: NOW - 90 * MIN, "fpp-server": NOW - 1 * MIN }, { pg: NOW - 200 * MIN })
    expect(p.stop).toEqual([])
  })

  test("only a running on-demand dev server is judged", () => {
    const rows = [row({ name: "a", state: "stopped" }), row({ name: "b", tier: "manual" }), row({ name: "c", kind: "launchd" }), row({ name: "d", can_stop: false })]
    const p = plan(rows, {}, Object.fromEntries(rows.map((r) => [r.name, NOW - 500 * MIN])))
    expect(p.stop).toEqual([])
    expect(Object.keys(p.firstSeen)).toEqual(["d"])
  })

  test("a server that stopped drops out of the first-seen map", () => {
    expect(plan([row({ state: "stopped" })], {}, { pg: NOW - 1 * MIN }).firstSeen).toEqual({})
  })
})

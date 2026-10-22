import { afterEach, expect, test } from "bun:test"
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { dayFile, run, splitLines, typesFromSchema } from "./herdr-events"

const dirs: string[] = []
const tmp = () => { const d = mkdtempSync(join(tmpdir(), "herdr-events-")); dirs.push(d); return d }
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }) })

test("typesFromSchema keeps type-only subscriptions, drops per-pane and skipped ones", () => {
  const one = (type: string, extra: string[] = []) => ({ required: ["type", ...extra], properties: { type: { const: type } } })
  const schema = { schemas: { request: { $defs: { Subscription: { oneOf: [
    one("tab.closed"), one("pane.exited"), one("pane.agent_status_changed", ["pane_id"]),
    one("pane.output_matched", ["pane_id"]), one("pane.scroll_changed", ["pane_id"]),
  ] } } } } }
  expect(typesFromSchema(schema)).toEqual(["tab.closed", "pane.exited"])
  expect(typesFromSchema({})).toEqual([])
})

test("splitLines returns the unfinished tail", () => {
  const got: string[] = []
  expect(splitLines('{"a":1}\n{"b"', (l) => got.push(l))).toBe('{"b"')
  expect(got).toEqual(['{"a":1}'])
})

test("records events, then a gap line after a server restart", async () => {
  const dir = tmp()
  const sock = join(tmp(), "s.sock")
  let conns = 0
  const server = Bun.listen({
    unix: sock,
    socket: {
      open(s) {
        conns++
        // First connection: ack, one event, then the server "restarts" (closes). Second: ack and stay up.
        s.write('{"id":"rec","result":{"type":"subscription_started"}}\n')
        if (conns === 1) { s.write('{"event":"tab_closed","data":{"tab_id":"t1"}}\n'); setTimeout(() => s.end(), 50) }
        else s.write('{"event":"pane_exited","data":{"pane_id":"p1"}}\n')
      },
      data() {},
    },
  })
  const ac = new AbortController()
  const done = run({ sock, dir, listPanes: async () => [], eventTypes: async () => ["tab.closed"], backoffMs: [20, 40], signal: ac.signal })
  await Bun.sleep(1200)
  ac.abort()
  server.stop(true)
  await Promise.race([done, Bun.sleep(1500)])

  const files = readdirSync(dir)
  expect(files).toEqual([dayFile(dir, new Date()).split("/").pop()!])
  const lines = readFileSync(join(dir, files[0]), "utf8").trim().split("\n").map((l) => JSON.parse(l))
  expect(lines.map((l) => l.event)).toEqual(["recorder.started", "tab_closed", "recorder.gap", "recorder.started", "pane_exited"])
  expect(lines.every((l) => typeof l.ts === "string")).toBe(true)
  expect(lines[2].why).toBe("closed")
})

test("a rejected subscription is recorded and reconnected, not left deaf", async () => {
  const dir = tmp()
  const sock = join(tmp(), "s.sock")
  const server = Bun.listen({
    unix: sock,
    socket: { open(s) { s.write('{"id":"rec","error":{"code":"invalid_request","message":"nope"}}\n') }, data() {} },
  })
  const ac = new AbortController()
  const done = run({ sock, dir, listPanes: async () => [], eventTypes: async () => ["tab.closed"], backoffMs: [20, 40], signal: ac.signal })
  await Bun.sleep(400)
  ac.abort()
  server.stop(true)
  await Promise.race([done, Bun.sleep(1500)])
  const lines = readFileSync(join(dir, readdirSync(dir)[0]), "utf8").trim().split("\n").map((l) => JSON.parse(l))
  expect(lines.filter((l) => l.event === "recorder.subscribe_failed").length).toBeGreaterThan(1) // it retried
  expect(lines[0].error.message).toBe("nope")
})

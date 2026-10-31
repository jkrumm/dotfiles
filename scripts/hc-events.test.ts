import { afterEach, expect, test } from "bun:test"
import { chmodSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { coreAvailable, dayFile, openHc, run, splitLines, type Link } from "./hc-events"

const dirs: string[] = []
const tmp = () => { const d = mkdtempSync(join(tmpdir(), "hc-events-")); dirs.push(d); return d }
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }) })

const ACK = (seq = 5, terminals: unknown[] = []) => JSON.stringify({ jsonrpc: "2.0", id: 1, result: { seq, terminals } })
const EVT = (seq: number, type: string, terminal: string, data: unknown) =>
  JSON.stringify({ jsonrpc: "2.0", method: "event", params: { seq, terminal, type, data } })

/** A scripted link: yields the lines, then ends (`hang: false`) or stays open until closed (`hang: true`). */
function link(lines: string[], hang: boolean): Link {
  let release: () => void = () => {}
  const closed = new Promise<void>((r) => { release = r })
  async function* gen() {
    for (const l of lines) yield l
    if (hang) await closed
  }
  return { lines: gen(), close: release }
}

/** Runs the recorder against scripted links (then "no core": open rejects) for `ms`, returns the recorded lines. */
async function record(links: Link[], ms: number, opts: { idleMs?: number } = {}) {
  const dir = tmp()
  const ac = new AbortController()
  const queue = [...links]
  const done = run({
    dir, backoffMs: [10, 20], signal: ac.signal, ...opts,
    open: async () => queue.shift() ?? (() => { throw new Error("no core") })(),
  })
  await Bun.sleep(ms)
  ac.abort()
  await Promise.race([done, Bun.sleep(1500)])
  const files = readdirSync(dir)
  expect(files).toEqual([dayFile(dir, new Date()).split("/").pop()!])
  return readFileSync(join(dir, files[0]), "utf8").trim().split("\n").map((l) => JSON.parse(l))
}

test("splitLines returns the unfinished tail", () => {
  const got: string[] = []
  expect(splitLines('{"a":1}\n{"b"', (l) => got.push(l))).toBe('{"b"')
  expect(got).toEqual(['{"a":1}'])
})

test("records the snapshot and events, skips heartbeats", async () => {
  const lines = await record([link([
    ACK(5, [{ address: "t1" }]),
    JSON.stringify({ jsonrpc: "2.0", method: "heartbeat", params: { seq: 5 } }),
    EVT(6, "status", "t1", { status: { app: "claude-code", state: "working" } }),
    EVT(7, "lost", "t1", { reason: "signaled", signal: 9 }),
  ], true)], 150)
  expect(lines.map((l) => l.event)).toEqual(["recorder.started", "recorder.snapshot", "status", "lost"])
  expect(lines[1]).toMatchObject({ why: "subscribe", seq: 5, terminals: [{ address: "t1" }] })
  expect(lines[2]).toMatchObject({ terminal: "t1", seq: 6, data: { status: { state: "working" } } })
  expect(lines.every((l) => typeof l.ts === "string")).toBe(true)
})

test("stream EOF (core restart) writes a gap once the next subscription is up", async () => {
  const lines = await record([
    link([ACK(), EVT(6, "turn", "t1", { state: "done", turn: 1 })], false),
    link([ACK(9), EVT(10, "turn", "t1", { state: "done", turn: 2 })], true),
  ], 300)
  expect(lines.map((l) => l.event)).toEqual([
    "recorder.started", "recorder.snapshot", "turn", "recorder.gap", "recorder.started", "recorder.snapshot", "turn"])
  expect(lines[3].why).toBe("closed")
  expect(Date.parse(lines[3].from)).toBeLessThanOrEqual(Date.parse(lines[3].to))
})

test("a missed event is a gap plus the snapshot that replaces state", async () => {
  const lines = await record([link([
    ACK(5),
    EVT(6, "labels", "t1", { labels: {} }),
    JSON.stringify({ jsonrpc: "2.0", method: "missed", params: { seq: 15191, terminals: [{ address: "t1" }, { address: "t2" }] } }),
    EVT(15192, "labels", "t2", { labels: { a: "b" } }),
  ], true)], 150)
  expect(lines.map((l) => l.event)).toEqual(["recorder.started", "recorder.snapshot", "labels", "recorder.gap", "recorder.snapshot", "labels"])
  expect(lines[3]).toMatchObject({ why: "missed", from_seq: 6, to_seq: 15191 })
  expect(lines[4]).toMatchObject({ why: "missed", seq: 15191, terminals: [{ address: "t1" }, { address: "t2" }] })
})

test("an unparseable line is recorded with a gap marker and the stream carries on", async () => {
  const lines = await record([link([
    ACK(),
    '{"jsonrpc":"2.0","method":"event","params":{"seq":6,"termi', // truncated, as fact 7 saw once
    "not an object at all [",
    "42",
    EVT(7, "title", "t1", { title: "x" }),
  ], true)], 150)
  const events = lines.map((l) => l.event)
  expect(events.filter((e) => e === "recorder.unparsed").length).toBe(3)
  expect(lines.filter((l) => l.event === "recorder.gap").map((l) => l.why)).toEqual(["unparsed line", "unparsed line", "unparsed line"])
  expect(events.at(-1)).toBe("title")
  expect(lines.find((l) => l.event === "recorder.unparsed").raw).toContain('"termi')
})

test("a rejected subscription is recorded and reconnected, not left deaf", async () => {
  const rejected = () => link([JSON.stringify({ jsonrpc: "2.0", id: 1, error: { code: -32602, message: "nope" } })], true)
  const lines = await record([rejected(), rejected(), link([ACK(), EVT(2, "title", "t1", { title: "x" })], true)], 300)
  expect(lines.filter((l) => l.event === "recorder.subscribe_failed").length).toBe(2)
  expect(lines[0].error.message).toBe("nope")
  expect(lines.map((l) => l.event).slice(-4)).toEqual(["recorder.gap", "recorder.started", "recorder.snapshot", "title"])
})

test("no core at the start: retries, then the first ack records the gap", async () => {
  const dir = tmp()
  const ac = new AbortController()
  let tries = 0
  const logs: string[] = []
  const done = run({
    dir, backoffMs: [10, 20], signal: ac.signal, log: (l) => logs.push(l),
    open: async () => { if (++tries < 3) throw new Error("com.jkrumm.herdr-core is not running"); return link([ACK()], true) },
  })
  await Bun.sleep(200)
  ac.abort()
  await Promise.race([done, Bun.sleep(1500)])
  const lines = readFileSync(join(dir, readdirSync(dir)[0]), "utf8").trim().split("\n").map((l) => JSON.parse(l))
  expect(lines.map((l) => l.event)).toEqual(["recorder.gap", "recorder.started", "recorder.snapshot"])
  expect(logs[0]).toContain("no core")
})

test("a stream that goes silent past idleMs is dropped and reconnected", async () => {
  const lines = await record([link([ACK()], true), link([ACK(8)], true)], 400, { idleMs: 80 })
  expect(lines.map((l) => l.event)).toEqual(["recorder.started", "recorder.snapshot", "recorder.gap", "recorder.started", "recorder.snapshot"])
  expect(lines[2].why).toBe("idle")
})

test("coreAvailable: a scratch HC_SESSION skips launchd, else the job must be running", () => {
  const down = () => "gui/501/com.jkrumm.herdr-core = {\n\tstate = not running\n}"
  const up = () => "gui/501/com.jkrumm.herdr-core = {\n\tstate = running\n\tpid = 1\n}"
  expect(coreAvailable({ HC_SESSION: "x" }, down)).toBe(true)
  expect(coreAvailable({}, down)).toBe(false)
  expect(coreAvailable({}, up)).toBe(true)
  expect(coreAvailable({}, () => { throw new Error("launchctl failed") })).toBe(false)
})

test("openHc refuses without a core and otherwise talks to `hc connect`", async () => {
  await expect(openHc(() => false)).rejects.toThrow("not connecting")
  const dir = tmp()
  const fake = join(dir, "hc")
  writeFileSync(fake, `#!/bin/sh\nread -r req\necho "$req" >> "${dir}/req.log"\nprintf '{"jsonrpc":"2.0","id":1,"result":{"seq":3,"terminals":[]}}\\n{"jsonrpc":"2.0","method":"event","params":{"seq":4,"terminal":"t1","type":"title","data":{}}}\\n'\n`)
  chmodSync(fake, 0o755)
  process.env.HC_BIN = fake
  try {
    const l = await openHc(() => true)
    const got: string[] = []
    for await (const line of l.lines) got.push(line)
    expect(got.length).toBe(2)
    expect(JSON.parse(got[1]).params.type).toBe("title")
    expect(JSON.parse(readFileSync(join(dir, "req.log"), "utf8"))).toMatchObject({ method: "events.subscribe", id: 1 })
  } finally {
    delete process.env.HC_BIN
  }
})

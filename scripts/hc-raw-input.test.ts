import { afterAll, expect, test } from "bun:test"
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { CLOSE, CREDIT, DATA, createFrameParser, encodeFrame, isAgent, typeInto } from "./hc-raw-input"

test("encodeFrame is channel u32le, type u8, length u32le, payload (bytes seen from `hc attach`)", () => {
  expect([...encodeFrame(1, DATA, "hello\r")]).toEqual([1, 0, 0, 0, 0, 6, 0, 0, 0, ...Buffer.from("hello\r")])
  expect([...encodeFrame(1, CLOSE)]).toEqual([1, 0, 0, 0, 2, 0, 0, 0, 0])
  expect([...encodeFrame(1, CREDIT, new Uint8Array([255, 0, 0, 0]))]).toEqual([1, 0, 0, 0, 1, 4, 0, 0, 0, 255, 0, 0, 0])
})

test("the frame parser reassembles frames split across chunks", () => {
  const a = encodeFrame(0, DATA, '{"id":1}')
  const b = encodeFrame(3, DATA, "\x1b[?997;2n")
  const all = Buffer.concat([a, b])
  const parse = createFrameParser()
  const got = [...parse(all.subarray(0, 5)), ...parse(all.subarray(5, a.length + 4)), ...parse(all.subarray(a.length + 4))]
  expect(got.map((f) => [f.channel, f.type, f.payload.toString()])).toEqual([
    [0, DATA, '{"id":1}'],
    [3, DATA, "\x1b[?997;2n"],
  ])
})

test("isAgent takes live claude / opencode terminals, by status or foreground program, never a shell", () => {
  const t = (over: object) => ({ address: "t1", state: "live", cols: 80, rows: 24, ...over })
  expect(isAgent(t({ status: { app: "claude-code" } }))).toBe(true)
  expect(isAgent(t({ foreground: { argv: ["/Users/x/.local/bin/claude", "--resume", "id"], name: "claude" } }))).toBe(true)
  expect(isAgent(t({ foreground: { name: "opencode" } }))).toBe(true)
  expect(isAgent(t({ foreground: { argv: ["-zsh"] }, argv: ["claude"] }))).toBe(false) // claude exited, a shell took over
  expect(isAgent(t({ argv: ["claude"] }))).toBe(true) // no foreground fact yet: the program itself
  expect(isAgent(t({ state: "finished", status: { app: "claude-code" } }))).toBe(false)
  expect(isAgent(t({ argv: ["python3"] }))).toBe(false)
})

// A stub `hc connect` that speaks the framed protocol: terminal.get answers `terminals`, attach hands out channel 5, and
// the bytes typed on it are appended to `log`. HC_BIN points typeInto at it, so a test never reaches a real core. The
// config is baked into the stub because a spawned child does not see env set inside the test process.
const stubDir = mkdtempSync(join(tmpdir(), "hc-raw-input-"))
afterAll(() => rmSync(stubDir, { recursive: true, force: true }))

function writeStub({ terminals, log }: { terminals: object; log: string }) {
  const path = join(stubDir, "hc")
  writeFileSync(path, `#!/usr/bin/env bun
import { appendFileSync } from "node:fs"
import { CLOSE, DATA, createFrameParser, encodeFrame } from ${JSON.stringify(join(import.meta.dir, "hc-raw-input.ts"))}
const terminals = ${JSON.stringify(terminals)}
const parse = createFrameParser()
let raw = Buffer.alloc(0)
let framed = false
const reply = (id, result) => process.stdout.write(encodeFrame(0, DATA, JSON.stringify({ jsonrpc: "2.0", id, result })))
const handle = (f) => {
  if (f.channel === 0) {
    const m = JSON.parse(f.payload.toString())
    if (m.method === "terminal.get") reply(m.id, terminals[m.params.terminal])
    if (m.method === "terminal.attach") reply(m.id, { channel: 5 })
  } else if (f.type === DATA) appendFileSync(${JSON.stringify(log)}, f.payload)
  else if (f.type === CLOSE) process.stdout.write(encodeFrame(f.channel, CLOSE))
}
for await (const chunk of Bun.stdin.stream()) {
  if (!framed) {
    raw = Buffer.concat([raw, chunk])
    const nl = raw.indexOf(10)
    if (nl < 0) continue
    framed = true
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: 0, result: {} }) + "\\n")
    for (const f of parse(raw.subarray(nl + 1))) handle(f)
  } else for (const f of parse(chunk)) handle(f)
}
`)
  chmodSync(path, 0o755)
  return path
}

async function runAgainstStub(agentsOnly: boolean) {
  const log = join(stubDir, `typed-${agentsOnly}`)
  writeFileSync(log, "")
  const live = { state: "live", cols: 80, rows: 24 }
  const prev = process.env.HC_BIN
  process.env.HC_BIN = writeStub({
    log,
    terminals: {
      t1: { address: "t1", ...live, status: { app: "claude-code" } },
      t2: { address: "t2", ...live, foreground: { argv: ["-zsh"] }, argv: ["claude"] }, // claude exited since it was listed
      t3: { address: "t3", state: "finished", cols: 80, rows: 24 },
    },
  })
  try {
    const out = await typeInto({ addresses: ["t1", "t2", "t3"], bytes: Buffer.from("\x1b[?997;2n"), agentsOnly })
    return { ...out, typed: readFileSync(log, "utf8") }
  } finally {
    if (prev === undefined) delete process.env.HC_BIN
    else process.env.HC_BIN = prev
  }
}

test("typeInto --agents rechecks right before sending and skips a terminal that stopped being an agent", async () => {
  const r = await runAgainstStub(true)
  expect(r.reached).toEqual(["t1"])
  expect(r.skipped).toEqual(["t2: no longer an agent"])
  expect(r.failed).toEqual(["t3: not live"])
  expect(r.typed).toBe("\x1b[?997;2n") // once: nothing reached the shell
})

test("typeInto with explicit addresses still types into a non-agent terminal", async () => {
  const r = await runAgainstStub(false)
  expect(r.reached).toEqual(["t1", "t2"])
  expect(r.skipped).toEqual([])
  expect(r.typed).toBe("\x1b[?997;2n\x1b[?997;2n")
})

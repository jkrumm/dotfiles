import { expect, test } from "bun:test"
import { CLOSE, CREDIT, DATA, createFrameParser, encodeFrame, isAgent } from "./hc-raw-input"

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

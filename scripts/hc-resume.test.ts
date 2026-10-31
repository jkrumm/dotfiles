import { expect, test } from "bun:test"
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { createResumer, isLoginShell, isSubscribeError, parseLine, resumeLine, run, sendHc, type Link, type Msg, type Terminal } from "./hc-resume"

const ID = "0d6f3a52-1c1e-4a55-9d0e-aaaaaaaaaaaa"
const ID2 = "1e7a4b63-2d2f-4b66-8e1f-bbbbbbbbbbbb"
const shell = ["/bin/zsh", "-l"]
const term = (over: Partial<Terminal> & { labels?: Record<string, string> } = {}): Terminal => ({
  address: "t1", argv: shell, labels: { "jk.claude.session": ID, "jk.claude.config": "/h/.claude-me" }, ...over,
})
const fg = (t: Terminal): Terminal => ({ ...t, foreground: { argv: shell } })
const snap = (...terminals: Terminal[]): Msg => ({ kind: "snapshot", terminals: terminals.map((t) => (t.foreground === undefined ? fg(t) : t)) })
const restarted = (t: Terminal): Msg => ({ kind: "restarted", terminals: [t] })

function harness(delayMs = 0) {
  const sent: [string, string][] = []
  const r = createResumer(async (a, l) => { sent.push([a, l]); if (delayMs) await Bun.sleep(delayMs) })
  return { sent, r }
}

test("login shell detection: foreground wins, else the terminal's program", () => {
  expect(isLoginShell(term(), true)).toBe(true)
  expect(isLoginShell(term({ argv: ["-zsh"] }), true)).toBe(true)
  expect(isLoginShell(term({ argv: ["/bin/zsh"] }), true)).toBe(false)
  expect(isLoginShell(term({ argv: ["claude"], foreground: null }), true)).toBe(false)
  expect(isLoginShell(term({ foreground: { argv: ["claude", "--resume", ID] } }), true)).toBe(false)
  expect(isLoginShell(term({ argv: ["sleep", "9"], foreground: { argv: shell } }))).toBe(true)
  // a snapshot must carry the foreground fact: the terminal's own argv is not enough
  expect(isLoginShell(term())).toBe(false)
  expect(isLoginShell(term({ foreground: null }))).toBe(false)
})

test("resume line: account dir quoted, iu uses env -u", () => {
  expect(resumeLine(term().labels!)).toBe(`env CLAUDE_CONFIG_DIR='/h/.claude-me' claude --dangerously-skip-permissions --resume ${ID}`)
  expect(resumeLine({ "jk.claude.session": ID })).toBe(`env -u CLAUDE_CONFIG_DIR claude --dangerously-skip-permissions --resume ${ID}`)
  expect(resumeLine({ "jk.claude.session": "x; rm -rf ~" })).toBeNull()
})

test("an account change on a reused terminal uses the new labels (me -> iu)", async () => {
  const { sent, r } = harness()
  r.handle(restarted(term()))
  await r.settled()
  r.handle(restarted(term({ labels: { "jk.claude.session": ID2 } })))
  await r.settled()
  expect(sent.map((s) => s[1])).toEqual([
    `env CLAUDE_CONFIG_DIR='/h/.claude-me' claude --dangerously-skip-permissions --resume ${ID}`,
    `env -u CLAUDE_CONFIG_DIR claude --dangerously-skip-permissions --resume ${ID2}`,
  ])
})

test("overlapping triggers (restarted + missed + reconnect snapshot) send exactly once", async () => {
  const { sent, r } = harness(30)
  r.handle(restarted(term()))
  r.handle(snap(term()))
  r.handle(snap(term()))
  await r.settled()
  r.handle(snap(term())) // a later reconnect, same session id: still no second attempt
  await r.settled()
  expect(sent).toHaveLength(1)
})

test("not a login shell and no session label send nothing", async () => {
  const { sent, r } = harness()
  r.handle(snap(term({ argv: ["claude"], foreground: { argv: ["claude"] } }), term({ address: "t2", labels: {} }), term({ address: "t3", labels: { "jk.claude.config": "/x" } })))
  await r.settled()
  expect(sent).toEqual([])
})

test("a failed send is not retried for the same session", async () => {
  let n = 0
  const r = createResumer(async () => { n++; throw new Error("nope") })
  r.handle(snap(term()))
  await r.settled()
  r.handle(snap(term()))
  await r.settled()
  expect(n).toBe(1)
})

test("parseLine: subscribe result and missed are snapshots, restarted needs a newer seq", () => {
  const seq = { n: 0 }
  const t = term()
  expect(parseLine(JSON.stringify({ id: 1, result: { seq: 5, terminals: [t] } }), seq)).toEqual({ kind: "snapshot", terminals: [t] })
  expect(seq.n).toBe(5)
  expect(parseLine(JSON.stringify({ method: "event", params: { seq: 5, type: "restarted", data: t } }), seq)).toBeNull()
  expect(parseLine(JSON.stringify({ method: "event", params: { seq: 6, type: "restarted", data: t } }), seq)).toEqual(restarted(t))
  expect(parseLine(JSON.stringify({ method: "missed", params: { seq: 20, terminals: [t] } }), seq)).toEqual({ kind: "snapshot", terminals: [t] })
  expect(parseLine(JSON.stringify({ method: "event", params: { seq: 19, type: "restarted", data: t } }), seq)).toBeNull()
  expect(parseLine(JSON.stringify({ method: "heartbeat", params: { seq: 21 } }), seq)).toBeNull()
  expect(parseLine("not json", seq)).toBeNull()
})

test("no core: open() keeps failing, nothing is sent; once up, the snapshot resumes; EOF reconnects without a double send", async () => {
  const sent: string[] = []
  const logs: string[] = []
  let opens = 0
  const ac = new AbortController()
  const link = (msgs: Msg[]): Link => ({
    messages: (async function* () { yield* msgs })(),
    close() {},
  })
  const done = run({
    open: async () => {
      opens++
      if (opens <= 2) throw new Error("hc connect exited 2")
      if (opens === 3) return link([snap(term())])
      if (opens === 4) return link([snap(term())])
      ac.abort()
      return link([])
    },
    send: async (a, l) => { sent.push(`${a} ${l}`) },
    log: (l) => logs.push(l),
    backoffMs: [5, 10],
    signal: ac.signal,
  })
  await Promise.race([done, Bun.sleep(3000)])
  expect(opens).toBeGreaterThanOrEqual(5)
  expect(logs.filter((l) => l.startsWith("no core"))).toHaveLength(2)
  expect(sent).toHaveLength(1)
})

test("a restarted event is a new loss: the same session resumes again; snapshots keep the dedupe", async () => {
  const { sent, r } = harness()
  r.handle(restarted(term()))
  await r.settled()
  r.handle(snap(term()))
  await r.settled()
  expect(sent).toHaveLength(1)
  r.handle(restarted(term())) // second kill -9 of the resumed session
  await r.settled()
  expect(sent).toHaveLength(2)
  r.handle(restarted(term()))
  r.handle(restarted(term())) // overlapping: inflight still dedupes
  await r.settled()
  expect(sent.length).toBeLessThanOrEqual(3)
})

test("a snapshot without a foreground fact sends nothing", async () => {
  const { sent, r } = harness()
  r.handle({ kind: "snapshot", terminals: [term()] })
  await r.settled()
  expect(sent).toEqual([])
})

test("a rejected events.subscribe response is recognised", () => {
  expect(isSubscribeError('{"id":1,"error":{"code":-32000}}')).toBe(true)
  expect(isSubscribeError('{"id":1,"result":{}}')).toBe(false)
  expect(isSubscribeError('{"id":2,"error":{}}')).toBe(false)
  expect(isSubscribeError("junk")).toBe(false)
})

// A fake `hc connect`: answers terminal.get from FAKE_TERMINAL, records every request, FAKE_HANG never answers.
function fakeHc(dir: string) {
  const bin = join(dir, "hc")
  writeFileSync(bin, `#!/usr/bin/env bun
import { appendFileSync } from "node:fs"
for await (const chunk of Bun.stdin.stream()) {
  for (const l of new TextDecoder().decode(chunk).split("\\n").filter(Boolean)) {
    const q = JSON.parse(l)
    appendFileSync(process.env.FAKE_LOG!, q.method + "\\n")
    if (process.env.FAKE_HANG) continue
    const result = q.method === "terminal.get" ? JSON.parse(process.env.FAKE_TERMINAL!) : { turn: 0 }
    console.log(JSON.stringify({ id: q.id, result }))
  }
}
`)
  chmodSync(bin, 0o755)
  return bin
}

async function withFake(env: Record<string, string>, fn: (log: () => string[]) => Promise<void>) {
  const dir = mkdtempSync(join(tmpdir(), "hc-resume-"))
  const saved = { ...process.env }
  Object.assign(process.env, { HC_BIN: fakeHc(dir), FAKE_LOG: join(dir, "log") }, env)
  try { await fn(() => { try { return readFileSync(join(dir, "log"), "utf8").trim().split("\n") } catch { return [] } }) }
  finally { for (const k of Object.keys(env).concat("HC_BIN", "FAKE_LOG")) delete process.env[k]; Object.assign(process.env, saved); rmSync(dir, { recursive: true, force: true }) }
}

test("sendHc revalidates: still a login shell with the same session -> sends", async () => {
  await withFake({ FAKE_TERMINAL: JSON.stringify(fg(term())) }, async (log) => {
    await sendHc("t1", "line", ID)
    expect(log()).toEqual(["terminal.get", "terminal.send"])
  })
})

test("sendHc skips when the session label changed or the shell is gone", async () => {
  await withFake({ FAKE_TERMINAL: JSON.stringify(fg(term({ labels: { "jk.claude.session": ID2 } }))) }, async (log) => {
    await expect(sendHc("t1", "line", ID)).rejects.toThrow("no longer carries session")
    expect(log()).toEqual(["terminal.get"])
  })
  await withFake({ FAKE_TERMINAL: JSON.stringify({ ...term(), foreground: { argv: ["claude"] } }) }, async (log) => {
    await expect(sendHc("t1", "line", ID)).rejects.toThrow("no longer at a login shell")
    expect(log()).toEqual(["terminal.get"])
  })
})

test("sendHc has a hard deadline: an unanswered connection is killed and rejects", async () => {
  await withFake({ FAKE_TERMINAL: "{}", FAKE_HANG: "1" }, async () => {
    const t0 = Date.now()
    await expect(sendHc("t1", "line", ID, 300)).rejects.toThrow("timed out")
    expect(Date.now() - t0).toBeLessThan(3000)
  })
})

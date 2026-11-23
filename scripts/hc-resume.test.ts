import { expect, test } from "bun:test"
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { DEFAULT_MAX_INFLIGHT, DEFAULT_STAGGER_MS, NotConnecting, RetryLater, createLostTracker, createResumer, fileProgramStore, parseBootTime, isLoginShell, modelFlags, pacingFromEnv, tailnetRunning, waitForTailnet, coreAvailable, isSubscribeError, listHc, openHc, parseLine, resumeLine, run, sendHc, type Link, type Msg, type Terminal } from "./hc-resume"

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
  const r = createResumer(async (a, l) => { sent.push([a, l]); if (delayMs) await Bun.sleep(delayMs) }, undefined, { staggerMs: 0 })
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
  // foreground null is unknown, the fallback never applies to it
  expect(isLoginShell(term({ foreground: null }), true)).toBe(false)
})

test("snapshot: missing foreground sends nothing, login-shell foreground sends, claude foreground sends nothing", async () => {
  const missing = harness()
  missing.r.handle({ kind: "snapshot", terminals: [term(), term({ address: "t2", foreground: null })] })
  await missing.r.settled()
  expect(missing.sent).toEqual([])
  const login = harness()
  login.r.handle({ kind: "snapshot", terminals: [term({ foreground: { argv: shell } })] })
  await login.r.settled()
  expect(login.sent).toHaveLength(1)
  const live = harness()
  live.r.handle({ kind: "snapshot", terminals: [term({ foreground: { argv: ["claude", "--resume", ID] } })] })
  await live.r.settled()
  expect(live.sent).toEqual([])
  // the foreground arrives in a later snapshot: re-evaluated, now sends
  missing.r.handle(snap(term()))
  await missing.r.settled()
  expect(missing.sent).toHaveLength(1)
})

test("a restarted record without a foreground fact still resumes (its replacement shell is the terminal's argv)", async () => {
  const { sent, r } = harness()
  r.handle(restarted(term()))
  await r.settled()
  expect(sent).toHaveLength(1)
})

test("resume line: account dir quoted, iu uses env -u", () => {
  expect(resumeLine(term().labels!)).toBe(`env CLAUDE_CONFIG_DIR='/h/.claude-me' claude --dangerously-skip-permissions --strict-mcp-config --resume ${ID}`)
  expect(resumeLine({ "jk.claude.session": ID })).toBe(`env -u CLAUDE_CONFIG_DIR claude --dangerously-skip-permissions --strict-mcp-config --resume ${ID}`)
  expect(resumeLine({ "jk.claude.session": "x; rm -rf ~" })).toBeNull()
})

test("resume line keeps --model and --effort from the terminal argv; none stays as is", () => {
  const labels = term().labels!
  const argv = ["claude", "--dangerously-skip-permissions", "--model", "claude-opus-5-5[1m]", "--effort=high"]
  expect(resumeLine(labels, argv)).toBe(`env CLAUDE_CONFIG_DIR='/h/.claude-me' claude --dangerously-skip-permissions --strict-mcp-config --model 'claude-opus-5-5[1m]' --effort 'high' --resume ${ID}`)
  expect(resumeLine(labels, ["claude", "--model", "sonnet"])).toBe(`env CLAUDE_CONFIG_DIR='/h/.claude-me' claude --dangerously-skip-permissions --strict-mcp-config --model 'sonnet' --resume ${ID}`)
  expect(resumeLine(labels, shell)).toBe(resumeLine(labels))
  expect(modelFlags(["claude", "--model", "x; rm -rf ~", "--effort"])).toEqual([])
})

test("createResumer passes the terminal argv flags into the typed line", async () => {
  const { sent, r } = harness()
  r.handle(restarted(term({ argv: ["-zsh", "--model", "opus", "--effort", "max"] })))
  await r.settled()
  expect(sent[0][1]).toContain("--model 'opus' --effort 'max' --resume")
})

test("an account change on a reused terminal uses the new labels (me -> iu)", async () => {
  const { sent, r } = harness()
  r.handle(restarted(term()))
  await r.settled()
  r.handle(restarted(term({ labels: { "jk.claude.session": ID2 } })))
  await r.settled()
  expect(sent.map((s) => s[1])).toEqual([
    `env CLAUDE_CONFIG_DIR='/h/.claude-me' claude --dangerously-skip-permissions --strict-mcp-config --resume ${ID}`,
    `env -u CLAUDE_CONFIG_DIR claude --dangerously-skip-permissions --strict-mcp-config --resume ${ID2}`,
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
  const r = createResumer(async () => { n++; throw new Error("nope") }, undefined, { staggerMs: 0 })
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
    pacing: { staggerMs: 0 },
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
    const result = q.method === "terminal.get" ? JSON.parse(process.env.FAKE_TERMINAL!) : q.method === "terminal.list" ? { terminals: JSON.parse(process.env.FAKE_TERMINALS!) } : { turn: 0 }
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
    await sendHc("t1", "line", ID, 5000, () => true)
    expect(log()).toEqual(["terminal.get", "terminal.send"])
  })
})

test("sendHc: unknown foreground is typed into only for a restarted trigger with the foreground key ABSENT", async () => {
  // restarted + absent foreground -> the terminal's own login-shell argv stands in: types
  await withFake({ FAKE_TERMINAL: JSON.stringify(term()) }, async (log) => {
    await sendHc("t1", "line", ID, 5000, () => true, true)
    expect(log()).toEqual(["terminal.get", "terminal.send"])
  })
  // snapshot-triggered + absent foreground -> RetryLater, nothing typed
  await withFake({ FAKE_TERMINAL: JSON.stringify(term()) }, async (log) => {
    await expect(sendHc("t1", "line", ID, 5000, () => true, false)).rejects.toBeInstanceOf(RetryLater)
    expect(log()).toEqual(["terminal.get"])
  })
  // foreground: null is unknown for every trigger, the fallback included
  for (const fallback of [false, true]) {
    await withFake({ FAKE_TERMINAL: JSON.stringify({ ...term(), foreground: null }) }, async (log) => {
      await expect(sendHc("t1", "line", ID, 5000, () => true, fallback)).rejects.toBeInstanceOf(RetryLater)
      expect(log()).toEqual(["terminal.get"])
    })
  }
  // a claude foreground is skipped for every trigger, even with a login-shell argv
  for (const fallback of [false, true]) {
    await withFake({ FAKE_TERMINAL: JSON.stringify({ ...term(), foreground: { argv: ["claude"] } }) }, async (log) => {
      await expect(sendHc("t1", "line", ID, 5000, () => true, fallback)).rejects.toThrow("no longer at a login shell")
      expect(log()).toEqual(["terminal.get"])
    })
  }
})

test("a live agent (status.app from its own hook) is never typed into, whatever the foreground fact says", async () => {
  const live = { app: "claude-code", state: "done" }
  // snapshot: a stale login-shell foreground with a reporting Claude -> nothing; without status -> resumes
  const a = harness()
  a.r.handle({ kind: "snapshot", terminals: [term({ foreground: { argv: shell }, status: live })] })
  await a.r.settled()
  expect(a.sent).toEqual([])
  const b = harness()
  b.r.handle({ kind: "snapshot", terminals: [term({ foreground: { argv: shell }, status: null })] })
  await b.r.settled()
  expect(b.sent).toHaveLength(1)
  // restarted: the event proves the program ended, a leftover status does not block
  const c = harness()
  c.r.handle(restarted(term({ foreground: { argv: shell }, status: live })))
  await c.r.settled()
  expect(c.sent).toHaveLength(1)
  // sendHc re-read: same rule per trigger
  await withFake({ FAKE_TERMINAL: JSON.stringify({ ...term(), foreground: { argv: shell }, status: live }) }, async (log) => {
    await expect(sendHc("t1", "line", ID, 5000, () => true, false)).rejects.toThrow("live claude-code session")
    expect(log()).toEqual(["terminal.get"])
  })
  await withFake({ FAKE_TERMINAL: JSON.stringify({ ...term(), foreground: { argv: shell }, status: live }) }, async (log) => {
    await sendHc("t1", "line", ID, 5000, () => true, true)
    expect(log()).toEqual(["terminal.get", "terminal.send"])
  })
})

test("createResumer passes argvFallback only for a restarted trigger", async () => {
  const flags: (boolean | undefined)[] = []
  const r = createResumer(async (_a, _l, _s, fb) => { flags.push(fb) }, undefined, { staggerMs: 0 })
  r.handle(restarted(term()))
  await r.settled()
  r.handle(snap(term({ address: "t2" })))
  await r.settled()
  expect(flags).toEqual([true, false])
})

test("sendHc skips when the session label changed or the shell is gone", async () => {
  await withFake({ FAKE_TERMINAL: JSON.stringify(fg(term({ labels: { "jk.claude.session": ID2 } }))) }, async (log) => {
    await expect(sendHc("t1", "line", ID, 5000, () => true)).rejects.toThrow("no longer carries session")
    expect(log()).toEqual(["terminal.get"])
  })
  await withFake({ FAKE_TERMINAL: JSON.stringify({ ...term(), foreground: { argv: ["claude"] } }) }, async (log) => {
    await expect(sendHc("t1", "line", ID, 5000, () => true)).rejects.toThrow("no longer at a login shell")
    expect(log()).toEqual(["terminal.get"])
  })
})

test("sendHc has a hard deadline: an unanswered connection is killed and rejects", async () => {
  await withFake({ FAKE_TERMINAL: "{}", FAKE_HANG: "1" }, async () => {
    const t0 = Date.now()
    await expect(sendHc("t1", "line", ID, 300, () => true)).rejects.toThrow("timed out")
    expect(Date.now() - t0).toBeLessThan(3000)
  })
})

test("coreAvailable: scratch HC_SESSION skips the check; else lib/core-up.sh must exit 0", () => {
  const never = () => { throw new Error("core-up must not run") }
  expect(coreAvailable({ HC_SESSION: "scr1" }, never)).toBe(true)
  expect(coreAvailable({}, () => 0)).toBe(true)
  expect(coreAvailable({}, () => 1)).toBe(false)
  expect(coreAvailable({}, never)).toBe(false)
})

test("a core that is down: openHc and sendHc never spawn hc", async () => {
  await withFake({ FAKE_TERMINAL: JSON.stringify(fg(term())) }, async (log) => {
    await expect(openHc(() => false)).rejects.toThrow("not connecting")
    await expect(sendHc("t1", "line", ID, 1000, () => false)).rejects.toThrow("not connecting")
    await Bun.sleep(100)
    expect(log()).toEqual([])
  })
})

test("a send refused by the core guard does not count as an attempt; skipped and real errors do", async () => {
  for (const [err, retried] of [[new NotConnecting("down"), true], [new Error("skipped: changed"), false], [new Error("boom"), false]] as const) {
    let n = 0
    const r = createResumer(async () => { n++; throw err }, undefined, { staggerMs: 0 })
    r.handle(snap(term()))
    await r.settled()
    r.handle(snap(term()))
    await r.settled()
    expect(n).toBe(retried ? 2 : 1)
  }
})

// --- pacing (issue 1033) ---------------------------------------------------------------------

const many = (n: number) => Array.from({ length: n }, (_, i) => term({ address: `t${i}`, labels: { "jk.claude.session": `${i.toString(16).padStart(8, "0")}-aaaa-4bbb-8ccc-dddddddddddd` } }))

test("at most maxInFlight sends are in flight at once and every kept terminal is still resumed", async () => {
  let live = 0, peak = 0
  const sent: string[] = []
  const r = createResumer(async (a) => { live++; peak = Math.max(peak, live); await Bun.sleep(5); sent.push(a); live-- }, undefined, { maxInFlight: 3, staggerMs: 0 })
  r.handle(snap(...many(25)))
  await r.settled()
  expect(peak).toBe(3)
  expect(sent.sort()).toEqual(many(25).map((t) => t.address).sort())
})

test("a start waits for the stagger gap even when a slot is free", async () => {
  const starts: number[] = []
  const r = createResumer(async () => { starts.push(Date.now()) }, undefined, { maxInFlight: 5, staggerMs: 40 })
  r.handle(snap(...many(4)))
  await r.settled()
  expect(starts).toHaveLength(4)
  for (let i = 1; i < starts.length; i++) expect(starts[i] - starts[i - 1]).toBeGreaterThanOrEqual(35)
})

test("nothing starts before the gate opens; a rejecting gate does not block", async () => {
  let open!: () => void
  const sent: string[] = []
  const r = createResumer(async (a) => { sent.push(a) }, undefined, { staggerMs: 0, gate: () => new Promise<void>((res) => { open = res }) })
  r.handle(snap(...many(3)))
  await Bun.sleep(20)
  expect(sent).toEqual([])
  open()
  await r.settled()
  expect(sent).toHaveLength(3)
  const bad = createResumer(async (a) => { sent.push(a) }, undefined, { staggerMs: 0, gate: () => Promise.reject(new Error("x")) })
  bad.handle(snap(term()))
  await bad.settled()
  expect(sent).toHaveLength(4)
})

test("a queued terminal is not queued twice and terminals added while draining are resumed", async () => {
  const sent: string[] = []
  const r = createResumer(async (a) => { sent.push(a); await Bun.sleep(5) }, undefined, { maxInFlight: 1, staggerMs: 0 })
  r.handle(snap(...many(3)))
  r.handle(snap(...many(3))) // reconnect snapshot while the first is still queued
  r.handle(snap(...many(5).slice(3)))
  await r.settled()
  expect(sent.sort()).toEqual(many(5).map((t) => t.address).sort())
})

test("pacing env: defaults, overrides, invalid values fall back", () => {
  expect(pacingFromEnv({})).toEqual({ maxInFlight: DEFAULT_MAX_INFLIGHT, staggerMs: DEFAULT_STAGGER_MS, tailnetWaitMs: 120000 })
  expect(pacingFromEnv({ HC_RESUME_MAX_INFLIGHT: "5", HC_RESUME_STAGGER_MS: "0", HC_RESUME_TAILNET_WAIT_MS: "0" })).toEqual({ maxInFlight: 5, staggerMs: 0, tailnetWaitMs: 0 })
  expect(pacingFromEnv({ HC_RESUME_MAX_INFLIGHT: "0", HC_RESUME_STAGGER_MS: "-1", HC_RESUME_TAILNET_WAIT_MS: "abc" })).toEqual({ maxInFlight: DEFAULT_MAX_INFLIGHT, staggerMs: DEFAULT_STAGGER_MS, tailnetWaitMs: 120000 })
})

test("waitForTailnet: returns when up, on timeout, when disabled, and when the CLI is missing", async () => {
  let n = 0
  await waitForTailnet(async () => ++n >= 3, 1000, 5)
  expect(n).toBe(3)
  const logs: string[] = []
  await waitForTailnet(async () => false, 30, 10, (l) => logs.push(l))
  expect(logs.join()).toContain("resuming anyway")
  let called = false
  await waitForTailnet(async () => { called = true; return false }, 0)
  expect(called).toBe(false)
  await waitForTailnet(async () => { throw new Error("ENOENT") }, 1000, 5)
})

test("tailnetRunning: Running only when the resolved CLI says so; no CLI throws", async () => {
  const dir = mkdtempSync(join(tmpdir(), "tsrun-"))
  try {
    const lib = join(dir, "lib.sh")
    const bin = join(dir, "ts")
    writeFileSync(lib, `TAILSCALE_BIN="$(cat ${dir}/bin)"\nts_run() { "$TAILSCALE_BIN" "$@"; }\n`)
    const use = (state: string | null) => {
      if (state) { writeFileSync(bin, `#!/bin/sh\necho '{"BackendState":"${state}"}'\n`); chmodSync(bin, 0o755) }
      writeFileSync(join(dir, "bin"), state ? bin : "")
    }
    use("Running")
    expect(await tailnetRunning(lib)).toBe(true)
    use("Starting")
    expect(await tailnetRunning(lib)).toBe(false)
    use(null)
    await expect(tailnetRunning(lib)).rejects.toThrow("no tailscale CLI")
  } finally { rmSync(dir, { recursive: true }) }
})

// --- rescan (issue 1367) ---------------------------------------------------------------------

/** A subscribed link that yields the first snapshot and then stays open until closed (a core that never says another word). */
function quietLink(first: Msg): Link {
  let release!: () => void
  const hold = new Promise<void>((r) => { release = r })
  return { messages: (async function* () { yield first; await hold })(), close: () => release() }
}
async function until(cond: () => boolean, ms = 3000) {
  const t0 = Date.now()
  while (!cond() && Date.now() - t0 < ms) await Bun.sleep(5)
}

test("rescan: unknown foregrounds in the only snapshot are resumed by a later read, with no new snapshot or restarted event; every skip is logged once with its reason", async () => {
  const live = { app: "claude-code", state: "done" }
  const label = (id: string) => ({ "jk.claude.session": id })
  // the boot snapshot: t1 foreground null, t2 foreground absent, t3 another program, t4 a login shell with a reporting agent
  const first = { kind: "snapshot", terminals: [
    term({ address: "t1", foreground: null }),
    term({ address: "t2", labels: label(ID2) }),
    term({ address: "t3", foreground: { argv: ["/usr/bin/vim", "x"] } }),
    term({ address: "t4", foreground: { argv: shell }, status: live }),
  ] } satisfies Msg
  let reads = 0
  const roster = (): Terminal[] => {
    reads++
    const known = reads >= 3 // the foreground facts arrive on the third read
    return [
      known ? fg(term({ address: "t1" })) : term({ address: "t1", foreground: null }),
      known ? fg(term({ address: "t2", labels: label(ID2) })) : term({ address: "t2", labels: label(ID2) }),
      term({ address: "t3", foreground: { argv: ["/usr/bin/vim", "x"] } }),
      term({ address: "t4", foreground: { argv: shell }, status: live }),
    ]
  }
  const ac = new AbortController()
  const sent: string[] = []
  const logs: string[] = []
  const done = run({
    open: async () => quietLink(first),
    list: async () => roster(),
    rescan: { fastMs: 5, slowMs: 5, windowMs: 60 },
    send: async (a) => { sent.push(a) },
    log: (l) => logs.push(l),
    pacing: { staggerMs: 0 },
    signal: ac.signal,
  })
  await until(() => sent.length >= 2 && reads >= 12)
  ac.abort()
  await done
  expect(sent.sort()).toEqual(["t1", "t2"])
  for (const l of ["skip t1: foreground unknown", "skip t2: foreground unknown", "skip t3: foreground is vim", "skip t4: live claude-code session (agent status)"]) {
    expect(logs.filter((x) => x === l)).toHaveLength(1)
  }
  expect(logs.filter((x) => x.startsWith("resume t1 ") || x.startsWith("resume t2 "))).toHaveLength(2)
  // t1 and t2 resumed once although every later read still shows the login shell
  expect(logs.filter((x) => x.startsWith("skip t1") || x.startsWith("skip t2"))).toHaveLength(2)
})

test("rescan: after the window it keeps reading while a foreground is unknown and stops once every terminal is running or skipped on purpose", async () => {
  let unknown = true
  let reads = 0
  const roster = (): Terminal[] => {
    reads++
    return [unknown ? term({ address: "t1", foreground: null }) : fg(term({ address: "t1" })), term({ address: "t2", foreground: { argv: ["vim"] } })]
  }
  const ac = new AbortController()
  const sent: string[] = []
  const logs: string[] = []
  const done = run({
    open: async () => quietLink({ kind: "snapshot", terminals: roster() }),
    list: async () => roster(),
    rescan: { fastMs: 5, slowMs: 10, windowMs: 40 },
    send: async (a) => { sent.push(a) },
    log: (l) => logs.push(l),
    pacing: { staggerMs: 0 },
    signal: ac.signal,
  })
  await Bun.sleep(150) // well past the window: t1 is still unknown, so the slow reads continue
  const during = reads
  await Bun.sleep(60)
  expect(reads).toBeGreaterThan(during)
  expect(sent).toEqual([])
  unknown = false
  await until(() => logs.some((l) => l.startsWith("rescan done")))
  expect(sent).toEqual(["t1"])
  const after = reads
  await Bun.sleep(80)
  expect(reads).toBe(after) // settled: no more reads on this connection
  ac.abort()
  await done
})

test("rescan: a failing read is logged once per streak, and the rescan ends with the connection", async () => {
  let reads = 0
  const logs: string[] = []
  const ac = new AbortController()
  const link = quietLink({ kind: "snapshot", terminals: [] })
  const done = run({
    open: async () => link,
    list: async () => { reads++; throw new Error("hc connect exited 2") },
    rescan: { fastMs: 5, slowMs: 5, windowMs: 1000 },
    send: async () => {},
    log: (l) => logs.push(l),
    signal: ac.signal,
  })
  await until(() => reads >= 4)
  expect(logs.filter((l) => l.startsWith("rescan failed"))).toEqual(["rescan failed: hc connect exited 2"])
  ac.abort()
  await done
  const stopped = reads
  await Bun.sleep(40)
  expect(reads).toBe(stopped)
})

test("a login shell whose foreground is claude is running, not a skip: nothing logged, nothing typed", async () => {
  const logs: string[] = []
  const r = createResumer(async () => { throw new Error("must not send") }, (l) => logs.push(l), { staggerMs: 0 })
  r.handle(snap(term({ foreground: { argv: ["/Users/x/.local/share/claude/versions/2.1.0/claude", "--resume", ID] } })))
  await r.settled()
  expect(logs).toEqual([])
  expect(r.outstanding()).toBe(0)
})

test("a skip reason that changes is logged again; a resumed terminal is not logged as skipped afterwards", async () => {
  const logs: string[] = []
  const r = createResumer(async () => {}, (l) => logs.push(l), { staggerMs: 0 })
  r.handle({ kind: "snapshot", terminals: [term({ foreground: null })] })
  r.handle({ kind: "snapshot", terminals: [term({ foreground: null })] })
  r.handle({ kind: "snapshot", terminals: [term({ foreground: { argv: ["/bin/zsh"] } })] })
  expect(r.outstanding()).toBe(0)
  r.handle(snap(term()))
  await r.settled()
  r.handle({ kind: "snapshot", terminals: [term({ foreground: { argv: ["claude"] } })] })
  expect(logs.filter((l) => l.startsWith("skip"))).toEqual(["skip t1: foreground unknown", "skip t1: foreground is zsh, not a login shell"])
})

test("listHc: live kept terminals only; a refused guard never spawns hc", async () => {
  const roster = [fg(term()), { ...fg(term({ address: "t2" })), state: "finished" }, { ...fg(term({ address: "t3" })), keep: false }, { ...fg(term({ address: "t4" })), state: "live", keep: true }]
  await withFake({ FAKE_TERMINAL: "{}", FAKE_TERMINALS: JSON.stringify(roster) }, async (log) => {
    expect((await listHc(5000, () => true)).map((t) => t.address)).toEqual(["t1", "t4"])
    expect(log()).toEqual(["terminal.list"])
  })
  await withFake({ FAKE_TERMINAL: "{}", FAKE_TERMINALS: "[]", FAKE_HANG: "1" }, async () => {
    await expect(listHc(300, () => true)).rejects.toThrow("terminal.list timed out")
  })
  await withFake({ FAKE_TERMINAL: "{}", FAKE_TERMINALS: "[]" }, async (log) => {
    await expect(listHc(1000, () => false)).rejects.toThrow("not connecting")
    expect(log()).toEqual([])
  })
})

// --- non-Claude programs in named tabs (issue 3160) ----------------------------------------------------------------

const BOOT = 1_800_000_000_000
const named = (address: string, where: string, labels: Record<string, string> = {}, over: Partial<Terminal> = {}): Terminal =>
  ({ address, argv: shell, labels: { where, ...labels }, ...over })
const running = (t: Terminal, argv: string[]): Terminal => ({ ...t, foreground: { argv } })
const atShell = (t: Terminal): Terminal => ({ ...t, foreground: { argv: shell } })
const memStore = (initial: Record<string, import("./hc-resume").Program> = {}) => {
  let data = initial
  return { read: () => structuredClone(data), write: (p: Record<string, import("./hc-resume").Program>) => { data = structuredClone(p) }, get: () => data }
}

test("a labelled non-Claude terminal is rerun, an unlabelled one is reported as not restorable (the 2026-11-23 reboot)", async () => {
  const store = memStore()
  const sent: [string, string][] = []
  const logs: string[] = []
  const ac = new AbortController()
  const labelled = named("t4nn", "basalt-ui / plan", { "jk.resume.cmd": "bun run preview" })
  const unlabelled = named("t5aa", "basalt-ui / docs")
  const helper = { address: "t6zz", argv: shell } as Terminal // no space/tab: unnamed helper, lost silently on purpose
  let opens = 0
  const link = (msgs: Msg[]): Link => ({ messages: (async function* () { yield* msgs })(), close() {} })
  const t0 = Date.now()
  const done = run({
    open: async () => {
      opens++
      // before the reboot: both run bun, the helper runs sleep
      if (opens === 1) return link([{ kind: "snapshot", terminals: [running(labelled, ["bun", "run", "preview"]), running(unlabelled, ["/x/bin/bun", "dev"]), running(helper, ["sleep", "9"])] }])
      // after the reboot: all three sit at a fresh login shell
      if (opens === 2) return link([{ kind: "snapshot", terminals: [atShell(labelled), atShell(unlabelled), atShell(helper)] }])
      ac.abort()
      return link([])
    },
    send: async (a, l) => { sent.push([a, l]) },
    log: (l) => logs.push(l),
    backoffMs: [5, 10],
    pacing: { staggerMs: 0 },
    // the program was seen "before the boot" (the clock reads before BOOT while the first snapshot is observed)
    lost: { store, bootedAtMs: BOOT, now: () => (opens < 2 ? BOOT - 1000 : BOOT + 1000) },
    signal: ac.signal,
  })
  await Promise.race([done, Bun.sleep(3000)])
  expect(Date.now() - t0).toBeLessThan(3000)
  expect(sent).toEqual([["t4nn", "bun run preview"]])
  expect(logs).toContain("not restorable: t5aa basalt-ui / docs bun")
  expect(logs.filter((l) => l.startsWith("not restorable"))).toHaveLength(1) // not the labelled one, not the unnamed helper
  expect(logs).toContain("resume t4nn jk.resume.cmd (rerun)")
})

test("jk.resume.cmd: typed once at a login shell, never into a running program, never without the label, never a second command", async () => {
  const label = { "jk.resume.cmd": "make dev" }
  const { sent, r } = harness()
  r.handle({ kind: "snapshot", terminals: [
    atShell(named("t1", "a / b", label)),
    running(named("t2", "a / c", label), ["make", "dev"]),
    atShell(named("t3", "a / d")),
    atShell(named("t4", "a / e", { "jk.resume.cmd": "make dev\nrm -rf ~" })),
    atShell(named("t5", "a / f", { "jk.resume.cmd": "  " })),
  ] })
  await r.settled()
  expect(sent).toEqual([["t1", "make dev"]])
  r.handle({ kind: "snapshot", terminals: [atShell(named("t1", "a / b", label))] })
  await r.settled()
  expect(sent).toHaveLength(1)
  // a Claude session label wins over the command label
  const both = harness()
  both.r.handle(snap(term({ labels: { "jk.claude.session": ID, "jk.resume.cmd": "make dev" } })))
  await both.r.settled()
  expect(both.sent[0][1]).toStartWith("env ")
})

test("sendHc accepts a jk.resume.cmd terminal and refuses one whose label changed", async () => {
  const t = atShell(named("t1", "a / b", { "jk.resume.cmd": "make dev" }))
  await withFake({ FAKE_TERMINAL: JSON.stringify(t) }, async (log) => {
    await sendHc("t1", "make dev", "make dev", 5000, () => true)
    expect(log()).toEqual(["terminal.get", "terminal.send"])
  })
  await withFake({ FAKE_TERMINAL: JSON.stringify(t) }, async (log) => {
    await expect(sendHc("t1", "make other", "make other", 5000, () => true)).rejects.toThrow("no longer carries")
    expect(log()).toEqual(["terminal.get"])
  })
})

test("lost tracker: only a program seen before the boot, in a named tab, is reported once; a program ended after the boot is not", () => {
  const logs: string[] = []
  const store = memStore()
  let clock = BOOT - 5000
  const tr = createLostTracker({ store, bootedAtMs: BOOT, now: () => clock, log: (l) => logs.push(l) })
  const a = named("t1", "basalt-ui / plan"), b = named("t2", "basalt-ui / docs"), c = named("t3", "x / y", { "jk.claude.session": ID })
  tr.handle({ kind: "snapshot", terminals: [running(a, ["/Users/x/.bun/bin/bun", "dev"]), running(b, ["vim"]), running(c, ["claude"])] })
  expect(Object.keys(store.get()).sort()).toEqual(["t1", "t2"])
  expect(store.get().t1).toMatchObject({ where: "basalt-ui / plan", program: "bun" })
  clock = BOOT + 60_000
  // an unknown foreground after the boot keeps the evidence; the login shell that follows reports each program once
  tr.handle({ kind: "snapshot", terminals: [{ ...atShell(a), foreground: null }, running(b, ["vim", "x"])] })
  expect(store.get().t1).toBeDefined()
  tr.handle({ kind: "snapshot", terminals: [atShell(a)] })
  tr.handle({ kind: "snapshot", terminals: [atShell(a), atShell(b)] })
  tr.handle({ kind: "snapshot", terminals: [atShell(a), atShell(b)] })
  expect(logs).toEqual(["not restorable: t1 basalt-ui / plan bun", "not restorable: t2 basalt-ui / docs vim"])
  expect(store.get()).toEqual({})
  // a program that starts and ends after the boot is nobody's loss
  tr.handle({ kind: "snapshot", terminals: [running(a, ["bun", "dev"])] })
  tr.handle({ kind: "snapshot", terminals: [atShell(a)] })
  expect(logs).toHaveLength(2)
})

test("lost tracker: a restarted event reports a known program regardless of the boot time; the store survives a new tracker", () => {
  const logs: string[] = []
  const store = memStore()
  const first = createLostTracker({ store, bootedAtMs: BOOT, now: () => BOOT + 10, log: (l) => logs.push(l) })
  first.handle({ kind: "snapshot", terminals: [running(named("t9", "s / t"), ["node", "srv.js"])] })
  // a new process (hc-resume restarted) reads what the first one stored; seen after the boot, so only the event proves a loss
  const second = createLostTracker({ store, bootedAtMs: BOOT, now: () => BOOT + 20, log: (l) => logs.push(l) })
  second.handle({ kind: "restarted", terminals: [named("t9", "s / t")] })
  expect(logs).toEqual(["not restorable: t9 s / t node"])
})

test("file store round-trips, tolerates a missing or corrupt file; boot time parses", () => {
  const dir = mkdtempSync(join(tmpdir(), "hcprog-"))
  try {
    const store = fileProgramStore(join(dir, "sub", "programs.json"))
    expect(store.read()).toEqual({})
    store.write({ t1: { where: "a / b", program: "bun", seenAt: 5 } })
    expect(store.read()).toEqual({ t1: { where: "a / b", program: "bun", seenAt: 5 } })
    writeFileSync(join(dir, "sub", "programs.json"), "{nope")
    expect(store.read()).toEqual({})
    writeFileSync(join(dir, "sub", "programs.json"), JSON.stringify({ t1: { where: 1 }, t2: { where: "a", program: "p", seenAt: 1 } }))
    expect(Object.keys(store.read())).toEqual(["t2"])
  } finally { rmSync(dir, { recursive: true, force: true }) }
  expect(parseBootTime("{ sec = 1790000000, usec = 123 } Mon Nov 23 2026")).toBe(1790000000_000)
  expect(parseBootTime("")).toBeNull()
})

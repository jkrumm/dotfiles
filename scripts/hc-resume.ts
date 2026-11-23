#!/usr/bin/env bun
// hc-resume — restores Claude sessions into kept herdr-core terminals (replaces classic herdr's
// resume_agents_on_restore). hooks/hc-session-label.ts labels a terminal with jk.claude.session=<id>
// and jk.claude.config=<dir> (absent = the `iu` account). When a kept terminal's program is lost, the
// core replaces it with a login shell; this types `claude --resume <id>` into that shell.
//
// Triggers: its own start (the subscribe snapshot), every reconnect (stream EOF = core restart), a
// `restarted` event, a `missed` snapshot, and the rescan. Rules: one attempt at a time per terminal, at most one
// attempt per (terminal, session id), only into a terminal whose foreground is POSITIVELY a login shell
// (an unknown foreground is skipped and re-evaluated by the next read).
//
// Rescan (issue 1367): after a boot the one subscribe snapshot arrives ~13 s after the core starts, when most terminals'
// foreground is not yet a login shell, and nothing produced a later snapshot: eleven sessions sat at a shell for seven hours.
// So each connection re-reads the roster (`terminal.list`, one short-lived connection) every RESCAN fast interval for the
// first 10 minutes, then every slow interval for as long as a labelled terminal's foreground is still unknown, and
// feeds it through the same rules as a snapshot. Every skip is logged once per terminal with its reason
// (`skip <addr>: <reason>`, the line scripts/recovery-check.sh reads).
//
// Pacing (docs/herdr-core.md §Resume pacing): after a reboot every kept terminal qualifies at once, and 25 `claude --resume`
// started in the same millisecond starved sshd and tailscale for 7 minutes (docs/incident-2026-11-13-mini-panic.md). So at most
// HC_RESUME_MAX_INFLIGHT sends are in flight (default 3) and consecutive starts are HC_RESUME_STAGGER_MS apart (default 3000),
// and the first start waits up to HC_RESUME_TAILNET_WAIT_MS (default 120000, 0 = off) for tailscale to be Running so
// reachability returns first. Pacing changes WHEN, never WHICH terminal or WHICH account.
//
// Never starts a core: `hc connect` STARTS one when none runs, so before every connect (with HC_SESSION
// unset, i.e. the real core) lib/core-up.sh must say a launchd-born core answers; otherwise it counts
// as "no core" and retries with backoff.
// Non-Claude programs (issue 3160): a terminal labelled `jk.resume.cmd=<command>` (set by whatever starts it, e.g. `hc run --label`)
// and sitting at a login shell gets that command typed once, through the same pacing and guards as a Claude resume. Nothing is
// ever typed without that opt-in label. A terminal in a named space/tab (label `where`) with neither label is only OBSERVED: the
// foreground program it runs is kept in a small state file, and when such a terminal is later found at a login shell after a
// reboot (or a `restarted` event) the line `not restorable: <address> <where> <program>` is logged, which recovery-check names.
// Runs under launchd KeepAlive: com.jkrumm.hc-resume.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { splitLines } from "./hc-events"

type Json = Record<string, unknown>
export type Terminal = {
  address: string
  argv?: string[]
  foreground?: { argv?: string[] } | null
  /** Set by a running agent's own hook (`app: "claude-code"`); null on a bare shell. The foreground fact can be stale. */
  status?: { app?: string } | null
  labels?: Record<string, string>
  /** `terminal.list` only: a finished or unkept terminal is never resumed. */
  state?: string
  keep?: boolean
}
/** What a link yields: a full snapshot (subscribe result, `missed`) or one restarted terminal. */
export type Msg = { kind: "snapshot" | "restarted"; terminals: Terminal[] }
export interface Link { messages: AsyncIterable<Msg>; close(): void }

export interface Deps {
  /** Connect and subscribe; rejects when no core runs. */
  open: () => Promise<Link>
  /** Re-reads the roster (`terminal.list`) for the rescan; absent = no rescan. */
  list?: () => Promise<Terminal[]>
  rescan?: Partial<Rescan>
  /** Observes non-Claude programs and reports the ones a reboot lost; absent = off. */
  lost?: { store: ProgramStore; bootedAtMs: number; now?: () => number }
  /** `session` is the id the line was built for: the real adapter re-checks it at send time. `argvFallback` is set only
   *  by a `restarted` trigger: the terminal's own argv may stand in for an ABSENT foreground fact. */
  send: (address: string, text: string, session: string, argvFallback?: boolean) => Promise<void>
  log?: (line: string) => void
  backoffMs?: [number, number]
  pacing?: Partial<Pacing>
  signal?: AbortSignal
}

const SESSION = "jk.claude.session"
const CONFIG = "jk.claude.config"
/** Opt-in label: the command to type into the terminal's shell after its program was lost (a reboot). */
export const RESUME_CMD = "jk.resume.cmd"
/** Set by the app on a terminal in a named space/tab: `<space> / <tab>`. */
const WHERE = "where"
const SHELLS = new Set(["sh", "bash", "zsh", "fish", "dash", "ksh"])

/**
 * The foreground is POSITIVELY a login shell. Only a `restarted` record (`argvFallback`: the core just replaced
 * the program with the terminal's own login shell, the foreground fact is not there yet) may fall back to the
 * terminal's own argv, and only when the foreground key is absent. A snapshot or terminal.get without the
 * foreground fact, or with `foreground: null`, is unknown and never counts: the terminal's own argv says nothing
 * about what runs in it now (a live Claude session sits in a terminal whose argv is `/bin/zsh -l`).
 */
export function isLoginShell(t: Terminal, argvFallback = false): boolean {
  const argv = t.foreground ? t.foreground.argv : argvFallback && t.foreground === undefined ? t.argv : undefined
  if (!argv?.length) return false
  const head = argv[0]
  const name = head.replace(/^-/, "").split("/").pop() ?? ""
  if (!SHELLS.has(name)) return false
  return head.startsWith("-") || argv.slice(1).some((a) => a === "-l" || a === "--login")
}

const quote = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`

/** `--model` / `--effort` from the terminal's own argv, so a resumed session keeps what it ran on. */
export function modelFlags(argv: string[] = []): string[] {
  const out: string[] = []
  for (const flag of ["--model", "--effort"]) {
    for (let i = 0; i < argv.length; i++) {
      const a = argv[i]
      const v = a === flag ? argv[i + 1] : a.startsWith(`${flag}=`) ? a.slice(flag.length + 1) : undefined
      if (v === undefined) continue
      if (/^[\w.\-:[\]]+$/.test(v)) out.push(flag, quote(v))
      break
    }
  }
  return out
}

/** The line typed into the shell; null when the labels carry no usable session id. */
/**
 * A live agent has reported itself through its own hook (`status.app`). Only a `restarted` record, which proves the
 * program ended, may type regardless: a snapshot's or terminal.get's `foreground` can still name the login shell while a
 * Claude runs in it (seen live: the resume line landed in running sessions as a user message).
 */
export function hasLiveAgent(t: Terminal): boolean {
  return Boolean(t.status?.app)
}

/** No repo `.mcp.json` server in a resumed session either (docs/browser.md §Strict MCP). */
export const MCP_FLAGS = ["--strict-mcp-config"]

export function resumeLine(labels: Record<string, string>, argv?: string[]): string | null {
  const id = labels[SESSION]
  if (!id || !/^[0-9a-f-]{8,64}$/i.test(id)) return null
  const dir = labels[CONFIG]
  const env = dir ? `env CLAUDE_CONFIG_DIR=${quote(dir)}` : "env -u CLAUDE_CONFIG_DIR"
  return [env, "claude", "--dangerously-skip-permissions", ...MCP_FLAGS, ...modelFlags(argv), "--resume", id].join(" ")
}

/** The opt-in command as a line to type; null when it is empty, too long or carries a control character (a second command). */
export function rerunLine(cmd: string): string | null {
  // eslint-disable-next-line no-control-regex
  return /^[^\x00-\x1f\x7f]{1,1000}$/.test(cmd) && cmd.trim() ? cmd : null
}

export const DEFAULT_MAX_INFLIGHT = 3
export const DEFAULT_STAGGER_MS = 3000
export const DEFAULT_TAILNET_WAIT_MS = 120000

export interface Rescan {
  /** Between reads during the window after a connection opens. */
  fastMs: number
  /** Between reads after the window, while a labelled terminal's foreground is still unknown. */
  slowMs: number
  /** How long the fast reads last whatever the roster looks like. */
  windowMs: number
}
export const DEFAULT_RESCAN: Rescan = { fastMs: 15000, slowMs: 60000, windowMs: 600000 }

export interface Pacing {
  /** Sends in flight at once (>= 1). */
  maxInFlight: number
  /** Minimum gap between two send starts. */
  staggerMs: number
  /** Awaited once before the first start; a rejection is ignored (never blocks the resume for good). */
  gate?: () => Promise<void>
}

/** Pacing from the environment; a missing or invalid value falls back to the default. */
export function pacingFromEnv(env: Record<string, string | undefined> = process.env): Pick<Pacing, "maxInFlight" | "staggerMs"> & { tailnetWaitMs: number } {
  const num = (v: string | undefined, d: number, min: number) => { const n = Number(v); return v !== undefined && v.trim() !== "" && Number.isInteger(n) && n >= min ? n : d }
  return {
    maxInFlight: num(env.HC_RESUME_MAX_INFLIGHT, DEFAULT_MAX_INFLIGHT, 1),
    staggerMs: num(env.HC_RESUME_STAGGER_MS, DEFAULT_STAGGER_MS, 0),
    tailnetWaitMs: num(env.HC_RESUME_TAILNET_WAIT_MS, DEFAULT_TAILNET_WAIT_MS, 0),
  }
}

const delay = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

/**
 * Resolves when `up()` says so, or after `timeoutMs` (resume goes ahead without the tailnet: a slow tailnet must not
 * keep sessions down). `up` throwing (no tailscale binary) also resolves at once: nothing to wait for.
 */
export async function waitForTailnet(up: () => Promise<boolean>, timeoutMs: number, intervalMs = 2000, log: (l: string) => void = () => {}): Promise<void> {
  if (timeoutMs <= 0) return
  const t0 = Date.now()
  for (;;) {
    try { if (await up()) { log(`tailnet up after ${Date.now() - t0} ms`); return } } catch { return }
    if (Date.now() - t0 + intervalMs > timeoutMs) { log(`tailnet not up after ${timeoutMs} ms: resuming anyway`); return }
    await delay(intervalMs)
  }
}

/**
 * `tailscale status --json` says BackendState Running, asked of the daemon scripts/lib/tailscale-cli.sh picks (the mini's
 * brew tailscaled on its explicit socket: a bare `tailscale` can reach the dormant app-bundle daemon and answer wrongly).
 * Throws when this machine has no tailscale CLI.
 */
export async function tailnetRunning(lib = join(import.meta.dir, "lib", "tailscale-cli.sh")): Promise<boolean> {
  const proc = Bun.spawn(["bash", "-c", 'source "$1"; [ -n "$TAILSCALE_BIN" ] || exit 127; ts_run status --json', "_", lib], { stdin: "ignore", stdout: "pipe", stderr: "ignore" })
  const timer = setTimeout(() => proc.kill(), 5000)
  try {
    const out = await new Response(proc.stdout).text()
    if ((await proc.exited) === 127) throw new Error("no tailscale CLI")
    return (JSON.parse(out) as Json).BackendState === "Running"
  } catch (e) {
    if ((e as Error).message === "no tailscale CLI") throw e
    return false
  } finally { clearTimeout(timer) }
}

// --- non-Claude programs: observe, report what a reboot lost --------------------------------------------------------

export type Program = { where: string; program: string; seenAt: number }
/** The programs seen running in unlabelled terminals of a named space/tab, by address. Survives a reboot. */
export interface ProgramStore { read(): Record<string, Program>; write(programs: Record<string, Program>): void }

/** A JSON file written atomically; a missing or unreadable file reads as empty (nothing observed yet). */
export function fileProgramStore(path: string): ProgramStore {
  return {
    read() {
      try {
        const o = JSON.parse(readFileSync(path, "utf8")) as Record<string, Partial<Program>>
        return Object.fromEntries(Object.entries(o).filter(([, p]) => typeof p?.where === "string" && typeof p.program === "string" && typeof p.seenAt === "number")) as Record<string, Program>
      } catch { return {} }
    },
    write(programs) {
      mkdirSync(dirname(path), { recursive: true })
      writeFileSync(`${path}.tmp`, JSON.stringify(programs))
      renameSync(`${path}.tmp`, path)
    },
  }
}

/** Seconds-since-epoch of the boot from `sysctl -n kern.boottime` (`{ sec = 1790000000, usec = 0 } ...`), in ms; null when unreadable. */
export function parseBootTime(out: string): number | null {
  const m = /sec\s*=\s*(\d+)/.exec(out)
  return m ? Number(m[1]) * 1000 : null
}

/** The foreground program's name when it is a known non-shell program; null for a shell or an unknown foreground. */
function programName(t: Terminal): string | null {
  const head = t.foreground?.argv?.[0]
  if (!head) return null
  const name = head.replace(/^-/, "").split("/").pop() || head
  return SHELLS.has(name) ? null : name.replace(/\s+/g, "_")
}

const PROGRAM_MAX_AGE_MS = 14 * 86400_000

/**
 * Keeps the last non-shell program of every unlabelled terminal in a named space/tab, and says so (`not restorable: ...`) when
 * such a terminal turns up at a login shell although the program was seen BEFORE this boot, or a `restarted` event says the core
 * replaced it. A program that ended after the boot is the user's doing and is dropped silently. Only logs and stores: never types.
 */
export function createLostTracker(o: { store: ProgramStore; bootedAtMs: number; now?: () => number; log?: (l: string) => void }) {
  const now = o.now ?? Date.now
  const log = o.log ?? (() => {})
  let programs = o.store.read()
  return {
    handle(m: Msg): void {
      const before = JSON.stringify(programs)
      for (const [a, p] of Object.entries(programs)) if (now() - p.seenAt > PROGRAM_MAX_AGE_MS) delete programs[a]
      for (const t of m.terminals) {
        const a = t.address
        const labels = t.labels ?? {}
        const where = (labels[WHERE] ?? "").trim()
        if ((t.state && t.state !== "live") || t.keep === false || labels[SESSION] || labels[RESUME_CMD] || !where) { delete programs[a]; continue }
        const restarted = m.kind === "restarted"
        if (!restarted && hasLiveAgent(t)) continue
        const prev = programs[a]
        if (isLoginShell(t, restarted)) {
          if (prev && (restarted || prev.seenAt < o.bootedAtMs)) log(`not restorable: ${a} ${prev.where} ${prev.program}`)
          delete programs[a]
          continue
        }
        const program = programName(t)
        if (!program) continue
        programs[a] = prev && prev.program === program && prev.where === where ? prev : { where, program, seenAt: now() }
      }
      if (JSON.stringify(programs) !== before) o.store.write(programs)
    },
  }
}

export function createResumer(send: Deps["send"], log: (l: string) => void = () => {}, pacing: Partial<Pacing> = {}) {
  const maxInFlight = Math.max(1, pacing.maxInFlight ?? DEFAULT_MAX_INFLIGHT)
  const staggerMs = Math.max(0, pacing.staggerMs ?? DEFAULT_STAGGER_MS)
  const inflight = new Set<string>() // queued or sending: one attempt at a time per terminal
  const attempted = new Map<string, string>() // address -> session id last tried
  const pending = new Set<Promise<void>>() // sends running now (at most maxInFlight)
  type Job = { address: string; line: string; id: string; shown: string; account: string; argvFallback: boolean }
  const queue: Job[] = []
  const skipLogged = new Map<string, string>() // address -> the skip reason last logged: a skip is logged once
  const unsettled = new Set<string>() // labelled, foreground unknown: not a deliberate skip, the rescan keeps reading
  let pump: Promise<void> | null = null
  let lastStart = 0
  let gated = !pacing.gate

  function start(j: Job): void {
    const p = send(j.address, j.line, j.id, j.argvFallback)
      .then(() => log(`resume ${j.address} ${j.shown} (${j.account})`))
      .catch((e) => {
        // Nothing was typed: let the next snapshot try again. "skipped" and real send errors keep the attempt.
        if (e instanceof RetryLater && attempted.get(j.address) === j.id) attempted.delete(j.address)
        log(`resume ${j.address} failed: ${(e as Error).message}`)
      })
      .finally(() => { inflight.delete(j.address); pending.delete(p) })
    pending.add(p)
  }

  /** Starts queued jobs: never more than maxInFlight at once, consecutive starts staggerMs apart, the first after the gate. */
  async function drain(): Promise<void> {
    if (!gated) { try { await pacing.gate!() } catch { /* never block the resume for good */ } gated = true }
    while (queue.length) {
      if (pending.size >= maxInFlight) { await Promise.race(pending); continue }
      const wait = lastStart + staggerMs - Date.now()
      if (wait > 0) { await delay(wait); continue }
      lastStart = Date.now()
      start(queue.shift()!)
    }
  }

  type Skip = { reason: string; unknown: boolean }
  /** Why this terminal is not typed into, or null when it qualifies. A claude foreground is the goal state, not a skip. */
  function skipOf(t: Terminal, argvFallback: boolean, anyProgramRuns: boolean): Skip | "running" | null {
    if (!isLoginShell(t, argvFallback)) {
      const head = t.foreground?.argv?.[0]
      if (!head) return { reason: "foreground unknown", unknown: true }
      const name = head.replace(/^-/, "").split("/").pop() || head
      if (name === "claude" || (anyProgramRuns && !SHELLS.has(name))) return "running"
      return { reason: SHELLS.has(name) ? `foreground is ${name}, not a login shell` : `foreground is ${name}`, unknown: false }
    }
    if (!argvFallback && hasLiveAgent(t)) return { reason: `live ${t.status?.app} session (agent status)`, unknown: false }
    return null
  }

  function noteSkip(address: string, s: Skip): void {
    if (s.unknown) unsettled.add(address); else unsettled.delete(address)
    if (skipLogged.get(address) === s.reason) return
    skipLogged.set(address, s.reason)
    log(`skip ${address}: ${s.reason}`)
  }

  function consider(t: Terminal, argvFallback: boolean): void {
    const labels = t.labels ?? {}
    const sessionId = labels[SESSION]
    const rerun = sessionId ? undefined : labels[RESUME_CMD]
    const id = sessionId || rerun
    if (!id) return
    if (inflight.has(t.address) || attempted.get(t.address) === id) return
    const skip = skipOf(t, argvFallback, rerun !== undefined)
    if (skip === "running") {
      unsettled.delete(t.address); skipLogged.delete(t.address)
      // an opt-in command seen running counts as done: a program the owner stops later is not retyped, only a `restarted` loss is
      if (rerun !== undefined) attempted.set(t.address, id)
      return
    }
    if (skip) { noteSkip(t.address, skip); return }
    const line = rerun !== undefined ? rerunLine(rerun) : resumeLine(labels, t.argv)
    if (!line) { noteSkip(t.address, { reason: rerun !== undefined ? `unusable ${RESUME_CMD} label` : "unusable session label", unknown: false }); return }
    unsettled.delete(t.address)
    skipLogged.delete(t.address)
    inflight.add(t.address)
    attempted.set(t.address, id)
    queue.push({ address: t.address, line, id, shown: rerun !== undefined ? RESUME_CMD : id, account: rerun !== undefined ? "rerun" : labels[CONFIG] || "iu", argvFallback })
    kick()
  }

  function kick(): void {
    pump ??= drain().finally(() => { pump = null; if (queue.length) kick() })
  }

  return {
    handle(m: Msg): void {
      if (m.kind === "snapshot") {
        const gone = (a: string) => !m.terminals.some((t) => t.address === a)
        for (const a of attempted.keys()) if (gone(a)) attempted.delete(a)
        for (const a of unsettled) if (gone(a)) unsettled.delete(a)
        for (const a of skipLogged.keys()) if (gone(a)) skipLogged.delete(a)
      }
      // A `restarted` event is a new loss: the previous attempt (if any) is history.
      for (const t of m.terminals) {
        if (m.kind === "restarted") attempted.delete(t.address)
        consider(t, m.kind === "restarted")
      }
    },
    /** Terminals still to be settled: queued or sending, or labelled with a foreground nobody has seen yet. */
    outstanding(): number { return inflight.size + unsettled.size },
    /** Resolves when every queued send has started and finished. */
    async settled(): Promise<void> { while (pump || pending.size) await Promise.all([pump, ...pending]) },
  }
}

export async function run(deps: Deps): Promise<void> {
  const log = deps.log ?? (() => {})
  const [minB, maxB] = deps.backoffMs ?? [1000, 30000]
  const resumer = createResumer(deps.send, log, deps.pacing)
  const lost = deps.lost ? createLostTracker({ ...deps.lost, log }) : null
  const handle = (m: Msg) => { resumer.handle(m); lost?.handle(m) }
  const rescan: Rescan = { ...DEFAULT_RESCAN, ...deps.rescan }
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
  let backoff = minB
  const onAbort = () => link?.close()
  let link: Link | undefined
  deps.signal?.addEventListener("abort", onAbort)

  /** The rescan of one connection: fast for the window, then slow while anything is unsettled; ends with the connection. */
  async function watch(stop: AbortSignal): Promise<void> {
    const t0 = Date.now()
    let failed = false
    let told = false
    while (!stop.aborted) {
      const age = Date.now() - t0
      const settled = age >= rescan.windowMs && resumer.outstanding() === 0
      if (settled && !lost) { log(`rescan done after ${Math.round(age / 1000)} s: every resumable terminal is running or skipped on purpose`); return }
      if (settled && !told) { told = true; log(`resume rescan done after ${Math.round(age / 1000)} s: every resumable terminal is running or skipped on purpose; still observing programs`) }
      await new Promise<void>((resolve) => {
        const timer = setTimeout(done, age < rescan.windowMs ? rescan.fastMs : rescan.slowMs)
        function done() { clearTimeout(timer); stop.removeEventListener("abort", done); resolve() }
        stop.addEventListener("abort", done)
      })
      if (stop.aborted) return
      try {
        const terminals = await deps.list!()
        if (stop.aborted) return
        failed = false
        // once the resume work is settled only the program observer reads on: the resumer keeps its own pace
        if (settled) lost?.handle({ kind: "snapshot", terminals }); else handle({ kind: "snapshot", terminals })
      } catch (e) {
        if (!failed) log(`rescan failed: ${(e as Error).message}`)
        failed = true
      }
    }
  }

  while (!deps.signal?.aborted) {
    let got = false
    try {
      link = await deps.open()
      const stop = new AbortController()
      if (deps.list) void watch(stop.signal)
      try { for await (const m of link.messages) { got = true; handle(m) } } finally { stop.abort() }
      log(got ? "stream ended (core restart?), reconnecting" : "stream ended with no data")
    } catch (e) {
      log(`no core: ${(e as Error).message}`)
    }
    backoff = got ? minB : Math.min(backoff * 2, maxB)
    if (!deps.signal?.aborted) await sleep(backoff)
  }
  await resumer.settled()
}

// --- real hc adapter ---------------------------------------------------------------------------

/** Parse one `hc connect` line (seq filter state kept by the caller); null for anything not a trigger. */
export function parseLine(line: string, minSeq: { n: number }): Msg | null {
  let o: Json
  try { o = JSON.parse(line) } catch { return null }
  const params = (o.params ?? {}) as Json
  const result = o.result as Json | undefined
  if (result && Array.isArray(result.terminals)) { minSeq.n = Number(result.seq ?? 0); return { kind: "snapshot", terminals: result.terminals as Terminal[] } }
  if (o.method === "missed" && Array.isArray(params.terminals)) { minSeq.n = Number(params.seq ?? 0); return { kind: "snapshot", terminals: params.terminals as Terminal[] } }
  if (o.method === "event" && params.type === "restarted" && Number(params.seq) > minSeq.n) return { kind: "restarted", terminals: [params.data as Terminal] }
  return null
}

export function isSubscribeError(line: string): boolean {
  try { const o = JSON.parse(line) as Json; return o.id === 1 && o.error !== undefined } catch { return false }
}

/** Nothing was typed and the terminal may qualify later: the attempt does not count. */
export class RetryLater extends Error {}
/** The core guard refused before anything was typed. */
export class NotConnecting extends RetryLater {}

/** True when it is safe to `hc connect`: a scratch HC_SESSION, or lib/core-up.sh says a launchd-born core answers. */
export function coreAvailable(
  env: Record<string, string | undefined> = process.env,
  coreUp: () => number = () => Bun.spawnSync(["bash", join(import.meta.dir, "lib", "core-up.sh")], { stdout: "ignore", stderr: "ignore" }).exitCode ?? 1
): boolean {
  if (env.HC_SESSION) return true
  try { return coreUp() === 0 } catch { return false }
}

function spawnConnect(guard: () => boolean) {
  if (!guard()) throw new NotConnecting("no launchd-born core answers (scripts/lib/core-up.sh): not connecting (hc would start a core)")
  return Bun.spawn([process.env.HC_BIN || "hc", "connect"], { stdin: "pipe", stdout: "pipe", stderr: "ignore", env: process.env })
}

async function* lines(stream: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const decoder = new TextDecoder()
  let buf = ""
  for await (const chunk of stream) {
    const out: string[] = []
    buf = splitLines(buf + decoder.decode(chunk, { stream: true }), (l) => out.push(l))
    yield* out
  }
}

export async function openHc(guard: () => boolean = coreAvailable): Promise<Link> {
  const proc = spawnConnect(guard)
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "events.subscribe", params: {} }) + "\n")
  proc.stdin.flush()
  const minSeq = { n: 0 }
  async function* messages(): AsyncGenerator<Msg> {
    for await (const l of lines(proc.stdout)) {
      // A rejected subscription would leave the link open and deaf: end it so `run` reconnects with backoff.
      if (isSubscribeError(l)) { proc.kill(); return }
      const m = parseLine(l, minSeq)
      if (m) yield m
    }
  }
  return { messages: messages(), close: () => { proc.kill() } }
}

export const SEND_DEADLINE_MS = 15000

/** One request/response on a connection; the lines iterator is shared so the next call continues the stream. */
async function call(proc: ReturnType<typeof Bun.spawn>, it: AsyncGenerator<string>, id: number, method: string, params: Json): Promise<Json> {
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n")
  proc.stdin.flush()
  for (;;) {
    const { value, done } = await it.next()
    if (done) throw new Error("connection closed before the request was answered")
    let o: Json
    try { o = JSON.parse(value) } catch { continue }
    if (o.id !== id) continue
    if (o.error) throw new Error(JSON.stringify(o.error).slice(0, 300))
    return (o.result ?? {}) as Json
  }
}

/** One short-lived connection with a hard deadline: the connect process is killed and the call rejects when it passes. */
async function withHc<T>(what: string, deadlineMs: number, guard: () => boolean, fn: (rpc: (id: number, method: string, params: Json) => Promise<Json>) => Promise<T>): Promise<T> {
  const proc = spawnConnect(guard)
  let timedOut = false
  const timer = setTimeout(() => { timedOut = true; proc.kill() }, deadlineMs)
  try {
    const it = lines(proc.stdout)
    return await fn((id, method, params) => call(proc, it, id, method, params))
  } catch (e) {
    if (timedOut) throw new Error(`${what} timed out after ${deadlineMs} ms`)
    throw e
  } finally {
    clearTimeout(timer)
    proc.kill()
  }
}

/**
 * Re-read the terminal on a short-lived connection and send only if its foreground is positively a login shell carrying
 * the same session label (the subscribed connection answers no requests). A hard deadline kills the
 * connect process and rejects, so the caller's `inflight` always clears.
 */
export async function sendHc(address: string, text: string, session: string, deadlineMs = SEND_DEADLINE_MS, guard: () => boolean = coreAvailable, argvFallback = false): Promise<void> {
  await withHc(`send to ${address}`, deadlineMs, guard, async (rpc) => {
    const t = (await rpc(3, "terminal.get", { terminal: address })) as unknown as Terminal
    if (t.labels?.[SESSION] !== session && t.labels?.[RESUME_CMD] !== session) throw new Error(`skipped: ${address} no longer carries session ${session}`)
    // Unknown foreground (null, or absent without the `restarted` fallback) is never typed into: a later snapshot decides.
    if (t.foreground === null || (t.foreground === undefined && !argvFallback)) throw new RetryLater(`foreground of ${address} unknown: not typing, a later snapshot decides`)
    if (!argvFallback && hasLiveAgent(t)) throw new Error(`skipped: ${address} runs a live ${t.status?.app} session`)
    if (!isLoginShell(t, argvFallback)) throw new Error(`skipped: ${address} is no longer at a login shell`)
    await rpc(2, "terminal.send", { terminal: address, text, caller: "hc-resume" })
  })
}

/** The roster for the rescan: live, kept terminals (a finished or unkept one is never resumed). */
export async function listHc(deadlineMs = SEND_DEADLINE_MS, guard: () => boolean = coreAvailable): Promise<Terminal[]> {
  return withHc("terminal.list", deadlineMs, guard, async (rpc) => {
    const r = await rpc(4, "terminal.list", {})
    if (!Array.isArray(r.terminals)) throw new Error("terminal.list answered without a terminals array")
    return (r.terminals as Terminal[]).filter((t) => (t.state ?? "live") === "live" && t.keep !== false)
  })
}

if (import.meta.main) {
  const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`)
  const ac = new AbortController()
  for (const sig of ["SIGTERM", "SIGINT"] as const) process.on(sig, () => { ac.abort(); setTimeout(() => process.exit(0), 200) })
  log(`hc-resume started pid=${process.pid}`)
  const { tailnetWaitMs, ...pace } = pacingFromEnv()
  log(`pacing: max ${pace.maxInFlight} in flight, ${pace.staggerMs} ms apart, tailnet wait ${tailnetWaitMs} ms; rescan ${DEFAULT_RESCAN.fastMs} ms for ${DEFAULT_RESCAN.windowMs} ms, then ${DEFAULT_RESCAN.slowMs} ms while a foreground is unknown`)
  const gate = () => waitForTailnet(tailnetRunning, tailnetWaitMs, 2000, log)
  const booted = parseBootTime(Bun.spawnSync(["/usr/sbin/sysctl", "-n", "kern.boottime"], { stdout: "pipe", stderr: "ignore" }).stdout.toString())
  const statePath = process.env.HC_RESUME_STATE || join(process.env.HOME ?? "", ".local/state/hc-resume/programs.json")
  // Without a boot time nothing can be told apart from a program that simply ended: the observer stays off.
  const lost = booted === null ? undefined : { store: fileProgramStore(statePath), bootedAtMs: booted }
  log(`program observer: ${lost ? `on, state ${statePath}` : "off (boot time unreadable)"}`)
  await run({ open: openHc, list: () => listHc(), lost, pacing: { ...pace, gate }, send: (a, t, s, fb) => sendHc(a, t, s, SEND_DEADLINE_MS, coreAvailable, fb), log, signal: ac.signal })
}

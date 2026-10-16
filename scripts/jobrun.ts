#!/usr/bin/env bun
// jobrun — run a command as a recorded background job (ops-signals.md §3 T0, background-jobs.md §Pattern).
//
//   jobrun <label> --owner <repo> [--every s] [--timeout s] [--lock name] [--kuma op-ref] -- <cmd...>
//
// Prefixes every output line with a timestamp, enforces the deadline (TERM, then KILL), takes an
// optional cross-label lock, writes ~/.local/state/jobs/<label>.json atomically, and pushes Kuma
// (only when --kuma is given, only on rc=0) with the URL resolved through `secrets-run`.
// The state file is read by scripts/lib/jobs-grade.ts — the only grading logic.
import { spawn, spawnSync } from "node:child_process"
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync, writeSync } from "node:fs"
import { homedir, constants as osConstants } from "node:os"
import { dirname, join } from "node:path"
import { type JobState, defaultStateDir } from "./lib/jobs-grade.ts"

const TAIL_LINES = 40
const RUN_HISTORY = 5
const DAY_MS = 86_400_000
const KILL_GRACE_MS = 10_000
const MAX_FAIL_TIMES = 100
const DRAIN_MS = 2_000

export interface Args {
  label: string
  owner: string
  every: number | null
  timeout: number | null
  lock: string | null
  kuma: string | null
  cmd: string[]
}

export function parseArgs(argv: string[]): Args {
  const dd = argv.indexOf("--")
  if (dd < 0 || dd === argv.length - 1) throw new Error("usage: jobrun <label> --owner <repo> [...] -- <cmd...>")
  const head = argv.slice(0, dd)
  const cmd = argv.slice(dd + 1)
  const label = head[0]
  if (!label || label.startsWith("--")) throw new Error("missing <label>")
  if (!/^[A-Za-z0-9._-]+$/.test(label)) throw new Error(`bad label '${label}'`)
  const known = new Set(["--owner", "--every", "--timeout", "--lock", "--kuma"])
  for (const t of head.slice(1)) if (t.startsWith("--") && !known.has(t)) throw new Error(`unknown option '${t}'`)
  const opt = (name: string): string | null => {
    const i = head.indexOf(name, 1)
    if (i < 0) return null
    const v = head[i + 1]
    if (v === undefined || v.startsWith("--")) throw new Error(`${name} needs a value`)
    return v
  }
  const num = (name: string): number | null => {
    const v = opt(name)
    if (v === null) return null
    const n = Number(v)
    if (!Number.isFinite(n) || n <= 0) throw new Error(`${name} must be a positive number`)
    return n
  }
  const owner = opt("--owner")
  if (!owner) throw new Error("--owner is required")
  if (!/^[A-Za-z0-9._-]+$/.test(owner)) throw new Error(`bad owner '${owner}'`)
  return { label, owner, every: num("--every"), timeout: num("--timeout"), lock: opt("--lock"), kuma: opt("--kuma"), cmd }
}

export function writeAtomic(path: string, data: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const tmp = `${path}.${process.pid}.tmp`
  const fd = openSync(tmp, "w")
  try {
    writeSync(fd, data)
    fsyncSync(fd) // a power cut after the rename must not leave a zero-length state file
  } finally {
    closeSync(fd)
  }
  renameSync(tmp, path)
}

const LOCK_NAME = /^[A-Za-z0-9._-]+$/

/** Process start time, the pid-reuse guard: after a reboot a recorded pid can belong to a stranger. */
function startTime(pid: number): string | null {
  const r = spawnSync("/bin/ps", ["-o", "lstart=", "-p", String(pid)], { encoding: "utf8" })
  return r.status === 0 ? r.stdout.trim() || null : null
}

function readHolder(lockDir: string): string | null {
  try {
    return readFileSync(join(lockDir, "holder.json"), "utf8")
  } catch {
    return null
  }
}

function holderAlive(lockDir: string): boolean {
  let info: { pid?: number; lstart?: string | null }
  try {
    info = JSON.parse(readFileSync(join(lockDir, "holder.json"), "utf8"))
  } catch {
    return false // no complete holder record: the lock is only ever published whole, so this is debris
  }
  if (!info.pid) return false
  try {
    process.kill(info.pid, 0)
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ESRCH") return false // verifiably gone
  }
  const now = startTime(info.pid)
  // Unknown (ps failed, or no start time was recorded) counts as held: never steal on a doubt.
  if (now === null || !info.lstart) return true
  return now === info.lstart
}

/**
 * Cross-label lock. The lock dir is published whole (holder.json written in a temp dir, then
 * renamed into place), so a contender never sees a half-made lock. A stale lock (holder dead, or
 * its pid reused by another process) is renamed aside before removal so two contenders cannot
 * both delete a fresh lock. Returns a release fn, or null when the lock is held; anything other
 * than "already exists" throws, so a read-only state dir is an error and not a silent skip.
 */
export function acquireLock(dir: string, name: string): (() => void) | null {
  if (!LOCK_NAME.test(name) || name === "." || name === "..") throw new Error(`bad lock name '${name}'`)
  const locks = join(dir, "locks")
  const lockDir = join(locks, name)
  mkdirSync(locks, { recursive: true })
  const mine = JSON.stringify({ pid: process.pid, lstart: startTime(process.pid) })
  for (let attempt = 0; attempt < 3; attempt++) {
    const tmp = join(locks, `.${name}.${process.pid}.${attempt}.tmp`)
    rmSync(tmp, { recursive: true, force: true })
    mkdirSync(tmp)
    writeFileSync(join(tmp, "holder.json"), mine)
    try {
      renameSync(tmp, lockDir)
      return () => {
        try {
          if (readFileSync(join(lockDir, "holder.json"), "utf8") === mine) rmSync(lockDir, { recursive: true, force: true })
        } catch {}
      }
    } catch (e) {
      rmSync(tmp, { recursive: true, force: true })
      const code = (e as NodeJS.ErrnoException).code
      if (code !== "EEXIST" && code !== "ENOTEMPTY") throw e
    }
    if (holderAlive(lockDir)) return null
    const judged = readHolder(lockDir)
    const aside = join(locks, `.${name}.stale.${process.pid}.${attempt}`)
    try {
      renameSync(lockDir, aside) // only one contender wins this rename
    } catch {
      continue // someone else already moved it
    }
    // Check-then-act: the dir we moved may be a fresh lock another contender published after
    // we judged the old one stale. Only discard it if it is still the record we judged.
    if (readHolder(aside) !== judged) {
      try {
        renameSync(aside, lockDir)
      } catch {
        rmSync(aside, { recursive: true, force: true })
      }
      return null
    }
    rmSync(aside, { recursive: true, force: true })
  }
  throw new Error(`lock '${name}' could not be acquired or cleared (contention or undeletable debris)`)
}

function ownerSha(owner: string): string | null {
  const root = process.env.JOBRUN_SOURCEROOT || join(homedir(), "SourceRoot")
  const dir = join(root, owner)
  if (!existsSync(dir)) return null
  const r = spawnSync("git", ["-C", dir, "rev-parse", "HEAD"], { encoding: "utf8", timeout: 10_000 })
  return r.status === 0 ? r.stdout.trim() : null
}

export interface RunResult {
  run_id: string
  started: number
  finished: number
  rc: number
  tail: string[]
  sha: string | null
  /** jobrun itself was told to stop (launchd unload, reboot): not the job's fault, so not a failure. */
  interrupted?: boolean
}

export function nextState(prev: JobState | null, args: Args, run: RunResult): JobState {
  const iso = (ms: number) => new Date(ms).toISOString()
  const failed = run.rc !== 0 && !run.interrupted
  const durationMs = run.finished - run.started
  const failTimes = [...(prev?.fail_times ?? []), ...(failed ? [iso(run.finished)] : [])]
    .filter((t) => run.finished - Date.parse(t) < DAY_MS)
    .slice(-MAX_FAIL_TIMES)
  const entry = { run_id: run.run_id, started: iso(run.started), rc: run.rc, duration_ms: durationMs }
  return {
    label: args.label,
    run_id: run.run_id,
    started: iso(run.started),
    finished: iso(run.finished),
    rc: run.rc,
    duration_ms: durationMs,
    every: args.every,
    owner: args.owner,
    owner_sha: run.sha,
    last_ok: run.rc === 0 ? iso(run.finished) : (prev?.last_ok ?? null),
    consecutive_fail: run.rc === 0 ? 0 : (prev?.consecutive_fail ?? 0) + (failed ? 1 : 0),
    fails_24h: failTimes.length,
    fail_times: failTimes,
    tail: run.tail,
    runs: [...(prev?.runs ?? []), entry].slice(-RUN_HISTORY),
  }
}

function readPrev(path: string): JobState | null {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as JobState
  } catch {
    return null
  }
}

const stamp = () => new Date().toISOString()

/** Runs the command in its own process group; resolves with the exit code (124 timeout, 128+n signal). */
export function runCommand(cmd: string[], timeoutS: number | null, onLine: (l: string) => void): Promise<{ rc: number; interrupted: boolean }> {
  return new Promise((resolve) => {
    const child = spawn(cmd[0], cmd.slice(1), { detached: true, stdio: ["ignore", "pipe", "pipe"] })
    let timedOut = false
    let interrupted = false
    let settled = false
    let killTimer: ReturnType<typeof setTimeout> | undefined
    const group = (sig: NodeJS.Signals) => {
      try {
        if (child.pid) process.kill(-child.pid, sig)
      } catch {}
    }
    const terminate = () => {
      group("SIGTERM")
      killTimer = setTimeout(() => group("SIGKILL"), KILL_GRACE_MS)
    }
    const deadline = timeoutS
      ? setTimeout(() => {
          timedOut = true
          terminate()
        }, timeoutS * 1000)
      : undefined
    const forward = () => {
      interrupted = true
      terminate()
    }
    process.on("SIGTERM", forward)
    process.on("SIGINT", forward)

    for (const stream of [child.stdout, child.stderr]) {
      let buf = ""
      stream.setEncoding("utf8")
      stream.on("data", (chunk: string) => {
        buf += chunk
        let i: number
        while ((i = buf.indexOf("\n")) >= 0) {
          onLine(buf.slice(0, i))
          buf = buf.slice(i + 1)
        }
      })
      stream.on("end", () => buf && onLine(buf))
    }
    const finish = (rc: number) => {
      if (settled) return
      settled = true
      clearTimeout(deadline)
      clearTimeout(killTimer)
      process.off("SIGTERM", forward)
      process.off("SIGINT", forward)
      group("SIGKILL") // reap stragglers the job left in its group
      resolve({ rc: timedOut ? 124 : rc, interrupted })
    }
    child.on("error", (e) => {
      onLine(`jobrun: cannot start '${cmd[0]}': ${e.message}`)
      finish(127)
    })
    const exitCode = (code: number | null, sig: NodeJS.Signals | null) => code ?? (sig ? 128 + (osConstants.signals[sig] ?? 0) : 1)
    // A grandchild that outlives the command can hold the pipes open forever: finish on exit,
    // after a bounded drain, rather than waiting for EOF.
    child.on("exit", (code, sig) => setTimeout(() => finish(exitCode(code, sig)), DRAIN_MS).unref())
    child.on("close", (code, sig) => finish(exitCode(code, sig)))
  })
}

async function pushKuma(ref: string, label: string): Promise<void> {
  const secretsRun = process.env.JOBRUN_SECRETS_RUN || "secrets-run"
  const r = spawnSync(secretsRun, ["read", ref], { encoding: "utf8", timeout: 20_000 })
  const url = r.stdout?.trim()
  if (r.status !== 0 || !url) throw new Error(`cannot resolve ${ref} (rc=${r.status})`)
  const u = new URL(url)
  u.searchParams.set("status", "up")
  u.searchParams.set("msg", `${label} ok`)
  const res = await fetch(u, { signal: AbortSignal.timeout(15_000) })
  if (!res.ok) throw new Error(`kuma push HTTP ${res.status}`)
}

export async function main(argv: string[]): Promise<number> {
  let a: Args
  try {
    a = parseArgs(argv)
  } catch (e) {
    console.error(`jobrun: ${(e as Error).message}`)
    return 64
  }
  const dir = defaultStateDir()
  const statePath = join(dir, `${a.label}.json`)
  const log = (l: string) => console.log(`${stamp()} ${l}`)

  let release: (() => void) | null
  try {
    release = a.lock ? acquireLock(dir, a.lock) : () => {}
  } catch (e) {
    console.error(`jobrun: cannot take lock '${a.lock}': ${(e as Error).message}`)
    return 70
  }
  if (!release) {
    log(`jobrun: lock '${a.lock}' held, skipping this run`)
    return 0
  }
  const started = Date.now()
  const run_id = `${started.toString(36)}-${process.pid}`
  const tail: string[] = []
  let result: { rc: number; interrupted: boolean }
  try {
    result = await runCommand(a.cmd, a.timeout, (l) => {
      log(l)
      tail.push(l)
      if (tail.length > TAIL_LINES) tail.shift()
    })
    if (result.rc === 124) log(`jobrun: deadline ${a.timeout}s exceeded, killed`)
    const prev = readPrev(statePath)
    const next = nextState(prev, a, { run_id, started, finished: Date.now(), rc: result.rc, tail, sha: ownerSha(a.owner), interrupted: result.interrupted })
    writeAtomic(statePath, `${JSON.stringify(next, null, 2)}\n`)
  } finally {
    release() // before the Kuma push: a slow push must not hold other jobs' lock
  }
  if (result.rc === 0 && a.kuma) {
    try {
      await pushKuma(a.kuma, a.label)
    } catch (e) {
      log(`jobrun: ${(e as Error).message}`)
      return 1 // the push failing must be visible; the run itself is already recorded ok
    }
  }
  return result.rc
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)))

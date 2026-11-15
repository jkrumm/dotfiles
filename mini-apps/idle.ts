#!/usr/bin/env bun
// The idle stop: an on-demand dev server whose door had no request for its idle window ends. Run every 120 s by
// jobrun (com.jkrumm.mini-apps-idle). The request times come from Caddy's door log (caddy-doors.log: the wildcard tailnet
// block writes it world-readable, the main access log is root-only); a server's own start time comes from the first run
// of this job that saw it running, kept in a state file. docs/mini-registry.md §Apps page.
import { closeSync, existsSync, fstatSync, mkdirSync, openSync, readFileSync, readSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import { IDLE_MINUTES, type Row } from "../scripts/mini-registry"

const HOME = homedir()
const DOOR_LOG = process.env.MINI_APPS_DOOR_LOG ?? "/opt/homebrew/var/log/caddy-doors.log"
const STATE_FILE = process.env.MINI_APPS_IDLE_STATE ?? join(HOME, ".local", "state", "mini-apps", "idle.json")
const REGISTRY = join(import.meta.dir, "..", "scripts", "mini-registry.ts")
// the newest request per door is kept in the state file between runs: a busy neighbour that pushes a door's last line out of
// this tail (or a log roll) must not read as "never requested"
const TAIL_BYTES = 4 * 1024 * 1024

// The last request per door label, from Caddy's JSON access log lines (`ts` in seconds, `request.host`, `request.uri`).
export function lastRequests(log: string): Map<string, number> {
  const last = new Map<string, number>()
  for (const line of log.split("\n")) {
    if (!line.startsWith("{")) continue
    let entry: { ts?: number; request?: { host?: string; uri?: string } }
    try { entry = JSON.parse(line) } catch { continue }
    const host = entry.request?.host
    const uri = entry.request?.uri ?? ""
    if (!host || typeof entry.ts !== "number" || /^\/_(up|wake|apps)(\/|$)/.test(uri)) continue
    const door = host.split(":")[0].toLowerCase().split(".")[0]
    last.set(door, Math.max(last.get(door) ?? 0, Math.round(entry.ts * 1000)))
  }
  return last
}

// The newest request per door of the services the job judges, merged with what earlier runs saw.
export function mergeLast(prior: Record<string, number>, seen: Map<string, number>, doors: Iterable<string>): Record<string, number> {
  const out: Record<string, number> = {}
  for (const d of doors) {
    const t = Math.max(prior[d] ?? 0, seen.get(d) ?? 0)
    if (t) out[d] = t
  }
  return out
}

type State = { firstSeen: Record<string, number>; last: Record<string, number> }

function readState(file: string): State {
  try {
    const j = JSON.parse(readFileSync(file, "utf8")) as Partial<State>
    return { firstSeen: j.firstSeen ?? {}, last: j.last ?? {} }
  } catch {
    return { firstSeen: {}, last: {} } // first run, or a file of an older shape: servers are dated from now, the safe direction
  }
}

export type IdleInput = { rows: Row[]; last: Map<string, number>; firstSeen: Record<string, number>; now: number }

// Names to stop, and the first-seen map for the next run (only what is running now).
export function planIdle({ rows, last, firstSeen, now }: IdleInput): { stop: string[]; firstSeen: Record<string, number> } {
  const next: Record<string, number> = {}
  const stop: string[] = []
  for (const r of rows) {
    if (r.kind !== "dev-server" || r.tier !== "on-demand" || r.state !== "running") continue
    next[r.name] = firstSeen[r.name] ?? now
    if (!r.can_stop) continue
    const requested = Math.max(0, ...r.doors.map((d) => last.get(d) ?? 0))
    const since = Math.max(requested, next[r.name])
    if (now - since > (r.idle_minutes ?? IDLE_MINUTES) * 60000) stop.push(r.name)
  }
  return { stop, firstSeen: next }
}

function tail(path: string, bytes: number): string {
  const fd = openSync(path, "r")
  try {
    const size = fstatSync(fd).size
    const start = Math.max(0, size - bytes)
    const buf = Buffer.alloc(size - start)
    readSync(fd, buf, 0, buf.length, start)
    return buf.toString("utf8")
  } finally {
    closeSync(fd)
  }
}

async function registry(args: string[]): Promise<{ rc: number; out: string }> {
  const p = Bun.spawn([process.execPath, REGISTRY, ...args], { stdout: "pipe", stderr: "pipe" })
  const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()])
  return { rc: await p.exited, out: out + err }
}

async function main(): Promise<number> {
  // Without the door log nothing says whether a server is in use: stop nothing.
  if (!existsSync(DOOR_LOG)) { console.log(`no door log at ${DOOR_LOG}: nothing is stopped (make caddy-tailnet writes it)`); return 0 }
  const ps = await registry(["ps", "--format", "json"])
  if (ps.rc !== 0) { console.error(`mini-registry ps exited ${ps.rc}: ${ps.out.slice(-300)}`); return 1 }
  const rows = (JSON.parse(ps.out) as { services: Row[] }).services
  const now = Date.now()
  const prior = readState(STATE_FILE)
  const doors = rows.filter((r) => r.kind === "dev-server" && r.tier === "on-demand").flatMap((r) => r.doors)
  const last = mergeLast(prior.last, lastRequests(tail(DOOR_LOG, TAIL_BYTES)), doors)
  const plan = planIdle({ rows, last: new Map(Object.entries(last)), firstSeen: prior.firstSeen, now })
  mkdirSync(dirname(STATE_FILE), { recursive: true })
  writeFileSync(STATE_FILE, JSON.stringify({ firstSeen: plan.firstSeen, last }))
  let failed = 0
  for (const name of plan.stop) {
    console.log(`idle stop ${name}`)
    const r = await registry(["down", name])
    if (r.rc !== 0) { failed++; console.error(`${name}: down exited ${r.rc}: ${r.out.slice(-300)}`) }
  }
  console.log(`${Object.keys(plan.firstSeen).length} dev server(s) running, ${plan.stop.length} stopped`)
  return failed ? 1 : 0
}

if (import.meta.main) process.exit(await main())

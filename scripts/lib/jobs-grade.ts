#!/usr/bin/env bun
// jobs-grade — the ONLY grading logic for background jobs (ops-signals.md §3 T1, §5).
// Reads the jobrun state dir plus `launchctl print` and grades every label:
//   ok | failing | stale | flapping | unloaded
// Called by the heartbeat (WARN), `make doctor` (table) and, later, warden's `job` source.
//
//   jobs-grade            JSON array on stdout
//   jobs-grade --table    human table, verdict line last (exit 0 / 2 like --summary)
//   jobs-grade --summary  one line, exit 0 (all ok) / 2 (WARN) — what the heartbeat and doctor relay
//
// Env: JOBRUN_STATE_DIR overrides ~/.local/state/jobs.
import { existsSync, readdirSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

export type Grade = "ok" | "failing" | "stale" | "flapping" | "unloaded"

export interface JobState {
  label: string
  run_id: string
  started: string
  finished: string
  rc: number
  duration_ms: number
  every: number | null
  owner: string
  owner_sha: string | null
  last_ok: string | null
  consecutive_fail: number
  fails_24h: number
  fail_times: string[]
  tail: string[]
  runs: { run_id: string; started: string; rc: number; duration_ms: number }[]
}

export interface Graded {
  label: string
  owner: string
  grade: Grade
  reason: string
  rc: number
  consecutive_fail: number
  fails_24h: number
  last_ok: string | null
  last_started: string
  every: number | null
}

// T1 thresholds (ops-signals.md §3). Exported so the tests pin the numbers.
export const FAILING_STREAK = 3
export const FLAPPING_FAILS_24H = 3
export const MIN_WINDOW_S = 30 * 60
export const DAILY_EVERY_S = 86400
export const DAILY_GRACE_S = 2 * 3600

export const defaultStateDir = () => process.env.JOBRUN_STATE_DIR || join(homedir(), ".local/state/jobs")

/** Seconds without a success (interval jobs) or a run (daily jobs) before a job is overdue. */
export function windowSeconds(every: number): number {
  return every >= DAILY_EVERY_S ? every + DAILY_GRACE_S : Math.max(3 * every, MIN_WINDOW_S)
}

export function isLoaded(label: string): boolean {
  const uid = process.getuid?.() ?? 0
  const r = Bun.spawnSync(["/bin/launchctl", "print", `gui/${uid}/${label}`], { stdout: "ignore", stderr: "ignore" })
  return r.exitCode === 0
}

const CORRUPT = "corrupt"
const CORRUPT_STREAK = 99

/** A state file we cannot trust is a visible failure, never a job that silently vanishes from grading. */
function corrupt(file: string, why: string): JobState {
  return { label: file.replace(/\.json$/, ""), owner: "?", started: "", finished: "", rc: -1, consecutive_fail: CORRUPT_STREAK, fails_24h: 0, last_ok: null, every: null, run_id: CORRUPT, duration_ms: 0, owner_sha: null, fail_times: [], tail: [why], runs: [] }
}

export function readStates(dir: string): JobState[] {
  if (!existsSync(dir)) return []
  const out: JobState[] = []
  for (const f of readdirSync(dir).sort()) {
    if (!f.endsWith(".json")) continue
    try {
      const s = JSON.parse(readFileSync(join(dir, f), "utf8")) as JobState
      const numeric = [s.consecutive_fail, s.fails_24h, s.rc].every((n) => Number.isFinite(n))
      const strings = typeof s.label === "string" && typeof s.owner === "string" && Number.isFinite(Date.parse(s.started))
      const cadence = s.every === null || Number.isFinite(s.every)
      const lastOk = s.last_ok === null || Number.isFinite(Date.parse(s.last_ok))
      if (strings && numeric && cadence && lastOk) out.push({ ...s, tail: Array.isArray(s.tail) ? s.tail : [] })
      else out.push(corrupt(f, "state file is missing required fields"))
    } catch (e) {
      out.push(corrupt(f, `state file unreadable: ${(e as Error).message}`))
    }
  }
  return out
}

export interface GradeOpts {
  now: number // epoch ms (clock injection)
  loaded: (label: string) => boolean
}

export function gradeOne(s: JobState, o: GradeOpts): Graded {
  const base = {
    label: s.label,
    owner: s.owner,
    rc: s.rc,
    consecutive_fail: s.consecutive_fail,
    fails_24h: s.fails_24h,
    last_ok: s.last_ok,
    last_started: s.started,
    every: s.every,
  }
  const done = (grade: Grade, reason: string): Graded => ({ ...base, grade, reason })

  if (s.run_id === CORRUPT) return done("failing", s.tail[0] ?? "state file corrupt")
  if (!o.loaded(s.label)) return done("unloaded", "not loaded in launchd")

  const ageS = (iso: string | null) => (iso ? (o.now - Date.parse(iso)) / 1000 : Number.POSITIVE_INFINITY)
  const windowS = s.every ? windowSeconds(s.every) : null
  const daily = !!s.every && s.every >= DAILY_EVERY_S

  if (s.consecutive_fail >= FAILING_STREAK) return done("failing", `${s.consecutive_fail} consecutive failures (rc=${s.rc})`)
  // Interval jobs also fail by not succeeding for too long while the last run is red.
  if (windowS && !daily && s.consecutive_fail > 0 && ageS(s.last_ok) > windowS) {
    const sinceOk = s.last_ok ? `${Math.round(ageS(s.last_ok) / 60)} min` : "ever"
    return done("failing", `no success for ${sinceOk}, last rc=${s.rc}`)
  }
  if (daily && s.consecutive_fail > 0) return done("failing", `daily job failed (rc=${s.rc})`)
  if (windowS && ageS(s.started) > windowS) {
    return done("stale", `last run ${Math.round(ageS(s.started) / 60)} min ago, window ${Math.round(windowS / 60)} min`)
  }
  if (s.fails_24h >= FLAPPING_FAILS_24H) return done("flapping", `${s.fails_24h} failures in 24 h`)
  return done("ok", s.consecutive_fail > 0 ? `last run failed (rc=${s.rc}), retrying` : "ok")
}

export function gradeAll(dir: string, o: GradeOpts): Graded[] {
  return readStates(dir).map((s) => gradeOne(s, o))
}

export function renderTable(rows: Graded[]): string {
  if (rows.length === 0) return "no jobs recorded"
  const w = Math.max(...rows.map((r) => r.label.length), 5)
  return rows.map((r) => `${r.grade.padEnd(9)} ${r.label.padEnd(w)}  ${r.owner.padEnd(14)} ${r.reason}`).join("\n")
}

/** One-line verdict for consumers that must not re-grade (heartbeat, doctor). Exit 0 = all ok, 2 = at least one is not. */
export function summarize(rows: Graded[]): { line: string; code: 0 | 2 } {
  const bad = rows.filter((r) => r.grade !== "ok")
  if (bad.length === 0) return { line: `jobs ok (${rows.length})`, code: 0 }
  return { line: `jobs WARN (${rows.length}): ${bad.map((r) => `${r.label}=${r.grade}`).join(", ")}`, code: 2 }
}

if (import.meta.main) {
  const rows = gradeAll(defaultStateDir(), { now: Date.now(), loaded: isLoaded })
  if (process.argv.includes("--summary")) {
    const { line, code } = summarize(rows)
    console.log(line)
    process.exit(code)
  }
  if (process.argv.includes("--table")) {
    const { line, code } = summarize(rows)
    console.log(`${renderTable(rows)}\n${line}`) // verdict is always the last line
    process.exit(code)
  }
  console.log(JSON.stringify(rows, null, 2))
}

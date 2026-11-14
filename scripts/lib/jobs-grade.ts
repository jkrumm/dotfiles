#!/usr/bin/env bun
// jobs-grade — the ONLY grading logic for background jobs (ops-signals.md §3 T1, §5).
// Reads the jobrun state dir plus `launchctl print` and grades every label:
//   ok | failing | stale | flapping | unloaded | retired | undelivered | overloaded
// Called by the heartbeat (WARN), `make doctor` (table) and any remediation consumer.
//
//   jobs-grade            JSON array on stdout
//   jobs-grade --table    human table, verdict line last (exit 0 / 2 like --summary)
//   jobs-grade --summary  one line, exit 0 (all ok) / 2 (WARN) — what the heartbeat and doctor relay
//   jobs-grade --report  with --summary or --table: report the not-ok jobs to the FACTORY, not to a person. A job not ok for
//                         REPORT_AFTER_GRADES consecutive grades files a signal on its owning repo (`factory signal file --from
//                         agent:dotfiles --repo <owner>`, one stable title per job so a repeat amends the same item) and a lead fixes
//                         it. A job is reported at most once per REPORT_EVERY_MS, so a flapping job costs one signal a day. ntfy
//                         (topic `alerts`, priority 3) is only the fallback when `factory` cannot be reached, also at most once a day
//                         per job. Best-effort: a failed report writes one stderr line, never changes stdout or the exit code, and
//                         is retried on the next tick (a job is only marked reported after it landed). Recovery sends nothing.
//   jobs-grade --notify   MacBook wake hook: like --summary, plus a macOS notification for the bad rows.
//                         A closed lid is not a stalled job, so `stale` is judged against AWAKE time:
//                         a row is dropped unless the machine has been awake for its whole window.
//
// Expected set: every installed plist whose ProgramArguments invoke `jobrun` declares a label this
// grader must see. A declared label with no state file is graded (never invisible); the plists are
// the single source, there is no hand list.
//
// Retired: a job stopped on purpose (an owner repo froze, a job waiting to come back) is retired by a marker file
// `<state dir>/<label>.retired` (its text is the reason): `echo "V1 frozen" > ~/.local/state/jobs/<label>.retired`.
// A marked label that is NOT loaded in launchd grades `retired` (counts as ok, files nothing). A marked label that IS
// loaded grades normally, so reinstalling the plist brings the job back without touching the marker; remove the marker
// on the way back anyway.
//
// Disabled: a label launchd reports disabled (`launchctl print-disabled`) is switched off on purpose. It is not graded
// at all (no row, no summary entry, no signal) and `--report` drops its stored counters.
//
// Undelivered: a heartbeat job exits PUSH_UNDELIVERED_RC (75, EX_TEMPFAIL) when its check ran but the push to the monitor could
// not be delivered. That is the push target being slow or down, never the job failing: jobrun does not count it as a failure,
// the grade is `undelivered`, and `--report` files ONE signal naming the target for every job in that state.
//
// Overloaded: a timeout (rc=124) while the host is over its load ceiling (HOST_LOAD_PER_CPU x cpus) or inside the boot grace is the
// host's problem, not the job's. jobrun records `host_overloaded` on the run and does not count it as a failure; the grade is
// `overloaded` and `--report` files ONE signal per overload episode, however many jobs timed out.
//
// Hermes cron jobs (~/.hermes/cron/jobs.json) are graded too, through an adapter below.
//
// Env: JOBRUN_STATE_DIR overrides ~/.local/state/jobs; JOBRUN_PLIST_DIR overrides ~/Library/LaunchAgents;
// JOBRUN_HERMES_CRON overrides ~/.hermes/cron/jobs.json.
// --report: JOBS_GRADE_REPORT_STATE (default ~/.local/state/jobs-grade/report.json), JOBS_GRADE_FACTORY_BIN (default `factory`);
// the ntfy fallback reads JOBS_GRADE_NTFY_TOPIC (default `alerts`),
// JOBS_GRADE_NTFY_TOKEN (default: `secrets-run read op://common/ntfy/TOKEN`), JOBS_GRADE_NTFY_URL or NTFY_URL (default: the
// base-url in ~/SourceRoot/homelab/config/ntfy/server.yml, read at run time because the host is private; tests point it at a stub).
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs"
import { cpus, homedir, hostname, loadavg, uptime } from "node:os"
import { dirname, join } from "node:path"

export type Grade = "ok" | "failing" | "stale" | "flapping" | "unloaded" | "retired" | "undelivered" | "overloaded"

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
  /** The host was over its load ceiling (or booting) when the run started or ended; absent on older state files. */
  host_overloaded?: boolean
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
  /** Owner repo HEAD when the last run started, the last 5 runs and the output tail: what a job brief quotes. Absent on a never-recorded job. */
  owner_sha?: string | null
  runs?: JobState["runs"]
  tail?: string[]
}

// T1 thresholds (ops-signals.md §3). Exported so the tests pin the numbers.
export const FAILING_STREAK = 3
export const FLAPPING_FAILS_24H = 3
// A job whose latest runs are all green has recovered: its 24 h failure count is history, not flapping.
export const RECOVERED_RUNS = 3
export const MIN_WINDOW_S = 30 * 60
export const DAILY_EVERY_S = 86400
export const DAILY_GRACE_S = 2 * 3600

// Exit code of a heartbeat job whose check ran but whose push to the monitor was not delivered (sysexits EX_TEMPFAIL).
export const PUSH_UNDELIVERED_RC = 75
export const PUSH_TARGET = "Uptime Kuma"
export const TIMEOUT_RC = 124
// Host overload: 1-minute load above HOST_LOAD_PER_CPU x cpus (a healthy mini ran load 7 on 12 cpus; 2026-11-12 hit 260+), or booted
// less than BOOT_GRACE_S ago (the heartbeat's own boot grace).
export const HOST_LOAD_PER_CPU = 2
export const BOOT_GRACE_S = 300

export interface HostLoad {
  load1: number
  ncpu: number
  uptimeS: number
}

export const isHostOverloaded = (h: HostLoad): boolean => h.load1 > HOST_LOAD_PER_CPU * h.ncpu || h.uptimeS < BOOT_GRACE_S

export function readHostLoad(): HostLoad {
  return { load1: loadavg()[0], ncpu: Math.max(1, cpus().length), uptimeS: uptime() }
}

export const RETIRED_SUFFIX = ".retired"

/** Retire markers in the state dir: label -> reason (the marker's text). A missing dir retires nothing. */
export function readRetired(dir: string): Map<string, string> {
  const out = new Map<string, string>()
  if (!existsSync(dir)) return out
  for (const f of readdirSync(dir).sort()) {
    if (!f.endsWith(RETIRED_SUFFIX)) continue
    let reason = ""
    try {
      reason = readFileSync(join(dir, f), "utf8").trim()
    } catch {
      // an unreadable marker still retires: the reason is only text
    }
    out.set(f.slice(0, -RETIRED_SUFFIX.length), reason)
  }
  return out
}

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

/** Labels launchd reports disabled (`launchctl print-disabled`): `"<label>" => disabled`. Unreadable output disables nothing. */
export function parseDisabled(out: string): Set<string> {
  const labels = new Set<string>()
  for (const m of out.matchAll(/"([^"]+)"\s*=>\s*(?:disabled|true)\b/g)) labels.add(m[1])
  return labels
}

export function readDisabled(): Set<string> {
  const uid = process.getuid?.() ?? 0
  const r = Bun.spawnSync(["/bin/launchctl", "print-disabled", `gui/${uid}`], { stdout: "pipe", stderr: "ignore" })
  return r.exitCode === 0 ? parseDisabled(r.stdout.toString()) : new Set()
}

const CORRUPT = "corrupt"
const CORRUPT_STREAK = 99

/** A state file we cannot trust is a visible failure, never a job that silently vanishes from grading. */
function corrupt(label: string, why: string): JobState {
  return { label, owner: "?", started: "", finished: "", rc: -1, consecutive_fail: CORRUPT_STREAK, fails_24h: 0, last_ok: null, every: null, run_id: CORRUPT, duration_ms: 0, owner_sha: null, fail_times: [], tail: [why], runs: [] }
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
      else out.push(corrupt(f.replace(/\.json$/, ""), "state file is missing required fields"))
    } catch (e) {
      out.push(corrupt(f.replace(/\.json$/, ""), `state file unreadable: ${(e as Error).message}`))
    }
  }
  return out
}

// --- Hermes cron adapter -------------------------------------------------------------------------
// Hermes cron jobs are not launchd jobs and never go through jobrun: the gateway runs them and keeps
// the last outcome in ~/.hermes/cron/jobs.json. They are translated into the same JobState records
// and graded by the same gradeOne, so a failing cron job becomes a `job` item for hermes-agent through
// the same path as every other job. Only the LAST run is known (no history): a failed daily/weekly job is `failing`
// at once, which is the right reading for a job that runs once a day or a week.
export const CRON_PREFIX = "hermes-cron."
export const CRON_GATEWAY_LABEL = "ai.hermes.gateway" // the launchd job that runs every cron job
export const CRON_OWNER = "hermes-agent"
export const defaultCronJobs = () => process.env.JOBRUN_HERMES_CRON || join(homedir(), ".hermes/cron/jobs.json")

/** The longest gap between two runs of a fixed-time cron expression, in seconds; null for anything else
 *  (then only a failure is graded, never staleness). Supports `M H * * <dow>` with `*`, lists and ranges. */
export function cronEvery(expr: unknown): number | null {
  if (typeof expr !== "string") return null
  const f = expr.trim().split(/\s+/)
  if (f.length !== 5 || !/^\d+$/.test(f[0]) || !/^\d+$/.test(f[1]) || f[2] !== "*" || f[3] !== "*") return null
  if (f[4] === "*") return 86400
  const days = new Set<number>()
  for (const part of f[4].split(",")) {
    const m = /^(\d)(?:-(\d))?$/.exec(part)
    if (!m) return null
    const [lo, hi] = [Number(m[1]), Number(m[2] ?? m[1])]
    if (lo > 7 || hi > 7 || lo > hi) return null
    for (let d = lo; d <= hi; d++) days.add(d % 7)
  }
  const sorted = [...days].sort((a, b) => a - b)
  const gap = Math.max(...sorted.map((d, i) => (i === sorted.length - 1 ? sorted[0] + 7 : sorted[i + 1]) - d))
  return gap * 86400
}

const slug = (name: string) => name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")

/** Enabled cron jobs that have run at least once, as run records. A missing file is no cron jobs; a registry
 *  or an entry we cannot read is a visible failure, like a corrupt jobrun state file, never a silent gap. */
export function readCronStates(path: string, now: number = Date.now()): JobState[] {
  if (!existsSync(path)) return []
  const broken = (label: string, why: string): JobState => ({ ...corrupt(label, why), owner: CRON_OWNER })
  let jobs: unknown[]
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"))
    if (!Array.isArray(parsed?.jobs)) return [broken(`${CRON_PREFIX}registry`, "cron registry has no jobs array")]
    jobs = parsed.jobs
  } catch (e) {
    return [broken(`${CRON_PREFIX}registry`, `cron registry unreadable: ${(e as Error).message}`)]
  }
  const out: JobState[] = []
  const used = new Set<string>()
  for (const [i, entry] of jobs.entries()) {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      out.push(broken(`${CRON_PREFIX}entry-${i}`, "cron registry entry is not an object"))
      continue
    }
    const j = entry as Record<string, unknown>
    const started = typeof j.last_run_at === "string" ? j.last_run_at : ""
    if (j.enabled === false || !started || !Number.isFinite(Date.parse(started)) || typeof j.last_status !== "string") continue
    const name = typeof j.name === "string" && j.name ? j.name : String(j.id ?? i)
    const ok = j.last_status === "ok"
    const sched = typeof j.schedule_display === "string" ? j.schedule_display : (j.schedule as { expr?: string } | undefined)?.expr
    let label = `${CRON_PREFIX}${slug(name) || i}`
    if (used.has(label)) label = `${label}-${j.id ?? i}` // two names slugging alike stay two jobs
    used.add(label)
    const failTail = `hermes cron job '${name}' (id ${j.id}, schedule ${sched ?? "?"}) ended status=${j.last_status}: ${j.last_error ?? "no error recorded"}`
    out.push({
      label, run_id: started, started, finished: started, rc: ok ? 0 : 1, duration_ms: 0, // Hermes records one outcome: it is the run
      every: cronEvery(sched), owner: CRON_OWNER, owner_sha: null, last_ok: ok ? started : null,
      consecutive_fail: ok ? 0 : 1, fails_24h: !ok && now - Date.parse(started) < 86400_000 ? 1 : 0, fail_times: ok ? [] : [started],
      tail: ok ? [] : [failTail],
      runs: [{ run_id: started, started, rc: ok ? 0 : 1, duration_ms: 0 }],
    })
  }
  return out
}

/** A label a plist promises to run through jobrun. */
export interface Expected {
  label: string
  owner: string
  every: number | null
  installedAt: number // epoch ms, the plist's mtime: the grace clock for a job that has not run yet
}

export interface GradeOpts {
  now: number // epoch ms (clock injection)
  loaded: (label: string) => boolean
  expected?: Expected[]
  cron?: JobState[] // Hermes cron jobs, already translated by readCronStates
  retired?: Map<string, string> // label -> reason, from readRetired
  disabled?: Set<string> // labels launchd reports disabled: not graded at all
  host?: { overloaded: boolean } // the host right now; a timeout while it is true grades `overloaded`
}

export const defaultPlistDir = () => process.env.JOBRUN_PLIST_DIR || join(homedir(), "Library/LaunchAgents")

/** The `jobrun <label> --owner <repo> --every <s> ...` invocation inside a plist's ProgramArguments, if any. */
export function parseJobrunArgs(args: string[]): { label: string; owner: string; every: number | null } | null {
  const i = args.findIndex((a) => a === "jobrun" || a.endsWith("/jobrun"))
  if (i < 0) return null
  const label = args[i + 1]
  if (!label || label.startsWith("--")) return null
  const dd = args.indexOf("--", i)
  const head = args.slice(i + 2, dd < 0 ? undefined : dd)
  const opt = (name: string) => {
    const k = head.indexOf(name)
    return k >= 0 ? (head[k + 1] ?? null) : null
  }
  const every = Number(opt("--every"))
  return { label, owner: opt("--owner") ?? "?", every: Number.isFinite(every) && every > 0 ? every : null }
}

export function readExpected(plistDir: string): Expected[] {
  if (!existsSync(plistDir)) return []
  const out: Expected[] = []
  for (const f of readdirSync(plistDir).sort()) {
    if (!f.endsWith(".plist")) continue
    const path = join(plistDir, f)
    const r = Bun.spawnSync(["/usr/bin/plutil", "-convert", "json", "-o", "-", "--", path], { stdout: "pipe", stderr: "ignore" })
    if (r.exitCode !== 0) continue
    try {
      const args = (JSON.parse(r.stdout.toString()) as { ProgramArguments?: unknown }).ProgramArguments
      const parsed = Array.isArray(args) ? parseJobrunArgs(args.map(String)) : null
      if (parsed) out.push({ ...parsed, installedAt: statSync(path).mtimeMs })
    } catch {
      // an unparseable plist declares nothing
    }
  }
  return out
}

const retiredReason = (why: string) => (why ? `retired on purpose: ${why}` : "retired on purpose")

/** Declared by a plist, but jobrun never wrote a state file: not loaded = unloaded, past its first window = stale. */
export function gradeNeverRecorded(e: Expected, o: GradeOpts): Graded {
  const base = { label: e.label, owner: e.owner, rc: -1, consecutive_fail: 0, fails_24h: 0, last_ok: null, last_started: "", every: e.every }
  if (!o.loaded(e.label)) {
    const why = o.retired?.get(e.label)
    return why === undefined
      ? { ...base, grade: "unloaded", reason: "declared by a plist but not loaded in launchd" }
      : { ...base, grade: "retired", reason: retiredReason(why) }
  }
  const windowS = windowSeconds(e.every ?? 0)
  const sinceInstallS = (o.now - e.installedAt) / 1000
  if (sinceInstallS > windowS) return { ...base, grade: "stale", reason: `never recorded, installed ${Math.round(sinceInstallS / 60)} min ago, window ${Math.round(windowS / 60)} min` }
  return { ...base, grade: "ok", reason: "not run yet, inside its first window" }
}

/** No plist declares the label, it is no Hermes cron job and it has no cadence. Needs `o.expected` (the plist scan): without it nothing is known to be undeclared. */
function isOnDemand(s: JobState, o: GradeOpts): boolean {
  if (!o.expected || s.every !== null || s.label.startsWith(CRON_PREFIX)) return false
  return !o.expected.some((e) => e.label === s.label)
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
    owner_sha: s.owner_sha,
    runs: s.runs ?? [],
    tail: s.tail,
  }
  const done = (grade: Grade, reason: string): Graded => ({ ...base, grade, reason })

  if (s.run_id === CORRUPT) return done("failing", s.tail[0] ?? "state file corrupt")
  // On demand: started by hand or a hook through `jobrun`, no plist, no cadence. There is nothing to load and
  // nothing to be late for, so only the outcome of the last run grades.
  if (isOnDemand(s, o)) return done(s.consecutive_fail > 0 ? "failing" : "ok", s.consecutive_fail > 0 ? `on-demand job's last run failed (rc=${s.rc})` : "ok")
  if (!o.loaded(s.label)) {
    const why = o.retired?.get(s.label)
    return why === undefined ? done("unloaded", "not loaded in launchd") : done("retired", retiredReason(why))
  }

  // The check ran, the push did not arrive: the monitor's fault, never the job's. A real failure streak still wins.
  if (s.rc === PUSH_UNDELIVERED_RC && s.consecutive_fail < FAILING_STREAK) return done("undelivered", `push target slow or down (${PUSH_TARGET}), the check itself ran`)
  if (s.rc === TIMEOUT_RC && (s.host_overloaded || o.host?.overloaded) && s.consecutive_fail < FAILING_STREAK) return done("overloaded", "host overloaded, run timed out (rc=124)")

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
  // A cron job's only record is its last outcome and its schedule may be one we cannot turn into a cadence:
  // a failure there must still grade, or it would read "retrying" forever.
  if (!s.every && s.label.startsWith(CRON_PREFIX) && s.consecutive_fail > 0) return done("failing", "cron job's last run failed")
  if (windowS && ageS(s.started) > windowS) {
    return done("stale", `last run ${Math.round(ageS(s.started) / 60)} min ago, window ${Math.round(windowS / 60)} min`)
  }
  if (s.fails_24h >= FLAPPING_FAILS_24H && !recovered(s)) return done("flapping", `${s.fails_24h} failures in 24 h`)
  return done("ok", s.consecutive_fail > 0 ? `last run failed (rc=${s.rc}), retrying` : "ok")
}

function recovered(s: JobState): boolean {
  const last = (s.runs ?? []).slice(-RECOVERED_RUNS)
  return last.length === RECOVERED_RUNS && last.every((r) => r.rc === 0)
}

export function gradeAll(dir: string, o: GradeOpts): Graded[] {
  // A cron job runs inside the Hermes gateway, so it is loaded exactly when the gateway is.
  const cronLoaded = { ...o, loaded: (l: string) => o.loaded(l.startsWith(CRON_PREFIX) ? CRON_GATEWAY_LABEL : l) }
  const on = (x: { label: string }) => !o.disabled?.has(x.label) // a disabled label is switched off, not failing
  const rows = [...readStates(dir).filter(on).map((s) => gradeOne(s, o)), ...(o.cron ?? []).filter(on).map((s) => gradeOne(s, cronLoaded))]
  const seen = new Set(rows.map((r) => r.label))
  for (const e of o.expected ?? []) {
    if (seen.has(e.label) || !on(e)) continue
    seen.add(e.label) // two plists declaring one label are one job
    rows.push(gradeNeverRecorded(e, o))
  }
  return rows.sort((a, b) => a.label.localeCompare(b.label))
}

/** Seconds since the last wake from `sysctl -n kern.waketime` (`{ sec = 1760000000, usec = 0 } Fri ...`). null = unreadable. */
export function awakeSeconds(waketime: string, now: number): number | null {
  const sec = /sec\s*=\s*(\d+)/.exec(waketime)?.[1]
  return sec ? Math.max(0, Math.round(now / 1000 - Number(sec))) : null
}

/** A `stale` row is only proof of a stalled job if the machine was awake for the job's whole window; asleep time proves nothing. */
export function judgeAgainstAwake(rows: Graded[], awakeS: number | null): Graded[] {
  if (awakeS === null) return rows
  return rows.filter((r) => r.grade !== "stale" || r.every === null || windowSeconds(r.every) <= awakeS)
}

function notify(message: string): void {
  Bun.spawnSync(["/usr/bin/osascript", "-e", `display notification ${JSON.stringify(message)} with title "jobs-grade"`], { stdout: "ignore", stderr: "ignore" })
}

export function renderTable(rows: Graded[]): string {
  if (rows.length === 0) return "no jobs recorded"
  const w = Math.max(...rows.map((r) => r.label.length), 5)
  return rows.map((r) => `${r.grade.padEnd(9)} ${r.label.padEnd(w)}  ${r.owner.padEnd(14)} ${r.reason}`).join("\n")
}

/** Retired is a decision, not a problem: it never warns and never files. */
const isBad = (r: Graded) => r.grade !== "ok" && r.grade !== "retired"

/** One-line verdict for consumers that must not re-grade (heartbeat, doctor). Exit 0 = all ok, 2 = at least one is not. */
export function summarize(rows: Graded[]): { line: string; code: 0 | 2 } {
  const bad = rows.filter(isBad)
  if (bad.length === 0) return { line: `jobs ok (${rows.length})`, code: 0 }
  return { line: `jobs WARN (${rows.length}): ${bad.map((r) => `${r.label}=${r.grade}`).join(", ")}`, code: 2 }
}

// --- Reporting: signals to the factory, ntfy only as the fallback -----------------------------------
// The owner wants only what needs him. A job that stays red is a repo's problem, so it becomes a signal on the
// owning repo (a lead fixes it); a person is paged only when the factory itself cannot take the signal.
export const REPORT_AFTER_GRADES = 2 // consecutive not-ok grades (the heartbeat grades every 5 min)
export const REPORT_EVERY_MS = 24 * 3600_000 // per job: a flapping job is one signal a day, never one per flap
export const SIGNAL_FROM = "agent:dotfiles"
const STATE_KEEP_MS = 2 * REPORT_EVERY_MS
const NTFY_MAX_CHARS = 1500
const NTFY_DEFAULT_TOPIC = "alerts"
const NTFY_TOKEN_REF = "op://common/ntfy/TOKEN"
// The server host is private and this repo is public: read it from the homelab repo's ntfy config at run time.
const NTFY_CONFIG = () => join(homedir(), "SourceRoot/homelab/config/ntfy/server.yml")

export const defaultReportState = () => process.env.JOBS_GRADE_REPORT_STATE || join(homedir(), ".local/state/jobs-grade/report.json")
const shortHost = () => hostname().split(".")[0]

const clip = (text: string, max = NTFY_MAX_CHARS) => (text.length > max ? `${text.slice(0, max - 1)}…` : text)

/** Per job: consecutive not-ok grades, when a signal last landed, when the ntfy fallback last landed. */
export interface JobReport {
  bad: number
  filedAt: number | null
  ntfyAt: number | null
  /** Groups only: when a member was last graded. A gap of EPISODE_GAP_MS ends the episode, so the next one files again. */
  seenAt?: number
}
export type ReportState = Record<string, JobReport>

/** A job's signal: one stable title per job, so the factory amends the same item on a repeat. */
export function signalFor(r: Graded): { repo: string; title: string; text: string } {
  const repo = r.owner && r.owner !== "?" ? r.owner : "dotfiles"
  const lines = [
    `Job ${r.label} (owner repo ${repo}) is ${r.grade}: ${r.reason}.`,
    `last rc=${r.rc}, ${r.consecutive_fail} consecutive failures, ${r.fails_24h} in 24 h, last ok ${r.last_ok ?? "never"}, cadence ${r.every ?? "none"} s${r.owner_sha ? `, owner HEAD ${r.owner_sha}` : ""}.`,
    ...(r.runs?.length ? [`last runs: ${r.runs.map((x) => `${x.started} rc=${x.rc} ${Math.round(x.duration_ms / 1000)}s`).join("; ")}`] : []),
    ...(r.tail?.length ? ["output tail:", ...r.tail.slice(-20)] : []),
    "Find the root cause and fix the job (or its plist/timeout). Grading: `bun scripts/lib/jobs-grade.ts --table` in dotfiles; run state under ~/.local/state/jobs.",
  ]
  return { repo, title: `Background job ${r.label} needs a fix`, text: clip(lines.join("\n"), 8000) }
}

// Grades that are one shared cause, not one job's fault: every row in such a grade joins ONE group, reported once per episode.
export const EPISODE_GAP_MS = 30 * 60_000
export const PUSH_GROUP_KEY = `push:${PUSH_TARGET}`
export const OVERLOAD_GROUP_KEY = "host:overloaded"
const GROUP_OF: Partial<Record<Grade, string>> = { undelivered: PUSH_GROUP_KEY, overloaded: OVERLOAD_GROUP_KEY }

export interface DueGroup {
  key: string
  rows: Graded[]
}

/** The one signal for a group: it names the push target, or the overloaded host, and every job it hit. */
export function signalForGroup(g: DueGroup): { repo: string; title: string; text: string } {
  const jobs = g.rows.map((r) => `- ${r.label} (owner ${r.owner}): last rc=${r.rc}, last run ${r.last_started || "never"}`)
  if (g.key === PUSH_GROUP_KEY) {
    return {
      repo: "dotfiles",
      title: `Push target ${PUSH_TARGET} slow or down`,
      text: clip([
        `${g.rows.length} heartbeat job(s) ran their check but could not deliver the push to ${PUSH_TARGET} (exit ${PUSH_UNDELIVERED_RC}): the push target is slow or down, the jobs are not failing.`,
        ...jobs,
        `Look at ${PUSH_TARGET} and the path to it (Cloudflare, the tunnel, the host load), not at the jobs. Grading: \`bun scripts/lib/jobs-grade.ts --table\` in dotfiles.`,
      ].join("\n"), 8000),
    }
  }
  return {
    repo: "dotfiles",
    title: "Host overloaded: background jobs timing out",
    text: clip([
      `${g.rows.length} job(s) timed out (rc=${TIMEOUT_RC}) while the host was over its load ceiling (${HOST_LOAD_PER_CPU} x cpus) or inside the boot grace. One cause, one message per episode: the jobs are not at fault.`,
      ...jobs,
      "Look at what loaded the host (runaway processes, a build storm, Spotlight/fseventsd), not at the jobs. Grading: `bun scripts/lib/jobs-grade.ts --table` in dotfiles.",
    ].join("\n"), 8000),
  }
}

/** Advance the per-job counters one grade and decide which jobs are due a report.
 *  `due` = not ok for REPORT_AFTER_GRADES grades in a row, and not reported (signal or ntfy) in REPORT_EVERY_MS.
 *  `dueGroups` = the same for the shared causes (an undelivered push, an overloaded host): one entry per cause, per episode. */
export function reportPlan(prev: ReportState, rows: Graded[], now: number): { next: ReportState; due: Graded[]; dueGroups: DueGroup[] } {
  const next: ReportState = {}
  const due: Graded[] = []
  const groups = new Map<string, Graded[]>()
  for (const r of rows) {
    const key = GROUP_OF[r.grade]
    if (key) groups.set(key, [...(groups.get(key) ?? []), r])
  }
  const dueGroups: DueGroup[] = []
  for (const [key, members] of groups) {
    const old = prev[key] ?? { bad: 0, filedAt: null, ntfyAt: null }
    const sameEpisode = old.seenAt !== undefined && now - old.seenAt <= EPISODE_GAP_MS
    const cur = { bad: old.bad + 1, filedAt: sameEpisode ? old.filedAt : null, ntfyAt: sameEpisode ? old.ntfyAt : null, seenAt: now }
    next[key] = cur
    if (cur.bad >= REPORT_AFTER_GRADES && cur.filedAt === null && cur.ntfyAt === null) dueGroups.push({ key, rows: members })
  }
  for (const r of rows) {
    if (GROUP_OF[r.grade]) continue // counted in its group, never as the job's own failure
    const old = prev[r.label] ?? { bad: 0, filedAt: null, ntfyAt: null }
    if (!isBad(r)) {
      // history only: a job that recovered keeps its last-report stamps for a day so a quick relapse is still one signal a day
      next[r.label] = { bad: 0, filedAt: old.filedAt, ntfyAt: old.ntfyAt }
      continue
    }
    const cur = { ...old, bad: old.bad + 1 }
    next[r.label] = cur
    const recent = (t: number | null) => t !== null && now - t < REPORT_EVERY_MS
    if (cur.bad >= REPORT_AFTER_GRADES && !recent(cur.filedAt)) due.push(r)
  }
  for (const [label, rep] of Object.entries(prev)) {
    if (next[label]) continue
    if (rep.seenAt !== undefined) {
      if (now - rep.seenAt <= EPISODE_GAP_MS) next[label] = rep // a quiet tick inside the episode: it goes on
      continue // past the gap the episode is over, nothing left to remember
    }
    // a job that vanished from grading keeps its stamps until they are old
    if ((rep.filedAt ?? 0) > now - STATE_KEEP_MS || (rep.ntfyAt ?? 0) > now - STATE_KEEP_MS) next[label] = { ...rep, bad: 0 }
  }
  for (const [label, rep] of Object.entries(next)) {
    if (rep.bad === 0 && (rep.filedAt ?? 0) <= now - STATE_KEEP_MS && (rep.ntfyAt ?? 0) <= now - STATE_KEEP_MS) delete next[label]
  }
  return { next, due, dueGroups }
}

function readReportState(path: string): ReportState {
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, "utf8"))
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return {}
    const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null)
    return Object.fromEntries(Object.entries(parsed).flatMap(([label, v]) => {
      if (typeof v !== "object" || v === null) return []
      const o = v as Record<string, unknown>
      const seenAt = num(o.seenAt)
      return [[label, { bad: num(o.bad) ?? 0, filedAt: num(o.filedAt), ntfyAt: num(o.ntfyAt), ...(seenAt === null ? {} : { seenAt }) }]]
    }))
  } catch {
    return {} // missing or corrupt = nothing reported yet
  }
}

function ntfyToken(): string {
  const fromEnv = process.env.JOBS_GRADE_NTFY_TOKEN
  if (fromEnv) return fromEnv
  // launchd's PATH is minimal; secrets-run lives in ~/.local/bin
  const PATH = `${process.env.PATH ?? "/usr/bin:/bin"}:${join(homedir(), ".local/bin")}`
  const r = Bun.spawnSync(["secrets-run", "read", NTFY_TOKEN_REF], { env: { ...process.env, PATH }, stdout: "pipe", stderr: "ignore", timeout: 10_000 })
  const token = r.stdout.toString().trim()
  if (r.exitCode !== 0 || !token) throw new Error("no ntfy token (secrets-run read failed)")
  return token
}

function ntfyBaseUrl(): string {
  const fromEnv = process.env.JOBS_GRADE_NTFY_URL || process.env.NTFY_URL
  if (fromEnv) return fromEnv.replace(/\/+$/, "")
  const m = /^base-url:\s*"?([^"\s]+)"?\s*$/m.exec(existsSync(NTFY_CONFIG()) ? readFileSync(NTFY_CONFIG(), "utf8") : "")
  if (!m) throw new Error(`no ntfy base url (NTFY_URL unset, ${NTFY_CONFIG()} unreadable)`)
  return m[1].replace(/\/+$/, "")
}

/** The fallback: priority 3 (default), because it only fires when the factory cannot take the signal. */
async function postNtfy(text: string): Promise<void> {
  const res = await fetch(`${ntfyBaseUrl()}/${process.env.JOBS_GRADE_NTFY_TOPIC || NTFY_DEFAULT_TOPIC}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${ntfyToken()}`, Title: "Background jobs", Tags: "warning", Priority: "3" },
    body: text,
    signal: AbortSignal.timeout(10_000),
  })
  if (!res.ok) throw new Error(`http ${res.status}`)
}

/** `factory signal file` for one job. Resolves true when the factory took it. */
async function fileSignal(s: { repo: string; title: string; text: string }): Promise<boolean> {
  const PATH = `${process.env.PATH ?? "/usr/bin:/bin"}:${join(homedir(), ".local/bin")}`
  const bin = process.env.JOBS_GRADE_FACTORY_BIN || "factory"
  const proc = Bun.spawn([bin, "signal", "file", "--from", SIGNAL_FROM, "--repo", s.repo, "--title", s.title, "--text", s.text], {
    env: { ...process.env, PATH }, stdout: "ignore", stderr: "pipe", timeout: 20_000,
  })
  const [err, code] = await Promise.all([new Response(proc.stderr).text(), proc.exited])
  if (code !== 0) console.error(`jobs-grade: factory signal for ${s.title} failed (rc=${code}): ${err.trim().split("\n")[0] ?? ""}`)
  return code === 0
}

export interface ReportDeps {
  now?: number
  file?: (s: { repo: string; title: string; text: string }) => Promise<boolean>
  ntfy?: (text: string) => Promise<void>
  /** Labels launchd reports disabled: their stored counters are dropped. */
  disabled?: Set<string>
}

/** Best-effort: file a signal for every job that is due, ntfy (priority 3, once a day per job) only for a job the
 *  factory would not take, then persist the counters. Never throws. "failed" = a report or the state write failed. */
export async function reportJobs(rows: Graded[], statePath: string = defaultReportState(), deps: ReportDeps = {}): Promise<"ok" | "unchanged" | "failed"> {
  const now = deps.now ?? Date.now()
  const file = deps.file ?? fileSignal
  const ntfy = deps.ntfy ?? postNtfy
  let failed = false
  let reported = false
  const prev = readReportState(statePath)
  const { next, due, dueGroups } = reportPlan(prev, rows, now)
  const items = [
    ...due.map((r) => ({ key: r.label, sig: signalFor(r), what: `${r.label}=${r.grade} (${r.reason})` })),
    ...dueGroups.map((g) => ({ key: g.key, sig: signalForGroup(g), what: `${g.key}: ${g.rows.map((r) => r.label).join(", ")}` })),
  ]
  for (const { key, sig, what } of items) {
    try {
      if (await file(sig)) {
        next[key].filedAt = now
        reported = true
        continue
      }
    } catch (e) {
      console.error(`jobs-grade: factory signal failed: ${(e as Error).message}`)
    }
    // factory unreachable: the fallback, at most once a day per job (a group: once per episode, see reportPlan)
    const ntfyAt = next[key].ntfyAt
    if (ntfyAt !== null && now - ntfyAt < REPORT_EVERY_MS) continue
    try {
      await ntfy(clip(`jobs-grade[${shortHost()}]: ${what} — factory unreachable, signal not filed for ${sig.repo}`))
      next[key].ntfyAt = now
      reported = true
    } catch (e) {
      console.error(`jobs-grade: ntfy fallback failed: ${(e as Error).message}`)
      failed = true
    }
  }
  for (const label of deps.disabled ?? []) delete next[label] // switched off on purpose: no stored grade survives
  try {
    mkdirSync(dirname(statePath), { recursive: true })
    const tmp = `${statePath}.${process.pid}.tmp`
    writeFileSync(tmp, JSON.stringify(next))
    renameSync(tmp, statePath)
  } catch (e) {
    console.error(`jobs-grade: report state write failed: ${(e as Error).message}`)
    return "failed"
  }
  return failed ? "failed" : reported ? "ok" : "unchanged"
}

const readAwakeSeconds = () => awakeSeconds(Bun.spawnSync(["/usr/sbin/sysctl", "-n", "kern.waketime"], { stderr: "ignore" }).stdout.toString(), Date.now())

if (import.meta.main) {
  const disabled = readDisabled()
  const rows = gradeAll(defaultStateDir(), { now: Date.now(), loaded: isLoaded, expected: readExpected(defaultPlistDir()), retired: readRetired(defaultStateDir()), cron: readCronStates(defaultCronJobs()), disabled, host: { overloaded: isHostOverloaded(readHostLoad()) } })
  if (process.argv.includes("--notify")) {
    const { line, code } = summarize(judgeAgainstAwake(rows, readAwakeSeconds()))
    if (code !== 0) notify(line)
    console.log(line)
    process.exit(code)
  }
  const reportStatus = process.argv.includes("--report") && (process.argv.includes("--summary") || process.argv.includes("--table"))
    ? await reportJobs(judgeAgainstAwake(rows, readAwakeSeconds()), defaultReportState(), { disabled })
    : null
  const failedNote = reportStatus === "failed" ? " [report failed]" : ""
  if (process.argv.includes("--summary")) {
    const { line, code } = summarize(rows)
    console.log(`${line}${failedNote}`)
    process.exit(code)
  }
  if (process.argv.includes("--table")) {
    const { line, code } = summarize(rows)
    console.log(`${renderTable(rows)}\n${line}${failedNote}`) // verdict is always the last line
    process.exit(code)
  }
  console.log(JSON.stringify(rows, null, 2))
}

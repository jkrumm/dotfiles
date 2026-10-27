#!/usr/bin/env bun
// jobs-grade — the ONLY grading logic for background jobs (ops-signals.md §3 T1, §5).
// Reads the jobrun state dir plus `launchctl print` and grades every label:
//   ok | failing | stale | flapping | unloaded
// Called by the heartbeat (WARN), `make doctor` (table) and any remediation consumer.
//
//   jobs-grade            JSON array on stdout
//   jobs-grade --table    human table, verdict line last (exit 0 / 2 like --summary)
//   jobs-grade --summary  one line, exit 0 (all ok) / 2 (WARN) — what the heartbeat and doctor relay
//   jobs-grade --slack    with --summary or --table: post to Slack #alerts when the set of not-ok jobs changes
//                         (new failure, grade change, recovery). Best-effort: a failed post writes one stderr
//                         line, never changes stdout or the exit code, and is retried on the next tick because
//                         the state file is only written after a successful post.
//   jobs-grade --notify   MacBook wake hook: like --summary, plus a macOS notification for the bad rows.
//                         A closed lid is not a stalled job, so `stale` is judged against AWAKE time:
//                         a row is dropped unless the machine has been awake for its whole window.
//
// Expected set: every installed plist whose ProgramArguments invoke `jobrun` declares a label this
// grader must see. A declared label with no state file is graded (never invisible); the plists are
// the single source, there is no hand list.
//
// Hermes cron jobs (~/.hermes/cron/jobs.json) are graded too, through an adapter below.
//
// Env: JOBRUN_STATE_DIR overrides ~/.local/state/jobs; JOBRUN_PLIST_DIR overrides ~/Library/LaunchAgents;
// JOBRUN_HERMES_CRON overrides ~/.hermes/cron/jobs.json.
// --slack: JOBS_GRADE_SLACK_STATE (default ~/.local/state/jobs-grade/slack.json), JOBS_GRADE_SLACK_CHANNEL
// (default the #alerts channel), JOBS_GRADE_SLACK_TOKEN (default: `secrets-run read` of the bot token),
// JOBS_GRADE_SLACK_URL (default the Slack chat.postMessage endpoint; tests point it at a stub).
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { homedir, hostname } from "node:os"
import { dirname, join } from "node:path"

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

/** Declared by a plist, but jobrun never wrote a state file: not loaded = unloaded, past its first window = stale. */
export function gradeNeverRecorded(e: Expected, o: GradeOpts): Graded {
  const base = { label: e.label, owner: e.owner, rc: -1, consecutive_fail: 0, fails_24h: 0, last_ok: null, last_started: "", every: e.every }
  if (!o.loaded(e.label)) return { ...base, grade: "unloaded", reason: "declared by a plist but not loaded in launchd" }
  const windowS = windowSeconds(e.every ?? 0)
  const sinceInstallS = (o.now - e.installedAt) / 1000
  if (sinceInstallS > windowS) return { ...base, grade: "stale", reason: `never recorded, installed ${Math.round(sinceInstallS / 60)} min ago, window ${Math.round(windowS / 60)} min` }
  return { ...base, grade: "ok", reason: "not run yet, inside its first window" }
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
  const last = s.runs.slice(-RECOVERED_RUNS)
  return last.length === RECOVERED_RUNS && last.every((r) => r.rc === 0)
}

export function gradeAll(dir: string, o: GradeOpts): Graded[] {
  // A cron job runs inside the Hermes gateway, so it is loaded exactly when the gateway is.
  const cronLoaded = { ...o, loaded: (l: string) => o.loaded(l.startsWith(CRON_PREFIX) ? CRON_GATEWAY_LABEL : l) }
  const rows = [...readStates(dir).map((s) => gradeOne(s, o)), ...(o.cron ?? []).map((s) => gradeOne(s, cronLoaded))]
  const seen = new Set(rows.map((r) => r.label))
  for (const e of o.expected ?? []) {
    if (seen.has(e.label)) continue
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

/** One-line verdict for consumers that must not re-grade (heartbeat, doctor). Exit 0 = all ok, 2 = at least one is not. */
export function summarize(rows: Graded[]): { line: string; code: 0 | 2 } {
  const bad = rows.filter((r) => r.grade !== "ok")
  if (bad.length === 0) return { line: `jobs ok (${rows.length})`, code: 0 }
  return { line: `jobs WARN (${rows.length}): ${bad.map((r) => `${r.label}=${r.grade}`).join(", ")}`, code: 2 }
}

// --- Slack transitions ---------------------------------------------------------------------------
const SLACK_MAX_CHARS = 1500
const SLACK_DEFAULT_CHANNEL = "C0AS1LAUQ3C" // #alerts
const SLACK_DEFAULT_URL = "https://slack.com/api/chat.postMessage"
const SLACK_TOKEN_REF = "op://hermes/slack/bot-token"

export const defaultSlackState = () => process.env.JOBS_GRADE_SLACK_STATE || join(homedir(), ".local/state/jobs-grade/slack.json")
const shortHost = () => hostname().split(".")[0]

const clip = (text: string) => (text.length > SLACK_MAX_CHARS ? `${text.slice(0, SLACK_MAX_CHARS - 1)}…` : text)

/** What to tell Slack, given the not-ok set already announced (`prev`) and the current rows.
 *  `text` is null when nothing changed (same labels, same grades); `next` is the set to persist once the post lands. */
export function slackTransition(prev: Record<string, string>, rows: Graded[], host: string = shortHost()): { text: string | null; next: Record<string, string> } {
  const bad = rows.filter((r) => r.grade !== "ok")
  const next = Object.fromEntries(bad.map((r) => [r.label, r.grade]))
  const same = Object.keys(next).length === Object.keys(prev).length && Object.entries(next).every(([l, g]) => prev[l] === g)
  if (same) return { text: null, next }
  const head = `jobs-grade[${host}]:`
  if (bad.length === 0) {
    const was = Object.entries(prev).map(([l, g]) => `${l}=${g}`).join(", ")
    return { text: clip(`${head} all jobs ok again (was: ${was})`), next }
  }
  const list = bad.map((r) => `${r.label}=${r.grade} (${r.reason})`).join(", ")
  return { text: clip(`${head} ${bad.length} job(s) not ok — ${list}`), next }
}

function readSlackState(path: string): Record<string, string> {
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, "utf8"))
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return {}
    return Object.fromEntries(Object.entries(parsed).filter((e): e is [string, string] => typeof e[1] === "string"))
  } catch {
    return {} // missing or corrupt = nothing announced yet
  }
}

function slackToken(): string {
  const fromEnv = process.env.JOBS_GRADE_SLACK_TOKEN
  if (fromEnv) return fromEnv
  // launchd's PATH is minimal; secrets-run lives in ~/.local/bin
  const PATH = `${process.env.PATH ?? "/usr/bin:/bin"}:${join(homedir(), ".local/bin")}`
  const r = Bun.spawnSync(["secrets-run", "read", SLACK_TOKEN_REF], { env: { ...process.env, PATH }, stdout: "pipe", stderr: "ignore", timeout: 10_000 })
  const token = r.stdout.toString().trim()
  if (r.exitCode !== 0 || !token) throw new Error("no slack token (secrets-run read failed)")
  return token
}

async function postSlack(text: string): Promise<void> {
  const res = await fetch(process.env.JOBS_GRADE_SLACK_URL || SLACK_DEFAULT_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${slackToken()}` },
    body: JSON.stringify({ channel: process.env.JOBS_GRADE_SLACK_CHANNEL || SLACK_DEFAULT_CHANNEL, text }),
    signal: AbortSignal.timeout(10_000),
  })
  const body = (await res.json().catch(() => null)) as { ok?: boolean; error?: string } | null
  if (res.status !== 200 || body?.ok !== true) throw new Error(`http ${res.status}${body?.error ? ` ${body.error}` : ""}`)
}

/** Best-effort: announce a change in the not-ok set, then persist it. Never throws. */
export async function slackNotify(rows: Graded[], statePath: string = defaultSlackState()): Promise<void> {
  try {
    const { text, next } = slackTransition(readSlackState(statePath), rows)
    if (text === null) return
    await postSlack(text)
    mkdirSync(dirname(statePath), { recursive: true })
    writeFileSync(statePath, JSON.stringify(next))
  } catch (e) {
    console.error(`jobs-grade: slack post failed: ${(e as Error).message}`)
  }
}

if (import.meta.main) {
  const rows = gradeAll(defaultStateDir(), { now: Date.now(), loaded: isLoaded, expected: readExpected(defaultPlistDir()), cron: readCronStates(defaultCronJobs()) })
  if (process.argv.includes("--notify")) {
    const wake = Bun.spawnSync(["/usr/sbin/sysctl", "-n", "kern.waketime"], { stderr: "ignore" }).stdout.toString()
    const { line, code } = summarize(judgeAgainstAwake(rows, awakeSeconds(wake, Date.now())))
    if (code !== 0) notify(line)
    console.log(line)
    process.exit(code)
  }
  const slack = process.argv.includes("--slack")
  if (process.argv.includes("--summary")) {
    const { line, code } = summarize(rows)
    if (slack) await slackNotify(rows)
    console.log(line)
    process.exit(code)
  }
  if (process.argv.includes("--table")) {
    const { line, code } = summarize(rows)
    if (slack) await slackNotify(rows)
    console.log(`${renderTable(rows)}\n${line}`) // verdict is always the last line
    process.exit(code)
  }
  console.log(JSON.stringify(rows, null, 2))
}

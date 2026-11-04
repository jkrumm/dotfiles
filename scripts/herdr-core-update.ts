#!/usr/bin/env bun
// herdr-core-update — keep the herdr-core on this machine on the newest release that is at least a day old and not
// above the pin. Runs daily as com.jkrumm.herdr-core-update under jobrun (docs/herdr-core.md §Updates); `--dry` previews.
//
//   1. newest release whose manifest was published >= --min-age-hours ago and <= the pin
//      (config/herdr-core-max-version, or --max-version for a hand-run promotion); its sha256 is checked against the index
//   2. preflight: the launcher is built from this checkout's source (a stale one cannot keep a 0.1.17+ core in launchd)
//   3. bump the formula in the jkrumm/tap checkout (commit + push), `brew upgrade` it
//   4. `launchctl kickstart -k` the core
//   5. assert (assertCoreUp): launchd `state = running` on a new pid, stable for STABLE_S with `runs` not climbing,
//      the core is up (lib/core-up.sh), reports the new version from homebrew, is the job's child, every terminal kept
//      its pid; then `hc machine ls` versions match
//
// ANY failure from step 3 on rolls back: the formula back to the version that ran (commit + push, so the other machine
// does not install it either), `brew reinstall`, kickstart, the same assertion. The failed version is recorded in
// FAILED_FILE when the restarted core misbehaved, and not retried until that file is removed. The exit code grades the job red either way.
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { cpus, homedir, hostname, loadavg } from "node:os"
import { dirname, join } from "node:path"

const RELEASES = process.env.HERDR_RELEASES_URL || "https://releases.herdr.dev"
const LABEL = "com.jkrumm.herdr-core"
const FORMULA = "Formula/herdr-core.rb"
const MAX_LOOKBACK = 25
const SHA256 = /^[0-9a-f]{64}$/
const PIN_FILE = join(import.meta.dir, "..", "config", "herdr-core-max-version")
const LAUNCHER_SRC = join(import.meta.dir, "herdr-core-launcher.c")
const CORE_UP = join(import.meta.dir, "lib", "core-up.sh")
const LAUNCHER_MARKER = join(homedir(), ".local", "libexec", "herdr-core-launcher.src-sha")
export const FAILED_FILE = join(homedir(), ".local", "state", "herdr-core-update", "failed.json")
/** launchd respawns a job that exits every ThrottleInterval (10 s): a window of 30 s sees a respawn loop at least twice. */
export const STABLE_S = 30

export type Manifest = { version: string; targets: Record<string, { url: string; sha256: string }> }

export const parseVersion = (v: string): [number, number, number] | null => {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v.trim())
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null
}

/** <0, 0, >0 like a comparator. Unparseable versions throw: a guessed order could downgrade a core. */
export const cmpVersion = (a: string, b: string): number => {
  const pa = parseVersion(a)
  const pb = parseVersion(b)
  if (!pa || !pb) throw new Error(`cannot compare versions "${a}" and "${b}"`)
  return pa[0] - pb[0] || pa[1] - pb[1] || pa[2] - pb[2]
}

/** The release before this one on the patch line (0.1.15 -> 0.1.14); null at .0. Releases are sequential patches. */
export const previousVersion = (v: string): string | null => {
  const p = parseVersion(v)
  return p && p[2] > 0 ? `${p[0]}.${p[1]}.${p[2] - 1}` : null
}

export const ageHours = (publishedMs: number, nowMs: number): number => (nowMs - publishedMs) / 3_600_000

/**
 * Newest release at least `minAgeHours` old, walking down from `latest`. `published(v)` is the manifest's
 * publish time in ms, or null when the version does not exist.
 */
export async function pickCandidate(args: {
  latest: string
  published: (v: string) => Promise<number | null>
  minAgeHours: number
  nowMs: number
}): Promise<{ version: string; ageH: number } | { version: null; reason: string }> {
  const { latest, published, minAgeHours, nowMs } = args
  let v: string | null = latest
  for (let i = 0; v && i < MAX_LOOKBACK; i++, v = previousVersion(v)) {
    const at = await published(v)
    if (at === null) continue
    const ageH = ageHours(at, nowMs)
    if (ageH >= minAgeHours) return { version: v, ageH }
  }
  return { version: null, reason: `no release >= ${minAgeHours}h old within ${MAX_LOOKBACK} versions of ${latest}` }
}

export type Shas = { arm: string; intel: string }

/** Rewrite the version and both sha256 lines of the tap formula; throws when the shape is not what we wrote. */
export function bumpFormula(args: { src: string; version: string; shas: Shas }): string {
  const { src, version, shas } = args
  const out = src
    .replace(/^(\s*version\s+)"[^"]*"/m, `$1"${version}"`)
    .replace(/(sha256\s+)"[0-9a-f]{64}"(\s*# herdr-core-arm)/, `$1"${shas.arm}"$2`)
    .replace(/(sha256\s+)"[0-9a-f]{64}"(\s*# herdr-core-intel)/, `$1"${shas.intel}"$2`)
  if (!out.includes(`"${version}"`) || !out.includes(shas.arm) || !out.includes(shas.intel)) {
    throw new Error("formula does not have the version and two marked sha256 lines")
  }
  return out
}

export const formulaVersion = (src: string): string | null => /^\s*version\s+"([^"]*)"/m.exec(src)?.[1] ?? null

/** The pin: the first line of the file that is a version (comments start with #). Throws when there is none. */
export function parsePin(src: string): string {
  const v = src
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l && !l.startsWith("#"))
  if (!v || !parseVersion(v)) throw new Error(`the pin file holds no version (want one line like 0.1.17)`)
  return v
}

/** Where the walk down starts: latest, or the pin when latest is above it (an unverified release is never installed). */
export const capToPin = (latest: string, pin: string): string => (cmpVersion(latest, pin) > 0 ? pin : latest)

/**
 * Seconds to wait for a restarted core. 60 s is plenty on an idle machine, but the 2026-11-04 mini sat at a load
 * average of ~26-44 on 12 cores while waves ran, and a core start there (state load, holder re-adoption) is CPU-bound:
 * scale with load per core, capped so a forward attempt plus a rollback stays inside jobrun's 900 s timeout.
 */
export const readyTimeoutS = (load1: number, cores: number, base = 60, cap = 240): number =>
  Math.round(Math.min(cap, base * Math.max(1, load1 / Math.max(1, cores))))

// ---- the core on this machine: a port, so the restart/rollback logic is testable without launchd -----------------

export type Job = { state: string; pid: number; runs: number }
export type CoreStatus = { version: string; installed_by: string | null; pid: number }

export interface Host {
  /** launchd's view of com.jkrumm.herdr-core; null when not loaded. */
  job(): Job | null
  kickstart(): void
  /** lib/core-up.sh: job running AND the socket answers. Never starts a core. */
  coreUp(): boolean
  /** `hc server status`; call only after coreUp(). */
  status(): CoreStatus
  parentPid(pid: number): number
  /** Live local terminals -> pid. */
  terminalPids(): Record<string, number>
  /** What /opt/homebrew/opt/herdr-core/bin/herdr-core --version says ("hc 0.1.17"), "" when it does not run. */
  installedVersion(): string
  brewUpgrade(): void
  brewReinstall(): void
  /** Set the tap formula to this version (commit + push); no-op when it is already there. */
  setFormula(version: string, shas: Shas, message: string): void
  formulaVersion(): string | null
  sleep(ms: number): Promise<void>
  now(): number
  say(m: string): void
}

const say = (m: string) => console.log(`herdr-core-update: ${m}`)
class StepError extends Error {}
/** applyUpdate's failure. `restarted`: the new core was started and misbehaved (recorded, not retried); false: it failed
 * before the kickstart (brew, network, git), which the next run may retry. */
export class UpdateFailed extends StepError {
  constructor(
    message: string,
    readonly restarted: boolean,
  ) {
    super(message)
  }
}
const fail = (m: string): never => {
  throw new StepError(m)
}

async function waitFor<T>(host: Host, what: string, deadlineMs: number, probe: () => T | null): Promise<T> {
  let last = ""
  for (;;) {
    try {
      const v = probe()
      if (v !== null) return v
    } catch (e) {
      last = (e as Error).message
    }
    if (host.now() > deadlineMs) return fail(`${what}: not ready in time${last ? ` (${last.slice(0, 200)})` : ""}`)
    await host.sleep(1000)
  }
}

/**
 * After a kickstart: the core is up the way every consumer defines it, launchd supervises it, and nothing was lost.
 * Throws a StepError naming the first thing that is not so.
 */
export async function assertCoreUp(
  host: Host,
  args: { version: string; oldJobPid: number; before: Record<string, number>; timeoutS: number; stableS?: number },
): Promise<CoreStatus> {
  const { version, oldJobPid, before, timeoutS } = args
  const stableS = args.stableS ?? STABLE_S
  const deadline = host.now() + timeoutS * 1000
  const job = await waitFor(host, `launchd running ${LABEL} on a new pid`, deadline, () => {
    const j = host.job()
    return j && j.state === "running" && j.pid !== 0 && j.pid !== oldJobPid ? j : null
  })
  await waitFor(host, `core socket answering (lib/core-up.sh)`, deadline, () => (host.coreUp() ? true : null))
  const status = await waitFor(host, `core ${version} from homebrew`, deadline, () => {
    const s = host.status()
    return s.version === version && s.installed_by === "homebrew" ? s : null
  })
  // A core that escapes the launcher exits the job: launchd shows `running` for an instant per respawn, so the state
  // must hold on one pid with `runs` not climbing for a whole window (the 2026-11-04 incident: runs ~3600, never running).
  for (let waited = 0; waited < stableS; waited += 2) {
    await host.sleep(2000)
    const j = host.job()
    if (!j || j.state !== "running") fail(`launchd job not stable: state ${j?.state ?? "not loaded"} ${waited + 2}s after start (runs ${job.runs} -> ${j?.runs ?? "?"})`)
    if (j!.pid !== job.pid) fail(`launchd job not stable: pid ${job.pid} -> ${j!.pid} (runs ${job.runs} -> ${j!.runs})`)
    if (j!.runs !== job.runs) fail(`launchd job not stable: runs ${job.runs} -> ${j!.runs} (respawning)`)
  }
  if (!host.coreUp()) fail("core socket stopped answering within the stability window")
  const ppid = host.parentPid(status.pid)
  if (ppid !== job.pid) fail(`core pid ${status.pid} is not the job's child (parent ${ppid}, job pid ${job.pid}): it escaped the launcher`)
  const now = host.terminalPids()
  const lost = Object.entries(before).filter(([a, pid]) => now[a] !== pid)
  if (lost.length) fail(`terminals did not survive: ${lost.map(([a, p]) => `${a} (pid ${p} -> ${now[a] ?? "gone"})`).join(", ")}`)
  return status
}

/**
 * Install `target` over `previous` (both formula versions with verified shas) and prove it; on any failure roll back to
 * `previous` and throw naming what failed and how the rollback went.
 */
export async function applyUpdate(
  host: Host,
  args: { target: string; previous: string; shas: Shas; previousShas: () => Promise<Shas>; timeoutS: number; stableS?: number },
): Promise<CoreStatus> {
  const { target, previous, timeoutS, stableS } = args
  const before = host.terminalPids()
  let kicked = false
  try {
    host.setFormula(target, args.shas, `chore(herdr-core): update to ${target}`)
    // brew may already have installed it on an earlier run that died before the kickstart: reconcile, don't repeat
    if (!host.installedVersion().endsWith(target)) host.brewUpgrade()
    const installed = host.installedVersion()
    if (!installed.endsWith(target)) fail(`brew installed "${installed}", wanted ${target}`)
    const oldJobPid = host.job()?.pid ?? 0
    host.kickstart()
    kicked = true
    const after = await assertCoreUp(host, { version: target, oldJobPid, before, timeoutS, stableS })
    host.say(`core ${target} up: pid ${after.pid}, launchd stable ${stableS ?? STABLE_S}s, ${Object.keys(before).length} terminals kept their pids`)
    return after
  } catch (e) {
    const why = (e as Error).message
    host.say(`FAILED on ${target}: ${why}; rolling back to ${previous}`)
    let rolled: string
    try {
      await rollback(host, { previous, failed: target, shas: await args.previousShas(), before, kicked, timeoutS, stableS })
      rolled = `rolled back to ${previous}`
    } catch (r) {
      rolled = `ROLLBACK to ${previous} FAILED: ${(r as Error).message}`
    }
    throw new UpdateFailed(`${target}: ${why}; ${rolled}`, kicked)
  }
}

async function rollback(
  host: Host,
  args: { previous: string; failed: string; shas: Shas; before: Record<string, number>; kicked: boolean; timeoutS: number; stableS?: number },
): Promise<void> {
  const { previous, failed, before, timeoutS, stableS } = args
  // the shared formula goes back first: the other machine must not install what failed here
  if (host.formulaVersion() !== previous) host.setFormula(previous, args.shas, `revert(herdr-core): back to ${previous}, ${failed} failed on ${hostname().split(".")[0]}`)
  if (!host.installedVersion().endsWith(previous)) host.brewReinstall()
  const installed = host.installedVersion()
  if (!installed.endsWith(previous)) fail(`brew reinstall gave "${installed}", wanted ${previous}`)
  const j = host.job()
  let healthy = false
  try {
    healthy = j?.state === "running" && host.coreUp() && host.status().version === previous
  } catch {
    // not answering: restart it below
  }
  if (!args.kicked && healthy) return
  host.kickstart()
  await assertCoreUp(host, { version: previous, oldJobPid: j?.pid ?? 0, before, timeoutS, stableS })
  host.say(`rolled back: core ${previous} up, terminals kept their pids`)
}

// ---- the real host ----------------------------------------------------------------------------------------------

function sh(cmd: string[], opts: { cwd?: string; allowFail?: boolean; env?: Record<string, string> } = {}): string {
  const p = Bun.spawnSync(cmd, { cwd: opts.cwd, env: { ...process.env, ...opts.env }, stdout: "pipe", stderr: "pipe" })
  const out = p.stdout.toString() + p.stderr.toString()
  if (p.exitCode !== 0 && !opts.allowFail) fail(`${cmd.join(" ")} -> rc ${p.exitCode}: ${out.trim().slice(-400)}`)
  return p.stdout.toString()
}

const hcJson = (...args: string[]) => JSON.parse(sh(["hc", ...args, "--json"]))
const BREW_ENV = { HOMEBREW_NO_AUTO_UPDATE: "1", HOMEBREW_NO_ENV_HINTS: "1" }

export const parseJob = (print: string): Job | null => {
  const state = /^\s*state = (.+)$/m.exec(print)?.[1]?.trim()
  if (!state) return null
  return { state, pid: Number(/^\s*pid = (\d+)/m.exec(print)?.[1] ?? 0), runs: Number(/^\s*runs = (\d+)/m.exec(print)?.[1] ?? 0) }
}

function realHost(): Host & { tap: () => string } {
  const domain = `gui/${process.getuid?.()}/${LABEL}`
  let tapDir = ""
  const tap = () => (tapDir ||= sh(["brew", "--repository", "jkrumm/tap"]).trim())
  return {
    tap,
    job: () => parseJob(sh(["launchctl", "print", domain], { allowFail: true })),
    kickstart: () => void sh(["launchctl", "kickstart", "-k", domain]),
    coreUp: () => Bun.spawnSync(["/bin/bash", CORE_UP], { stdout: "ignore", stderr: "ignore" }).exitCode === 0,
    status: () => hcJson("server", "status"),
    parentPid: (pid) => Number(sh(["ps", "-o", "ppid=", "-p", String(pid)], { allowFail: true }).trim() || 0),
    terminalPids: () => {
      const out: Record<string, number> = {}
      const ls = hcJson("ls") as { terminals: { address: string; state: string }[] }
      for (const t of ls.terminals) {
        // linked machines' terminals ("mini/t5") are not ours
        if (t.state !== "live" || t.address.includes("/")) continue
        // 0 when the core reports none: the terminal still has to be there after the restart
        out[t.address] = (hcJson("get", t.address) as { pid: number | null }).pid ?? 0
      }
      return out
    },
    installedVersion: () => sh(["/opt/homebrew/opt/herdr-core/bin/herdr-core", "--version"], { allowFail: true }).trim(),
    brewUpgrade: () => void sh(["brew", "upgrade", "jkrumm/tap/herdr-core"], { env: BREW_ENV }),
    brewReinstall: () => void sh(["brew", "reinstall", "jkrumm/tap/herdr-core"], { env: BREW_ENV }),
    formulaVersion: () => formulaVersion(readFileSync(join(tap(), FORMULA), "utf8")),
    setFormula: (version, shas, message) => {
      const dir = tap()
      const path = join(dir, FORMULA)
      if (sh(["git", "status", "--porcelain", "--", FORMULA], { cwd: dir }).trim()) fail(`${path} has uncommitted changes; refusing to publish them`)
      sh(["git", "pull", "--ff-only", "-q"], { cwd: dir })
      // a commit a failed push left behind on an earlier run is published first
      if (Number(sh(["git", "rev-list", "--count", "@{u}..HEAD"], { cwd: dir }).trim()) > 0) sh(["git", "push", "-q"], { cwd: dir })
      const src = readFileSync(path, "utf8")
      if (formulaVersion(src) === version) return
      writeFileSync(path, bumpFormula({ src, version, shas }))
      // pathspec commit: an unrelated change staged in the shared tap checkout is not swept in
      sh(["git", "commit", "-q", "-m", message, "--", FORMULA], { cwd: dir })
      try {
        sh(["git", "push", "-q"], { cwd: dir })
      } catch {
        // the other machine pushed first
        sh(["git", "pull", "--rebase", "-q"], { cwd: dir })
        sh(["git", "push", "-q"], { cwd: dir })
      }
      say(`formula set to ${version}`)
    },
    sleep: (ms) => Bun.sleep(ms),
    now: () => Date.now(),
    say,
  }
}

async function fetchManifest(version: string | "latest"): Promise<Manifest | null> {
  const url = version === "latest" ? `${RELEASES}/core/latest.json` : `${RELEASES}/core/${version}/manifest.json`
  const r = await fetch(url)
  if (r.status === 404) return null
  if (!r.ok) fail(`${url} -> HTTP ${r.status}`)
  return (await r.json()) as Manifest
}

async function publishedMs(version: string): Promise<number | null> {
  const r = await fetch(`${RELEASES}/core/${version}/manifest.json`, { method: "HEAD" })
  if (r.status === 404) return null
  if (!r.ok) fail(`manifest ${version} -> HTTP ${r.status}`)
  const lm = r.headers.get("last-modified")
  if (!lm) fail(`manifest ${version} has no Last-Modified; cannot date the release`)
  const at = Date.parse(lm as string)
  if (Number.isNaN(at)) fail(`manifest ${version} has an unparseable Last-Modified "${lm}"`)
  return at
}

async function verifiedSha(manifest: Manifest, target: string): Promise<string> {
  const t = manifest.targets[target]
  if (!t) return fail(`manifest ${manifest.version} has no ${target}`)
  if (!SHA256.test(t.sha256)) fail(`${target} sha256 in the index is not 64 lowercase hex characters`)
  const r = await fetch(t.url)
  if (!r.ok) fail(`${t.url} -> HTTP ${r.status}`)
  const got = createHash("sha256").update(new Uint8Array(await r.arrayBuffer())).digest("hex")
  if (got !== t.sha256) fail(`${target} sha256 mismatch: index ${t.sha256}, download ${got}`)
  return t.sha256
}

async function verifiedShas(version: string): Promise<Shas> {
  const manifest = await fetchManifest(version)
  if (!manifest) return fail(`release ${version} has no manifest`)
  return { arm: await verifiedSha(manifest, "macos-aarch64"), intel: await verifiedSha(manifest, "macos-x86_64") }
}

/** The launcher this checkout builds: a stale one (no HC_LAUNCHD_DIRECT) cannot keep a 0.1.17+ core in launchd. */
function launcherCurrent(): string | null {
  const want = createHash("sha256").update(readFileSync(LAUNCHER_SRC)).digest("hex")
  const have = existsSync(LAUNCHER_MARKER) ? readFileSync(LAUNCHER_MARKER, "utf8").split(/\s+/)[0] : ""
  return have === want ? null : `the launcher (${LAUNCHER_MARKER}) is not built from this checkout's scripts/herdr-core-launcher.c`
}

type Linked = { name: string; state: string; version?: string }
const linkedMachines = (): Linked[] => (hcJson("machine", "ls") as { machines: Linked[] }).machines

/** After the local update: every linked machine runs the same version. The MacBook nudges the mini's own job. */
async function assertParity(host: Host, version: string, dry: boolean): Promise<void> {
  for (const m of linkedMachines()) {
    if (m.version === version) continue
    if (dry) {
      say(`parity: ${m.name} is on ${m.version ?? "?"} (would nudge its update job)`)
      continue
    }
    say(`parity: ${m.name} is on ${m.version ?? "?"}, starting its update job`)
    sh(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", m.name, `launchctl kickstart gui/$(id -u)/${JOB_LABEL}`])
    await waitFor(host, `${m.name} on ${version}`, Date.now() + 300_000, () => (linkedMachines().find((x) => x.name === m.name)?.version === version ? true : null))
  }
}

const JOB_LABEL = "com.jkrumm.herdr-core-update"

type Failed = { version: string; at: string; reason: string }
const readFailed = (): Failed | null => (existsSync(FAILED_FILE) ? (JSON.parse(readFileSync(FAILED_FILE, "utf8")) as Failed) : null)

async function main() {
  const args = process.argv.slice(2)
  const dry = args.includes("--dry")
  const opt = (name: string) => (args.indexOf(name) >= 0 ? args[args.indexOf(name) + 1] : undefined)
  const minAgeHours = opt("--min-age-hours") !== undefined ? Number(opt("--min-age-hours")) : 24
  if (!Number.isFinite(minAgeHours)) fail("--min-age-hours needs a number")
  const pinArg = opt("--max-version")
  if (pinArg !== undefined && !parseVersion(pinArg)) fail("--max-version needs a version like 0.1.18")
  const pin = pinArg ?? parsePin(readFileSync(PIN_FILE, "utf8"))
  const host = realHost()

  // never an hc call while the core is down: it would start one outside launchd
  if (!host.coreUp()) fail(`the core is not up before the update (bash ${CORE_UP} says why); nothing changed`)
  const status = host.status()
  say(`${hostname().split(".")[0]}: core ${status.version}, installed_by=${status.installed_by}, pin ${pin}${pinArg ? " (--max-version)" : ""}`)
  if (status.installed_by !== "homebrew") {
    const why = `core is not managed by homebrew (installed_by=${status.installed_by}); run: make herdr-core-setup`
    if (!dry) fail(why)
    say(`dry: a real run would fail here: ${why}`)
  }

  const latest = await fetchManifest("latest")
  if (!latest) return fail("latest.json missing")
  const from = capToPin(latest.version, pin)
  if (from !== latest.version) {
    say(`latest ${latest.version} is above the pin ${pin} (config/herdr-core-max-version): not installed unattended; verify it by hand and move the pin (docs/herdr-core.md §Updates)`)
  }
  const pick = await pickCandidate({ latest: from, published: publishedMs, minAgeHours, nowMs: Date.now() })
  if (!pick.version) {
    // e.g. a fresh X.Y.0 with nothing older on its line: wait until it ages instead of grading red
    say(`nothing to install yet: ${pick.reason}; staying on ${status.version}`)
    await assertParity(host, status.version, dry)
    return
  }
  say(`candidate ${pick.version} (published ${pick.ageH.toFixed(1)}h ago, latest is ${latest.version})`)

  if (cmpVersion(pick.version, status.version) <= 0) {
    say(`up to date (${status.version})`)
    await assertParity(host, status.version, dry)
    return
  }

  const failed = readFailed()
  if (failed && failed.version === pick.version) {
    fail(`${pick.version} failed here on ${failed.at} and was rolled back (${failed.reason}); not retried. Fix the cause, then rm ${FAILED_FILE}`)
  }
  const stale = launcherCurrent()
  if (stale) fail(`${stale}: run make herdr-core-setup first; nothing changed`)

  const shas = await verifiedShas(pick.version)
  say(`sha256 of both macOS artifacts verified against the index (${shas.arm.slice(0, 12)}…)`)
  const onFormula = host.formulaVersion()
  // the other machine may already have bumped past our candidate (it only ever bumps to a release >= 24 h old):
  // never publish a downgrade, install what the formula says, but never above the pin
  const target = onFormula && cmpVersion(onFormula, pick.version) > 0 ? onFormula : pick.version
  if (cmpVersion(target, pin) > 0) fail(`the tap formula is at ${target}, above the pin ${pin}: refusing (is the other machine's dotfiles behind?)`)
  const timeoutS = readyTimeoutS(loadavg()[0], cpus().length)
  if (dry) {
    say(`dry: would set ${FORMULA} to ${target}, brew upgrade, kickstart ${LABEL}, assert launchd stable ${STABLE_S}s + socket + pids within ${timeoutS}s, roll back to ${status.version} on any failure`)
    await assertParity(host, target, true)
    return
  }

  try {
    await applyUpdate(host, {
      target,
      previous: status.version,
      shas: target === pick.version ? shas : await verifiedShas(target),
      previousShas: () => verifiedShas(status.version),
      timeoutS,
    })
  } catch (e) {
    // only a core that was started and misbehaved blocks the version; a brew or network failure may be retried tomorrow
    if (e instanceof UpdateFailed && e.restarted) {
      mkdirSync(dirname(FAILED_FILE), { recursive: true })
      writeFileSync(FAILED_FILE, JSON.stringify({ version: target, at: new Date().toISOString(), reason: e.message }) + "\n")
    }
    throw e
  }
  if (failed) rmSync(FAILED_FILE, { force: true })
  await assertParity(host, target, false)
}

if (import.meta.main) {
  main().catch((e) => {
    console.log(`herdr-core-update: FAILED: ${(e as Error).message}`)
    process.exit(1)
  })
}

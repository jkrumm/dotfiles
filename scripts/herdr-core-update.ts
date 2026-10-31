#!/usr/bin/env bun
// herdr-core-update — keep the herdr-core on this machine on the newest release that is at least a day old.
// Runs daily as com.jkrumm.herdr-core-update under jobrun (docs/herdr-core.md §Updates); `--dry` previews.
//
//   1. newest release whose manifest was published >= --min-age-hours ago; its sha256 is checked against the index
//   2. bump the formula in the jkrumm/tap checkout (commit + push), `brew upgrade` it
//   3. `launchctl kickstart -k` the core
//   4. assert: same terminal pids as before, `hc machine ls` versions match
//
// Any failed step before the kickstart leaves the old core running; the exit code grades the job red.
import { createHash } from "node:crypto"
import { readFileSync, writeFileSync } from "node:fs"
import { hostname } from "node:os"
import { join } from "node:path"

const RELEASES = process.env.HERDR_RELEASES_URL || "https://releases.herdr.dev"
const LABEL = "com.jkrumm.herdr-core"
const FORMULA = "Formula/herdr-core.rb"
const MAX_LOOKBACK = 25
const SHA256 = /^[0-9a-f]{64}$/

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

// ---- effects ---------------------------------------------------------------------------------

const say = (m: string) => console.log(`herdr-core-update: ${m}`)
class StepError extends Error {}
const fail = (m: string): never => {
  throw new StepError(m)
}

function sh(cmd: string[], opts: { cwd?: string; allowFail?: boolean; env?: Record<string, string> } = {}): string {
  const p = Bun.spawnSync(cmd, { cwd: opts.cwd, env: { ...process.env, ...opts.env }, stdout: "pipe", stderr: "pipe" })
  const out = p.stdout.toString() + p.stderr.toString()
  if (p.exitCode !== 0 && !opts.allowFail) fail(`${cmd.join(" ")} -> rc ${p.exitCode}: ${out.trim().slice(-400)}`)
  return p.stdout.toString()
}

const hcJson = (...args: string[]) => JSON.parse(sh(["hc", ...args, "--json"]))

type CoreStatus = { version: string; installed_by: string | null; pid: number }
const coreStatus = (): CoreStatus => hcJson("server", "status")

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

/** Live local terminals -> pid. Linked machines' terminals ("mini/t5") are not ours. */
function terminalPids(): Record<string, number> {
  const out: Record<string, number> = {}
  const ls = hcJson("ls") as { terminals: { address: string; state: string }[] }
  for (const t of ls.terminals) {
    if (t.state !== "live" || t.address.includes("/")) continue
    // 0 when the core reports none: the terminal still has to be there after the restart
    out[t.address] = (hcJson("get", t.address) as { pid: number | null }).pid ?? 0
  }
  return out
}

async function waitFor<T>(what: string, secs: number, probe: () => T | null): Promise<T> {
  const end = Date.now() + secs * 1000
  for (;;) {
    try {
      const v = probe()
      if (v !== null) return v
    } catch {
      // not up yet
    }
    if (Date.now() > end) return fail(`${what}: not ready after ${secs}s`)
    await Bun.sleep(1000)
  }
}

type Machine = { name: string; state: string; version?: string }
const linkedMachines = (): Machine[] => (hcJson("machine", "ls") as { machines: Machine[] }).machines

/** After the local update: every linked machine runs the same version. The MacBook nudges the mini's own job. */
async function assertParity(version: string, dry: boolean): Promise<void> {
  for (const m of linkedMachines()) {
    if (m.version === version) continue
    if (dry) {
      say(`parity: ${m.name} is on ${m.version ?? "?"} (would nudge its update job)`)
      continue
    }
    say(`parity: ${m.name} is on ${m.version ?? "?"}, starting its update job`)
    sh(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", m.name, `launchctl kickstart gui/$(id -u)/${JOB_LABEL}`])
    await waitFor(`${m.name} on ${version}`, 300, () => (linkedMachines().find((x) => x.name === m.name)?.version === version ? true : null))
  }
}

const JOB_LABEL = "com.jkrumm.herdr-core-update"

async function main() {
  const args = process.argv.slice(2)
  const dry = args.includes("--dry")
  const mi = args.indexOf("--min-age-hours")
  const minAgeHours = mi >= 0 ? Number(args[mi + 1]) : 24
  if (!Number.isFinite(minAgeHours)) fail("--min-age-hours needs a number")

  const status = coreStatus()
  say(`${hostname().split(".")[0]}: core ${status.version}, installed_by=${status.installed_by}`)
  if (status.installed_by !== "homebrew") {
    fail(`core is not managed by homebrew (installed_by=${status.installed_by}); run: make herdr-core-setup`)
  }

  const latest = await fetchManifest("latest")
  if (!latest) return fail("latest.json missing")
  const pick = await pickCandidate({ latest: latest.version, published: publishedMs, minAgeHours, nowMs: Date.now() })
  if (!pick.version) {
    // e.g. a fresh X.Y.0 with nothing older on its line: wait until it ages instead of grading red
    say(`nothing to install yet: ${pick.reason}; staying on ${status.version}`)
    await assertParity(status.version, dry)
    return
  }
  say(`candidate ${pick.version} (published ${pick.ageH.toFixed(1)}h ago, latest is ${latest.version})`)

  if (cmpVersion(pick.version, status.version) <= 0) {
    say(`up to date (${status.version})`)
    await assertParity(status.version, dry)
    return
  }

  const manifest = (await fetchManifest(pick.version)) as Manifest
  const arm = await verifiedSha(manifest, "macos-aarch64")
  const intel = await verifiedSha(manifest, "macos-x86_64")
  say(`sha256 of both macOS artifacts verified against the index (${arm.slice(0, 12)}…)`)

  const tap = sh(["brew", "--repository", "jkrumm/tap"]).trim()
  const formulaPath = join(tap, FORMULA)
  if (dry) {
    say(`dry: would bump ${FORMULA} to ${pick.version}, brew upgrade, kickstart ${LABEL}, assert pids and parity`)
    await assertParity(pick.version, true)
    return
  }

  if (sh(["git", "status", "--porcelain", "--", FORMULA], { cwd: tap }).trim()) fail(`${formulaPath} has uncommitted changes; refusing to publish them`)
  sh(["git", "pull", "--ff-only", "-q"], { cwd: tap })
  // a commit a failed push left behind on an earlier run is published first
  if (Number(sh(["git", "rev-list", "--count", "@{u}..HEAD"], { cwd: tap }).trim()) > 0) sh(["git", "push", "-q"], { cwd: tap })
  const src = readFileSync(formulaPath, "utf8")
  const onFormula = formulaVersion(src)
  // the other machine may already have bumped past our candidate (it only ever bumps to a release >= 24 h old):
  // never publish a downgrade, install what the formula says
  const target = onFormula && cmpVersion(onFormula, pick.version) > 0 ? onFormula : pick.version
  if (onFormula !== target) {
    writeFileSync(formulaPath, bumpFormula({ src, version: target, shas: { arm, intel } }))
    // pathspec commit: an unrelated change staged in the shared tap checkout is not swept in
    sh(["git", "commit", "-q", "-m", `chore(herdr-core): update to ${target}`, "--", FORMULA], { cwd: tap })
    try {
      sh(["git", "push", "-q"], { cwd: tap })
    } catch {
      // the other machine bumped first
      sh(["git", "pull", "--rebase", "-q"], { cwd: tap })
      sh(["git", "push", "-q"], { cwd: tap })
    }
    say(`formula bumped to ${target}`)
  }
  // brew may already have installed it on an earlier run that died before the kickstart: reconcile, don't repeat
  const brewVersion = () => sh(["/opt/homebrew/opt/herdr-core/bin/herdr-core", "--version"], { allowFail: true }).trim()
  if (!brewVersion().endsWith(target)) {
    sh(["brew", "upgrade", "jkrumm/tap/herdr-core"], { env: { HOMEBREW_NO_AUTO_UPDATE: "1", HOMEBREW_NO_ENV_HINTS: "1" } })
  }
  const installed = brewVersion()
  if (!installed.endsWith(target)) fail(`brew installed "${installed}", wanted ${target}`)

  const before = terminalPids()
  const domain = `gui/${process.getuid?.()}/${LABEL}`
  const jobPid = () => Number(/\bpid = (\d+)/.exec(sh(["launchctl", "print", domain], { allowFail: true }))?.[1] ?? 0)
  const oldJobPid = jobPid()
  sh(["launchctl", "kickstart", "-k", domain])
  // Wait for launchd's own new core before any hc call: a client call with no core listening auto-starts one
  // outside launchd (and outside the launcher's Full Disk Access).
  await waitFor("launchd restarted the core job", 30, () => {
    const pid = jobPid()
    return pid !== 0 && pid !== oldJobPid ? true : null
  })
  await Bun.sleep(1500)
  const after = await waitFor(`core ${target} up`, 60, () => {
    const s = coreStatus()
    return s.version === target && s.installed_by === "homebrew" ? s : null
  })
  say(`core restarted: pid ${status.pid} -> ${after.pid}, version ${after.version}`)

  const now = terminalPids()
  const lost = Object.entries(before).filter(([a, pid]) => now[a] !== pid)
  if (lost.length) fail(`terminals did not survive: ${lost.map(([a, p]) => `${a} (pid ${p} -> ${now[a] ?? "gone"})`).join(", ")}`)
  say(`${Object.keys(before).length} terminals kept their pids`)

  await assertParity(target, false)
}

if (import.meta.main) {
  main().catch((e) => {
    console.log(`herdr-core-update: FAILED: ${(e as Error).message}`)
    process.exit(1)
  })
}

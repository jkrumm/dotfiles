#!/usr/bin/env bun
// The mini's service registry: every launchd job, compose container, VM, static door and dev server on
// the Mac mini with its tier, memory budget and start/stop verbs. docs/mini-registry.md.
//
//   mini-registry ps    [--format table|json]    tier, state, footprint against budget, drift
//   mini-registry check                          drift and budget findings only; exit 1 on drift, 2 on a budget breach
//   mini-registry up    NAME                     start what NAME needs first, then NAME
//   mini-registry down  NAME [--force]           stop NAME; a core service needs --force
//   mini-registry profile NAME --up|--down       every manual service of a profile (work, dev-db)
//
// The registry is config/mini/services.yaml plus, beside it, a `mini-services.yaml` at the root of any repo
// under ~/SourceRoot and ~/IuRoot, so a repo that adds a job registers it in the same commit.
// A verb runs only a command the registry holds (or launchctl for a launchd job without one): a name
// from the command line selects an entry, it never reaches a shell.

import { existsSync, readFileSync, readdirSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const HOME = homedir()
const DOTFILES = join(import.meta.dir, "..")
const HOST_FILE = join(DOTFILES, "config", "mini", "services.yaml")
const REPO_FILE = "mini-services.yaml"
const CHECK_DEADLINE_MS = 30000

export const KINDS = ["launchd", "compose", "vm", "static", "dev-server"] as const
export const TIERS = ["core", "on-demand", "manual"] as const
export const PROFILES = ["work", "dev-db"] as const
export type Kind = (typeof KINDS)[number]
export type Tier = (typeof TIERS)[number]

export type Service = {
  name: string
  repo: string
  kind: Kind
  tier: Tier
  profile?: string
  needs: string[]
  memory_mib: number
  doors: string[]
  // launchd: the label (a brew service matches either sh.brew.<n> or homebrew.mxcl.<n>); daemon: a system-domain job
  label?: string
  daemon?: boolean
  // compose: the container name and the Colima profile whose VM runs it
  container?: string
  project?: string
  vm?: string
  // a process name (top's COMMAND column) for a job whose tree is not rooted in a launchd pid
  process?: string
  // Postgres: every process's footprint counts the shared buffers again
  shared_memory?: boolean
  start?: string
  stop?: string
  status?: string
  note?: string
}

export type Loaded = { services: Service[]; errors: string[] }

const FAMILY = /^(com\.jkrumm\.|com\.iu\.|ai\.hermes\.|homebrew\.mxcl\.|sh\.brew\.|com\.colima\.)/
const NAME = /^[a-z0-9][a-z0-9.-]*$/
const BREW = /^(sh\.brew|homebrew\.mxcl)\./

// ---------------------------------------------------------------- registry

export function expand(text: string, home = HOME): string {
  return text.replaceAll("${HOME}", home).replaceAll("~/", `${home}/`)
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v.trim() ? v.trim() : undefined)

export function parseRegistry(text: string, source: string, repoDefault?: string, home = HOME): Loaded {
  const errors: string[] = []
  let doc: unknown
  try {
    doc = Bun.YAML.parse(text)
  } catch (e) {
    return { services: [], errors: [`${source}: ${(e as Error).message}`] }
  }
  const rows = (doc as { services?: unknown })?.services
  if (!Array.isArray(rows)) return { services: [], errors: [`${source}: no services list`] }
  const services: Service[] = []
  for (const raw of rows as Record<string, unknown>[]) {
    const name = str(raw?.name)
    const at = `${source}: ${name ?? JSON.stringify(raw)}`
    const err = (m: string) => errors.push(`${at}: ${m}`)
    if (!name || !NAME.test(name)) { err("name missing or not [a-z0-9.-]"); continue }
    const kind = raw.kind as Kind
    const tier = raw.tier as Tier
    if (!KINDS.includes(kind)) err(`kind must be one of ${KINDS.join(", ")}`)
    if (!TIERS.includes(tier)) err(`tier must be one of ${TIERS.join(", ")}`)
    const profile = str(raw.profile)
    if (profile && tier !== "manual") err("profile is only for tier manual")
    if (profile && !PROFILES.includes(profile as (typeof PROFILES)[number])) err(`profile must be one of ${PROFILES.join(", ")}`)
    const budget = raw.memory_mib
    if (typeof budget !== "number" || budget < 0) err("memory_mib must be a number of MiB")
    const repo = str(raw.repo) ?? repoDefault
    if (!repo) err("repo missing")
    const door = raw.door
    const doors = door == null ? [] : Array.isArray(door) ? door.map(String) : [String(door)]
    const needs = Array.isArray(raw.needs) ? raw.needs.map(String) : raw.needs == null ? [] : [String(raw.needs)]
    const s: Service = {
      name, repo: repo ?? "", kind, tier, profile, needs, memory_mib: typeof budget === "number" ? budget : 0, doors,
      label: str(raw.label), daemon: raw.daemon === true, container: str(raw.container), project: str(raw.project),
      vm: str(raw.vm), process: str(raw.process), shared_memory: raw.shared_memory === true,
      start: str(raw.start) && expand(str(raw.start)!, home), stop: str(raw.stop) && expand(str(raw.stop)!, home),
      status: str(raw.status) && expand(str(raw.status)!, home), note: str(raw.note),
    }
    if (kind === "launchd" && !s.label) err("a launchd service needs a label")
    if (kind === "compose" && !s.container) err("a compose service needs a container")
    if (kind === "compose" && !s.vm) s.vm = "default"
    if (kind === "vm" && !s.process && !s.vm) err("a vm service needs vm: <colima profile>")
    services.push(s)
  }
  return { services, errors }
}

export function validate(services: Service[]): string[] {
  const errors: string[] = []
  const names = new Set<string>()
  const labels = new Map<string, string>()
  const containers = new Map<string, string>()
  for (const s of services) {
    if (names.has(s.name)) errors.push(`duplicate name ${s.name}`)
    names.add(s.name)
    if (s.label) {
      const key = normalizeLabel(s.label)
      if (labels.has(key)) errors.push(`label ${s.label} registered by ${labels.get(key)} and ${s.name}`)
      labels.set(key, s.name)
    }
    if (s.container) {
      const key = `${s.vm}/${s.container}`
      if (containers.has(key)) errors.push(`container ${key} registered by ${containers.get(key)} and ${s.name}`)
      containers.set(key, s.name)
    }
  }
  // a command shared by two services of one project acts on both: a single-service verb would start or stop its neighbour
  for (const verb of ["start", "stop"] as const) {
    const seen = new Map<string, string>()
    for (const s of services.filter((x) => x.kind === "compose" && x[verb])) {
      const key = `${s.vm}/${s.project ?? ""}/${s[verb]}`
      if (seen.has(key)) errors.push(`${s.name} and ${seen.get(key)} share the ${verb} command of one compose project (${s[verb]}); it acts on both, so register a per-service command or none`)
      else seen.set(key, s.name)
    }
  }
  for (const s of services) {
    for (const n of s.needs) {
      const dep = resolveNeed(s, n)
      if (!services.some((o) => o.name === dep)) errors.push(`${s.name}: needs ${n}, no service ${dep}`)
    }
  }
  return errors
}

export function loadAll(roots = defaultRoots(), hostFile = HOST_FILE, home = HOME): Loaded {
  const out: Loaded = { services: [], errors: [] }
  const files: [string, string | undefined][] = [[hostFile, undefined]]
  for (const root of roots) {
    if (!existsSync(root)) continue
    for (const d of readdirSync(root, { withFileTypes: true })) {
      if (d.isDirectory() && existsSync(join(root, d.name, REPO_FILE))) files.push([join(root, d.name, REPO_FILE), d.name])
    }
  }
  for (const [file, repo] of files) {
    if (!existsSync(file)) { out.errors.push(`${file}: not found`); continue }
    const r = parseRegistry(readFileSync(file, "utf8"), file.replace(`${home}/`, "~/"), repo, home)
    out.services.push(...r.services)
    out.errors.push(...r.errors)
  }
  out.errors.push(...validate(out.services))
  return out
}

function defaultRoots(): string[] {
  const env = process.env.MINI_REGISTRY_ROOTS
  return env ? env.split(":").filter(Boolean) : [join(HOME, "SourceRoot"), join(HOME, "IuRoot")]
}

export function normalizeLabel(label: string): string {
  return label.replace(BREW, "brew:")
}

// `needs: [vm]` is the Colima VM of the service's own profile; anything else is a service name.
export function resolveNeed(s: Service, need: string): string {
  return need === "vm" ? `colima-${s.vm ?? "default"}` : need
}

// ---------------------------------------------------------------- live probes

export type Proc = { pid: number; ppid: number; mib: number; cmd: string }

// `top -l 1 -stats pid,ppid,mem,command`: MEM is the physical footprint, `1747M`, `994M `, `8785K`, `1G`, with a +/- trend mark.
export function parseTop(out: string): Proc[] {
  const procs: Proc[] = []
  for (const line of out.split("\n")) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+(?:\.\d+)?)([KMGB]?)[+-]?\s+(\S.*?)\s*$/)
    if (!m) continue
    const n = Number(m[3])
    const mib = m[4] === "K" ? n / 1024 : m[4] === "G" ? n * 1024 : m[4] === "B" ? n / 1048576 : n
    procs.push({ pid: Number(m[1]), ppid: Number(m[2]), mib, cmd: m[5] })
  }
  return procs
}

export function treePids(root: number, procs: Proc[]): Proc[] {
  const byParent = new Map<number, Proc[]>()
  for (const p of procs) byParent.set(p.ppid, [...(byParent.get(p.ppid) ?? []), p])
  const out: Proc[] = []
  const seen = new Set<number>()
  const walk = (pid: number) => {
    if (seen.has(pid)) return
    seen.add(pid)
    const self = procs.find((p) => p.pid === pid)
    if (self) out.push(self)
    for (const c of byParent.get(pid) ?? []) walk(c.pid)
  }
  walk(root)
  return out
}

// A backend's private memory is small; whatever a Postgres process shows above this is shared buffers it touched.
export const PRIVATE_CAP_MIB = 32

export function footprint(tree: Proc[], sharedMemory = false): number {
  if (!sharedMemory) return tree.reduce((a, p) => a + p.mib, 0)
  // every process's footprint counts the shared buffers again: the largest process plus the others' private part
  const sorted = [...tree].sort((a, b) => b.mib - a.mib)
  return sorted.reduce((a, p, i) => a + (i === 0 ? p.mib : Math.min(p.mib, PRIVATE_CAP_MIB)), 0)
}

export type LaunchctlRow = { pid: number | null; status: number; label: string }
export function parseLaunchctlList(out: string): LaunchctlRow[] {
  const rows: LaunchctlRow[] = []
  for (const line of out.split("\n").slice(1)) {
    const [pid, status, label] = line.split("\t")
    if (!label) continue
    rows.push({ pid: pid === "-" ? null : Number(pid), status: Number(status), label: label.trim() })
  }
  return rows
}

export function parseDisabled(out: string): Set<string> {
  const set = new Set<string>()
  for (const m of out.matchAll(/"([^"]+)"\s*=>\s*(disabled|true)\b/g)) set.add(m[1])
  return set
}

export type Container = { name: string; project: string; state: string; mib: number | null }

export function parseContainers(ps: string, stats: string): Container[] {
  const mem = new Map<string, number>()
  for (const line of stats.split("\n")) {
    const m = line.match(/^(\S+)\|([\d.]+)\s*(B|KiB|MiB|GiB|kB|MB|GB)\b/)
    if (!m) continue
    const n = Number(m[2])
    const f: Record<string, number> = { B: 1 / 1048576, KiB: 1 / 1024, kB: 1 / 1048.576, MiB: 1, MB: 0.953674, GiB: 1024, GB: 953.674 }
    mem.set(m[1], n * f[m[3]])
  }
  const out: Container[] = []
  for (const line of ps.split("\n")) {
    const [name, project, state] = line.split("|")
    if (!name) continue
    out.push({ name, project: project ?? "", state: state ?? "", mib: mem.get(name) ?? null })
  }
  return out
}

export type Plist = { label: string; path: string; program: string; domain: "gui" | "system" }

export type Snapshot = {
  uid: number
  procs: Proc[]
  loaded: LaunchctlRow[]
  disabled: Set<string>
  plists: Plist[]
  systemRunning: Set<string>
  vms: Map<string, { running: boolean; mib: number }>
  containers: Map<string, Container[]> // by colima profile; a profile with a stopped VM is absent
  doors: string[]
}

// ---------------------------------------------------------------- state

export type State = "running" | "stopped" | "not loaded" | "disabled" | "not installed" | "absent"

export type Row = {
  name: string
  tier: Tier
  kind: Kind
  profile?: string
  state: State
  footprint_mib: number | null
  budget_mib: number
  over: boolean
  doors: string[]
  note?: string
}

function containerFor(s: Service, snap: Snapshot): Container | undefined {
  return snap.containers.get(s.vm ?? "default")?.find((c) => c.name === s.container)
}

export function stateOf(s: Service, snap: Snapshot): { state: State; mib: number | null } {
  if (s.kind === "launchd" && s.label) {
    const key = normalizeLabel(s.label)
    const labelOf = (l: string) => normalizeLabel(l) === key
    if (s.daemon) {
      const plist = snap.plists.find((p) => labelOf(p.label) && p.domain === "system")
      if (!plist) return { state: "not installed", mib: null }
      const running = [...snap.systemRunning].some(labelOf)
      const procs = s.process ? snap.procs.filter((p) => p.cmd === s.process) : []
      return { state: running ? "running" : "stopped", mib: procs.length ? footprint(procs) : null }
    }
    const row = snap.loaded.find((r) => labelOf(r.label))
    const plist = snap.plists.find((p) => labelOf(p.label) && p.domain === "gui")
    const disabled = [...snap.disabled].some(labelOf)
    if (!row) {
      if (disabled) return { state: "disabled", mib: null }
      return { state: plist ? "not loaded" : "not installed", mib: null }
    }
    if (row.pid == null) return { state: "stopped", mib: null }
    return { state: "running", mib: footprint(treePids(row.pid, snap.procs), s.shared_memory) }
  }
  if (s.kind === "compose") {
    const c = containerFor(s, snap)
    if (!c) return { state: snap.containers.has(s.vm ?? "default") ? "absent" : "stopped", mib: null }
    return { state: c.state === "running" ? "running" : "stopped", mib: c.mib }
  }
  if (s.kind === "vm") {
    const vm = snap.vms.get(s.vm ?? "")
    return { state: vm?.running ? "running" : "stopped", mib: vm?.running ? vm.mib : null }
  }
  // static and dev-server: served through a door; running when a process answers for it is not knowable without
  // a probe, so a registered launch label or process decides, else the state is unknown (shown as stopped).
  if (s.process) {
    const procs = snap.procs.filter((p) => p.cmd === s.process)
    return { state: procs.length ? "running" : "stopped", mib: procs.length ? footprint(procs) : null }
  }
  return { state: s.kind === "static" ? "running" : "stopped", mib: null }
}

export type Drift = {
  unknown_jobs: string[]
  worktree_jobs: string[]
  unknown_installed: string[]
  missing: string[]
  unknown_containers: string[]
  unclaimed_doors: string[]
  disabled: string[]
}

export function grade(services: Service[], snap: Snapshot): { rows: Row[]; drift: Drift } {
  const rows: Row[] = services.map((s) => {
    const { state, mib } = stateOf(s, snap)
    return {
      name: s.name, tier: s.tier, kind: s.kind, profile: s.profile, state, footprint_mib: mib === null ? null : Math.round(mib),
      budget_mib: s.memory_mib, over: mib !== null && s.memory_mib > 0 && mib > s.memory_mib, doors: s.doors, note: s.note,
    }
  })
  const known = new Set(services.filter((s) => s.label).map((s) => normalizeLabel(s.label!)))
  const inFamily = (l: string) => FAMILY.test(l)
  const worktree = (path: string) => path.includes("/.claude/worktrees/")
  const drift: Drift = {
    unknown_jobs: snap.loaded.map((r) => r.label).filter((l) => inFamily(l) && !known.has(normalizeLabel(l))).sort(),
    worktree_jobs: snap.plists.filter((p) => inFamily(p.label) && worktree(p.program) && (snap.loaded.some((r) => r.label === p.label) || p.domain === "system")).map((p) => `${p.label} (${p.program})`).sort(),
    unknown_installed: snap.plists.filter((p) => inFamily(p.label) && !known.has(normalizeLabel(p.label)) && !snap.loaded.some((r) => r.label === p.label)).map((p) => p.label).sort(),
    // a manual compose service has no container while its project is down: that is its normal state, not drift
    missing: rows.filter((r, i) => ["not installed", "absent"].includes(r.state) && services[i].kind !== "vm" && !(services[i].kind === "compose" && services[i].tier === "manual")).map((r) => r.name),
    unknown_containers: [],
    unclaimed_doors: snap.doors.filter((d) => !services.some((s) => s.doors.includes(d))).sort(),
    disabled: rows.filter((r) => r.state === "disabled").map((r) => r.name),
  }
  const registered = new Set(services.filter((s) => s.container).map((s) => `${s.vm}/${s.container}`))
  for (const [vm, list] of snap.containers) for (const c of list) if (!registered.has(`${vm}/${c.name}`)) drift.unknown_containers.push(`${vm}/${c.name}`)
  drift.unknown_containers.sort()
  return { rows, drift }
}

// check: 1 = fail (an unregistered loaded job, a program inside a worktree), 2 = warn (budget breach), 0 = clean
export function findings(rows: Row[], drift: Drift): { lines: string[]; rc: number } {
  const lines: string[] = []
  for (const l of drift.unknown_jobs) lines.push(`FAIL loaded job not in the registry: ${l}`)
  for (const l of drift.worktree_jobs) lines.push(`FAIL job program inside a worktree: ${l}`)
  for (const r of rows.filter((r) => r.over)) lines.push(`WARN over budget: ${r.name} ${r.footprint_mib} MiB of ${r.budget_mib}`)
  const rc = drift.unknown_jobs.length || drift.worktree_jobs.length ? 1 : rows.some((r) => r.over) ? 2 : 0
  return { lines, rc }
}

// ---------------------------------------------------------------- verbs

export type Step = { service: string; argv: string[]; shell: boolean; label: string }

export function startOrder(s: Service, all: Service[], running: (n: string) => boolean): Service[] {
  const out: Service[] = []
  const visit = (x: Service, trail: string[]) => {
    if (trail.includes(x.name)) throw new Error(`needs cycle: ${[...trail, x.name].join(" -> ")}`)
    for (const n of x.needs) {
      const dep = all.find((o) => o.name === resolveNeed(x, n))
      if (dep && !running(dep.name)) visit(dep, [...trail, x.name])
    }
    if (!out.includes(x)) out.push(x)
  }
  visit(s, [])
  return out
}

// The registry describes the mini: on another machine its labels and commands would act on the wrong host.
export function hostRefusal(backend: string, override = false): string | null {
  if (override || backend === "cache") return null
  return `the registry describes the Mac mini (secrets backend 'cache'); this machine reports '${backend || "unset"}'. Run it on the mini: ssh mini 'make -C ~/SourceRoot/dotfiles mini-ps'`
}

// What stops a verb before anything runs: an unknown name, or a core service without --force.
export function refusal(services: Service[], verb: "up" | "down", name: string | undefined, force: boolean): string | null {
  const s = services.find((x) => x.name === name)
  if (!s) return `unknown service '${name ?? ""}'. Known: ${services.map((x) => x.name).join(" ")}`
  if (verb === "down" && s.tier === "core" && !force) return `${s.name} is core: refusing to stop it without FORCE=1`
  return null
}

// A command from the registry runs through sh; a launchd job without one gets launchctl, argv only.
export function stepFor(s: Service, verb: "start" | "stop", snap: Pick<Snapshot, "uid" | "plists" | "loaded">): Step | string {
  const cmd = verb === "start" ? s.start : s.stop
  if (cmd) return { service: s.name, argv: ["sh", "-c", cmd], shell: true, label: cmd }
  if (s.kind === "launchd" && s.label && !s.daemon) {
    const key = normalizeLabel(s.label)
    const loaded = snap.loaded.find((r) => normalizeLabel(r.label) === key)
    const plist = snap.plists.find((p) => normalizeLabel(p.label) === key && p.domain === "gui")
    const label = loaded?.label ?? plist?.label ?? s.label
    const target = `gui/${snap.uid}/${label}`
    if (verb === "stop") {
      if (!loaded) return `${s.name}: not loaded`
      return { service: s.name, argv: ["launchctl", "bootout", target], shell: false, label: `launchctl bootout ${target}` }
    }
    if (loaded) return { service: s.name, argv: ["launchctl", "kickstart", target], shell: false, label: `launchctl kickstart ${target}` }
    if (!plist) return `${s.name}: no plist installed for ${s.label}`
    return { service: s.name, argv: ["sh", "-c", `launchctl enable ${target} && launchctl bootstrap gui/${snap.uid} '${plist.path}'`], shell: false, label: `launchctl enable ${target} && launchctl bootstrap gui/${snap.uid} ${plist.path}` }
  }
  return `${s.name}: no ${verb} command registered (${s.kind}, owner ${s.repo})`
}

// ---------------------------------------------------------------- live snapshot

async function run(argv: string[], env: Record<string, string> = {}, timeoutMs = 20000): Promise<{ out: string; rc: number }> {
  try {
    const p = Bun.spawn(argv, { stdout: "pipe", stderr: "pipe", env: { ...process.env, ...env }, timeout: timeoutMs })
    const out = await new Response(p.stdout).text()
    return { out, rc: await p.exited }
  } catch {
    return { out: "", rc: 127 }
  }
}

const PLIST_DIRS: [string, "gui" | "system"][] = [
  [join(HOME, "Library", "LaunchAgents"), "gui"],
  ["/Library/LaunchAgents", "gui"],
  ["/Library/LaunchDaemons", "system"],
]

async function readPlists(): Promise<Plist[]> {
  const files: { path: string; domain: "gui" | "system" }[] = []
  for (const [dir, domain] of PLIST_DIRS) {
    if (!existsSync(dir)) continue
    for (const f of readdirSync(dir)) if (f.endsWith(".plist") && FAMILY.test(f)) files.push({ path: join(dir, f), domain })
  }
  return Promise.all(files.map(async ({ path, domain }) => {
    const { out } = await run(["/usr/bin/plutil", "-convert", "json", "-o", "-", path])
    let program = ""
    try {
      const j = JSON.parse(out)
      program = [j.Program, ...(j.ProgramArguments ?? []), j.WorkingDirectory].filter(Boolean).join(" ")
    } catch { /* an unreadable plist has no program to grade */ }
    return { label: path.split("/").pop()!.replace(/\.plist$/, ""), path, program, domain }
  }))
}

const COLIMA_VMS: Record<string, string> = { default: "colima", teamchat: "colima-teamchat" }

async function readVms(procs: Proc[], vmNames: string[]): Promise<Map<string, { running: boolean; mib: number }>> {
  const vz = procs.filter((p) => p.cmd.startsWith("com.apple.Virtua")).sort((a, b) => a.pid - b.pid)
  const out = new Map<string, { running: boolean; mib: number }>()
  for (const name of vmNames) {
    const dir = join(HOME, ".colima", "_lima", COLIMA_VMS[name] ?? `colima-${name}`)
    const pidFile = join(dir, "ha.pid")
    const ha = existsSync(pidFile) ? Number(readFileSync(pidFile, "utf8").trim()) : 0
    const alive = ha > 0 && procs.some((p) => p.pid === ha && p.cmd.startsWith("limactl"))
    // the VM's XPC process is the first one started after its hostagent (the only link between them)
    const vm = alive ? vz.find((p) => p.pid > ha) : undefined
    out.set(name, { running: alive, mib: vm?.mib ?? 0 })
  }
  return out
}

export async function snapshot(services: Service[], { withDoors }: { withDoors: boolean } = { withDoors: false }): Promise<Snapshot> {
  const uid = process.getuid?.() ?? 501
  const docker = process.env.DOCKER_BIN ?? "/opt/homebrew/bin/docker"
  const [top, list, disabled, plists, doors] = await Promise.all([
    run(["/usr/bin/top", "-l", "1", "-stats", "pid,ppid,mem,command"], {}, 25000),
    run(["/bin/launchctl", "list"]),
    run(["/bin/launchctl", "print-disabled", `gui/${uid}`]),
    readPlists(),
    withDoors
      ? run(["/usr/bin/python3", "-I", join(DOTFILES, "scripts", "lib", "caddy-registry.py"), "--caddyfile", join(DOTFILES, "config", "Caddyfile"), "--caddy-bin", process.env.CADDY_BIN ?? "/opt/homebrew/bin/caddy", "--quiet"])
      : Promise.resolve({ out: "", rc: 0 }),
  ])
  const procs = parseTop(top.out)
  const vmNames = [...new Set(services.filter((s) => s.kind === "vm").map((s) => s.vm!))]
  const vms = await readVms(procs, vmNames)
  const systemRunning = new Set<string>()
  await Promise.all(plists.filter((p) => p.domain === "system").map(async (p) => {
    const r = await run(["/bin/launchctl", "print", `system/${p.label}`])
    if (/state = running/.test(r.out)) systemRunning.add(p.label)
  }))
  const containers = new Map<string, Container[]>()
  await Promise.all([...vms].filter(([, v]) => v.running).map(async ([name]) => {
    const env = { DOCKER_HOST: `unix://${HOME}/.colima/${name}/docker.sock` }
    const [ps, stats] = await Promise.all([
      run([docker, "ps", "-a", "--format", '{{.Names}}|{{.Label "com.docker.compose.project"}}|{{.State}}'], env),
      run([docker, "stats", "--no-stream", "--format", "{{.Name}}|{{.MemUsage}}"], env),
    ])
    containers.set(name, parseContainers(ps.out, stats.out))
  }))
  return {
    uid, procs, loaded: parseLaunchctlList(list.out), disabled: parseDisabled(disabled.out), plists, systemRunning, vms, containers,
    doors: doors.out.split("\n").map((l) => l.split("\t")[0]).filter(Boolean),
  }
}

// ---------------------------------------------------------------- output

const MIB = (n: number | null) => (n === null ? "-" : n >= 1024 ? `${(n / 1024).toFixed(1)}G` : `${n}M`)

export function renderTable(rows: Row[], drift: Drift, services: Service[]): string {
  const out: string[] = []
  for (const tier of TIERS) {
    const part = rows.filter((r) => r.tier === tier)
    if (!part.length) continue
    out.push("", `${tier.toUpperCase()}  (${part.length})`)
    out.push(`  ${"NAME".padEnd(34)}${"KIND".padEnd(11)}${"PROFILE".padEnd(9)}${"STATE".padEnd(14)}${"FOOTPRINT".padStart(10)}${"BUDGET".padStart(9)}`)
    for (const r of part) {
      const mark = r.over ? " OVER" : ""
      out.push(`  ${r.name.padEnd(34)}${r.kind.padEnd(11)}${(r.profile ?? "").padEnd(9)}${r.state.padEnd(14)}${MIB(r.footprint_mib).padStart(10)}${MIB(r.budget_mib || null).padStart(9)}${mark}`)
    }
    const used = part.reduce((a, r) => a + (r.footprint_mib ?? 0), 0)
    out.push(`  ${"".padEnd(68)}${MIB(used).padStart(10)}${MIB(part.reduce((a, r) => a + r.budget_mib, 0)).padStart(9)}`)
  }
  const shared = services.filter((s) => s.shared_memory).map((s) => s.name)
  out.push("", "Footprint is the physical footprint (top MEM), summed over a job's process tree; containers by docker stats; a VM by its Virtualization process.")
  if (shared.length) out.push(`${shared.join(", ")}: every process's footprint counts the shared buffers again, so this is the largest process plus the others' private part, each capped at ${PRIVATE_CAP_MIB} MiB (an estimate).`)
  const section = (title: string, list: string[]) => {
    if (list.length) out.push("", `${title} (${list.length})`, ...list.map((l) => `  ${l}`))
  }
  out.push("", "DRIFT")
  section("loaded jobs the registry does not know", drift.unknown_jobs)
  section("jobs whose program is inside a worktree", drift.worktree_jobs)
  section("installed, not loaded, not registered", drift.unknown_installed)
  section("registry entries with no plist or container", drift.missing)
  section("containers the registry does not know", drift.unknown_containers)
  section("doors no service claims", drift.unclaimed_doors)
  section("disabled leftovers (plist still installed)", drift.disabled)
  if (Object.values(drift).every((l) => l.length === 0)) out.push("  none")
  return out.join("\n")
}

// ---------------------------------------------------------------- cli

async function main(argv: string[]) {
  const [verb, ...rest] = argv
  const flag = (n: string) => rest.includes(n)
  const arg = rest.find((a) => !a.startsWith("--"))
  const fmt = rest.includes("--format") ? rest[rest.indexOf("--format") + 1] : "table"
  if (!verb || !["ps", "check", "up", "down", "profile", "list"].includes(verb)) {
    console.error("usage: mini-registry ps [--format table|json] | check | up NAME | down NAME [--force] | profile NAME --up|--down")
    return 2
  }
  const backend = (() => {
    try { return readFileSync(join(process.env.XDG_CONFIG_HOME ?? join(HOME, ".config"), "secrets", "backend"), "utf8").trim() } catch { return "" }
  })()
  const wrongHost = hostRefusal(backend, process.env.MINI_REGISTRY_ANY_HOST === "1")
  if (wrongHost) { console.error(wrongHost); return 2 }
  const loaded = loadAll()
  if (loaded.errors.length) {
    console.error(`FAIL registry invalid:\n  ${loaded.errors.join("\n  ")}`)
    return 1
  }
  const { services } = loaded
  if (verb === "list") { console.log(services.map((s) => s.name).join("\n")); return 0 }
  if (verb === "up" || verb === "down") {
    const refused = refusal(services, verb, arg, flag("--force"))
    if (refused) { console.error(refused); return 2 }
  }
  // the heartbeat bounds `check` at 40 s and grades a timeout FAIL: a slow probe is a WARN here, never a finding
  const probe = snapshot(services, { withDoors: verb === "ps" })
  const snap = verb === "check"
    ? await Promise.race([probe, new Promise<null>((r) => setTimeout(() => r(null), CHECK_DEADLINE_MS))])
    : await probe
  if (!snap) { console.log(`registry: probes did not finish in ${CHECK_DEADLINE_MS / 1000} s, not graded`); return 2 }
  const { rows, drift } = grade(services, snap)

  if (verb === "ps") {
    if (fmt === "json") console.log(JSON.stringify({ at: new Date().toISOString(), services: rows, drift }, null, 2))
    else console.log(renderTable(rows, drift, services))
    return 0
  }
  if (verb === "check") {
    const f = findings(rows, drift)
    for (const l of f.lines) console.log(l)
    console.log(f.rc === 0 ? `registry: ${rows.length} services, no drift, within budget` : `registry: ${f.lines.length} finding(s) over ${rows.length} services (make mini-ps)`)
    return f.rc
  }

  const find = (n?: string) => services.find((s) => s.name === n)
  const running = (n: string) => rows.find((r) => r.name === n)?.state === "running"
  const exec = async (step: Step) => {
    console.log(`  $ ${step.label}`)
    const p = Bun.spawn(step.argv, { stdout: "inherit", stderr: "inherit" })
    return p.exited
  }

  if (verb === "up" || verb === "down") {
    const s = find(arg)!
    const plan = verb === "up" ? startOrder(s, services, running) : [s]
    for (const x of plan) {
      if (verb === "up" && running(x.name)) { console.log(`${x.name}: already running`); continue }
      const step = stepFor(x, verb === "up" ? "start" : "stop", snap)
      if (typeof step === "string") {
        console.error(step)
        if (x === s) return 1
        continue
      }
      console.log(`${verb} ${x.name}`)
      const rc = await exec(step)
      if (rc !== 0) { console.error(`${x.name}: ${step.label} exited ${rc}`); return 1 }
    }
    const after = grade(services, await snapshot(services)).rows.find((r) => r.name === s.name)
    console.log(`${s.name}: ${after?.state}`)
    return 0
  }

  // profile
  const profile = arg
  const members = services.filter((s) => s.tier === "manual" && s.profile === profile)
  if (!profile || !members.length) {
    console.error(`unknown profile '${profile ?? ""}'. Profiles: ${[...new Set(services.filter((s) => s.profile).map((s) => s.profile))].join(" ")}`)
    return 2
  }
  if (flag("--up") === flag("--down")) { console.error("profile needs exactly one of --up, --down"); return 2 }
  const up = flag("--up")
  const order = up ? members : [...members].reverse()
  const done = new Set<string>()
  let failed = 0
  for (const m of order) {
    const plan = up ? startOrder(m, services, running) : [m]
    for (const x of plan) {
      if (done.has(x.name)) continue
      done.add(x.name)
      if (up && running(x.name)) { console.log(`${x.name}: already running`); continue }
      if (!up && !running(x.name)) { console.log(`${x.name}: not running`); continue }
      const step = stepFor(x, up ? "start" : "stop", snap)
      if (typeof step === "string") { console.error(step); if (x === m) failed++; continue }
      // members of one compose project share a command: run it once per operation
      const key = step.label
      if (done.has(`cmd:${key}`)) continue
      done.add(`cmd:${key}`)
      console.log(`${up ? "start" : "stop"} ${x.name}`)
      if ((await exec(step)) !== 0) { console.error(`${x.name}: ${step.label} failed`); failed++ }
    }
  }
  return failed ? 1 : 0
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)))

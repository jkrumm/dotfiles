#!/usr/bin/env bun
// The mini's service registry: every launchd job, compose container, VM, static door and dev server on
// the Mac mini with its tier, memory budget and start/stop verbs. docs/mini-registry.md.
//
//   mini-registry ps    [--format table|json]    tier, state, footprint against budget, drift
//   mini-registry check                          drift, run-rule and budget findings only; exit 1 on drift or a rule breach, 2 on a budget breach
//   mini-registry debt                           the recorded breaches (debt and exceptions), one per line
//   mini-registry lint  [--file F] [--repo R|--host]  F (default ./mini-services.yaml) as repo R (default this repo's directory name) against every other registry; no probes, runs on any machine
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
import { basename, dirname, join, resolve } from "node:path"

const HOME = homedir()
const DOTFILES = join(import.meta.dir, "..")
const HOST_FILE = join(DOTFILES, "config", "mini", "services.yaml")
const REPO_FILE = "mini-services.yaml"
const CHECK_DEADLINE_MS = 30000

export const KINDS = ["launchd", "compose", "vm", "static", "dev-server"] as const
export const TIERS = ["core", "on-demand", "manual"] as const
export const PROFILES = ["work", "dev-db"] as const
export const PROCESS_TYPES = ["interactive"] as const
// `ps -o pri=` of a launchd job with ProcessType Interactive, measured on the mini 2026-11-14: the same 31 as a process
// started in a terminal. A job with no ProcessType runs at 20 (launchd's "light resource limits"), a Background one lower.
export const INTERACTIVE_PRI = 31
export type Kind = (typeof KINDS)[number]
export type Tier = (typeof TIERS)[number]
export type ProcessType = (typeof PROCESS_TYPES)[number]

// The run rules (rules/run-on-mini.md). A DETECTED rule is judged from the registry and the probes, so a debt field for it
// can go stale; a DECLARED one cannot be seen from here (a KeepAlive agent that polls in a loop looks like a server).
export const RULES = ["restart-policy", "no-memory-limit", "port-binding", "second-vm", "shared-infrastructure", "no-budget", "worktree-program"] as const
export const DECLARED_RULES = ["keepalive-poll", "docker-build-tool"] as const
export type Rule = (typeof RULES)[number]
const ALL_RULES: readonly string[] = [...RULES, ...DECLARED_RULES]

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
  // the launchd ProcessType the service must run at: a running service below its band fails the check
  process_type?: ProcessType
  start?: string
  stop?: string
  status?: string
  note?: string
  // a breach of a run rule that is known and has a plan row (debt), or is allowed for a stated reason (exception); rule -> row | reason
  debt: Record<string, string>
  exception: Record<string, string>
  // a root one-shot at boot: no process to budget
  oneshot?: boolean
}

// A breach that belongs to no service of the registry (a make target that runs docker): recorded in the host file's top-level `debt:` list.
export type ListedDebt = { repo: string; target: string; rule: string; plan: string }

export type Loaded = { services: Service[]; errors: string[]; listed: ListedDebt[] }

const FAMILY = /^(com\.jkrumm\.|com\.iu\.|ai\.hermes\.|homebrew\.mxcl\.|sh\.brew\.|com\.colima\.)/
const NAME = /^[a-z0-9][a-z0-9.-]*$/
const BREW = /^(sh\.brew|homebrew\.mxcl)\./

// ---------------------------------------------------------------- registry

export function expand(text: string, home = HOME): string {
  return text.replaceAll("${HOME}", home).replaceAll("~/", `${home}/`)
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v.trim() ? v.trim() : undefined)

function ruleMap(raw: unknown, field: string, err: (m: string) => void): Record<string, string> {
  if (raw == null) return {}
  if (typeof raw !== "object" || Array.isArray(raw)) { err(`${field} must map a rule to a ${field === "debt" ? "plan row" : "reason"}`); return {} }
  const out: Record<string, string> = {}
  for (const [rule, v] of Object.entries(raw as Record<string, unknown>)) {
    if (!ALL_RULES.includes(rule)) err(`${field}: unknown rule ${rule} (${ALL_RULES.join(", ")})`)
    else if (!str(v)) err(`${field}.${rule} must name ${field === "debt" ? "the plan row that fixes it" : "the reason it is allowed"}`)
    else out[rule] = str(v)!
  }
  return out
}

export function parseRegistry(text: string, source: string, repoDefault?: string, home = HOME): Loaded {
  const errors: string[] = []
  let doc: unknown
  try {
    doc = Bun.YAML.parse(text)
  } catch (e) {
    return { services: [], errors: [`${source}: ${(e as Error).message}`], listed: [] }
  }
  const rows = (doc as { services?: unknown })?.services
  if (!Array.isArray(rows)) return { services: [], errors: [`${source}: no services list`], listed: [] }
  const listed: ListedDebt[] = []
  const rawListed = (doc as { debt?: unknown }).debt
  if (rawListed != null && !Array.isArray(rawListed)) errors.push(`${source}: debt must be a list of { repo, target, rule, plan }`)
  for (const d of Array.isArray(rawListed) ? (rawListed as Record<string, unknown>[]) : []) {
    const at = `${source}: debt ${JSON.stringify(d)}`
    if (!str(d?.repo) || !str(d?.target) || !str(d?.plan) || !ALL_RULES.includes(String(d?.rule))) { errors.push(`${at}: needs repo, target, plan and a known rule`); continue }
    listed.push({ repo: str(d.repo)!, target: str(d.target)!, rule: String(d.rule), plan: str(d.plan)! })
  }
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
      debt: ruleMap(raw.debt, "debt", err), exception: ruleMap(raw.exception, "exception", err), oneshot: raw.oneshot === true,
    }
    if (raw.process_type != null) {
      if (!PROCESS_TYPES.includes(raw.process_type as ProcessType)) err(`process_type must be one of ${PROCESS_TYPES.join(", ")}`)
      else if (kind !== "launchd" || tier !== "core") err("process_type is only for a launchd service of tier core")
      else s.process_type = raw.process_type as ProcessType
    }
    if (kind === "launchd" && !s.label) err("a launchd service needs a label")
    if (kind === "compose" && !s.container) err("a compose service needs a container")
    if (kind === "compose" && !s.vm) s.vm = "default"
    if (kind === "vm" && !s.process && !s.vm) err("a vm service needs vm: <colima profile>")
    services.push(s)
  }
  return { services, errors, listed }
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

// `candidate` is a registry file under edit (a worktree's, not the checkout the roots find): it stands in for the host
// file (no `repo`) or for the file of the repo directory named `repo`, so a change is validated against everyone else's rows.
export type Candidate = { file: string; repo?: string }

export function loadAll(roots = defaultRoots(), hostFile = HOST_FILE, home = HOME, candidate?: Candidate): Loaded {
  const out: Loaded = { services: [], errors: [], listed: [] }
  const files: [string, string | undefined][] = [[candidate && !candidate.repo ? candidate.file : hostFile, undefined]]
  for (const root of roots) {
    if (!existsSync(root)) continue
    for (const d of readdirSync(root, { withFileTypes: true })) {
      if (candidate?.repo === d.name) continue
      if (d.isDirectory() && existsSync(join(root, d.name, REPO_FILE))) files.push([join(root, d.name, REPO_FILE), d.name])
    }
  }
  if (candidate?.repo) files.push([candidate.file, candidate.repo])
  for (const [file, repo] of files) {
    if (!existsSync(file)) { out.errors.push(`${file}: not found`); continue }
    const r = parseRegistry(readFileSync(file, "utf8"), file.replace(`${home}/`, "~/"), repo, home)
    out.services.push(...r.services)
    out.errors.push(...r.errors)
    out.listed.push(...r.listed)
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

export type Container = {
  name: string; project: string; state: string; mib: number | null
  // docker inspect: absent when the inspect pass did not run
  image?: string; restart?: string; limit_mib?: number; bind_hosts?: string[]
}

// `docker inspect --format '{{.Name}}|{{.Config.Image}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.Memory}}|{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}[{{.HostIp}}]{{end}}{{end}}'`
export function parseInspect(out: string): Map<string, Pick<Container, "image" | "restart" | "limit_mib" | "bind_hosts">> {
  const map = new Map<string, Pick<Container, "image" | "restart" | "limit_mib" | "bind_hosts">>()
  for (const line of out.split("\n")) {
    const [name, image, restart, mem, binds = ""] = line.split("|")
    if (!name || image === undefined) continue
    map.set(name.replace(/^\//, ""), {
      image, restart: restart || "no", limit_mib: Math.round(Number(mem || 0) / 1048576),
      bind_hosts: [...binds.matchAll(/\[([^\]]*)\]/g)].map((m) => m[1]),
    })
  }
  return map
}

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

export type Plist = { label: string; path: string; program: string; domain: "gui" | "system"; processType?: string }

// `ps -axo pid=,pri=`: the scheduler priority of every process.
export function parsePri(out: string): Map<number, number> {
  const pri = new Map<number, number>()
  for (const line of out.split("\n")) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s*$/)
    if (m) pri.set(Number(m[1]), Number(m[2]))
  }
  return pri
}

export type Snapshot = {
  uid: number
  procs: Proc[]
  pri: Map<number, number> // pid -> `ps -o pri=`
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
  // the scheduler priority of the main process and the band the entry declares
  pri: number | null
  process_type?: ProcessType
  below_band: boolean
  plist_process_type?: string | null // the plist file's ProcessType, for a declared service
}

// The main process of a launchd service: the job's pid, or for a system daemon the oldest process of that name.
function mainPid(s: Service, snap: Snapshot): number | null {
  if (s.kind !== "launchd" || !s.label) return null
  const key = normalizeLabel(s.label)
  if (s.daemon) return snap.procs.filter((p) => p.cmd === s.process).sort((a, b) => a.pid - b.pid)[0]?.pid ?? null
  return snap.loaded.find((r) => normalizeLabel(r.label) === key)?.pid ?? null
}

function plistFileOf(s: Service, snap: Snapshot): Plist | undefined {
  const key = s.label ? normalizeLabel(s.label) : ""
  return snap.plists.find((p) => normalizeLabel(p.label) === key && p.domain === (s.daemon ? "system" : "gui"))
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
      // launchd keeps the disabled flag after the plist is gone: with no file there is nothing left to prune, only a row to delete
      if (disabled && plist) return { state: "disabled", mib: null }
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
    const pid = state === "running" ? mainPid(s, snap) : null
    const pri = pid === null ? null : snap.pri.get(pid) ?? null
    const plistFile = s.process_type ? plistFileOf(s, snap) : undefined
    return {
      name: s.name, tier: s.tier, kind: s.kind, profile: s.profile, state, footprint_mib: mib === null ? null : Math.round(mib),
      budget_mib: s.memory_mib, over: mib !== null && s.memory_mib > 0 && mib > s.memory_mib, doors: s.doors, note: s.note,
      pri, process_type: s.process_type, below_band: s.process_type === "interactive" && pri !== null && pri < INTERACTIVE_PRI,
      plist_process_type: s.process_type && plistFile ? plistFile.processType ?? null : undefined,
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
  // A container is known by its name: one that runs in another VM than its row declares is the second-vm rule's finding (the VM-merge
  // Issues track it), not an unknown container.
  const registered = new Set(services.filter((s) => s.container).map((s) => s.container))
  for (const [vm, list] of snap.containers) for (const c of list) if (!registered.has(c.name)) drift.unknown_containers.push(`${vm}/${c.name}`)
  drift.unknown_containers.sort()
  return { rows, drift }
}

// ---------------------------------------------------------------- run rules

export type Breach = { service: string; rule: Rule; detail: string }
export type RuleReport = {
  failures: Breach[] // breaches with no debt field and no exception
  debt: (Breach & { plan: string })[]
  allowed: (Breach & { reason: string })[]
  stale: { service: string; rule: string }[] // a debt or exception field whose breach is gone
  declared: { service: string; rule: string; plan: string }[] // debt on a rule the registry cannot see
  listed: ListedDebt[]
  warnings: string[] // the limits of a VM's core services add up to more than the VM
  worktreeLabels: Set<string> // worktree programs this report already judges
}

const SHARED_IMAGE = /(^|\/)(postgres(ql)?|redis|valkey|keydb|memcached)(:|@|$)/
// the last label segment names the software: com.iu.athena-postgres, sh.brew.postgresql@18, com.jkrumm.valkey
const SHARED_LABEL = /(^|[.-])(postgres(ql)?|redis|valkey|keydb|memcached)(@[\d.]+)?$/
const family = (word: string) => (/^postgres/.test(word) ? "postgres" : "cache")

// Breaches of rules/run-on-mini.md among what the registry lists. Container rules need the inspect pass: a container that is not there
// (a manual project that is down, a VM that is off) is not judged, which is also why its debt field is not judged stale.
export function ruleBreaches(services: Service[], snap: Snapshot): Breach[] {
  const out: Breach[] = []
  const add = (s: Service, rule: Rule, detail: string) => out.push({ service: s.name, rule, detail })
  for (const s of services) {
    if (s.memory_mib === 0 && s.kind !== "static" && !s.oneshot) add(s, "no-budget", "memory_mib is 0 (set 1.5 times the footprint after an hour of use)")
    if (s.kind === "vm" && (s.vm ?? "default") !== "default") add(s, "second-vm", `Colima profile ${s.vm}: the mini runs one VM, the default`)
    if (s.kind === "compose") {
      const c = containerFor(s, snap)
      if (c?.restart !== undefined) {
        if (/^(always|unless-stopped)$/.test(c.restart) && s.tier !== "core") add(s, "restart-policy", `restart ${c.restart} on a ${s.tier} service: only a core service restarts itself`)
        if (c.limit_mib === 0) add(s, "no-memory-limit", "no mem_limit")
        const open = (c.bind_hosts ?? []).filter((h) => h !== "127.0.0.1" && h !== "::1")
        if (open.length) add(s, "port-binding", `published on ${[...new Set(open.map((h) => h || "0.0.0.0"))].join(", ")}, not 127.0.0.1`)
      }
      if (c?.image && SHARED_IMAGE.test(c.image)) add(s, "shared-infrastructure", `image ${c.image}: Postgres and a cache are one native instance under launchd, not a container per app`)
    }
  }
  // native instances: the one Postgres is a brew service; a cache is allowed once, when a service needs it
  const native = services.filter((s) => s.kind === "launchd" && s.label && SHARED_LABEL.test(s.label!))
  for (const [fam, list] of Object.entries(Object.groupBy(native, (s) => family(s.label!.match(SHARED_LABEL)![2])))) {
    const keep = fam === "postgres" ? list!.find((s) => /^(sh\.brew|homebrew\.mxcl)\./.test(s.label!)) : list![0]
    for (const s of list!) if (s !== keep) add(s, "shared-infrastructure", `a second native ${fam === "postgres" ? "Postgres" : "cache"} instance beside ${keep?.name ?? "the one"}`)
  }
  const loaded = new Set(snap.loaded.map((r) => r.label))
  for (const s of services) {
    const key = s.label && normalizeLabel(s.label)
    const p = key ? snap.plists.find((x) => normalizeLabel(x.label) === key) : undefined
    if (p && p.program.includes("/.claude/worktrees/") && (loaded.has(p.label) || p.domain === "system")) add(s, "worktree-program", p.program)
  }
  return out
}

// A breach is a failure unless its service carries a debt field (a plan row fixes it) or an exception (a reason it is allowed).
// A field whose breach is gone is stale: it must go, or the next breach hides behind it.
export function gradeRules(services: Service[], snap: Snapshot, listed: ListedDebt[] = []): RuleReport {
  const breaches = ruleBreaches(services, snap)
  const r: RuleReport = { failures: [], debt: [], allowed: [], stale: [], declared: [], listed, warnings: [], worktreeLabels: new Set() }
  for (const b of breaches) {
    const s = services.find((x) => x.name === b.service)!
    if (b.rule === "worktree-program" && s.label) r.worktreeLabels.add(s.label)
    if (s.debt[b.rule]) r.debt.push({ ...b, plan: s.debt[b.rule] })
    else if (s.exception[b.rule]) r.allowed.push({ ...b, reason: s.exception[b.rule] })
    else r.failures.push(b)
  }
  for (const s of services) {
    for (const [rule, plan] of Object.entries(s.debt)) {
      if (!(RULES as readonly string[]).includes(rule)) r.declared.push({ service: s.name, rule, plan })
      else if (!breaches.some((b) => b.service === s.name && b.rule === rule) && judgeable(s, rule as Rule, snap)) r.stale.push({ service: s.name, rule })
    }
    for (const rule of Object.keys(s.exception)) {
      if ((RULES as readonly string[]).includes(rule) && !breaches.some((b) => b.service === s.name && b.rule === rule) && judgeable(s, rule as Rule, snap)) r.stale.push({ service: s.name, rule })
    }
  }
  for (const vm of services.filter((x) => x.kind === "vm")) {
    const limits = services.filter((x) => x.kind === "compose" && x.tier === "core" && (x.vm ?? "default") === vm.vm).reduce((a, x) => a + (containerFor(x, snap)?.limit_mib ?? 0), 0)
    if (vm.memory_mib > 0 && limits > vm.memory_mib) r.warnings.push(`core services of VM ${vm.vm} are limited to ${limits} MiB in total, the VM has ${vm.memory_mib}`)
  }
  return r
}

// Whether the probes could have seen the breach: a container rule needs the container inspected.
function judgeable(s: Service, rule: Rule, snap: Snapshot): boolean {
  if (["restart-policy", "no-memory-limit", "port-binding"].includes(rule)) return containerFor(s, snap)?.restart !== undefined
  if (rule === "shared-infrastructure" && s.kind === "compose") return containerFor(s, snap)?.image !== undefined
  return true
}

export function debtLines(r: RuleReport): string[] {
  return [
    ...r.debt.map((d) => `${d.service}: ${d.rule} -> ${d.plan} (${d.detail})`),
    ...r.declared.map((d) => `${d.service}: ${d.rule} -> ${d.plan} (declared; the registry cannot see it)`),
    ...r.listed.map((d) => `${d.repo} make ${d.target}: ${d.rule} -> ${d.plan}`),
    ...r.allowed.map((d) => `${d.service}: ${d.rule} allowed: ${d.reason}`),
  ]
}

// check: 1 = fail (an unregistered loaded job, a run-rule breach with no debt, a stale debt field, a service below its declared band or whose
// plist lost its ProcessType), 2 = warn (budget breach), 0 = clean
export function findings(rows: Row[], drift: Drift, rules?: RuleReport): { lines: string[]; rc: number } {
  const lines: string[] = []
  for (const l of drift.unknown_jobs) lines.push(`FAIL loaded job not in the registry: ${l}`)
  const worktree = drift.worktree_jobs.filter((l) => !rules?.worktreeLabels.has(l.split(" ")[0]))
  for (const l of worktree) lines.push(`FAIL job program inside a worktree: ${l}`)
  for (const b of rules?.failures ?? []) lines.push(`FAIL ${b.service} breaks rule ${b.rule}: ${b.detail}`)
  for (const s of rules?.stale ?? []) lines.push(`FAIL ${s.service}: the ${s.rule} breach is gone, remove its debt/exception field`)
  for (const r of rows.filter((r) => r.below_band)) lines.push(`FAIL runs below its declared process type: ${r.name} at priority ${r.pri}, ${r.process_type} is ${INTERACTIVE_PRI} (reload the job; docs/mini-registry.md §Process type)`)
  // the running process can still be fine while the file launchd reads at the next boot is not: brew rewrites its plists on a restart
  for (const r of rows.filter((r) => r.process_type && r.plist_process_type !== undefined && r.plist_process_type?.toLowerCase() !== r.process_type)) {
    lines.push(`FAIL plist has no ProcessType ${r.process_type}: ${r.name} (${r.plist_process_type ?? "key missing"}; the next start loses the band)`)
  }
  for (const w of rules?.warnings ?? []) lines.push(`WARN ${w}`)
  for (const r of rows.filter((r) => r.over)) lines.push(`WARN over budget: ${r.name} ${r.footprint_mib} MiB of ${r.budget_mib}`)
  // leftovers a person must not have to remember: `make mini-prune` lists them, `make mini-prune ARGS=--apply` removes them
  for (const c of drift.unknown_containers) lines.push(`WARN container the registry does not know: ${c} (register it, or make mini-prune)`)
  for (const d of drift.disabled) lines.push(`WARN disabled but still installed: ${d} (make mini-prune removes the plist)`)
  const failed = lines.some((l) => l.startsWith("FAIL"))
  return { lines, rc: failed ? 1 : lines.length ? 2 : 0 }
}

// ---------------------------------------------------------------- prune

export type PruneAction = { kind: "plist"; name: string; path: string } | { kind: "container"; vm: string; name: string; state: string }

// What `prune` removes: the plist of a disabled launchd job, registered or not (a row that is gone with its job leaves the file,
// which the architecture check then lists as on-disk-but-unmapped), and a container no row names that is not running (created or
// exited: a test run's leftover, a retired compose project's). Disabled is the proof: `launchctl disable` is the owner's or an
// agent's explicit off switch, which no job being merely stopped or unloaded has. A running or paused unknown container is never touched.
export function pruneActions(services: Service[], rows: Row[], snap: Snapshot, drift: Drift, agentsDir = join(HOME, "Library", "LaunchAgents")): PruneAction[] {
  const out: PruneAction[] = []
  const agents = agentsDir + "/"
  const add = (name: string, file: Plist | undefined) => {
    if (file && file.domain === "gui" && file.path.startsWith(agents) && !out.some((a) => a.kind === "plist" && a.path === file.path)) out.push({ kind: "plist", name, path: file.path })
  }
  rows.forEach((r, i) => { if (r.state === "disabled") add(r.name, plistFileOf(services[i], snap)) })
  const disabled = new Set([...snap.disabled].map(normalizeLabel))
  for (const label of drift.unknown_installed) {
    if (disabled.has(normalizeLabel(label))) add(label, snap.plists.find((p) => p.label === label && p.domain === "gui"))
  }
  const stopped = /^(created|exited|dead)$/
  for (const id of drift.unknown_containers) {
    const [vm, ...rest] = id.split("/")
    const name = rest.join("/")
    const c = snap.containers.get(vm)?.find((x) => x.name === name)
    if (c && stopped.test(c.state)) out.push({ kind: "container", vm, name, state: c.state })
  }
  return out
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
    let processType: string | undefined
    try {
      const j = JSON.parse(out)
      program = [j.Program, ...(j.ProgramArguments ?? []), j.WorkingDirectory].filter(Boolean).join(" ")
      processType = typeof j.ProcessType === "string" ? j.ProcessType : undefined
    } catch { /* an unreadable plist has no program to grade */ }
    return { label: path.split("/").pop()!.replace(/\.plist$/, ""), path, program, domain, processType }
  }))
}

const INSPECT_FORMAT = "{{.Name}}|{{.Config.Image}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.Memory}}|{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}[{{.HostIp}}]{{end}}{{end}}"

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
  const [top, pri, list, disabled, plists, doors] = await Promise.all([
    run(["/usr/bin/top", "-l", "1", "-stats", "pid,ppid,mem,command"], {}, 25000),
    run(["/bin/ps", "-axo", "pid=,pri="]),
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
    const [ps, stats, ids] = await Promise.all([
      run([docker, "ps", "-a", "--format", '{{.Names}}|{{.Label "com.docker.compose.project"}}|{{.State}}'], env),
      run([docker, "stats", "--no-stream", "--format", "{{.Name}}|{{.MemUsage}}"], env),
      run([docker, "ps", "-aq"], env),
    ])
    const list = parseContainers(ps.out, stats.out)
    const idList = ids.out.split("\n").filter(Boolean)
    if (idList.length) {
      const inspect = await run([docker, "inspect", "--format", INSPECT_FORMAT, ...idList], env)
      const by = parseInspect(inspect.out)
      for (const c of list) Object.assign(c, by.get(c.name))
    }
    containers.set(name, list)
  }))
  return {
    uid, procs, pri: parsePri(pri.out), loaded: parseLaunchctlList(list.out), disabled: parseDisabled(disabled.out), plists, systemRunning, vms, containers,
    doors: doors.out.split("\n").map((l) => l.split("\t")[0]).filter(Boolean),
  }
}

// ---------------------------------------------------------------- output

const MIB = (n: number | null) => (n === null ? "-" : n >= 1024 ? `${(n / 1024).toFixed(1)}G` : `${n}M`)

export function renderTable(rows: Row[], drift: Drift, services: Service[], rules?: RuleReport): string {
  const out: string[] = []
  for (const tier of TIERS) {
    const part = rows.filter((r) => r.tier === tier)
    if (!part.length) continue
    out.push("", `${tier.toUpperCase()}  (${part.length})`)
    out.push(`  ${"NAME".padEnd(34)}${"KIND".padEnd(11)}${"PROFILE".padEnd(9)}${"STATE".padEnd(14)}${"PRI".padStart(5)}${"FOOTPRINT".padStart(10)}${"BUDGET".padStart(9)}`)
    for (const r of part) {
      const mark = (r.over ? " OVER" : "") + (r.below_band ? " BELOW-BAND" : "")
      out.push(`  ${r.name.padEnd(34)}${r.kind.padEnd(11)}${(r.profile ?? "").padEnd(9)}${r.state.padEnd(14)}${String(r.pri ?? "-").padStart(5)}${MIB(r.footprint_mib).padStart(10)}${MIB(r.budget_mib || null).padStart(9)}${mark}`)
    }
    const used = part.reduce((a, r) => a + (r.footprint_mib ?? 0), 0)
    out.push(`  ${"".padEnd(73)}${MIB(used).padStart(10)}${MIB(part.reduce((a, r) => a + r.budget_mib, 0)).padStart(9)}`)
  }
  out.push("PRI is `ps -o pri=` of the main process: 31 = launchd ProcessType Interactive (a terminal's too), 20 = no ProcessType, lower = Background.")
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
  if (rules) {
    out.push("", "RUN RULES (rules/run-on-mini.md)")
    for (const b of rules.failures) out.push(`  FAIL ${b.service}: ${b.rule}: ${b.detail}`)
    for (const s of rules.stale) out.push(`  FAIL ${s.service}: the ${s.rule} field is stale`)
    const debt = debtLines(rules)
    out.push(...debt.map((l) => `  debt  ${l}`))
    if (!rules.failures.length && !rules.stale.length && !debt.length) out.push("  none")
  }
  return out.join("\n")
}

// ---------------------------------------------------------------- cli

// The repo that adds a row learns of a clash before the merge, not from the next lead's Watch: its `make check` runs
// `bun ~/SourceRoot/dotfiles/scripts/mini-registry.ts lint`. Static (the registry files only), so it needs no mini and no probe.
function lint(args: string[]): number {
  const opt = (n: string) => (args.includes(n) ? args[args.indexOf(n) + 1] : undefined)
  const file = resolve(opt("--file") ?? "mini-services.yaml")
  const host = args.includes("--host")
  const repo = host ? undefined : opt("--repo") ?? repoDirName()
  if (!existsSync(file)) { console.log(`registry lint: ${file} not found, nothing to check`); return 0 }
  const loaded = loadAll(defaultRoots(), HOST_FILE, HOME, { file, repo })
  if (loaded.errors.length) {
    console.error(`FAIL registry invalid (${file} as ${repo ?? "the host file"}):\n  ${loaded.errors.join("\n  ")}`)
    return 1
  }
  console.log(`registry lint: ${loaded.services.length} services, no clash`)
  return 0
}

// A worktree's directory is not its repo's name: the main checkout's name is the parent of the git common dir.
function repoDirName(): string {
  const p = Bun.spawnSync(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], { stderr: "ignore" })
  const common = p.exitCode === 0 ? p.stdout.toString().trim() : ""
  return basename(common ? dirname(common) : process.cwd())
}

async function main(argv: string[]) {
  const [verb, ...rest] = argv
  const flag = (n: string) => rest.includes(n)
  const arg = rest.find((a) => !a.startsWith("--"))
  const fmt = rest.includes("--format") ? rest[rest.indexOf("--format") + 1] : "table"
  if (verb === "lint") return lint(rest)
  if (!verb || !["ps", "check", "debt", "prune", "up", "down", "profile", "list"].includes(verb)) {
    console.error("usage: mini-registry ps [--format table|json] | check | debt | prune [--apply] | lint [--file F] [--repo R|--host] | up NAME | down NAME [--force] | profile NAME --up|--down")
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
  const { services, listed } = loaded
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
  const rules = gradeRules(services, snap, listed)

  if (verb === "ps") {
    if (fmt === "json") console.log(JSON.stringify({ at: new Date().toISOString(), services: rows, drift, rules: { ...rules, worktreeLabels: undefined } }, null, 2))
    else console.log(renderTable(rows, drift, services, rules))
    return 0
  }
  if (verb === "debt") {
    const lines = debtLines(rules)
    console.log(lines.length ? lines.join("\n") : "no recorded breaches")
    return 0
  }
  if (verb === "prune") {
    const actions = pruneActions(services, rows, snap, drift)
    if (!actions.length) { console.log("nothing to prune"); return 0 }
    const docker = process.env.DOCKER_BIN ?? "/opt/homebrew/bin/docker"
    let failed = 0
    for (const a of actions) {
      const label = a.kind === "plist" ? `remove plist ${a.path}` : `docker rm ${a.vm}/${a.name} (${a.state})`
      if (!flag("--apply")) { console.log(`would ${label}`); continue }
      const ok = a.kind === "plist"
        ? (() => { try { rmSync(a.path); return true } catch { return false } })()
        : (await run([docker, "rm", a.name], { DOCKER_HOST: `unix://${HOME}/.colima/${a.vm}/docker.sock` })).rc === 0
      console.log(`${ok ? "done" : "FAILED"}: ${label}`)
      if (!ok) failed++
    }
    if (!flag("--apply")) console.log("(dry run: make mini-prune ARGS=--apply)")
    return failed ? 1 : 0
  }
  if (verb === "check") {
    const f = findings(rows, drift, rules)
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

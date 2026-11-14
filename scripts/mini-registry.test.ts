import { describe, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  type Plist, type Snapshot, footprint, findings, grade, loadAll, normalizeLabel, parseContainers, parseDisabled,
  hostRefusal, parseLaunchctlList, parsePri, parseRegistry, parseTop, refusal, startOrder, stepFor, treePids, validate,
} from "./mini-registry.ts"

const HOME = "/home/u"
const REGISTRY = `
services:
  - { name: colima-default, repo: dotfiles, kind: vm, tier: core, vm: default, memory_mib: 4000 }
  - { name: web, repo: app, kind: launchd, tier: core, label: com.jkrumm.web, door: web, memory_mib: 100 }
  - { name: brewed, repo: dotfiles, kind: launchd, tier: core, label: sh.brew.thing, memory_mib: 50 }
  - { name: pg, repo: dotfiles, kind: launchd, tier: core, label: "sh.brew.postgresql@18", shared_memory: true, memory_mib: 1000 }
  - { name: job, repo: app, kind: launchd, tier: manual, profile: work, label: com.iu.job, memory_mib: 50 }
  - name: db
    repo: vps
    kind: compose
    tier: manual
    profile: dev-db
    container: mariadb
    needs: [vm]
    start: "make -C ~/vps up"
    stop: "make -C ~/vps down"
    memory_mib: 200
`
const load = () => {
  const r = parseRegistry(REGISTRY, "test", undefined, HOME)
  expect(r.errors).toEqual([])
  return r.services
}

const plist = (label: string, program = "/bin/true", domain: "gui" | "system" = "gui"): Plist => ({ label, path: `/p/${label}.plist`, program, domain })
const snap = (o: Partial<Snapshot> = {}): Snapshot => ({
  uid: 501, procs: [], pri: new Map(), loaded: [], disabled: new Set(), plists: [], systemRunning: new Set(), vms: new Map(), containers: new Map(), doors: [], ...o,
})

describe("registry parsing", () => {
  test("a valid file loads, ~/ expands and a compose service defaults to the default VM", () => {
    const s = load()
    expect(s.find((x) => x.name === "db")?.start).toBe("make -C /home/u/vps up")
    expect(s.find((x) => x.name === "db")?.vm).toBe("default")
    expect(s.find((x) => x.name === "web")?.doors).toEqual(["web"])
  })

  test("a repo file takes its repo from the directory", () => {
    const r = parseRegistry("services:\n  - { name: x, kind: launchd, tier: core, label: com.jkrumm.x, memory_mib: 1 }", "t", "myrepo", HOME)
    expect(r.errors).toEqual([])
    expect(r.services[0].repo).toBe("myrepo")
  })

  test.each([
    ["a bad tier", "{ name: x, repo: r, kind: launchd, tier: always, label: l, memory_mib: 1 }", "tier must be one of"],
    ["a bad kind", "{ name: x, repo: r, kind: cron, tier: core, memory_mib: 1 }", "kind must be one of"],
    ["a profile on a core service", "{ name: x, repo: r, kind: launchd, tier: core, profile: work, label: l, memory_mib: 1 }", "profile is only for tier manual"],
    ["an unknown profile", "{ name: x, repo: r, kind: launchd, tier: manual, profile: play, label: l, memory_mib: 1 }", "profile must be one of"],
    ["a launchd entry without a label", "{ name: x, repo: r, kind: launchd, tier: core, memory_mib: 1 }", "needs a label"],
    ["a compose entry without a container", "{ name: x, repo: r, kind: compose, tier: core, memory_mib: 1 }", "needs a container"],
    ["no budget", "{ name: x, repo: r, kind: launchd, tier: core, label: l }", "memory_mib"],
    ["no repo", "{ name: x, kind: launchd, tier: core, label: l, memory_mib: 1 }", "repo missing"],
  ])("%s is an error", (_, row, message) => {
    const r = parseRegistry(`services:\n  - ${row}`, "t", undefined, HOME)
    expect(r.errors.join("\n")).toContain(message)
  })

  test("duplicate names, one label under two brew names, and a need nobody provides", () => {
    const rows = parseRegistry(
      `services:
  - { name: a, repo: r, kind: launchd, tier: core, label: sh.brew.x, memory_mib: 1 }
  - { name: a, repo: r, kind: launchd, tier: core, label: homebrew.mxcl.x, memory_mib: 1 }
  - { name: b, repo: r, kind: compose, tier: core, container: c, needs: [ghost], memory_mib: 1 }`,
      "t", undefined, HOME,
    ).services
    const e = validate(rows).join("\n")
    expect(e).toContain("duplicate name a")
    expect(e).toContain("label homebrew.mxcl.x registered by a and a")
    expect(e).toContain("b: needs ghost")
  })

  test("repo files are read beside the host file, and a repo's job can not take a registered name", () => {
    const dir = mkdtempSync(join(tmpdir(), "mini-reg-"))
    mkdirSync(join(dir, "src", "myrepo"), { recursive: true })
    writeFileSync(join(dir, "host.yaml"), "services:\n  - { name: web, repo: dotfiles, kind: launchd, tier: core, label: com.jkrumm.web, memory_mib: 1 }")
    writeFileSync(join(dir, "src", "myrepo", "mini-services.yaml"), "services:\n  - { name: extra, kind: launchd, tier: core, label: com.jkrumm.extra, memory_mib: 1 }")
    const ok = loadAll([join(dir, "src")], join(dir, "host.yaml"), dir)
    expect(ok.errors).toEqual([])
    expect(ok.services.map((s) => [s.name, s.repo])).toEqual([["web", "dotfiles"], ["extra", "myrepo"]])
    writeFileSync(join(dir, "src", "myrepo", "mini-services.yaml"), "services:\n  - { name: web, kind: launchd, tier: core, label: com.jkrumm.other, memory_mib: 1 }")
    expect(loadAll([join(dir, "src")], join(dir, "host.yaml"), dir).errors.join()).toContain("duplicate name web")
  })

  test("two services of one compose project can not share a start or stop command", () => {
    const rows = parseRegistry(
      `services:
  - { name: a, repo: r, kind: compose, tier: core, container: a, project: p, start: "make up", stop: "make down", memory_mib: 1 }
  - { name: b, repo: r, kind: compose, tier: core, container: b, project: p, start: "make up", stop: "make down", memory_mib: 1 }
  - { name: c, repo: r, kind: compose, tier: core, container: c, project: q, start: "make up", memory_mib: 1 }`,
      "t", undefined, HOME,
    ).services
    const e = validate(rows).join("\n")
    expect(e).toContain("b and a share the start command")
    expect(e).toContain("b and a share the stop command")
    expect(e).not.toContain("c and")
  })

  test("the registry runs on the mini only", () => {
    expect(hostRefusal("cache")).toBeNull()
    expect(hostRefusal("op")).toContain("Mac mini")
    expect(hostRefusal("")).toContain("unset")
    expect(hostRefusal("op", true)).toBeNull()
  })

  test("the tracked registry is valid, names every door of the Caddyfile and gives every manual profile a member", () => {
    const real = loadAll()
    expect(real.errors).toEqual([])
    expect(real.services.length).toBeGreaterThan(100)
    expect(real.services.filter((s) => s.tier === "manual" && s.profile === "dev-db").map((s) => s.name)).toContain("mariadb")
    expect(real.services.find((s) => s.name === "rb")?.tier).toBe("core")
    const doors = real.services.flatMap((s) => s.doors)
    for (const d of ["argo-live", "brain", "rb", "linewatch", "fpp", "rollhook", "weatherorb-tiles"]) expect(doors).toContain(d)
  })
})

describe("probes", () => {
  const TOP = `PID    PPID  MEM    COMMAND
25264  1     92M    postgres
25270  25264 2119M  postgres
25271  25264 609M+  postgres
25272  25264 8785K  postgres
25273  25264 1G-    postgres
400    1     37M    caddy
`
  test("top: K, M and G units, trend marks, the command", () => {
    const p = parseTop(TOP)
    expect(p.map((x) => x.pid)).toEqual([25264, 25270, 25271, 25272, 25273, 400])
    expect(p[3].mib).toBeCloseTo(8785 / 1024)
    expect(p[4].mib).toBe(1024)
    expect(p[2].mib).toBe(609)
    expect(p[5].cmd).toBe("caddy")
  })

  test("a job's footprint is its tree; a shared-memory server is the largest process plus a capped private part", () => {
    const p = parseTop(TOP)
    const tree = treePids(25264, p)
    expect(tree).toHaveLength(5)
    expect(footprint(tree)).toBeCloseTo(92 + 2119 + 609 + 8785 / 1024 + 1024)
    expect(footprint(tree, true)).toBeCloseTo(2119 + 32 + 32 + 32 + 8785 / 1024)
  })

  test("launchctl list and print-disabled", () => {
    const rows = parseLaunchctlList("PID\tStatus\tLabel\n123\t0\tcom.jkrumm.a\n-\t78\tcom.jkrumm.b\n")
    expect(rows).toEqual([{ pid: 123, status: 0, label: "com.jkrumm.a" }, { pid: null, status: 78, label: "com.jkrumm.b" }])
    const d = parseDisabled('disabled services = {\n\t"com.jkrumm.c" => disabled\n\t"com.jkrumm.d" => enabled\n}')
    expect([...d]).toEqual(["com.jkrumm.c"])
  })

  test("docker ps and stats", () => {
    const c = parseContainers("a|p|running\nb||exited\n", "a|307.2MiB / 3GiB\nz|1GiB / 2GiB\n")
    expect(c).toEqual([{ name: "a", project: "p", state: "running", mib: 307.2 }, { name: "b", project: "", state: "exited", mib: null }])
  })

  test("brew labels match under either name", () => {
    expect(normalizeLabel("homebrew.mxcl.colima")).toBe(normalizeLabel("sh.brew.colima"))
  })
})

describe("grade", () => {
  const services = load()
  const procs = parseTop("PID PPID MEM COMMAND\n10 1 150M web\n11 10 20M helper\n20 1 10M x\n")

  test("running, stopped, not loaded and disabled launchd states with footprints", () => {
    const s = snap({
      procs,
      loaded: [{ pid: 10, status: 0, label: "com.jkrumm.web" }, { pid: null, status: 0, label: "homebrew.mxcl.thing" }],
      plists: [plist("com.jkrumm.web"), plist("sh.brew.thing"), plist("com.iu.job")],
    })
    const { rows } = grade(services, s)
    const by = (n: string) => rows.find((r) => r.name === n)!
    expect(by("web")).toMatchObject({ state: "running", footprint_mib: 170, over: true })
    expect(by("brewed").state).toBe("stopped")
    expect(by("job").state).toBe("not loaded")
    const d = grade(services, snap({ disabled: new Set(["com.iu.job"]), plists: [plist("com.iu.job")] })).rows.find((r) => r.name === "job")
    expect(d?.state).toBe("disabled")
  })

  test("a loaded job the registry does not know fails, naming it; removing it passes again", () => {
    const base = { loaded: [{ pid: 10, status: 0, label: "com.jkrumm.web" }], plists: [plist("com.jkrumm.web")] }
    expect(findings(...(Object.values(grade(services, snap(base))) as [never, never])).rc).toBe(0)
    const throwaway = snap({ loaded: [...base.loaded, { pid: null, status: 0, label: "com.jkrumm.throwaway" }], plists: [...base.plists, plist("com.jkrumm.throwaway")] })
    const g = grade(services, throwaway)
    const f = findings(g.rows, g.drift)
    expect(f.rc).toBe(1)
    expect(f.lines.join("\n")).toContain("com.jkrumm.throwaway")
    const gone = grade(services, snap(base))
    expect(findings(gone.rows, gone.drift).rc).toBe(0)
  })

  test("labels outside the families are not ours to know", () => {
    const g = grade(services, snap({ loaded: [{ pid: 1, status: 0, label: "com.apple.something" }, { pid: 2, status: 0, label: "com.google.keystone.agent" }] }))
    expect(g.drift.unknown_jobs).toEqual([])
  })

  test("a program inside a worktree fails even when the job is registered", () => {
    const wt = plist("com.jkrumm.web", "/bin/bash /home/u/src/repo/.claude/worktrees/factory-1-1/run.sh")
    const g = grade(services, snap({ loaded: [{ pid: null, status: 0, label: "com.jkrumm.web" }], plists: [wt] }))
    const f = findings(g.rows, g.drift)
    expect(f.rc).toBe(1)
    expect(f.lines.join("\n")).toContain("inside a worktree")
    // an installed but unloaded plist in a worktree is not a running job
    expect(grade(services, snap({ plists: [wt] })).drift.worktree_jobs).toEqual([])
  })

  test("a budget breach alone is a warning", () => {
    const g = grade(services, snap({ procs, loaded: [{ pid: 10, status: 0, label: "com.jkrumm.web" }], plists: [plist("com.jkrumm.web")] }))
    const f = findings(g.rows, g.drift)
    expect(f.rc).toBe(2)
    expect(f.lines).toEqual(["WARN over budget: web 170 MiB of 100"])
  })

  test("containers, VMs, missing entries, unknown containers and unclaimed doors", () => {
    const s = snap({
      vms: new Map([["default", { running: true, mib: 3200 }]]),
      containers: new Map([["default", [{ name: "mariadb", project: "vps", state: "running", mib: 104 }, { name: "stray", project: "", state: "created", mib: null }]]]),
      doors: ["web", "ghost-door"],
    })
    const g = grade(services, s)
    const by = (n: string) => g.rows.find((r) => r.name === n)!
    expect(by("colima-default")).toMatchObject({ state: "running", footprint_mib: 3200 })
    expect(by("db")).toMatchObject({ state: "running", footprint_mib: 104 })
    expect(g.drift.unknown_containers).toEqual(["default/stray"])
    expect(g.drift.unclaimed_doors).toEqual(["ghost-door"])
    expect(g.drift.missing).toContain("web")
    // db is a manual compose service with no container: its project is down, which is normal
    expect(g.drift.missing).not.toContain("db")
    // a stopped VM means its containers are stopped, not absent
    expect(grade(services, snap()).rows.find((r) => r.name === "db")?.state).toBe("stopped")
  })

  test("a daemon is read from the system domain", () => {
    const svc = parseRegistry("services:\n  - { name: caddy, repo: d, kind: launchd, tier: core, label: sh.brew.caddy, daemon: true, process: caddy, memory_mib: 100 }", "t", undefined, HOME).services
    const s = snap({ procs, plists: [plist("sh.brew.caddy", "/x", "system")], systemRunning: new Set(["sh.brew.caddy"]) })
    expect(grade(svc, s).rows[0]).toMatchObject({ state: "running" })
    expect(grade(svc, snap()).rows[0].state).toBe("not installed")
  })
})

describe("verbs", () => {
  const services = load()

  test("an unknown name and a core stop are refused, FORCE lets the core stop through", () => {
    expect(refusal(services, "up", "nope", false)).toContain("unknown service 'nope'")
    expect(refusal(services, "down", "web", false)).toContain("core")
    expect(refusal(services, "down", "web", true)).toBeNull()
    expect(refusal(services, "down", "db", false)).toBeNull()
    expect(refusal(services, "up", "web", false)).toBeNull()
  })

  test("a service starts after what it needs, and only what is not running", () => {
    const db = services.find((s) => s.name === "db")!
    expect(startOrder(db, services, () => false).map((s) => s.name)).toEqual(["colima-default", "db"])
    expect(startOrder(db, services, (n) => n === "colima-default").map((s) => s.name)).toEqual(["db"])
  })

  test("a needs cycle is an error", () => {
    const a = parseRegistry("services:\n  - { name: a, repo: r, kind: launchd, tier: core, label: l.a, needs: [b], memory_mib: 1 }\n  - { name: b, repo: r, kind: launchd, tier: core, label: l.b, needs: [a], memory_mib: 1 }", "t", undefined, HOME).services
    expect(() => startOrder(a[0], a, () => false)).toThrow("cycle")
  })

  test("a registered command runs through sh, launchd falls back to launchctl, argv only", () => {
    const s = snap({ loaded: [{ pid: 1, status: 0, label: "homebrew.mxcl.thing" }], plists: [plist("com.iu.job"), plist("sh.brew.thing")] })
    const db = stepFor(services.find((x) => x.name === "db")!, "start", s)
    expect(db).toMatchObject({ argv: ["sh", "-c", "make -C /home/u/vps up"] })
    // the loaded label is the one launchd knows, whatever the registry calls it
    const stop = stepFor(services.find((x) => x.name === "brewed")!, "stop", s)
    expect(stop).toMatchObject({ argv: ["launchctl", "bootout", "gui/501/homebrew.mxcl.thing"], shell: false })
    expect(stepFor(services.find((x) => x.name === "brewed")!, "start", s)).toMatchObject({ argv: ["launchctl", "kickstart", "gui/501/homebrew.mxcl.thing"] })
    const start = stepFor(services.find((x) => x.name === "job")!, "start", s)
    expect(start).toMatchObject({ argv: ["sh", "-c", "launchctl enable gui/501/com.iu.job && launchctl bootstrap gui/501 '/p/com.iu.job.plist'"] })
  })

  test("the vps dev databases start and stop one service each, so naming mariadb can not start redis", () => {
    const real = loadAll().services
    const cmd = (n: string, v: "start" | "stop") => real.find((x) => x.name === n)?.[v]
    expect(cmd("mariadb", "start")).toMatch(/ dev-mariadb-up$/)
    expect(cmd("mariadb", "stop")).toMatch(/ dev-mariadb-down$/)
    expect(cmd("redis", "start")).toMatch(/ dev-redis-up$/)
    expect(cmd("redis", "stop")).toMatch(/ dev-redis-down$/)
    expect(cmd("clickstack", "start")).toMatch(/ clickstack-up$/)
    for (const n of ["mariadb", "redis", "clickstack"]) for (const v of ["start", "stop"] as const) expect(cmd(n, v)).not.toMatch(/ (up|down)$/)
  })

  test("what has no command or no plist says so instead of guessing", () => {
    const s = snap()
    expect(stepFor(services.find((x) => x.name === "colima-default")!, "start", s)).toContain("no start command registered")
    expect(stepFor(services.find((x) => x.name === "job")!, "start", s)).toContain("no plist installed")
    expect(stepFor(services.find((x) => x.name === "job")!, "stop", s)).toContain("not loaded")
  })
})

describe("process type", () => {
  const reg = (extra: string) => parseRegistry(`services:\n  - ${extra}`, "t", undefined, HOME)
  const pg = (type = "interactive") => `{ name: pg, repo: dotfiles, kind: launchd, tier: core, label: "sh.brew.postgresql@18", process_type: ${type}, memory_mib: 1000 }`
  const procs = parseTop("PID PPID MEM COMMAND\n10 1 150M postgres\n11 10 20M postgres\n")
  const loaded = [{ pid: 10, status: 0, label: "sh.brew.postgresql@18" }]
  const grading = (pri: string, processType?: string) => {
    const services = reg(pg()).services
    const g = grade(services, snap({ procs, pri: parsePri(pri), loaded, plists: [{ ...plist("sh.brew.postgresql@18"), processType }] }))
    return { row: g.rows[0], f: findings(g.rows, g.drift) }
  }

  test("only interactive, only on a core launchd service", () => {
    expect(reg(pg()).errors).toEqual([])
    expect(reg(pg("background")).errors.join()).toContain("process_type must be one of interactive")
    expect(reg("{ name: j, repo: r, kind: launchd, tier: manual, label: l, process_type: interactive, memory_mib: 1 }").errors.join()).toContain("only for a launchd service of tier core")
    expect(reg("{ name: c, repo: r, kind: compose, tier: core, container: c, process_type: interactive, memory_mib: 1 }").errors.join()).toContain("only for a launchd service of tier core")
  })

  test("parsePri reads `ps -axo pid=,pri=`", () => {
    expect([...parsePri("    1  20\n 4242  31\n")]).toEqual([[1, 20], [4242, 31]])
  })

  test("an Interactive entry running at the terminal band and with the key in its plist is clean", () => {
    const { row, f } = grading("10 31\n11 31\n", "Interactive")
    expect(row).toMatchObject({ state: "running", pri: 31, below_band: false })
    expect(f).toEqual({ lines: [], rc: 0 })
  })

  test("an Interactive entry running lower fails, naming the priority", () => {
    const { row, f } = grading("10 20\n11 20\n", "Interactive")
    expect(row.below_band).toBe(true)
    expect(f.rc).toBe(1)
    expect(f.lines.join("\n")).toContain("FAIL runs below its declared process type: pg at priority 20")
  })

  test("a plist that lost the key fails even while the process still runs at 31 (brew rewrote it)", () => {
    const { f } = grading("10 31\n", undefined)
    expect(f.rc).toBe(1)
    expect(f.lines.join("\n")).toContain("FAIL plist has no ProcessType interactive: pg (key missing")
  })

  test("a stopped service has no priority to grade, and an entry without the field is never graded", () => {
    const services = reg(pg()).services
    const stopped = grade(services, snap({ procs, pri: parsePri("10 20\n"), loaded: [{ pid: null, status: 0, label: "sh.brew.postgresql@18" }], plists: [plist("sh.brew.postgresql@18")] }))
    expect(stopped.rows[0]).toMatchObject({ state: "stopped", pri: null, below_band: false })
    const plain = grade(load(), snap({ procs, pri: parsePri("10 20\n"), loaded: [{ pid: 10, status: 0, label: "com.jkrumm.web" }], plists: [plist("com.jkrumm.web")] }))
    expect(plain.rows.find((r) => r.name === "web")).toMatchObject({ pri: 20, below_band: false })
  })

  test("a system daemon is read by its process name", () => {
    const services = reg("{ name: caddy, repo: d, kind: launchd, tier: core, label: sh.brew.caddy, daemon: true, process: caddy, process_type: interactive, memory_mib: 1 }").services
    const g = grade(services, snap({
      procs: parseTop("PID PPID MEM COMMAND\n364 1 50M caddy\n"), pri: parsePri("364 20\n"),
      plists: [{ ...plist("sh.brew.caddy", "/x", "system"), processType: "Interactive" }], systemRunning: new Set(["sh.brew.caddy"]),
    }))
    expect(g.rows[0]).toMatchObject({ state: "running", pri: 20, below_band: true })
  })

  test("the host registry declares the control plane Interactive", () => {
    const declared = loadAll().services.filter((s) => s.process_type).map((s) => s.name)
    for (const n of ["postgres", "software-factory", "factory-door", "kuma-door"]) expect(declared).toContain(n)
  })
})

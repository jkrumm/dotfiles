import { describe, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  type Container, type Plist, type Snapshot, footprint, findings, grade, loadAll, normalizeLabel, parseContainers, parseDisabled,
  canVerb, listenerPids, parseDoorPorts, parseListeners, startDetached, stopListeners,
  debtLines, gradeRules, hostRefusal, parseInspect, pruneActions, parseLaunchctlList, parsePri, parseRegistry, parseTop, refusal, startOrder, stepFor, treePids, validate,
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

  test("a port is a list of TCP ports and two services can not claim one", () => {
    const rows = parseRegistry(
      `services:
  - { name: a, repo: r, kind: launchd, tier: core, label: com.jkrumm.a, ports: [4416, 4417], memory_mib: 1 }
  - { name: b, repo: r, kind: launchd, tier: core, label: com.jkrumm.b, ports: [4417], memory_mib: 1 }`,
      "t", undefined, HOME,
    )
    expect(rows.errors).toEqual([])
    expect(rows.services[0].ports).toEqual([4416, 4417])
    expect(validate(rows.services).join("\n")).toContain("port 4417 registered by a and b")
    const bad = parseRegistry("services:\n  - { name: x, repo: r, kind: launchd, tier: core, label: l, ports: [http], memory_mib: 1 }", "t", undefined, HOME)
    expect(bad.errors.join()).toContain("ports must be a list of TCP port numbers")
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

  describe("lint: a file under edit against everyone else's rows", () => {
    const setup = () => {
      const dir = mkdtempSync(join(tmpdir(), "mini-reg-"))
      mkdirSync(join(dir, "src", "myrepo"), { recursive: true })
      mkdirSync(join(dir, "src", "other"), { recursive: true })
      writeFileSync(join(dir, "src", "other", "mini-services.yaml"), "services:\n  - { name: owned, kind: launchd, tier: core, label: com.jkrumm.owned, memory_mib: 1 }")
      // the checkout's own file is stale: the candidate replaces it, so its old row is not a clash with the new one
      writeFileSync(join(dir, "src", "myrepo", "mini-services.yaml"), "services:\n  - { name: old, kind: launchd, tier: core, label: com.jkrumm.mine, memory_mib: 1 }")
      writeFileSync(join(dir, "host.yaml"), "services:\n  - { name: web, repo: dotfiles, kind: launchd, tier: core, label: com.jkrumm.web, memory_mib: 1 }")
      return dir
    }
    const candidate = (dir: string, row: string) => {
      const file = join(dir, "candidate.yaml")
      writeFileSync(file, `services:\n  - ${row}`)
      return file
    }

    test("a second row for a label another repo owns is an error, a fresh label is not", () => {
      const dir = setup()
      const clash = loadAll([join(dir, "src")], join(dir, "host.yaml"), dir, {
        repo: "myrepo", file: candidate(dir, "{ name: dup, kind: launchd, tier: core, label: com.jkrumm.owned, memory_mib: 1 }"),
      })
      expect(clash.errors.join()).toContain("label com.jkrumm.owned registered by owned and dup")
      const fine = loadAll([join(dir, "src")], join(dir, "host.yaml"), dir, {
        repo: "myrepo", file: candidate(dir, "{ name: mine, kind: launchd, tier: core, label: com.jkrumm.mine, memory_mib: 1 }"),
      })
      expect(fine.errors).toEqual([])
      expect(fine.services.map((s) => s.name).sort()).toEqual(["mine", "owned", "web"])
    })

    test("a host-file candidate replaces the host file and meets the repos' rows", () => {
      const dir = setup()
      const file = candidate(dir, "{ name: owned, repo: dotfiles, kind: launchd, tier: core, label: com.jkrumm.web, memory_mib: 1 }")
      expect(loadAll([join(dir, "src")], join(dir, "host.yaml"), dir, { file }).errors.join()).toContain("duplicate name owned")
    })

    test("the CLI exits 1 naming the clash and 0 when there is none", () => {
      const dir = setup()
      const run = (row: string) => Bun.spawnSync(["bun", join(import.meta.dir, "mini-registry.ts"), "lint", "--repo", "myrepo", "--file", candidate(dir, row)], {
        env: { ...process.env, MINI_REGISTRY_ROOTS: join(dir, "src") },
      })
      const bad = run("{ name: dup, kind: launchd, tier: core, label: com.jkrumm.owned, memory_mib: 1 }")
      expect(bad.exitCode).toBe(1)
      expect(bad.stderr.toString()).toContain("registered by owned and dup")
      expect(run("{ name: mine, kind: launchd, tier: core, label: com.jkrumm.mine2, memory_mib: 1 }").exitCode).toBe(0)
    })
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

  test("one VM, always on: the work stack and the sandbox are core, so the work profile's down verb never reaches them", () => {
    const { services } = loadAll()
    expect(services.filter((s) => s.kind === "vm").map((s) => s.name)).toEqual(["colima-default"])
    const core = ["vpn", "prometheus-vpn-watcher", "prometheus-stack-dashboard", "prometheus-dashboard-autodeploy",
      "prometheus-state-backup", "prometheus-artefact-daily", "prometheus-conduktor-token", "prometheus-epos-token", "tool-checkout-deploy",
      "teamchat-opencode", "teamchat-relay", "teamchat-egress"]
    for (const n of core) expect(services.find((s) => s.name === n)?.tier).toBe("core")
    for (const n of ["dashboard-api", "dashboard-ui"]) expect(services.find((s) => s.name === n)?.tier).toBe("manual")
    // the selection `mini-registry profile work --down` makes
    const members = services.filter((s) => s.tier === "manual" && s.profile === "work").map((s) => s.name)
    expect(members.length).toBeGreaterThan(0)
    for (const m of members) expect(m.startsWith("idss-")).toBe(true)
    const vm = services.find((s) => s.name === "colima-default")!
    expect(vm.memory_mib).toBeLessThanOrEqual(3400)
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
    // the flag outlives a pruned plist: that is a row to delete (drift.missing), not a leftover to warn about
    const pruned = grade(services, snap({ disabled: new Set(["com.iu.job"]) }))
    expect(pruned.rows.find((r) => r.name === "job")?.state).toBe("not installed")
    expect(pruned.drift.disabled).toEqual([])
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

  test("leftovers are warnings: a container no row names and a disabled job whose plist is still installed", () => {
    const stray = snap({
      vms: new Map([["default", { running: true, mib: 3200 }]]),
      containers: new Map([["default", [{ name: "stray", project: "", state: "created", mib: null }]]]),
      disabled: new Set(["com.iu.job"]),
      plists: [plist("com.iu.job")],
    })
    const g = grade(services, stray)
    const f = findings(g.rows, g.drift)
    expect(f.rc).toBe(2)
    expect(f.lines).toContain("WARN container the registry does not know: default/stray (register it, or make mini-prune)")
    expect(f.lines).toContain("WARN disabled but still installed: job (make mini-prune removes the plist)")
    // a registered container in another VM than its row declares is the second-vm rule's finding, not an unknown container
    const moved = snap({ vms: new Map([["teamchat", { running: true, mib: 100 }]]), containers: new Map([["teamchat", [{ name: "mariadb", project: "vps", state: "running", mib: 10 }]]]) })
    expect(grade(services, moved).drift.unknown_containers).toEqual([])
  })

  test("prune removes a disabled plist (registered or not) and a stopped unknown container, never a running one", () => {
    const s = snap({
      vms: new Map([["default", { running: true, mib: 3200 }]]),
      containers: new Map([["default", [
        { name: "dead", project: "", state: "exited", mib: null },
        { name: "made", project: "", state: "created", mib: null },
        { name: "alive", project: "", state: "running", mib: 5 },
      ]]]),
      disabled: new Set(["com.iu.job", "com.jkrumm.gone", "com.jkrumm.off-but-elsewhere"]),
      plists: [
        { ...plist("com.iu.job"), path: "/home/u/Library/LaunchAgents/com.iu.job.plist" },
        { ...plist("com.jkrumm.gone"), path: "/home/u/Library/LaunchAgents/com.jkrumm.gone.plist" },
        { ...plist("com.jkrumm.off-but-elsewhere"), path: "/Library/LaunchAgents/com.jkrumm.off-but-elsewhere.plist" },
        { ...plist("com.jkrumm.fine"), path: "/home/u/Library/LaunchAgents/com.jkrumm.fine.plist" },
      ],
    })
    const g = grade(services, s)
    const actions = pruneActions(services, g.rows, s, g.drift, "/home/u/Library/LaunchAgents")
    expect(actions.filter((a) => a.kind === "plist").map((a) => a.path).sort()).toEqual([
      "/home/u/Library/LaunchAgents/com.iu.job.plist",
      "/home/u/Library/LaunchAgents/com.jkrumm.gone.plist",
    ])
    expect(actions.filter((a) => a.kind === "container").map((a) => a.name).sort()).toEqual(["dead", "made"])
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

describe("run rules", () => {
  const reg = (...rows: string[]) => {
    const r = parseRegistry(`services:\n${rows.map((x) => `  - ${x}`).join("\n")}`, "t", undefined, HOME)
    expect(r.errors).toEqual([])
    return r.services
  }
  const vm = "{ name: colima-default, repo: d, kind: vm, tier: core, vm: default, memory_mib: 4000 }"
  const app = (extra = "", tier = "manual") => `{ name: app, repo: r, kind: compose, tier: ${tier}, container: app, needs: [vm], memory_mib: 100${extra} }`
  const containers = (c: Partial<Container>) => new Map([["default", [{ name: "app", project: "p", state: "running", mib: 10, image: "app:1", restart: "no", limit_mib: 256, bind_hosts: ["127.0.0.1"], ...c }]]])
  const check = (services: ReturnType<typeof reg>, c: Partial<Container> = {}) => {
    const s = snap({ containers: containers(c) })
    const g = grade(services, s)
    const rules = gradeRules(services, s)
    return { rules, f: findings(g.rows, g.drift, rules) }
  }

  test("inspect output: restart policy, limit in MiB, the host of every published port", () => {
    const m = parseInspect("/app|app:1|unless-stopped|268435456|[127.0.0.1][]\n/db|mariadb:11|no|0|\n")
    expect(m.get("app")).toEqual({ image: "app:1", restart: "unless-stopped", limit_mib: 256, bind_hosts: ["127.0.0.1", ""] })
    expect(m.get("db")).toMatchObject({ restart: "no", limit_mib: 0, bind_hosts: [] })
  })

  test("a compliant container passes", () => {
    expect(check(reg(vm, app())).f.rc).toBe(0)
  })

  test("restart unless-stopped with no debt field fails, naming the service and the rule; the debt field passes it and is listed", () => {
    const failing = check(reg(vm, app()), { restart: "unless-stopped" })
    expect(failing.f.rc).toBe(1)
    expect(failing.f.lines.join("\n")).toMatch(/FAIL app breaks rule restart-policy/)
    const recorded = check(reg(vm, app(", debt: { restart-policy: some-row }")), { restart: "unless-stopped" })
    expect(recorded.f.rc).toBe(0)
    expect(debtLines(recorded.rules)[0]).toContain("app: restart-policy -> some-row")
  })

  test("a debt field with no breach is stale and fails until it is removed", () => {
    const stale = check(reg(vm, app(", debt: { restart-policy: some-row }")))
    expect(stale.f.rc).toBe(1)
    expect(stale.f.lines.join("\n")).toContain("app: the restart-policy breach is gone, remove its debt/exception field")
  })

  test("a container that is not there is not judged, so its field is not stale", () => {
    const services = reg(vm, app(", debt: { no-memory-limit: some-row }"))
    const s = snap({ containers: new Map([["default", []]]) })
    expect(gradeRules(services, s).stale).toEqual([])
  })

  test("a core service may restart itself; nothing else may", () => {
    expect(check(reg(vm, app("", "core")), { restart: "unless-stopped" }).f.rc).toBe(0)
    expect(check(reg(vm, app("", "on-demand")), { restart: "always" }).f.rc).toBe(1)
  })

  test("no memory limit and a port that is not on 127.0.0.1", () => {
    expect(check(reg(vm, app()), { limit_mib: 0 }).f.lines.join()).toContain("app breaks rule no-memory-limit")
    expect(check(reg(vm, app()), { bind_hosts: ["127.0.0.1", ""] }).f.lines.join()).toContain("published on 0.0.0.0")
    expect(check(reg(vm, app()), { bind_hosts: ["0.0.0.0"] }).rules.failures[0].rule).toBe("port-binding")
  })

  test("a Postgres or cache image is a breach, a native cache is allowed once, a second Postgres never", () => {
    expect(check(reg(vm, app()), { image: "valkey/valkey:8-alpine" }).rules.failures[0].rule).toBe("shared-infrastructure")
    expect(check(reg(vm, app()), { image: "postgres:18" }).rules.failures[0].rule).toBe("shared-infrastructure")
    expect(check(reg(vm, app()), { image: "redis-exporter:1" }).f.rc).toBe(0)
    const native = (n: string, l: string) => `{ name: ${n}, repo: d, kind: launchd, tier: core, label: ${l}, memory_mib: 50 }`
    const one = gradeRules(reg(native("postgres", '"sh.brew.postgresql@18"'), native("valkey", "com.jkrumm.valkey")), snap())
    expect(one.failures).toEqual([])
    const two = gradeRules(reg(native("postgres", '"sh.brew.postgresql@18"'), native("pg2", "com.iu.athena-postgres"), native("valkey", "com.jkrumm.valkey"), native("redis", "com.jkrumm.redis")), snap())
    expect(two.failures.map((b) => b.service).sort()).toEqual(["pg2", "redis"])
  })

  test("an exception is allowed and listed with its reason", () => {
    const r = check(reg(vm, app(', exception: { shared-infrastructure: "mirrors production" }')), { image: "valkey/valkey:8" })
    expect(r.f.rc).toBe(0)
    expect(debtLines(r.rules).join()).toContain("allowed: mirrors production")
  })

  test("a second VM, an entry with no budget and a worktree program", () => {
    const services = reg(vm, "{ name: colima-x, repo: d, kind: vm, tier: on-demand, vm: x, memory_mib: 4000 }",
      "{ name: nobudget, repo: d, kind: launchd, tier: core, label: com.jkrumm.nb, memory_mib: 0 }",
      "{ name: onceoff, repo: d, kind: launchd, tier: core, label: com.jkrumm.once, daemon: true, oneshot: true, memory_mib: 0 }",
      "{ name: wt, repo: d, kind: launchd, tier: core, label: com.jkrumm.wt, memory_mib: 50 }")
    const rules = gradeRules(services, snap({ loaded: [{ pid: 1, status: 0, label: "com.jkrumm.wt" }], plists: [plist("com.jkrumm.wt", "/r/.claude/worktrees/x/run.sh")] }))
    expect(rules.failures.map((b) => `${b.service}:${b.rule}`).sort()).toEqual(["colima-x:second-vm", "nobudget:no-budget", "wt:worktree-program"])
    const f = findings([], { unknown_jobs: [], worktree_jobs: ["com.jkrumm.wt (/r/.claude/worktrees/x/run.sh)"], unknown_installed: [], missing: [], unknown_containers: [], unclaimed_doors: [], disabled: [] }, rules)
    expect(f.lines.filter((l) => l.includes("worktree")).length).toBe(1)
  })

  test("a debt or exception field names a known rule and a reason", () => {
    const bad = parseRegistry("services:\n  - { name: x, repo: r, kind: launchd, tier: core, label: l, memory_mib: 1, debt: { restart-polcy: row }, exception: { port-binding: \"\" } }", "t", undefined, HOME)
    expect(bad.errors.join()).toContain("unknown rule restart-polcy")
    expect(bad.errors.join()).toContain("exception.port-binding must name the reason it is allowed")
  })

  test("the core budgets of a VM add up to what the VM has; a wide mem_limit cap is not a budget", () => {
    const big = "{ name: big, repo: r, kind: compose, tier: core, container: big, needs: [vm], memory_mib: 4500 }"
    const over = check(reg(vm, big), { name: "big" })
    expect(over.rules.warnings[0]).toContain("4500 MiB")
    expect(over.f.rc).toBe(2)
    const wide = check(reg(vm, app("", "core")), { limit_mib: 5000 })
    expect(wide.rules.warnings).toEqual([])
    expect(wide.f.rc).toBe(0)
  })

  test("the tracked registry passes its own rules on a quiet host", () => {
    const { services, listed, errors } = loadAll()
    expect(errors).toEqual([])
    expect(listed.length).toBeGreaterThan(0)
    const r = gradeRules(services, snap(), listed)
    expect(r.failures.filter((b) => b.rule !== "worktree-program").map((b) => `${b.service}:${b.rule}`)).toEqual([])
  })
})

describe("dev servers: listeners are the state", () => {
  const DEV = parseRegistry(`
services:
  - { name: pg, repo: basalt-ui, kind: dev-server, tier: on-demand, door: [pg-door, pg-api], start: "cd ~/basalt-ui && bun run dev", idle_minutes: 10, memory_mib: 400 }
  - { name: bare, repo: r, kind: dev-server, tier: on-demand, door: bare-door, memory_mib: 400 }
  - { name: stopcmd, repo: r, kind: dev-server, tier: on-demand, door: stop-door, stop: "make -C ~/r down", memory_mib: 400 }
  - { name: nodoor, repo: r, kind: dev-server, tier: on-demand, memory_mib: 400 }
`, "t", undefined, HOME)
  const [pg, bare, stopcmd, nodoor] = DEV.services
  const live = snap({
    doorPorts: new Map([["pg-door", 7710], ["pg-api", 7711], ["bare-door", 7712]]),
    listeners: new Map([[7711, [300]]]),
    procs: [{ pid: 300, ppid: 1, mib: 200, cmd: "bun" }, { pid: 301, ppid: 300, mib: 150, cmd: "node" }, { pid: 9, ppid: 1, mib: 999, cmd: "other" }],
  })

  test("the registry parses idle_minutes and refuses a bad one", () => {
    expect(DEV.errors).toEqual([])
    expect(pg.idle_minutes).toBe(10)
    expect(parseRegistry("services:\n  - { name: x, repo: r, kind: dev-server, tier: on-demand, idle_minutes: 0, memory_mib: 1 }", "t", undefined, HOME).errors[0]).toContain("idle_minutes")
  })

  test("running when any door port has a listener; the footprint is the listener's tree", () => {
    const rows = grade(DEV.services, live).rows
    expect(rows.find((r) => r.name === "pg")).toMatchObject({ state: "running", footprint_mib: 350, can_start: true, can_stop: true, idle_minutes: 10 })
    expect(rows.find((r) => r.name === "bare")).toMatchObject({ state: "stopped", can_start: false, can_stop: false, idle_minutes: 30 })
    expect(rows.find((r) => r.name === "nodoor")).toMatchObject({ state: "stopped", can_stop: false })
  })

  test("listenerPids follows the doors only", () => {
    expect(listenerPids(pg, live)).toEqual([300])
    expect(listenerPids(bare, live)).toEqual([])
  })

  test("parsers: caddy-registry lines and lsof -Fpn", () => {
    expect(parseDoorPorts("a\t7710\t0\t-\nb\t7711\t1\t/x/*\n\n")).toEqual(new Map([["a", 7710], ["b", 7711]]))
    const m = parseListeners("p10\nf5\nn*:7710\nf6\nn[::1]:7710\np11\nf3\nn127.0.0.1:7711\nn*:7712\n")
    expect(m.get(7710)).toEqual([10])
    expect(m.get(7711)).toEqual([11])
    expect(m.get(7712)).toEqual([11])
  })

  test("start is a detached step, stop with no command is a signal step, a missing command is refused", () => {
    expect(stepFor(pg, "start", live)).toMatchObject({ mode: "detach", argv: ["sh", "-c", "cd /home/u/basalt-ui && bun run dev"] })
    expect(stepFor(pg, "stop", live)).toMatchObject({ mode: "kill", argv: [] })
    expect(stepFor(bare, "start", live)).toContain("no start command")
    expect(stepFor(bare, "stop", snap({ doorPorts: new Map([["bare-door", 7712]]), listeners: new Map([[7712, [77]]]) }))).toContain("does not signal")
    expect(stepFor(stopcmd, "stop", live)).toMatchObject({ argv: ["sh", "-c", "make -C /home/u/r down"] })
  })

  test("canVerb: a dev server stops with no command and starts only with one", () => {
    expect(canVerb(pg, "start")).toBe(true)
    expect(canVerb(bare, "start")).toBe(false)
    // a dev server the registry does not start is never signalled: its door port may belong to something else (a docker forwarder)
    expect(canVerb(bare, "stop")).toBe(false)
    expect(canVerb(pg, "stop")).toBe(true)
    expect(canVerb(stopcmd, "stop")).toBe(true)
    expect(canVerb(nodoor, "stop")).toBe(false)
    expect(canVerb(load().find((x) => x.name === "web")!, "start")).toBe(true)
    expect(canVerb(load().find((x) => x.name === "db")!, "stop")).toBe(true)
  })
})

describe("dev servers: a real detached start and a signal stop", () => {
  // the pgid record and the start log of these tests go to a scratch directory, never the live ones
  const scratch = mkdtempSync(join(tmpdir(), "mini-apps-state-"))
  process.env.MINI_APPS_STATE_DIR = join(scratch, "state")
  process.env.MINI_APPS_LOG_DIR = join(scratch, "logs")

  // the start command is a tiny listener on a free port; the door "t-door" maps to it
  async function freePort(): Promise<number> {
    const s = Bun.serve({ port: 0, fetch: () => new Response("") })
    const port = s.port as number
    await s.stop(true)
    return port
  }

  test("startDetached waits for the door, the process outlives the verb, stopListeners ends its group", async () => {
    const port = await freePort()
    const script = join(mkdtempSync(join(tmpdir(), "mini-apps-")), "serve.ts")
    writeFileSync(script, `Bun.serve({ port: ${port}, hostname: "127.0.0.1", fetch: () => new Response("up") }); setInterval(() => {}, 1000)`)
    const svc = parseRegistry(`services:\n  - { name: itest-dev, repo: r, kind: dev-server, tier: on-demand, door: t-door, start: "exec ${process.execPath} ${script}", memory_mib: 1 }`, "t", undefined, HOME).services[0]
    const doorPorts = new Map([["t-door", port]])
    const step = stepFor(svc, "start", snap({ doorPorts }))
    expect(typeof step).not.toBe("string")
    expect(await startDetached(svc, step as Parameters<typeof startDetached>[1], { doorPorts }, 15000)).toBe(0)
    expect((await fetch(`http://127.0.0.1:${port}/`).then((r) => r.text()))).toBe("up")

    const listeners = new Map([[port, [Number((await Bun.$`lsof -nP -iTCP:${port} -sTCP:LISTEN -t`.text()).trim().split("\n")[0])]]])
    const procs = parseTop(await Bun.$`top -l 1 -stats pid,ppid,mem,command`.text())
    expect(await stopListeners(svc, { procs, doorPorts, listeners })).toBe(0)
    await Bun.sleep(300)
    await expect(fetch(`http://127.0.0.1:${port}/`)).rejects.toBeDefined()
  }, 40000)

  test("a start command that exits at once is reported, not waited out", async () => {
    const svc = parseRegistry(`services:\n  - { name: itest-dead, repo: r, kind: dev-server, tier: on-demand, door: t-door, start: "exit 3", memory_mib: 1 }`, "t", undefined, HOME).services[0]
    const step = stepFor(svc, "start", snap()) as Parameters<typeof startDetached>[1]
    const t0 = Date.now()
    expect(await startDetached(svc, step, { doorPorts: new Map([["t-door", 1]]) }, 20000)).toBe(1)
    expect(Date.now() - t0).toBeLessThan(5000)
  })
})

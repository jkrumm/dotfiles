import { describe, expect, test } from "bun:test"
import {
  ageHours,
  applyUpdate,
  bumpFormula,
  capToPin,
  cmpVersion,
  type CoreStatus,
  formulaVersion,
  type Host,
  type Job,
  UpdateFailed,
  parseJob,
  parsePin,
  parseVersion,
  pickCandidate,
  previousVersion,
  readyTimeoutS,
} from "./herdr-core-update.ts"

const FORMULA = `class HerdrCore < Formula
  version "0.1.15"
  on_arm do
    url "https://x/#{version}/a.tar.gz"
    sha256 "${"a".repeat(64)}" # herdr-core-arm
  end
  on_intel do
    url "https://x/#{version}/i.tar.gz"
    sha256 "${"b".repeat(64)}" # herdr-core-intel
  end
end
`

describe("versions", () => {
  test("parse and compare", () => {
    expect(parseVersion("0.1.15")).toEqual([0, 1, 15])
    expect(parseVersion("0.1.15-beta")).toBeNull()
    expect(cmpVersion("0.1.15", "0.1.9")).toBeGreaterThan(0)
    expect(cmpVersion("0.2.0", "0.1.99")).toBeGreaterThan(0)
    expect(cmpVersion("0.1.15", "0.1.15")).toBe(0)
    expect(() => cmpVersion("x", "0.1.1")).toThrow()
  })
  test("previous stops at .0", () => {
    expect(previousVersion("0.1.15")).toBe("0.1.14")
    expect(previousVersion("0.2.0")).toBeNull()
  })
})

describe("pickCandidate", () => {
  const now = Date.parse("2026-10-31T12:00:00Z")
  const at = (h: number) => now - h * 3_600_000
  const dates: Record<string, number> = { "0.1.15": at(5), "0.1.14": at(30), "0.1.13": at(50) }
  const published = async (v: string) => dates[v] ?? null

  test("skips a release younger than the minimum age", async () => {
    const r = await pickCandidate({ latest: "0.1.15", published, minAgeHours: 24, nowMs: now })
    expect(r.version).toBe("0.1.14")
  })
  test("takes latest when it is old enough", async () => {
    const r = await pickCandidate({ latest: "0.1.15", published, minAgeHours: 1, nowMs: now })
    expect(r.version).toBe("0.1.15")
  })
  test("skips versions that do not exist", async () => {
    const r = await pickCandidate({ latest: "0.1.17", published, minAgeHours: 24, nowMs: now })
    expect(r.version).toBe("0.1.14")
  })
  test("reports when nothing is old enough", async () => {
    const r = await pickCandidate({ latest: "0.1.15", published, minAgeHours: 500, nowMs: now })
    expect(r.version).toBeNull()
  })
  test("age in hours", () => expect(ageHours(at(3), now)).toBeCloseTo(3))
})

describe("bumpFormula", () => {
  test("rewrites version and both shas, keeps markers", () => {
    const out = bumpFormula({ src: FORMULA, version: "0.1.16", shas: { arm: "c".repeat(64), intel: "d".repeat(64) } })
    expect(formulaVersion(out)).toBe("0.1.16")
    expect(out).toContain(`"${"c".repeat(64)}" # herdr-core-arm`)
    expect(out).toContain(`"${"d".repeat(64)}" # herdr-core-intel`)
  })
  test("throws when the markers are missing", () => {
    expect(() => bumpFormula({ src: 'version "0.1.15"\n', version: "0.1.16", shas: { arm: "c".repeat(64), intel: "d".repeat(64) } })).toThrow()
  })
})

describe("pin and readiness", () => {
  test("parsePin reads the first version line, skipping comments", () => {
    expect(parsePin("# the pin\n# why\n0.1.17\n")).toBe("0.1.17")
    expect(() => parsePin("# nothing\n")).toThrow()
    expect(() => parsePin("latest\n")).toThrow()
  })
  test("capToPin never starts the walk above the pin", () => {
    expect(capToPin("0.1.18", "0.1.17")).toBe("0.1.17")
    expect(capToPin("0.1.17", "0.1.17")).toBe("0.1.17")
    expect(capToPin("0.1.16", "0.1.17")).toBe("0.1.16")
  })
  test("pickCandidate under the pin skips the unverified release even when it is old enough", async () => {
    const now = Date.parse("2026-11-06T03:15:00Z")
    const published = async (v: string) => ({ "0.1.18": now - 48 * 3_600_000, "0.1.17": now - 90 * 3_600_000 })[v] ?? null
    const r = await pickCandidate({ latest: capToPin("0.1.18", "0.1.17"), published, minAgeHours: 24, nowMs: now })
    expect(r.version).toBe("0.1.17")
  })
  test("readyTimeoutS scales with load per core, 60 s floor, 240 s cap", () => {
    expect(readyTimeoutS(2, 12)).toBe(60)
    expect(readyTimeoutS(26, 12)).toBe(130)
    expect(readyTimeoutS(44, 12)).toBe(220)
    expect(readyTimeoutS(400, 12)).toBe(240)
  })
  test("parseJob reads the job's own state, pid and runs (nested blocks say active)", () => {
    const print = "gui/501/x = {\n\tactive count = 0\n\tstate = spawn scheduled\n\truns = 3647\n\tlast exit code = 0\n\t\tstate = active\n}"
    expect(parseJob(print)).toEqual({ state: "spawn scheduled", pid: 0, runs: 3647 })
    expect(parseJob("\tstate = running\n\truns = 5\n\tpid = 78834\n")).toEqual({ state: "running", pid: 78834, runs: 5 })
    expect(parseJob("Could not find service")).toBeNull()
  })
})

/**
 * A fake machine: launchd, the core, brew and the tap formula. `behaviour[version]` says what a kickstart of that
 * version does: "good" (a supervised core), "detach" (the 0.1.17 escape: the job exits 0 and respawns every 10 s,
 * never running, the socket held by an orphan the guard refuses), "escape" (running, but the core is not the job's
 * child), "loseTerminals" (up, but the holders died).
 */
type Behaviour = "good" | "detach" | "escape" | "loseTerminals"
function fakeHost(opts: { installed: string; behaviour: Record<string, Behaviour>; brokenReinstall?: boolean }) {
  let clock = 0
  let pid = 100
  let installed = opts.installed
  let formula = opts.installed
  let job: Job = { state: "running", pid: pid, runs: 1 }
  let core: CoreStatus = { version: installed, installed_by: "homebrew", pid: pid + 1 }
  let parent = job.pid
  let terminals: Record<string, number> = { t1: 501, t2: 502 }
  let mode: Behaviour = "good"
  const calls: string[] = []
  const log: string[] = []
  const host: Host = {
    job: () => {
      if (mode === "detach") job = { state: "spawn scheduled", pid: 0, runs: job.runs + 1 }
      return { ...job }
    },
    kickstart: () => {
      calls.push(`kickstart ${installed}`)
      mode = opts.behaviour[installed] ?? "good"
      pid += 10
      job = { state: mode === "detach" ? "spawn scheduled" : "running", pid: mode === "detach" ? 0 : pid, runs: job.runs + 1 }
      core = { version: installed, installed_by: "homebrew", pid: pid + 1 }
      parent = mode === "escape" ? 1 : pid
      if (mode === "loseTerminals") terminals = { t1: 900 }
    },
    coreUp: () => mode !== "detach",
    status: () => {
      if (mode === "detach") throw new Error("hc: refusing to start a herdr-core outside launchd")
      return { ...core }
    },
    parentPid: (p) => (p === core.pid ? parent : 0),
    terminalPids: () => ({ ...terminals }),
    installedVersion: () => `hc ${installed}`,
    brewUpgrade: () => {
      calls.push(`brew upgrade -> ${formula}`)
      installed = formula
    },
    brewReinstall: () => {
      calls.push(`brew reinstall -> ${formula}`)
      if (!opts.brokenReinstall) installed = formula
    },
    setFormula: (v, _shas, message) => {
      if (formula === v) return
      calls.push(`formula ${v}: ${message}`)
      formula = v
    },
    formulaVersion: () => formula,
    sleep: async (ms) => {
      clock += ms
    },
    now: () => clock,
    say: (m) => log.push(m),
  }
  return { host, calls, log, state: () => ({ installed, formula, job, mode, terminals }) }
}

const shas = { arm: "c".repeat(64), intel: "d".repeat(64) }
const run = (host: Host, target = "0.1.17", previous = "0.1.16") =>
  applyUpdate(host, { target, previous, shas, previousShas: async () => shas, timeoutS: 60, stableS: 30 })

describe("applyUpdate", () => {
  test("a supervised core: formula, brew, kickstart, proven up; no rollback", async () => {
    const f = fakeHost({ installed: "0.1.16", behaviour: { "0.1.17": "good" } })
    const after = await run(f.host)
    expect(after.version).toBe("0.1.17")
    expect(f.calls).toEqual(["formula 0.1.17: chore(herdr-core): update to 0.1.17", "brew upgrade -> 0.1.17", "kickstart 0.1.17"])
    expect(f.state().formula).toBe("0.1.17")
  })

  test("the 0.1.17 incident: the job never runs -> rolled back to the previous version and red", async () => {
    const f = fakeHost({ installed: "0.1.16", behaviour: { "0.1.17": "detach", "0.1.16": "good" } })
    const err = await run(f.host).catch((e: Error) => e)
    expect(err).toBeInstanceOf(Error)
    expect((err as Error).message).toContain("0.1.17: launchd running com.jkrumm.herdr-core on a new pid: not ready in time")
    expect((err as Error).message).toContain("rolled back to 0.1.16")
    expect((err as UpdateFailed).restarted).toBe(true)
    expect(f.calls).toEqual([
      "formula 0.1.17: chore(herdr-core): update to 0.1.17",
      "brew upgrade -> 0.1.17",
      "kickstart 0.1.17",
      expect.stringMatching(/^formula 0\.1\.16: revert\(herdr-core\): back to 0\.1\.16, 0\.1\.17 failed on /),
      "brew reinstall -> 0.1.16",
      "kickstart 0.1.16",
    ])
    expect(f.state()).toMatchObject({ installed: "0.1.16", formula: "0.1.16", mode: "good" })
    expect(f.log.some((l) => l.startsWith("rolled back: core 0.1.16 up"))).toBe(true)
  })

  test("a job that flickers running between respawns fails the stability window", async () => {
    const f = fakeHost({ installed: "0.1.16", behaviour: { "0.1.17": "good", "0.1.16": "good" } })
    // running on a new pid at first sight, then launchd respawns it (runs climbs, pid changes)
    const job = f.host.job
    let seen = 0
    f.host.job = () => {
      const j = job()
      if (f.state().installed === "0.1.17" && ++seen > 2) return { ...j, pid: j.pid + seen, runs: j.runs + seen }
      return j
    }
    const err = (await run(f.host).catch((e: Error) => e)) as Error
    expect(err.message).toContain("launchd job not stable")
    expect(err.message).toContain("rolled back to 0.1.16")
  })

  test("a core that is not the job's child is an escape: rolled back", async () => {
    const f = fakeHost({ installed: "0.1.16", behaviour: { "0.1.17": "escape", "0.1.16": "good" } })
    const err = (await run(f.host).catch((e: Error) => e)) as Error
    expect(err.message).toContain("is not the job's child")
    expect(err.message).toContain("rolled back to 0.1.16")
  })

  test("lost terminals are a failure even when the core is up", async () => {
    const f = fakeHost({ installed: "0.1.16", behaviour: { "0.1.17": "loseTerminals", "0.1.16": "good" } })
    const err = (await run(f.host).catch((e: Error) => e)) as Error
    expect(err.message).toContain("terminals did not survive: t1 (pid 501 -> 900), t2 (pid 502 -> gone)")
    // the rollback asserts the same terminals and says they are gone too: it reports, it cannot bring them back
    expect(err.message).toContain("ROLLBACK to 0.1.16 FAILED: terminals did not survive")
  })

  test("a rollback that cannot install the previous version says so", async () => {
    const f = fakeHost({ installed: "0.1.16", behaviour: { "0.1.17": "detach" }, brokenReinstall: true })
    const err = (await run(f.host).catch((e: Error) => e)) as Error
    expect(err.message).toContain(`ROLLBACK to 0.1.16 FAILED: brew reinstall gave "hc 0.1.17", wanted 0.1.16`)
    // the shared formula went back regardless, so the other machine does not install the failed version
    expect(f.state().formula).toBe("0.1.16")
  })

  test("a brew failure before the kickstart rolls the formula back and leaves the running core alone", async () => {
    const f = fakeHost({ installed: "0.1.16", behaviour: {} })
    f.host.brewUpgrade = () => {
      throw new Error("brew upgrade jkrumm/tap/herdr-core -> rc 1: download failed")
    }
    const err = (await run(f.host).catch((e: Error) => e)) as Error
    expect(err.message).toContain("download failed; rolled back to 0.1.16")
    expect((err as UpdateFailed).restarted).toBe(false) // a brew failure is retried tomorrow, not recorded
    expect(f.calls.filter((c) => c.startsWith("kickstart"))).toEqual([])
    expect(f.state().formula).toBe("0.1.16")
  })
})

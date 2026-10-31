import { describe, expect, test } from "bun:test"
import { ageHours, bumpFormula, cmpVersion, formulaVersion, parseVersion, pickCandidate, previousVersion } from "./herdr-core-update.ts"

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

import { describe, expect, test } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { readHealthy } from "./jobrun-canary.ts"

const cfg = (body: string) => {
  const p = join(mkdtempSync(join(tmpdir(), "canary-")), "c.json")
  writeFileSync(p, body)
  return p
}

describe("jobrun-canary", () => {
  test("healthy only on a literal true", () => {
    expect(readHealthy(cfg('{"healthy": true}')).healthy).toBe(true)
    for (const body of ['{"healthy": false}', '{"healthy": "true"}', "{}", "{torn"]) expect(readHealthy(cfg(body)).healthy).toBe(false)
  })
  test("a missing file is unhealthy, not a crash", () => expect(readHealthy("/nonexistent/c.json").healthy).toBe(false))
  test("the committed config is healthy", () => expect(readHealthy(join(import.meta.dir, "../config/jobrun-canary.json")).healthy).toBe(true))
  test("exit code follows the config", () => {
    const run = (path: string) => Bun.spawnSync(["bun", join(import.meta.dir, "jobrun-canary.ts")], { env: { ...process.env, JOBRUN_CANARY_CONFIG: path } }).exitCode
    expect(run(cfg('{"healthy": true}'))).toBe(0)
    expect(run(cfg('{"healthy": false}'))).toBe(1)
  })
})

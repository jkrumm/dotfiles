#!/usr/bin/env bun
// jobrun-canary — the end-to-end probe for the job failure chain (docs/waves/PLAN.md Wave 7).
// Exits 1 unless config/jobrun-canary.json has `"healthy": true`; the job com.jkrumm.jobrun-canary
// runs it every 300 s under jobrun. Keep it healthy and committed. Flipping it is how the chain is
// exercised: locally uncommitted to see `failing` (Wave 5), committed by the owner to let a remediation
// consumer fix it end to end (Wave 7).
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"

const DEFAULT_CONFIG = join(dirname(import.meta.dir), "config/jobrun-canary.json")

/** What the run record's tail says on failure: the cause and the one-line fix, for the implementer that reads it. */
export const CANARY_FIX = "canary unhealthy: config/jobrun-canary.json has healthy:false; the fix is to set healthy:true and commit"

/** Anything but a literal `"healthy": true` is unhealthy, including a missing or unparseable file. */
export function readHealthy(path: string): { healthy: boolean; why: string } {
  try {
    const cfg = JSON.parse(readFileSync(path, "utf8")) as { healthy?: unknown }
    return cfg.healthy === true ? { healthy: true, why: "healthy" } : { healthy: false, why: `healthy=${JSON.stringify(cfg.healthy)}` }
  } catch (e) {
    return { healthy: false, why: `cannot read ${path}: ${(e as Error).message}` }
  }
}

if (import.meta.main) {
  const { healthy, why } = readHealthy(process.env.JOBRUN_CANARY_CONFIG || DEFAULT_CONFIG)
  console.log(`jobrun-canary: ${why}`)
  // The failure names its own fix, so a job brief shows an implementer that this is a plain code/config
  // fault in the owner repo (a normal implement), not a question for the owner.
  if (!healthy) console.log(CANARY_FIX)
  process.exit(healthy ? 0 : 1)
}

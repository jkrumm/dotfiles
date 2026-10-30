// Variant B: take the spec the gateway ALREADY serves (GET /openapi/json, @elysiajs/openapi) and
// overlay only what it lacks: stable operationIds and `x-cli`. Compares schemas with the
// hand-built spec (gen-openapi.ts) to measure how much re-declaration was really needed.
// Run: node overlay-served.ts   (reads the public, unauthenticated /openapi/json once)
import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import { fileURLToPath } from 'node:url'
import { buildSpec } from './gen-openapi.ts'

const here = dirname(fileURLToPath(import.meta.url))
const base = process.env.AGW_RESEARCH_URL ?? 'http://localhost:7780'
const served = await (await fetch(`${base}/openapi/json`)).json()
const mine = buildSpec()

// served path keys -> mine; the gateway's discovery/health/probe routes are not part of the overlay
const map: Record<string, string> = { '/research/': '/research', '/research/{jobId}': '/research/{jobId}' }
const strip = (s: unknown) => JSON.parse(JSON.stringify(s, (k, v) => (k === '$schema' || k === 'description' ? undefined : v)))
const report: string[] = []
const paths: Record<string, unknown> = {}
for (const [sp, mp] of Object.entries(map)) {
  const ops = served.paths[sp]
  for (const [method, op] of Object.entries<any>(ops)) {
    const m = (mine.paths as any)[mp][method]
    op.operationId = m.operationId
    op['x-cli'] = m['x-cli']
    const same = (a: unknown, b: unknown) => isDeepStrictEqual(strip(a), strip(b))
    report.push(
      `${method.toUpperCase()} ${mp}: request ${op.requestBody ? same(op.requestBody, m.requestBody) : 'n/a'}, ` +
        `200 ${same(op.responses['200'], m.responses['200'])}, statuses served=[${Object.keys(op.responses)}] mine=[${Object.keys(m.responses)}]`,
    )
  }
  paths[mp] = ops
}
const out = { ...served, paths, info: { ...served.info, 'x-source': 'GET /openapi/json + overlay (operationId, x-cli)' } }
writeFileSync(join(here, 'specs/research.served.openapi.json'), JSON.stringify(out, null, 2) + '\n')
console.log(report.join('\n'))

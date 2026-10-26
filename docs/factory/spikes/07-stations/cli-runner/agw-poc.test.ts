// Unit tests: argv -> request mapping, unknown flags, exit-code mapping, pending/resume.
// Runs under `node --test agw-poc.test.ts` and `bun test agw-poc.test.ts` (node:test API).
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { EXIT, buildCommands, buildRequest, mapHttpError, parseArgv, run, type Ctx } from './agw-poc.ts'

const here = dirname(fileURLToPath(import.meta.url))
const specPath = resolve(here, 'specs/research.openapi.json')
const spec = JSON.parse(readFileSync(specPath, 'utf8'))
const specSha = createHash('sha256').update(readFileSync(specPath)).digest('hex')
const cmds = buildCommands(spec)
const cmd = (name: string) => cmds.find((c) => c.path.join(' ') === name)!

type Handler = (url: string, init: RequestInit) => { status?: number; body?: unknown; headers?: Record<string, string> }
function harness(handler: Handler, o: { env?: Record<string, string>; tty?: boolean; noToken?: boolean } = {}) {
  const calls: { url: string; init: RequestInit }[] = []
  const out: string[] = []
  const err: string[] = []
  let t = 0
  const ctx: Ctx = {
    fetch: (async (url: string, init: RequestInit) => {
      calls.push({ url, init })
      const r = handler(url, init)
      return new Response(JSON.stringify(r.body ?? null), { status: r.status ?? 200, headers: r.headers })
    }) as typeof fetch,
    env: { ...(o.noToken ? {} : { RESEARCH_GATEWAY_TOKEN: 'tok-secret' }), ...o.env },
    keychain: () => null,
    readFile: (p) => readFileSync(p),
    isTTY: o.tty ?? false,
    out: (s) => out.push(s),
    err: (s) => err.push(s),
    sleep: async (ms) => void (t += ms),
    now: () => t,
    configPath: resolve(here, 'gateways.json'),
  }
  return { ctx, calls, out, err }
}
const lastErr = (err: string[]) => JSON.parse(err.join('').trim().split('\n').at(-1)!).error

test('commands are generated from x-cli, incl. the declared wait', () => {
  assert.deepEqual(cmds.map((c) => c.path.join(' ')).sort(), ['research cancel', 'research run', 'research status', 'research wait'])
  assert.equal(cmd('research wait').kind, 'wait')
  assert.equal(cmd('research run').mutating, true)
})

test('argv -> request: positional + enum flag + auto kebab flags map to the POST body', () => {
  const { values } = parseArgv(cmd('research run'), ['what is x', '--depth', 'quick', '--idempotency-key=k1'])
  assert.deepEqual(buildRequest(cmd('research run'), values), { method: 'POST', path: '/research', body: { query: 'what is x', depth: 'quick', idempotencyKey: 'k1' } })
})

test('argv -> request: path param positional is URL-encoded', () => {
  const { values } = parseArgv(cmd('research status'), ['a/b'])
  assert.deepEqual(buildRequest(cmd('research status'), values), { method: 'GET', path: '/research/a%2Fb' })
})

test('usage errors: bad enum, missing required, extra arg, short query', () => {
  const c = cmd('research run')
  assert.throws(() => parseArgv(c, ['abc', '--depth', 'huge']), /one of quick \| standard \| deep/)
  assert.throws(() => parseArgv(c, ['--depth', 'quick']), /missing required: <query>/)
  assert.throws(() => parseArgv(c, ['abc', 'def']), /unexpected argument/)
  assert.throws(() => parseArgv(c, ['ab']), /at least 3/)
})

test('unknown flag -> exit 2, last stderr line is the error JSON with a hint listing valid flags', async () => {
  const h = harness(() => ({}))
  const code = await run(['research', 'run', 'abc', '--json', '--commit'], h.ctx)
  assert.equal(code, EXIT.usage)
  const e = lastErr(h.err)
  assert.equal(e.kind, 'usage')
  assert.match(e.hint, /--depth/)
  assert.equal(h.calls.length, 0)
})

test('mutating-only globals are unknown on read-only commands', async () => {
  const h = harness(() => ({}))
  assert.equal(await run(['research', 'status', 'j1', '--commit'], h.ctx), EXIT.usage)
})

test('exit-code table is the ADR-004 order', () => {
  assert.deepEqual(Object.entries(EXIT), [['ok', 0], ['general', 1], ['usage', 2], ['auth', 3], ['not_found', 4], ['conflict', 5], ['confirmation_required', 6], ['network', 7], ['rate_limited', 8], ['contract_mismatch', 9], ['pending', 10]])
})

test('HTTP status -> kind/exit mapping', () => {
  const none = { get: () => null }
  const k = (s: number, body: unknown = { error: 'x' }) => mapHttpError(s, body, none)
  assert.equal(k(401).exitCode, EXIT.auth)
  assert.equal(k(404).exitCode, EXIT.not_found)
  assert.equal(k(409).exitCode, EXIT.conflict)
  assert.equal(k(429).exitCode, EXIT.rate_limited)
  assert.equal(k(429).retryable, true)
  assert.equal(k(503).exitCode, EXIT.general)
  assert.equal(k(503).retryable, true)
  assert.equal(k(422, { summary: 'bad body' }).message, 'bad body')
  assert.equal(k(412).exitCode, EXIT.contract_mismatch)
  assert.equal(k(409, { error: { kind: 'contract_mismatch', message: 'm', hint: 'reinstall' } }).exitCode, EXIT.contract_mismatch)
  assert.equal(mapHttpError(429, { error: 'q' }, { get: (n) => (n === 'retry-after' ? '30' : null) }).details.retryAfterS, 30)
})

test('non-TTY mutation without --commit -> confirmation_required, no request; --dry-run previews', async () => {
  const h = harness(() => ({}))
  assert.equal(await run(['research', 'run', 'abc def'], h.ctx), EXIT.confirmation_required)
  assert.equal(lastErr(h.err).kind, 'confirmation_required')
  const d = harness(() => ({}))
  assert.equal(await run(['research', 'run', 'abc def', '--dry-run'], d.ctx), EXIT.ok)
  assert.equal(JSON.parse(d.out.join('')).dryRun, true)
  assert.equal(h.calls.length + d.calls.length, 0)
})

test('every request carries x-contract-sha = sha256(spec file), bearer, and a generated idempotency key', async () => {
  const h = harness((url, init) => (init.method === 'POST' ? { body: { jobId: 'j1', status: 'queued' } } : { body: { status: 'done', result: { report: 'R' } } }))
  assert.equal(await run(['research', 'run', 'abc def', '--commit'], h.ctx), EXIT.ok)
  for (const c of h.calls) {
    const headers = c.init.headers as Record<string, string>
    assert.equal(headers['x-contract-sha'], specSha)
    assert.equal(headers.authorization, 'Bearer tok-secret')
  }
  const body = JSON.parse(h.calls[0]!.init.body as string)
  assert.match(body.idempotencyKey, /^[0-9a-f-]{36}$/)
  assert.equal(h.out.join('').includes('tok-secret') || h.err.join('').includes('tok-secret'), false)
})

test('missing token -> auth exit 3 without a request', async () => {
  const h = harness(() => ({}), { noToken: true })
  assert.equal(await run(['research', 'status', 'j1'], h.ctx), EXIT.auth)
  assert.equal(h.calls.length, 0)
})

test('404 on status -> not_found exit 4', async () => {
  const h = harness(() => ({ status: 404, body: { error: 'Job not found: nope' } }))
  assert.equal(await run(['research', 'status', 'nope'], h.ctx), EXIT.not_found)
  assert.equal(lastErr(h.err).message, 'Job not found: nope')
})

test('transport failure -> network exit 7, retryable', async () => {
  const h = harness(() => ({}))
  h.ctx.fetch = (async () => { throw new TypeError('fetch failed') }) as typeof fetch
  assert.equal(await run(['research', 'status', 'j1'], h.ctx), EXIT.network)
  assert.equal(lastErr(h.err).retryable, true)
})

test('pending: budget elapses -> exit 10, hint is the exact resume command; resume gets a fresh budget and completes', async () => {
  let polls = 0
  const handler: Handler = (url, init) => {
    if (init.method === 'POST') return { body: { jobId: 'job-9', status: 'queued' } }
    polls++
    return polls < 10 ? { body: { status: 'running', progress: { phase: 'researching' } } } : { body: { status: 'done', result: { report: '# Report' } } }
  }
  const first = harness(handler, { env: { AGW_WAIT_BUDGET_S: '5', AGW_POLL_MS: '1000' } })
  assert.equal(await run(['research', 'run', 'abc def', '--commit'], first.ctx), EXIT.pending)
  const e = lastErr(first.err)
  assert.equal(e.kind, 'pending')
  assert.equal(e.hint, 'agw-poc research wait job-9')
  assert.equal(e.retryable, true)
  assert.equal(e.details.jobId, 'job-9')
  assert.equal(JSON.parse(first.out.join('').trim()).status, 'running') // stdout = data only (last state)

  const second = harness(handler, { env: { AGW_WAIT_BUDGET_S: '5', AGW_POLL_MS: '1000' } })
  assert.equal(await run(['research', 'wait', 'job-9'], second.ctx), EXIT.ok)
  const done = JSON.parse(second.out.join('').trim())
  assert.equal(done.status, 'done')
  assert.equal(done.jobId, 'job-9')
  assert.equal(second.err.length, 0)
})

test('terminal error job -> stdout data, exit 1, stderr general', async () => {
  const h = harness(() => ({ body: { status: 'error', error: 'boom' } }))
  assert.equal(await run(['research', 'wait', 'j1'], h.ctx), EXIT.general)
  assert.equal(JSON.parse(h.out.join('').trim()).status, 'error')
  assert.match(lastErr(h.err).message, /boom/)
})

test('--no-wait returns the submit response; plain format prints the report only', async () => {
  const a = harness(() => ({ body: { jobId: 'j2', status: 'queued' } }))
  assert.equal(await run(['research', 'run', 'abc def', '--commit', '--no-wait'], a.ctx), EXIT.ok)
  assert.equal(JSON.parse(a.out.join('')).jobId, 'j2')
  const b = harness(() => ({ body: { status: 'done', result: { report: '# R' } } }))
  assert.equal(await run(['research', 'wait', 'j2', '--format', 'plain'], b.ctx), EXIT.ok)
  assert.equal(b.out.join(''), '# R\n')
})

test('schema is offline and prints input+output JSON Schema; --exit-codes prints the table', async () => {
  const h = harness(() => { throw new Error('network must not be touched') })
  assert.equal(await run(['schema', 'research', 'run'], h.ctx), EXIT.ok)
  const s = JSON.parse(h.out.join(''))
  assert.deepEqual(s.input.properties.depth.enum, ['quick', 'standard', 'deep'])
  assert.deepEqual(s.input.required, ['query'])
  assert.equal(s.output.type, 'object')
  assert.equal(s.contractSha, specSha)
  const t = harness(() => ({}))
  assert.equal(await run(['schema', '--exit-codes'], t.ctx), EXIT.ok)
  assert.equal(JSON.parse(t.out.join('')).exitCodes.pending, 10)
  assert.equal(h.calls.length + t.calls.length, 0)
})

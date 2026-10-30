# Spike 7 / cli-runner: report (2026-10-26)

**Verdict: yes.** One generic runner turns research-gateway's OpenAPI document into an ADR-004 CLI. `agw-poc.ts`
has 536 lines and no dependencies. It builds `research run|status|wait|cancel` from the spec plus `x-cli` and
implements ADR-004 items 3, 4, 5, 6, 8 and the client half of 9. Item 1 is partial, items 2 and 7 are not built.
A long job that went pending and was resumed finished in **2 calls**. A quick job finished in 1. The resume hint was
an exact command, so no policy sentence was needed.

Files: `agw-poc.ts`, `agw-poc.test.ts`, `gen-openapi.ts`, `overlay-served.ts`, `specs/`, `gateways.json`,
`gateways.served.json`, `live-test.sh`, `live-transcript.txt`. The git-ignored `node_modules` symlink to
research-gateway's is needed by `gen-openapi.ts` only.

**The better source.** research-gateway already serves OpenAPI 3.1 at `GET /openapi/json` (`@elysiajs/openapi`,
`src/index.ts:211`). Only `x-cli` and stable operationIds are missing. `overlay-served.ts` adds them, and the
runner works on that spec unchanged. Use this path, not the hand-built `gen-openapi.ts`.

## 1. Spec coverage and re-declared schemas

All 3 routes in `src/routes/research.ts` are covered (POST `/research`, GET and DELETE `/research/{jobId}`).
`/health*`, `/probe/fetch` and `/mcp` are not.

| Piece | Source | Drift risk |
|-|-|-|
| `ResearchInput`, `JobLiveFields`, `JobStatus`, `ResearchReport` | imported from `src/agent/schema.ts` (zod only) | none |
| `ResearchSubmit` (`idempotencyKey`) | re-declared verbatim | medium |
| Status wrapper | re-declared; uses the `JobStatus` enum where the route says `z.string()` | medium (deliberate) |
| Submit, cancel and error bodies, status table | re-declared | low |
| `x-cli` blocks | written in `gen-openapi.ts` | new information |

- `node gen-openapi.ts --check` compares the route table and status keys in `research.ts` with the spec. It does not
  catch field changes.
- The generated spec embeds research-gateway's git sha, so every commit there marks it stale.
- The served-spec overlay removes the re-declaration risk, and its differences from the hand-built spec are cosmetic.

## 2. Node vs Bun

| | node 26.5.1 | bun 1.4.3 |
|-|-|-|
| Run `.ts` | `node agw-poc.ts`, no flag | `bun agw-poc.ts` |
| Tests | `node --test` 17/17 | `bun test` 17/17 |
| tsc `--strict` | clean | n/a |

- Node runs it only with erasable TypeScript syntax (no enums, no constructor parameter properties) and `.ts` import
  suffixes.
- Bun bug: a method named `line()` on an `Error` subclass collides with JavaScriptCore's `Error.line` and throws under
  Bun only. Renamed to `errorLine`.

## 3. Exit codes and HTTP mapping

Exit codes: 0 ok, 1 general, 2 usage, 3 auth, 4 not_found, 5 conflict, 6 confirmation_required, 7 network,
8 rate_limited, 9 contract_mismatch, 10 pending. `agw-poc schema --exit-codes` prints the table.

| HTTP | Exit |
|-|-|
| 401/403 | 3 auth |
| 404 | 4 not_found |
| 409 | 5 conflict |
| 429 | 8 rate_limited (retryable, `Retry-After` in details) |
| 400/422 | 2 usage |
| 412, or body `error.kind == contract_mismatch` | 9 contract_mismatch |
| other 5xx | 1 general (retryable) |
| transport failure | 7 network (retryable) |

A terminal `error` or `cancelled` job exits 1, with the job state still on stdout.

## 4. Live transcript (abridged, raw in `live-transcript.txt`)

| # | Command | Exit | Result |
|-|-|-|-|
| 1 | `research status job-does-not-exist` | 4 | `not_found`, server message passed through |
| 2 | `research run "<q>" --depth quick --bogus` | 2 | unknown flag, hint lists valid flags |
| 3 | `schema --exit-codes` | 0 | table above |
| 4 | `research run "<q>" --depth quick` (non-TTY, no `--commit`) | 6 | `confirmation_required`, no request sent |
| 5 | `AGW_WAIT_BUDGET_S=5 research run … --commit` | 10 | after 4 s: stdout = last job state (`running`); stderr `kind:pending`, hint `agw-poc research wait 897ca6f0-…` |
| 6 | the hint, verbatim | 0 | after 65 s: `done`, report on stdout |
| 7 | (bun) `research run … --commit`, default budget | 0 | 37 s, `done`, 1 call |
| 8 | (bun) `research cancel <done job> --commit` | 0 | idempotent, status `done` |
| 9 | (bun) `research cancel <done job>` | 6 | `confirmation_required` |

## 5. Verdict against ADR-004's ≤ 2 calls

The rule holds, with the arithmetic ADR-004 already states: calls = ⌈duration ÷ budget⌉.

- The budget-5 run plus its resume (rows 5 and 6) took 2 calls for a 72 s job. The resume ran on the default 110 s
  budget.
- At the default 110 s budget, a quick job is always 1 call and a standard job (p50 ~150 s) is 2.
- A deep job (p50 450–700 s) takes 5–7 calls unless the harness raises the Bash timeout and sets
  `AGW_WAIT_BUDGET_S` ≥ 350. That is the settings-template work ADR-004 item 6 already names.

## 6. What a gateway must add server-side

| Need | Status in research-gateway |
|-|-|
| Serve `GET /openapi/json` | exists |
| Stable operationIds via `detail.operationId` | missing (auto ids `postResearch`, `getResearchByJobId`) |
| `x-cli` per operation in route `detail` | missing; whether `detail` passes `x-` keys through is unverified |
| Contract-sha check (`onBeforeHandle`) | missing |

The contract-sha check would compare `x-contract-sha` with the sha of the served spec. On a mismatch it returns 412
`{"error":{"kind":"contract_mismatch",…,"details":{"server","client"}}}`. The runner already maps that response.

Two gaps on the client side:
- The runner hashes the cached file's raw bytes. A canonical form (sorted keys, no whitespace) would be safer.
- Refresh-and-retry-once on a mismatch is not built.

## 7. Prior art

Research job `81239747-3780-427a-9563-73b49843c43a` (quick, ok). None of the three tools documents a pending/resume
convention, so that part of the contract is ours.

| Tool | What it documents |
|-|-|
| restish | exit-code table (0, 1, 2 for usage and unknown flags, 3/4/5 for final 3xx/4xx/5xx); no structured error line, no offline schema, no pending/resume |
| Fern's generator | the closest: exit codes 0–5, structured JSON errors on stderr, global `--schema` |
| openapi-cli-generator | only blocking `x-cli-waiters` |

## Open questions and gaps

1. **`--commit` on `research run`.** ADR-004 item 4 makes submit mutating, so the most-used verb needs `--commit`. The
   alternative is `mutating:false` plus the idempotency key. Owner decision.
2. **Plain format** drops `result.status` and `unverified`, which AGENTS.md says must always be surfaced. A generic
   runner needs an `x-cli.plainSummaryFields`.
3. **Not built:** `jsonl`, `tsv`, `--fields`, `--limit`, `--out` spill, spec refresh on mismatch, `@file` values,
   the conformance suite.
4. **Request timeout.** A 30 s per-request guard covers HTTP calls only. Poll failures retry until the budget ends,
   then exit `network` with the resume hint.
5. **Noticed, untouched:** `research-gateway/src/routes/research.ts:136` still describes a 409 for "the other replica
   of an in-progress deploy". The second instance was retired on 2026-09-26.

3 quick jobs ran on production :7780 (2 live tests, 1 prior-art research). No process is left running, and
research-gateway is untouched.

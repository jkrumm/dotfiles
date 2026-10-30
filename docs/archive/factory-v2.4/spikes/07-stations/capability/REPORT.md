# Spike 7 / capability: in-house `defineCapability` vs Mastra (2026-10-26)

**Verdict: build the shared capability layer in-house.** Mastra covers the import door and an eval runner. It does
not give the HTTP and CLI doors the shape the design needs. It earns a place only as an engine *behind* plain
capability functions, and only if a repo needs stateful agents, workflow suspend/resume or LLM-judge scorers.

The capability: `summarize({text, maxWords?}) → {title, summary}`, model resolved from route key `triage` via
`agw routing --json`. Spend: about $0.01 for ~110 calls at ~$0.00004 each.

## Results

| | in-house | Mastra |
|-|-|-|
| Code written | 341 lines (core 162) | 140 lines |
| `node_modules` | 25 MB, 12 packages | 191 MB, 152 packages |
| Module import, Node / Bun | 135 / 49 ms | 1048 / 336 ms |
| Cold start to first result, Node / Bun | 1526 / 1044 ms | 2182 / 1626 ms |
| Warm call median, Node / Bun | 955 / 1065 ms | 1022 / 1082 ms |
| Usage and cost | tokens plus `usage.raw.cost` from the endpoint, returned and on the span | tokens on spans only; no cost; the tool returns no usage |
| Trace | one `capability.summarize` span per call, accepts `traceparent` | ~10 spans per call; no tool span; root is `agent_run`; custom JSONL exporter is 17 lines |
| OpenAPI | 1.8 KB, input and output schema per capability | 3.2 MB, 360 paths; execute body is `{data:{}}`; "summarize" appears 0 times |
| CLI | flags generated from zod, exit 0/1/2, error JSON on the last stderr line, offline `cap schema` | none usable; `mastra api tool execute` takes generic JSON, exits 0 on bad input, exits 1 with plain text on an unknown flag |
| HTTP errors | typed | a validation failure returns HTTP 200 with `{error:true}` |
| Eval | 28 lines, gate on pass rate | `runEvals` cannot take a tool; needed a one-step workflow wrapper and a registered scorer |
| Eval pass rates | 5/5, 5/5, 4/5, 5/5, 5/5 | 5/5 ×3 |
| Node / Bun | both clean | both clean (HTTP bootstrap differs: `Bun.serve` vs `@hono/node-server`) |

The first prompt version scored 3/5 and 2/5, so the eval catches real regressions.

## IU endpoint quirks found

- It rejects `response_format: json_schema`. `json_object` works only if the prompt contains the word "json".
- It honours `reasoning_effort: "none"` and returns `usage.cost` on every response, so cost needs no price table.
- It wraps a provider 400 in HTTP 503, which made the AI SDK retry a non-retryable error. The in-house version sets
  `maxRetries: 1`.

## Gaps in the in-house layer

- Only the `iu-openai` transport is implemented.
- No fallback chain.
- No OTLP exporter.
- No `--commit` or idempotency handling.
- The routing JSON has no effort or variant field, so each capability sets reasoning effort itself. That belongs in
  `agw routing`.
- Not typechecked with `tsc`.

## Caveats

- One capability, one model, 5 eval cases.
- Cold start is n=3, noisy by about ±300 ms.
- A custom Mastra gateway for route keys was not tried.

## Files

- `inhouse/src/{core,capabilities,server,cli}.ts`, `inhouse/eval/{run.ts,cases.jsonl}`
- `mastra/src/{mastra,scorers,server}.ts`, `mastra/eval/run.ts`
- `bench/run.ts`, `bench/results.jsonl`
- Sample spans: `inhouse/spans.jsonl`, `mastra/spans.jsonl`, `bench/spans-bench.jsonl`

To reproduce, run `eval "$(zsh -ic 'source ~/SourceRoot/dotfiles/config/zsh/claude.zsh >/dev/null 2>&1; _oc_env' 2>/dev/null)"`
first, then:
- `cd inhouse && node src/cli.ts summarize --text "…"`, `node src/server.ts` (port 7790), `node eval/run.ts`
- `cd mastra && node src/server.ts` (port 7792), `node eval/run.ts`

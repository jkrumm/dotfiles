// In-house capability layer: define once, call via import / HTTP / CLI. Model chosen by route key.
import { execFileSync } from 'node:child_process';
import { appendFileSync, readFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { generateText, Output } from 'ai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { z } from 'zod';

// The endpoint has no json_schema mode; the SDK warns each call. The prompt carries the schema instead.
(globalThis as { AI_SDK_LOG_WARNINGS?: boolean }).AI_SDK_LOG_WARNINGS = false;

// ---- errors (ADR-004 item 3 envelope) ----
export type ErrorKind =
  | 'usage' | 'validation' | 'auth' | 'rate_limited' | 'upstream' | 'invalid_output' | 'unsupported_route' | 'not_found' | 'general';

export class CapError extends Error {
  kind: ErrorKind;
  hint: string;
  retryable: boolean;
  constructor(kind: ErrorKind, message: string, hint = '', retryable = false) {
    super(message);
    this.kind = kind;
    this.hint = hint;
    this.retryable = retryable;
  }
  envelope() {
    return { error: { kind: this.kind, message: this.message, hint: this.hint, retryable: this.retryable } };
  }
}

export function toCapError(e: unknown): CapError {
  if (e instanceof CapError) return e;
  const err = e as { statusCode?: number; name?: string; message?: string };
  if (err?.name === 'AI_NoObjectGeneratedError' || err?.name === 'AI_TypeValidationError')
    return new CapError('invalid_output', 'model output did not match the output schema', 'retry; check the prompt', true);
  if (err?.statusCode === 429) return new CapError('rate_limited', 'upstream rate limit', 'back off and retry', true);
  if (err?.statusCode === 401 || err?.statusCode === 403) return new CapError('auth', 'upstream rejected credentials', 'check IU_KEY');
  if (err?.statusCode) return new CapError('upstream', `upstream HTTP ${err.statusCode}`, '', err.statusCode >= 500);
  return new CapError('general', err?.message ?? String(e));
}

// ---- routes: key -> model, resolved once from `agw routing --json` (never a hardcoded model id) ----
export type Route = { model: string; backend: string; transport: string };
let routeTable: Record<string, Route> | undefined;

export function resolveRoute(key: string): Route {
  routeTable ??= JSON.parse(
    process.env.CAP_ROUTING_FILE
      ? readFileSync(process.env.CAP_ROUTING_FILE, 'utf8')
      : execFileSync('agw', ['routing', '--json'], { encoding: 'utf8' }),
  ).routes;
  const route = routeTable?.[key];
  if (!route) throw new CapError('usage', `unknown route key "${key}"`, 'see `agw routing --json`');
  return route;
}

let iu: ReturnType<typeof createOpenAICompatible> | undefined;
function modelFor(route: Route) {
  if (route.transport !== 'iu-openai')
    throw new CapError('unsupported_route', `transport "${route.transport}" not implemented`, 'only iu-openai in this spike');
  const baseURL = process.env.IU_OPENAI_BASE;
  const apiKey = process.env.IU_KEY;
  if (!baseURL || !apiKey) throw new CapError('auth', 'IU_OPENAI_BASE / IU_KEY not set', 'run via secrets-run');
  iu ??= createOpenAICompatible({ name: 'iu', baseURL, apiKey });
  return iu.chatModel(route.model);
}

// ---- capability definition ----
export type Usage = { inputTokens: number; outputTokens: number; costUsd: number | null; calls: number };
export type ObjectOpts<T> = { schema: z.ZodType<T>; system?: string; prompt: string; effort?: 'none' | 'low' | 'medium' | 'high' };
export type Ctx = {
  route: Route;
  /** One structured model call on this capability's route; usage is accumulated onto the span. */
  object<T>(o: ObjectOpts<T>): Promise<T>;
};
type Def<I extends z.ZodType, O extends z.ZodType> = {
  id: string;
  description: string;
  input: I;
  output: O;
  route: string;
  run: (input: z.output<I>, ctx: Ctx) => Promise<z.input<O>>;
};
export type CallResult<O> = { output: O; usage: Usage; traceId: string; spanId: string };
export type Capability<I extends z.ZodType = z.ZodType, O extends z.ZodType = z.ZodType> = {
  (input: z.input<I>): Promise<z.output<O>>;
  def: Def<I, O>;
  call(input: unknown, opts?: { traceparent?: string }): Promise<CallResult<z.output<O>>>;
};

const spansPath = () => process.env.CAP_SPANS ?? new URL('../spans.jsonl', import.meta.url).pathname;
const hex = (n: number) => randomBytes(n).toString('hex');

export function defineCapability<I extends z.ZodType, O extends z.ZodType>(def: Def<I, O>): Capability<I, O> {
  const call: Capability<I, O>['call'] = async (rawInput, opts) => {
    const parsed = def.input.safeParse(rawInput);
    if (!parsed.success) throw new CapError('validation', z.prettifyError(parsed.error), `see \`cap schema ${def.id}\``);
    const tp = opts?.traceparent?.match(/^00-([0-9a-f]{32})-[0-9a-f]{16}-[0-9a-f]{2}$/);
    const traceId = tp?.[1] ?? hex(16);
    const spanId = hex(8);
    const startMs = Date.now();
    const usage: Usage = { inputTokens: 0, outputTokens: 0, costUsd: null, calls: 0 };
    let route: Route | undefined;
    let outcome = 'ok';
    try {
      route = resolveRoute(def.route);
      const ctx: Ctx = {
        route,
        async object<T>({ schema, system, prompt, effort = 'none' }: ObjectOpts<T>) {
          const r = await generateText({
            model: modelFor(route!),
            system,
            prompt,
            output: Output.object({ schema }),
            providerOptions: { iu: { reasoningEffort: effort } },
            maxRetries: 1,
          });
          usage.calls++;
          usage.inputTokens += r.usage.inputTokens ?? 0;
          usage.outputTokens += r.usage.outputTokens ?? 0;
          const cost = (r.usage.raw as { cost?: number } | undefined)?.cost; // IU endpoint returns usage.cost
          if (typeof cost === 'number') usage.costUsd = (usage.costUsd ?? 0) + cost;
          return r.output as T;
        },
      };
      const out = def.output.safeParse(await def.run(parsed.data, ctx));
      if (!out.success) throw new CapError('invalid_output', z.prettifyError(out.error), 'model broke the output contract', true);
      return { output: out.data, usage, traceId, spanId };
    } catch (e) {
      const err = toCapError(e);
      outcome = err.kind;
      throw err;
    } finally {
      appendFileSync(
        spansPath(),
        JSON.stringify({
          traceId, spanId, name: `capability.${def.id}`, startMs, durMs: Date.now() - startMs,
          attrs: { route: def.route, model: route?.model, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, costUsd: usage.costUsd, outcome },
        }) + '\n',
      );
    }
  };
  const fn = (async (input) => (await call(input)).output) as Capability<I, O>;
  fn.def = def;
  fn.call = call;
  return fn;
}

export type Registry = Record<string, Capability<any, any>>;

// ---- schemas shared by OpenAPI and `cap schema` ----
export function schemasOf(cap: Capability<any, any>) {
  const clean = (s: Record<string, unknown>) => (delete s.$schema, s);
  return {
    input: clean(z.toJSONSchema(cap.def.input, { io: 'input' }) as Record<string, unknown>),
    output: clean(z.toJSONSchema(cap.def.output, { io: 'output' }) as Record<string, unknown>),
  };
}

export function httpStatus(kind: ErrorKind): number {
  return ({ usage: 400, validation: 400, auth: 502, rate_limited: 429, upstream: 502, invalid_output: 502, unsupported_route: 501, not_found: 404, general: 500 } as const)[kind];
}

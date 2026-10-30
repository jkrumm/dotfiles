import { createServer } from 'node:http';
import { CapError, httpStatus, schemasOf, toCapError, type Registry } from './core.ts';

export function openapi(caps: Registry) {
  const paths: Record<string, unknown> = {};
  for (const cap of Object.values(caps)) {
    const { input, output } = schemasOf(cap);
    paths[`/cap/${cap.def.id}`] = {
      post: {
        operationId: cap.def.id,
        summary: cap.def.description,
        'x-cli': { command: cap.def.id, mutating: false },
        requestBody: { required: true, content: { 'application/json': { schema: input } } },
        responses: {
          '200': {
            description: 'ok',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  required: ['output', 'usage', 'traceId'],
                  properties: {
                    output,
                    usage: { type: 'object', properties: { inputTokens: { type: 'integer' }, outputTokens: { type: 'integer' }, costUsd: { type: ['number', 'null'] }, calls: { type: 'integer' } } },
                    traceId: { type: 'string' },
                  },
                },
              },
            },
          },
          default: { description: 'error', content: { 'application/json': { schema: { type: 'object', properties: { error: { type: 'object', properties: { kind: { type: 'string' }, message: { type: 'string' }, hint: { type: 'string' }, retryable: { type: 'boolean' } } } } } } } },
        },
      },
    };
  }
  return { openapi: '3.1.0', info: { title: 'capabilities', version: '0.0.0' }, paths };
}

export function startServer(caps: Registry, port: number) {
  const server = createServer(async (req, res) => {
    const send = (status: number, body: unknown) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    try {
      const url = new URL(req.url ?? '/', 'http://x');
      if (req.method === 'GET' && url.pathname === '/openapi.json') return send(200, openapi(caps));
      if (req.method === 'GET' && url.pathname === '/health') return send(200, { status: 'ok' });
      const m = url.pathname.match(/^\/cap\/([\w-]+)$/);
      if (req.method !== 'POST' || !m) throw new CapError('not_found', `${req.method} ${url.pathname}`);
      const cap = caps[m[1]];
      if (!cap) throw new CapError('not_found', `unknown capability "${m[1]}"`);
      const chunks: Buffer[] = [];
      for await (const c of req) chunks.push(c as Buffer);
      let body: unknown;
      try { body = JSON.parse(Buffer.concat(chunks).toString() || '{}'); } catch { throw new CapError('usage', 'body is not JSON'); }
      const r = await cap.call(body, { traceparent: req.headers.traceparent as string | undefined });
      send(200, { output: r.output, usage: r.usage, traceId: r.traceId });
    } catch (e) {
      const err = toCapError(e);
      send(httpStatus(err.kind), err.envelope());
    }
  });
  return new Promise<typeof server>((resolve) => server.listen(port, () => resolve(server)));
}

if (import.meta.main) {
  const { caps } = await import('./capabilities.ts');
  const port = Number(process.env.PORT ?? 7790);
  await startServer(caps, port);
  console.error(`listening on :${port}`);
}

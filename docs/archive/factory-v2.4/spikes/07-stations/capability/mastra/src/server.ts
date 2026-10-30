import { Hono } from 'hono';
import { MastraServer, type HonoBindings, type HonoVariables } from '@mastra/hono';
import { mastra } from './mastra.ts';

const app = new Hono<{ Bindings: HonoBindings; Variables: HonoVariables }>();
await new MastraServer({ app, mastra, openapiPath: '/openapi.json' }).init();

const port = Number(process.env.PORT ?? 7792);
if (typeof Bun !== 'undefined') {
  Bun.serve({ fetch: app.fetch, port });
} else {
  const { serve } = await import('@hono/node-server');
  serve({ fetch: app.fetch, port });
}
console.error(`listening on :${port}`);

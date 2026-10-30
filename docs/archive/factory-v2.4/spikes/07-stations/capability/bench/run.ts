// usage: <runtime> bench/run.ts inhouse|mastra  -> one JSON line: cold start to first result + 5 warm calls
const which = process.argv[2];
const text = 'Hermes is the owner\'s messaging agent. It runs on the mac mini and talks to Telegram. Each message becomes a session; cheap models handle triage while Opus handles planning. The gateways broker credentials so the session never sees provider keys.';
const input = { text, maxWords: 30 };

let call: () => Promise<unknown>;
if (which === 'inhouse') {
  const { caps } = await import('../inhouse/src/index.ts');
  call = () => caps.summarize(input);
} else {
  const { summarize } = await import('../mastra/src/mastra.ts');
  call = () => summarize.execute!(input, {}) as Promise<unknown>;
}
const importMs = Math.round(performance.now()); // process start -> modules loaded
const first = await call();
const coldMs = Math.round(performance.now()); // process start -> first result
const warm: number[] = [];
for (let i = 0; i < 5; i++) {
  const s = performance.now();
  await call();
  warm.push(Math.round(performance.now() - s));
}
const median = [...warm].sort((a, b) => a - b)[2];
console.log(JSON.stringify({ which, runtime: typeof Bun !== 'undefined' ? 'bun' : 'node', coldToFirstResultMs: coldMs, importMs, firstCallMs: coldMs - importMs, warm, median, ok: Boolean(first) }));
setTimeout(() => process.exit(0), 2000); // let Mastra flush spans

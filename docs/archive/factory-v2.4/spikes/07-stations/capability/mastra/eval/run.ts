// Eval gate on Mastra: runEvals over the one-step workflow, a code scorer, 0.8 pass-rate threshold.
import { readFileSync } from 'node:fs';
import { runEvals } from '@mastra/core/evals';
import { mastra } from '../src/mastra.ts';

const gate = Number(process.argv.find((a) => a.startsWith('--gate='))?.slice(7) ?? 0.8);

const cases = readFileSync(new URL('./cases.jsonl', import.meta.url), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
const result = await runEvals({
  target: mastra.getWorkflow('summarizeWorkflow'),
  data: cases.map((c) => ({ input: c.input, groundTruth: c.checks })),
  scorers: { workflow: [mastra.getScorer('checksScorer')] },
  concurrency: 1,
  onItemComplete: ({ item, scorerResults }) => console.log(JSON.stringify({ text: (item.input as { text: string }).text.slice(0, 30), scorerResults })),
});
console.log(JSON.stringify({ scores: result.scores, summary: result.summary, verdict: (result as any).verdict }));
const rate = (result.scores as any).workflow?.['summarize-checks'] ?? 0;
console.log(`pass rate ${rate} (gate ${gate})`);
process.exitCode = rate >= gate ? 0 : 1;

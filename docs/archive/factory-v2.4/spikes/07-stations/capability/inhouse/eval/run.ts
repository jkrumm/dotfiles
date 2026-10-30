// Eval gate: runs the cases through the direct-import path, exits 1 below the pass-rate gate.
import { readFileSync } from 'node:fs';
import { caps } from '../src/capabilities.ts';

const gate = Number(process.argv.find((a) => a.startsWith('--gate='))?.slice(7) ?? 0.8);
const words = (s: string) => s.trim().split(/\s+/).filter(Boolean).length;
type Case = { id: string; input: { text: string; maxWords?: number }; checks: { titleMaxWords: number; summaryMaxWords: number; includesAny: string[] } };

const cases: Case[] = readFileSync(new URL('./cases.jsonl', import.meta.url), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
let passed = 0;
for (const c of cases) {
  const failures: string[] = [];
  try {
    const { title, summary } = await caps.summarize(c.input);
    if (words(title) > c.checks.titleMaxWords) failures.push(`title ${words(title)} words`);
    if (words(summary) > c.checks.summaryMaxWords) failures.push(`summary ${words(summary)} words`);
    if (summary.length >= c.input.text.length) failures.push('summary not shorter than text');
    const hay = `${title} ${summary}`.toLowerCase();
    if (!c.checks.includesAny.some((t) => hay.includes(t.toLowerCase()))) failures.push(`none of ${c.checks.includesAny.join('|')}`);
  } catch (e) {
    failures.push(`error: ${(e as Error).message}`);
  }
  if (!failures.length) passed++;
  console.log(`${failures.length ? 'FAIL' : 'ok  '} ${c.id}${failures.length ? '  ' + failures.join('; ') : ''}`);
}
const rate = passed / cases.length;
console.log(`pass rate ${passed}/${cases.length} = ${rate.toFixed(2)} (gate ${gate})`);
process.exitCode = rate >= gate ? 0 : 1;

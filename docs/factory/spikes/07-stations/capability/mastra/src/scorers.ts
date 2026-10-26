import { createScorer } from '@mastra/core/evals';

const words = (s: string) => s.trim().split(/\s+/).filter(Boolean).length;

export const checksScorer = createScorer({ id: 'summarize-checks', description: 'title/summary length, key term, shorter than input' }).generateScore(({ run }) => {
  const out = run.output as { title?: string; summary?: string } | undefined;
  const checks = run.groundTruth as { titleMaxWords: number; summaryMaxWords: number; includesAny: string[] };
  const text = (run.input as { text: string }).text;
  if (!out?.title || !out?.summary) return 0;
  const hay = `${out.title} ${out.summary}`.toLowerCase();
  const ok =
    words(out.title) <= checks.titleMaxWords &&
    words(out.summary) <= checks.summaryMaxWords &&
    out.summary.length < text.length &&
    checks.includesAny.some((t) => hay.includes(t.toLowerCase()));
  return ok ? 1 : 0;
});

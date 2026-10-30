// `cap <id> [--flag value…]`, generated from the registry. Contract subset of ADR-004: json default,
// last stderr line = error JSON, exit 0 ok / 1 general / 2 usage, unknown flags rejected, offline `schema`.
import { readFileSync } from 'node:fs';
import { CapError, schemasOf, toCapError, type Registry } from './core.ts';

type Prop = { type?: string; description?: string; default?: unknown };
const kebab = (s: string) => s.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase());

function parseFlags(argv: string[], props: Record<string, Prop>, extra: string[]) {
  const byFlag = new Map(Object.entries(props).map(([name, p]) => [kebab(name), { name, p }]));
  const input: Record<string, unknown> = {};
  const globals: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) throw new CapError('usage', `unexpected argument "${a}"`, 'flags only: --name value');
    const [flag, inline] = a.slice(2).split(/=(.*)/s);
    if (extra.includes(flag)) {
      globals[flag] = inline ?? argv[++i];
      continue;
    }
    const spec = byFlag.get(flag);
    if (!spec) throw new CapError('usage', `unknown flag --${flag}`, `valid: ${[...byFlag.keys(), ...extra].map((f) => '--' + f).join(' ')}`);
    if (spec.p.type === 'boolean') { input[spec.name] = inline === undefined ? true : inline === 'true'; continue; }
    let v = inline ?? argv[++i];
    if (v === undefined) throw new CapError('usage', `--${flag} needs a value`);
    if (v === '-') v = readFileSync(0, 'utf8');
    if (spec.p.type === 'number' || spec.p.type === 'integer') {
      if (Number.isNaN(Number(v))) throw new CapError('usage', `--${flag} must be a number`);
      input[spec.name] = Number(v);
    } else input[spec.name] = v;
  }
  return { input, globals };
}

function help(caps: Registry): string {
  const lines = ['usage: cap <id> [--flag value…] [--format json|plain]', '       cap schema [id]', '       cap list', ''];
  for (const cap of Object.values(caps)) {
    const props = (schemasOf(cap).input.properties ?? {}) as Record<string, Prop>;
    lines.push(`${cap.def.id}  ${cap.def.description}`);
    for (const [n, p] of Object.entries(props)) lines.push(`  --${kebab(n)} <${p.type}>  ${p.description ?? ''}${p.default !== undefined ? ` (default ${p.default})` : ''}`);
  }
  return lines.join('\n');
}

export async function main(argv: string[], caps: Registry): Promise<number> {
  const out = (s: string) => process.stdout.write(s + '\n');
  try {
    const [cmd, ...rest] = argv;
    if (!cmd || cmd === '--help' || cmd === 'help') return out(help(caps)), cmd ? 0 : 2;
    if (cmd === 'list') return out(JSON.stringify(Object.values(caps).map((c) => ({ id: c.def.id, description: c.def.description, route: c.def.route })))), 0;
    if (cmd === 'schema') {
      const id = rest[0];
      if (id && !caps[id]) throw new CapError('usage', `unknown capability "${id}"`);
      const doc = (c: Registry[string]) => ({ id: c.def.id, description: c.def.description, ...schemasOf(c) });
      return out(JSON.stringify(id ? doc(caps[id]) : Object.values(caps).map(doc), null, 2)), 0;
    }
    const cap = caps[cmd];
    if (!cap) throw new CapError('usage', `unknown command "${cmd}"`, 'try `cap list`');
    const { input, globals } = parseFlags(rest, (schemasOf(cap).input.properties ?? {}) as Record<string, Prop>, ['format']);
    const format = globals.format ?? 'json';
    if (!['json', 'plain'].includes(format)) throw new CapError('usage', `--format must be json or plain`);
    const r = await cap.call(input);
    out(format === 'json' ? JSON.stringify({ output: r.output, usage: r.usage, traceId: r.traceId }) : Object.values(r.output).join('\n'));
    return 0;
  } catch (e) {
    const err = toCapError(e);
    process.stderr.write(JSON.stringify(err.envelope()) + '\n');
    return err.kind === 'usage' || err.kind === 'validation' ? 2 : 1;
  }
}

if (import.meta.main) {
  const { caps } = await import('./capabilities.ts');
  process.exitCode = await main(process.argv.slice(2), caps);
}

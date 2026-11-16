#!/usr/bin/env bun

/**
 * PreToolUse hook: when an agent edits or writes a file, hand it the nested AGENTS.md files of that directory.
 *
 * Claude Code loads a nested AGENTS.md only when a file of its directory is Read. An Edit without a prior Read and a
 * Write load nothing (measured 2026-11-16, 2.1.325), and a factory lead has no Grep or Glob tool and inspects with `rg`
 * in Bash, so it can change `server/` without ever seeing `server/AGENTS.md`. This hook closes that gap: from the target
 * file's directory it walks up to the repository root (the nearest `.git`) and returns every AGENTS.md strictly below
 * the root as `additionalContext`, nearest last. The root file is already loaded and is never returned.
 *
 * Delivered once per session (and per subagent, which has its own context): a state file under
 * ~/.claude/cache/nested-agents/ remembers `size:mtime` per file, and a changed file is delivered again. A SessionStart
 * on `compact` clears that state, because the delivered text is gone from the context.
 *
 * Fails open everywhere: it never blocks a tool call, never exits non-zero, and does nothing outside a git repository.
 * additionalContext is capped by Claude Code at 10,000 characters (longer text becomes a file path and a 2,000-character
 * preview), so the total stays below that: bodies and headers within CONTENT_BUDGET, the rest for the preamble and the
 * list of files named but not delivered.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

export const CONTENT_BUDGET = 9_000;
export const FILE_BUDGET = 8_000;
const MIN_USEFUL = 400;
const MAX_NAMED = 5;
const STATE_KEEP_MS = 3 * 24 * 60 * 60 * 1000;

interface HookInput {
  hook_event_name?: string;
  session_id?: string;
  agent_id?: string;
  cwd?: string;
  tool_name?: string;
  tool_input?: { file_path?: unknown; notebook_path?: unknown };
}

export const defaultStateDir = () => join(process.env.NESTED_AGENTS_STATE_DIR ?? join(homedir(), ".claude", "cache", "nested-agents"));

const isFile = (path: string) => {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
};

/** Every AGENTS.md strictly below the repository root on the way from the target's directory, outermost first; null outside a git repository. */
export function nestedAgentsFiles(target: string): string[] | null {
  const found: string[] = [];
  let dir = dirname(target);
  for (;;) {
    if (existsSync(join(dir, ".git"))) return found.reverse();
    const file = join(dir, "AGENTS.md");
    if (isFile(file)) found.push(file);
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

const stamp = (path: string) => {
  const { size, mtimeMs } = statSync(path);
  return `${size}:${mtimeMs}`;
};

const sessionKey = (input: HookInput) =>
  `${input.session_id ?? "unknown"}${input.agent_id ? `.${input.agent_id}` : ""}`.replace(/[^A-Za-z0-9_.-]/g, "_");

const stateFile = (stateDir: string, input: HookInput) => join(stateDir, `${sessionKey(input)}.json`);

function readSeen(file: string): Record<string, string> {
  try {
    const seen = JSON.parse(readFileSync(file, "utf8"));
    return seen && typeof seen === "object" ? seen : {};
  } catch {
    return {};
  }
}

function writeSeen(stateDir: string, file: string, seen: Record<string, string>): void {
  mkdirSync(stateDir, { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(seen));
  renameSync(tmp, file);
  const cutoff = Date.now() - STATE_KEEP_MS;
  for (const name of readdirSync(stateDir)) {
    const path = join(stateDir, name);
    if (statSync(path).mtimeMs < cutoff) unlinkSync(path);
  }
}

/** `text` cut to at most `max` bytes without a broken character, with `note` appended; unchanged when it fits. */
function fit(text: string, max: number, note: string): { body: string; cut: boolean } {
  const bytes = Buffer.from(text);
  if (bytes.length <= max) return { body: text, cut: false };
  const room = Math.max(0, max - Buffer.byteLength(note));
  return { body: bytes.subarray(0, room).toString("utf8").replace(/�+$/, "") + note, cut: true };
}

/** The additionalContext for this call, or null when there is nothing new to deliver. Records what it delivers. */
export function nestedContext(input: HookInput, stateDir = defaultStateDir()): string | null {
  const raw = input.tool_input?.file_path ?? input.tool_input?.notebook_path;
  if (typeof raw !== "string" || raw === "") return null;
  const target = resolve(input.cwd ?? process.cwd(), raw);
  const files = nestedAgentsFiles(target);
  if (!files || files.length === 0) return null;

  const file = stateFile(stateDir, input);
  const seen = readSeen(file);
  const pending = files.filter((path) => seen[path] !== stamp(path));
  if (pending.length === 0) return null;

  let remaining = CONTENT_BUDGET;
  const blocks = new Map<string, string>();
  const named: string[] = [];
  for (const path of [...pending].reverse()) {
    const header = `### ${path}\n`;
    const room = Math.min(FILE_BUDGET, remaining - Buffer.byteLength(header));
    if (room < MIN_USEFUL) {
      named.push(path);
      continue;
    }
    const { body, cut } = fit(readFileSync(path, "utf8"), room, `\n[cut here: Read ${path} for the rest]\n`);
    // only the nearest file may be cut: a farther one that does not fit whole is named and delivered by a later call
    if (cut && blocks.size > 0) {
      named.push(path);
      continue;
    }
    const block = `${header}${body}`;
    blocks.set(path, block);
    remaining -= Buffer.byteLength(block);
    seen[path] = stamp(path);
  }
  if (blocks.size === 0 && named.length === 0) return null;

  const parts = [`Nested AGENTS.md for ${target}: each applies to its directory and below, the nearest comes last. Follow them.`];
  for (const path of pending) if (blocks.has(path)) parts.push(blocks.get(path) as string);
  if (named.length > 0) {
    const shown = named.slice(0, MAX_NAMED).reverse();
    parts.push(`Not delivered here (too large for one call): ${shown.join(", ")}${named.length > MAX_NAMED ? ` and ${named.length - MAX_NAMED} more` : ""}. Read it before you change files in its directory.`);
  }
  try {
    writeSeen(stateDir, file, seen);
  } catch {
    // an unwritable state directory only means a file is delivered again
  }
  return parts.join("\n");
}

/** SessionStart on compact: the delivered text left the context, so deliver again. */
export function resetSession(input: HookInput, stateDir = defaultStateDir()): void {
  const prefix = sessionKey({ session_id: input.session_id });
  for (const name of readdirSync(stateDir)) if (name === `${prefix}.json` || name.startsWith(`${prefix}.`)) unlinkSync(join(stateDir, name));
}

if (import.meta.main) {
  try {
    const input: HookInput = JSON.parse(await Bun.stdin.text());
    if (input.hook_event_name === "SessionStart") {
      resetSession(input);
    } else {
      const additionalContext = nestedContext(input);
      if (additionalContext) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext } }));
    }
  } catch {
    // never block a tool call
  }
  process.exit(0);
}

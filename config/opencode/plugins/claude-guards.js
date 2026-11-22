// The Claude Code PreToolUse guards, for OpenCode. Under `permission: "allow"` these
// hooks are the only stop between a session and `hc server restart`, `pkill -f`, a
// direct `docker compose`, a review bypass or a test runner outside its slot, so every
// shell call (and every write, edit or patch) passes the same hooks a Claude Code
// Bash / Write / Edit call passes. The hooks own the policy: this plugin feeds each
// the Claude Code payload ({tool_name, tool_input, cwd}) and turns a deny into a
// thrown error. One policy, never a copy.
//
// Which hooks: the PreToolUse groups of the live ~/.claude/settings.json (merged from
// config/settings.template.json) whose matcher covers Bash, Write or Edit, so a guard
// added there reaches OpenCode without a second edit. SKIP names the two that are not
// guards: protect-branches (plugins/protect-branches.js runs it) and nested-agents
// (it only injects context). claude-guards.test.ts fails when the template gains a
// hook this file neither runs nor skips on purpose.
//
// Fail closed: only a clean exit with empty stdout, or with a JSON verdict this file
// understands, lets a call through. A crash, a timeout, a non-zero exit, unparsable
// output or an unreadable settings.json blocks it. The one change a hook may make is
// `updatedInput` (test-slot wraps a test runner in its slot); it is applied.
//
// Scope limit: the hooks run with the OpenCode service's environment, not the
// session's (the shared service starts without the pane's env), so a guard that keys
// on a session variable (review-bypass-guard on FACTORY_SESSION) judges nothing there.
//
// OpenCode v2 API (verified live on 2.0.32): a plugin default-exports { id, setup(ctx) };
// `execute.before` may throw to deny and may replace `event.input`.
import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

const DEFAULT_TIMEOUT_S = 10;
const SKIP = ["protect-branches.ts", "nested-agents.ts"];

// OpenCode tool -> the Claude Code tool name a hook matcher is written against.
const CLAUDE_TOOL = { shell: "Bash", write: "Write", edit: "Edit", patch: "Edit" };

const settingsPath = () => join(process.env.HOME || homedir(), ".claude", "settings.json");

const cache = new Map(); // settings path -> { mtimeMs, groups }

// The PreToolUse groups. Throws when the file cannot be read: no guards means no calls.
function preToolUseGroups() {
  const path = settingsPath();
  try {
    const { mtimeMs } = statSync(path);
    const hit = cache.get(path);
    if (hit?.mtimeMs === mtimeMs) return hit.groups;
    const groups = JSON.parse(readFileSync(path, "utf8"))?.hooks?.PreToolUse;
    if (!Array.isArray(groups)) throw new Error("no hooks.PreToolUse array");
    cache.set(path, { mtimeMs, groups });
    return groups;
  } catch (err) {
    throw new Error(`claude-guards: cannot read the guard list from ${path} (${err.message}) — call blocked`);
  }
}

function matches(matcher, toolName) {
  if (!matcher || matcher === "*") return true;
  try {
    return new RegExp(`^(?:${matcher})$`).test(toolName);
  } catch {
    return false;
  }
}

const hookName = (command) => command.trim().split(/\s+/)[0].split("/").pop();

// Command hooks whose matcher covers this Claude tool name, once per command, minus SKIP.
function guardHooks(groups, toolName) {
  const seen = new Map();
  for (const group of groups) {
    if (!matches(group?.matcher, toolName) || !Array.isArray(group?.hooks)) continue;
    for (const h of group.hooks) {
      if (h?.type !== "command" || typeof h.command !== "string") continue;
      if (SKIP.includes(hookName(h.command)) || seen.has(h.command)) continue;
      seen.set(h.command, h);
    }
  }
  return [...seen.values()];
}

// Every [{ toolName, input }] a call stands for: one for a shell, write or edit, one per
// touched file for a patch (Add -> Write, Update, Delete and Move -> Edit).
function calls(tool, args, directory) {
  const abs = (p) => (isAbsolute(p) ? p : resolve(directory, p));
  if (tool === "shell") {
    return typeof args?.command === "string" ? [{ toolName: "Bash", input: { command: args.command } }] : [];
  }
  if (tool === "patch") {
    const out = [];
    for (const m of String(args?.patchText ?? "").matchAll(
      /^\*\*\* (Add|Update|Delete) File: (.+)$|^\*\*\* Move to: (.+)$/gm,
    )) {
      if (m[3]) out.push({ toolName: "Edit", input: { file_path: abs(m[3].trim()) } });
      else out.push({ toolName: m[1] === "Add" ? "Write" : "Edit", input: { file_path: abs(m[2].trim()) } });
    }
    return out;
  }
  const file = args?.path ?? args?.filePath;
  if (typeof file !== "string" || !file) return [];
  if (tool === "write") return [{ toolName: "Write", input: { file_path: abs(file), content: args?.content } }];
  return [
    {
      toolName: "Edit",
      input: {
        file_path: abs(file),
        old_string: args?.oldString,
        new_string: args?.newString,
        replace_all: args?.replaceAll,
      },
    },
  ];
}

// One hook run: { name, stdout, stderr, exitCode, failure }.
async function runHook(hook, payload, cwd) {
  const name = hookName(hook.command);
  const timeoutMs = (typeof hook.timeout === "number" && hook.timeout > 0 ? hook.timeout : DEFAULT_TIMEOUT_S) * 1000;
  try {
    const proc = Bun.spawn(["/bin/sh", "-c", hook.command], {
      cwd,
      env: { ...process.env, CLAUDE_PROJECT_DIR: cwd },
      stdin: new TextEncoder().encode(JSON.stringify(payload)),
      stdout: "pipe",
      stderr: "pipe",
    });
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      proc.kill();
    }, timeoutMs);
    try {
      const [stdout, stderr, exitCode] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
      if (timedOut) return { name, failure: `timed out after ${timeoutMs / 1000}s` };
      return { name, stdout, stderr, exitCode };
    } finally {
      clearTimeout(timer);
    }
  } catch (err) {
    return { name, failure: String(err) };
  }
}

// A finished run: { deny: string } | { updatedInput } | {} (allow). Anything else denies.
function judge(res) {
  const broke = (why) => ({ deny: `${res.name}: guard hook ${why} — call blocked` });
  if (res.failure) return broke(`could not run (${res.failure})`);
  if (res.exitCode !== 0) {
    const detail = res.stderr.trim().slice(0, 300);
    return broke(`exited ${res.exitCode}${detail ? ` (${detail})` : ""}`);
  }
  if (!res.stdout.trim()) return {};
  let out;
  try {
    out = JSON.parse(res.stdout).hookSpecificOutput;
  } catch {
    return broke("output unparsable");
  }
  if (out?.permissionDecision === "deny") {
    return { deny: out.permissionDecisionReason || `${res.name}: denied` };
  }
  if (out?.updatedInput && typeof out.updatedInput === "object" && !out.permissionDecision) {
    return { updatedInput: out.updatedInput };
  }
  return broke("returned an unexpected verdict");
}

// Runs the matching hooks for each call (in parallel, as Claude Code does) and returns
// the replacement tool input a hook asked for, or undefined. Throws on any deny.
async function guard(tool, args, directory, sessionID) {
  const list = calls(tool, args, directory);
  if (!list.length) return undefined;
  const cwd = typeof args?.workdir === "string" && args.workdir ? resolve(directory, args.workdir) : directory;
  const groups = preToolUseGroups();
  let updated;
  for (const { toolName, input } of list) {
    const hooks = guardHooks(groups, toolName);
    const payload = { session_id: sessionID, cwd, hook_event_name: "PreToolUse", tool_name: toolName, tool_input: input };
    const verdicts = (await Promise.all(hooks.map((h) => runHook(h, payload, cwd)))).map(judge);
    const denies = verdicts.flatMap((v) => (v.deny ? [v.deny] : []));
    if (denies.length) throw new Error(denies.join("\n"));
    const rewrite = verdicts.find((v) => v.updatedInput)?.updatedInput;
    if (rewrite && tool === "shell") updated = rewrite;
  }
  return updated;
}

export default {
  id: "claude-guards",
  async setup(ctx) {
    const directory = ctx.location.directory;
    await ctx.tool.hook("execute.before", async (event) => {
      if (!(event.tool in CLAUDE_TOOL)) return;
      const updated = await guard(event.tool, event.input, directory, event.sessionID);
      if (updated?.command) event.input = { ...event.input, command: updated.command };
    });
  },
};

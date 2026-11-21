// Claude Code command hooks for OpenCode: a repo's .claude/settings.json declares
// edit hooks (the basalt-ui lint shim, a deny on managed files); OpenCode loads the
// repo's AGENTS.md, skills and rules but never runs them. This plugin runs the
// PreToolUse / PostToolUse command hooks whose matcher covers a file-writing tool,
// with the event JSON on stdin in the shape Claude Code sends and CLAUDE_PROJECT_DIR
// set. Exit 2 on PreToolUse denies the call (a thrown error is the deny); exit 2 on
// PostToolUse appends the hook's stderr to the tool result, which is how the model
// hears it. Any other exit is a non-blocking error and stays silent, as in Claude
// Code. Stop and every other event are out of scope (docs/opencode.md).
//
// OpenCode v2 API (verified live on 2.0.32, 2026-11-21): a plugin default-exports
// { id, setup(ctx) }; a named v1 export fails to load. `ctx.tool.hook` takes
// "execute.before" (event: tool, sessionID, id, input; a throw denies) and
// "execute.after" (the same plus status and a mutable result.content of text parts).
// One plugin instance exists per project: ctx.location.directory is that project.
import { statSync, readFileSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";

const DEFAULT_TIMEOUT_S = 60;

// OpenCode tool -> the Claude Code tool name a hook matcher is written against.
const WRITE_TOOLS = { edit: "Edit", write: "Write", apply_patch: "Edit" };

const cache = new Map(); // settings path -> { mtimeMs, hooks }

// The project's hooks object, or null. One stat per call; the file is re-read only
// when its mtime moved. A missing or unparsable file is "no hooks": never block an edit.
function projectHooks(directory) {
  const path = join(directory, ".claude", "settings.json");
  let mtimeMs;
  try {
    mtimeMs = statSync(path).mtimeMs;
  } catch {
    cache.delete(path);
    return null;
  }
  const hit = cache.get(path);
  if (hit?.mtimeMs === mtimeMs) return hit.hooks;
  let hooks = null;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    if (parsed?.hooks && typeof parsed.hooks === "object") hooks = parsed.hooks;
  } catch {}
  cache.set(path, { mtimeMs, hooks });
  return hooks;
}

function matches(matcher, toolName) {
  if (!matcher || matcher === "*") return true;
  try {
    return new RegExp(`^(?:${matcher})$`).test(toolName);
  } catch {
    return false;
  }
}

// Command hooks matching this tool, deduplicated by command (Claude Code does too).
function commandHooks(hooks, event, toolName) {
  const groups = Array.isArray(hooks?.[event]) ? hooks[event] : [];
  const seen = new Map();
  for (const group of groups) {
    if (!matches(group?.matcher, toolName) || !Array.isArray(group?.hooks)) continue;
    for (const h of group.hooks) {
      if (h?.type === "command" && typeof h.command === "string" && !seen.has(h.command)) {
        seen.set(h.command, h);
      }
    }
  }
  return [...seen.values()];
}

// The files a write tool touches, as [{ toolName, path, deleted }].
function targets(tool, args, directory) {
  const abs = (p) => (isAbsolute(p) ? p : resolve(directory, p));
  if (tool === "apply_patch") {
    const out = [];
    for (const m of String(args?.patchText ?? "").matchAll(
      /^\*\*\* (Add|Update|Delete) File: (.+)$|^\*\*\* Move to: (.+)$/gm,
    )) {
      if (m[3]) out.push({ toolName: "Edit", path: abs(m[3].trim()), deleted: false });
      else
        out.push({
          toolName: m[1] === "Add" ? "Write" : "Edit",
          path: abs(m[2].trim()),
          deleted: m[1] === "Delete",
        });
    }
    return out;
  }
  const file = args?.path ?? args?.filePath;
  if (typeof file !== "string" || !file) return [];
  return [{ toolName: WRITE_TOOLS[tool], path: abs(file), deleted: false }];
}

function toolInput(tool, args, path) {
  if (tool === "write") return { file_path: path, content: args?.content };
  if (tool === "edit") {
    return {
      file_path: path,
      old_string: args?.oldString,
      new_string: args?.newString,
      replace_all: args?.replaceAll,
    };
  }
  return { file_path: path };
}

async function runHook(hook, payload, directory) {
  const timeoutMs = (typeof hook.timeout === "number" && hook.timeout > 0 ? hook.timeout : DEFAULT_TIMEOUT_S) * 1000;
  try {
    const proc = Bun.spawn(["/bin/sh", "-c", hook.command], {
      cwd: directory,
      env: { ...process.env, CLAUDE_PROJECT_DIR: directory },
      stdin: new TextEncoder().encode(JSON.stringify(payload)),
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => proc.kill(), timeoutMs);
    try {
      const [stdout, stderr, exitCode] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
      return { stdout, stderr, exitCode };
    } finally {
      clearTimeout(timer);
    }
  } catch {
    return { stdout: "", stderr: "", exitCode: null };
  }
}

// What a finished hook asks for: { block: string } or null. Exit 2 blocks with its
// stderr; exit 0 may block through Claude Code's JSON output.
function verdict(event, res) {
  if (res.exitCode === 2) return { block: res.stderr.trim() || `${event} hook exited 2` };
  if (res.exitCode !== 0 || !res.stdout.trim().startsWith("{")) return null;
  try {
    const json = JSON.parse(res.stdout);
    if (event === "PreToolUse" && json.hookSpecificOutput?.permissionDecision === "deny") {
      return { block: json.hookSpecificOutput.permissionDecisionReason || "denied by PreToolUse hook" };
    }
    if (event === "PostToolUse" && json.decision === "block") {
      return { block: json.reason || "PostToolUse hook blocked" };
    }
  } catch {}
  return null;
}

// Runs every matching hook for every touched file; returns the blocking messages.
async function dispatch(event, tool, args, directory, sessionID, response) {
  if (!(tool in WRITE_TOOLS)) return [];
  const hooks = projectHooks(directory);
  if (!hooks?.[event]) return [];
  const messages = [];
  for (const t of targets(tool, args, directory)) {
    if (event === "PostToolUse" && t.deleted) continue;
    const matching = commandHooks(hooks, event, t.toolName);
    if (!matching.length) continue;
    const payload = {
      session_id: sessionID,
      transcript_path: "",
      cwd: directory,
      hook_event_name: event,
      tool_name: t.toolName,
      tool_input: toolInput(tool, args, t.path),
      ...(event === "PostToolUse" ? { tool_response: { filePath: t.path, success: true, ...response } } : {}),
    };
    const results = await Promise.all(matching.map((h) => runHook(h, payload, directory)));
    for (const res of results) {
      const v = verdict(event, res);
      if (v) messages.push(v.block);
    }
  }
  return messages;
}

export default {
  id: "claude-hooks",
  async setup(ctx) {
    const directory = ctx.location.directory;
    await ctx.tool.hook("execute.before", async (event) => {
      const messages = await dispatch("PreToolUse", event.tool, event.input, directory, event.sessionID);
      if (messages.length) throw new Error(messages.join("\n"));
    });
    await ctx.tool.hook("execute.after", async (event) => {
      if (event.status !== "completed") return;
      const text = event.result?.content?.map((part) => part.text).join("\n");
      const messages = await dispatch("PostToolUse", event.tool, event.input, directory, event.sessionID, {
        output: text,
      });
      if (messages.length) {
        event.result.content.push({
          type: "text",
          text: `PostToolUse hook feedback (.claude/settings.json):\n${messages.join("\n")}`,
        });
      }
    });
  },
};

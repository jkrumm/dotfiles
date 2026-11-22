// Branch protection for OpenCode — the same gate Claude Code gets from
// hooks/protect-branches.ts. That hook owns the logic (push parsing, the
// PR-required repo list, IuRoot rule); this plugin only feeds it the Claude Code
// hook payload and turns a `deny` into a thrown error, so there is one policy,
// not two copies drifting apart.
//
// OpenCode v2 API (verified live on 2.0.32): a plugin default-exports
// { id, setup(ctx) }; the shell tool is `shell` with input.command, and a throw
// from `execute.before` denies the call. Same shape as claude-hooks.js.
import { homedir } from "node:os";
import { join } from "node:path";

const HOOK_TIMEOUT_MS = 10_000;

// process.env.HOME first: Bun's homedir() ignores a HOME set after startup, which the test relies on.
const hookPath = () => join(process.env.HOME || homedir(), ".claude", "hooks", "protect-branches.ts");

// Fail closed: the policy runs for EVERY shell call (a `git` substring pre-filter
// is bypassable — `g\it push`), and only a clean exit with empty stdout allows.
// A crash, a non-zero exit or unparsable output blocks the command.
async function policy(command, directory) {
  let stdout;
  let stderr;
  let exitCode;
  try {
    const proc = Bun.spawn(["bun", hookPath()], {
      stdin: new TextEncoder().encode(
        JSON.stringify({ tool_name: "Bash", tool_input: { command }, cwd: directory }),
      ),
      stdout: "pipe",
      stderr: "pipe",
    });
    // A hung hook must not hang the agent: kill it and fail closed.
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      proc.kill();
    }, HOOK_TIMEOUT_MS);
    try {
      [stdout, stderr, exitCode] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
    } finally {
      clearTimeout(timer);
    }
    if (timedOut) {
      throw new Error(`timed out after ${HOOK_TIMEOUT_MS / 1000}s`);
    }
  } catch (err) {
    throw new Error(`protect-branches: policy hook could not run (${err}) — command blocked`);
  }

  if (exitCode !== 0) {
    const detail = stderr.trim().slice(0, 300);
    throw new Error(
      `protect-branches: policy hook exited ${exitCode}${detail ? ` (${detail})` : ""} — command blocked`,
    );
  }
  if (!stdout.trim()) return;

  let verdict;
  try {
    verdict = JSON.parse(stdout).hookSpecificOutput;
  } catch {
    throw new Error("protect-branches: policy hook output unparsable — command blocked");
  }
  throw new Error(
    verdict?.permissionDecision === "deny"
      ? verdict.permissionDecisionReason
      : "protect-branches: unexpected policy hook verdict — command blocked",
  );
}

export default {
  id: "protect-branches",
  async setup(ctx) {
    const directory = ctx.location.directory;
    await ctx.tool.hook("execute.before", async (event) => {
      if (event.tool !== "shell") return;
      const command = event.input?.command;
      if (typeof command !== "string") return;
      await policy(command, directory);
    });
  },
};

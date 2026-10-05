// Branch protection for OpenCode — the same gate Claude Code gets from
// hooks/protect-branches.ts. That hook owns the logic (push parsing, the
// PR-required repo list, IuRoot rule); this plugin only feeds it the Claude Code
// hook payload and turns a `deny` into a thrown error, so there is one policy,
// not two copies drifting apart. Spec for the hook API: opencode.ai/docs/plugins.
import { homedir } from "node:os";
import { join } from "node:path";

const HOOK = join(homedir(), ".claude", "hooks", "protect-branches.ts");
const HOOK_TIMEOUT_MS = 10_000;

// Fail closed: the policy runs for EVERY bash call (a `git` substring pre-filter
// is bypassable — `g\it push`), and only a clean exit with empty stdout allows.
// A crash, a non-zero exit or unparsable output blocks the command.
export const ProtectBranches = async ({ directory }) => ({
  "tool.execute.before": async (input, output) => {
    if (input.tool !== "bash") return;
    const command = output.args?.command;
    if (typeof command !== "string") return;

    let stdout;
    let stderr;
    let exitCode;
    try {
      const proc = Bun.spawn(["bun", HOOK], {
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
  },
});

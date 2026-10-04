// Branch protection for OpenCode — the same gate Claude Code gets from
// hooks/protect-branches.ts. That hook owns the logic (push parsing, the
// PR-required repo list, IuRoot rule); this plugin only feeds it the Claude Code
// hook payload and turns a `deny` into a thrown error, so there is one policy,
// not two copies drifting apart. Spec for the hook API: opencode.ai/docs/plugins.
import { homedir } from "node:os";
import { join } from "node:path";

const HOOK = join(homedir(), ".claude", "hooks", "protect-branches.ts");

export const ProtectBranches = async ({ directory }) => ({
  "tool.execute.before": async (input, output) => {
    if (input.tool !== "bash") return;
    const command = output.args?.command;
    if (typeof command !== "string" || !command.includes("git")) return;

    const proc = Bun.spawn(["bun", HOOK], {
      stdin: new TextEncoder().encode(
        JSON.stringify({ tool_name: "Bash", tool_input: { command }, cwd: directory }),
      ),
      stdout: "pipe",
      stderr: "ignore",
    });
    const stdout = await new Response(proc.stdout).text();
    await proc.exited;

    if (!stdout.trim()) return;
    let verdict;
    try {
      verdict = JSON.parse(stdout).hookSpecificOutput;
    } catch {
      return;
    }
    if (verdict?.permissionDecision === "deny") throw new Error(verdict.permissionDecisionReason);
  },
});

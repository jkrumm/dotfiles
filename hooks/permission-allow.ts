#!/usr/bin/env bun

/**
 * PermissionRequest hook: answer every permission dialog that survives
 * `bypassPermissions`, so an unattended session never waits on a human.
 *
 * Permission is pre-granted on these machines (global CLAUDE.md); the dialogs
 * that still appear under bypass (an `ask` rule, a protected path, a tool that
 * wants confirmation) only stall a session nobody is watching. The real
 * guards are PreToolUse denies (protect-branches, broad-kill-guard,
 * review-bypass-guard, …) and `permissions.deny`, which run before this and
 * win over an allow.
 *
 * One exception stays a stop: `rm` aimed at `/` or the home directory is
 * irreversible loss. It is denied at once with a rewrite hint, instead of the
 * built-in two-minute wait.
 *
 * Not reachable from a hook (Claude Code's own limits): MCP tools that require
 * user interaction, MCP elicitation, `AskUserQuestion` (denied in settings).
 */

interface HookInput {
  tool_name?: string;
  tool_input?: { command?: string; [key: string]: unknown };
}

/**
 * `rm` aimed at `/` or the home directory. Matched on the command with quotes and
 * backslashes removed, so `bash -c "rm -rf ~"`, `rm -rf "$HOME"/*` and `\rm -rf /`
 * read like the plain form; `rm` may follow a path (`/bin/rm`) as well as a
 * separator. The target must end at the path itself (`/`, `/*`, `/.`, `~/`), so
 * `rm -rf /tmp/x` and `rm -rf ~/x` stay allowed.
 */
const DANGEROUS_RM =
  /(?:^|[\s;&|(\/`])rm\s+(?:-\S+\s+)*(?:\/|~|\$HOME|\$\{HOME\})(?:\/?\*|\.|\/\.?)?(?=\s|$|[;&|)`])/;

export function decide(input: HookInput): { behavior: "allow" } | { behavior: "deny"; message: string } {
  const command = input.tool_input?.command ?? "";
  if (input.tool_name === "Bash" && DANGEROUS_RM.test(command.replace(/['"\\]/g, ""))) {
    return {
      behavior: "deny",
      message:
        "rm on / or the home directory is never run unattended. Delete the specific paths you created instead.",
    };
  }
  return { behavior: "allow" };
}

if (import.meta.main) {
  const input: HookInput = JSON.parse(await Bun.stdin.text());
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: { hookEventName: "PermissionRequest", decision: decide(input) },
    }),
  );
}

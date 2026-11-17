#!/usr/bin/env bun

/**
 * PreToolUse hook: no agent sets an environment variable on the shared launchd
 * domain.
 *
 * Incident 2026-11-17 21:39Z (issue 2152): a lead ran
 * `launchctl setenv HTTPS_PROXY http://127.0.0.1:9` to black out one service in a
 * test and never unset it. `launchctl setenv` is global to the login session: every
 * job and process started afterwards inherits it, so every heartbeat push (devhost
 * health, hermes, linewatch) hit the dead proxy until the owner's lead unset it six
 * minutes later, and Uptime Kuma paged "Software Factory - Push is down".
 *
 * Denied (command position only; `sudo`, `env`, `;`/`&&` chains, `ssh <host> '<cmd>'`,
 * `bash -c` and `eval` are looked through): `launchctl setenv`.
 * Allowed: `launchctl unsetenv|getenv|print`, and every word above inside quotes.
 * A test that needs a dead proxy hands it to its own child (`HTTPS_PROXY=… cmd`).
 */

import { collect } from "./broad-kill-guard.ts";

interface HookInput {
  tool_name: string;
  tool_input?: { command?: string; [key: string]: unknown };
}

const REASON =
  "`launchctl setenv` sets the variable for every job and process of the login session, not for your test " +
  "(incident 2026-11-17: HTTPS_PROXY=127.0.0.1:9 left on the domain blacked out every Uptime Kuma heartbeat). " +
  "Give the variable to your own child instead: `HTTPS_PROXY=… <cmd>` or `env HTTPS_PROXY=… <cmd>`.";

export function findViolation(command: string, depth = 0): string | null {
  if (depth > 4) return null;
  for (const { name, args } of collect(command)) {
    if (name === "launchctl" && args.includes("setenv")) return REASON;
    // `ssh host 'cmd'` and `ssh host cmd…`: the remote command is the quoted argument or what follows the host.
    if (name === "ssh") {
      const remotes = [...args.filter((a) => /\s/.test(a)), args.filter((a) => !a.startsWith("-")).slice(1).join(" ")];
      for (const remote of remotes) {
        const nested = remote ? findViolation(remote, depth + 1) : null;
        if (nested) return nested;
      }
    }
  }
  return null;
}

if (import.meta.main) {
  const input: HookInput = JSON.parse(await Bun.stdin.text());
  const violation = input.tool_name === "Bash" ? findViolation((input.tool_input?.command ?? "").trim()) : null;
  if (violation) {
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: violation },
      }),
    );
  }
}

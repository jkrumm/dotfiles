#!/usr/bin/env bun

/**
 * SessionStart logger.
 *
 * Writes one `session_env` entry per session start (ANTHROPIC_BASE_URL +
 * USAGE_LANE + the Claude account id) to the structured JSONL debug log at
 * ~/.claude/logs/YYYY-MM-DD.jsonl — usage-tracker bills each launcher from it.
 * The line also carries the factory runner's FACTORY_ROLE and FACTORY_SESSION
 * when set (usage-tracker reads them to attribute a session's lane/role).
 * Prunes log files older than 3 days on every run. Never blocks Claude: any
 * failure exits 0.
 *
 * Desktop notifications were removed — the Herdr app's native agent-state
 * notifications cover "input required" and "done".
 */

import { appendFileSync, existsSync, mkdirSync, readdirSync, statSync, unlinkSync } from "fs";
import { dirname, join } from "path";
import { homedir } from "os";

const LOG_DIR = join(homedir(), ".claude", "logs");

function logEvent(
  src: string,
  event: string,
  level: "info" | "warn" | "error",
  data: Record<string, unknown>
): void {
  try {
    mkdirSync(LOG_DIR, { recursive: true });
    const date = new Date();
    const entry =
      JSON.stringify({ ts: date.toISOString(), src, event, level, data }) + "\n";
    appendFileSync(join(LOG_DIR, `${date.toISOString().slice(0, 10)}.jsonl`), entry);
  } catch {
    // never throw from logging
  }
}

function cleanupOldLogs(keepDays = 3): void {
  try {
    if (!existsSync(LOG_DIR)) return;
    const cutoff = Date.now() - keepDays * 24 * 60 * 60 * 1000;
    for (const file of readdirSync(LOG_DIR)) {
      if (!file.endsWith(".jsonl")) continue;
      const filePath = join(LOG_DIR, file);
      if (statSync(filePath).mtimeMs < cutoff) unlinkSync(filePath);
    }
  } catch {
    // never throw from logging
  }
}

/**
 * Registry id of the account this session runs on, from `claude-account account` (CLAUDE_CONFIG_DIR unset = the default
 * account). null when it cannot say: no CLI, unreadable registry, or a dir no account owns ("?").
 */
function currentAccount(): string | null {
  try {
    const bin = Bun.which("claude-account") ?? join(homedir(), ".local", "bin", "claude-account");
    const r = Bun.spawnSync([bin, "account"], {
      // the CLI is `#!/usr/bin/env bun`: the bun that runs this hook must be findable
      env: { ...process.env, PATH: `${process.env.PATH ?? ""}:${dirname(process.execPath)}` },
      stdout: "pipe",
      stderr: "ignore",
      timeout: 5_000,
    });
    const id = r.exitCode === 0 ? r.stdout.toString().trim() : "";
    return id && id !== "?" ? id : null;
  } catch {
    return null;
  }
}

async function main() {
  try {
    const input: { session_id?: string; hook_event_name?: string } = JSON.parse(
      await Bun.stdin.text()
    );
    cleanupOldLogs();
    if (input.hook_event_name !== "SessionStart") return;

    logEvent("hook", "session_env", "info", {
      session: input.session_id,
      base_url: process.env.ANTHROPIC_BASE_URL || null,
      lane: process.env.USAGE_LANE || null,
      account: currentAccount(),
      factory_role: process.env.FACTORY_ROLE || null,
      factory_session: process.env.FACTORY_SESSION || null,
    });
  } catch (error) {
    console.error("session-env hook error:", error);
  }
}

await main();
process.exit(0);

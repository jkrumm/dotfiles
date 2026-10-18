#!/usr/bin/env bun

/**
 * SessionStart logger.
 *
 * Writes one `session_env` entry per session start (ANTHROPIC_BASE_URL +
 * USAGE_LANE) to the structured JSONL debug log at
 * ~/.claude/logs/YYYY-MM-DD.jsonl — usage-tracker bills each launcher from it.
 * Prunes log files older than 3 days on every run. Never blocks Claude: any
 * failure exits 0.
 *
 * Desktop notifications were removed — herdr's native agent-state
 * notifications cover "input required" and "done".
 */

import { appendFileSync, existsSync, mkdirSync, readdirSync, statSync, unlinkSync } from "fs";
import { join } from "path";
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
    });
  } catch (error) {
    console.error("session-env hook error:", error);
  }
}

await main();
process.exit(0);

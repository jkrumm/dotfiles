#!/usr/bin/env bun

/**
 * Claude Code Notification System
 *
 * Rich macOS notifications for Claude Code CLI events with enhanced context
 * and workspace-specific sound identification.
 *
 * ============================================================================
 * FEATURES
 * ============================================================================
 *
 * 1. Enhanced Context Display
 *    Format: project • branch • duration
 *    - Project: Extracted from cwd (SourceRoot: 2 levels, IuRoot: 1 level)
 *    - Branch: Extracted from transcript (skips main/master)
 *    - Duration: Elapsed time since session start
 *
 *    Examples:
 *    - SourceRoot: "free-planning-poker/fpp-analytics • feat/JK-123 • 2m 34s"
 *    - IuRoot:     "epos.student-enrolment • feat/EP-456 • 1m 12s"
 *
 * 2. Workspace-Specific Sounds (identify workspace by sound)
 *    - SourceRoot → Hero (personal projects)
 *    - IuRoot     → Ping (work projects)
 *    - Other      → Tink (unknown workspace)
 *
 *    Use case: Multiple tabs open, hear sound to know which workspace needs attention
 *
 * 3. Click-to-Focus
 *    Uses terminal-notifier to bring Warp terminal to foreground on click
 *
 * 4. State Persistence
 *    Tracks session timing, project, branch, workspace across hook invocations
 *
 * ============================================================================
 * NOTIFICATION EVENTS
 * ============================================================================
 *
 * - SessionStart:  Silently tracks session start time and context
 * - Notification:  Input required (idle_prompt) or permission needed
 * - Stop:          Task completion with summary
 * - SessionEnd:    Session summary with total duration
 *
 * ============================================================================
 * CONFIGURATION
 * ============================================================================
 *
 * Sound Customization (line ~65):
 * const WORKSPACE_SOUNDS = {
 *   SourceRoot: "Hero",  // Change to any macOS sound
 *   IuRoot: "Ping",      // Available: Glass, Tink, Pop, Purr, etc.
 *   Other: "Tink"
 * }
 *
 * Project Path Patterns (line ~107):
 * - SourceRoot: ~/SourceRoot/repo/project
 *   Extracts: "repo/project" (2 levels)
 * - IuRoot: ~/IuRoot/project
 *   Extracts: "project" (1 level)
 *
 * Available macOS Sounds:
 * Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr,
 * Sosumi, Submarine, Tink
 *
 * ============================================================================
 * STATE FILE
 * ============================================================================
 *
 * Location: ~/.claude/notification-state.json
 *
 * Structure:
 * {
 *   "sessionStartTime": 1735600000000,
 *   "currentSession": "abc123",
 *   "projectName": "free-planning-poker/fpp-analytics",
 *   "workspace": "SourceRoot",
 *   "gitBranch": "feat/JK-123",
 *   "chatContext": "Implement notification system"
 * }
 *
 * ============================================================================
 * TROUBLESHOOTING
 * ============================================================================
 *
 * Notifications not showing:
 * - Check macOS Notification Settings → Script Editor → Allow Notifications
 * - Ensure terminal-notifier is installed: brew install terminal-notifier
 * - Test manually: terminal-notifier -title "Test" -message "Hello"
 *
 * Wrong sounds:
 * - Sound names are case-sensitive ("Hero" not "hero")
 * - Test sound: afplay /System/Library/Sounds/Hero.aiff
 *
 * Wrong project name:
 * - Verify cwd path includes "SourceRoot" or "IuRoot"
 * - Check extractProjectName() logic (line ~107)
 *
 * No branch shown:
 * - Branch is skipped if main/master
 * - Verify transcript has gitBranch field
 * - Check extractGitBranch() logic (line ~180)
 *
 * Duration not showing:
 * - SessionStart must fire first to track start time
 * - Check state file has sessionStartTime
 *
 * ============================================================================
 * USAGE WITH MULTIPLE TABS
 * ============================================================================
 *
 * Scenario: 3 Warp tabs open
 * 1. SourceRoot/free-planning-poker/fpp-analytics on feat/JK-123
 * 2. IuRoot/epos.student-enrolment on feat/EP-456
 * 3. SourceRoot/basalt-ui/examples on main
 *
 * Notification arrives:
 * - Sound: Hero (SourceRoot)
 * - Body: "free-planning-poker/fpp-analytics • feat/JK-123 • 2m 34s"
 *
 * You immediately know:
 * ✓ SourceRoot workspace (heard Hero)
 * ✓ free-planning-poker repo
 * ✓ feat/JK-123 branch
 * ✓ 2m 34s elapsed
 * → Quickly find the right tab!
 */

import { $ } from "bun";
import { readFileSync, writeFileSync, appendFileSync, existsSync, writeSync, mkdirSync, readdirSync, statSync, unlinkSync } from "fs";
import { join } from "path";
import { homedir } from "os";

// ============================================================================
// Structured Logging
// ============================================================================

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
    const dateStr = date.toISOString().slice(0, 10);
    const entry =
      JSON.stringify({ ts: date.toISOString(), src, event, level, data }) +
      "\n";
    appendFileSync(join(LOG_DIR, `${dateStr}.jsonl`), entry);
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
      if (statSync(filePath).mtimeMs < cutoff) {
        unlinkSync(filePath);
      }
    }
  } catch {
    // never throw from logging
  }
}

// ============================================================================
// Queue Integration
// ============================================================================

/**
 * Find the cqueue.md file for the given cwd by locating the git root.
 * Returns null if cwd is not inside a git repo.
 */
function findQueueFile(cwd: string): string | null {
  try {
    const result = Bun.spawnSync(["git", "rev-parse", "--show-toplevel"], {
      cwd,
      stdout: "pipe",
      stderr: "pipe",
    });
    if (result.exitCode !== 0) return null;
    return join(result.stdout.toString().trim(), "sc-queue.md");
  } catch {
    return null;
  }
}

function parseQueueBlocks(raw: string): string[] {
  const lines = raw.split("\n");

  // Skip leading header lines (# comments and blanks)
  let startIdx = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("#") || line === "") {
      startIdx = i + 1;
    } else {
      break;
    }
  }

  const body = lines.slice(startIdx).join("\n");
  if (!body.trim()) return [];

  return body.split(/\n---\n/).map((b) => b.trim()).filter((b) => b.length > 0);
}

function writeQueueBlocks(queueFile: string, blocks: string[]): void {
  const content = blocks.length === 0 ? "" : blocks.join("\n---\n") + "\n";
  writeFileSync(queueFile, content);
}

/**
 * Pop the first task from the repo's cqueue.md.
 * Returns null if no queue or empty, "STOP" for the STOP sentinel.
 */
function popQueueTask(queueFile: string): string | null {
  if (!existsSync(queueFile)) return null;

  try {
    const raw = readFileSync(queueFile, "utf-8");
    const blocks = parseQueueBlocks(raw);
    if (blocks.length === 0) return null;

    const [first, ...rest] = blocks;
    writeQueueBlocks(queueFile, rest);

    return first;
  } catch {
    return null;
  }
}

/** Count remaining tasks after a pop. */
function getQueueSize(queueFile: string): number {
  if (!existsSync(queueFile)) return 0;

  try {
    const raw = readFileSync(queueFile, "utf-8");
    return parseQueueBlocks(raw).length;
  } catch {
    return 0;
  }
}

// ============================================================================
// Question Detection (prevents queue from overriding pending questions)
// ============================================================================

interface TranscriptMessage {
  role: string;
  text: string;
}

/**
 * Extract the last N messages from the transcript as role+text pairs.
 * Truncates from the START to preserve the end (where questions live).
 * Last message gets more room since it contains the actual question.
 */
function extractLastMessages(
  transcriptPath: string,
  count: number = 5
): TranscriptMessage[] {
  if (!existsSync(transcriptPath)) return [];

  try {
    const lines = readFileSync(transcriptPath, "utf-8")
      .split("\n")
      .filter((l) => l.trim());

    const messages: TranscriptMessage[] = [];

    for (const line of lines.slice(-count * 2).reverse()) {
      if (messages.length >= count) break;
      try {
        const entry = JSON.parse(line);
        if (entry.role && entry.content && Array.isArray(entry.content)) {
          const textParts: string[] = [];
          for (const block of entry.content) {
            if (block.type === "text" && block.text) {
              textParts.push(block.text);
            }
          }
          if (textParts.length > 0) {
            messages.unshift({ role: entry.role, text: textParts.join("\n") });
          }
        }
      } catch {
        continue;
      }
    }

    // Truncate from the start: last message gets 2000 chars, earlier ones 500
    return messages.map((msg, i) => {
      const isLast = i === messages.length - 1;
      const limit = isLast ? 2000 : 500;
      if (msg.text.length > limit) {
        return { role: msg.role, text: "…" + msg.text.slice(-limit) };
      }
      return msg;
    });
  } catch {
    return [];
  }
}

/**
 * Check if the last assistant turn used the AskUserQuestion tool.
 * Zero false positives — this is the fast/free check.
 */
function hadAskUserQuestion(transcriptPath: string): boolean {
  if (!existsSync(transcriptPath)) return false;

  try {
    const lines = readFileSync(transcriptPath, "utf-8")
      .split("\n")
      .filter((l) => l.trim());

    for (const line of lines.slice(-5).reverse()) {
      try {
        const entry = JSON.parse(line);
        if (entry.role === "assistant" && Array.isArray(entry.content)) {
          for (const block of entry.content) {
            if (
              block.type === "tool_use" &&
              block.name === "AskUserQuestion"
            ) {
              return true;
            }
          }
        }
      } catch {
        continue;
      }
    }
    return false;
  } catch {
    return false;
  }
}

/**
 * Ask Haiku whether Claude is waiting for user input.
 * Only called when the last assistant message contains "?".
 * Returns true if Haiku thinks Claude is asking a question.
 */
async function haikuEvaluatesQuestion(
  messages: TranscriptMessage[]
): Promise<boolean> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey || messages.length === 0) {
    logEvent("hook", "haiku_skip", "warn", {
      reason: !apiKey ? "no_api_key" : "no_messages",
      api_key_present: !!apiKey,
      msg_count: messages.length,
    });
    return false;
  }

  const conversationText = messages
    .map((m) => `[${m.role}]: ${m.text}`)
    .join("\n\n");

  const t0 = Date.now();
  try {
    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 10,
        system:
          "Determine if the assistant's final message is asking the user a question or requesting input/decision/clarification. Respond with only YES or NO.",
        messages: [{ role: "user", content: conversationText }],
      }),
    });

    const latencyMs = Date.now() - t0;

    if (!response.ok) {
      logEvent("hook", "haiku_call", "error", {
        http_status: response.status,
        latency_ms: latencyMs,
        result: false,
      });
      return false;
    }

    const data = (await response.json()) as {
      content?: Array<{ text?: string }>;
    };
    const answer = data.content?.[0]?.text?.trim().toUpperCase();
    const isQuestion = answer?.startsWith("YES") ?? false;

    logEvent("hook", "haiku_call", "info", {
      answer,
      result: isQuestion,
      latency_ms: latencyMs,
      http_status: response.status,
    });

    return isQuestion;
  } catch (err) {
    logEvent("hook", "haiku_call", "error", {
      error: String(err),
      latency_ms: Date.now() - t0,
      result: false,
    });
    return false;
  }
}

/**
 * Two-tier question detection:
 * 1. Fast: check for AskUserQuestion tool (zero false positives)
 * 2. Smart: if last message has "?", ask Haiku to evaluate
 */
async function isWaitingForInput(transcriptPath: string): Promise<boolean> {
  // Tier 1: explicit AskUserQuestion tool
  if (hadAskUserQuestion(transcriptPath)) {
    process.stderr.write("[cq] Question detected (AskUserQuestion tool)\n");
    logEvent("hook", "question_detect", "info", { tier: 1, result: true });
    return true;
  }

  // Tier 2: "?" in last assistant message → Haiku evaluation
  const messages = extractLastMessages(transcriptPath, 5);
  if (messages.length === 0) {
    logEvent("hook", "question_detect", "info", {
      tier: 2,
      result: false,
      reason: "no_messages",
    });
    return false;
  }

  const lastMsg = messages[messages.length - 1];
  const hasQuestionMark =
    lastMsg.role === "assistant" && lastMsg.text.includes("?");

  if (!hasQuestionMark) {
    logEvent("hook", "question_detect", "info", {
      tier: 2,
      result: false,
      reason: "no_question_mark",
      last_role: lastMsg.role,
      last_msg_preview: lastMsg.text.slice(-100),
    });
    return false;
  }

  const isQuestion = await haikuEvaluatesQuestion(messages);
  if (isQuestion) {
    process.stderr.write("[cq] Question detected (Haiku evaluation)\n");
  }
  logEvent("hook", "question_detect", "info", {
    tier: 2,
    has_question_mark: true,
    haiku_result: isQuestion,
    result: isQuestion,
  });
  return isQuestion;
}

// ============================================================================
// Types & Configuration
// ============================================================================

interface HookInput {
  session_id: string;
  transcript_path: string;
  cwd: string;
  permission_mode: string;
  hook_event_name: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  tool_response?: Record<string, unknown>;
  prompt?: string;
  message?: string;
  notification_type?: string;
  stop_hook_active?: boolean;
  trigger?: string;
  source?: string;
}

interface NotificationState {
  sessionStartTime?: number;
  currentSession?: string;
  activeSubagents: string[];
  lastEvent?: string;
  chatContext?: string;
  projectName?: string;
  gitBranch?: string;
  workspace?: "SourceRoot" | "IuRoot" | "Other";
}

interface NotificationConfig {
  title: string;
  body: string;
  sound: string;
  subtitle?: string;
}

const STATE_FILE = join(homedir(), ".claude", "notification-state.json");

const SOUNDS = {
  success: "Glass",      // Task/session complete
  input: "Tink",         // User input required (default)
  error: "Basso",        // Errors or problems
  completion: "Hero",    // Subagent completion
  info: "Purr",          // General info
} as const;

// Workspace-specific sounds for input required (Option 2)
const WORKSPACE_SOUNDS = {
  SourceRoot: "Hero",      // Personal projects - heroic sound
  IuRoot: "Ping",          // Work projects - sharp attention sound
  Other: "Tink",           // Unknown workspace - default
} as const;

// ============================================================================
// State Management
// ============================================================================

function loadState(): NotificationState {
  if (!existsSync(STATE_FILE)) {
    return { activeSubagents: [] };
  }
  try {
    return JSON.parse(readFileSync(STATE_FILE, "utf-8"));
  } catch {
    return { activeSubagents: [] };
  }
}

function saveState(state: NotificationState): void {
  try {
    writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
  } catch (error) {
    console.error("Failed to save state:", error);
  }
}

// ============================================================================
// Project Name Extraction
// ============================================================================

function extractProjectName(cwd: string): string | undefined {
  const pathParts = cwd.split("/");

  // Check for SourceRoot pattern
  const sourceRootIdx = pathParts.indexOf("SourceRoot");
  if (sourceRootIdx >= 0 && pathParts.length > sourceRootIdx + 1) {
    // SourceRoot: extract 2 levels (e.g., "free-planning-poker/fpp-analytics")
    const projectParts = pathParts.slice(sourceRootIdx + 1);
    return projectParts.length >= 2
      ? projectParts.slice(0, 2).join("/")
      : projectParts[0];
  }

  // Check for IuRoot pattern
  const iuRootIdx = pathParts.indexOf("IuRoot");
  if (iuRootIdx >= 0 && pathParts.length > iuRootIdx + 1) {
    // IuRoot: extract 1 level (e.g., "epos.student-enrolment")
    return pathParts[iuRootIdx + 1];
  }

  // Fallback: use last directory name
  return pathParts[pathParts.length - 1] || undefined;
}

function detectWorkspace(cwd: string): "SourceRoot" | "IuRoot" | "Other" {
  if (cwd.includes("/SourceRoot/")) return "SourceRoot";
  if (cwd.includes("/IuRoot/")) return "IuRoot";
  return "Other";
}

// ============================================================================
// Chat Context Extraction
// ============================================================================

function extractChatContext(transcriptPath: string): string | undefined {
  if (!existsSync(transcriptPath)) {
    return undefined;
  }

  try {
    const lines = readFileSync(transcriptPath, "utf-8")
      .split("\n")
      .filter((line) => line.trim());

    // Look for user messages to infer context
    for (const line of lines.slice(-50).reverse()) {
      try {
        const entry = JSON.parse(line);
        if (entry.role === "user" && entry.content?.[0]?.type === "text") {
          const text = entry.content[0].text.trim();
          // Extract first meaningful sentence (max 60 chars)
          const match = text.match(/^(.{1,60})[\.\!\?]?\s/);
          if (match) {
            return match[1].trim();
          }
          return text.slice(0, 60);
        }
      } catch {
        continue;
      }
    }

    return "Active session";
  } catch {
    return undefined;
  }
}

function extractGitBranch(transcriptPath: string): string | undefined {
  if (!existsSync(transcriptPath)) {
    return undefined;
  }

  try {
    const lines = readFileSync(transcriptPath, "utf-8")
      .split("\n")
      .filter((line) => line.trim());

    // Look for most recent gitBranch in transcript entries
    for (const line of lines.slice(-20).reverse()) {
      try {
        const entry = JSON.parse(line);
        if (entry.gitBranch && entry.gitBranch !== "main" && entry.gitBranch !== "master") {
          return entry.gitBranch;
        }
      } catch {
        continue;
      }
    }

    return undefined; // No branch found or on main/master
  } catch {
    return undefined;
  }
}

// ============================================================================
// Duration Formatting
// ============================================================================

function formatDuration(milliseconds: number): string {
  const seconds = Math.floor(milliseconds / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);

  if (hours > 0) {
    return `${hours}h ${minutes % 60}m`;
  } else if (minutes > 0) {
    return `${minutes}m ${seconds % 60}s`;
  } else {
    return `${seconds}s`;
  }
}

function getDuration(state: NotificationState): string | undefined {
  if (!state.sessionStartTime) {
    return undefined;
  }
  const duration = Date.now() - state.sessionStartTime;
  return formatDuration(duration);
}

// ============================================================================
// Notification Handlers
// ============================================================================

function handleNotificationEvent(
  input: HookInput,
  state: NotificationState
): NotificationConfig | null {
  const { notification_type, message } = input;

  // Handle idle_prompt (user input required)
  if (notification_type === "idle_prompt") {
    const duration = getDuration(state);
    const project = state.projectName || "Claude Code";
    const branch = state.gitBranch;

    // Build enhanced body: project • branch • duration
    const parts = [project];
    if (branch) parts.push(branch);
    if (duration) parts.push(duration);

    // Workspace-specific sound (Option 2)
    const workspace = state.workspace || "Other";
    const sound = WORKSPACE_SOUNDS[workspace];

    return {
      title: "Claude Code",
      subtitle: "Input Required",
      body: parts.join(" • "),
      sound: sound,
    };
  }

  // Handle permission_prompt
  if (notification_type === "permission_prompt") {
    const project = state.projectName || "Claude Code";
    const branch = state.gitBranch;

    const parts = [project];
    if (branch) parts.push(branch);
    parts.push(message || "Action requires approval");

    return {
      title: "Claude Code",
      subtitle: "Permission Needed",
      body: parts.join(" • "),
      sound: SOUNDS.info,
    };
  }

  return null;
}

async function handleStopEvent(
  input: HookInput,
  state: NotificationState
): Promise<NotificationConfig | null> {
  const queueFile = findQueueFile(input.cwd);
  const queueSize = queueFile ? getQueueSize(queueFile) : 0;

  logEvent("hook", "queue_state", "info", {
    file: queueFile,
    size: queueSize,
    exists: queueFile ? existsSync(queueFile) : false,
  });

  // Before popping: check if Claude is asking the user a question
  const hasQueue =
    queueFile && existsSync(queueFile) && queueSize > 0;
  if (hasQueue && (await isWaitingForInput(input.transcript_path))) {
    // Skip queue — let the user answer first. Queue stays intact.
    const remaining = getQueueSize(queueFile!);
    process.stderr.write(
      `[cq] Paused queue (${remaining} remaining) — Claude needs input\n`
    );
    logEvent("hook", "stop_decision", "info", {
      decision: "pause_for_question",
      remaining,
    });
    // Fall through to normal stop notification
    const duration = getDuration(state);
    const project = state.projectName || "Task";
    const branch = state.gitBranch;
    const parts = [project];
    if (branch) parts.push(branch);
    if (duration) parts.push(duration);
    return {
      title: "Claude Code",
      subtitle: "Input Required (queue paused)",
      body: parts.join(" • "),
      sound:
        WORKSPACE_SOUNDS[state.workspace || "Other"],
    };
  }

  const nextTask = queueFile ? popQueueTask(queueFile) : null;

  if (nextTask !== null) {
    const taskType =
      nextTask === "STOP"
        ? "stop"
        : nextTask.trim() === "/clear"
        ? "clear"
        : nextTask.trim().startsWith("/")
        ? "slash"
        : "text";
    logEvent("hook", "queue_pop", "info", {
      task_type: taskType,
      preview: nextTask.slice(0, 80),
      remaining: queueFile ? getQueueSize(queueFile) : 0,
    });
  }

  if (nextTask === "STOP") {
    process.stderr.write("[sc] STOPPED\n");
    logEvent("hook", "stop_decision", "info", { decision: "stop_sentinel" });
    process.exit(0);
  }

  // Handle /clear — end session, signal c() to restart with next task
  if (nextTask?.trim() === "/clear") {
    // Skip consecutive /clear blocks
    let nextRealTask: string | null = null;
    while (true) {
      nextRealTask = queueFile ? popQueueTask(queueFile) : null;
      if (!nextRealTask || nextRealTask.trim() !== "/clear") break;
    }

    if (!nextRealTask || nextRealTask === "STOP") {
      process.stderr.write("[cq] Context clear — session ending\n");
      logEvent("hook", "stop_decision", "info", { decision: "clear_then_stop" });
      process.exit(0);
    }

    // Write next task to marker file — c() reads it and restarts Claude
    writeFileSync(
      join(homedir(), ".claude", ".queue-restart"),
      nextRealTask
    );
    const remaining = getQueueSize(queueFile!);
    process.stderr.write(
      `[cq] Context clear — restarting (${remaining} remaining)\n`
    );
    logEvent("hook", "stop_decision", "info", {
      decision: "clear_then_restart",
      remaining,
      next_preview: nextRealTask.slice(0, 80),
    });
    process.exit(0);
  }

  if (nextTask) {
    // Output JSON to stdout: decision=block continues the session,
    // reason becomes the next user message to Claude. Exit 0 (not 2).
    const taskType = nextTask.trim().startsWith("/") ? "slash" : "text";
    logEvent("hook", "stop_decision", "info", {
      decision: "inject_task",
      task_type: taskType,
      preview: nextTask.slice(0, 80),
    });
    const output = JSON.stringify({ decision: "block", reason: nextTask });
    writeSync(1, output);
    process.exit(0);
  }

  // Normal stop notification
  logEvent("hook", "stop_decision", "info", { decision: "normal_stop" });
  const duration = getDuration(state);
  const project = state.projectName || "Task";
  const branch = state.gitBranch;

  const parts = [project];
  if (branch) parts.push(branch);
  if (duration) parts.push(duration);

  return {
    title: "Claude Code",
    subtitle: "Task Complete",
    body: parts.join(" • "),
    sound: SOUNDS.success,
  };
}

function handleSessionStartEvent(
  input: HookInput,
  state: NotificationState
): NotificationConfig | null {
  // Update state to track session start and context
  state.sessionStartTime = Date.now();
  state.currentSession = input.session_id;
  state.projectName = extractProjectName(input.cwd);
  state.workspace = detectWorkspace(input.cwd);
  state.gitBranch = extractGitBranch(input.transcript_path);
  state.chatContext = extractChatContext(input.transcript_path);
  saveState(state);

  // No notification for session start (silent tracking)
  // Date injection: Claude Code already injects # currentDate automatically.
  // Research reminder: handled by ~/.claude/rules/research-first.md (always loaded).
  return null;
}

function handleSessionEndEvent(
  input: HookInput,
  state: NotificationState
): NotificationConfig | null {
  const duration = getDuration(state);
  const project = state.projectName || "Session";

  // Reset state
  state.sessionStartTime = undefined;
  state.activeSubagents = [];
  saveState(state);

  return {
    title: "Claude Code",
    subtitle: "Session Ended",
    body: `${project}${duration ? ` • ${duration}` : ""}`,
    sound: SOUNDS.success,
  };
}

// ============================================================================
// Notification Delivery
// ============================================================================

async function sendNotification(config: NotificationConfig): Promise<void> {
  const { title, subtitle, body, sound } = config;

  // Prefer cmux notify when running inside cmux (env var is set by cmux for all child processes)
  const cmuxSocket = process.env.CMUX_SOCKET_PATH;
  const cmuxTab = process.env.CMUX_TAB_ID;
  if (cmuxSocket) {
    try {
      const args = ["notify", "--title", title, "--body", body];
      if (subtitle) args.push("--subtitle", subtitle);
      if (cmuxTab) args.push("--tab", cmuxTab);
      await $`cmux ${args}`.quiet();
      return;
    } catch {
      // Fall through to osascript
    }
  }

  // Fallback: native osascript (terminal-notifier hangs in multiplexer environments)
  const subtitleLine = subtitle ? `subtitle "${escapeAppleScript(subtitle)}"` : "";
  const script = `
    display notification "${escapeAppleScript(body)}" with title "${escapeAppleScript(title)}" ${subtitleLine} sound name "${sound}"
  `.trim();

  try {
    await $`osascript -e ${script}`.quiet();
  } catch (error) {
    console.error("Failed to send notification:", error);
  }
}

function escapeAppleScript(text: string): string {
  return text.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

// ============================================================================
// Main Entry Point
// ============================================================================

async function main() {
  try {
    // Read hook input from stdin
    const input: HookInput = JSON.parse(await Bun.stdin.text());

    cleanupOldLogs();

    logEvent("hook", "received", "info", {
      event: input.hook_event_name,
      session: input.session_id?.slice(0, 8),
      cwd: input.cwd,
      stop_hook_active: input.stop_hook_active ?? false,
    });

    // Load current state
    const state = loadState();

    // Update project name, workspace, and context from current input
    if (input.cwd) {
      const project = extractProjectName(input.cwd);
      if (project) {
        state.projectName = project;
      }
      state.workspace = detectWorkspace(input.cwd);
    }

    if (input.transcript_path) {
      const context = extractChatContext(input.transcript_path);
      if (context) {
        state.chatContext = context;
      }

      const branch = extractGitBranch(input.transcript_path);
      if (branch) {
        state.gitBranch = branch;
      }
    }

    // Track current session ID
    if (input.session_id) {
      state.currentSession = input.session_id;
    }

    // Route to appropriate handler
    let notificationConfig: NotificationConfig | null = null;

    switch (input.hook_event_name) {
      case "Notification":
        notificationConfig = handleNotificationEvent(input, state);
        break;
      case "Stop":
        notificationConfig = await handleStopEvent(input, state);
        break;
      case "SessionStart":
        notificationConfig = handleSessionStartEvent(input, state);
        break;
      case "SessionEnd":
        notificationConfig = handleSessionEndEvent(input, state);
        break;
      // SubagentStop removed - too noisy
    }

    // Send notification if configured
    if (notificationConfig) {
      await sendNotification(notificationConfig);
    }

    // Save updated state
    saveState(state);

    // Exit successfully (allows hook to continue)
    process.exit(0);
  } catch (error) {
    // Log error but don't block Claude (exit 0)
    console.error("Notification hook error:", error);
    process.exit(0);
  }
}

main();

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
import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync, readdirSync, statSync, unlinkSync } from "fs";
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

function handleStopEvent(
  _input: HookInput,
  state: NotificationState
): NotificationConfig | null {
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
        notificationConfig = handleStopEvent(input, state);
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

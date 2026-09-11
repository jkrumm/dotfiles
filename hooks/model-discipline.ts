#!/usr/bin/env bun

/**
 * PreToolUse hook: enforce the model-discipline rule the prose could not.
 *
 * `global.CLAUDE.md` and `output-styles/Direct.md` say workers run on Sonnet,
 * "never `fork` from Fable/Opus", and raising a worker above Sonnet is a
 * judgment call for novel-hard logic. Round 2 of the estate audit (finding 11)
 * probed this from a live Fable orchestrator: `Agent` with no `model` correctly
 * landed on Sonnet (the `CLAUDE_CODE_SUBAGENT_MODEL` pin holds), but `Agent` with
 * `model: "fable"` landed on Fable — the pin is overridable by construction, and
 * nothing enforced the "never" beyond the reader's attention. Two leak shapes
 * exist. This hook closes both:
 *
 *   1. `subagent_type: "fork"` from a Fable/Opus orchestrator — a fork always
 *      inherits the caller's model (the Agent tool's own description says an
 *      explicit `model` override is ignored on a fork), so there is no
 *      legitimate justification to allow here; spawn a named agent instead.
 *   2. an explicit `model: "fable"` (or any alias/id containing "fable") on a
 *      worker — Fable is the interactive-orchestrator model, not a worker
 *      model; the estate has zero documented legitimate use of it as a worker.
 *
 * `model: "opus"` is deliberately NOT blocked here. It is the sanctioned escape
 * valve for novel-hard logic (`implement/SKILL.md`'s Heavy tier — a worker may
 * run on Opus with a one-clause justification at the call site) and the audit
 * itself calls existing Opus worker sites "deliberate second opinion, fine" —
 * hard-blocking it here would break real, already-endorsed workflows. The
 * justification for THAT path stays a one-clause note at the call site
 * (documentation), not a machine-checkable field on the Agent tool.
 *
 * ── Determining the caller's own model ────────────────────────────────────
 *
 * `PreToolUse` input carries no field for "what model is this session on" —
 * confirmed empirically (`claude -p --settings <probe> --allowedTools Agent`,
 * captured stdin: session_id, transcript_path, cwd, prompt_id, permission_mode,
 * effort, hook_event_name, tool_name, tool_input, tool_use_id — no `model`).
 * The transcript JSONL at `transcript_path` does carry it: every assistant
 * message includes `message.model` (e.g. "claude-fable-5-1"). Reading the last
 * assistant turn's model out of that file is the only signal available. If the
 * file is missing, unreadable, or carries no assistant turn yet, this fails
 * OPEN on the fork check (does not block) — the fork ban is a cost/hygiene
 * rule, not a security boundary, and a hook bug must not be able to wedge every
 * `Agent` call in the estate.
 *
 * The `model: "fable"` check needs no orchestrator lookup at all — it is
 * unconditional, so it fails safe regardless of transcript readability.
 *
 * Blocking mechanism verified empirically the same way: a `PreToolUse` hook on
 * `matcher: "Agent"` returning `permissionDecision: "deny"` actually prevents
 * the subagent from spawning (no agent ran, cost was zero) — this is the same
 * mechanism `protect-branches.ts` uses for Bash. A `SubagentStart` hook exists
 * but is observational only (confirmed against the Claude Code hooks
 * reference, code.claude.com/docs/en/hooks) — it cannot deny a spawn, which is
 * why this hook fires on the tool call instead.
 */

interface HookInput {
  tool_name: string;
  tool_input?: { subagent_type?: string; model?: string; [key: string]: unknown };
  transcript_path?: string;
}

function isFableOrOpus(model: string | undefined): boolean {
  if (!model) return false;
  const m = model.toLowerCase();
  return m.includes("fable") || m.includes("opus");
}

function isFable(model: string | undefined): boolean {
  return !!model && model.toLowerCase().includes("fable");
}

function isAssistantModelRecord(obj: unknown): obj is { type: "assistant"; message: { model: string } } {
  if (typeof obj !== "object" || obj === null) return false;
  const rec = obj as { type?: unknown; message?: unknown };
  if (rec.type !== "assistant" || typeof rec.message !== "object" || rec.message === null) return false;
  return typeof (rec.message as { model?: unknown }).model === "string";
}

/**
 * Best-effort read of the calling session's own model from its transcript.
 * Scans from the end — the model rarely changes mid-session, but the last
 * assistant turn is the freshest truth if it ever does.
 */
async function callerModel(transcriptPath: string | undefined): Promise<string | undefined> {
  if (!transcriptPath) return undefined;
  try {
    const text = await Bun.file(transcriptPath).text();
    const lines = text.split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i]?.trim();
      if (!line) continue;
      let obj: unknown;
      try {
        obj = JSON.parse(line);
      } catch {
        continue;
      }
      if (isAssistantModelRecord(obj)) return obj.message.model;
    }
  } catch {
    // transcript unreadable — fails open, see file header
  }
  return undefined;
}

function block(reason: string): never {
  const output = JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  });
  process.stdout.write(output);
  process.exit(0);
}

if (import.meta.main) {
  let input: HookInput;
  try {
    input = JSON.parse(await Bun.stdin.text());
  } catch {
    // Malformed payload — fail open like the rest of this file, not a thrown
    // exception with no permissionDecision on stdout.
    process.exit(0);
  }

  if (input.tool_name !== "Agent") process.exit(0);

  const { subagent_type, model } = input.tool_input ?? {};

  if (isFable(model)) {
    block(
      [
        "A worker on Fable is blocked in Claude Code.",
        "",
        "Fable is the interactive-orchestrator model, not a worker model — this estate",
        "has no legitimate use of it here. Spawn with no model override (Sonnet pin",
        "applies) or model: opus for justified novel-hard logic.",
      ].join("\n")
    );
  }

  if (subagent_type === "fork") {
    const caller = await callerModel(input.transcript_path);
    if (isFableOrOpus(caller)) {
      block(
        [
          `A fork from ${caller} is blocked in Claude Code.`,
          "",
          "A fork always inherits the parent's model — that is architectural, no",
          "override changes it. Spawn a named agent (subagent_type) instead; it runs on",
          "the Sonnet pin with its own cache.",
        ].join("\n")
      );
    }
  }
}

export { callerModel, isFable, isFableOrOpus };

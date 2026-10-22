#!/usr/bin/env bun

/**
 * UserPromptSubmit + PreToolUse(Agent) hook: no Opus or Fable on a metered endpoint.
 *
 * IU-billed Claude Code is for cheap models — DeepSeek V4.1 Flash first, Sonnet as
 * the Claude ceiling. On 2026-10-22 a Max session hand-rolled its own IU runner
 * (Keychain creds → `claude -p --model opus`) and spent ~$31 on 26 Opus jobs that
 * usage-tracker never saw (`--no-session-persistence`). The launchers can't stop
 * that — the runner bypassed them — so the guard lives in every Claude process
 * itself: this hook fires inside the child `claude -p` as well.
 *
 * "Metered" = a non-empty `ANTHROPIC_BASE_URL` that is not api.anthropic.com. `c`
 * blanks it, so a Max session never matches; `ca`, `claude_iu` and any hand-rolled
 * runner all set it.
 *
 * The hook input carries no model field (probed 2026-10-22), so the main model is
 * resolved the way Claude Code does: `--model` on the claude process's own argv
 * (`CLAUDE_PID`) → `ANTHROPIC_MODEL` → `~/.claude/settings.json` `model`. An alias
 * (`opus`, `fable`, `sonnet`, `haiku`) resolves through `ANTHROPIC_DEFAULT_<TIER>_MODEL`
 * when set — which is why `ca`, pinning every tier to its own model, stays usable
 * under `/model opus`. Unresolvable → allowed (the API-key default is not Opus).
 */

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;

interface HookInput {
  hook_event_name?: string;
  tool_name?: string;
  tool_input?: { model?: string; [key: string]: unknown };
}

const TIERS = ["opus", "fable", "sonnet", "haiku"] as const;

function isMetered(env: Env): boolean {
  const base = env.ANTHROPIC_BASE_URL?.trim();
  if (!base) return false;
  try {
    return new URL(base).hostname !== "api.anthropic.com";
  } catch {
    return true;
  }
}

function modelFromArgv(argv: string): string | undefined {
  return argv.match(/(?:^|\s)--model(?:=|\s+)(\S+)/)?.[1];
}

/** Map a tier alias onto its pinned id; anything else passes through. */
function resolveAlias(model: string, env: Env): string {
  const m = model.toLowerCase().replace(/\[1m\]$/, "");
  const tier = TIERS.find((t) => m === t);
  return (tier && env[`ANTHROPIC_DEFAULT_${tier.toUpperCase()}_MODEL`]) || model;
}

function isPremium(model: string | undefined): boolean {
  return !!model && /opus|fable/i.test(model);
}

function processArgv(pid: string | undefined): string {
  if (!pid) return "";
  const r = Bun.spawnSync(["ps", "-o", "args=", "-p", pid]);
  return r.success ? r.stdout.toString().trim() : "";
}

function settingsModel(): string | undefined {
  try {
    const s = JSON.parse(readFileSync(join(homedir(), ".claude", "settings.json"), "utf8"));
    return typeof s.model === "string" ? s.model : undefined;
  } catch {
    return undefined;
  }
}

function mainModel({ env, argv, fromSettings }: { env: Env; argv: string; fromSettings?: string }): string | undefined {
  const raw = modelFromArgv(argv) ?? env.ANTHROPIC_MODEL ?? fromSettings;
  return raw ? resolveAlias(raw, env) : undefined;
}

const POLICY = [
  "Metered (IU) Claude Code runs cheap models only: DeepSeek V4.1 Flash first",
  "(`cdf`, or `ca DeepSeek-V4-Flash`), Sonnet as the Claude ceiling (`ca`, or",
  "`claude_iu --model sonnet`). Opus and Fable belong on the Max subscription (`c`).",
].join("\n");

if (import.meta.main) {
  const env = process.env as Env;
  if (!isMetered(env)) process.exit(0);

  let input: HookInput;
  try {
    input = JSON.parse(await Bun.stdin.text());
  } catch {
    process.exit(0);
  }

  if (input.hook_event_name === "UserPromptSubmit") {
    const model = mainModel({ env, argv: processArgv(env.CLAUDE_PID), fromSettings: settingsModel() });
    if (isPremium(model)) {
      process.stdout.write(
        JSON.stringify({ decision: "block", reason: `${model} on a metered endpoint is blocked.\n\n${POLICY}` })
      );
    }
    process.exit(0);
  }

  if (input.tool_name === "Agent" && input.tool_input?.model) {
    const model = resolveAlias(input.tool_input.model, env);
    if (isPremium(model)) {
      process.stdout.write(
        JSON.stringify({
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: `A ${model} worker on a metered endpoint is blocked.\n\n${POLICY}`,
          },
        })
      );
    }
  }
}

export { isMetered, isPremium, mainModel, modelFromArgv, resolveAlias };

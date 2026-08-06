#!/usr/bin/env bun

/**
 * Machine-role SessionStart hook
 *
 * Injects the headless-secrets backend of THIS machine into the model's context
 * at session start, so the agent knows whether it is on the headless Mac mini
 * (cache backend — a direct `op` call HANGS on the biometric prompt) or a
 * present-human machine (op backend — live biometric `op` works).
 *
 * Contract: a SessionStart hook adds whatever it writes to stdout to Claude's
 * context (plain text, no JSON wrapper). We read the per-machine backend marker
 * `~/.config/secrets/backend` (`cache` | `op`) and emit a short note. It reads
 * only that marker (a two-word role, never a secret) and always exits 0 — a
 * secrets hint must never block a session.
 *
 * See ~/.claude/CLAUDE.md → "Headless secrets — the `secrets-run` shim".
 */

import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { execFileSync } from "child_process";

const BACKEND_MARKER = join(homedir(), ".config", "secrets", "backend");
const HUMAN_QUEUE_SCRIPT = join(
  homedir(),
  "SourceRoot",
  "dotfiles",
  "scripts",
  "human-queue.sh",
);

// How many present-human requests the mini's agents have queued, or 0 on
// anything short of a clean small non-negative integer on stdout. This must
// never throw and never block a session over a queue-depth hint, so every
// failure mode collapses to "0, stay silent" rather than surfacing an error:
// an unreachable mini (asleep, off the tailnet), a slow ssh handshake (capped
// at 2.5s here, well under human-queue.sh's own 8s ConnectTimeout, so a
// SessionStart hook never waits out a full ssh timeout), a missing script
// (an older checkout), or a non-numeric line (a future format change). The
// script itself already fails toward "0, exit 0" for the same reason on its
// own side — this is the same posture applied one layer up.
function pendingHumanQueueCount(): number {
  try {
    if (!existsSync(HUMAN_QUEUE_SCRIPT)) return 0;
    const out = execFileSync("bash", [HUMAN_QUEUE_SCRIPT, "count"], {
      timeout: 2500,
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString()
      .trim();
    return /^\d+$/.test(out) ? parseInt(out, 10) : 0;
  } catch {
    return 0;
  }
}

function contextFor(backend: string): string | null {
  switch (backend) {
    case "cache":
      return [
        "[secrets] Backend: cache — this is the headless Mac mini. `op` is NOT interactively",
        "signed in, so a direct `op read` / `op run` HANGS on the biometric prompt. Resolve",
        "secrets via the `secrets-run` shim (reads the age-encrypted offline cache):",
        "`secrets-run read op://vault/item/field`, `secrets-run run --env-file=<tpl> -- <cmd>`.",
        "`make secrets-seed` is interactive (biometric) — it can't be driven from a",
        "non-interactive tool call; have the user run it with the `!` prefix. Which refs the",
        "mini may hold is `dotfiles-private/headless.refs`. See ~/.claude/CLAUDE.md → \"Headless secrets\".",
        "Outbound access from this machine: `ssh homelab` / `ssh vps` are Tailscale SSH —",
        "keyless, headless-safe, use them freely; GitHub goes over HTTPS via",
        "`~/.gitconfig-headless`, whose credential helper is",
        "`scripts/git-credential-secrets-cache` resolving `op://mini/github/token` from the",
        "same cache (NOT the `gh` keyring token — that path was retired 2026-07-26 because",
        "`gh auth git-credential get` exits 0 with an empty body on expiry). NEVER rely on the",
        "1Password SSH agent here — it hangs like `op` does. Full model:",
        "dotfiles-private/docs/access-model.md.",
      ].join(" ");
    case "op": {
      const lines = [
        "[secrets] Backend: op — present-human machine (e.g. MacBook). `secrets-run` proxies to",
        "live biometric `op`; a direct `op --account <acct>` also works (a Touch ID prompt may",
        "appear). See ~/.claude/CLAUDE.md → \"Headless secrets\".",
      ];
      // Only this backend ever asks — the mini enqueues, this machine is the
      // one with inbound reach to drain it. A zero count (by far the common
      // case) says nothing; a nonzero one is the whole reason to interrupt
      // context with an extra line, so the check only costs a line when it
      // has something to report.
      const pending = pendingHumanQueueCount();
      if (pending > 0) {
        lines.push(
          `[human-queue] ${pending} request(s) from the mini await you — 'make human-queue' to list, 'human-queue.sh run <id>' to act.`,
        );
      }
      return lines.join(" ");
    }
    default:
      return null; // unknown/unset marker — stay silent rather than clutter context
  }
}

async function main() {
  try {
    // Drain stdin (the SessionStart hook payload) so the writer never sees EPIPE.
    // We don't need its fields — the machine role comes from the local marker.
    await Bun.stdin.text().catch(() => "");

    if (existsSync(BACKEND_MARKER)) {
      const backend = readFileSync(BACKEND_MARKER, "utf-8").trim();
      const ctx = contextFor(backend);
      if (ctx) process.stdout.write(ctx + "\n");
    }
  } catch {
    // A secrets hint must never block a session — swallow everything.
  }
  process.exit(0);
}

main();

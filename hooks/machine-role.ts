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

const BACKEND_MARKER = join(homedir(), ".config", "secrets", "backend");

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
    case "op":
      return [
        "[secrets] Backend: op — present-human machine (e.g. MacBook). `secrets-run` proxies to",
        "live biometric `op`; a direct `op --account <acct>` also works (a Touch ID prompt may",
        "appear). See ~/.claude/CLAUDE.md → \"Headless secrets\".",
      ].join(" ");
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

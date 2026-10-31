#!/usr/bin/env bun

/**
 * Claude session -> herdr-core terminal labels, so `scripts/hc-resume.ts` can restore the session.
 *
 * SessionStart: `hc label $HC_TERMINAL_ID jk.claude.session=<id> jk.claude.config=<CLAUDE_CONFIG_DIR>`
 * (`jk.claude.config=` removes the label for the `iu` account, so a reused terminal never keeps the
 * previous account). SessionEnd: `jk.claude.session=` — a session the user quit is never resumed;
 * a lost program fires no SessionEnd, which is the case resume is for.
 *
 * Only inside a core terminal (HC_TERMINAL_ID set): any `hc` call auto-starts a core otherwise.
 * Bounded and never fails the session: exit 0 always, errors to stderr.
 */

const TIMEOUT_MS = 5000

// SessionEnd `reason` values per the Claude Code hooks docs: clear, resume, logout, prompt_input_exit, other.
// Claude also fires SessionEnd on SIGTERM (reboot, logout of the OS), reason `other`: that is the case
// resume exists for, so the label stays. Cleared only for a deliberate exit: `prompt_input_exit` (the user
// quit from the prompt) and `logout` (/logout). `clear` and `resume` start another session whose
// SessionStart relabels the terminal; unknown reasons keep the label.
const DELIBERATE_EXIT = new Set(["prompt_input_exit", "logout"])

/** The `hc label` arguments for a hook event, or null when there is nothing to label. */
export function labelArgs(
  input: { session_id?: string; hook_event_name?: string; reason?: string },
  env: Record<string, string | undefined>
): string[] | null {
  const terminal = env.HC_TERMINAL_ID
  if (!terminal) return null
  if (input.hook_event_name === "SessionEnd") {
    return DELIBERATE_EXIT.has(input.reason ?? "") ? ["label", terminal, "jk.claude.session="] : null
  }
  if (input.hook_event_name !== "SessionStart" || !input.session_id) return null
  return [
    "label", terminal,
    `jk.claude.session=${input.session_id}`,
    `jk.claude.config=${env.CLAUDE_CONFIG_DIR ?? ""}`,
  ]
}

async function main() {
  try {
    const args = labelArgs(JSON.parse(await Bun.stdin.text()), process.env)
    if (!args) return
    const proc = Bun.spawn([process.env.HC_BIN || "hc", ...args], {
      stdin: "ignore", stdout: "ignore", stderr: "pipe", timeout: TIMEOUT_MS,
    })
    const [err, code] = await Promise.all([new Response(proc.stderr).text(), proc.exited])
    if (code !== 0) console.error(`hc-session-label: hc exited ${code}: ${err.trim().slice(0, 300)}`)
  } catch (error) {
    console.error("hc-session-label hook error:", error)
  }
}

if (import.meta.main) {
  await main()
  process.exit(0)
}

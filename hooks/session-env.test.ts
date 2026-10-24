import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"

const HOOK = join(import.meta.dir, "session-env.ts")
let home: string

beforeAll(() => {
  home = mkdtempSync(join(tmpdir(), "session-env-"))
})
afterAll(() => rmSync(home, { recursive: true, force: true }))

function run(env: Record<string, string>) {
  const logs = join(home, ".claude", "logs")
  rmSync(logs, { recursive: true, force: true })
  const base: Record<string, string> = { ...(process.env as Record<string, string>), HOME: home }
  delete base.CLAUDE_CONFIG_DIR
  Bun.spawnSync(["bun", HOOK], {
    env: { ...base, ...env },
    stdin: new TextEncoder().encode(JSON.stringify({ session_id: "s1", hook_event_name: "SessionStart" })),
    stdout: "pipe", stderr: "pipe",
  })
  const file = readdirSync(logs).find((f) => f.endsWith(".jsonl"))!
  return JSON.parse(readFileSync(join(logs, file), "utf8").trim().split("\n").pop()!)
}

describe("session_env account", () => {
  test("CLAUDE_CONFIG_DIR unset -> a", () => {
    expect(run({}).data).toMatchObject({ session: "s1", account: "a" })
  })
  test("an unknown dir falls back to a", () => {
    expect(run({ CLAUDE_CONFIG_DIR: join(homedir(), ".claude-b-unknown") }).data.account).toBe("a")
  })
  test("CLAUDE_CONFIG_DIR at account b's dir -> b", () => {
    expect(run({ CLAUDE_CONFIG_DIR: join(home, ".claude-b") }).data.account).toBe("b")
  })
  test("a broken registry still emits the line, with account null", () => {
    const e = run({ CLAUDE_ACCOUNTS_REGISTRY: join(home, "missing.json") })
    expect(e.event).toBe("session_env")
    expect(e.data.account).toBeNull()
    expect(e.data.session).toBe("s1")
  })
})

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
  delete base.FACTORY_ROLE
  delete base.FACTORY_SESSION
  Bun.spawnSync(["bun", HOOK], {
    env: { ...base, ...env },
    stdin: new TextEncoder().encode(JSON.stringify({ session_id: "s1", hook_event_name: "SessionStart" })),
    stdout: "pipe", stderr: "pipe",
  })
  const file = readdirSync(logs).find((f) => f.endsWith(".jsonl"))!
  return JSON.parse(readFileSync(join(logs, file), "utf8").trim().split("\n").pop()!)
}

describe("session_env account", () => {
  test("CLAUDE_CONFIG_DIR unset -> iu", () => {
    expect(run({}).data).toMatchObject({ session: "s1", account: "iu" })
  })
  test("a set but unregistered dir is account null, not iu", () => {
    expect(run({ CLAUDE_CONFIG_DIR: join(homedir(), ".claude-me-unknown") }).data.account).toBeNull()
  })
  test("CLAUDE_CONFIG_DIR at account me's dir -> me", () => {
    expect(run({ CLAUDE_CONFIG_DIR: join(home, ".claude-me") }).data.account).toBe("me")
  })
  test("a broken registry still emits the line, with account null", () => {
    const e = run({ CLAUDE_ACCOUNTS_REGISTRY: join(home, "missing.json") })
    expect(e.event).toBe("session_env")
    expect(e.data.account).toBeNull()
    expect(e.data.session).toBe("s1")
  })
})

describe("session_env factory fields", () => {
  test("FACTORY_ROLE and FACTORY_SESSION are logged when set", () => {
    const e = run({ FACTORY_ROLE: "lead", FACTORY_SESSION: "spawn-1" })
    expect(e.data.factory_role).toBe("lead")
    expect(e.data.factory_session).toBe("spawn-1")
  })
  test("both are null when unset", () => {
    const e = run({})
    expect(e.data.factory_role).toBeNull()
    expect(e.data.factory_session).toBeNull()
  })
})

import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const HOOK = join(import.meta.dir, "session-env.ts")
let home: string
let bin: string

// A stub `claude-account` stands in for the real CLI (CI has none): `account` prints $STUB_ID, exits $STUB_RC.
beforeAll(() => {
  home = mkdtempSync(join(tmpdir(), "session-env-"))
  bin = join(home, "bin")
  mkdirSync(bin)
  writeFileSync(join(bin, "claude-account"), '#!/bin/sh\n[ "$1" = account ] || exit 2\necho "$STUB_ID"\nexit "${STUB_RC:-0}"\n')
  chmodSync(join(bin, "claude-account"), 0o755)
})
afterAll(() => rmSync(home, { recursive: true, force: true }))

function run(env: Record<string, string>) {
  const logs = join(home, ".claude", "logs")
  rmSync(logs, { recursive: true, force: true })
  const base: Record<string, string> = { ...(process.env as Record<string, string>), HOME: home }
  base.PATH = `${bin}:${base.PATH}`
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
  test("the id claude-account prints is logged", () => {
    expect(run({ STUB_ID: "me" }).data).toMatchObject({ session: "s1", account: "me" })
  })
  test("\"?\" (a dir no account owns) is account null", () => {
    expect(run({ STUB_ID: "?" }).data.account).toBeNull()
  })
  test("a failing claude-account still emits the line, with account null", () => {
    const e = run({ STUB_ID: "iu", STUB_RC: "2" })
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

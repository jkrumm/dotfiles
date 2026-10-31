import { afterAll, beforeAll, expect, test } from "bun:test"
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { labelArgs } from "./hc-session-label"

const HOOK = join(import.meta.dir, "hc-session-label.ts")
let dir: string
let fake: string
let calls: string

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), "hc-label-"))
  calls = join(dir, "calls")
  fake = join(dir, "hc")
  writeFileSync(fake, `#!/bin/sh\necho "$@" >> "${calls}"\n[ -n "$HC_FAIL" ] && { echo boom >&2; exit 2; }\nexit 0\n`)
  chmodSync(fake, 0o755)
})
afterAll(() => rmSync(dir, { recursive: true, force: true }))

function run(event: object, env: Record<string, string>) {
  rmSync(calls, { force: true })
  const base: Record<string, string> = { ...(process.env as Record<string, string>) }
  for (const k of ["HC_TERMINAL_ID", "CLAUDE_CONFIG_DIR", "HC_FAIL"]) delete base[k]
  const r = Bun.spawnSync(["bun", HOOK], {
    env: { ...base, HC_BIN: fake, ...env },
    stdin: new TextEncoder().encode(JSON.stringify(event)),
    stdout: "pipe", stderr: "pipe",
  })
  let log = ""
  try { log = readFileSync(calls, "utf8").trim() } catch {}
  return { code: r.exitCode, log, stderr: r.stderr.toString() }
}

test("SessionStart labels the terminal with session and config", () => {
  const r = run({ session_id: "s1", hook_event_name: "SessionStart" }, { HC_TERMINAL_ID: "t7", CLAUDE_CONFIG_DIR: "/h/.claude-me" })
  expect(r.code).toBe(0)
  expect(r.log).toBe("label t7 jk.claude.session=s1 jk.claude.config=/h/.claude-me")
})

test("iu (CLAUDE_CONFIG_DIR unset) removes the config label", () => {
  const r = run({ session_id: "s1", hook_event_name: "SessionStart" }, { HC_TERMINAL_ID: "t7" })
  expect(r.log).toBe("label t7 jk.claude.session=s1 jk.claude.config=")
})

test("SessionEnd clears the session label only for a deliberate exit", () => {
  for (const reason of ["prompt_input_exit", "logout"]) {
    const r = run({ session_id: "s1", hook_event_name: "SessionEnd", reason }, { HC_TERMINAL_ID: "t7" })
    expect(r.log).toBe("label t7 jk.claude.session=")
  }
})

test("SessionEnd keeps the label for other, clear, resume, unknown or missing reasons (SIGTERM fires `other`)", () => {
  for (const reason of ["other", "clear", "resume", "weird", undefined]) {
    const r = run({ session_id: "s1", hook_event_name: "SessionEnd", reason }, { HC_TERMINAL_ID: "t7" })
    expect(r.code).toBe(0)
    expect(r.log).toBe("")
  }
})

test("no HC_TERMINAL_ID: hc is never called", () => {
  const r = run({ session_id: "s1", hook_event_name: "SessionStart" }, {})
  expect(r.code).toBe(0)
  expect(r.log).toBe("")
})

test("a failing hc or bad stdin still exits 0", () => {
  const r = run({ session_id: "s1", hook_event_name: "SessionStart" }, { HC_TERMINAL_ID: "t7", HC_FAIL: "1" })
  expect(r.code).toBe(0)
  expect(r.stderr).toContain("hc exited 2")
  expect(labelArgs({ hook_event_name: "SessionStart" }, { HC_TERMINAL_ID: "t7" })).toBeNull()
})

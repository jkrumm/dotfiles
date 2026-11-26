// What dotfiles still owns around the factory's accounts package: the owner's registry and the peer snapshot script.
// Both are checked against the live release's own code, so it runs where there is one (the mini).
import { describe, expect, test } from "bun:test"
import { existsSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const PACKAGE = join(homedir(), ".software-factory", "current", "packages", "accounts", "src", "index.ts")
const live = existsSync(PACKAGE)
const snapshot = () => readFileSync(join(import.meta.dir, "claude-account-snapshot.sh"), "utf8")

describe("claude-account-snapshot.sh", () => {
  test("exports PATH so `#!/usr/bin/env bun` resolves", () => {
    expect(snapshot()).toContain('export PATH="$HOME/.local/bin:/opt/homebrew/bin:$HOME/.bun/bin:$PATH"')
  })
  test.skipIf(!live)("its command text is the package's PEER_SCRIPT (the ssh and core reads must agree)", async () => {
    const { HOME_BIN, PEER_SCRIPT } = await import(PACKAGE)
    const sh = snapshot()
    const own = '"$HOME/.local/bin/claude-account"'
    expect(sh.slice(sh.indexOf(own)).trim().replaceAll(own, HOME_BIN)).toBe(PEER_SCRIPT)
  })
})

describe("config/claude-accounts.json", () => {
  test.skipIf(!live)("the package loads it, with the default account and real plans", async () => {
    const { loadRegistry } = await import(PACKAGE)
    const reg = loadRegistry(join(import.meta.dir, "..", "config", "claude-accounts.json"))
    const accounts = Object.values(reg.accounts) as { dir: string | null; plan: string }[]
    expect(accounts.every((a) => ["max", "ultra"].includes(a.plan))).toBe(true)
    expect(reg.accounts.iu.dir).toBeNull()
  })
})

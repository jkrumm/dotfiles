// shared-chrome: the idle decision as pure cases, then the supervisor end to end against a fake DevTools
// endpoint (scripts/lib/shared-chrome-fake.ts) standing in for Chrome.
import { afterAll, describe, expect, test } from "bun:test"
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { plan, unitsOf, type PlanState, type TargetInfo } from "./shared-chrome"

const cfg = { idleMs: 1000, graceMs: 500 }
const page = (id: string, ctx: string, url = "https://a.test/", title = ""): TargetInfo => ({
  targetId: id,
  type: "page",
  url,
  title,
  browserContextId: ctx,
})

describe("unitsOf", () => {
  test("Chrome's own blank tab in the default context is nobody's session", () => {
    expect(unitsOf([page("p0", "def", "about:blank")], [], "def")).toEqual([])
  })
  test("an isolated context counts even with no page, a default page counts when it is not blank", () => {
    const u = unitsOf([page("p1", "def", "https://x.test/")], ["iso"], "def")
    expect(u.map((x) => [x.id, x.isDefault])).toEqual([
      ["iso", false],
      ["def", true],
    ])
  })
})

describe("plan", () => {
  const empty: PlanState = { units: {}, emptySince: 0 }
  const unit = (fp: string) => ({ id: "c1", isDefault: false, fp, targetIds: ["p"] })

  test("a context that changes stays; one that does not is disposed after idleMs", () => {
    let s = plan(empty, [unit("a")], 0, cfg).state
    expect(plan(s, [unit("b")], 900, cfg).disposeContexts).toEqual([])
    s = plan(s, [unit("b")], 900, cfg).state
    expect(plan(s, [unit("b")], 1899, cfg).disposeContexts).toEqual([])
    expect(plan(s, [unit("b")], 1900, cfg).disposeContexts).toEqual(["c1"])
  })
  test("stop only after graceMs without any context, counted from the last one", () => {
    const s = plan(empty, [unit("a")], 100, cfg).state
    const gone = plan(s, [], 200, cfg)
    expect(gone.stop).toBe(false)
    expect(plan(gone.state, [], 599, cfg).stop).toBe(false)
    expect(plan(gone.state, [], 600, cfg).stop).toBe(true)
  })
  test("closing the last idle context starts the grace clock", () => {
    const s = plan(empty, [unit("a")], 0, cfg).state
    const p = plan(s, [unit("a")], 1000, cfg)
    expect(p.disposeContexts).toEqual(["c1"])
    expect(p.stop).toBe(false)
    expect(plan(p.state, [], 1000 + 499, cfg).stop).toBe(false)
    expect(plan(p.state, [], 1000 + 500, cfg).stop).toBe(true)
  })
  test("a lease from ensure holds Chrome open for graceMs even with no context", () => {
    const s = plan(empty, [], 10_000, cfg, 9_800)
    expect(s.stop).toBe(false)
    expect(plan(s.state, [], 10_299, cfg, 9_800).stop).toBe(false)
    expect(plan(s.state, [], 10_300, cfg, 9_800).stop).toBe(true)
  })
  test("a default-context page is closed by target, never by disposing the default context", () => {
    const d = { id: "def", isDefault: true, fp: "x", targetIds: ["p9"] }
    const s = plan(empty, [d], 0, cfg).state
    const p = plan(s, [d], 1000, cfg)
    expect(p.closeTargets).toEqual(["p9"])
    expect(p.disposeContexts).toEqual([])
  })
})

describe("supervisor against a fake Chrome", () => {
  const dir = mkdtempSync(join(tmpdir(), "shared-chrome-"))
  const port = 20000 + Math.floor(Math.random() * 20000)
  const fakeBin = join(dir, "fake-chrome")
  writeFileSync(fakeBin, `#!/bin/sh\nexec ${process.execPath} ${join(import.meta.dir, "lib/shared-chrome-fake.ts")} "$@"\n`)
  chmodSync(fakeBin, 0o755)
  const env = {
    ...process.env,
    SHARED_CHROME_PORT: String(port),
    SHARED_CHROME_BIN: fakeBin,
    SHARED_CHROME_PROFILE: join(dir, "profile"),
    SHARED_CHROME_STATE: join(dir, "state"),
    SHARED_CHROME_LOG: join(dir, "shared-chrome.log"),
    SHARED_CHROME_LABEL: `com.jkrumm.shared-chrome-test-${process.pid}`, // not loaded: ensure falls back to a detached run
    SHARED_CHROME_IDLE_MS: "1500",
    SHARED_CHROME_GRACE_MS: "800",
    SHARED_CHROME_POLL_MS: "250",
  }
  const cli = (verb: string) => Bun.spawnSync([process.execPath, join(import.meta.dir, "shared-chrome.ts"), verb], { env })
  const base = `http://127.0.0.1:${port}`
  const post = (path: string, body: object) => fetch(`${base}${path}`, { method: "POST", body: JSON.stringify(body) })
  const state = async () => (await (await fetch(`${base}/_fake/state`)).json()) as { contexts: string[]; pages: { targetId: string }[] }
  const up = async () => fetch(`${base}/json/version`).then((r) => r.ok, () => false)
  const until = async (cond: () => Promise<boolean>, ms: number) => {
    for (const end = Date.now() + ms; Date.now() < end; ) {
      if (await cond()) return true
      await Bun.sleep(100)
    }
    return false
  }
  afterAll(() => {
    cli("stop")
    rmSync(dir, { recursive: true, force: true })
  })

  test("ensure starts it and prints the URL; a second ensure changes nothing", async () => {
    const r = cli("ensure")
    expect(r.stdout.toString().trim()).toBe(base)
    expect(await up()).toBe(true)
    expect(cli("ensure").stdout.toString().trim()).toBe(base)
  })

  test("an idle context is closed, an active one stays, and Chrome stops when none is left", async () => {
    await post("/_fake/context", { id: "idle" })
    await post("/_fake/page", { id: "pi", context: "idle" })
    await post("/_fake/context", { id: "busy" })
    await post("/_fake/page", { id: "pb", context: "busy" })

    // keep "busy" changing for longer than the idle window
    const end = Date.now() + 3000
    let n = 0
    while (Date.now() < end) {
      await post("/_fake/title", { id: "pb", title: `t${n++}` })
      await Bun.sleep(300)
    }
    const s = await state()
    expect(s.contexts).toEqual(["busy"])
    expect(s.pages.map((p) => p.targetId).sort()).toEqual(["p0", "pb"])

    expect(await until(async () => !(await up()), 8000)).toBe(true)
  }, 20_000)

  test("after Chrome is gone the next ensure starts it again", async () => {
    expect(await up()).toBe(false)
    expect(cli("ensure").stdout.toString().trim()).toBe(base)
    expect(await up()).toBe(true)
    expect(cli("stop").stdout.toString().trim()).toBe("stopped")
    expect(await up()).toBe(false)
  }, 20_000)
})

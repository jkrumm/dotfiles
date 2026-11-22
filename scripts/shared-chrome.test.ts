// shared-chrome: the idle decision as pure cases, then the supervisor end to end against a fake DevTools
// endpoint (scripts/lib/shared-chrome-fake.ts) standing in for Chrome.
import { afterAll, describe, expect, test } from "bun:test"
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { CONFIG, DISPATCHED, HELP, VERB_HELP, daemonOf, plan, unitsOf, type PlanState, type TargetInfo } from "./shared-chrome"

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

describe("help", () => {
  test("every verb the dispatch accepts is in the help text, and the help lists no other", () => {
    for (const v of DISPATCHED) expect(HELP, `verb '${v}' missing from HELP`).toContain(`shared-chrome ${v}`)
    expect(VERB_HELP.map((v) => v.name).sort()).toEqual([...DISPATCHED].sort())
  })
  test("the supervisor verb sits under 'not for agents' with its caller", () => {
    const [agents, jobs] = HELP.split("Not for agents:")
    expect(agents).not.toContain("shared-chrome run")
    expect(jobs).toContain("shared-chrome run")
    expect(jobs).toContain("com.jkrumm.shared-chrome")
  })
  test("`<verb> --help`, --help, -h, help and a bare call print it, exit 0, and start nothing", async () => {
    const dir = mkdtempSync(join(tmpdir(), "shared-chrome-help-"))
    const port = 20000 + Math.floor(Math.random() * 20000)
    const env = { ...process.env, SHARED_CHROME_PORT: String(port), SHARED_CHROME_BIN: join(dir, "no-chrome"), SHARED_CHROME_PROFILE: join(dir, "profile"), SHARED_CHROME_STATE: join(dir, "state"), SHARED_CHROME_LOG: join(dir, "log"), SHARED_CHROME_LABEL: `com.jkrumm.shared-chrome-help-${process.pid}` }
    const run = (...args: string[]) => Bun.spawnSync([process.execPath, join(import.meta.dir, "shared-chrome.ts"), ...args], { env })
    for (const args of [["ensure", "--help"], ["stop", "-h"], ["status", "--help"], ["run", "--help"], ["--help"], ["-h"], ["help"], []]) {
      const r = run(...args)
      expect(r.exitCode, args.join(" ")).toBe(0)
      expect(r.stdout.toString(), args.join(" ")).toBe(HELP)
    }
    // `ensure` writes its lease first and would spawn the supervisor and the log: none of it may exist
    expect(existsSync(join(dir, "state"))).toBe(false)
    expect(existsSync(join(dir, "log"))).toBe(false)
    expect(await fetch(`http://127.0.0.1:${port}/json/version`).then((r) => r.ok, () => false)).toBe(false)
    expect(run("frobnicate").exitCode).toBe(2)
    expect(run("frobnicate", "--help").exitCode).toBe(2) // help is for a verb that exists
    rmSync(dir, { recursive: true, force: true })
  })
})

describe("start limits", () => {
  test("ensure waits less than the supervisor does, so it never hands out a Chrome about to be killed", () => {
    expect(CONFIG.ensureMs).toBeLessThan(CONFIG.startMs)
  })
})

describe("daemonOf", () => {
  const url = "http://127.0.0.1:9223"
  const running = (args: string) => `chrome-devtools-mcp daemon is running.\npid=4242 socket=/tmp/x start-date=2026-11-16T08:47:11.447Z version=1.13.0\nargs=${args}\n`
  test("no daemon", () => {
    expect(daemonOf("chrome-devtools-mcp daemon is not running.\n", url)).toEqual({ kind: "none" })
  })
  test("a daemon whose arguments name this Chrome is ours", () => {
    expect(daemonOf(running(`["--viaCli","--browser-url=${url}"]`), url)).toEqual({ kind: "ours", pid: 4242, startedAt: Date.parse("2026-11-16T08:47:11.447Z") })
  })
  test("a daemon attached elsewhere is foreign, whatever else it says", () => {
    expect(daemonOf(running(`["--viaCli","--auto-connect"]`), url).kind).toBe("foreign")
    expect(daemonOf(running(`["--viaCli","--browser-url=http://127.0.0.1:9222"]`), url).kind).toBe("foreign")
    expect(daemonOf(running("not json"), url).kind).toBe("foreign")
  })
})

describe("supervisor against a fake Chrome", () => {
  const dir = mkdtempSync(join(tmpdir(), "shared-chrome-"))
  const port = 20000 + Math.floor(Math.random() * 20000)
  const fakeBin = join(dir, "fake-chrome")
  writeFileSync(fakeBin, `#!/bin/sh\nexec ${process.execPath} ${join(import.meta.dir, "lib/shared-chrome-fake.ts")} "$@"\n`)
  chmodSync(fakeBin, 0o755)
  // A stand-in for the chrome-devtools CLI: one daemon per "user", its state in a file.
  const daemonFile = join(dir, "daemon")
  const fakeCdt = join(dir, "chrome-devtools")
  writeFileSync(
    fakeCdt,
    `#!/bin/sh
S="$FAKE_DEVTOOLS_STATE"
case "$1" in
status) if [ -f "$S" ]; then echo "chrome-devtools-mcp daemon is running."; cat "$S"; else echo "chrome-devtools-mcp daemon is not running."; fi ;;
start) shift; args='"--viaCli"'; for a in "$@"; do a=$(printf %s "$a" | sed 's/^--browserUrl=/--browser-url=/'); args="$args,\\"$a\\""; done
  printf 'pid=%s socket=/tmp/fake start-date=%s version=1\nargs=[%s]\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$args" > "$S" ;;
stop) rm -f "$S" ;;
list_pages) [ -f "$S" ] && [ ! -f "$S.dead" ] && { [ ! -f "$S.busy" ] || sleep 3; } ;;
esac
`,
  )
  chmodSync(fakeCdt, 0o755)
  const env = {
    ...process.env,
    SHARED_CHROME_PORT: String(port),
    SHARED_CHROME_BIN: fakeBin,
    SHARED_CHROME_PROFILE: join(dir, "profile"),
    SHARED_CHROME_STATE: join(dir, "state"),
    SHARED_CHROME_LOG: join(dir, "shared-chrome.log"),
    SHARED_CHROME_LABEL: `com.jkrumm.shared-chrome-test-${process.pid}`, // not loaded: ensure falls back to a detached run
    SHARED_CHROME_IDLE_MS: "1500",
    SHARED_CHROME_GRACE_MS: "2500", // longer than the 800 ms probe: a devtools call must not outlast the lease it took
    SHARED_CHROME_POLL_MS: "250",
    SHARED_CHROME_DEVTOOLS_BIN: fakeCdt,
    SHARED_CHROME_PROBE_MS: "800",
    FAKE_DEVTOOLS_STATE: daemonFile,
  }
  const cli = (verb: string, extra: Record<string, string> = {}) =>
    Bun.spawnSync([process.execPath, join(import.meta.dir, "shared-chrome.ts"), verb], { env: { ...env, ...extra } })
  const daemonText = () => (existsSync(daemonFile) ? readFileSync(daemonFile, "utf8") : null)
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

  test("devtools starts the daemon on the shared Chrome when none runs, and leaves a running one alone", () => {
    const r = cli("devtools")
    expect(r.exitCode).toBe(0)
    const first = daemonText()
    expect(first).toContain(`--browser-url=${base}`)
    expect(first).toContain("--usageStatistics=false")
    expect(cli("devtools").exitCode).toBe(0)
    expect(daemonText()).toBe(first) // same pid, not restarted
    expect(cli("status").stdout.toString()).toMatch(/devtools: +daemon pid \d+ on the shared Chrome/)
  })

  test("a daemon that answers late is busy, not dead: it is not restarted", () => {
    const before = daemonText()
    writeFileSync(`${daemonFile}.busy`, "")
    expect(cli("devtools").exitCode).toBe(0)
    expect(daemonText()).toBe(before)
    rmSync(`${daemonFile}.busy`)
  })

  test("a daemon started before this Chrome is stale and replaced, even when it only hangs", () => {
    const before = daemonText()!
    writeFileSync(daemonFile, before.replace(/start-date=\S+/, "start-date=2001-01-01T00:00:00Z"))
    writeFileSync(`${daemonFile}.busy`, "") // its probe would hang: only the start time can tell
    const r = cli("devtools")
    expect(r.stderr.toString()).toBe("")
    expect(r.exitCode).toBe(0)
    expect(daemonText()).not.toContain("2001-01-01")
    rmSync(`${daemonFile}.busy`)
  })

  test("a daemon of ours that fails to answer is replaced", () => {
    const before = daemonText()
    writeFileSync(`${daemonFile}.dead`, "")
    expect(cli("devtools").exitCode).toBe(0) // stop + start: the fake's start writes a new pid
    expect(daemonText()).not.toBe(before)
    expect(daemonText()).toContain(`--browser-url=${base}`)
    rmSync(`${daemonFile}.dead`)
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

    expect(await until(async () => !(await up()), 14_000)).toBe(true)
    expect(await until(async () => daemonText() === null, 3000)).toBe(true) // the daemon went with Chrome
  }, 30_000)

  test("after Chrome is gone the next ensure starts it again", async () => {
    expect(await up()).toBe(false)
    expect(cli("ensure").stdout.toString().trim()).toBe(base)
    expect(await up()).toBe(true)
    expect(cli("devtools").exitCode).toBe(0)
    expect(daemonText()).not.toBeNull()
    expect(cli("stop").stdout.toString().trim()).toBe("stopped")
    expect(await up()).toBe(false)
    expect(await until(async () => daemonText() === null, 3000)).toBe(true) // `stop` ends the daemon too
  }, 20_000)

  test("a CLI that cannot run is unknown, not 'no daemon': devtools fails naming it, status says unreadable", () => {
    const broken = { SHARED_CHROME_DEVTOOLS_BIN: join(dir, "no-such-cli") }
    const r = cli("devtools", broken)
    expect(r.exitCode).toBe(1)
    expect(r.stderr.toString()).toContain("status failed")
    expect(cli("status", broken).stdout.toString()).toMatch(/devtools: +unreadable/)
  })

  const logText = () => (existsSync(env.SHARED_CHROME_LOG) ? readFileSync(env.SHARED_CHROME_LOG, "utf8") : "")

  test("a Chrome that answers later than the supervisor waits is given up on: it logs it, ensure exits 1", async () => {
    // answers after 3 s, the supervisor waits 2 s, ensure 1 s (the floor)
    cli("stop")
    expect(await until(async () => !(await up()), 5000)).toBe(true)
    const slow = { FAKE_CHROME_DELAY_MS: "3000", SHARED_CHROME_START_MS: "2000", SHARED_CHROME_ENSURE_MS: "1500" }
    const r = cli("ensure", slow)
    expect(r.exitCode).toBe(1)
    expect(r.stdout.toString()).toBe("")
    expect(r.stderr.toString()).toContain("did not come up in 1 s")
    expect(r.stderr.toString()).toContain("keeps waiting up to 2 s")
    expect(await until(async () => logText().includes("never answered on its DevTools port in 2 s"), 5000)).toBe(true)
    expect(await up()).toBe(false)
  }, 20_000)

  test("a slow Chrome inside both limits is waited for: ensure exits 0 and Chrome stays up", async () => {
    // answers after 2 s; the supervisor waits 6 s, ensure 4.5 s
    const slow = { FAKE_CHROME_DELAY_MS: "2000", SHARED_CHROME_START_MS: "6000", SHARED_CHROME_ENSURE_MS: "4500" }
    const r = cli("ensure", slow)
    expect(r.exitCode).toBe(0)
    expect(r.stdout.toString().trim()).toBe(base)
    expect(await up()).toBe(true)
    expect(cli("status", slow).exitCode).toBe(0)
    expect(logText()).not.toContain("answered after") // 2 s is under the 5 s a start must exceed to be logged
    expect(cli("stop").stdout.toString().trim()).toBe("stopped")
    expect(await up()).toBe(false)
  }, 20_000)

  test("a daemon attached elsewhere is refused and never stopped", async () => {
    const foreign = `pid=777 socket=/tmp/fake start-date=now version=1\nargs=["--viaCli","--auto-connect"]\n`
    writeFileSync(daemonFile, foreign)
    const r = cli("devtools")
    expect(r.exitCode).toBe(1)
    const err = r.stderr.toString()
    expect(err).toContain("pid 777")
    expect(err).toContain("attached elsewhere")
    expect(daemonText()).toBe(foreign)
    expect(cli("status").stdout.toString()).toMatch(/devtools: +daemon pid 777 attached elsewhere/)
    expect(cli("stop").stdout.toString().trim()).toBe("stopped")
    expect(await up()).toBe(false)
    expect(daemonText()).toBe(foreign) // Chrome stopped, the foreign daemon did not
  }, 20_000)
})

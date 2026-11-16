import { describe, expect, test } from "bun:test"
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { extract, parseTable, run, subCommands } from "./cli-refs.ts"

const SCRIPT = join(import.meta.dir, "cli-refs.ts")

// Fake CLIs with the help shapes of the real ones: agw (one flat command per line), factory (path, 2-space gap, description;
// per-verb help), hc (alternations, a Commands: section in a group's help), playwright-cli (a flag before the verb).
const FAKES: Record<string, string> = {
  agw: `echo 'agw <command> [args] [--help]    agw schema [command…] [--exit-codes]'
echo '  agw web read <url> [--ask <string>] [--format json|plain]'
echo '  agw llm summarize [text] [--max-words <integer>] [--format json|plain]'`,
  factory: `case "$*" in
  "issue new --help") echo 'usage: factory issue new [flags]'; echo '  --repo <text>  required'; echo '  --title <text>' ;;
  *--help*) echo 'usage: factory [--format json|plain] <command>'; echo; echo 'commands:'
    echo '  version                  the CLI version'
    echo '  session note <session> <text>   a note typed to a lead'
    echo '  issue new                the owner files an Issue'
    echo '  issue show <id>          one Issue'
    echo '  merge-lock --project <name> -- <cmd>   run <cmd> holding the lock'
    echo '  hook <event>             the Claude Code hook' ;;
esac`,
  hc: `case "$*" in
  "file --help") echo 'Usage: hc file [OPTIONS] <COMMAND>'; echo; echo 'Commands:'; echo '  read   Print a file'; echo '  write  Write a file'; echo; echo 'Options:'; echo '      --json  JSON output' ;;
  "file read --help") echo 'Usage: hc file read [OPTIONS] <PATH>'; echo '      --on <M>  the machine' ;;
  "run --help") echo 'Usage: hc run [OPTIONS] [ARGV]...'; echo '      --keep  replace lost programs' ;;
  *--help*) echo 'hc - run programs'; echo; echo 'Usage: hc <command>'; echo
    echo '  run <cmd|template> [task]   run it and wait'
    echo '  file read|write [--on m] <path>   a file here or there'
    echo '                              continuation prose at a deep indent' ;;
esac`,
  "playwright-cli": `echo 'playwright-cli <command> [args] [options]'; echo
echo '  attach [name]               attach to a running browser'
echo '  goto <url>                  navigate'
echo 'Global options:'; echo '  --json                      output response as JSON'`,
}

function bin(names: string[] = Object.keys(FAKES)): string {
  const dir = mkdtempSync(join(tmpdir(), "cli-refs-bin-"))
  for (const name of names) {
    const path = join(dir, name)
    writeFileSync(path, `#!/bin/sh\n${FAKES[name]}\n`)
    chmodSync(path, 0o755)
  }
  return `${dir}:/usr/bin:/bin`
}

function repo(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), "cli-refs-"))
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(join(root, path, ".."), { recursive: true })
    writeFileSync(join(root, path), text)
  }
  return root
}

const scan = (files: Record<string, string>, PATH = bin()) => run(["--root", repo(files)], { env: { PATH } })

describe("findings", () => {
  test("a verb the CLI does not have and a flag the verb does not have fail, as file:line with the quoted text", async () => {
    const r = await scan({ "docs/a.md": "# t\n\nRun `factory fleet` first.\n\n`agw web read --no-such-flag <url>`\n" })
    expect(r.code).toBe(1)
    expect(r.err).toContain("docs/a.md:3: no such command: factory fleet  | factory fleet")
    expect(r.err).toContain("docs/a.md:5: no such flag: agw web read --no-such-flag  | agw web read --no-such-flag <url>")
  })

  test("valid commands, flags and positional arguments pass", async () => {
    const r = await scan({
      "docs/a.md": [
        "`agw web read https://x.test --ask q --format plain`",
        "`factory issue show 12` and `factory --format plain session note lead text` and `factory issue new --repo r`",
        "`agw schema --exit-codes` · `agw llm summarize --no-max-words`",
        "`agw` alone names a CLI and quotes no command",
      ].join("\n"),
    })
    expect(r.err).toBe("")
    expect(r.code).toBe(0)
  })

  test("a group that needs a sub-verb flags a sub-verb it does not have (factory session wait)", async () => {
    const r = await scan({ "AGENTS.md": "`factory session wait --on workers`\n" })
    expect(r.code).toBe(1)
    expect(r.err).toContain("AGENTS.md:1: no such command: factory session wait")
  })

  test("a flag before the verb is skipped, its value too when the table says it takes one", async () => {
    const ok = await scan({
      "docs/a.md": "`playwright-cli -s=$S attach --json`\n`factory --format plain issue show 3`\n`factory issue show --nope`\n",
    })
    expect(ok.err).toContain("docs/a.md:3: no such flag: factory issue show --nope")
    expect(ok.err.split("\n").filter((l) => l.startsWith("docs/"))).toHaveLength(1)
    const bad = await scan({ "docs/a.md": "`playwright-cli -s=$S nonesuch`\n" })
    expect(bad.err).toContain("no such command: playwright-cli nonesuch")
  })

  test("a piped command is checked on each CLI's own words, never on the other program's flags", async () => {
    const r = await scan({
      "docs/a.md": [
        "`agw web read <url> | jq --raw-output .x`",
        "`echo hi | agw web read --bogus`",
        "`agw llm summarize && factory fleet`",
        "`agw web read <url> 2>&1 > out.txt`",
        "`factory merge-lock --project x -- sh -c 'agw --whatever'`",
      ].join("\n"),
    })
    const lines = r.err.split("\n").filter((l) => l.startsWith("docs/"))
    expect(lines).toHaveLength(2)
    expect(lines[0]).toContain("docs/a.md:2: no such flag: agw web read --bogus")
    expect(lines[1]).toContain("docs/a.md:3: no such command: factory fleet")
  })

  test("a fenced shell block is read, a continued command is one command at its first line, other fences are not", async () => {
    const text = [
      "```bash",
      "# agw web read --in-a-comment",
      "agw web read <url> \\",
      "  --no-such-flag",
      "$ FOO=1 factory fleet   # trailing comment --ignored",
      "```",
      "```json",
      '{"cmd": "agw nonsense"}',
      "agw nonsense",
      "```",
    ].join("\n")
    const r = await scan({ "skills/x/SKILL.md": text })
    const lines = r.err.split("\n").filter((l) => l.startsWith("skills/"))
    expect(lines).toHaveLength(2)
    expect(lines[0]).toContain("SKILL.md:3: no such flag: agw web read --no-such-flag")
    expect(lines[1]).toContain("SKILL.md:5: no such command: factory fleet")
  })

  test("the ignore marker silences its line, the line below, and a whole fence it sits above", async () => {
    const text = [
      "`factory fleet` <!-- cli-refs: ignore -->",
      "<!-- cli-refs: ignore -->",
      "`factory status`",
      "`factory status` is not silenced",
      "<!-- cli-refs: ignore -->",
      "```sh",
      "factory fleet",
      "agw nonsense",
      "```",
    ].join("\n")
    const r = await scan({ "docs/a.md": text })
    const lines = r.err.split("\n").filter((l) => l.startsWith("docs/"))
    expect(lines).toHaveLength(1)
    expect(lines[0]).toContain("docs/a.md:4: no such command: factory status")
  })

  test("a group's own help lists its sub-verbs: `hc file read|write` passes, `hc file chmod` and an unknown alternative fail", async () => {
    const ok = await scan({ "docs/a.md": "`hc file read|write --on mini <path>`\n`hc run --keep reviewer \"task\"`\n" })
    expect(ok.err).toBe("")
    const bad = await scan({ "docs/a.md": "`hc file chmod x`\n`hc file read|nope`\n`hc run --nope`\n" })
    expect(bad.err).toContain("docs/a.md:1: no such command: hc file chmod")
    expect(bad.err).toContain("docs/a.md:2: no such command: hc file nope")
    expect(bad.err).toContain("docs/a.md:3: no such flag: hc run --nope")
  })

  test("a verb in noHelp is never asked: its flags come from the top help", async () => {
    const r = await scan({ "docs/a.md": "`factory hook SessionStart`\n" })
    expect(r.err).toBe("")
  })
})

describe("not installed", () => {
  test("a CLI that is not on PATH is skipped with one line and no failure", async () => {
    const r = await scan({ "docs/a.md": "`factory fleet` and `playwright-cli nonesuch`\n`agw web read --nope`\n" }, bin(["agw"]))
    expect(r.err).toContain("cli-refs: factory: not installed, skipped")
    expect(r.err).toContain("cli-refs: playwright-cli: not installed, skipped")
    expect(r.err).toContain("agw web read --nope")
    expect(r.err.match(/factory: not installed/g)).toHaveLength(1)
    const none = await scan({ "docs/a.md": "`factory fleet`\n" }, "/usr/bin:/bin")
    expect(none.code).toBe(0)
    expect(none.err).toBe("cli-refs: factory: not installed, skipped\n")
  })
})

describe("files and output", () => {
  test("docs/archive and worktrees are not scanned; nested AGENTS.md, skills and rules are", async () => {
    const r = await scan({
      "docs/archive/old.md": "`factory fleet`\n",
      "docs/waves/archive/old.md": "`factory fleet`\n",
      ".claude/worktrees/x/AGENTS.md": "`factory fleet`\n",
      "apps/web/AGENTS.md": "`factory a`\n",
      ".claude/skills/s/SKILL.md": "`factory b`\n",
      "rules/r.md": "`factory c`\n",
      "agents/a.md": "`factory d`\n",
      "config/global.CLAUDE.md": "`factory e`\n",
    })
    const files = r.err.split("\n").filter((l) => l.includes("no such command")).map((l) => l.split(":")[0])
    expect(files.sort()).toEqual(["agents/a.md", ".claude/skills/s/SKILL.md", "apps/web/AGENTS.md", "config/global.CLAUDE.md", "rules/r.md"].sort())
  })

  test("--json prints the findings, the skipped CLIs and the counts on stdout", async () => {
    const root = repo({ "docs/a.md": "`factory fleet`\n`playwright-cli goto`\n" })
    const r = await run(["--root", root, "--json"], { env: { PATH: bin(["factory"]) } })
    const body = JSON.parse(r.out)
    expect(r.code).toBe(1)
    expect(body.findings).toEqual([
      { file: "docs/a.md", line: 1, kind: "unknown-command", cli: "factory", what: "factory fleet", text: "factory fleet" },
    ])
    expect(body.skipped).toEqual(["playwright-cli: not installed, skipped"])
    expect(body.files).toBe(1)
  })

  test("the CLI process exits 1 on a finding, 0 clean, 2 on a bad argument", async () => {
    const root = repo({ "docs/a.md": "`factory fleet`\n" })
    const env = { PATH: bin(), HOME: process.env.HOME }
    const spawn = (args: string[]) => Bun.spawnSync([process.execPath, SCRIPT, ...args], { env, stderr: "pipe", stdout: "pipe" })
    const bad = spawn(["--root", root])
    expect(bad.exitCode).toBe(1)
    expect(bad.stderr.toString()).toContain("docs/a.md:1: no such command: factory fleet")
    expect(spawn(["--root", repo({ "docs/a.md": "`factory version`\n" })]).exitCode).toBe(0)
    expect(spawn(["--bogus"]).exitCode).toBe(2)
    expect(spawn(["--root", "/no/such/dir"]).exitCode).toBe(2)
  })
})

describe("parsers", () => {
  test("extract: spans and fences, env and `$ ` prefixes, $(…) inside a command", () => {
    const q = extract("f.md", "`agw a` and `$ sudo hc b`\n```\nx=1 rd c | factory d\necho $(claude-account e)\n```\n")
    expect(q.map((x) => `${x.line}:${x.cli}:${x.rest}`)).toEqual(["1:agw:a", "1:hc:b", "3:rd:c", "3:factory:d", "4:claude-account:e"])
  })

  test("parseTable: paths from lines at indent ≤ 4, alternatives expanded, continuation lines and prose left out", () => {
    const t = parseTable("hc", "Usage: hc <command>\n  run <cmd>   run it\n  file read|write <p>   a file\n                    deep prose here\n  Some Prose\n")
    expect([...t.paths].sort()).toEqual(["file read", "file write", "run"])
  })

  test("subCommands: only the words of a Commands: section", () => {
    expect([...subCommands("x\n\nCommands:\n  read   Print\n  write  Write\n\nOptions:\n  --json  x\n")]).toEqual(["read", "write"])
    expect(subCommands("no section here\n  read  Print\n").size).toBe(0)
  })
})

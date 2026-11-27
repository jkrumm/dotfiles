import { describe, expect, test } from "bun:test"
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { CLIS, extract, injections, parseRuleRows, parseTable, run, subCommands } from "./cli-refs.ts"

const SCRIPT = join(import.meta.dir, "cli-refs.ts")

// Fake CLIs with the help shapes of the real ones: agw (one flat command per line), factory (path, 2-space gap, description;
// per-verb help), hc (alternations, a Commands: section in a group's help), playwright-cli (a flag before the verb).
const FAKES: Record<string, string> = {
  agw: `echo 'agw <command> [args] [--help]    agw schema [command…] [--exit-codes]'
echo '  agw web read <url> [--ask <string>] [--format json|plain]'
echo '  agw llm summarize [text] [--max-words <integer>] [--format json|plain]'`,
  factory: `case "$*" in
  "issue new --help") echo 'usage: factory issue new [flags]'; echo '  --repo <text>  required'; echo '  --title <text>' ;;
  "issue --all --help") echo 'usage: factory issue <verb> [flags]'; echo; echo '  issue defer <id>  the lead waits'; echo '  issue ask <id>    the lead raises a Decision' ;;
  "issue defer --help") echo 'usage: factory issue defer <id> [flags]'; echo '  --attempt <integer>  required'; echo '  --after <issue-id>  repeatable' ;;
  *--help*) echo 'usage: factory [--format json|plain] <command>'; echo; echo 'commands:'
    echo '  version                  the CLI version'
    echo '  session note <session> <text>   a note typed to a lead'
    echo '  issue new                the owner files an Issue'
    echo '  issue     defer <id>, ask <id>   the group, its verbs in the group help'
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
  "agent-note": `echo 'usage: agent-note <machine>:<terminal> [--check] [--dry-run] [--pages <range>]'`,
  jobrun: `echo 'jobrun: broken'; exit 3`,
  "playwright-cli": `echo 'playwright-cli <command> [args] [options]'; echo
echo '  attach [name]               attach to a running browser'
echo '  goto <url>                  navigate'
echo 'Global options:'; echo '  --json                      output response as JSON'`,
}

function bin(names: string[] = Object.keys(FAKES).filter((n) => n !== "jobrun")): string {
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

  test("a group whose help lists its verbs with no Commands header (factory issue --all --help) resolves them and their flags", async () => {
    const r = await scan({
      "docs/a.md": "`factory issue defer 12 --attempt 1 --after issue_3`\n`factory issue defer 12 --nope`\n`factory issue frobnicate`\n",
    })
    expect(r.err).toContain("docs/a.md:2: no such flag: factory issue defer --nope")
    expect(r.err).toContain("docs/a.md:3: no such command: factory issue frobnicate")
    expect(r.err.split("\n").filter((l) => l.startsWith("docs/"))).toHaveLength(2)
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

  test("the ignore marker silences its own line, the line below when it stands alone, and a whole fence it sits above", async () => {
    const text = [
      "`factory fleet` <!-- cli-refs: ignore -->",
      "`factory version --nope` is not silenced by the trailing marker above",
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
    expect(lines).toHaveLength(2)
    expect(lines[0]).toContain("docs/a.md:2: no such flag: factory version --nope")
    expect(lines[1]).toContain("docs/a.md:5: no such command: factory status")
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

  test("a quote behind `command` is checked like the bare CLI name", async () => {
    const root = repo({ "skills/p/SKILL.md": "`command agent-note --bogus`\n`command agent-note --check`\n" })
    const r = await run(["--root", root, "--json"], { env: { PATH: bin(["agent-note"]) } })
    const body = JSON.parse(r.out)
    expect(r.code).toBe(1)
    expect(body.findings.map((f: { kind: string; line: number }) => [f.kind, f.line])).toEqual([["unknown-flag", 1]])
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

// A rules/clis.md with one row per adapter: `<cli> --help` is its list command. `omit` drops rows, `extra` adds raw rows.
function ruleFile(omit: string[] = [], extra: string[] = []): string {
  const rows = Object.keys(CLIS)
    .filter((c) => !omit.includes(c))
    .map((c) => `| \`${c}\` | something | \`${c} --help\` | none |`)
  return ["# CLIs", "", "| CLI | For | Lists everything | Skill |", "|-|-|-|-|", ...rows, ...extra, ""].join("\n")
}

describe("rule rows", () => {
  test("a table with a row per adapter, every installed CLI's list command exiting 0, passes", async () => {
    const r = await scan({ "rules/clis.md": ruleFile() })
    expect(r.err.split("\n").filter((l) => l.startsWith("rules/"))).toEqual([])
    expect(r.code).toBe(0)
  })

  test("a row that names a CLI with no adapter fails", async () => {
    const r = await scan({ "rules/clis.md": ruleFile([], ["| `agwx` | typo | `agwx --help` | none |"]) })
    expect(r.code).toBe(1)
    expect(r.err).toContain("rules/clis.md:")
    expect(r.err).toContain("agwx: a row names a CLI with no adapter in CLIS")
  })

  test("a list command that exits non-zero fails; a list command of another CLI than the row's fails", async () => {
    const broken = await scan({ "rules/clis.md": ruleFile() }, bin([...Object.keys(FAKES)]))
    expect(broken.code).toBe(1)
    expect(broken.err).toContain("jobrun --help: the list command exits 3")
    const other = await scan({ "rules/clis.md": ruleFile(["home"], ["| `home` | x | `hc --help` | none |"]) })
    expect(other.err).toContain("hc --help: the list command is not of a CLI in the row")
    expect(other.err).toContain("home: no list command for it in the row")
  })

  test("an adapter with no row fails, and a CLI that is not installed is skipped, not failed", async () => {
    const r = await scan({ "rules/clis.md": ruleFile(["home", "epx"]) })
    expect(r.code).toBe(1)
    expect(r.err).toContain("home: has an adapter and no row")
    expect(r.err).toContain("epx: has an adapter and no row")
    const ok = await scan({ "rules/clis.md": ruleFile() }, bin(["agw"]))
    expect(ok.code).toBe(0)
    expect(ok.err).toContain("cli-refs: factory: not installed, its list command was not run")
  })

  test("one row may hold two CLIs and two list commands", () => {
    const rows = parseRuleRows("| CLI | For | L | S |\n|-|-|-|-|\n| `a`, `b` | x | `a --help`, `b --help` | s |\n")
    expect(rows).toEqual([{ line: 3, clis: ["a", "b"], lists: ["a --help", "b --help"], text: "| `a`, `b` | x | `a --help`, `b --help` | s |" }])
  })

  test("a repo without rules/clis.md is not asked for one", async () => {
    const r = await scan({ "docs/a.md": "`factory version`\n" })
    expect(r.code).toBe(0)
  })
})

describe("injected commands", () => {
  const skill = (body: string) => ({ "skills/x/SKILL.md": `---\nname: x\n---\n\n${body}\n` })

  test("injections finds a !`cmd` after whitespace or at the line start and a ```! block, not a plain fence or a bare span", () => {
    const text = "a !`hc --help`\n!`rd --help`\n`!` and !not\nx!`no`\n```!\nhc --help\nrd --help\n```\n```sh\n!`hc --help`\n```\n"
    expect(injections("f.md", text).map((i) => `${i.line}:${i.command}`)).toEqual(["1:hc --help", "2:rd --help", "5:hc --help\nrd --help"])
  })

  test("injected lines are not quotes: a verb the CLI lacks inside one is the run's business", () => {
    const q = extract("f.md", '!`factory fleet 2>&1 || echo "x"`\n```!\nagw nonsense\n```\n`agw web read`\n')
    expect(q.map((x) => x.line)).toEqual([5])
  })

  test("a command that falls back, with and without its CLI, passes and counts", async () => {
    const r = await scan(skill('!`hc --help 2>&1 || echo "hc is not on this machine"`\n\n```!\nagw web read x 2>&1 || echo "agw is not on this machine"\n```'))
    expect(r.err).toBe("")
    expect(r.out).toContain("2 injected commands")
  })

  test("a command with no fallback fails when its CLI is missing from PATH", async () => {
    const r = await scan(skill("!`hc --help`"))
    expect(r.code).toBe(1)
    expect(r.err).toContain('skills/x/SKILL.md:5: injected command: exits 127 when its CLI is not on PATH: end it with || echo "<cli> is not on this machine"')
  })

  test("a command that fails on this machine fails; one that only prints its fallback although the CLI is there fails", async () => {
    const failing = await scan(skill("!`jobrun --help`"), bin([...Object.keys(FAKES)]))
    expect(failing.err).toContain("exits 3: a failing command aborts the whole skill")
    const fellBack = await scan(skill('!`jobrun --help 2>&1 || echo "jobrun is not on this machine"`'), bin([...Object.keys(FAKES)]))
    expect(fellBack.err).toContain("printed its fallback line although the CLI is on PATH")
  })

  test("output over 4,000 bytes in one skill fails", async () => {
    const r = await scan(skill('!`yes "0123456789" | head -c 4100 2>&1 || echo "none is not on this machine"`'))
    expect(r.err).toContain("skills/x/SKILL.md:1: injected command: injects 4100 bytes, over 4000")
  })
})

// The skills the live block was added to (Issue 1636): it sits in the first 25 lines and ends so it cannot fail the skill.
describe("this repo's skills", () => {
  const SKILLS = ["herdr", "remote-dev", "otel", "home", "browse", "secrets", "img", "podcast", "excalidraw-diagram", "mini-service", "research"]
  for (const name of SKILLS) {
    test(`${name} injects its CLI's list in its first 25 lines`, () => {
      const text = require("node:fs").readFileSync(join(import.meta.dir, "..", "skills", name, "SKILL.md"), "utf8") as string
      const found = injections(`skills/${name}/SKILL.md`, text)
      expect(found.length).toBeGreaterThan(0)
      expect(found[0]!.line).toBeLessThanOrEqual(25)
      expect(found.every((i) => i.command.includes("||"))).toBe(true)
    })
  }

  test("rules/clis.md holds a row for every adapter and fits the always-on budget", () => {
    const text = require("node:fs").readFileSync(join(import.meta.dir, "..", "rules", "clis.md"), "utf8") as string
    expect(Buffer.byteLength(text)).toBeLessThanOrEqual(2000)
    const named = new Set(parseRuleRows(text).flatMap((r) => r.clis))
    expect(Object.keys(CLIS).filter((c) => !named.has(c))).toEqual([])
  })
})

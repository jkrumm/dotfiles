import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import plugin from "./claude-guards.js";

// The real hooks under a throwaway HOME: ~/.claude/hooks links to hooks/ and
// ~/.claude/settings.json is a copy of config/settings.template.json, so the plugin
// resolves the same guards Claude Code does. A stub `factory` on PATH lets test-slot rewrite.
const REPO = join(import.meta.dir, "..", "..", "..");
const TEMPLATE = await Bun.file(join(REPO, "config", "settings.template.json")).text();

let home: string;
let project: string;
const saved = { HOME: process.env.HOME, PATH: process.env.PATH, FACTORY_SESSION: process.env.FACTORY_SESSION, FACTORY_SLOT_ACTIVE: process.env.FACTORY_SLOT_ACTIVE };

function install(settings: string, hooksDir: string | null = join(REPO, "hooks")) {
  mkdirSync(join(home, ".claude"), { recursive: true });
  if (hooksDir) symlinkSync(hooksDir, join(home, ".claude", "hooks"));
  writeFileSync(join(home, ".claude", "settings.json"), settings);
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "claude-guards-"));
  project = join(home, "project");
  mkdirSync(project);
  // a Makefile that drives docker, so docker-makefile has a project to protect
  writeFileSync(join(project, "Makefile"), "up:\n\tdocker compose up -d\ncheck:\n\ttrue\n");
  const bin = join(home, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "factory"), "#!/bin/sh\n");
  chmodSync(join(bin, "factory"), 0o755);
  process.env.HOME = home;
  process.env.PATH = `${bin}:${saved.PATH}`;
  delete process.env.FACTORY_SESSION;
  delete process.env.FACTORY_SLOT_ACTIVE; // set inside a slot: test-slot then leaves the command alone
});

afterEach(() => {
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  rmSync(home, { recursive: true, force: true });
});

type Event = { tool: string; sessionID: string; id: string; input: Record<string, unknown> };
type Handler = (event: Event) => Promise<void>;

// The OpenCode v2 plugin context: records the tool hooks the plugin registers. Returns the
// event after the hook ran, so a replaced input shows.
async function before(tool: string, input: Record<string, unknown>): Promise<Event> {
  const handlers: Record<string, Handler> = {};
  await plugin.setup({
    location: { directory: project },
    tool: { hook: async (name: string, cb: Handler) => void (handlers[name] = cb) },
  } as never);
  const event = { tool, sessionID: "s1", id: "c1", input };
  await handlers["execute.before"](event);
  return event;
}

const shell = (command: string, extra: Record<string, unknown> = {}) => before("shell", { command, ...extra });

describe("claude-guards plugin", () => {
  beforeEach(() => install(TEMPLATE));

  test("default-exports the v2 definition", () => {
    expect(plugin.id).toBe("claude-guards");
    expect(typeof plugin.setup).toBe("function");
  });

  describe("shell guards: one denied command each, with the guard's reason", () => {
    test("docker-makefile", async () => {
      await expect(shell("docker compose up -d")).rejects.toThrow(/Raw docker\/docker-compose commands are blocked/);
    });

    test("broad-kill-guard", async () => {
      await expect(shell("pkill -f gate.sh")).rejects.toThrow(/matches every process's full command line/);
    });

    test("review-bypass-guard (factory sessions only)", async () => {
      process.env.FACTORY_SESSION = "1";
      await expect(shell("gh pr merge 12 -R someone/repo --admin")).rejects.toThrow(/bypasses a required review/);
    });

    test("herdr-core-guard", async () => {
      await expect(shell("hc server restart")).rejects.toThrow(/restarts, stops or starts the core/);
    });

    test("launchd-env-guard", async () => {
      await expect(shell("launchctl setenv HTTPS_PROXY http://127.0.0.1:9")).rejects.toThrow(
        /sets the variable for every job and process/,
      );
    });

    test("test-slot rewrites a test runner into its slot and the plugin applies it", async () => {
      const event = await shell("make check");
      expect(event.input.command).toStartWith("factory slot run --name");
      expect(event.input.command).toContain("make check");
    });
  });

  describe("allowed commands pass", () => {
    test.each([
      "ls -la",
      "git status",
      "docker ps",
      "kill 12345",
      "hc read mini:1",
      "launchctl getenv HTTPS_PROXY",
      "gh pr merge 12 --squash",
    ])("%s", async (command) => {
      const event = await shell(command);
      expect(event.input.command).toBe(command);
    });
  });

  test("every denying guard's message reaches the thrown error when several deny", async () => {
    await expect(shell("pkill -f x; hc server restart")).rejects.toThrow(/full command line[\s\S]*restarts, stops or starts the core/);
  });

  test("a shell workdir is the guards' cwd", async () => {
    const elsewhere = join(home, "elsewhere");
    mkdirSync(elsewhere);
    // project has a docker Makefile, elsewhere has none: docker-makefile allows it there
    await expect(shell("docker compose up -d", { workdir: elsewhere })).resolves.toBeDefined();
    await expect(shell("docker compose up -d", { workdir: project })).rejects.toThrow(/Raw docker/);
  });

  describe("file writes pass herdr-core-guard", () => {
    const wrapper = () => join(home, ".local", "bin", "hc");

    test("write to the core's wrapper is denied", async () => {
      await expect(before("write", { path: wrapper(), content: "x" })).rejects.toThrow(/creates a wrapper at/);
    });

    test("edit to the core's wrapper is denied", async () => {
      await expect(before("edit", { path: wrapper(), oldString: "a", newString: "b" })).rejects.toThrow(
        /creates a wrapper at/,
      );
    });

    test("a patch touching the core's wrapper is denied", async () => {
      const patchText = `*** Begin Patch\n*** Update File: notes.md\n@@\n-a\n+b\n*** Add File: ${wrapper()}\n+x\n*** End Patch`;
      await expect(before("patch", { patchText })).rejects.toThrow(/creates a wrapper at/);
    });

    test("a write elsewhere passes, relative to the project", async () => {
      await expect(before("write", { path: "notes.md", content: "x" })).resolves.toBeDefined();
      await expect(before("edit", { path: "notes.md", oldString: "a", newString: "b" })).resolves.toBeDefined();
    });
  });

  test("tools without a Claude Code counterpart are not gated", async () => {
    await expect(before("read", { path: "a.ts" })).resolves.toBeDefined();
    await expect(before("bash", { command: "hc server restart" })).resolves.toBeDefined();
  });

  test("protect-branches and nested-agents are not run here", async () => {
    install(
      JSON.stringify({
        hooks: {
          PreToolUse: [
            {
              matcher: "Bash|Write",
              hooks: [
                { type: "command", command: "~/.claude/hooks/protect-branches.ts" },
                { type: "command", command: "~/.claude/hooks/nested-agents.ts" },
              ],
            },
          ],
        },
      }),
      null,
    );
    // neither hook exists under this HOME: a run would exit 127 and block
    await expect(shell("git push origin master")).resolves.toBeDefined();
    await expect(before("write", { path: "a.md", content: "x" })).resolves.toBeDefined();
  });
});

describe("claude-guards fail closed", () => {
  const settings = (hook: Record<string, unknown>) =>
    JSON.stringify({ hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", ...hook }] }] } });

  test("a crashing guard blocks", async () => {
    install(settings({ command: "echo hook broke >&2; exit 1" }), null);
    await expect(shell("ls")).rejects.toThrow(/exited 1 \(hook broke\).*blocked/);
  });

  test("a guard that does not exist blocks (exit 127)", async () => {
    install(settings({ command: "~/.claude/hooks/missing.ts" }), null);
    await expect(shell("ls")).rejects.toThrow(/missing\.ts: guard hook exited 127.*blocked/);
  });

  test("a guard that times out blocks", async () => {
    install(settings({ command: "sleep 5", timeout: 1 }), null);
    const started = Date.now();
    await expect(shell("ls")).rejects.toThrow(/timed out after 1s.*blocked/);
    expect(Date.now() - started).toBeLessThan(4000);
  });

  test("unparsable output blocks", async () => {
    install(settings({ command: "echo not-json" }), null);
    await expect(shell("ls")).rejects.toThrow(/output unparsable.*blocked/);
  });

  test("an unknown verdict blocks", async () => {
    install(settings({ command: `echo '{"hookSpecificOutput":{"permissionDecision":"ask"}}'` }), null);
    await expect(shell("ls")).rejects.toThrow(/unexpected verdict.*blocked/);
  });

  test("an unreadable settings.json blocks", async () => {
    install("{ not json", null);
    await expect(shell("ls")).rejects.toThrow(/cannot read the guard list.*blocked/);
  });

  test("a missing settings.json blocks", async () => {
    await expect(shell("ls")).rejects.toThrow(/cannot read the guard list.*blocked/);
  });
});

describe("the guard list follows the settings template", () => {
  // The plugin runs whatever the Bash and Write|Edit matchers name. This fails when the
  // template gains a hook there, so a new one is a decision: a guard OpenCode now runs
  // (add it below, with its test above), or a hook to SKIP in claude-guards.js.
  const NOT_GUARDS = ["protect-branches.ts", "nested-agents.ts"];
  const GUARDS = [
    "broad-kill-guard.ts",
    "docker-makefile.ts",
    "herdr-core-guard.ts",
    "launchd-env-guard.ts",
    "review-bypass-guard.ts",
    "test-slot.ts",
  ];

  const names = (tool: string) => {
    const groups = JSON.parse(TEMPLATE).hooks.PreToolUse as { matcher: string; hooks: { command: string }[] }[];
    return groups
      .filter((g) => new RegExp(`^(?:${g.matcher})$`).test(tool))
      .flatMap((g) => g.hooks.map((h) => h.command.split("/").pop() as string));
  };

  test("Bash", () => {
    expect(names("Bash").filter((n) => !NOT_GUARDS.includes(n)).sort()).toEqual(GUARDS);
  });

  test("Write and Edit", () => {
    for (const tool of ["Write", "Edit"]) {
      expect(names(tool).filter((n) => !NOT_GUARDS.includes(n))).toEqual(["herdr-core-guard.ts"]);
    }
  });
});

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import plugin from "./protect-branches.js";

// A stand-in for hooks/protect-branches.ts, installed under a throwaway HOME so the
// plugin's policy path resolves to it. Denies "push origin master", crashes on "boom".
const FAKE_HOOK = `
const input = JSON.parse(await Bun.stdin.text());
const cmd = input.tool_input.command;
if (cmd.includes("boom")) {
  console.error("hook broke");
  process.exit(1);
}
if (cmd.includes("push origin master")) {
  console.log(JSON.stringify({ hookSpecificOutput: { permissionDecision: "deny", permissionDecisionReason: "no direct push" } }));
}
`;

let home: string;
const savedHome = process.env.HOME;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "protect-branches-"));
  mkdirSync(join(home, ".claude", "hooks"), { recursive: true });
  writeFileSync(join(home, ".claude", "hooks", "protect-branches.ts"), FAKE_HOOK);
  process.env.HOME = home;
});

afterEach(() => {
  if (savedHome === undefined) delete process.env.HOME;
  else process.env.HOME = savedHome;
  rmSync(home, { recursive: true, force: true });
});

type Handler = (event: Record<string, unknown>) => Promise<void>;

// The OpenCode v2 plugin context: records the tool hooks the plugin registers.
async function before(tool: string, input: unknown): Promise<void> {
  const handlers: Record<string, Handler> = {};
  await plugin.setup({
    location: { directory: home },
    tool: { hook: async (name: string, cb: Handler) => void (handlers[name] = cb) },
  } as never);
  await handlers["execute.before"]({ tool, sessionID: "s1", id: "c1", input });
}

describe("protect-branches plugin", () => {
  test("default-exports the v2 definition", () => {
    expect(plugin.id).toBe("protect-branches");
    expect(typeof plugin.setup).toBe("function");
  });

  test("a denied shell command throws the hook's reason", async () => {
    await expect(before("shell", { command: "git push origin master" })).rejects.toThrow("no direct push");
  });

  test("an allowed shell command passes", async () => {
    await expect(before("shell", { command: "ls -la" })).resolves.toBeUndefined();
  });

  test("a crashing hook fails closed", async () => {
    await expect(before("shell", { command: "boom" })).rejects.toThrow(/exited 1.*hook broke.*blocked/);
  });

  test("the v1 tool name bash is not gated", async () => {
    await expect(before("bash", { command: "git push origin master" })).resolves.toBeUndefined();
  });

  test("other tools are not gated", async () => {
    await expect(before("edit", { path: "a.ts" })).resolves.toBeUndefined();
  });
});

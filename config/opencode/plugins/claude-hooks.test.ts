import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import plugin from "./claude-hooks.js";

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

function project(settings?: unknown): string {
  const dir = mkdtempSync(join(tmpdir(), "claude-hooks-"));
  dirs.push(dir);
  if (settings !== undefined) {
    mkdirSync(join(dir, ".claude"));
    writeFileSync(join(dir, ".claude", "settings.json"), JSON.stringify(settings));
  }
  return dir;
}

const hook = (command: string, matcher = "Edit|Write|MultiEdit") => ({
  matcher,
  hooks: [{ type: "command", command }],
});

type Handler = (event: Record<string, unknown>) => Promise<void>;

// A stand-in for OpenCode's plugin context: it records the tool hooks the plugin registers.
async function load(dir: string) {
  const handlers: Record<string, Handler> = {};
  await plugin.setup({
    location: { directory: dir },
    tool: { hook: async (name: string, cb: Handler) => void (handlers[name] = cb) },
  } as never);
  return handlers;
}

const OK = "Created file successfully.";

// Runs the after hook the way OpenCode does: returns the text parts the model will read.
async function post(dir: string, tool: string, input: unknown) {
  const handlers = await load(dir);
  const event = { tool, sessionID: "s1", id: "c1", input, status: "completed", result: { content: [{ type: "text", text: OK }] } };
  await handlers["execute.after"](event);
  return event.result.content.map((part) => part.text).join("\n");
}

async function pre(dir: string, tool: string, input: unknown) {
  const handlers = await load(dir);
  await handlers["execute.before"]({ tool, sessionID: "s1", id: "c1", input });
}

describe("PostToolUse", () => {
  test("exit 2 appends the hook's stderr to the tool result", async () => {
    const dir = project({
      hooks: { PostToolUse: [hook("echo 'basalt/colour-literal at line 3' >&2; exit 2")] },
    });
    const out = await post(dir, "write", { path: join(dir, "a.ts"), content: "#ff0000" });
    expect(out).toContain(OK);
    expect(out).toContain("basalt/colour-literal at line 3");
  });

  test("the hook gets the Claude Code event on stdin and CLAUDE_PROJECT_DIR", async () => {
    const dir = project({
      hooks: { PostToolUse: [hook('cat > "$CLAUDE_PROJECT_DIR/event.json"')] },
    });
    const file = join(dir, "src", "a.ts");
    await post(dir, "edit", { path: file, oldString: "a", newString: "b" });
    const event = JSON.parse(readFileSync(join(dir, "event.json"), "utf8"));
    expect(event).toMatchObject({
      hook_event_name: "PostToolUse",
      tool_name: "Edit",
      cwd: dir,
      session_id: "s1",
      tool_input: { file_path: file, old_string: "a", new_string: "b" },
    });
  });

  test("a relative tool path is resolved against the project directory", async () => {
    const dir = project({ hooks: { PostToolUse: [hook('cat > "$CLAUDE_PROJECT_DIR/event.json"')] } });
    await post(dir, "write", { path: "src/a.ts", content: "x" });
    const event = JSON.parse(readFileSync(join(dir, "event.json"), "utf8"));
    expect(event.tool_input.file_path).toBe(join(dir, "src/a.ts"));
  });

  test("a failed tool call is not checked", async () => {
    const dir = project({ hooks: { PostToolUse: [hook("echo no >&2; exit 2")] } });
    const handlers = await load(dir);
    const event = { tool: "edit", sessionID: "s", id: "c", input: { path: "a.ts" }, status: "error", result: { content: [] } };
    await handlers["execute.after"](event);
    expect(event.result.content).toEqual([]);
  });

  test("exit 0 and other non-2 exits add nothing", async () => {
    for (const code of [0, 1, 127]) {
      const dir = project({ hooks: { PostToolUse: [hook(`echo noise >&2; exit ${code}`)] } });
      expect(await post(dir, "write", { path: join(dir, "a.ts"), content: "x" })).toBe(
        OK,
      );
    }
  });

  test("a matcher that does not cover Edit or Write does not run", async () => {
    const dir = project({ hooks: { PostToolUse: [hook("echo no >&2; exit 2", "Bash")] } });
    expect(await post(dir, "edit", { path: join(dir, "a.ts") })).toBe(OK);
  });

  test("non-writing tools never run hooks", async () => {
    const dir = project({ hooks: { PostToolUse: [hook("echo no >&2; exit 2", "*")] } });
    expect(await post(dir, "read", { path: join(dir, "a.ts") })).toBe(OK);
  });

  test("apply_patch runs per file, skipping deletes", async () => {
    const dir = project({
      hooks: { PostToolUse: [hook('jq -r .tool_input.file_path >> "$CLAUDE_PROJECT_DIR/seen"')] },
    });
    const patchText = [
      "*** Begin Patch",
      "*** Update File: src/a.ts",
      "@@",
      "-a",
      "+b",
      "*** Add File: src/b.ts",
      "+x",
      "*** Delete File: src/gone.ts",
      "*** End Patch",
    ].join("\n");
    await post(dir, "apply_patch", { patchText });
    expect(readFileSync(join(dir, "seen"), "utf8").trim().split("\n")).toEqual([
      join(dir, "src/a.ts"),
      join(dir, "src/b.ts"),
    ]);
  });

  test("JSON decision:block feeds the reason back", async () => {
    const dir = project({
      hooks: { PostToolUse: [hook(`echo '{"decision":"block","reason":"fix the lint"}'`)] },
    });
    expect(await post(dir, "write", { path: join(dir, "a.ts"), content: "x" })).toContain("fix the lint");
  });
});

describe("PreToolUse", () => {
  test("exit 2 denies with the stderr as the error", async () => {
    const dir = project({
      hooks: { PreToolUse: [hook("echo 'managed file, do not edit' >&2; exit 2")] },
    });
    await expect(pre(dir, "edit", { path: join(dir, "a.ts") })).rejects.toThrow(
      "managed file, do not edit",
    );
  });

  test("exit 0 allows", async () => {
    const dir = project({ hooks: { PreToolUse: [hook("exit 0")] } });
    await pre(dir, "write", { path: join(dir, "a.ts"), content: "x" });
  });

  test("permissionDecision deny in JSON denies", async () => {
    const out = '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"nope"}}';
    const dir = project({ hooks: { PreToolUse: [hook(`echo '${out}'`)] } });
    await expect(pre(dir, "write", { path: join(dir, "a.ts"), content: "x" })).rejects.toThrow("nope");
  });
});

describe("a project without hooks", () => {
  test("no settings.json: nothing happens", async () => {
    const dir = project();
    expect(await post(dir, "write", { path: join(dir, "a.ts"), content: "x" })).toBe(
      OK,
    );
    await pre(dir, "write", { path: join(dir, "a.ts"), content: "x" });
  });

  test("settings.json without hooks, or unparsable: nothing happens", async () => {
    const noHooks = project({ permissions: {} });
    expect(await post(noHooks, "edit", { path: join(noHooks, "a.ts") })).toBe(OK);
    const bad = project();
    mkdirSync(join(bad, ".claude"));
    writeFileSync(join(bad, ".claude", "settings.json"), "{ not json");
    expect(await post(bad, "edit", { path: join(bad, "a.ts") })).toBe(OK);
  });
});

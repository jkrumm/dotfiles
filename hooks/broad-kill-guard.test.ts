#!/usr/bin/env bun

/**
 * Tests for the broad-kill-guard PreToolUse hook (incident 2026-11-01 20:12).
 *
 * A false allow ends other agents' sessions; a false deny blocks a legitimate
 * kill of the agent's own process. Both directions are covered.
 */

import { describe, expect, test } from "bun:test";
import { findViolation } from "./broad-kill-guard";

const HOOK = `${import.meta.dir}/broad-kill-guard.ts`;

const denied = (cmd: string) => expect(findViolation(cmd)).not.toBeNull();
const allowed = (cmd: string) => expect(findViolation(cmd)).toBeNull();

describe("deny", () => {
  test("the exact incident command", () => {
    denied(`for p in $(pgrep -f 'gate.sh'); do pkill -TERM -P $p; kill $p; done`);
  });

  test("pkill -f in any flag cluster", () => {
    denied("pkill -f gate.sh");
    denied("pkill -9 -f gate.sh");
    denied("pkill -fx gate.sh");
    denied("pkill -xf gate.sh");
    denied("pkill --full gate.sh");
    denied("pkill -f -P 123 gate.sh");
  });

  test("pkill with a pattern and no -P/-g scope", () => {
    denied("pkill gate.sh");
    denied("pkill -TERM claude");
    denied("pkill -9 -x bun");
    denied("pkill -u someuser");
  });

  test("a signal named -PIPE does not count as -P scope", () => {
    denied("pkill -PIPE gate.sh");
  });

  test("killall", () => {
    denied("killall node");
    denied("killall -9 claude");
    denied("sudo killall bun");
  });

  test("kill fed by a pgrep -f substitution", () => {
    denied("kill $(pgrep -f gate.sh)");
    denied('kill -9 "$(pgrep -f gate.sh)"');
    denied("kill `pgrep -f gate.sh`");
    denied("pids=$(pgrep -fl gate.sh); kill $pids");
  });

  test("pipe from pgrep -f into xargs kill", () => {
    denied("pgrep -f gate.sh | xargs kill");
    denied("pgrep -f gate.sh | xargs -r kill -9");
    denied("pgrep -af gate.sh | awk '{print $1}' | xargs -n1 kill -TERM");
  });

  test("pkill -P / -g fed by pgrep -f", () => {
    denied("pkill -P $(pgrep -f gate.sh)");
    denied("pkill -g $(pgrep -f gate.sh)");
    denied("for p in $(pgrep -f x); do pkill -P $p; done");
  });

  test("for loop whose body kills", () => {
    denied("for p in $(pgrep -f gate.sh); do\n  kill $p\ndone");
    denied("while read p; do kill $p; done < <(pgrep -f gate.sh)");
  });

  test("wrappers, env assignments and shells do not hide the call", () => {
    denied("sudo pkill -f gate.sh");
    denied("sudo -n pkill -f gate.sh");
    denied("env FOO=1 pkill gate.sh");
    denied("timeout 5 killall node");
    denied("nohup killall node");
    denied("/usr/bin/pkill -f gate.sh");
    denied("echo ok && pkill -f gate.sh");
    denied("bash -c 'pkill -f gate.sh'");
    denied(`sh -lc "killall node"`);
    denied(`eval "pkill -f gate.sh"`);
    denied("xargs pkill < list");
  });

  test("redirections, long wrapper options, env -S and shell stdin do not hide the call", () => {
    denied(">/dev/null pkill -f gate.sh");
    denied("2>&1 pkill -f gate.sh");
    denied("> /dev/null killall node");
    denied("sudo --user root pkill -f gate.sh");
    denied("sudo --user=root pkill -f gate.sh");
    denied("env -S 'pkill -f gate.sh'");
    denied("env --split-string='killall node'");
    denied("bash <<'EOF'\npkill -f gate.sh\nEOF");
    denied("bash <<EOF\nkillall node\nEOF");
    denied("sh <<< 'pkill -f gate.sh'");
    denied("bash <<'END-SCRIPT'\npkill -f gate.sh\nEND-SCRIPT");
    denied("2>&- pkill -f gate.sh");
    denied("env -S 'pkill -P 123' -f gate.sh");
    denied(`env -S "'killall' node"`);
    denied("env -S '-i pkill -f gate.sh'");
    denied("sudo -n bash <<EOF\nkillall node\nEOF");
  });

  test("xargs -I{} replacement operands do not hide the kill", () => {
    denied("pgrep -f gate.sh | xargs -I{} kill {}");
    denied("pgrep -f gate.sh | xargs -I{} pkill -P {}");
    denied("pgrep -f gate.sh | xargs -I{} kill 1234 {}");
  });
});

describe("allow", () => {
  test("kill of a literal pid, $!, job or pidfile", () => {
    allowed("kill 1234");
    allowed("kill -9 1234");
    allowed("kill -TERM 1234 5678");
    allowed("kill -s TERM 1234");
    allowed("kill $!");
    allowed("kill -TERM -- -1234");
    allowed("kill %1");
    allowed("kill %%");
    allowed('kill "$(cat /tmp/gate.pid)"');
    allowed("kill $(cat /tmp/gate.pid)");
    allowed('kill -TERM "$(cat "$PIDFILE")"');
  });

  test("kill of a variable without any pgrep -f", () => {
    allowed("kill $pid");
  });

  test("pkill -P / -g with a literal pid or $!", () => {
    allowed("pkill -P 1234");
    allowed("pkill -TERM -P 1234");
    allowed("pkill -P $!");
    allowed("pkill -P1234");
    allowed("pkill --parent 1234");
    allowed("pkill -g 4321");
    allowed("pkill -TERM -P $parent");
    allowed("pkill -9 -P 1234 gate.sh");
  });

  test("literal kills beside an unrelated pgrep -f read", () => {
    allowed("pgrep -f gate.sh; kill 1234");
    allowed("pgrep -f gate.sh && kill $!");
    allowed("pgrep -f gate.sh | head -1; pkill -P 1234");
  });

  test("pgrep alone is a read", () => {
    allowed("pgrep -f gate.sh");
    allowed("pgrep -fl gate.sh");
    allowed("pgrep -af gate.sh | head");
    allowed("pgrep -P 1234");
    allowed("echo $(pgrep -f gate.sh)");
  });

  test("xargs kill without a pgrep -f", () => {
    allowed("cat /tmp/pids | xargs kill");
  });

  test("the words inside quoted text are data", () => {
    allowed(`grep -n 'pkill -f' hooks/*.ts`);
    allowed(`grep -rn "killall" docs/`);
    allowed(`git commit -m "deny pkill -f and killall"`);
    allowed(`git commit -m "fix: for p in \\$(pgrep -f x); do kill \\$p; done"`);
    allowed(`echo "pgrep -f gate.sh | xargs kill"`);
    allowed(`echo pkill -f gate.sh`);
    allowed(`cat <<'EOF'\npkill -f gate.sh\nkillall node\nEOF`);
    allowed(`rg 'killall|pkill' .`);
  });

  test("empty and unrelated commands", () => {
    allowed("");
    allowed("ls -la");
    allowed("bash -c 'echo hi'");
    allowed("make hooks-test");
    allowed("bash <<'EOF'\necho hi\nEOF");
    allowed(">/dev/null kill 1234");
    allowed(`echo "sh <<< 'pkill -f gate.sh'"`);
    allowed("env -S 'echo hello; killall node'");
    allowed("sudo --user root kill 1234");
  });
});

describe("deny reason", () => {
  test("names the safe alternative", () => {
    const reason = findViolation("pkill -f gate.sh") ?? "";
    expect(reason).toContain("Pattern kills hit every agent on this machine (incident 2026-11-01)");
    expect(reason).toContain("keep $! in a pidfile");
  });
});

describe("hook I/O", () => {
  const run = async (tool_name: string, command: string) => {
    const proc = Bun.spawn(["bun", HOOK], {
      stdin: new Blob([JSON.stringify({ tool_name, tool_input: { command } })]),
      stdout: "pipe",
      stderr: "pipe",
    });
    const stdout = await new Response(proc.stdout).text();
    return { code: await proc.exited, stdout };
  };

  test("denies with the PreToolUse deny shape", async () => {
    const { code, stdout } = await run("Bash", "pkill -f gate.sh");
    expect(code).toBe(0);
    const out = JSON.parse(stdout).hookSpecificOutput;
    expect(out.hookEventName).toBe("PreToolUse");
    expect(out.permissionDecision).toBe("deny");
    expect(out.permissionDecisionReason).toContain("pidfile");
  });

  test("silent on an allowed command", async () => {
    expect(await run("Bash", "kill $!")).toEqual({ code: 0, stdout: "" });
  });

  test("silent on a non-Bash tool", async () => {
    expect(await run("Edit", "pkill -f gate.sh")).toEqual({ code: 0, stdout: "" });
  });
});

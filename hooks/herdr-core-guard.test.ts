#!/usr/bin/env bun

/**
 * Tests for the herdr-core-guard PreToolUse hook (incident 2026-11-13, mini panic).
 *
 * A false allow lets an agent restart or update the core; a false deny blocks the
 * read verbs agents live on (`hc read`, `hc send`, `hc run`). Both are covered.
 * Nothing here runs a command: the hook only parses text.
 */

import { describe, expect, test } from "bun:test";
import { homedir } from "node:os";
import { findFileViolation, findViolation } from "./herdr-core-guard";

const HOOK = `${import.meta.dir}/herdr-core-guard.ts`;

const denied = (cmd: string) => expect(findViolation(cmd)).not.toBeNull();
const allowed = (cmd: string) => expect(findViolation(cmd)).toBeNull();

describe("deny: the core's own CLI", () => {
  test("hc server restart | stop | start", () => {
    denied("hc server restart");
    denied("hc server stop");
    denied("hc server start");
    denied("~/.local/bin/hc server restart");
    denied("hc --machine mini server restart");
    denied("hc server restart --json");
  });

  test("hc update and hc machine update", () => {
    denied("hc update");
    denied("hc update --yes");
    denied("hc machine update");
    denied("hc machine update mini");
    denied("hc --machine mini update");
  });

  test("starting herdr-core as a server", () => {
    denied("herdr-core serve");
    denied("herdr-core");
    denied("herdr-core connect");
    denied("nohup herdr-core serve &");
    denied("'/Users/someone/.local/share/herdr-core/active/Herdr Core.app/Contents/MacOS/herdr-core' serve");
    denied("herdr-core server restart");
    denied("herdr-core update");
  });

  test("make herdr-core-* that restarts or installs the core", () => {
    denied("make herdr-core-update");
    denied("make -C ~/SourceRoot/dotfiles herdr-core-update");
    denied("make herdr-core-update FORCE=1");
    denied("make herdr-core-clean-restart");
    denied("make herdr-core-setup");
    denied("make herdr-core-teardown");
  });

  test("launchctl on the core's label", () => {
    for (const verb of ["kickstart", "bootout", "bootstrap", "unload", "load", "stop", "kill", "remove", "disable"]) {
      denied(`launchctl ${verb} gui/501/com.jkrumm.herdr-core`);
    }
    denied("launchctl kickstart -k gui/$(id -u)/com.jkrumm.herdr-core");
    denied("launchctl bootout gui/501 ~/Library/LaunchAgents/com.jkrumm.herdr-core.plist");
    denied("launchctl unload ~/Library/LaunchAgents/com.jkrumm.herdr-core.plist");
    denied("launchctl kill TERM gui/501/com.jkrumm.herdr-core");
  });

  test("reboot, shutdown, halt", () => {
    denied("shutdown -r now");
    denied("reboot");
    denied("halt");
    denied("/sbin/shutdown -h now");
    denied("launchctl reboot system");
  });

  test("kill, pkill, killall naming herdr-core", () => {
    denied("pkill herdr-core");
    denied("pkill -f herdr-core");
    denied("killall herdr-core");
    denied('killall "Herdr Core"');
    denied("kill -9 $(pgrep herdr-core)");
    denied("pids=$(pidof herdr-core); kill $pids");
  });
});

describe("deny: wrappers around the same words", () => {
  test("sudo", () => {
    denied("sudo reboot");
    denied("sudo shutdown -r now");
    denied("sudo -n halt");
    denied("sudo hc server restart");
    denied("sudo launchctl bootout system/com.jkrumm.herdr-core");
    denied("sudo killall herdr-core");
    denied("sudo -u root hc update");
  });

  test("env-prefixed", () => {
    denied("FOO=1 hc update");
    denied("env FOO=1 hc server restart");
    denied("env -i HOME=/tmp hc update");
    denied("time hc update");
  });

  test("; and && chains, pipes, subshells", () => {
    denied("echo start; hc server restart");
    denied("cd ~ && hc update");
    denied("hc server status && hc server restart");
    denied("false || reboot");
    denied("echo go | xargs hc update");
    denied("(hc server stop)");
    denied("echo $(hc update)");
    denied("hc server stop; hc server start");
    denied("ls\nhc update\nls");
  });

  test("ssh mini '<cmd>'", () => {
    denied("ssh mini 'hc server restart'");
    denied('ssh mini "hc update"');
    denied("ssh mini hc server restart");
    denied("ssh -t mini hc update");
    denied("ssh -o BatchMode=yes -p 22 mini 'make -C ~/SourceRoot/dotfiles herdr-core-update'");
    denied("ssh mini 'sudo reboot'");
    denied("ssh mini 'cd ~/SourceRoot/dotfiles && make herdr-core-update'");
    denied("ssh mini 'launchctl kickstart -k gui/501/com.jkrumm.herdr-core'");
  });

  test("shells, eval, heredocs, hc run", () => {
    denied("bash -c 'hc server restart'");
    denied("sh -lc 'reboot'");
    denied("eval 'hc update'");
    denied("bash <<'EOF'\nhc server restart\nEOF");
    denied("hc run -- hc server restart");
    denied("hc run --timeout 60 'hc update'");
    denied("hc run --machine mini 'make herdr-core-update'");
  });
});

describe("deny: wrappers at ~/.local/bin/{hc,herdr-core}", () => {
  test("redirection", () => {
    denied("echo '#!/bin/sh' > ~/.local/bin/hc");
    denied("echo x >> ~/.local/bin/herdr-core");
    denied("echo x >~/.local/bin/hc");
    denied("cat <<'EOF' > $HOME/.local/bin/hc\n#!/bin/sh\nEOF");
    denied("> ~/.local/bin/hc echo x");
    denied(`echo x > ${homedir()}/.local/bin/hc`);
    denied("bash -c 'echo x > ~/.local/bin/herdr-core'");
  });

  test("tee, cp, mv, ln, install, touch, dd", () => {
    denied("echo x | tee ~/.local/bin/hc");
    denied("echo x | tee -a ~/.local/bin/herdr-core");
    denied("cp /tmp/wrapper ~/.local/bin/hc");
    denied("mv /tmp/wrapper $HOME/.local/bin/herdr-core");
    denied("ln -sf /tmp/wrapper ~/.local/bin/hc");
    denied("install -m 755 /tmp/w ~/.local/bin/hc");
    denied("touch ~/.local/bin/hc");
    denied("dd if=/tmp/w of=~/.local/bin/hc");
  });

  test("Write / Edit file paths", () => {
    expect(findFileViolation(`${homedir()}/.local/bin/hc`)).not.toBeNull();
    expect(findFileViolation(`${homedir()}/.local/bin/herdr-core`)).not.toBeNull();
    expect(findFileViolation("/Users/someone/.local/bin/hc")).not.toBeNull();
    expect(findFileViolation("~/.local/bin/herdr-core")).not.toBeNull();
    expect(findFileViolation("$HOME/.local/bin/hc")).not.toBeNull();
  });
});

describe("allow", () => {
  test("read verbs", () => {
    allowed("hc read t1");
    allowed("hc read t1 --lines 50");
    allowed("hc send t1 'hello'");
    allowed("hc send t1 update");
    allowed("hc wait t1");
    allowed("hc list");
    allowed("hc ls");
    allowed("hc ls | jq '.terminals | length'");
    allowed("hc run --timeout 900 'make secrets-seed'");
    allowed("hc run -- echo hi");
    allowed("hc run --machine mini 'echo \"hc update\"'");
    allowed("hc attach t1");
    allowed("hc events");
    allowed("hc kill t1");
    allowed("hc --version");
    allowed("hc server status");
    allowed("hc server status --json");
    allowed("hc --machine mini server status");
    allowed("herdr-core --version");
  });

  test("make targets that do not touch the core", () => {
    allowed("make herdr-core-status");
    allowed("make herdr-core-test");
    allowed("make herdr-core-launcher");
    allowed("make check");
    allowed("make hooks-test");
    allowed("make -C ~/SourceRoot/dotfiles doctor");
  });

  test("launchctl reads and unrelated jobs", () => {
    allowed("launchctl print gui/501/com.jkrumm.herdr-core");
    allowed("launchctl list | grep herdr-core");
    allowed("launchctl kickstart -k gui/501/com.jkrumm.hc-resume");
    allowed("launchctl bootout gui/501/com.jkrumm.collie");
  });

  test("kills of other things", () => {
    allowed("kill 1234");
    allowed("kill $!");
    allowed("pkill -P 1234");
    allowed("pgrep herdr-core");
    allowed("pgrep -l herdr-core | head");
  });

  test("ssh to read", () => {
    allowed("ssh mini hc server status");
    allowed("ssh mini 'hc read t1'");
    allowed("ssh -t mini hc");
    allowed("ssh mini 'cat ~/.local/bin/hc'");
    allowed("ssh mini");
  });

  test("reading or running the wrapper path", () => {
    allowed("cat ~/.local/bin/hc");
    allowed("ls -l ~/.local/bin/hc ~/.local/bin/herdr-core");
    allowed("readlink ~/.local/bin/hc");
    allowed("cp ~/.local/bin/hc /tmp/hc.bak");
    allowed("echo x > ~/.local/bin/other");
    allowed("echo x > /tmp/hc");
    allowed("ln -s ~/.local/bin/agw /tmp/agw");
  });

  test("the denied words inside quoted text are data", () => {
    allowed(`grep -n 'hc server restart' docs/*.md`);
    allowed(`grep -rn "hc update" scripts/`);
    allowed(`git commit -m "deny hc server restart, hc update and reboot"`);
    allowed(`echo "make herdr-core-update"`);
    allowed(`echo "ssh mini 'hc server restart'"`);
    allowed(`echo hc server restart`);
    allowed(`echo reboot`);
    allowed(`rg 'launchctl bootout.*herdr-core' docs/`);
    allowed(`cat <<'EOF'\nhc server restart\nmake herdr-core-update\nreboot\nEOF`);
    allowed(`cat <<'EOF' > /tmp/note.md\nhc update\nEOF`);
    allowed(`echo "echo x > ~/.local/bin/hc"`);
    allowed(`git commit -m "no wrapper at ~/.local/bin/hc"`);
    allowed(`bash <<'EOF'\necho hi\nEOF`);
    allowed(`env -S 'echo hello; reboot'`);
  });

  test("empty and unrelated commands", () => {
    allowed("");
    allowed("ls -la");
    allowed("git status");
    allowed("bash -c 'echo hi'");
  });

  test("Write / Edit on other files", () => {
    expect(findFileViolation("/tmp/hc")).toBeNull();
    expect(findFileViolation(`${homedir()}/.local/bin/agw`)).toBeNull();
    expect(findFileViolation("scripts/lib/core-up.sh")).toBeNull();
    expect(findFileViolation("docs/herdr-core.md")).toBeNull();
    expect(findFileViolation("")).toBeNull();
  });
});

describe("deny reason", () => {
  test("names the one update path and the incident doc", () => {
    const reason = findViolation("hc server restart") ?? "";
    expect(reason).toContain("make herdr-core-update");
    expect(reason).toContain("docs/incident-2026-11-13-mini-panic.md");
  });
});

describe("hook I/O", () => {
  const run = async (tool_name: string, tool_input: Record<string, unknown>) => {
    const proc = Bun.spawn(["bun", HOOK], {
      stdin: new Blob([JSON.stringify({ tool_name, tool_input })]),
      stdout: "pipe",
      stderr: "pipe",
    });
    const stdout = await new Response(proc.stdout).text();
    return { code: await proc.exited, stdout };
  };

  test("denies a Bash command with the PreToolUse deny shape", async () => {
    const { code, stdout } = await run("Bash", { command: "hc server restart" });
    expect(code).toBe(0);
    const out = JSON.parse(stdout).hookSpecificOutput;
    expect(out.hookEventName).toBe("PreToolUse");
    expect(out.permissionDecision).toBe("deny");
    expect(out.permissionDecisionReason).toContain("make herdr-core-update");
  });

  test("denies Write and Edit of the wrapper path", async () => {
    for (const tool of ["Write", "Edit"]) {
      const { stdout } = await run(tool, { file_path: `${homedir()}/.local/bin/hc`, content: "#!/bin/sh" });
      expect(JSON.parse(stdout).hookSpecificOutput.permissionDecision).toBe("deny");
    }
  });

  test("silent on an allowed command and file", async () => {
    expect(await run("Bash", { command: "hc read t1" })).toEqual({ code: 0, stdout: "" });
    expect(await run("Write", { file_path: "/tmp/x", content: "x" })).toEqual({ code: 0, stdout: "" });
  });

  test("silent on another tool", async () => {
    expect(await run("Read", { file_path: `${homedir()}/.local/bin/hc` })).toEqual({ code: 0, stdout: "" });
  });
});

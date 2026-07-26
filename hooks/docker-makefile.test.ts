#!/usr/bin/env bun

/**
 * Tests for the docker-makefile PreToolUse hook.
 *
 * The hook is symlinked live into ~/.claude/hooks, so a regression here blocks
 * real commands immediately. The two failure directions are not symmetric:
 * a false block is loud and annoying, a false allow silently runs raw docker
 * and defeats the point of the hook. Both are covered below.
 */

import { describe, expect, test } from "bun:test";
import { inspectDockerCommand, shouldBlock, splitIntoCommands } from "./docker-makefile";

describe("splitIntoCommands", () => {
  test("splits on unquoted operators", () => {
    expect(splitIntoCommands("a && b | c ; d")).toEqual([["a"], ["b"], ["c"], ["d"]]);
  });

  test("keeps quoted text as a single data token", () => {
    expect(splitIntoCommands("grep -n 'a|b;c' file")).toEqual([
      ["grep", "-n", "a|b;c", "file"],
    ]);
  });

  test("double quotes preserve operators as data", () => {
    expect(splitIntoCommands('echo "a && b"')).toEqual([["echo", "a && b"]]);
  });

  test("parses command substitution recursively", () => {
    const cmds = splitIntoCommands("echo $(docker compose up)");
    expect(cmds).toContainEqual(["docker", "compose", "up"]);
  });

  test("handles escaped characters outside quotes", () => {
    expect(splitIntoCommands("echo a\\ b")).toEqual([["echo", "a b"]]);
  });
});

describe("mentions of docker are not invocations", () => {
  // The exact command that misfired: the `|` inside the quoted grep pattern
  // read as a pipe, and `docker-socket` read as the docker binary.
  test("the regression case — grep pattern containing a pipe and docker-socket", () => {
    expect(
      shouldBlock(
        "cd ~/SourceRoot/dotfiles && grep -n '_setup-caddy\\|_setup-dnsmasq\\|docker-socket' Makefile | head -20"
      )
    ).toBe(false);
  });

  test.each([
    "grep -rn 'docker compose up' docs/",
    'echo "run docker compose up to start"',
    "rg --files | grep docker-makefile.ts",
    "cat docker-compose.yml",
    "ls /var/run/docker.sock",
    "sed -i 's/docker run/make up/' README.md",
    "git commit -m 'fix: docker compose ordering'",
  ])("allows: %s", (cmd) => {
    expect(shouldBlock(cmd)).toBe(false);
  });
});

describe("heredoc bodies are data, not commands", () => {
  // Hit for real: committing the fix for this hook was blocked by the hook,
  // because the commit message mentioned `$(docker compose up)`.
  test("a quoted heredoc mentioning a substitution does not execute it", () => {
    const cmd = [
      "git commit -q -F - <<'EOF'",
      "fix(hooks): docker gate matched mentions, not invocations",
      "",
      "Substitutions are parsed recursively, so `$(docker compose up)` is caught.",
      "EOF",
    ].join("\n");
    expect(shouldBlock(cmd)).toBe(false);
  });

  test("a quoted heredoc whose body starts with a docker line", () => {
    expect(shouldBlock("cat <<'EOF' > run.sh\ndocker compose up -d\nEOF")).toBe(false);
  });

  test("<<- strips leading tabs when matching the delimiter", () => {
    expect(shouldBlock("cat <<-'EOF'\ndocker compose up\n\tEOF")).toBe(false);
  });

  test("an UNQUOTED heredoc still expands substitutions, so they are caught", () => {
    expect(shouldBlock("cat <<EOF\nresult: $(docker compose up)\nEOF")).toBe(true);
  });

  test("a herestring is not a heredoc", () => {
    expect(shouldBlock("grep docker <<< 'docker compose up'")).toBe(false);
  });

  test("parsing resumes after the heredoc terminator", () => {
    expect(shouldBlock("cat <<'EOF'\nhello\nEOF\ndocker compose up")).toBe(true);
  });
});

describe("real invocations are still blocked", () => {
  test.each([
    "docker compose up -d",
    "docker-compose up",
    "docker run -it alpine sh",
    "sudo docker compose down",
    "sudo -S docker compose restart",
    "cd /srv && docker compose up",
    "make foo; docker rm -f web",
    "echo hi && docker volume prune",
    "DOCKER_HOST=tcp://x docker compose up",
    "/usr/local/bin/docker compose up",
    "docker compose -f prod.yml up",
    "docker -H tcp://x run alpine",
    "echo $(docker compose up)",
    'bash -c "true" && docker stop web',
  ])("blocks: %s", (cmd) => {
    expect(shouldBlock(cmd)).toBe(true);
  });
});

describe("read-only subcommands stay allowed", () => {
  test.each([
    "docker ps",
    "docker compose logs -f web",
    "docker-compose ps",
    "docker inspect web",
    "docker exec -it web sh",
    "sudo docker stats",
    "docker images | head",
    "docker compose -f prod.yml logs",
  ])("allows: %s", (cmd) => {
    expect(shouldBlock(cmd)).toBe(false);
  });

  test("a bare docker with no subcommand just prints help", () => {
    expect(shouldBlock("docker")).toBe(false);
  });
});

describe("inspectDockerCommand", () => {
  test("returns null for non-docker commands", () => {
    expect(inspectDockerCommand(["grep", "docker"])).toBeNull();
  });

  test("sees through wrappers and env assignments", () => {
    expect(inspectDockerCommand(["FOO=1", "sudo", "-S", "docker", "compose", "up"]))
      .toEqual({ subcommand: "up" });
  });

  test("skips global flags that take a value", () => {
    expect(inspectDockerCommand(["docker", "compose", "-f", "a.yml", "up"]))
      .toEqual({ subcommand: "up" });
  });
});

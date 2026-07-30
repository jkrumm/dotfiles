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
import {
  effectiveCwd,
  inspectDockerCommand,
  projectDirectories,
  shouldBlock,
  splitIntoCommands,
} from "./docker-makefile";

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

describe("the management form is classified on the verb, not the object", () => {
  // Observed in the wild: `docker inspect X` was allowed while the equivalent
  // `docker image inspect X` was denied, taking an unrelated batched command
  // down with it.
  test.each([
    "docker image inspect alpine",
    "docker image ls",
    "docker container ls -a",
    "docker container inspect web",
    "docker volume inspect rb_rb-data",
    "docker volume ls",
    "docker network inspect bridge",
    "docker system df",
    "docker buildx ls",
    "docker context ls",
    // Help output, not an action.
    "docker image",
    "docker image --help",
  ])("allows: %s", (cmd) => {
    expect(shouldBlock(cmd)).toBe(false);
  });

  test.each([
    "docker image rm alpine",
    "docker image prune -f",
    "docker container rm -f web",
    "docker container stop web",
    "docker volume prune",
    "docker volume rm rb_rb-data",
    "docker network create foo",
    "docker system prune -af",
    "docker service update web",
    "docker stack deploy -c stack.yml app",
  ])("still blocks: %s", (cmd) => {
    expect(shouldBlock(cmd)).toBe(true);
  });

  test("an object noun does not launder a write verb that shares its name", () => {
    // `build` is a verb, never an object — it must not reach the management path.
    expect(shouldBlock("docker buildx build --push .")).toBe(true);
  });
});

describe("docker build --check is a linter, not a build", () => {
  test.each([
    "docker build --check .",
    "docker build --check -f apps/api/Dockerfile .",
    "docker buildx build --check .",
    "cd ~/SourceRoot/argo && docker build --check -f apps/api/Dockerfile .",
  ])("allows: %s", (cmd) => {
    expect(shouldBlock(cmd)).toBe(false);
  });

  test.each([
    "docker build .",
    "docker build -t app:latest .",
    "docker buildx build --push .",
    // --check on a non-build subcommand is not a linter run.
    "docker compose up --check",
  ])("still blocks: %s", (cmd) => {
    expect(shouldBlock(cmd)).toBe(true);
  });

  test("a build-arg whose value merely contains --check does not open the gate", () => {
    expect(shouldBlock("docker build --build-arg MODE=--check .")).toBe(true);
  });
});

describe("effectiveCwd — the Makefile that matters is the one you cd into", () => {
  const HOME = process.env.HOME ?? "";

  test("no leading cd keeps the session cwd", () => {
    expect(effectiveCwd("docker compose up", "/tmp")).toBe("/tmp");
  });

  test("a leading cd to an absolute dir wins", () => {
    expect(effectiveCwd("cd /usr && docker compose up", "/tmp")).toBe("/usr");
  });

  test("expands a leading tilde", () => {
    expect(effectiveCwd("cd ~ && docker compose up", "/tmp")).toBe(HOME);
  });

  test("resolves a relative dir against the session cwd", () => {
    expect(effectiveCwd("cd bin && docker compose up", "/usr")).toBe("/usr/bin");
  });

  test("falls back to the session cwd when the dir does not exist", () => {
    expect(effectiveCwd("cd /nope/nowhere && docker compose up", "/tmp")).toBe("/tmp");
  });

  test("a cd that is not the first command is ignored", () => {
    expect(effectiveCwd("docker compose up && cd /usr", "/tmp")).toBe("/tmp");
  });

  test("`cd -` and bare `cd` are not directory names", () => {
    expect(effectiveCwd("cd - && docker compose up", "/tmp")).toBe("/tmp");
    expect(effectiveCwd("cd && docker compose up", "/tmp")).toBe("/tmp");
  });
});

describe("inspectDockerCommand", () => {
  test("returns null for non-docker commands", () => {
    expect(inspectDockerCommand(["grep", "docker"])).toBeNull();
  });

  test("sees through wrappers and env assignments", () => {
    expect(inspectDockerCommand(["FOO=1", "sudo", "-S", "docker", "compose", "up"]))
      .toEqual({ subcommand: "up", args: [], fileArgs: [] });
  });

  test("skips global flags that take a value", () => {
    expect(inspectDockerCommand(["docker", "compose", "-f", "a.yml", "up"]))
      .toEqual({ subcommand: "up", args: [], fileArgs: ["a.yml"] });
  });

  test("carries the tokens after the subcommand", () => {
    expect(inspectDockerCommand(["docker", "build", "--check", "."]))
      .toEqual({ subcommand: "build", args: ["--check", "."], fileArgs: [] });
  });

  test("collects -f before the subcommand, after it, and in --file= form", () => {
    const files = (tokens: string[]) => inspectDockerCommand(tokens)?.fileArgs;

    expect(files(["docker", "compose", "-f", "a.yml", "up"])).toEqual(["a.yml"]);
    expect(files(["docker", "build", "-f", "apps/api/Dockerfile", "."])).toEqual([
      "apps/api/Dockerfile",
    ]);
    expect(files(["docker", "compose", "--file=a.yml", "up"])).toEqual(["a.yml"]);
    expect(files(["docker", "compose", "-f", "a.yml", "-f", "b.yml", "up"])).toEqual([
      "a.yml",
      "b.yml",
    ]);
  });

  test("does not mistake other value flags for files", () => {
    expect(inspectDockerCommand(["docker", "compose", "-p", "proj", "up"])?.fileArgs)
      .toEqual([]);
    expect(inspectDockerCommand(["docker", "compose", "--env-file", ".env", "up"])
      ?.fileArgs).toEqual([]);
  });
});

/**
 * The regression that motivated projectDirectories: consulting only the `cd`
 * target let one prepended token switch the gate off, because the scratch dir it
 * landed in has no Makefile to deny on behalf of — while `-f` meant the command
 * still operated on a real project. A `-f` path names the project outright, so
 * it is the first thing checked, and the session cwd is kept as a backstop so a
 * Makefile-less directory anywhere in the chain cannot fail the gate open.
 */
describe("projectDirectories — a cd cannot shake off the project", () => {
  const HOME = process.env.HOME ?? "";
  const REPO = `${HOME}/SourceRoot/dotfiles`;

  test("an absolute -f puts its own directory first", () => {
    expect(projectDirectories(`cd /tmp && docker compose -f ${REPO}/x.yml up`, "/usr")[0])
      .toBe(REPO);
  });

  test("expands ~ in a -f path", () => {
    expect(
      projectDirectories("cd /tmp && docker compose -f ~/SourceRoot/dotfiles/x.yml up", "/usr")
    ).toContain(REPO);
  });

  test("resolves a relative -f against the effective cwd, not the session cwd", () => {
    expect(projectDirectories("cd /usr && docker build -f bin/Dockerfile .", "/tmp"))
      .toContain("/usr/bin");
  });

  test("keeps the session cwd as a backstop so a scratch dir cannot fail it open", () => {
    expect(projectDirectories("cd /usr && docker compose up", "/tmp")).toEqual([
      "/usr",
      "/tmp",
    ]);
  });

  test("drops directories that do not exist rather than spawning git in them", () => {
    expect(projectDirectories("docker compose -f /nope/nowhere/x.yml up", "/tmp")).toEqual([
      "/tmp",
    ]);
  });

  test("does not duplicate a directory reached two ways", () => {
    const dirs = projectDirectories("cd /usr && docker compose -f /usr/x.yml up", "/usr");
    expect(dirs).toEqual(["/usr"]);
  });
});

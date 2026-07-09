---
description: Makefile authoring conventions — default help target, 1Password signing inside make targets
paths: ["Makefile", "**/Makefile"]
---

# Makefile Conventions

- **Default target:** set `.DEFAULT_GOAL := help` and make `help` the first target, so a bare `make` prints the target list instead of running the first real target.
- **1Password in Makefiles:** always pass an explicit `--account <name>` to `op` calls inside a Makefile, and guard with a signin check — the interactive shell's cached 1Password session does not carry into `make`'s subshell:
  ```makefile
  @op whoami --account <name> >/dev/null 2>&1 || op signin --account <name>
  @op run --account <name> --env-file=... -- <cmd>
  ```
  See `prometheus-scripts/mcp-hub/Makefile` (`hub-up`) for the pattern in practice.

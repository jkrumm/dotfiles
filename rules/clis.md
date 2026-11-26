---
description: The CLIs an agent on this machine uses, what each is for, and the command that lists everything it can do
---

# CLIs on this machine

Before using a CLI for something this table or a skill does not spell out, run its list command; before writing a flag, run that verb's help.

| CLI | For | Lists everything | Skill |
|-|-|-|-|
| `agw` | web search and page reads, research, review, check, prose, images, diagrams, podcast, observability queries, vault, cheap text calls | `agw schema --index` | research, review, check, prose, img, otel, podcast |
| `factory` | issues, plans and the queue, signals, merge and deploy locks | `factory --help` | factory |
| `hc` | terminals and agents in herdr-core: run, read, send, wait | `hc --help` | herdr |
| `rd` | place work on the mini, read and steer its agents, repos | `rd --help` | remote-dev |
| `agent-note` | message an agent terminal on the other machine (mini / MacBook) and get the reply; list who takes notes | `agent-note --help` | remote-dev |
| `claude-account` | Claude Max accounts (the factory's accounts package): pick, quota, mode, expiry | `claude-account --help` | none |
| `secrets-run` | read secrets on the mini | `secrets-run --help` | secrets |
| `jobrun` | run and record a scheduled job | `jobrun --help` | mini-service |
| `shared-chrome` | the one headless Chrome | `shared-chrome --help` | browse |
| `home` | Apple Home: lights, scenes, accessories | `home --help` | home |
| `epx` | IuRoot work only: tickets, code index, wiki, read-only databases and logs | `epx schema --index` | none |
| `playwright-cli`, `chrome-devtools` | page checks, screenshots, traces; reached through `/browse` | `playwright-cli --help`, `chrome-devtools --help` | browse |

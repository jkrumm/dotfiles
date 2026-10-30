## Bottom line

**cyclopts** is at **5.3.0** (PyPI `cyclopts-5.3.0.tar.gz` / `cyclopts-5.3.0-py3-none-any.whl`, both uploaded **Oct 22, 2026**; GitHub release `v5.3.0` published 2026-10-22T14:23:22Z), requires **Python >=3.11**, license **Apache-2.0**; it derives subcommands, parameters, defaults and `--help` text from function signatures, type hints and reST-style docstrings, and it already exposes a **documented doc generator** — `App.generate_docs(output_format='markdown', …)` plus `App.command_tree()` and the shipped `cyclopts generate-docs` / `cyclopts tree` CLIs — so a Markdown/AGENTS generator is a thin wrapper over the App, not a new project.

**Of the TypeScript options, only `incur` (0.7.1) is confirmed to serve one Zod-defined procedure set as CLI + HTTP + MCP simultaneously** (`--mcp` stdio, `cli.fetch` Fetch handler with `/mcp`, plus `--llms` manifest and `--schema` JSON Schema). **`trpc-cli` (0.17.1) is confirmed CLI + HTTP from the same tRPC *or* oRPC router** but not MCP. **oRPC itself** (`@orpc/*` **1.16.1** stable) covers HTTP + OpenAPI + a type-only typed client, and gets MCP only via `@orpc/mcp`, which has **no stable release** (latest `2.0.0-beta.44`, `beta 2.0.0-beta.46`) — and `trpc-cli`'s oRPC peer range is `@orpc/server: ^1.0.0`, so CLI-via-trpc-cli and MCP-via-@orpc/mcp currently sit on different major lines. **citty (0.2.2), gunshi (0.37.3), @stricli/core (1.3.0) and @effect/cli (0.77.2) are CLI-only**, and none of them is Zod-driven (`@effect/cli` sits on Effect Schema; `@effect/schema` 0.75.5 is deprecated into the `effect` package).

**For the Bun factory core** (TypeScript, Postgres, sharing types with the TanStack/React Argo dashboard): `incur` 0.7.1 is the lowest-friction match if you want one definition → CLI for agents + HTTP for the dashboard + MCP + `--llms` docs; `oRPC` + `trpc-cli` is the better fit if the dashboard needs RPC semantics and TanStack Query integration.

**The agent-CLI contract that recurs across clig.dev, `gh` and Vercel's CLI is:** machine output to stdout / messages to stderr, a JSON flag with field projection (`--json number,title` in `gh`; Vercel now prefers `--format json` and deprecates boolean `--json` where `--format` exists), `-h/--help` on every subcommand with terse no-arg help, prompting only when stdin is a TTY *and* no agent is detected, and exit 0 on success / non-zero on failure.

---

## 1. cyclopts (Python) — current, and already introspectable

**Packaging.** 5.3.0, files uploaded Oct 22, 2026, `Requires-Python: >=3.11`, no upper bound; repo metadata: Apache-2.0 (PyPI's license field is null, so Apache-2.0 rests on the GitHub repo), not archived, last push 2026-10-23. 169 releases listed. Python 3.11 is the floor — worth noting since the Python-side tools in the prior decision may already be 3.10-era.

**How commands/help are derived.** `@app.command` registers a function; the command name is the function name with `_`→`-` and leading/trailing underscores stripped, overridable via `name=`, `alias=`, `synonym=` or a global `App.name_transform`. Every function parameter becomes a CLI parameter from its Python name + type hint; defaults come from the signature default and render as `[default: …]`, required ones as `[required]` with a `*`. `@app.default` registers the no-command action (with none registered, cyclopts prints help). Nested sub-commands are recursive sub-`App`s reachable as a dict (`app["foo"].command`) or via `sub_app = app.command(App(name="foo"))`; `name="*"` flattens a sub-app's commands into the parent.

**Typing constructs** (Coercion Rules): `str`, `int` (decimal/bin/octal/hex), `float`, `complex`, `bool` as `--flag/--no-flag`, `None` via `"none"/"null"`, `list`/`Iterable`/`Sequence`/`Set`/`frozenset`/`Tuple` (nesting; `tuple[T, ...]` only at root), `dict` via `--mapping.KEY`, `Union` (left-to-right, first success), `Optional`, `Literal` (case-sensitive), `Enum` (matched by **name**, not value), `Flag`/`IntFlag`, `date`, `datetime`, `timedelta` (`30s`, `1h30m`), `slice`, and user classes: **attrs, dataclass, NamedTuple, pydantic, TypedDict**, expanded into dotted sub-keys with JSON dict/list parsing and `Parameter(name="*")` flattening. Verbatim on the important one: *"For pydantic classes, Cyclopts will not internally perform type conversions and instead relies on pydantic's coercion engine."*

**Docstrings → help.** First docstring block is the short description (the command summary in the Commands panel), text after the first blank line is the long description, and a `Parameters\n----------\nname: type\n    description` section supplies per-parameter help (docstrings must use the *Python* name even when `Parameter(name=...)` renames the flag). Precedence for command help: `@app.command(help=…)` > `App.help` > docstring; `Parameter(help=…)` beats a docstring parameter entry; class/field docstrings feed parameter help but a command-docstring entry wins. `App.help_format` selects markup (`plaintext`, `markdown`/`md` default, `restructuredtext`/`rst`) and inherits to sub-apps — note the docs prose also describes a `"rich"` mode that the documented `Literal` type does not include (API signature vs prose disagree; treat `markdown` as the safe value).

**Non-interactive by default.** There is **no per-parameter prompt** — the documented `cyclopts.Parameter(...)` signature has no `prompt` field. The only prompt knob is `App.interactive_shell(prompt='$ ', …)`, an opt-in blocking REPL. For embedding: `exit_on_error=False, print_error=False, help_flags=[], result_action="return_value"`.

**Introspection / docs generation — the key win for AGENTS.md.** `App.generate_docs(output_format='markdown', recursive=True, include_hidden=False, heading_level=1, max_heading_level=6, flatten_commands=False, usage_name=None) -> str` (accepts `markdown/md`, `html/htm`, `rst/rest/restructuredtext`), `App.command_tree(*, description=True, include_hidden=False, max_depth=None) -> Tree`, `App.help_print(...)`, `App.parse_commands(...) -> (tuple[str,...], tuple[App,...], list[str])`, `App.parse_args(...) -> (callable, BoundArguments, dict)`. Shipped CLIs: `cyclopts generate-docs [OPTIONS] SCRIPT [ARGS]` (`-o/--output`, `-f/--format` with the same three families, `--include-hidden`, `--heading-level`, `--usage-name`) and `cyclopts tree SCRIPT` (`-d/--description`, `-m/--max-depth`). I found **no `App.to_dict`, JSON-output flag, or JSON-Schema export** in the reference passages read — the introspection surface is a Python object graph plus text/markup renderers, so a JSON routing table has to be walked off `command_tree()`/`app[...]`.

**Minimal shape** (assembled from documented APIs, not executed):

```python
import cyclopts
from typing import Annotated, Literal
from pydantic import BaseModel

app = cyclopts.App(name="factory", help="Factory CLI.")

class DeployCfg(BaseModel):
    replicas: int = 2
    region: Literal["us", "eu"] = "us"

@app.command
def deploy(env: Literal["dev", "staging", "prod"],
           cfg: Annotated[DeployCfg, cyclopts.Parameter(name="*")] = DeployCfg()):
    """Deploy a service.

    Parameters
    ----------
    env
        Target environment.
    cfg
        Deployment settings.
    """

@app.command
def status(job: str, *, follow: bool = False):
    """Show job status."""

@app.default
def main():
    """Print help when no command is given."""
    app.help_print()

if __name__ == "__main__":
    app()
```

Help renders as a `Usage:` line + short description, a `╭─ Commands ─╮` panel (each command + docstring summary, plus `--help -h` and `--version`), and per-command `╭─ Parameters ─╮` panels with `* NAME --name <help> [choices: …] [required]` / `[default: …]` rows.

## 2. TypeScript: what actually serves one procedure set three ways

| Package (latest) | Schema-driven | CLI | + HTTP | + MCP | Docs/manifest output | Bun |
|---|---|---|---|---|---|---|
| **incur 0.7.1** (MIT, 2026-10-14) | zod ^4.3.6 (bundled re-export) | ✅ | ✅ `cli.fetch` | ✅ `--mcp` stdio + `/mcp` | `--llms`, `--schema`, `--format toon\|json\|yaml\|md\|jsonl`, `skills add`, `mcp add`, `incur gen/build` | ✅ (`bun i incur`, `Bun.serve(cli)`) |
| **trpc-cli 0.17.1** (Apache-2.0, 2026-10-01) | zod/arktype/valibot/effect/typebox via JSON Schema | ✅ (commander ^14) | ✅ same router | ✗ not in README | `.toJSON()`, `deepHelp(program)` | ✅ (TS-module mode under bun) |
| **oRPC `@orpc/*` 1.16.1** | Standard Schema (zod/valibot/arktype) | ✗ (no CLI page) | ✅ RPC + OpenAPI 3.2 + typed client | ⚠️ `@orpc/mcp` beta only | OpenAPI spec from the same router | ✅ (Fetch adapter; Bun playground, Elysia adapter) |
| citty 0.2.2 | ✗ declarative `{type:'positional'\|'string'\|'boolean'\|'enum'}` | ✅ | ✗ | ✗ | — | not documented |
| gunshi 0.37.3 | ✗ args-tokens declarative | ✅ | ✗ | ✗ (`gunshi/agent` detects agents) | pluggable renderers | ✅ documented ("Node.js, Deno, Bun") |
| @stricli/core 1.3.0 | not shown (no code sample read) | ✅ | ✗ | ✗ | publishes *its own* llms.txt for its docs | not verified |
| @effect/cli 0.77.2 | Effect Schema (peers `effect`, `@effect/platform`, `@effect/printer*`) — no zod peer | ✅ | ✗ | ✗ | — | not verified |

**incur** is the only package confirmed to give CLI + HTTP + MCP from one definition:

```ts
import { Cli, z } from 'incur';
Cli.create('greet', {
  description: 'A greeting CLI',
  args: z.object({ name: z.string().describe('Name to greet') }),
  run(c) { return { message: `hello ${c.args.name}` } },
}).serve();
```

Multi-command is chained `.command('name', { args, options, env, output, run })`; `--mcp` starts an MCP stdio server, `mcp: false` hides a command from MCP, and `cli.fetch` is a standard Fetch handler (`Bun.serve(cli)`, `Deno.serve(cli.fetch)`, Cloudflare default export, Hono/Elysia/Next) that routes path segments to commands and auto-exposes `/mcp`. Standard Schema support is not mentioned in its README — it is a zod-4 house style (README imports `{ Cli, z } from 'incur'`).

**trpc-cli** — `createCli({router}).run()`; procedure names → kebab-case commands (`squareRoot` → `square-root`), nested routers → subcommands (`mycli search byId --id 123`), `z.object` fields → `--flags`, scalars and `z.tuple` → positionals, `z.array` → variadic. **oRPC is officially supported** — *"it needs to be an `@orpc/server` router, not an `@orpc/contract`"*, and lazy procedures need `unlazyRouter()`. It explicitly positions one router as CLI + HTTP ("use the same router for a CLI and an HTTP server"). Caveat: `--json <json>` is an **input** mechanism (`jsonInput: 'never'|'auto'|'always'`, "especially useful for machine-generated invocations (e.g. an LLM calling your CLI)"), not an output format; for piped output you swap the default `yamlTableConsoleLogger` for `lineByLineConsoleLogger` (JSON.stringify).

**oRPC** as the HTTP layer: `os` builder with optional `.input(schema)` then `.handler(async ({input, context, errors}) => …)`; routers are plain nested objects; `.output` is optional and client types flow from the handler return. `new OpenAPIGenerator({ converters: [new ZodToJsonSchemaConverter()] })` then `await generator.generate(router, { version: '3.2.0', base: { info, servers } })` (default 3.2.0; older versions are downgrades of the 3.2 doc). **Operation metadata is not inferred from Zod** — method/path/`operationId`/summary/description/tags come from `openapi({...})`; schema-level `description`/`examples` need `JSON_SCHEMA_REGISTRY` / `JSON_SCHEMA_INPUT_REGISTRY` / `JSON_SCHEMA_OUTPUT_REGISTRY` from `@orpc/zod`. Clients need no codegen: `createORPCClient(new RPCLink({origin, url}))` typed as `RouterClient<typeof router>` via a type-only import, or `OpenAPILink(contract, {...})` typed `JsonifiedClient<...>` (needs the contract at runtime unless you use the build-time macro). MCP: `new McpRegistrar(router)` → `registrar.register(server, { context })`, tool names from `operationId`, "tool calls run through the same standard handler as the RPC and OpenAPI handlers".

**Version-line mismatch to plan around:** stable `@orpc/*` is **1.16.1**, `@orpc/mcp` exists only as `2.0.0-beta.44`/`2.0.0-beta.46`, orpc.dev now documents v2 beta (install `@orpc/server@beta`, v1 docs at v1.orpc.dev), and `trpc-cli`'s oRPC peer range is `@orpc/server: ^1.0.0`. Choosing this stack means running trpc-cli against v1 while MCP requires the v2 beta — the one combination that is *not* demonstrated end-to-end in any doc read.

## 3. Recommended shape for the Bun factory core

- **Fewest moving parts → `incur` 0.7.1.** One `Cli.create`/`.command` tree gives the agent CLI, `Bun.serve(cli)` for the dashboard's HTTP needs, MCP at `/mcp`, `--llms` (Markdown or JSON manifest) for AGENTS.md, `--schema` JSON Schema per command, `--format toon|json|yaml|md|jsonl`, and `incur build` for standalone Bun binaries. Cost: zod-only (no Standard Schema claim), young (0.7.x), and its OpenAPI/`@scalar/openapi-types` dependency is present but OpenAPI *generation* was not verified.
- **Dashboard-first → oRPC 1.16.1 + trpc-cli 0.17.1.** You get RPC + OpenAPI 3.2 + type-only client + `@orpc/tanstack-query` (peer `@tanstack/query-core >=5.80.2`) / `@orpc/react-query` for the TanStack/React surface, and trpc-cli turns the same router into the agent CLI. Defer `@orpc/mcp` until it leaves beta, or run the MCP beta separately.
- Either way, keep the "one typed definition" discipline: cyclopts' `App.generate_docs`/`command_tree` on the Python side, `incur --llms`/`--schema` or trpc-cli `.toJSON()`/`deepHelp(program)` on the TS side, and one generator that emits both human Markdown reference and the AGENTS.md routing table from that output.

## 4. Agent-facing CLI checklist (sourced)

1. **Machine output on stdout, everything else on stderr** so piped commands never ingest log lines. JSON as an opt-in flag.
2. **Pick `--format json`, keep `--json` as an alias.** Vercel: "For machine-readable output, prefer `--format json` where a command documents it; the boolean `--json` is deprecated on commands that also support `--format`." `gh` uses plain `--json <fields>` and, when the field list is omitted, **prints the available field names** — a cheap self-documenting projection (`--jq`/`--template` are only valid with `--json`). Field projection is also the single biggest token saver.
3. **`--help` is the contract.** clig.dev: help on `-h/--help` for every subcommand, ignore other args when `-h` is appended, and keep the no-arg form to description + 1–2 examples + a pointer to `--help`. Vercel's MCP documentation tool literally "instructs the LLM to use Vercel CLI commands with `--help`".
4. **Non-interactive by default.** clig.dev: prompt only when stdin is a TTY, `--no-input` to disable, `-f/--force`, `--dry-run`, `--quiet`, `-o/--output`. Vercel auto-sets `--non-interactive` **only when an agent is detected and stdin is not a TTY**, and keeps `--yes` per-command. trpc-cli goes furthest: prompts only when stdin is a TTY **and** no agent env is detected (`isAgent()` covers Claude Code, Codex, opencode), so piped/CI/agent runs get a missing-argument error instead of hanging.
5. **Exit codes:** zero on success, non-zero on failure, mapped to the important failure modes (clig.dev); trpc-cli ships the 0-or-1 minimal version. No source read prescribes a numeric taxonomy for usage-vs-runtime-vs-auth.
6. **Token-lean:** disable colour when not a TTY / `NO_COLOR` / `TERM=dumb` / `--no-color`; pager and progress bars only on a TTY; narrow calls and pre-shape responses rather than dumping payloads (Vercel's own agent guidance).
7. **Credentials from env, not flags** (Vercel prefers `VERCEL_TOKEN` over `--token` to keep secrets out of shell history).
8. **llms.txt is real in the wild** (trpc.io publishes `/llms.txt` with versioned variants; Claude Code publishes `.md` twins of its docs) — but the concrete "`--llms` flag" implementation here is incur's, and no source read defines an AGENTS.md routing-table standard.

## What remains open / where sources disagree

- **trpc-cli's MCP, `llms.txt` and AGENTS.md generation**: absent from the README, but the README was truncated at 61,114 of 66,631 characters, so absence there is not proof of absence in the package.
- **Stricli's definition shape** (schema-driven vs hand-written) and **@effect/cli's code shape** were not read from docs; only npm metadata (zero deps / Effect peers) is verified. gunshi findings rest on its README only. Bun support for citty and @stricli/core is undocumented in the pages read.
- **Cyclopts**: whether `generate_docs`/`command_tree` shipped in 5.3.0 specifically (they appear in the `/en/latest/` API page and in a v4.11.0 PDF), plus Google/NumPy docstring styles, are not confirmed; its `help_format` prose and `Literal` type disagree on `"rich"`; and no JSON/JSON-Schema command-tree export exists in the reference passages read.
- **oRPC**: minimum Bun/Node versions, the npm-publish client recipe body, and v1-specific generator identifiers (`schemaConverters` vs v2 `converters`) are unverified.
- **Convention conflict worth a decision, not a lookup:** `--json` (gh, clig.dev) vs `--format json` (Vercel, going forward) and TTY-conditional default JSON (Arcjet's practitioner approach) are three different houses; pick one and document it in AGENTS.md.


# Research: 2026-10-22-ts-cli-introspection

Job `267dcc12-3acc-4f11-81fd-79b66a980038` · depth standard · status ok

**Query:** TypeScript/Bun CLI frameworks with an introspectable command tree, verified as of October 2026, for an agent-first CLI contract: which libraries let a program enumerate its full command tree (commands, subcommands, options, types, help text) at runtime so help, Markdown docs, JSON Schema for inputs/outputs and a drift check can be generated from one definition? Compare clipanion (cli.definitions()), @effect/cli, oclif (manifest), commander (program.commands introspection), citty, cac, gunshi, yargs, @stricli/core, and any 2026 newcomers; for each: latest version and date, licence, Bun compatibility, introspection API, typed options (Zod/Valibot/TypeBox/Effect Schema integration), generated docs support, JSON Schema export, startup time, maintenance status. Also: libraries that generate a CLI from existing JSON Schema / Zod tool definitions (e.g. MCP tool schemas → CLI). Python baseline for comparison is cyclopts + pydantic v2 (cyclopts' generate_docs, introspectable App).

## Bottom line

- **No framework in this list exposes a fully typed runtime command tree from one definition.** The closest are **yargs** (`.getOptions()` returns the whole option dictionary with `type`, `choices`, `default`, `demandOption`, `desc`), **oclif** (`oclif manifest` → `oclif.manifest.json`), **commander** (`commands` / `options` / `registeredArguments` as live objects) and **gunshi** (`subCommands` as `Record|Map` plus an `args` schema); **clipanion's `definitions()` and `effect/cli`'s `Command` give you structure but not typed option metadata**, so both require a parallel spec.
- **Only clipanion is stale**: 4.0.0-rc.4, published 2024-09-06, a release candidate that has never cut a stable or GitHub release. Everything else is current as of October 2026 — @oclif/core 5.1.9 (2026-10-19), oclif 6.0.10 (2026-10-18), cac 7.1.0 (2026-10-11), gunshi 0.37.3 (2026-10-02), commander 15.0.0 (2026-09-02), yargs 18.2.0 (2026-09-20), @effect/cli 0.77.2 (2026-09-18) with the live CLI now shipping as `effect/cli` inside effect 4.0.5 (2026-10-16), citty 0.2.2 (2026-08-20), @stricli/core 1.3.0 (2026-07-16).
- **No framework documents a JSON Schema emitter for command inputs or outputs.** One ships Markdown generation out of the box (oclif's `readme` command); two ship whole-tree text generation (`@stricli/core` `generateHelpTextForAllCommands`, gunshi `generate()`); everything else means walking the tree yourself.
- **Only bunli verifiably integrates a schema library** (`option(z.enum([...]))`, `zod ^4.3.6`) and ships an agent-skill plugin. There is **no official Zod/Valibot/TypeBox/Effect Schema adapter for commander, yargs, citty, cac, gunshi, @stricli/core, clipanion (typanion) or oclif** — all are hand-rolled parsers.
- **No npm package surfaced that turns a JSON Schema or an MCP `tools/list` into a per-tool subcommand CLI with per-command schemas.** The adjacent tools are OpenAPI-side (`spec2cli`, `@tronsfey/openapi2cli`) or hosted (Fern CLI generator).
- **Bun `--compile` preserves schema objects defined in code but breaks path-based resolution, and a standalone executable does not load `package.json`/`tsconfig.json`** — so version/manifest must be `--define`d or embedded.
- **No reliable startup-time number exists** for any of these frameworks under Bun or Node; cyclopts + pydantic v2 remains the yardstick because `App` is simultaneously the introspection surface, the docs generator, and (via pydantic) the JSON Schema source — no TS framework gives you that single object.

## The introspection axis, ranked by what a generator can actually read

**Tier 1 — plain data, types recoverable.** citty's `defineCommand()` returns an inspectable object (`meta`, `args`, `subCommands`, `default`), and `resolveSubCommand` / `renderUsage` consume the same object. commander's `Command` holds `commands`, `options`, `registeredArguments`, with `Help#visibleCommands` / `visibleOptions` / `visibleArguments` doing the walk and hidden items flagged. gunshi's `Command.subCommands` is `Record<string, SubCommandable> | Map<…>` (since v0.28.0) and `args` stays a schema with `type`, `short`, `required`, `description`. @stricli/core nests `buildRouteMap({routes, defaultCommand, aliases})` maps whose targets are commands or further maps. yargs exposes the richest single call: `.getOptions()` returns `type`, `choices`, `default`, `demandOption`, `desc`, `hidden`, `group`, `array`, `coerce`. (The yargs docs *site* index read only lists `.getHelp()` and `.getCompletion()`; the repository API reference documents `.getOptions()`. Treat it as documented but thinly covered.) oclif's artifact is `oclif.manifest.json`, written by `oclif manifest [path]`, typed `Manifest = {commands: Record<string, Command.Cached>, version: string}`.

**Tier 2 — structure without types.** clipanion: `Cli#definitions({colored?}) → Array<Definition>`, `Cli#definition(cls) → Definition | null`, mirrored on the `MiniCli` handed to commands as `this.cli`. `Definition = Usage & {path: string; usage: string; options: Array<{preferredName: string; nameSet: Array<string>; definition: string; description?: string; required: boolean}>}` with `Usage = {category?, description?, details?, examples?}`. There is **no `name`, no `type`, no `arity`, no default, and no positionals array** — values are flattened into rendered `path`/`usage`/`definition` strings, so you cannot emit JSON Schema without re-deriving types from the option constructors. Note also that `definition()` returns null when `commandClass.usage` is undefined, so undocumented commands silently vanish from the tree. `effect/cli` v4: `Command` is a callable Effect value with readable `name`, `description`, `shortDescription`, `alias`, `examples`, `annotations`, `unlisted` and `subcommands: ReadonlyArray<{group, commands}>`, and the docs demonstrate traversal (`root.subcommands[0].commands[0].unlisted`). **Flag metadata is not public** — configuration is consumed at construction and survives only at the type level via `Command.Config.Infer<Config>`; `Param.Param<Kind, Value>` exposes `.kind` on the config object *you wrote*, not on the built `Command`. The module is marked `unstable` in the v4 API reference.

**Tier 3 — rendered text only.** cac: `cli.parse()` returns `{args, options}` and `cli.help(cb)` hands you mutable `HelpSection[]`; the README documents no command-table property, so help generation is text-level.

## Per-library fact sheet (versions verified against npm, October 2026)

| Library | Latest (date) | Licence | Introspection | Typed options / adapters | Bun |
|---|---|---|---|---|---|
| clipanion | 4.0.0-rc.4 (2024-09-06) | MIT | `definitions()` / `definition(cls)`, strings only | typanion `Command.schema: LooseTest[]` applied in `validateAndExecute()`; no Zod/Valibot/TypeBox bridge | not verified |
| @effect/cli | 0.77.2 (2026-09-18); live API is `effect/cli` in effect 4.0.5 (2026-10-16) | MIT | `Command.subcommands` walkable; no flag accessor | `Flag.String/Int/Boolean`, `Argument.String/variadic`; no Schema-accepting flag constructor documented | not verified |
| oclif / @oclif/core | 6.0.10 (2026-10-18) / 5.1.9 (2026-10-19) | MIT | `oclif manifest [path]` → `oclif.manifest.json` | static `args`/`flags` with `options`, `default`, `required`, `description`; no adapters | `engines.node >=22.0.0`; otherwise unverified |
| commander | 15.0.0 (2026-09-02) | MIT, 0 deps | `commands`, `options`, `registeredArguments` | hand-rolled; no adapters | `engines.node >=22.12.0`; unverified |
| yargs | 18.2.0 (2026-09-20) | MIT | `.getOptions()`, `.getHelp()`, `.commandDir()` (flattens `recurse`) | no adapters | `^20.19 \|\| ^22.12 \|\| >=23`; unverified |
| citty | 0.2.2 (2026-08-20) | MIT, 0 deps | plain `CommandDef` object | no adapters | unverified |
| cac | 7.1.0 (2026-10-11) | MIT, 0 deps | `HelpSection[]` only | no adapters | `>=20.19.0`; unverified |
| gunshi | 0.37.3 (2026-10-02) | MIT, 0 deps | `subCommands` + `args` schema + `generate()` | no adapters | Bun documented (`Bun.argv.slice(2)`) |
| @stricli/core | 1.3.0 (2026-07-16) | Apache-2.0 | route-map objects, `generateHelpTextForAllCommands` | no adapters | unverified |
| bunli | 0.9.1 (2026-04-09) | MIT | `createCLI` / `defineCommand` / `option` / `defineGroup` | `option(z.enum([...]), {description})`, `zod ^4.3.6`, Standard Schema | Bun-native, compiles to standalone binaries |

Two flags: **gunshi's docs render under a `v1.0.0-rc.1` badge while npm `latest` is 0.37.3** (dist-tags also carry `beta: 1.0.0-beta.2`, `rc: 1.0.0-rc.1`) — pin the exact version. **clipanion's dependency typanion** is itself at 3.14.0, published 2023-08-11.

## Generating help, docs, JSON Schema and a drift check from one definition

**Help** is universal: clipanion's `Cli#usage()` derives the usage line from `static paths` + declared options with `Command.Usage({category, description, details, examples})` metadata; commander `createHelp()`/`configureHelp()`/`formatHelp`; yargs `.getHelp()` (a promise of the rendered string); oclif static `args`/`flags`/`examples`/`description`/`summary`/`aliases`; citty `renderUsage`; gunshi's renderer plugin; cac `help(cb)`.

**Markdown**: only oclif. Its bundled `readme` command writes README.md from live command metadata.

**JSON Schema**: none of the retrieved framework docs documents an emitter. Build it: yargs `getOptions()` for enums/required/defaults; oclif `Flags.string({options, default, required, description})` plus a serialisable `Plugin.manifest`; commander's three arrays; clipanion's `definitions()` (insufficient — no types); **Effect is the one stack with a documented types→JSON Schema path** (`Schema` → JSON Schema, covering output types too), but its CLI layer exposes no flag reflection, so you would author the Schema separately from the Flag definitions. The v3→v4 migration guide records breaking churn — pin versions.

**Drift check** is feasible in every framework provided you generate from *definitions*, never argv: emit a sorted IR from `definitions()`, `getOptions()`, the oclif manifest, or the plain objects of citty/gunshi/stricli; commit Markdown + JSON Schema + contract tables; diff in CI. commander and yargs expose registration-ordered arrays, so sort explicitly.

**Contract mapping** (all app-level, per the decided design): implement `--format`/`--fields`/`--limit`/`--out`/envelope/typed errors/`--commit` as shared middleware and declare each as a real option with an enum constraint (`choices` in yargs/commander, `options` in oclif) so they appear in generated docs; `schema [cmd]` is an ordinary subcommand printing generated JSON Schema; one exit-code const module feeds both the error handler and the docs table.

## Schema layer for the Elysia gateway

Zod **4.6.7** (2026-10-12, MIT) ships first-party `z.toJSONSchema()`: Draft 2020-12 by default, `io: "input"|"output"` (default output — use `input` when generating from argv), metadata from `z.globalRegistry`, `$defs` via `reused: "ref"`, cycles as `$ref`, throws on unrepresentable types. `z.fromJSONSchema()` is explicitly experimental. `zod-to-json-schema` **3.25.2 is archived** — do not add it on Zod 4.

TypeBox values **are** JSON Schema ("in-memory JSON Schema objects… passed directly to any compliant validator"), so a TypeBox-defined CLI needs zero conversion. There are two package lines: **`typebox` 1.4.3** (2026-10-22, ESM-only, native 2020-12) and **`@sinclair/typebox` 0.34.52** (2026-07-16, ESM+CJS). Elysia **1.4.30** (2026-10-19) pins peer `@sinclair/typebox >=0.34.0 <1`, so an Elysia 1.x gateway is on the **0.34.x** line — `npm i typebox` installs a different package. Elysia's `t` is a TypeBox-based builder giving runtime validation, coercion, TS type and OpenAPI schema from one source, and Elysia also accepts Standard Schema validators (Zod, Valibot, ArkType, Effect Schema) directly as `params`/`query`/`body`/`response`. Practical shape: one `models.ts`; the TypeBox side needs no conversion, the Zod side goes through `z.toJSONSchema()`.

Validation: **ajv 8.20.0** (2026-04-24) defaults to draft-07; draft-2020-12 is a separate class and cannot share an instance with earlier drafts, and no formats are bundled (`ajv-formats` required). Since Zod emits 2020-12 by default, instantiate the 2020-12 Ajv class. Ajv under Bun is unverified; TypeBox's own `Schema.Compile()` is the alternative.

## JSON Schema / OpenAPI / MCP → runnable CLI

- **Fern CLI generator** — generates from OpenAPI or a GraphQL introspection schema into "a single statically linked Rust binary", marketed for agents needing "runtime-introspectable schemas"; labelled "Beta / Early access", "Reach out to get started". A hosted generator, not a Bun library.
- **`spec2cli` 0.9.0** (MIT, 2026-08-03, `node>=18`) — reads OpenAPI 3.x/Swagger 2.0 *at runtime*, "no code generation, no build step"; depends on `commander@^13`.
- **`@tronsfey/openapi2cli` 1.0.17** (MIT, 2026-03-29, `node>=18`) — generate or proxy an OpenAPI 3.x spec as a typed Commander.js CLI; one published version, thin signal.
- **`f/mcptools`** (Go, MIT; binaries `mcp`/`mcpt`) — the inverse bridge: a generic MCP *client* (`mcp tools`, `mcp call <tool> --params '{...}'`, `--format table|json|pretty`) plus `mock`/`proxy`/`guard` for exposing shell commands as MCP tools. It does **not** create one subcommand per tool, so it does not satisfy the contract.
- Bun runnability of spec2cli and openapi2cli is **unverified**.

## 2026 entrants

**bunli** 0.9.1 (MIT, 2026-04-09) is the only genuinely new Bun-first framework: `@bunli/core`, `@bunli/tui`, `@bunli/test`, `@bunli/generator`, plugins `-ai-detect`, `-completions`, `-config`, `-mcp` ("MCP integration for agentic workflows") and **`@bunli/plugin-skills` — "Sync CLI commands as agent skill files for AI coding agents"**. It compiles to standalone binaries via Bun. Signal is thin: 96 stars, 5 forks, 21 open issues, created 2025-06-16, last push 2026-06-17, latest release 0.9.1 on 2026-04-09 — roughly two months without commits as of mid-2026, single organisation. **Optique** is positioned against commander/yargs-style frameworks with Standard Schema integration (Zod/Valibot/ArkType) and `@optique/man` man-page generation — man pages, not Markdown reference docs or per-command JSON Schema.

## Bun `--compile` implications

`bun build --compile` bundles entrypoint + imports + runtime, cross-compiling to `bun-{linux,windows,darwin}-{x64,arm64}` (+musl). Embedding: `with { type: "file" }` yields an internal `/$bunfs/` path; `--asset`/`compile.assets` embeds trees under `import.meta.dir`; `Bun.embeddedFiles` lists embedded assets and `Bun.isStandaloneExecutable` detects the mode. **Critical for a CLI contract:** standalone executables do **not** load `tsconfig.json` or `package.json` at runtime by default (`.env` and `bunfig.toml` are loaded) — so version, manifest and any shipped schema must be `--define`d or embedded rather than read from disk. `--compile` rejects `--outdir`, `--no-bundle` and `--target=node`; workers must be declared as extra entrypoints. Bun issue #13405 reports `createRequire(import.meta.url).resolve()` / `Bun.resolve(…, import.meta.url)` resolving relative to cwd inside a compiled binary, with the thread's workaround reading from `Bun.embeddedFiles` — i.e. **schema objects defined in code survive compilation; path-based resolution does not**. Introspection survives compilation; file discovery does not.

## Cyclopts as the parity yardstick

Cyclopts' `App` is the introspection surface *and* the docs generator: `App.generate_docs()` emits documentation from the docstring-introspected command tree, with pydantic v2 supplying JSON Schema, and no separate codegen step. No TS framework in scope offers one object that does all three — oclif comes closest (manifest + README) and Effect closest on schema fidelity (Schema → JSON Schema), but neither unifies them.

**Practical consequence for the TS side**: pick the framework whose command definitions are plain data (gunshi, citty, commander, oclif or yargs) and treat your own emitted IR — not the framework's API — as the contract's source of truth, then generate Markdown, JSON Schema and the drift diff from that IR. Choose Effect only if output-side JSON Schema is a hard requirement and you accept the v4 churn; avoid clipanion unless you want to maintain a parallel typed spec for a package frozen at an RC since September 2024.

**Not verified:** oclif's per-command/per-flag manifest field list (`Command.Cached`); clipanion's runtime producer behind `Definition.options`; the @effect/cli v3 Command interface and its deprecation notice; Effect Schema composition with `Flag`/`Argument`; commander's `Option` property names; Stricli's `buildCommand` docs; Bun compatibility for clipanion/effect/oclif/commander/yargs/citty/cac/stricli; maintenance cadence and download volumes for the second tier; Elysia's OpenAPI plugin API; and any methodology-bearing Bun/Node startup benchmark (the one comparison article surfaced is a vendor-style blog without reproducible measurements).

## Citations

- [https://www.npmjs.com/package/clipanion](https://www.npmjs.com/package/clipanion) — confidence high
- [https://github.com/arcanis/clipanion](https://github.com/arcanis/clipanion) — confidence medium
- [https://github.com/arcanis/clipanion/blob/HEAD/sources/advanced/Cli.ts](https://github.com/arcanis/clipanion/blob/HEAD/sources/advanced/Cli.ts) — confidence high
- [https://github.com/arcanis/clipanion/blob/HEAD/sources/advanced/Command.ts](https://github.com/arcanis/clipanion/blob/HEAD/sources/advanced/Command.ts) — confidence high
- [https://github.com/arcanis/clipanion/blob/HEAD/sources/advanced/Command.ts](https://github.com/arcanis/clipanion/blob/HEAD/sources/advanced/Command.ts) — confidence high
- [https://www.npmjs.com/package/typanion](https://www.npmjs.com/package/typanion) — confidence high
- [https://www.npmjs.com/package/@effect/cli](https://www.npmjs.com/package/@effect/cli) — confidence high
- [https://www.npmjs.com/package/effect](https://www.npmjs.com/package/effect) — confidence high
- [https://github.com/Effect-TS/effect/blob/HEAD/packages/effect/src/cli/Command.ts](https://github.com/Effect-TS/effect/blob/HEAD/packages/effect/src/cli/Command.ts) — confidence high
- [https://github.com/Effect-TS/effect/blob/HEAD/packages/effect/src/cli/Command.ts](https://github.com/Effect-TS/effect/blob/HEAD/packages/effect/src/cli/Command.ts) — confidence high
- [https://effect.website/docs/v4/api/effect/cli/Command](https://effect.website/docs/v4/api/effect/cli/Command) — confidence high
- [https://www.npmjs.com/package/oclif](https://www.npmjs.com/package/oclif) — confidence high
- [https://github.com/oclif/core](https://github.com/oclif/core) — confidence high
- [https://github.com/oclif/oclif/blob/HEAD/src/commands/manifest.ts](https://github.com/oclif/oclif/blob/HEAD/src/commands/manifest.ts) — confidence medium
- [https://github.com/oclif/core/blob/HEAD/src/interfaces/manifest.ts](https://github.com/oclif/core/blob/HEAD/src/interfaces/manifest.ts) — confidence high
- [https://github.com/oclif/oclif/blob/HEAD/src/commands/readme.ts](https://github.com/oclif/oclif/blob/HEAD/src/commands/readme.ts) — confidence high
- [https://github.com/oclif/core/blob/main/_autodocs/api-reference/command.md](https://github.com/oclif/core/blob/main/_autodocs/api-reference/command.md) — confidence high
- [https://github.com/oclif/core/blob/main/_autodocs/api-reference/plugin.md](https://github.com/oclif/core/blob/main/_autodocs/api-reference/plugin.md) — confidence medium
- [https://www.npmjs.com/package/commander](https://www.npmjs.com/package/commander) — confidence high
- [https://github.com/tj/commander.js/blob/master/lib/command.js](https://github.com/tj/commander.js/blob/master/lib/command.js) — confidence high
- [https://github.com/tj/commander.js/blob/master/lib/help.js](https://github.com/tj/commander.js/blob/master/lib/help.js) — confidence high
- [https://github.com/tj/commander.js/blob/master/docs/help-in-depth.md](https://github.com/tj/commander.js/blob/master/docs/help-in-depth.md) — confidence high
- [https://www.npmjs.com/package/yargs](https://www.npmjs.com/package/yargs) — confidence high
- [https://github.com/yargs/yargs/blob/main/docs/api.md](https://github.com/yargs/yargs/blob/main/docs/api.md) — confidence high
- [https://yargs.js.org/docs/](https://yargs.js.org/docs/) — confidence high
- [https://github.com/yargs/yargs/blob/main/docs/api.md](https://github.com/yargs/yargs/blob/main/docs/api.md) — confidence high
- [https://www.npmjs.com/package/citty](https://www.npmjs.com/package/citty) — confidence high
- [https://github.com/unjs/citty/blob/main/_autodocs/api-reference/command.md](https://github.com/unjs/citty/blob/main/_autodocs/api-reference/command.md) — confidence high
- [https://github.com/unjs/citty/blob/main/_autodocs/api-reference/usage.md](https://github.com/unjs/citty/blob/main/_autodocs/api-reference/usage.md) — confidence high
- [https://www.npmjs.com/package/cac](https://www.npmjs.com/package/cac) — confidence high
- [https://github.com/cacjs/cac/blob/HEAD/README.md](https://github.com/cacjs/cac/blob/HEAD/README.md) — confidence high
- [https://github.com/cacjs/cac/blob/HEAD/README.md](https://github.com/cacjs/cac/blob/HEAD/README.md) — confidence high
- [https://www.npmjs.com/package/gunshi](https://www.npmjs.com/package/gunshi) — confidence high
- [https://gunshi.dev/api/default/interfaces/Command](https://gunshi.dev/api/default/interfaces/Command) — confidence high
- [https://gunshi.dev/api/default/interfaces/Command](https://gunshi.dev/api/default/interfaces/Command) — confidence high
- [https://gunshi.dev/guide/advanced/docs-gen](https://gunshi.dev/guide/advanced/docs-gen) — confidence high
- [https://gunshi.dev/guide/essentials/getting-started](https://gunshi.dev/guide/essentials/getting-started) — confidence high
- [https://www.npmjs.com/package/@stricli/core](https://www.npmjs.com/package/@stricli/core) — confidence high
- [https://bloomberg.github.io/stricli/packages/core/functions/generateHelpTextForAllCommands.md](https://bloomberg.github.io/stricli/packages/core/functions/generateHelpTextForAllCommands.md) — confidence medium
- [https://github.com/bloomberg/stricli/blob/main/docs/docs/features/command-routing/route-maps.mdx](https://github.com/bloomberg/stricli/blob/main/docs/docs/features/command-routing/route-maps.mdx) — confidence high
- [https://www.npmjs.com/package/bunli](https://www.npmjs.com/package/bunli) — confidence high
- [https://bunli.dev/docs](https://bunli.dev/docs) — confidence high
- [https://bunli.dev/docs/api](https://bunli.dev/docs/api) — confidence high
- [https://github.com/AryaLabsHQ/bunli/blob/HEAD/README.md](https://github.com/AryaLabsHQ/bunli/blob/HEAD/README.md) — confidence high
- [https://github.com/AryaLabsHQ/bunli](https://github.com/AryaLabsHQ/bunli) — confidence high
- [https://optique.dev/compare/](https://optique.dev/compare/) — confidence medium
- [https://buildwithfern.com/learn/cli-generator/get-started/overview](https://buildwithfern.com/learn/cli-generator/get-started/overview) — confidence high
- [https://www.npmjs.com/package/spec2cli](https://www.npmjs.com/package/spec2cli) — confidence high
- [https://www.npmjs.com/package/@tronsfey/openapi2cli](https://www.npmjs.com/package/@tronsfey/openapi2cli) — confidence high
- [https://github.com/f/mcptools/blob/master/README.md](https://github.com/f/mcptools/blob/master/README.md) — confidence high
- [https://www.npmjs.com/package/zod](https://www.npmjs.com/package/zod) — confidence high
- [https://zod.dev/json-schema](https://zod.dev/json-schema) — confidence high
- [https://zod.dev/json-schema](https://zod.dev/json-schema) — confidence high
- [https://github.com/StefanTerdell/zod-to-json-schema](https://github.com/StefanTerdell/zod-to-json-schema) — confidence high
- [https://github.com/sinclairzx81/typebox](https://github.com/sinclairzx81/typebox) — confidence high
- [https://www.npmjs.com/package/typebox](https://www.npmjs.com/package/typebox) — confidence high
- [https://www.npmjs.com/package/elysia](https://www.npmjs.com/package/elysia) — confidence high
- [https://elysiajs.com/essential/validation](https://elysiajs.com/essential/validation) — confidence high
- [https://elysiajs.com/essential/validation](https://elysiajs.com/essential/validation) — confidence high
- [https://ajv.js.org/json-schema.html](https://ajv.js.org/json-schema.html) — confidence high
- [https://bun.com/docs/bundler/executables](https://bun.com/docs/bundler/executables) — confidence high
- [https://bun.com/docs/bundler/executables](https://bun.com/docs/bundler/executables) — confidence high
- [https://bun.com/docs/bundler/executables](https://bun.com/docs/bundler/executables) — confidence high
- [https://bun.com/docs/bundler/executables](https://bun.com/docs/bundler/executables) — confidence high
- [https://github.com/oven-sh/bun/issues/13405](https://github.com/oven-sh/bun/issues/13405) — confidence medium
- [https://cyclopts.readthedocs.io/en/latest/api.html](https://cyclopts.readthedocs.io/en/latest/api.html) — confidence medium
- [https://cyclopts.readthedocs.io/en/latest/](https://cyclopts.readthedocs.io/en/latest/) — confidence medium
- [https://github.com/effect-ts/effect/blob/main/packages/effect/SCHEMA.md](https://github.com/effect-ts/effect/blob/main/packages/effect/SCHEMA.md) — confidence medium
- [https://github.com/arcanis/clipanion/blob/master/website/docs/help.md](https://github.com/arcanis/clipanion/blob/master/website/docs/help.md) — confidence high
- [https://www.grizzlypeaksoftware.com/library/cli-framework-comparison-commander-vs-yargs-vs-oclif-utxlf9v9](https://www.grizzlypeaksoftware.com/library/cli-framework-comparison-commander-vs-yargs-vs-oclif-utxlf9v9) — confidence low

## Unverified (as reported by the job)

- {"topic": "clipanion core command-builder runtime shape (whether options really carry preferredName/nameSet/required at runtime)", "url": "https://github.com/arcanis/clipanion/blob/HEAD/sources/core/CommandBuilder.ts", "reason": "404 \u2014 no file at that path; the runtime producer behind Definition.options is unverified and only the declared type is confirmed."}
- {"topic": "@effect/cli v3 Command interface shape on npm", "url": null, "reason": "Only registry metadata and package description were retrievable; the v3 source/typedoc for the Command interface was not readable. (The page itself WAS retrieved elsewhere in this run and backs citations \u2014 this entry records an unverified topic, not an unusable source.)"}
- {"topic": "Effect Schema composition with effect/cli Flag/Argument", "url": null, "reason": "The API page read documented no Schema-accepting flag/argument constructor, and the Flag/Param API reference pages were not fetched \u2014 composition remains unconfirmed rather than established as absent. (The page itself WAS retrieved elsewhere in this run and backs citations \u2014 this entry records an unverified topic, not an unusable source.)"}
- {"topic": "@effect/cli v3 vs v4 public introspection surface", "url": "https://github.com/effect-ts/effect/blob/main/migration/v3-to-v4.md", "reason": "The migration guide confirms API churn across Effect packages, but the exact fate of the descriptor-level introspection API could not be pinned down from the retrieved text."}
- {"topic": "commander Option/Command typings (default value, arg choices, mandatory property names) for v15.0.0", "url": "https://raw.githubusercontent.com/tj/commander.js/v15.0.0/typings/index.d.ts", "reason": "Fetch rejected (too many line filters) and the tool became unavailable before a retry, so the Option class property names could not be read from source."}
- {"topic": "Bun compatibility for clipanion, @effect/cli/effect, oclif, commander, yargs, citty, cac and @stricli/core", "url": null, "reason": "No retrieved page addressed Bun runtime, Node-internals, or ESM/CJS behaviour for these libraries; only gunshi and bunli docs mention Bun, and only for argv passing."}
- {"topic": "Elysia/Bun.serve usage docs and compile-to-single-binary caveats for commander, yargs, citty, cac, gunshi, @stricli/core", "url": null, "reason": "No retrieved page addressed Bun runtime or bun build --compile compatibility for these libraries."}
- {"topic": "Maintenance cadence (stars, last push, release dates) for commander, yargs, citty, cac, gunshi and @stricli/core", "url": null, "reason": "Repository metadata was only retrieved for AryaLabsHQ/bunli, oclif/core and arcanis/clipanion; commit and release cadence for the other six is unverified."}
- {"topic": "npm weekly download volumes for all compared packages", "url": null, "reason": "Registry metadata carries no download stats and no downloads API page was retrieved."}
- {"topic": "Elysia OpenAPI plugin docs (name/API for emitting an OpenAPI document from routes)", "url": "https://elysiajs.com/plugins/openapi", "reason": "Tools became unavailable before the fetch could run; the plugin's exact name and API surface remain unverified."}
- {"topic": "@openapitools/openapi-generator-cli current version, licence and publish date", "url": "https://www.npmjs.com/package/@openapitools/openapi-generator-cli", "reason": "Only seen as a search-result snippet; registry lookup could not be performed."}
- {"topic": "Runtime Bun compatibility of spec2cli and @tronsfey/openapi2cli", "url": null, "reason": "Package metadata was verified from the npm registry, but no documentation or issue report on running these under Bun was located."}
- {"topic": "Bun-specific startup benchmarks for any of the compared CLI frameworks", "url": null, "reason": "No published, methodology-bearing Bun or Node startup measurement for these frameworks was located, so no number can be reported."}

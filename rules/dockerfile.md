---
description: Dockerfile + Compose invariants — BuildKit syntax, cache/secret mounts, layer order, non-root, healthcheck-gated depends_on. Base image and pinning are deliberately NOT prescribed.
paths: ["**/Dockerfile", "**/Dockerfile.*", "**/*.dockerfile", "**/.dockerignore", "**/compose.y*ml", "**/compose.*.y*ml", "**/docker-compose*.y*ml", "**/docker-bake.*"]
---

# Dockerfile & Compose

Most Dockerfile advice in training data predates BuildKit becoming the default
(Docker Engine 23.0). The list below is the part that is unconditionally true;
everything genuinely conditional is in **Decisions**, and must be asked, not
defaulted. Running the containers is `docker-makefile.md`'s business, not this
file's.

## Always

- **`# syntax=docker/dockerfile:1` as line 1.** Gates every feature below, and
  pins the frontend independently of the installed Engine version.
- **Layer order is the caching strategy.** Manifest (`package.json`+lockfile,
  `go.mod`+`go.sum`, `requirements.txt`) → install → `COPY` the rest of the
  source. Source changes must not invalidate the dependency install.
- **`.dockerignore` before the first build, at the *build context root*.** It
  bounds the build context, so it also bounds what a careless `COPY . .` can leak
  into a layer. The context root is frequently **not** the Dockerfile's own
  directory: read `build.context` in compose or `context:` in the CI workflow
  before writing the file. One repo can need several — `free-planning-poker`
  builds `apps/server/Dockerfile` with `context: .` and `fpp-analytics/Dockerfile`
  with `context: fpp-analytics`, so the root file governs one and cannot see the
  other. Start from `.git`, `node_modules`, `.env*`; **build output is a
  judgement call, not a default** — ignoring `dist/` is right when the image
  rebuilds it, and breaks the build when the Dockerfile `COPY`s a prebuilt
  artifact in. `~/IuRoot/prometheus-scripts` is the reference: two files, each
  with a header comment naming the context it governs.
- **Secrets via `RUN --mount=type=secret`.** Never `ARG` (lands in image
  history), never `ENV` (lands in the running image). This is an invariant, not
  a preference.
- **Package caches via `RUN --mount=type=cache`.** Use `sharing=locked` for
  apt/apk. The cache persists across builds without entering a layer, which is
  what makes `&& rm -rf /var/lib/apt/lists/*` redundant — drop the cleanup *when
  a cache mount replaces it*, not on sight. **The target path must be the cache
  directory of the RUN's effective user**, or the mount is a permanent no-op that
  looks like a working optimisation: bun-as-root `/root/.bun/install/cache`, npm
  `/root/.npm`, uv `/root/.cache/uv`, pip `/root/.cache/pip`, Go
  `/root/.cache/go-build` **and** `/go/pkg/mod`. A `USER`-switched or
  differently-based image moves these — check, don't assume.
- **`COPY --link` only when the copy depends on nothing in the layers below it.**
  It builds against an *empty* base, so it cannot see a user, group, or directory
  an earlier instruction created. `COPY --link --chown=app:app` after a
  `RUN adduser app` does not warn — it **fails the build** with `invalid user
  index: -1`; numeric `--chown=100:101` works. Worth it for large static content
  where a base-image bump would otherwise invalidate everything downstream; not a
  default, and not free to retrofit.
- **Non-root `USER`** in the final stage, and **exec-form `ENTRYPOINT`**
  (`["/app"]`, not a bare string) so signals reach PID 1 instead of a shell.
- **Compose: no `version:` key.** Obsolete in the Compose Specification —
  present only for back-compat, and Compose warns on it.
- **Compose: `depends_on: {svc: {condition: service_healthy}}`**, not the bare
  list form, which only means "started" and races on anything slower than the
  dependent. Pair with a real `healthcheck` + `start_period`.
- **`init: true`** in compose (or `--init`) for PID 1 zombie reaping and signal
  forwarding. This is a *different problem* from running multiple processes —
  don't reach for a process supervisor to solve it.

## Decisions — ask, do not default

These depend on the language, its libc coupling, and the repo's automation.
State the tradeoff and pick with the user; do not carry a house default.

- **Base image** — alpine / debian-slim / distroless / Wolfi. musl's real
  differences are specific (128 KB default thread stack vs glibc's 2–10 MB,
  parallel DNS, no lazy binding), so the answer is language-dependent: near-free
  for `CGO_ENABLED=0` Go, materially riskier for glibc-coupled C extensions.
- **Digest pinning** — immutable builds, but the pins rot into stale CVEs unless
  Renovate (`docker:pinDigests`) or equivalent is actually wired up. Don't pin
  digests by hand into a repo with no update automation.
- **Multi-stage depth**, **multi-platform strategy** (cross-compile vs QEMU vs
  native nodes), **multi-process** (separate containers vs s6-overlay; note
  supervisord neither solves PID 1 nor lets a failed process fail the container).

## Verify

Two tools, and they check different things — run both.

**`docker build --check <context>`** is BuildKit's own linter: it resolves the
frontend the `# syntax=` line pins and evaluates the build graph against it,
producing no image and running no build step. It is the only check that sees what
that specific frontend sees. Allowed by the docker-makefile hook for that reason.

**`droast <path>`** lints Dockerfiles, and discovers them from compose/bake files
too — it reads compose only to find Dockerfile paths, so it says nothing about
the compose file itself. Verified against droast 1.4.11, these fire wrongly here
and must not be actioned without checking:

| ID | Fires | Why it is wrong here |
|-|-|-|
| DF033 | "no effective build-context ignore file" | Infers the context as the *Dockerfile's own directory*. Wrong for every monorepo build using `context: .` — it reports the correct root file as missing. |
| DF004 | "apt cache not cleaned" | Not cache-mount aware; fires with `--mount=type=cache` on the same RUN, contradicting the cache-mount rule above. |
| DF030 | "pip install without --no-cache-dir" | Same contradiction. |
| DF005, DF051, DF052 | "pin apt/pip/apk package versions" | This fleet runs no Renovate. A hand-pinned version rots into a broken build — deliberately not done. |
| DF036 | "no CMD or ENTRYPOINT defined" | Does not consider the base image's own. Wrong for every `FROM nginx:*` final stage. |

Where the two disagree on anything else, droast wins on facts and this file wins
on the Decisions section. `--format json` for machine-reading, `--min-severity
error` to gate.

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
- **`.dockerignore` before the first build.** At minimum `.git`, `node_modules`,
  build output, `.env*`. It bounds the build context, so it also bounds what a
  careless `COPY . .` can leak into a layer.
- **Secrets via `RUN --mount=type=secret`.** Never `ARG` (lands in image
  history), never `ENV` (lands in the running image). This is an invariant, not
  a preference.
- **Package caches via `RUN --mount=type=cache`**, not `&& rm -rf
  /var/lib/apt/lists/*`. Use `sharing=locked` for apt/apk. The cache persists
  across builds without entering a layer — the cleanup incantation is obsolete.
- **`COPY --link`** where the source is a build stage or static content: it
  builds an independent layer, so a base-image change no longer invalidates
  everything downstream.
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

Run **`droast <path>`** before treating a Dockerfile or compose file as done —
it discovers Dockerfiles referenced from compose/bake files too. Its ruleset
ships fresher than this file does; where they disagree, it wins on facts and
this file wins on the Decisions section. `--format json` for machine-reading,
`--min-severity error` to gate.

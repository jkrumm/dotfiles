# Dependency Hygiene

npm/pnpm/bun packages are compromised regularly via supply-chain attacks
(malicious postinstall scripts, hijacked maintainer accounts, typosquats). Most
compromised versions are caught within hours, and most attacks arrive through
*transitive* dependencies. These habits cut the attack surface; they apply to
every repo regardless of package manager.

## Adding dependencies

- **Prefer none.** Every dependency is attack surface. Reach for the standard
  library, native APIs (`fetch`, `structuredClone`, `Intl`, …), or a small local
  snippet before adding a package — especially for micro-utilities (the
  Lodash/Axios/`is-odd` class of dep). In AI-assisted code this is usually a few
  lines, not a dependency.
- **When a dep is genuinely warranted**, prefer well-maintained, widely-used
  packages. Be suspicious of brand-new packages, near-miss names (typosquats),
  and anything with no repo/README/license.
- **Pin exact versions** for direct dependencies so every upgrade is deliberate.
  Note this only locks *your* direct deps — transitive ranges are still loose,
  which is why the release-age cooldown (below) matters.

## Release-age cooldown

A global cooldown is configured (`~/.bunfig.toml` → `minimumReleaseAge`) so
freshly-published versions aren't installed instantly. Do **not** bypass it
casually — only for a vetted, security-urgent fix. `bunx`/`npx` ignore the
cooldown, so treat one-off `bunx <pkg>` runs of untrusted packages with the same
caution as a fresh install.

## Install scripts

Bun and pnpm block dependency lifecycle (postinstall) scripts by default — this
is the single most common malware vector. Only re-enable a script for a package
you've vetted (`trustedDependencies` in package.json for bun; `pnpm
approve-builds` for pnpm). Never blanket-allow build scripts.

## Updating

- **Never blind-update the whole tree** (`bun update`, `npm update`,
  `pnpm update` with no target). Upgrade deliberately, one package at a time,
  with a reason — that mass-update reflex is exactly what attackers count on.
- Use `/upgrade-deps` for guided, researched upgrades.

## Lockfiles & CI

- **Always commit the lockfile** (`bun.lock`, `package-lock.json`,
  `pnpm-lock.yaml`) — never `.gitignore` it.
- **Use clean/frozen installs in CI and production**: `bun install
  --frozen-lockfile`, `npm ci`, `pnpm install --frozen-lockfile`. These install
  exactly what the lockfile specifies and fail (rather than silently re-resolve)
  if it disagrees with `package.json`.

---
description: TanStack Start SSR + integration patterns — server functions, middleware, auth, hydration, query-router coordination
paths: ["**/routeTree.gen.ts", "**/routes/**/*.ts", "**/routes/**/*.tsx", "**/router.tsx"]
source: DeckardGer/tanstack-agent-skills@b2fc14c (2026-09-09)
---

# TanStack Start Best Practices

> Official, version-locked skills ship in the npm packages: read `node_modules/@tanstack/react-start/skills/*/SKILL.md` first for API facts of the installed version (`npx @tanstack/intent@latest list` shows them). The rules below are community heuristics (not TanStack-owned); where they disagree with the installed skill, the skill wins.

Comprehensive guidelines for implementing TanStack Start patterns in full-stack React applications. These rules cover server functions, middleware, SSR, authentication, and deployment.

## Rule Categories by Priority

| Priority | Category | Rules | Impact |
|----------|----------|-------|--------|
| CRITICAL | Server Functions | 5 rules | Core data mutation patterns |
| CRITICAL | Security | 4 rules | Prevents vulnerabilities |
| HIGH | Middleware | 4 rules | Request/response handling |
| HIGH | Authentication | 4 rules | Secure user sessions |
| MEDIUM | API Routes | 1 rule | External endpoint patterns |
| MEDIUM | SSR | 5 rules | Server rendering patterns |
| MEDIUM | Error Handling | 3 rules | Graceful failure handling |
| MEDIUM | Environment | 1 rule | Configuration management |
| LOW | File Organization | 3 rules | Maintainable code structure |
| LOW | Deployment | 2 rules | Production readiness |

## Quick Reference

### Server Functions (Prefix: `sf-`)

- `sf-create-server-fn` — Use createServerFn for server-side logic
- `sf-input-validation` — Always validate server function inputs
- `sf-method-selection` — Choose appropriate HTTP method
- `sf-error-handling` — Handle errors in server functions
- `sf-response-headers` — Customize response headers when needed

### Security (Prefix: `sec-`)

- `sec-validate-inputs` — Validate all user inputs with schemas
- `sec-auth-middleware` — Protect routes with auth middleware
- `sec-sensitive-data` — Keep secrets server-side only
- `sec-csrf-protection` — Implement CSRF protection for mutations

### Middleware (Prefix: `mw-`)

- `mw-request-middleware` — Use request middleware for cross-cutting concerns
- `mw-function-middleware` — Use function middleware for server functions
- `mw-context-flow` — Properly pass context through middleware
- `mw-composability` — Compose middleware effectively

### Authentication (Prefix: `auth-`)

- `auth-session-management` — Implement secure session handling
- `auth-route-protection` — Protect routes with beforeLoad
- `auth-server-functions` — Verify auth in server functions
- `auth-cookie-security` — Configure secure cookie settings

### API Routes (Prefix: `api-`)

- `api-routes` — Create API routes for external consumers

### SSR (Prefix: `ssr-`)

- `ssr-data-loading` — Load data appropriately for SSR
- `ssr-hydration-safety` — Prevent hydration mismatches
- `ssr-streaming` — Implement streaming SSR for faster TTFB
- `ssr-selective` — Apply selective SSR when beneficial
- `ssr-prerender` — Configure static prerendering and ISR

### Environment (Prefix: `env-`)

- `env-functions` — Use environment functions for configuration

### Error Handling (Prefix: `err-`)

- `err-server-errors` — Handle server function errors
- `err-redirects` — Use redirects appropriately
- `err-not-found` — Handle not-found scenarios

### File Organization (Prefix: `file-`)

- `file-separation` — Separate server and client code
- `file-functions-file` — Use .functions.ts pattern
- `file-shared-validation` — Share validation schemas

### Deployment (Prefix: `deploy-`)

- `deploy-env-config` — Configure environment variables
- `deploy-adapters` — Choose appropriate deployment adapter

## Detailed Rules

For full explanations with code examples, read individual rules in `~/SourceRoot/dotfiles/reference/tanstack-start/`

## Integration Patterns (Query + Router + Start)

Guidelines for integrating TanStack Query + Router + Start together. 4 rules across 3 categories.

### Setup — CRITICAL (Prefix: `setup-`)

- `setup-query-client-context` — Pass QueryClient through router context
- `setup-provider-wrapping` — Correctly wrap with QueryClientProvider
- `setup-stale-time-coordination` — Coordinate staleTime between router and query

### Data Flow — HIGH (Prefix: `flow-`)

- `flow-loader-query-pattern` — Use loaders with ensureQueryData
- `flow-suspense-query-component` — Use useSuspenseQuery in components
- `flow-mutations-invalidation` — Coordinate mutations with query invalidation
- `flow-server-functions-queries` — Use server functions for query functions

### Caching — MEDIUM (Prefix: `cache-`)

- `cache-single-source` — Let TanStack Query manage caching
- `cache-preload-coordination` — Coordinate preloading between router and query
- `cache-invalidation-patterns` — Unified invalidation patterns

### SSR Integration — CRITICAL

- `ssr-dehydrate-hydrate` — Use setupRouterSsrQueryIntegration for automatic SSR
- `ssr-per-request-client` — Create QueryClient per request
- `ssr-streaming-queries` — Handle streaming with queries

## Detailed Rules

For full explanations with code examples, read individual rules in `~/SourceRoot/dotfiles/reference/tanstack-integration/`

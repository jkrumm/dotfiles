---
description: TanStack Router — type-safe routing, search params, loaders, code splitting, navigation patterns
paths: ["**/routeTree.gen.ts", "**/routes/**/*.ts", "**/routes/**/*.tsx", "**/router.tsx"]
source: DeckardGer/tanstack-agent-skills@0e8bcdc (2026-04-03)
---

# TanStack Router Best Practices

Guidelines for TanStack Router — type safety, data loading, navigation, and code organization. 15 rules across 10 categories.

## Rule Categories by Priority

| Priority | Category | Rules | Impact |
|-|-|-|-|
| CRITICAL | Type Safety | 4 | Prevents runtime errors and enables refactoring |
| CRITICAL | Route Organization | 5 | Ensures maintainable route structure |
| HIGH | Router Config | 1 | Global router defaults |
| HIGH | Data Loading | 6 | Optimizes data fetching and caching |
| HIGH | Search Params | 5 | Enables type-safe URL state |
| HIGH | Error Handling | 1 | Handles 404 and errors gracefully |
| MEDIUM | Navigation | 5 | Improves UX and accessibility |
| MEDIUM | Code Splitting | 3 | Reduces bundle size |
| MEDIUM | Preloading | 3 | Improves perceived performance |
| LOW | Route Context | 3 | Enables dependency injection |

## Quick Reference

### Type Safety — CRITICAL (Prefix: `ts-`)

- `ts-register-router` — Register router type for global inference
- `ts-use-from-param` — Use `from` parameter for type narrowing
- `ts-route-context-typing` — Type route context with createRootRouteWithContext
- `ts-query-options-loader` — Use queryOptions in loaders for type inference

### Route Organization — CRITICAL (Prefix: `org-`)

- `org-file-based-routing` — Prefer file-based routing for conventions
- `org-route-tree-structure` — Follow hierarchical route tree patterns
- `org-pathless-layouts` — Use pathless routes for shared layouts
- `org-index-routes` — Understand index vs layout routes
- `org-virtual-routes` — Understand virtual file routes

### Router Config — HIGH (Prefix: `router-`)

- `router-default-options` — Configure router defaults (scrollRestoration, defaultErrorComponent, etc.)

### Data Loading — HIGH (Prefix: `load-`)

- `load-use-loaders` — Use route loaders for data fetching
- `load-loader-deps` — Define loaderDeps for cache control
- `load-ensure-query-data` — Use ensureQueryData with TanStack Query
- `load-deferred-data` — Split critical and non-critical data
- `load-error-handling` — Handle loader errors appropriately
- `load-parallel` — Leverage parallel route loading

### Search Params — HIGH (Prefix: `search-`)

- `search-validation` — Always validate search params
- `search-type-inheritance` — Leverage parent search param types
- `search-middleware` — Use search param middleware
- `search-defaults` — Provide sensible defaults
- `search-custom-serializer` — Configure custom search param serializers

### Error Handling — HIGH (Prefix: `err-`)

- `err-not-found` — Handle not-found routes properly

### Navigation — MEDIUM (Prefix: `nav-`)

- `nav-link-component` — Prefer Link component for navigation
- `nav-active-states` — Configure active link states
- `nav-use-navigate` — Use useNavigate for programmatic navigation
- `nav-relative-paths` — Understand relative path navigation
- `nav-route-masks` — Use route masks for modal URLs

### Code Splitting — MEDIUM (Prefix: `split-`)

- `split-lazy-routes` — Use .lazy.tsx for code splitting
- `split-critical-path` — Keep critical config in main route file
- `split-auto-splitting` — Enable autoCodeSplitting when possible

### Preloading — MEDIUM (Prefix: `preload-`)

- `preload-intent` — Enable intent-based preloading
- `preload-stale-time` — Configure preload stale time
- `preload-manual` — Use manual preloading strategically

### Route Context — LOW (Prefix: `ctx-`)

- `ctx-root-context` — Define context at root route
- `ctx-before-load` — Extend context in beforeLoad
- `ctx-dependency-injection` — Use context for dependency injection

## Detailed Rules

For full explanations with code examples, read individual rules in `~/SourceRoot/dotfiles/reference/tanstack-router/`

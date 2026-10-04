---
description: TypeScript coding standards and error handling
paths: ["**/*.ts", "**/*.tsx"]
---

# TypeScript Standards

- Strict mode (`strict: true`)
- No `any` unless explicitly justified with comment
- Prefer type inference where clear, explicit types for public APIs
- Use `satisfies` for type validation without widening
- Typed objects as function arguments (not multiple parameters)

## Error Handling

- Throw and propagate errors (don't catch everywhere)
- Let errors bubble up to global handlers
- Global error monitoring where configured

---
description: Elysia (Bun) backend — routing, validation, lifecycle, plugins, encapsulation, type safety patterns
paths: ["**/api/**/*.ts", "**/server/**/*.ts"]
source: elysiajs/skills@8fd8031 (2026-01-20)
---

# Elysia Best Practices

TypeScript framework for Bun-first, type-safe, high-performance backend servers.

For latest API reference, fetch `https://elysiajs.com/llms.txt` and follow topic links.

## Critical Concepts

### Method Chaining — Required for Types

Each method returns a new type reference. Breaking the chain loses type inference.

```ts
// ✅ Chain methods
new Elysia()
  .state('build', 1)
  .get('/', ({ store }) => store.build)

// ❌ Separate calls lose types
const app = new Elysia()
app.state('build', 1)
app.get('/', ({ store }) => store.build) // build doesn't exist
```

### Encapsulation — Isolates by Default

Lifecycles don't leak between instances unless scoped.

- `local` (default) — current instance + descendants
- `scoped` — parent + current + descendants
- `global` — all instances

```ts
.onBeforeHandle(() => {})                          // local only
.onBeforeHandle({ as: 'global' }, () => {})        // exports to all
```

Global scope when: no types added (cors, helmet), global lifecycle (logging, tracing).
Explicit when: adds types (state, models), business logic (auth, db).

### Explicit Dependencies

Each instance is independent — declare what you use via `.use()`.

### Deduplication

Plugins re-execute unless named: `new Elysia({ name: 'my-plugin' })` runs once.

### Order Matters

Events apply to routes registered **after** them.

### Type Inference

Use inline functions only for accurate types. Destructure in inline wrapper for controllers:

```ts
.post('/', ({ body }) => Controller.greet(body), {
  body: t.Object({ name: t.String() })
})
```

Get type from schema: `type MyType = typeof MyType.static`

## Validation (TypeBox)

```ts
import { Elysia, t } from 'elysia'

.post('/user', ({ body }) => body, {
  body: t.Object({
    name: t.String(),
    email: t.String({ format: 'email' }),
    age: t.Optional(t.Number())
  }),
  response: {
    200: t.Object({ id: t.Number(), name: t.String() }),
    404: t.String()
  }
})
```

Also supports Zod/Valibot/ArkType via Standard Schema.

## Error Handling

```ts
.get('/user/:id', ({ params: { id }, status }) => {
  const user = findUser(id)
  if (!user) return status(404, 'User not found')
  return user
})
```

## Guards (Apply to Multiple Routes)

```ts
.guard({
  params: t.Object({ id: t.Number() })
}, app => app
  .get('/user/:id', ({ params: { id } }) => id)
  .delete('/user/:id', ({ params: { id } }) => id)
)
```

## Macros

Compose schema/lifecycle as reusable key-value:

```ts
.macro({
  requireAuth: (role: string) => ({
    beforeHandle({ headers }) { /* verify JWT + role */ }
  })
})
.get('/admin', () => 'secret', { requireAuth: 'admin' })
```

## Reference Model

```ts
new Elysia()
  .model({ book: t.Object({ name: t.String() }) })
  .prefix('model', 'Namespace')
  .post('/', ({ body }) => body.name, { body: 'Namespace.Book' })
```

## Best Practice (MVC)

- **Controller** (index.ts): HTTP routing, validation, cookies. Use Elysia instance. Register models via `.model()` with namespace prefix. Use Reference Model by name.
- **Service** (service.ts): Business logic, decoupled from HTTP. Prefer class/abstract class. Return `status()` for errors, prefer `return Error` over `throw Error`.
- **Model** (model.ts): Validation schemas + types. Always export both. Custom errors here too.

```
src/
├── index.ts              # Main server entry
├── modules/
│   ├── auth/
│   │   ├── index.ts      # Routes (Elysia instance)
│   │   ├── service.ts    # Business logic
│   │   └── model.ts      # TypeBox schemas/DTOs
│   └── user/
└── plugins/
```

## Official Plugins

| Plugin | Package | Purpose |
|-|-|-|
| CORS | `@elysiajs/cors` | Cross-origin config |
| JWT | `@elysiajs/jwt` | JWT/JWK auth |
| OpenAPI | `@elysiajs/openapi` | API documentation |
| OpenTelemetry | `@elysiajs/opentelemetry` | Tracing/instrumentation |
| Static | `@elysiajs/static` | Serve static files |
| Bearer | `@elysiajs/bearer` | Bearer token extraction |
| Cron | `@elysiajs/cron` | Scheduled jobs |
| HTML | `@elysiajs/html` | HTML/JSX responses |

## Detailed Reference

For full documentation with code examples:

- **Core**: `~/SourceRoot/dotfiles/reference/elysia/references/` (route, validation, lifecycle, plugin, cookie, macro, eden, websocket, testing, deployment)
- **Plugins**: `~/SourceRoot/dotfiles/reference/elysia/plugins/` (cors, jwt, openapi, opentelemetry, etc.)
- **Integrations**: `~/SourceRoot/dotfiles/reference/elysia/integrations/` (drizzle, better-auth, tanstack-start, etc.)
- **Patterns**: `~/SourceRoot/dotfiles/reference/elysia/patterns/mvc.md`
- **Examples**: `~/SourceRoot/dotfiles/reference/elysia/examples/` (14 .ts files)
- **Latest docs**: Fetch `https://elysiajs.com/llms.txt` for up-to-date API, then follow specific topic URLs

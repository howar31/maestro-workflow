# Backend reference

Patterns and templates for `/magi:web-backend-spec`. Read once before
elaborating a feature's backend section.

## Stack discovery

| Signal | Likely stack |
|--------|--------------|
| `package.json` + `express` / `fastify` / `koa` / `hono` / `nestjs` | Node web framework |
| `package.json` + `next.config.*` (route handlers / API routes) | Next.js full-stack |
| `pyproject.toml` + `fastapi` / `flask` / `django` | Python web framework |
| `go.mod` + `net/http` / `chi` / `echo` / `gin` | Go |
| `Cargo.toml` + `axum` / `actix-web` / `rocket` | Rust |
| `Gemfile` + `rails` | Ruby on Rails |

Detect: ORM (Prisma / TypeORM / SQLAlchemy / GORM / Active Record), DB (Postgres / MySQL / SQLite / Mongo), auth (JWT / session cookie / OAuth proxy), background jobs (BullMQ / Sidekiq / Celery / k8s CronJob).

If ambiguous, **ask the user**.

## API contract — write the schema FIRST

Always produce the contract before discussing implementation. Two flavours:

### REST + OpenAPI

```yaml
# openapi excerpt
paths:
  /users/{id}:
    get:
      operationId: getUser
      parameters:
        - name: id
          in: path
          required: true
          schema: { type: string, format: uuid }
      responses:
        '200':
          description: User
          content:
            application/json:
              schema: { $ref: '#/components/schemas/User' }
        '404':
          $ref: '#/components/responses/NotFound'
        '401':
          $ref: '#/components/responses/Unauthorized'
components:
  schemas:
    User:
      type: object
      required: [id, email]
      properties:
        id:    { type: string, format: uuid }
        email: { type: string, format: email }
```

### GraphQL SDL

```graphql
type User {
  id: ID!
  email: String!
  profile: Profile
}

type Query {
  user(id: ID!): User
}

type Mutation {
  updateUserEmail(id: ID!, email: String!): User!
}
```

### Contract review checklist

- **Versioning**: `/v1/...` in path, or via header? Sun-setting policy if breaking.
- **Pagination**: cursor-based (preferred for large sets) vs offset; consistent across endpoints.
- **Filtering / sorting**: parameter naming convention; allowlist of fields (never raw query interpolation).
- **Errors**: shape (`{error: {code, message, details?}}`), HTTP codes used (`400` vs `422` vs `409`), retryability hint if applicable.
- **Idempotency**: which endpoints accept `Idempotency-Key`? Required?
- **Rate limits**: per-token vs per-IP; documented `X-RateLimit-*` headers.
- **CORS**: which origins; for credentialed requests `Access-Control-Allow-Credentials: true` ⇒ no `*`.
- **Auth**: bearer token vs session; required scopes per endpoint.

## Data model changes

If the feature alters the schema:

- **Migration plan** — name(s) of migration files, order, rollback strategy.
- **Backfill plan** — for new NOT NULL columns on populated tables: add nullable → backfill → switch app reads → set NOT NULL. Justify if compressing steps.
- **Indexes** — add index for any new query path; drop unused.
- **Constraints** — FK, unique, check; cascade vs restrict.
- **Read replicas / lag** — if the change interacts with replication.

Long migrations on populated tables: document the **online migration**
strategy explicitly (e.g. `pg_repack`, `gh-ost` for MySQL, dual-write
periods).

## Authentication & authorisation

- Endpoint-by-endpoint authz matrix:
  - Who can call this? (role / scope / ownership rule)
  - What gets logged for audit?
- Tokens: lifetime, refresh strategy, revocation path.
- Sensitive fields: never serialise password hashes, security questions, PII beyond what the caller is entitled to.

## Validation & input safety

- Use the project's validation library (zod, yup, joi, pydantic, validator). Never trust the client.
- Reject early at the edge; do not let invalid data reach the domain layer.
- Sanitise output too: HTML-escape user-generated content rendered server-side.
- Path traversal: when accepting filenames, normalise and confine to a
  base directory (`path.resolve` and `startsWith` check).
- Logging: never log secrets, full bearer tokens, full request bodies of
  endpoints that accept credentials.

## Idempotency & retries

For any endpoint that mutates external state (charges, emails, third-party
API calls):

- Accept an `Idempotency-Key` header.
- Store the key + result for at least the maximum reasonable retry window.
- On retry with same key: return the previous result; do not re-execute.

## Observability

- **Structured logs** — JSON, with `request_id`, `user_id`, `route`, `latency_ms`.
- **Metrics** — request count / error rate / p50/p95/p99 latency per endpoint.
- **Tracing** — OpenTelemetry spans for cross-service calls.
- **Alerts** — what threshold pages whom?

## Test plan

| Layer | Tool | What it covers |
|-------|------|----------------|
| Unit | jest / vitest / pytest / go test / cargo test | Pure functions, validation, mappers. |
| Integration | testcontainers / supertest + real DB | Endpoint → DB roundtrip; transaction boundaries. |
| Contract | Pact / dredd / vitest with OpenAPI fixture | Producer/consumer contract enforcement. |
| Load (when relevant) | k6 / locust / vegeta | p95 < target under N concurrent users. |

### Contract test template (TypeScript + supertest + zod)

```typescript
// tests/api/users.contract.test.ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import { z } from 'zod';
import { createApp } from '@/app';

const UserSchema = z.object({
  id: z.string().uuid(),
  email: z.string().email(),
});

describe('GET /v1/users/:id', () => {
  let app: ReturnType<typeof createApp>;

  beforeAll(async () => { app = await createApp({ mode: 'test' }); });
  afterAll(async () => { await app.close(); });

  it('200 returns a User matching the schema', async () => {
    const res = await request(app.server)
      .get('/v1/users/123e4567-e89b-12d3-a456-426614174000')
      .set('Authorization', 'Bearer test-token')
      .expect(200);

    UserSchema.parse(res.body); // throws if shape diverges
  });

  it('404 when not found', async () => {
    await request(app.server)
      .get('/v1/users/00000000-0000-0000-0000-000000000000')
      .set('Authorization', 'Bearer test-token')
      .expect(404);
  });

  it('401 without token', async () => {
    await request(app.server).get('/v1/users/x').expect(401);
  });
});
```

## Common anti-patterns to flag

- ❌ N+1 queries — use joins / dataloaders.
- ❌ Raw SQL string interpolation with user input.
- ❌ `Promise.all` for fan-out without bounded concurrency on hot paths.
- ❌ `try { ... } catch { /* swallow */ }` — log + decide, never silent.
- ❌ Returning the full DB row when only a subset is part of the contract.
- ❌ Synchronous heavy work on the request thread (move to a job).
- ❌ Skipping migrations because "it's just a new column" — write the migration anyway.

## Deliverable

`/magi:web-backend-spec` appends to SPEC.md a **Backend** section:

```markdown
## Backend

### Stack & layers
<framework, ORM, DB, auth>

### API contract
<inline OpenAPI excerpt or .yaml file path / GraphQL SDL>

### Data model changes
- migration plan
- indexes / constraints
- backfill plan

### Authentication & authorisation
<matrix>

### Validation & safety
<rules>

### Observability
<logs, metrics, traces, alerts>

### Test plan
- Unit: ...
- Integration: ...
- Contract: tests/api/<feature>.contract.test.ts (recipe above)

### Open questions
- ...
```

Plus, when applicable, scaffold contract test file using the template above
(structure only — fill-in-the-blanks for the developer).

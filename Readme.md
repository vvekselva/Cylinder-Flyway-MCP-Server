# Cylinder Flyway MCP Server — Phase 0

This repository is the **zero-write runtime qualification** for a future Java/Flyway MCP server.

## Current scope

The service tests:

- Java 21
- Flyway 10.0.0 runtime
- PostgreSQL JDBC 42.7.2 runtime
- DNS resolution of the configured PostgreSQL endpoint
- raw TCP connectivity to port 5432
- presence of runtime secrets without exposing them
- governed migration directory and SQL count
- PostgreSQL JDBC authentication using a read-only SELECT
- genuine `Flyway.info()`

It intentionally contains **no endpoint or code path for `migrate()`, `clean()`, `repair()`, or `baseline()`**.

`DATABASE_WRITES=0` is a mandatory Phase-0 invariant.

## Frozen migration source

The Docker build downloads V1–V17 only from the frozen CylinderManagement source commit:

`3ae6e61442132d94a307275b08dd65fcef228d89`

Each downloaded SQL file is checked against the governed Git blob SHA-1 in `migration-manifest.csv`. The image build fails closed if any file differs or if the total is not exactly 17.

## Render deployment

Create a Render **Web Service** from this repository using Docker, or use `render.yaml`.

Configure these secret values in Render:

- `DB_PASSWORD` — the database password; never commit it
- `QUAL_TOKEN` — a strong random token used to protect `/qualify`; never commit it

The non-secret connection settings are already populated in `render.yaml` and `.env.example` for the current Supabase Session Pooler.

## Endpoints

### Health

`GET /health`

No database activity is performed.

### Phase-0 qualification

`POST /qualify`

Header:

`Authorization: Bearer <QUAL_TOKEN>`

The response reports PASS/FAIL gates and always reports:

`DATABASE_WRITES=0`

The DB password, DB URL, DB user and qualification token are scrubbed from exception output and are never returned as values by the qualification endpoint.

## Promotion rule

Do not build or enable the production migration MCP write tools until Phase-0 returns all mandatory PASS gates and:

`OVERALL=SUITABLE_FOR_FLYWAY_MCP`

Even after Phase-0 succeeds, BL-008 migration writes must remain genuine Flyway Java API, one governed migration at a time, with verification before advancing.

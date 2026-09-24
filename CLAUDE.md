# grap-ia

grap-ia is an agent-based chat for real estate brokers in Mexico City. Brokers add rental and sale listings in natural language, search other brokers' listings, get proactive matches, and chat with each other. End clients are never users. CDMX is the launch market, and the data model must stay ready for other Mexican cities.

- Product scope and decisions: [scope.md](scope.md)
- Approved technology stack and architecture: [tech-stack.md](tech-stack.md)

Read both before making design decisions. If a change contradicts them, raise it instead of silently diverging.

## Repository layout

```
apps/web/            Next.js PWA (TypeScript) — UI, auth session, broker-to-broker chat via supabase-js
apps/api/            FastAPI service (Python) — grap-ia agent, listings, search, matching, Inngest jobs
supabase/migrations/ SQL migrations: the single source of truth for schema, RLS, indexes, extensions
supabase/tests/      pgTAP tests for RLS policies
```

## Commands

| Task | Command |
|---|---|
| Install (web) | `pnpm install` |
| Install (api) | `cd apps/api && uv sync` |
| Local database | `supabase start`, then `supabase db reset` to apply all migrations |
| New migration | `supabase migration new <snake_case_name>` |
| RLS tests | `supabase test db` |
| Regenerate DB types | `supabase gen types typescript --local > apps/web/src/lib/database.types.ts` |
| Web checks | `pnpm lint && pnpm typecheck && pnpm test` |
| API checks | `cd apps/api && uv run ruff check . && uv run mypy . && uv run pytest` |
| Inngest dev server | `npx inngest-cli@latest dev -u http://localhost:8000/api/inngest` |

The Supabase CLI is a root `devDependency` (the `supabase` npm package). In cloud sessions, the SessionStart hook (`.claude/hooks/session-start.sh`) installs pnpm and uv dependencies and puts the CLI on `PATH`.

## Conventions

- **Language:** code, identifiers, comments, commits and docs are in English. Everything a broker sees (UI copy, agent replies, notifications) is in Mexican Spanish.
- **Schema changes** only go through new SQL migrations. Never edit an applied migration. Use the `supabase-migration` skill.
- **Row-Level Security is on for every table.** User-initiated queries from the API run under the broker's JWT claims so RLS applies (defense in depth on top of explicit checks in code). Background jobs use a privileged connection and must scope every query explicitly by the IDs they were given.
- **Identity comes from the session, never from input.** Broker IDs are never taken from request bodies, tool arguments or LLM output.
- **Money** is stored as integer centavos (`bigint`) plus an ISO currency code (`MXN` or `USD`). Areas are stored in m² as `numeric`.
- **Location** is a structured city + colonia from the SEPOMEX catalog, plus `geography(Point, 4326)` coordinates.
- **End-client personal data** (names, phones, budgets that brokers mention in chat) is regulated under Mexico's LFPDPPP. Keep it to a minimum, never put it in listings, embeddings, logs, analytics or LLM traces, and run the `privacy-review` skill on any change that touches it.
- **Slow work never blocks a chat reply.** Embeddings, photo tagging, match detection, duplicate checks and notifications run as Inngest jobs. Use the `inngest-job` skill.
- **Secrets** live in Vercel, Cloud Run and Supabase secret managers, never in the repo.

## Skills

| Skill | Use it when |
|---|---|
| `supabase-migration` | Any schema, RLS, index, function or extension change |
| `agent-tool` | Adding or changing a tool the grap-ia agent can call |
| `inngest-job` | Adding background, async or scheduled work |
| `privacy-review` | A change touches personal data, logging, tracing, analytics or a new third-party processor |
| `claude-api` (built-in) | Any Anthropic SDK code: runner config, models, prompt caching, evals |
| `security-review` (built-in) | Before merging anything auth- or data-related |

## Glossary (Mexican real estate)

| Term | Meaning |
|---|---|
| renta / arrendamiento | rent / lease (operation type) |
| venta | sale (operation type) |
| depa (departamento), casa, casa en condominio, oficina, local comercial, bodega, terreno | property types |
| PH (penthouse), garden house | apartment subtypes |
| colonia | neighborhood; the primary search zone |
| alcaldía / municipio | CDMX borough / municipality in other states |
| CP (código postal) | postal code; SEPOMEX maps it to colonias |
| recámaras | bedrooms |
| baños / medios baños | full / half bathrooms |
| cajones de estacionamiento | parking spaces |
| m² de construcción / m² de terreno | built area / land area |
| amueblado / semi-amueblado | furnished / partly furnished |
| pet friendly / acepta mascotas | pets allowed |
| mantenimiento | monthly HOA / maintenance fee |
| depósito | security deposit (often 1–2 months) |
| aval / fiador | guarantor |
| póliza jurídica | rental legal-protection policy, common alternative to an aval |
| exclusiva | exclusive listing held by one broker |
| comisión compartida | commission split between the listing and buyer/tenant brokers |
| asesor inmobiliario | real estate broker/agent |
| AMPI | Asociación Mexicana de Profesionales Inmobiliarios |
| predial | property tax |
| escrituras | property deed |
| uso de suelo | zoning / land use |
| "28 mil", "28k" | 28,000 MXN (brokers rarely say "pesos") |
